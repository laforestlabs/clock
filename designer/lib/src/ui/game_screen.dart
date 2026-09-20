// The game screen.
//
// Shows the game running on a simulated LED panel, driven by a ticker that
// steps the simulation every frame and renders the RGBA8888 bytes through the
// same paint path the layout preview uses: one emitter disc per lit cell with
// dead space between pixels, and the same veneer diffusion pass.
//
// The veneer and LED settings are shared with the designer through the
// DesignerController: changing them here changes the layout preview too, and
// vice versa. They are display-layer settings, not game state.
//
// Controls: the play surface is the same set of buttons whether the simulation
// runs here or on a connected mirror - movement under the left thumb, actions
// under the right, the local panel in the middle and nothing there in mirror
// mode. Pad presses and releases are dispatched on the edge they arrive on, so
// a tap that fits inside one frame still lands, and the ticker keeps feeding
// the full held state as recovery. Every control is owned by its sources - a
// pointer, a physical key, tilt, or a semantic activation - so two fingers (or
// a finger and a key) can hold the same control without one release cancelling
// the other.
//
// Keyboard: arrow keys / WASD drive the round's declared direction controls
// (Up/W, Down/S, Left/A, Right/D), Space is Shoot while a round is live and
// starts or replays one otherwise, P or Escape toggles pause. The preview is
// display-only: the pads are the only local input.
//
// Keyboard and pointer input belongs to whichever round the screen is feeding,
// local or mirror: the Focus around the play surface resolves key labels from
// that round's control metadata. An interruption - the app leaving the
// foreground, or the play surface losing keyboard focus - pauses a live round
// (and stops it on firmware that cannot pause), because a round nobody is
// holding must not keep running. Resuming is always an explicit request.
//
// Choosing and learning a game happen before it starts: the setup view states
// the selected game's goal, its actual controls, and which screen shows the
// game (the preview here, or the mirror's panel). During play only Pause, Help
// and the controls are prominent; panel size, veneer/LED, tick count, latency
// live in a closed-by-default Display & diagnostics sheet, and Help and that
// sheet pause the round before they open. The round's actions - Resume,
// Restart, Choose game, and Play again once it is terminal - are on the screen
// it applies to; anything that would throw away a nonterminal round asks once
// first, and backing out of the screen uses the same question.
//
// Tilt is calibrated deliberately: a motion round calibrates before its first
// start, keeps that mapper (and its sensor subscription) across an ordinary
// pause, and rebuilds it for Recalibrate or after the app was suspended. While
// neutral samples are still pending the round does not start at all, and a
// sensor that fails leaves the manual pad in charge.
//
// The local preview always shows the newest frame the simulation produced, and
// only ever one decode is in flight. The simulation keeps its cadence while
// the decoder is busy - the frames it skips are never copied - and the panel
// catches up to the state the engine is in the moment the decoder frees, so a
// round that outruns its decoder shows where it is rather than where it was. A
// decoded frame belongs to the round that made it: a frame that lands after
// that round was replaced, paused, or thrown away is disposed instead of drawn
// over the round that took its place, and the picture on screen when a round
// is paused is the picture it is frozen on. A round whose frames cannot be
// produced at all says so, with the way back to setup, instead of going blank.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../controller.dart';
import '../engine/game_bindings.dart' show GameLibraryException;
import '../engine/game_engine.dart';
import '../services/mirror_ble.dart';
import '../services/mirror_ble_game.dart';
import '../services/mirror_ble_status.dart';
import '../services/mirror_connection.dart';
import '../services/motion_control.dart';
import '../services/tilt_sensor.dart';

/// How the mirror game is controlled: the on-screen gamepad or phone tilt.
enum _InputMode { manual, motion }

/// The actions behind the screen's overflow menu. They all apply to the round
/// on screen, so they are disabled when there is none.
enum _MenuAction { diagnostics, restart, choose }

/// Where the round on screen stands, local or mirror. This replaces the
/// overlapping booleans that used to track "running" and "mirror game over":
/// every play action and every asynchronous mirror transition reads one
/// value, so a stale reply can never flip two flags out of step.
///
/// Loading of the mirror's game catalogue is deliberately not part of this
/// enum: a catalogue that is still loading says nothing about the round.
enum _PlayPhase {
  /// Nothing is running. The local setup view, or the mirror's game picker.
  idle,

  /// `game start <id>` is in flight on the mirror.
  starting,

  /// A round is live and this screen is feeding it input.
  playing,

  /// A pause request is in flight (mirror rounds only).
  pausing,

  /// The round is frozen and every input is released: the mirror accepted
  /// `game pause`, or the local preview retained its engine without stepping
  /// it. The round itself is still there to be resumed.
  paused,

  /// A resume request is in flight (mirror rounds only).
  resuming,

  /// `game stop` is in flight on the mirror.
  stopping,

  /// The round reached its terminal state (game over, or a win).
  over,
}

/// One thing holding a control. Sources compare by identity, so a second
/// press from the same pointer, or a repeated key-down from the same physical
/// key, is not a new press and does not restart a hold.
sealed class _InputSource {
  const _InputSource();
}

/// A finger on a pad.
final class _PointerSource extends _InputSource {
  const _PointerSource(this.pointer);

  final int pointer;

  @override
  bool operator ==(Object other) =>
      other is _PointerSource && other.pointer == pointer;

  @override
  int get hashCode => Object.hash('pointer', pointer);
}

/// A physical key. Identified by the key, not the event, so its key-repeat
/// events keep holding the same control instead of pressing it again.
final class _KeySource extends _InputSource {
  const _KeySource(this.key);

  final LogicalKeyboardKey key;

  @override
  bool operator ==(Object other) => other is _KeySource && other.key == key;

  @override
  int get hashCode => Object.hash('key', key);
}

/// An accessibility activation of one pad: a discrete press, and for a
/// movement control a hold long enough to span a game tick.
final class _SemanticSource extends _InputSource {
  const _SemanticSource(this.control);

  final int control;

  @override
  bool operator ==(Object other) =>
      other is _SemanticSource && other.control == control;

  @override
  int get hashCode => Object.hash('semantic', control);
}

/// Human-facing copy for one game: what it asks of the player, and the names
/// of any controls whose wire label names a code rather than an action.
class _GameCopy {
  const _GameCopy(
      {required this.goal, this.aliases = const <String, String>{}});

  final String goal;
  final Map<String, String> aliases;
}

/// How the phone is currently reading tilt, for a round that is steered by it.
enum _MotionPhase {
  /// Not reading tilt: manual mode, or no round being set up.
  off,

  /// Waiting for the player to hold the phone still: neutral is being
  /// established from the first samples, and no game starts until it is.
  calibrating,
}

/// One pad button of the round on screen: its index in the held state (which
/// is its control code), the wire label it carries, the human label drawn on
/// it, and the keys it answers to.
class _PadSpec {
  const _PadSpec({
    required this.index,
    required this.wire,
    required this.label,
    required this.hint,
  });

  final int index;
  final String wire;
  final String label;
  final String hint;

  /// Whether this pad is a movement direction rather than an action.
  bool get isDirection =>
      label == wire && _GameScreenState._directionWires.contains(wire);
}

/// The largest zoom that shows a [canvasWidth]x[canvasHeight] game inside a
/// [maxWidth]x[maxHeight] box, filling the tighter axis exactly. Never below 1,
/// so a game never gets shrunk past one screen pixel per cell.
double fitGameZoom({
  required double maxWidth,
  required double maxHeight,
  required int canvasWidth,
  required int canvasHeight,
}) {
  final zw = maxWidth / canvasWidth;
  final zh = maxHeight / canvasHeight;
  final zoom = zw < zh ? zw : zh;
  return zoom < 1 ? 1 : zoom;
}

/// A game running on a simulated panel.
class GameScreen extends StatefulWidget {
  const GameScreen({
    super.key,
    required this.controller,
    required this.connection,
    this.decodeFrame,
    this.simplified = false,
  });

  /// Shares veneer and LED settings with the layout designer.
  final DesignerController controller;

  /// The app-scoped BLE link. While connected, this screen becomes a gamepad
  /// for the game the mirror runs on its panel; the simulation below is only
  /// for the not-connected case.
  final MirrorConnection connection;

  /// How a rendered frame becomes a panel image. The default - the engine's
  /// own decoder, which reads pixels off `dart:ui` - is what the app always
  /// uses; the seam exists so a regression can hold one decode open across a
  /// restart and show that a frame from the round that is gone never draws
  /// over the round that replaced it. The simulation itself is never
  /// replaced: the bytes handed here are the ones the native game rendered.
  final Future<ui.Image?> Function(GameEngine engine, Uint8List bytes)?
      decodeFrame;

  /// Trimmed surface, for the app's default view: tilt is how a round is
  /// steered and the pads are what a device without a working accelerometer
  /// falls back to, so there is no mode to choose, and the panel size, the
  /// display settings and the round's diagnostics stay in the developer
  /// workspace.
  final bool simplified;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late Ticker _ticker;

  /// The gameplay focus: the node every key the round understands arrives on.
  /// Both the local and the mirror play surface sit inside it, so it is also
  /// how the screen notices that the player walked away from the controls.
  late FocusNode _gameplayFocus;
  GameEngine? _engine;
  ui.Image? _image;
  Uint8List? _frame;
  Duration _lastTime = Duration.zero;

  /// Why the local round cannot go on: a frame the engine would not render, a
  /// decode that failed, or a step the engine refused. Shown in place of the
  /// play surface with a way back to setup, so a round that breaks is never a
  /// permanently blank panel.
  String? _playError;

  /// The generation of the local session on screen. Every start, pause, stop
  /// and disposal bumps it, and a decode carries the generation it was begun
  /// in: a frame whose round has since been replaced, frozen, or thrown away
  /// is rejected and its image disposed rather than drawn. This is what keeps
  /// a pre-pause decode from landing on a resumed round, and a previous
  /// game's frame from flashing into the next one.
  int _localGeneration = 0;

  /// Whether a decode is in flight. Exactly one runs at a time - across
  /// restarts and stops too, since the old future keeps the slot until it
  /// resolves - so a round that outruns the decoder cannot pile up images.
  bool _decodeBusy = false;

  /// Whether a frame was wanted while the decode slot was busy. Set instead of
  /// copying another set of stale bytes, drained by rendering the state the
  /// engine is in when the slot frees: the panel catches up to the newest
  /// frame instead of replaying the ones nobody saw.
  bool _decodePending = false;

  // Panel sizes the game can run at, same set the hardware supports.
  static const _panelSizes = <_PanelPreset>[
    _PanelPreset('Mini (64x32)', 64, 32),
    _PanelPreset('Square (64x64)', 64, 64),
    _PanelPreset('Wide (128x64)', 128, 64),
    _PanelPreset('Large (128x128)', 128, 128),
  ];

  /// The reason a mirror gives when the round a command was about has already
  /// reached its terminal state (`game error game over`). A pause or resume
  /// refused with it means the session is finished, not that the command was
  /// rejected.
  static const String _gameOverReason = 'game over';

  /// The lowest side a pad button may shrink to. A play surface that cannot
  /// give every button this much room is refused, not clipped.
  static const double _minPadSide = 48;

  /// The gap between the movement grid, the panel, and the action column, and
  /// between two buttons. Also the unit the shared button-size formula
  /// reserves its spacing in.
  static const double _padGap = 8;

  /// The largest a pad button ever grows, so the controls stay the same size
  /// on a tablet as on a phone.
  static const double _maxPadSide = 96;

  /// The wire labels that mean movement. Everything else a round declares
  /// (Shoot today, any action tomorrow) is an action button.
  static const Set<String> _directionWires = <String>{
    'Up',
    'Down',
    'Left',
    'Right',
  };

  /// The labels that name the phone's two accelerometer axes on the wire. A
  /// control is tilt-driven when it is declared as an axis under one of these
  /// labels: the label says which way the phone is held, the type says it is
  /// positional rather than something to press.
  static const Set<String> _tiltLabels = <String>{'TiltX', 'TiltY'};

  /// Human-facing copy for the games this build ships: the one-sentence goal
  /// the setup view and Help show, and the names of controls whose wire label
  /// names the code rather than the action.
  ///
  /// This is presentation only. No gameplay rule and no network code lives
  /// here, and a game the app does not know - a mirror id this build does not
  /// compile - keeps its raw name with no invented instructions.
  static const Map<String, _GameCopy> _gameCopy = <String, _GameCopy>{
    'rally': _GameCopy(
      goal: 'Move your paddle up and down. Get the ball past the computer.',
    ),
    'snake': _GameCopy(
      goal: 'Eat the food and avoid the walls and your tail. '
          'You cannot reverse direction.',
    ),
    'tetris': _GameCopy(
      goal: 'Fill rows to clear them. Rotate pieces and hold Soft drop to '
          'fall faster.',
      aliases: <String, String>{'Up': 'Rotate', 'Down': 'Soft drop'},
    ),
    'breakout': _GameCopy(
      goal: 'Clear the bricks and keep the ball in play. '
          'You have three lives.',
    ),
    'invaders': _GameCopy(
      goal: 'Move left and right, and shoot before the invaders reach you.',
    ),
    'probe': _GameCopy(
      goal: 'The tilt visualiser: the red dot sits where the phone points. '
          'Move it with the buttons or with tilt.',
    ),
  };

  /// The goal sentence for a game id, or null for one this build does not
  /// know. Never invented: an unknown mirror game simply has no goal to show.
  static String? _goalFor(String id) => _gameCopy[id]?.goal;

  /// The keys each control answers to, shown on its pad so the mapping is
  /// visible without opening anything.
  static const Map<String, String> _keyHints = <String, String>{
    'Up': 'Up / W',
    'Down': 'Down / S',
    'Left': 'Left / A',
    'Right': 'Right / D',
    'Shoot': 'Space',
  };

  int _sizeIndex = 0;

  int _seed = 1;

  /// Where the round on screen stands. Set by the local start/stop and by the
  /// mirror's start/stop/pause transitions; never by a superseded transition.
  _PlayPhase _phase = _PlayPhase.idle;

  /// The resolved held state of the round on screen, sized when a local game
  /// is opened or the mirror acknowledges a start. This is what the local
  /// engine is fed and what the mirror receives; it is rebuilt from [_sources]
  /// and [_axes] on every change rather than written directly by a handler, so
  /// opposing directions cancel and two sources can hold one control.
  List<int> _held = const <int>[];

  /// Which sources hold each button control. A source is a pointer id, a
  /// physical key, tilt, or a semantic activation; ownership is per source, so
  /// releasing one of two sources holding the same control leaves it held.
  final Map<int, Set<Object>> _sources = <int, Set<Object>>{};

  /// Raw axis values (the probe's two tilt axes) by control index. Axes are
  /// not buttons: they never take part in source ownership, and they are
  /// rendered as readouts rather than pads.
  final Map<int, int> _axes = <int, int>{};

  /// The local game actually on screen. Restart replays this game, not
  /// whatever the picker happens to show afterwards.
  GameInfo? _localGame;

  /// The running local game's controls in code order, captured when the engine
  /// was opened. Keyboard and pad input resolve their labels from here, so a
  /// restart with another game cannot feed the previous one's controls. The
  /// declared type travels with each label: an axis is driven by tilt and
  /// drawn as a readout, never as a pad.
  List<GameControl> _localControls = const <GameControl>[];

  /// The control each movement-pad pointer is currently steering, so sliding
  /// from one direction button onto the next releases the first.
  final Map<int, int> _padPointers = <int, int>{};

  /// Pointers whose action button released them by leaving its rectangle. A
  /// button is never re-armed by sliding back into it.
  final Set<int> _deadPointers = <int>{};

  /// The 50 ms holds behind accessibility activation of a movement control,
  /// keyed by control index.
  final Map<int, Timer> _semanticHold = <int, Timer>{};

  /// Set while a build has found the play surface too small for its minimum
  /// pad size, so the one pause it schedules is not scheduled again.
  bool _spacePauseScheduled = false;

  List<GameInfo> _games = const <GameInfo>[];
  int _gameIndex = 0;

  /// Why the local game library is unavailable, or null when it loaded. A
  /// missing library is presented in place of the picker instead of crashing
  /// the screen during startup.
  String? _libraryError;

  DesignerController get _c => widget.controller;
  MirrorConnection get _connection => widget.connection;

  // Controller mode: the mirror runs the game, this phone streams buttons.
  //
  // The catalogue (ids, loading, listing error) is tracked separately from
  // the round on purpose: a list that is still loading or failed says nothing
  // about whether a game is running.
  List<String>? _mirrorGameIds;

  /// The mirror game the picker has selected, or null for "the first one the
  /// mirror offers". The selection is an id rather than an index because the
  /// mirror's catalogue arrives as ids and the dropdown indexes into whatever
  /// the device listed.
  String? _mirrorSelected;
  bool _mirrorUnsupported = false;
  bool _mirrorLoading = false;

  /// The device's reason for refusing to list its games, or null. A named
  /// error is retryable: the link is still up and the mirror answered.
  String? _mirrorListError;

  /// The mirror game this screen believes is running, or null. Set before the
  /// start command is written and kept until the round is stopped or the link
  /// is lost, so a late terminal notification can still be matched to it.
  String? _mirrorGameId;
  MirrorGame? _mirrorGame;

  /// Whether the mirror paused the round while `game start` was still in
  /// flight: `game ok <id>` must then leave the round paused, not running.
  bool _pendingPaused = false;

  /// Whether the mirror reported the round over while `game start` was still
  /// in flight: the acknowledged start must not overwrite it with `playing`.
  bool _pendingOver = false;

  /// Whether the player walked away (or the app left the foreground) while a
  /// transition was still in flight. The round is then paused the moment the
  /// transition lands in `playing`, instead of running unattended until the
  /// next interruption.
  bool _pendingInterruption = false;

  /// Whether that deferred interruption was one the player did not ask for.
  /// An automatic one stops a round whose firmware cannot pause; a deliberate
  /// one (Help, Display & diagnostics, the discard question) just reports the
  /// refusal and leaves the round running.
  bool _pendingInterruptionAutomatic = true;

  /// Monotonic generation of the newest mirror transition. Combined with the
  /// captured session identity it lets every await inside a transition check
  /// that its operation was not superseded by a newer one, a disconnect, or
  /// the route being disposed.
  int _opGeneration = 0;

  /// The session the screen last reacted to, so a replacement is noticed even
  /// when both the old and the new session are non-null.
  BleSession? _seenSession;

  StreamSubscription<String>? _gameOverSub;
  int _lastMirrorSendMs = 0;
  BleLatency? _latency;
  int _roundTripMs = 0;
  _InputMode _inputMode = _InputMode.manual;

  /// Whether this device's accelerometer reports. Asked once for this screen,
  /// before any calibration: the answer decides whether tilt is offered at all,
  /// and a device that has none is never asked to hold still.
  final TiltSensor _tilt = TiltSensor();

  /// The local simulation ticks (and mirror heartbeat ticks) of the round on
  /// screen. A diagnostic readout, reset with every round.
  int _ticks = 0;

  /// The tilt mapper the current motion round is steered by. Built while the
  /// player holds the phone still, kept across an ordinary pause, and thrown
  /// away by Recalibrate, a suspension, or the end of the round.
  MotionControl? _motion;

  /// The accelerometer subscription feeding [_motion], or null while it is
  /// detached (paused, or calibrating).
  StreamSubscription<AccelerometerEvent>? _motionSub;
  _MotionPhase _motionPhase = _MotionPhase.off;

  /// Samples collected into the mapper being calibrated, for the "hold still"
  /// progress. Mirrors [MotionControl.calibrationSamples]; the mapper itself
  /// decides when neutral is established.
  int _calibrationSamples = 0;
  static const int _calibrationTarget = 20;

  /// Completes when calibration finishes, fails, or is cancelled. Only one
  /// calibration is pending at a time, and a superseded one never completes
  /// the newest request.
  Completer<bool>? _calibration;

  /// Fires when no sample has arrived for two seconds while neutral is still
  /// pending: a sensor that is not reporting must not leave the player
  /// waiting on a game that will never start.
  Timer? _calibrationTimer;

  /// Milestone for the sensor subscription and the calibration watchdog, so a
  /// stale sample or timer cannot touch a newer calibration.
  int _motionGeneration = 0;

  /// The gyroscope subscription feeding [_motion]. Its life is the
  /// accelerometer's, but its failure is not: a device without a gyroscope
  /// still steers, on the accelerometer alone.
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  /// Whether the gyroscope has reported that this device has none. The mapper
  /// falls back to the accelerometer and the surface says which estimator is
  /// running, so a degraded round never looks like a healthy one.
  bool _gyroUnavailable = false;

  /// Whether the player has been told about the missing gyroscope, so it is
  /// said once and not on every round.
  bool _gyroWarned = false;

  /// Fires when a calibration hold has not become still enough in time. The
  /// accelerometer watchdog cannot see this: samples are arriving, they are
  /// all being refused as "not at rest", and the hold would never complete.
  Timer? _calibrationStillTimer;

  /// How long a hold may take before that is reported as a failure rather than
  /// left running. Twenty still samples take 0.4 s at 50 Hz, so this is the
  /// time a player gets to stop moving, not the time the measurement needs.
  static const Duration _calibrationStill = Duration(seconds: 5);

  /// The last time an axis value was sent to the mirror. Analog tilt is
  /// throttled to one send per 20 ms; the heartbeat carries the newest value
  /// in between.
  int _lastAxisSendMs = 0;

  /// How many screen-owned modals (Help, Display & diagnostics, the discard
  /// question) are open. While one is, the gameplay Focus is expected to move
  /// away from the play surface, and the automatic interruption stands down:
  /// the caller already paused deliberately.
  int _modalDepth = 0;

  /// Whether the Display & diagnostics sheet is on screen. Latency is polled
  /// only while it is.
  bool _diagSheetOpen = false;

  /// The periodic poll behind the open Display & diagnostics sheet.
  Timer? _latencyTimer;

  /// The diagnostics request in flight, if any: one at a time, and a game
  /// transition waits for it.
  Future<void>? _diagPending;

  /// Bumped when a diagnostic readout changes, so the open sheet rebuilds.
  final ValueNotifier<int> _diagRevision = ValueNotifier<int>(0);

  /// Whether this screen is a gamepad for a connected mirror.
  bool get _isControllerMode => _connection.session != null;

  /// Whether a mirror transition is in flight. Conflicting and duplicate
  /// actions stay disabled until it settles.
  bool get _mirrorBusy =>
      _phase == _PlayPhase.starting ||
      _phase == _PlayPhase.stopping ||
      _phase == _PlayPhase.pausing ||
      _phase == _PlayPhase.resuming;

  /// Whether neutral is still being established for a motion round. The
  /// calibration view owns the screen while it is, so nothing else may start.
  bool get _motionBusy => _motionPhase == _MotionPhase.calibrating;

  /// Whether the local preview has a round on screen: live, paused, or
  /// finished but not yet discarded. A mirror round never counts, even though
  /// it shares the phase.
  bool get _localRound =>
      !_isControllerMode &&
      (_phase == _PlayPhase.playing ||
          _phase == _PlayPhase.paused ||
          _phase == _PlayPhase.over);

  @override
  void initState() {
    super.initState();
    // The game screen is operated like a handheld controller, and a motion
    // round's tilt mapping is the landscape-left one. Ask for that single
    // orientation while this screen is up; the rest of the designer goes back
    // to both orientations on the way out (see dispose).
    unawaited(SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
    ]));
    try {
      _games = GameEngine.games;
    } on GameLibraryException catch (e) {
      // The native library is missing the game symbols: present that instead
      // of crashing the route during its first build.
      _games = const <GameInfo>[];
      _libraryError = e.message;
    }
    _ticker = Ticker(_onTick);
    _gameplayFocus = FocusNode();
    // The app leaving the foreground is an interruption like any other: a
    // suspended phone must not keep driving (or keep a mirror game running
    // unattended).
    WidgetsBinding.instance.addObserver(this);
    _connection.addListener(_onConnectionChanged);
    // First evaluation after the first build: the connection may already be
    // up when the screen opens, and a listener that setStates during build
    // would assert.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onConnectionChanged());
    // Ask about the accelerometer now rather than when a round is about to
    // start: the answer is what decides whether tilt is on offer, and asking it
    // while the player is still choosing a game costs nobody anything. On a
    // device that has no sensor the fallback is settled before Start is
    // reached, so no round pays for the discovery.
    _startInputMode();
  }

  /// The mode a fresh screen starts in, and the sensor question behind it.
  ///
  /// The developer workspace starts on the pads, because the player there
  /// picks the mode and the screen must not choose for them. The default view
  /// has no mode to pick, so it starts on tilt and drops to the pads the
  /// moment the accelerometer says it does not report.
  void _startInputMode() {
    _inputMode =
        widget.simplified ? _InputMode.motion : _InputMode.manual;
    if (widget.simplified) {
      // The panel an offline preview round runs on is the mirror's, when the
      // mirror has said what it is: the size picker that would otherwise offer
      // this lives in the developer workspace.
      _sizeIndex = _presetFor(_connection.panelWidth, _connection.panelHeight);
    }
    unawaited(_tilt.present().then((present) {
      if (!mounted) return;
      // A device that does report needs nothing said about it. One that does
      // not has the default view moved off tilt here, so a round started later
      // never waits on a calibration that cannot finish. The workspace keeps
      // the player's own choice and explains in place of the picker why it
      // cannot work; its start refuses rather than running unsteerable.
      if (present || !widget.simplified) {
        setState(() {});
        return;
      }
      setState(() {
        if (_phase == _PlayPhase.idle || _phase == _PlayPhase.paused) {
          _inputMode = _InputMode.manual;
        }
      });
      _showMessage('No tilt sensor on this device: the pads steer the game');
    }));
  }

  /// The panel preset matching a geometry, or the 64x32 reference build when
  /// the size is unknown or is not one of the presets.
  int _presetFor(int w, int h) {
    final index = _panelSizes.indexWhere((p) => p.w == w && p.h == h);
    return index < 0 ? 0 : index;
  }

  @override
  void dispose() {
    // The rest of the designer supports either phone orientation.
    unawaited(SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
    _connection.removeListener(_onConnectionChanged);
    WidgetsBinding.instance.removeObserver(this);
    // Any mirror transition still awaiting its reply must not apply its
    // result to a disposed route.
    _opGeneration++;
    _gameOverSub?.cancel();
    _gameOverSub = null;
    // Nothing may be left awaiting the sensor: the probe ends as "no sensor"
    // with the screen that asked about it.
    _tilt.dispose();
    final session = _connection.session;
    if (_mirrorGameId != null && session != null) {
      // Leaving the screen stops the mirror's game. The device may already be
      // gone or refuse the command, and the route is gone either way.
      unawaited(_stopMirrorOnLeave(session));
    }
    // The route is going away: drop every held control, tell the mirror
    // explicitly, and stop the sources that kept the round alive.
    _releaseMirrorInput();
    _stopLatencyPoll();
    _discardMotion();
    _diagRevision.dispose();
    // The local round goes with the route: its engine and its last frame are
    // destroyed and the decode in flight for it is invalidated - that
    // completion finds the route gone and disposes its own image - so a frame
    // can never draw into a disposed screen.
    _disposeLocalSession();
    // Disposed, not only stopped: a stopped ticker still holds the callback
    // and the vsync registration.
    _ticker.dispose();
    _gameplayFocus.dispose();
    super.dispose();
  }

  /// The games the picker offers, in catalogue order. The probe is one of
  /// them: it is the tilt visualiser - a red dot that sits where the phone
  /// points - and picking it is how a player sees what motion control is
  /// doing before a round depends on it.
  List<GameInfo> get _playableGames => _games;

  static bool _isProbeId(String id) => id == 'probe';

  /// The mirror's catalogue, as offered by its own picker.
  List<String> get _mirrorPlayableIds =>
      _mirrorGameIds ?? const <String>[];

  /// The game a fresh Start on the mirror begins: the picker's selection, or
  /// the mirror's first game that is played for score. The probe is never
  /// picked for a player who has not asked for it: it is a diagnostic, not a
  /// round, so it stays out of the default and nothing startles a player with
  /// it. Null when the mirror offers none.
  String? get _mirrorPlayableSelection {
    final playable = _mirrorPlayableIds;
    if (playable.isEmpty) return null;
    final selected = _mirrorSelected;
    if (selected != null && playable.contains(selected)) return selected;
    for (final id in playable) {
      if (!_isProbeId(id)) return id;
    }
    return playable.first;
  }

  /// Hand keyboard control back to the round after a picker selection. The
  /// setup view lives inside the gameplay Focus, so without this a keyboard
  /// player would leave Space and the arrows with the dropdown they just used
  /// (a focused dropdown owns its own keys - including re-opening itself on
  /// Space).
  void _reclaimGameplayFocus() {
    if (!mounted) return;
    _gameplayFocus.requestFocus();
  }

  /// Start the game the picker shows.
  void _startGame() {
    if (_isControllerMode) return;
    final games = _playableGames;
    if (games.isEmpty || _gameIndex >= games.length) return;
    _startLocalGame(games[_gameIndex]);
  }

  /// Start the game the picker shows, establishing tilt neutral first when the
  /// round is to be steered by the phone. A calibration the player cancelled
  /// or a sensor that never reported leaves the setup view alone.
  Future<void> _startLocalFromSetup() async {
    final games = _playableGames;
    if (games.isEmpty || _gameIndex >= games.length) return;
    final game = games[_gameIndex];
    if (!await _motionAllowsPlay()) return;
    if (!mounted) return;
    _startLocalGame(game);
  }

  /// Whether play may go ahead with the mode the screen is in.
  ///
  /// A motion round establishes neutral first, and a calibration that failed
  /// or was cancelled declines the action. The default view is the exception:
  /// the player there never chose tilt, so a device that cannot calibrate
  /// falls back to the pads instead of being unable to play at all. A
  /// deliberate cancel is still a cancel in either view - the mode is still
  /// motion, so nothing happens until the player asks again.
  Future<bool> _motionAllowsPlay() async {
    if (_inputMode != _InputMode.motion) return true;
    if (await _ensureMotionReady()) return true;
    return widget.simplified && _inputMode != _InputMode.motion;
  }

  /// Start (or restart) one local game. A library failure leaves the setup
  /// view in place with the reason on screen: nothing is indexed blindly.
  ///
  /// A restart opens a fresh session: the previous engine and its frame are
  /// destroyed rather than resumed, its decode - if one is still in flight -
  /// is invalidated so it cannot draw over the new round, and every input
  /// source is released so a key that was down in the old round cannot appear
  /// pressed in the new one.
  void _startLocalGame(GameInfo game) {
    final panel = _panelSizes[_sizeIndex];
    _disposeLocalSession();
    final GameEngine engine;
    try {
      engine = GameEngine.open(
        gameId: game.id,
        panelWidth: panel.w,
        panelHeight: panel.h,
        seed: _seed,
        // This screen has one input route, so it opens a single-player
        // engine. Rally's absent second player is the AI the runtime attaches;
        // multiplayer support stays in the runtime, the FFI, and the CLI.
        players: 1,
      );
    } on GameLibraryException catch (e) {
      setState(() {
        _phase = _PlayPhase.idle;
        _libraryError = e.message;
        _playError = null;
        _image = null;
        _frame = null;
        _held = const <int>[];
        _localGame = null;
        _localControls = const <GameControl>[];
      });
      return;
    }
    setState(() {
      _engine = engine;
      _localGame = game;
      _localControls = game.controls;
      _phase = _PlayPhase.playing;
      _libraryError = null;
      _playError = null;
      _image = null;
      _frame = null;
      // The resolved state is built from the round's own controls, so an axis
      // starts idle - not at the middle of its travel, which would fight the
      // phone from the first frame.
      _held = List<int>.filled(game.controls.length, 0);
      // The ticker's clock restarts with the round: zero means "the next
      // frame is the first one, use the nominal step".
      _lastTime = Duration.zero;
      _ticks = 0;
    });
    _recomputeHeld();
    // Motion only means something for a round that declares a tilt axis. A
    // game that takes none (nothing this build ships) is played on the pads
    // and told so, rather than started unsteerable.
    if (_inputMode == _InputMode.motion && !_tiltDrivesAxes) {
      _discardMotion();
      setState(() => _inputMode = _InputMode.manual);
      _showMessage('This game does not take tilt; use manual controls');
    }
    // Opening the round discarded the local session, and with it the sensor
    // subscription the calibration was reading. A motion round re-attaches the
    // mapper it was calibrated with - the same rule the mirror path follows,
    // and the reason a preview round is steerable at all.
    if (_inputMode == _InputMode.motion) _attachMotion();
    // Restarting (start over) runs while the ticker may already be active.
    if (!_ticker.isActive) unawaited(_ticker.start());
    // Critical: reclaim focus after the button was tapped, so the Focus
    // wrapping the body gets keyboard events before the traversal system.
    _gameplayFocus.requestFocus();
    _seed++;
  }

  /// Pause the local preview where it is. The engine, its board, and the last
  /// decoded frame are all retained: Resume continues this round, and only
  /// Choose game (or a fresh Start) discards it. Every input source is
  /// released first - in the engine as well as in Dart - so nothing stays held
  /// across the pause, and a decode that is still in flight is invalidated so
  /// the panel keeps the frame the pause froze.
  void _pauseLocalGame() {
    if (_isControllerMode || _phase != _PlayPhase.playing) return;
    _sendLocalRelease();
    // The sensor is dropped with the ticker but the mapper is kept: an
    // ordinary pause keeps the neutral this round was calibrated with, and a
    // resume carries on from it.
    _detachMotion();
    _ticker.stop();
    setState(() {
      _phase = _PlayPhase.paused;
      // The frame on screen is the one the round is frozen on. Anything the
      // decoder is still working on belongs to the running round and must not
      // replace it, even if Resume arrives before that decode lands.
      _localGeneration++;
      _releaseAllInput();
    });
  }

  /// Continue the retained local round. Held sources are released and
  /// `_lastTime` is cleared, so a key pressed while paused cannot leak into
  /// the round and the time spent paused is not simulated as elapsed time.
  void _resumeLocalGame() {
    if (_isControllerMode || _phase != _PlayPhase.paused) return;
    // A round whose frames cannot be drawn is not a round to continue: the
    // way out of it is the failure view's Return to setup, Restart, or
    // Choose game.
    if (_playError != null) return;
    setState(() {
      _phase = _PlayPhase.playing;
      _releaseAllInput();
      _lastTime = Duration.zero;
    });
    if (_inputMode == _InputMode.motion) _attachMotion();
    if (!_ticker.isActive) unawaited(_ticker.start());
    _gameplayFocus.requestFocus();
  }

  /// Discard the local round: the engine and its last frame are destroyed, so
  /// the next Start opens a fresh session rather than resuming this one, and
  /// the setup view is back.
  void _stopGame() {
    _disposeLocalSession();
    _discardMotion();
    setState(() => _phase = _PlayPhase.idle);
  }

  // -------------------------------------------------- local frame lifecycle
  //
  // The rules this section keeps, in one place: exactly one decode is in
  // flight; the panel shows the newest frame the engine has, not the newest
  // one the decoder finished; a frame belongs to the session that produced it
  // and is dropped - image and all - when that session is gone; and a round
  // that cannot be drawn says so instead of going blank.

  /// Whether the newest frame the engine renders is one the screen wants: a
  /// live round, or a finished one whose final panel stays on screen. A paused
  /// round keeps the frame it was frozen on, so nothing is wanted for it.
  bool get _wantsLocalFrame =>
      _phase == _PlayPhase.playing || _phase == _PlayPhase.over;

  /// Destroy the local session: its engine, its frame, the sources that held
  /// its controls, and any decode still in flight for it. The phase is the
  /// caller's, since stopping the round returns to setup while a mirror taking
  /// over has its own screen to show.
  ///
  /// The generation bump is what makes a late decode harmless: it carries the
  /// generation it began in and finds it stale, so the image it produced is
  /// disposed instead of drawn into whatever is on screen by then.
  void _disposeLocalSession() {
    _sendLocalRelease();
    _detachMotion();
    _ticker.stop();
    // The sources go too: a held pad pointer or a pending semantic activation
    // must not outlive the round it was holding.
    _releaseAllInput();
    _localGeneration++;
    _decodePending = false;
    final engine = _engine;
    final image = _image;
    // Cleared before disposing, so nothing that runs between the two - a
    // decode completion, a queued callback - can reach a dead session.
    _engine = null;
    _image = null;
    _frame = null;
    _localGame = null;
    _localControls = const <GameControl>[];
    _held = const <int>[];
    _playError = null;
    _lastTime = Duration.zero;
    _ticks = 0;
    engine?.dispose();
    image?.dispose();
  }

  /// Render the round's current pixels and decode them into the panel image.
  /// Does nothing while a decode is already in flight beyond remembering that
  /// a frame is wanted: the slot is freed by rendering the state the engine is
  /// in *then*, so a round that outruns the decoder catches up to its newest
  /// frame instead of replaying stale copies nobody saw.
  void _requestLocalFrame(GameEngine engine) {
    if (_decodeBusy) {
      _decodePending = true;
      return;
    }
    _decodePending = false;
    final Uint8List? bytes;
    try {
      bytes = engine.renderBytes();
    } on StateError {
      _failLocalRound('the game could not be rendered');
      return;
    }
    if (bytes == null) {
      _failLocalRound('the game could not be rendered');
      return;
    }
    _decodeBusy = true;
    final generation = _localGeneration;
    final terminal = _phase == _PlayPhase.over;
    final Future<ui.Image?> decoded;
    try {
      decoded = _decodeFrame(engine, bytes);
    } catch (error) {
      // A decoder that refuses the frame outright rather than returning a
      // failed future: the slot must not stay busy for a decode that never
      // started.
      _decodeBusy = false;
      _failLocalRound('the frame could not be decoded: $error');
      return;
    }
    decoded.then<void>((ui.Image? img) {
      _decodeBusy = false;
      if (!mounted ||
          generation != _localGeneration ||
          !identical(_engine, engine) ||
          !_wantsLocalFrame) {
        // A frame for a round that is gone - replaced, paused, stopped, or a
        // disposed route: never let it flash into the round on screen.
        img?.dispose();
      } else if (img == null) {
        _failLocalRound('the frame could not be decoded');
      } else {
        setState(() {
          _frame = bytes;
          _image?.dispose();
          _image = img;
        });
        if (terminal) _ticker.stop();
      }
      _drainPendingLocalFrame();
    }, onError: (Object error) {
      _decodeBusy = false;
      if (mounted && generation == _localGeneration) {
        _failLocalRound('the frame could not be decoded: $error');
      }
      _drainPendingLocalFrame();
    });
  }

  /// The slot is free again. A frame was wanted while it was busy: render and
  /// decode the state the engine is in now, which is the one the player should
  /// be looking at.
  void _drainPendingLocalFrame() {
    if (!_decodePending || !mounted) return;
    final engine = _engine;
    if (engine == null || _playError != null || !_wantsLocalFrame) {
      // The round this frame belonged to is gone, is frozen on the frame it
      // was paused on, or has already said it cannot draw one.
      _decodePending = false;
      return;
    }
    _requestLocalFrame(engine);
  }

  /// Decode one rendered frame. The default is the engine's own decoder, which
  /// keeps the app on the exact pixels the native game rendered; a regression
  /// can substitute a decoder it holds open to exercise the stale-frame rules
  /// against the real simulation.
  Future<ui.Image?> _decodeFrame(GameEngine engine, Uint8List bytes) =>
      widget.decodeFrame?.call(engine, bytes) ?? engine.decodeImage(bytes);

  /// The local round cannot go on: the engine would not render a frame, the
  /// decoder returned nothing, or a step failed. Stop feeding it, freeze where
  /// it stands, and put the reason on screen with the one action that still
  /// works - back to setup. A broken round is never a blank panel, and a
  /// resume that would only break again is not offered.
  void _failLocalRound(String reason) {
    if (!mounted) return;
    _ticker.stop();
    if (_playError != null) return;
    _sendLocalRelease();
    setState(() {
      _playError = reason;
      // A live round is frozen where it stands. A finished one stays finished:
      // its phase is what says whether Restart still has progress to ask about.
      if (_phase == _PlayPhase.playing) _phase = _PlayPhase.paused;
      // Whatever the decoder is still working on belongs to the frame that
      // failed; it is not the frame this round should show.
      _localGeneration++;
      _releaseAllInput();
    });
  }

  /// Drop every held control of the round on screen without touching the
  /// round itself: the sources that held them, the axis values, and the
  /// pointers steering the movement pad. The local engine reads the rebuilt
  /// zero list on its next frame; callers that need the mirror told about the
  /// release send the zero packet themselves.
  void _releaseAllInput() {
    _cancelSemanticHolds();
    _sources.clear();
    _axes.clear();
    _padPointers.clear();
    _deadPointers.clear();
    // Through the ordinary resolution, so an axis slot ends up idle rather
    // than at zero: zero is the middle of an axis's travel, and a still phone
    // must not recentre the player.
    _recomputeHeld();
  }

  // ------------------------------------------------------------ input edges

  /// Hold control [index] for [source] and dispatch the state that results.
  /// A source that already holds the control is not a new press, and a round
  /// that is not live takes no input at all.
  ///
  /// A *second* source landing on Invaders' Shoot while another still holds it
  /// is a press of its own, and the wire only carries held state: sending the
  /// level again would look like more of the same hold. So that one case sends
  /// an explicit Shoot-low frame and then the held state that follows it,
  /// which is what the firmware reads as a press. Nothing about the sources,
  /// the axes or the held state is changed to do it.
  void _pressControl(int index, _InputSource source) {
    if (_phase != _PlayPhase.playing) return;
    if (index < 0 || index >= _held.length) return;
    final owners = _sources.putIfAbsent(index, () => <Object>{});
    final wasHeld = owners.isNotEmpty;
    if (!owners.add(source)) return;
    if (wasHeld &&
        _runningGameId == 'invaders' &&
        index == _controlIndexForLabel('Shoot')) {
      _dispatchInput(releasedControl: index);
      _dispatchInput();
      return;
    }
    _applyInput();
  }

  /// Release [source] from control [index]. A source that does not hold it
  /// changes nothing, so releasing one of two sources holding the same
  /// control leaves it held.
  void _releaseControl(int index, _InputSource source) {
    final owners = _sources[index];
    if (owners == null || !owners.remove(source)) return;
    if (owners.isEmpty) _sources.remove(index);
    _applyInput();
  }

  /// Rebuild the held state from its sources and send it on when anything
  /// changed. Every edge goes through here, so a press and a release that fit
  /// inside one frame still reach the round.
  void _applyInput() {
    final before = List<int>.of(_held);
    _recomputeHeld();
    var changed = false;
    for (var i = 0; i < _held.length; i++) {
      if (_held[i] != before[i]) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    if (mounted) setState(() {});
    _dispatchInput();
  }

  /// The resolved state: every button from its sources, every axis from its
  /// raw value. A button nobody holds is 0 (released) and an axis nobody
  /// drives is [MotionControl.idle] — never 0, which would be the middle of
  /// the axis's travel and would recentre a tilted player's paddle.
  void _recomputeHeld() {
    for (var i = 0; i < _held.length; i++) {
      _held[i] = _isAxisAt(i) ? MotionControl.idle : 0;
    }
    _sources.forEach((index, owners) {
      if (index < _held.length && owners.isNotEmpty) _held[index] = 1;
    });
    _axes.forEach((index, value) {
      if (index < _held.length) _held[index] = value;
    });
    _neutralizeOpposites('Up', 'Down');
    _neutralizeOpposites('Left', 'Right');
  }

  /// Whether control [index] of the round on screen is an axis. The declared
  /// type decides, on both paths: the mirror states it per control in its
  /// start reply, and the local catalogue carries it from the engine.
  bool _isAxisAt(int index) {
    if (_isControllerMode) {
      final game = _mirrorGame;
      if (game == null || index >= game.controls.length) return false;
      return game.controls[index].isAxis;
    }
    if (index >= _localControls.length) return false;
    return _localControls[index].isAxis;
  }

  /// Two opposing directions held at once resolve to neutral for that axis: a
  /// round must never receive whichever one happens to sit last in the list.
  void _neutralizeOpposites(String a, String b) {
    final first = _controlIndexForLabel(a);
    final second = _controlIndexForLabel(b);
    if (first == null || second == null) return;
    if (first >= _held.length || second >= _held.length) return;
    if (_held[first] != 0 && _held[second] != 0) {
      _held[first] = 0;
      _held[second] = 0;
    }
  }

  /// Hand the current held state to whichever round is on screen, now.
  /// [releasedControl] sends one control as up for this single frame while
  /// everything else keeps its held value: the press edge a second finger on
  /// Invaders' Shoot needs (see [_pressControl]).
  void _dispatchInput({int? releasedControl}) {
    if (_phase != _PlayPhase.playing) return;
    if (_isControllerMode) {
      _sendMirrorInput(releasedControl: releasedControl);
    } else {
      _sendLocalInput(releasedControl: releasedControl);
    }
  }

  /// Feed the local engine the full held state right now. Every pad and key
  /// edge calls this, so a short tap is not sampled away by the ticker; the
  /// ticker calls it each frame as held-state recovery and to keep a held
  /// direction moving. The values go through as they are: the native side
  /// resolves each control's declared type, so a button arrives as a level and
  /// an axis keeps its whole range (see GameEngine.input).
  void _sendLocalInput({int? releasedControl}) {
    final engine = _engine;
    if (engine == null || _phase != _PlayPhase.playing) return;
    for (var i = 0; i < _held.length; i++) {
      engine.input(
        playerId: 1,
        code: i,
        value: i == releasedControl ? 0 : _held[i],
      );
    }
  }

  /// Tell the local engine that every declared control is up. Clearing the
  /// Dart sources alone would leave the native controller holding whatever was
  /// down when the round stopped being fed, so this is what actually releases
  /// a held direction before the round is paused or thrown away.
  void _sendLocalRelease() {
    final engine = _engine;
    if (engine == null) return;
    try {
      for (var i = 0; i < _held.length; i++) {
        engine.input(
          playerId: 1,
          code: i,
          value: _isAxisAt(i) ? MotionControl.idle : 0,
        );
      }
    } on StateError {
      // The engine is already gone: there is nothing left to release.
    }
  }

  /// One pointer is gone: release the direction it was steering and any
  /// control it held, whichever pad that was.
  void _releasePointer(int pointer) {
    final source = _PointerSource(pointer);
    final steered = _padPointers.remove(pointer);
    _deadPointers.remove(pointer);
    final held = <int>[];
    _sources.forEach((index, owners) {
      if (owners.contains(source)) held.add(index);
    });
    if (steered == null && held.isEmpty) return;
    if (steered != null) _releaseControl(steered, source);
    for (final index in held) {
      _releaseControl(index, source);
    }
  }

  /// The movement pad's single pointer surface: [index] is the direction
  /// button under the pointer, or null over the gaps and outside the pad.
  /// Sliding changes direction; nothing under the finger means neutral, and
  /// the control the pointer left is released.
  void _trackPadPointer(int pointer, int? index) {
    final source = _PointerSource(pointer);
    final previous = _padPointers[pointer];
    if (previous == index) return;
    if (previous != null) _releaseControl(previous, source);
    if (index == null) {
      _padPointers.remove(pointer);
      return;
    }
    _padPointers[pointer] = index;
    _pressControl(index, source);
  }

  /// A press on an action button. A pointer that already left its rectangle
  /// cannot press it again.
  void _pressAction(int pointer, int index) {
    if (_deadPointers.contains(pointer)) return;
    _pressControl(index, _PointerSource(pointer));
  }

  /// An action button's pointer moved. Leaving the rectangle releases the
  /// button and kills the pointer's press: the button is not re-armed by
  /// sliding back into it. Invaders in motion mode is the exception - its
  /// Shoot target is the whole play area, so there is no rectangle to leave.
  void _moveAction(int pointer, int index, bool inside) {
    if (_deadPointers.contains(pointer)) return;
    if (inside) return;
    if (_runningGameId == 'invaders' &&
        _inputMode == _InputMode.motion &&
        index == _controlIndexForLabel('Shoot')) {
      return;
    }
    _deadPointers.add(pointer);
    _releaseControl(index, _PointerSource(pointer));
  }

  /// A press anywhere on the motion play area. Invaders in motion mode takes
  /// its Shoot from the whole board, so a thumb that has to find one small
  /// button does not have to: the surface is the control. The pointer is the
  /// same source the Shoot pad would use, so a press that lands on both is one
  /// press and not two.
  void _pressMotionSurface(PointerDownEvent event) {
    if (_phase != _PlayPhase.playing) return;
    if (_inputMode != _InputMode.motion) return;
    if (_runningGameId != 'invaders') return;
    final shoot = _controlIndexForLabel('Shoot');
    if (shoot == null) return;
    _pressControl(shoot, _PointerSource(event.pointer));
  }

  /// Activate a pad the way an accessibility action does: one discrete press
  /// and one release, through the same edge path a finger uses. A movement
  /// direction is held for 50 ms so it spans at least one 25 ms game tick - a
  /// press and release inside one frame would not move such a game at all.
  void _activatePad(_PadSpec spec) {
    final source = _SemanticSource(spec.index);
    _pressControl(spec.index, source);
    if (!spec.isDirection) {
      _releaseControl(spec.index, source);
      return;
    }
    _semanticHold[spec.index]?.cancel();
    _semanticHold[spec.index] = Timer(const Duration(milliseconds: 50), () {
      _semanticHold.remove(spec.index);
      if (!mounted) return;
      _releaseControl(spec.index, source);
    });
  }

  /// Cancel the holds behind in-flight accessibility activations. Called
  /// whenever the round's inputs are dropped, so no source outlives it.
  void _cancelSemanticHolds() {
    for (final timer in _semanticHold.values) {
      timer.cancel();
    }
    _semanticHold.clear();
  }

  /// True while [session] is still the live link, [generation] is still the
  /// newest mirror operation, and the route is still mounted. Every async
  /// boundary inside a mirror transition re-checks this before touching
  /// state, so a superseded reply is dropped instead of reviving a dead
  /// session.
  bool _opStillValid(BleSession session, int generation) =>
      mounted &&
      generation == _opGeneration &&
      identical(_connection.session, session);

  /// The check an await that is not part of a numbered operation - closing the
  /// diagnostics sheet, establishing tilt neutral - makes before it touches
  /// state: the link is still the same one and the route is still mounted.
  bool _opStillValidSession(BleSession? session) =>
      mounted && identical(_connection.session, session);

  /// Release every held control, tell the mirror so, and stop the sources
  /// that would keep the round alive. Used before every transition, before
  /// the input mode changes, and on the way out of the route.
  void _releaseMirrorInput() {
    _releaseAllInput();
    _lastMirrorSendMs = 0;
    _stopMirrorSources();
    _sendReleasePacket();
  }

  /// Tell the mirror that every control is released, without touching the
  /// round's own sources. The packet is a full-state list sized to the running
  /// game's control count: an *empty* packet is not a release, and a short one
  /// would leave the device holding whatever the missing controls last
  /// carried. A button is released to 0; an axis is released to idle, because
  /// 0 is the middle of its travel and would recentre the player's paddle.
  void _sendReleasePacket() {
    final session = _connection.session;
    final game = _mirrorGame;
    if (session == null || game == null) return;
    unawaited(session.sendGameInput(<int>[
      for (var i = 0; i < game.controls.length; i++)
        game.controls[i].isAxis ? MotionControl.idle : 0,
    ]));
  }

  /// Stop the sources that drive a mirror round without touching the round
  /// itself: the frame heartbeat and the motion sensor subscription. A paused
  /// round keeps neither running, and the calibrated tilt mapper is kept for
  /// the resume. The latency poll is not one of these: it belongs to the open
  /// Display & diagnostics sheet, not to the round.
  void _stopMirrorSources() {
    _detachMotion();
    _ticker.stop();
  }

  /// Start the sources that keep a live mirror round alive. Only called once
  /// a round is acknowledged as playing: a paused round has no heartbeat and
  /// no sensor subscription. The tilt mapper re-attached here is the one this
  /// round was calibrated with, never a silent replacement; latency belongs to
  /// the Display & diagnostics sheet and is not polled for a plain round.
  void _startMirrorSources() {
    if (_phase != _PlayPhase.playing) return;
    if (_inputMode == _InputMode.motion) _attachMotion();
    if (!_ticker.isActive) unawaited(_ticker.start());
  }

  /// Drop everything this screen tracks about the mirror's round: the game id
  /// and controls, the pending transition flags, the status subscription, the
  /// tilt mapper, the diagnostic numbers, the input sources, and the phase.
  /// The link itself is left alone, so a replacement session can be adopted
  /// right after, and the open diagnostics sheet is not closed here - it
  /// simply stops having numbers to show.
  void _clearMirrorPlay() {
    final owned = _mirrorGameId != null || _mirrorGame != null;
    // Release while the game is still known: the zero packet is sized from
    // its controls.
    _releaseMirrorInput();
    _mirrorGameId = null;
    _mirrorGame = null;
    _pendingPaused = false;
    _pendingOver = false;
    _pendingInterruption = false;
    _pendingInterruptionAutomatic = true;
    _gameOverSub?.cancel();
    _gameOverSub = null;
    // The diagnostics poll is not stopped here: it belongs to the open
    // Display & diagnostics sheet, and this only forgets the numbers.
    // The round's tilt mapper and its calibration end with the round, though:
    // the next motion round calibrates again instead of inheriting this one's
    // neutral.
    _discardMotion();
    _latency = null;
    _roundTripMs = 0;
    _ticks = 0;
    if (owned) _phase = _PlayPhase.idle;
  }

  /// The remote state is unknown (a timeout, a malformed reply, or a dead
  /// link): release input, drop the round, and take the link down so the
  /// player reconnects deliberately instead of driving a game that may not be
  /// there.
  Future<void> _loseConnection() async {
    _opGeneration++;
    if (mounted) {
      setState(() {
        _clearMirrorPlay();
        _mirrorLoading = false;
        _mirrorListError = null;
      });
    }
    _showMessage('Game connection lost. Reconnect to play again.',
        dismissible: true);
    await _connection.disconnect();
  }

  void _showMessage(String message, {bool dismissible = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(seconds: dismissible ? 8 : 4),
        action: dismissible
            ? SnackBarAction(
                label: 'Dismiss',
                onPressed: () => messenger.hideCurrentSnackBar(),
              )
            : null,
      ),
    );
  }

  /// The connection changed (connected, disconnected, failed). Keeps the
  /// controller-mode state in sync with the link.
  ///
  /// Everything here is keyed on the session identity changing: a rename or
  /// any other notification on the same link must not throw away a loaded
  /// catalogue or a running round.
  void _onConnectionChanged() {
    if (!mounted) return;
    final session = _connection.session;
    if (identical(session, _seenSession)) return;
    _seenSession = session;
    // A new link (or none) supersedes every transition still in flight.
    _opGeneration++;

    if (session != null) {
      // Fresh link: reload the catalogue, or show the old-firmware view when
      // the gamepad channel itself is missing. A round from the previous link
      // cannot survive the replacement.
      final unsupported = session.gameIn == null;
      final stale = _mirrorGameId != null || _mirrorGame != null;
      // This screen is the mirror's gamepad from here on, so a local preview
      // cannot stay behind it: an engine nobody can see or steer would keep
      // stepping at every frame. It is destroyed, its decode invalidated, and
      // the setup view - this time the mirror's - is what shows.
      final local = _localRound || _engine != null;
      setState(() {
        _mirrorUnsupported = unsupported;
        _mirrorGameIds = null;
        _mirrorLoading = false;
        _mirrorListError = null;
        _mirrorSelected = null;
        if (stale) _clearMirrorPlay();
        if (local) {
          _disposeLocalSession();
          _phase = _PlayPhase.idle;
        }
      });
      if (stale) {
        _showMessage('Mirror disconnected; the game ended.', dismissible: true);
      }
      if (!unsupported) unawaited(_loadMirrorGames());
      return;
    }

    // The link is gone. The firmware stops its game on disconnect, so this is
    // local cleanup; a round this screen was driving ended with the link, and
    // the local preview starts from setup rather than from a phase the mirror
    // left behind.
    final ended = _mirrorGameId != null || _mirrorGame != null;
    setState(() {
      _mirrorUnsupported = false;
      _mirrorGameIds = null;
      _mirrorLoading = false;
      _mirrorListError = null;
      _mirrorSelected = null;
      if (ended) {
        _clearMirrorPlay();
      } else if (_engine == null && _phase != _PlayPhase.idle) {
        // Nothing local is on screen behind the link that went away, so idle
        // is where the round state starts again.
        _phase = _PlayPhase.idle;
      }
    });
    if (ended) {
      // Never fall through to local setup without saying why.
      _showMessage('Mirror disconnected; the game ended.', dismissible: true);
    }
  }

  /// The app left the foreground (or came back). Leaving pauses the round:
  /// a phone in a pocket must not keep a game running, and on firmware that
  /// cannot pause the round is stopped instead of left unattended. Coming
  /// back deliberately does *not* resume - the player asks for that.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // A phone that was put down has no meaningful neutral any more, and a
        // sensor that was suspended mid-calibration will not deliver the
        // samples it promised: the mapper is dropped, so the next Resume
        // establishes neutral again before it moves anything.
        if (_inputMode == _InputMode.motion &&
            (_motion != null || _motionSub != null)) {
          setState(_discardMotion);
        }
        _interrupt(automatic: true);
      case AppLifecycleState.resumed:
        break;
    }
  }

  /// The play surface stopped being the focus path for keyboard input.
  ///
  /// The check is deliberately subtree-aware (_gameplayFocus.hasFocus, not
  /// hasPrimaryFocus): moving between the controls inside the play surface is
  /// still playing, while a dialog, another route, or an unfocused window is
  /// the player leaving. It is deferred by a microtask so a focus change
  /// delivered mid-build cannot mutate state, and re-checked so a focus that
  /// bounced straight back does not pause anything.
  void _onGameplayFocusChange(bool hasFocus) {
    if (hasFocus) return;
    scheduleMicrotask(() {
      if (!mounted || _gameplayFocus.hasFocus) return;
      // A screen-owned modal (Help, Display & diagnostics, the discard
      // question) takes the focus away on purpose, and the code that opened it
      // already paused the round with the intent it wanted.
      if (_modalDepth > 0) return;
      _interrupt(automatic: true);
    });
  }

  /// The round is no longer being watched or driven: pause it.
  ///
  /// [automatic] marks an interruption the player did not ask for (the app
  /// leaving the foreground, lost gameplay focus, or running out of room).
  /// Firmware that refuses a pause is then stopped rather than left running,
  /// while a pause the player asked for just reports the refusal and keeps
  /// playing.
  ///
  /// Repeated interruptions are free: each phase below is handled once, so
  /// losing focus while a pause is already in flight starts nothing new.
  void _interrupt({required bool automatic}) {
    if (!mounted) return;
    if (!_isControllerMode) {
      if (_phase == _PlayPhase.playing) _pauseLocalGame();
      return;
    }
    switch (_phase) {
      case _PlayPhase.playing:
        unawaited(_pauseMirrorGame(automatic: automatic));
      case _PlayPhase.starting:
      case _PlayPhase.resuming:
        // The transition is on its way to `playing`: pause the moment it
        // lands instead of letting the round run for even one frame.
        _pendingInterruption = true;
        _pendingInterruptionAutomatic = automatic;
      case _PlayPhase.idle:
      case _PlayPhase.pausing:
      case _PlayPhase.paused:
      case _PlayPhase.stopping:
      case _PlayPhase.over:
        // Not running, already frozen, or already being frozen.
        break;
    }
  }

  /// A sheet interrupts play. Wait for a real pause before covering controls;
  /// old firmware stops instead, so no modal pretends to preserve its round.
  Future<bool> _pauseForModal() async {
    if (_mirrorBusy || _motionBusy) return false;
    if (_phase != _PlayPhase.playing) return mounted;
    final session = _connection.session;
    if (session == null) {
      _pauseLocalGame();
      return true;
    }
    final generation = _opGeneration + 1;
    await _pauseMirrorGame(automatic: true);
    return _opStillValid(session, generation) &&
        (_phase == _PlayPhase.paused || _phase == _PlayPhase.over);
  }

  /// Open one of this screen's own modals around [open]. While it is up the
  /// gameplay focus is expected to leave the play surface, so the automatic
  /// interruption stands down and the caller's own pause decision is what
  /// applies. Keyboard control comes back to the play surface afterwards.
  Future<T?> _showModal<T>(Future<T?> Function() open) async {
    _modalDepth++;
    try {
      return await open();
    } finally {
      _modalDepth--;
      _reclaimGameplayFocus();
    }
  }

  /// The overflow menu took the gameplay focus. It is a modal like the sheets,
  /// so the focus move is not an interruption in itself.
  void _onMenuOpened() => _modalDepth++;

  /// The overflow menu closed, with or without a selection. Keyboard control
  /// goes back to the play surface, and the next focus move is an interruption
  /// again.
  void _onMenuClosed() {
    if (_modalDepth > 0) _modalDepth--;
    _reclaimGameplayFocus();
  }

  /// Whether a round exists that throwing away would end: a local preview, or
  /// the mirror's round. A round that already finished has nothing to discard.
  bool get _roundInProgress {
    if (_phase == _PlayPhase.over) return false;
    if (_isControllerMode) {
      return _mirrorGame != null || _mirrorGameId != null;
    }
    return _localRound;
  }

  /// Return the acknowledged operation generation after confirmation, or null.
  /// Callers must still own that generation before discarding the round.
  Future<int?> _confirmDiscard() async {
    if (_modalDepth > 0) return null;
    if (!_roundInProgress) return _opGeneration;
    if (!await _pauseForModal()) return null;
    if (!mounted) return null;
    final generation = _opGeneration;
    final session = _connection.session;
    final discard = await _showModal<bool>(
      () => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey<String>('discard-round-dialog'),
          title: const Text('Discard round?'),
          content: const Text(
            'The round on screen is thrown away and cannot be resumed.',
          ),
          actions: <Widget>[
            TextButton(
              key: const ValueKey<String>('discard-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey<String>('discard-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Discard'),
            ),
          ],
        ),
      ),
    );
    if (!_opStillValidSession(session) || generation != _opGeneration) {
      return null;
    }
    return discard == true ? generation : null;
  }

  /// Start the round on screen over: Restart while a round exists, Play again
  /// once it is terminal. Both ask first when there is progress to lose.
  Future<void> _restartRound() async {
    if (_mirrorBusy) return;
    final generation = await _confirmDiscard();
    if (!mounted || generation == null || generation != _opGeneration) return;
    if (_isControllerMode) {
      await _restartMirrorGame();
      return;
    }
    await _replayOrStartLocal();
  }

  /// Leave the round for the picker. The round is discarded first - asked for
  /// once when it is not terminal - so the setup view never appears over a
  /// session that is still running.
  Future<void> _chooseGame() async {
    if (_mirrorBusy) return;
    final generation = await _confirmDiscard();
    if (!mounted || generation == null || generation != _opGeneration) return;
    if (_isControllerMode) {
      await _stopMirrorGame();
      return;
    }
    _stopGame();
  }

  /// Continue the round that is on screen.
  void _resumeRound() {
    if (_isControllerMode) {
      unawaited(_resumeMirrorGame());
    } else {
      _resumeLocalGame();
    }
  }

  /// The actions of the round on screen: while it is live, the ways to
  /// continue it, start it over, or leave it; once it finished, the ways to
  /// play it again or choose another. Never a Stop: choosing a game is the
  /// way out, and it asks before it discards anything.
  Widget _buildRoundActions({required bool terminal}) {
    if (terminal) {
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        alignment: WrapAlignment.center,
        children: <Widget>[
          FilledButton.icon(
            key: const ValueKey<String>('over-play-again'),
            onPressed: _mirrorBusy ? null : _restartRound,
            icon: const Icon(Icons.replay),
            label: const Text('Play again'),
          ),
          OutlinedButton.icon(
            key: const ValueKey<String>('over-choose'),
            onPressed: _mirrorBusy ? null : _chooseGame,
            icon: const Icon(Icons.sports_esports),
            label: const Text('Choose game'),
          ),
        ],
      );
    }
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: <Widget>[
        FilledButton.icon(
          key: const ValueKey<String>('round-resume'),
          onPressed: _canTogglePause ? _resumeRound : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Resume'),
        ),
        OutlinedButton.icon(
          key: const ValueKey<String>('round-restart'),
          onPressed: _mirrorBusy ? null : _restartRound,
          icon: const Icon(Icons.replay),
          label: const Text('Restart'),
        ),
        OutlinedButton.icon(
          key: const ValueKey<String>('round-choose'),
          onPressed: _mirrorBusy ? null : _chooseGame,
          icon: const Icon(Icons.sports_esports),
          label: const Text('Choose game'),
        ),
      ],
    );
  }

  /// Pause or resume whichever round is on screen. One key-down (or one tap)
  /// is one toggle.
  void _togglePause() {
    if (_isControllerMode) {
      switch (_phase) {
        case _PlayPhase.playing:
          unawaited(_pauseMirrorGame(automatic: false));
        case _PlayPhase.paused:
          unawaited(_resumeMirrorGame());
        case _PlayPhase.idle:
        case _PlayPhase.starting:
        case _PlayPhase.pausing:
        case _PlayPhase.resuming:
        case _PlayPhase.stopping:
        case _PlayPhase.over:
          break;
      }
      return;
    }
    if (_phase == _PlayPhase.playing) {
      _pauseLocalGame();
    } else if (_phase == _PlayPhase.paused) {
      _resumeLocalGame();
    }
  }

  /// Whether the round on screen is frozen and could be resumed. A round that
  /// broke - a frame the engine or the decoder would not produce - is not one
  /// of them: the failure view's way out is Return to setup.
  bool get _canTogglePause =>
      !_mirrorBusy &&
      _playError == null &&
      (_phase == _PlayPhase.playing || _phase == _PlayPhase.paused);

  /// Change how the mirror round is controlled. The current source is released
  /// first. Switching a paused round to motion establishes neutral but never
  /// resumes it; manual selection also cancels a pending calibration.
  Future<void> _setInputMode(_InputMode mode) async {
    if (_inputMode == mode || _mirrorBusy) return;
    if (_phase != _PlayPhase.idle && _phase != _PlayPhase.paused) return;
    // Release whatever the round on screen is holding, on whichever path it
    // runs: a direction the pads were holding must not stay held across a
    // change of how the round is steered.
    if (_isControllerMode) {
      _releaseMirrorInput();
    } else {
      _sendLocalRelease();
      _releaseAllInput();
    }
    if (mode == _InputMode.manual) _discardMotion();
    setState(() => _inputMode = mode);
    if (mode == _InputMode.motion && _phase == _PlayPhase.paused) {
      await _calibrateMotion();
    }
  }

  /// Fetch the mirror's game list. A null reply (old firmware answering
  /// "unknown command") means the mirror has no games to list; a bare `games`
  /// is an empty catalogue. Every failure keeps the link: a named device
  /// error is shown as the device's reason, and a reply that never arrived is
  /// a retryable catalogue error. Listing is deliberately not in the
  /// disconnect rule the start/stop transitions follow, so one slow answer
  /// does not cost the player a reconnect.
  Future<void> _loadMirrorGames({bool force = false}) async {
    final session = _connection.session;
    if (session == null || _mirrorLoading) return;
    if (!force && _mirrorGameIds != null) return;
    final generation = ++_opGeneration;
    setState(() {
      _mirrorLoading = true;
      _mirrorListError = null;
    });
    try {
      final ids = await session.listGames();
      if (!_opStillValid(session, generation)) return;
      setState(() {
        _mirrorLoading = false;
        if (ids == null) {
          _mirrorUnsupported = true;
          _mirrorGameIds = null;
        } else {
          _mirrorUnsupported = false;
          _mirrorGameIds = ids;
          // A mirror that no longer lists the selected game (or lists it in
          // another place) falls back to its first one.
          if (_mirrorSelected == null || !ids.contains(_mirrorSelected)) {
            _mirrorSelected = null;
          }
        }
      });
    } on BlePushException catch (e) {
      // The device answered and refused: show its reason and offer a retry.
      if (!_opStillValid(session, generation)) return;
      _setListError(e.message);
    } on TimeoutException {
      if (!_opStillValid(session, generation)) return;
      _setListError('the mirror did not answer');
    } catch (e) {
      // Either the reply was unreadable or the write failed; the mirror's own
      // link listener owns the connection, and the catalogue stays retryable.
      if (!_opStillValid(session, generation)) return;
      _setListError(e is FormatException
          ? 'the mirror sent an unexpected reply'
          : 'the game list could not be requested');
    } finally {
      // A superseded load must not leave the setup view spinning forever.
      if (mounted &&
          _mirrorLoading &&
          identical(_connection.session, session)) {
        setState(() => _mirrorLoading = false);
      }
    }
  }

  /// Record a retryable catalogue failure with [reason] and stop the spinner.
  void _setListError(String reason) {
    setState(() {
      _mirrorLoading = false;
      _mirrorListError = reason;
    });
  }

  /// Watch this session's status lines. Subscribed *before* the start command
  /// is written so a terminal or paused notification that lands while the
  /// start is still awaiting its reply is never missed.
  void _attachStatusListener(BleSession session) {
    _gameOverSub?.cancel();
    _gameOverSub = session.statusLines.listen(_onMirrorStatus);
  }

  /// The mirror pushed a status line. Only a terminal notification for the
  /// round this screen started, or the pause the mirror applies when input
  /// stops arriving, changes the phase.
  void _onMirrorStatus(String line) {
    if (!mounted) return;
    final over = parseGameOver(line);
    if (over != null) {
      // Another game's end, or none of ours: it must not end this round.
      if (over != _mirrorGameId) return;
      _onMirrorTerminal();
      return;
    }
    if (line == 'game paused' && _mirrorGameId != null) {
      _onMirrorPaused();
    }
  }

  void _onMirrorTerminal() {
    if (_phase == _PlayPhase.starting ||
        _phase == _PlayPhase.pausing ||
        _phase == _PlayPhase.resuming) {
      // The round ended while a command was still in flight: `_pendingOver`
      // keeps the command's acknowledgment from reviving it as running or
      // merely paused.
      _pendingOver = true;
      return;
    }
    if (_phase != _PlayPhase.playing && _phase != _PlayPhase.paused) return;
    setState(() {
      _phase = _PlayPhase.over;
      _releaseMirrorInput();
      // A finished round keeps no tilt neutral: playing it again calibrates.
      _discardMotion();
    });
  }

  /// The mirror answered that the round it was asked about is already over.
  /// Nothing else can be done with a terminal session, so show it as ended
  /// rather than as a rejection.
  void _mirrorTerminalFromReply() {
    if (!mounted) return;
    setState(() {
      _phase = _PlayPhase.over;
      _releaseMirrorInput();
      _discardMotion();
    });
  }

  void _onMirrorPaused() {
    if (_phase == _PlayPhase.starting) {
      // The watchdog paused while the start was in flight; `game ok` must
      // leave the round paused, not running.
      _pendingPaused = true;
      return;
    }
    if (_phase != _PlayPhase.playing) return;
    setState(() {
      _phase = _PlayPhase.paused;
      _releaseMirrorInput();
    });
  }

  /// Start [requestedId] on the mirror. The id is captured by the caller (the
  /// terminal screen, Restart, and the diagnostic button all pass the id of
  /// the round they belong to); a fresh Start uses the picker's selection.
  ///
  /// Nothing starts until the diagnostics sheet is closed and, in motion mode,
  /// until neutral has been established: a round nothing can steer is worse
  /// than a refused start.
  Future<void> _startMirrorGame([String? requestedId]) async {
    final session = _connection.session;
    if (session == null || _mirrorBusy) return;
    final id = requestedId ?? _mirrorPlayableSelection;
    if (id == null) return;
    final preparingGeneration = _opGeneration;
    await _closeDiagnostics();
    if (!_opStillValid(session, preparingGeneration) || _mirrorBusy) return;
    if (!await _motionAllowsPlay()) return;
    if (!_opStillValid(session, preparingGeneration) || _mirrorBusy) return;
    final generation = ++_opGeneration;
    _releaseMirrorInput();
    setState(() {
      _phase = _PlayPhase.starting;
      _mirrorGameId = id;
      _mirrorGame = null;
      _pendingOver = false;
      _pendingPaused = false;
      _pendingInterruption = false;
      _pendingInterruptionAutomatic = true;
      // Diagnostics must never inherit the previous session's numbers.
      _latency = null;
      _roundTripMs = 0;
      _ticks = 0;
    });
    _attachStatusListener(session);
    final MirrorGame game;
    try {
      game = await session.startGame(id);
    } on BlePushException catch (e) {
      // A named rejection: the device is alive and the round never started,
      // so the acknowledged state stays as it was.
      if (!_opStillValid(session, generation)) return;
      setState(() {
        _phase = _PlayPhase.idle;
        _mirrorGameId = null;
        _pendingInterruption = false;
        _pendingPaused = false;
        _pendingOver = false;
      });
      _showMessage('Could not start the game: ${e.message}');
      return;
    } on TimeoutException {
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    } on FormatException {
      // A malformed successful reply means the remote state is unknown.
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    } catch (_) {
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    }
    if (!_opStillValid(session, generation)) return;
    final interrupted = _pendingInterruption;
    setState(() {
      _mirrorGame = game;
      // Sources from the round this replaces must not hold anything in the
      // new one: a key that was down when Start was tapped is not a press.
      _releaseAllInput();
      _held = List<int>.filled(game.controls.length, 0);
      _phase = _pendingOver
          ? _PlayPhase.over
          : (_pendingPaused ? _PlayPhase.paused : _PlayPhase.playing);
      _pendingOver = false;
      _pendingPaused = false;
      _pendingInterruption = false;
    });
    // The slots the round declares are resolved from its own controls, so the
    // first frame of a motion round carries idle axes rather than zeroes.
    _recomputeHeld();
    // The mirror only says what a game declares once it has started, so this
    // is the first moment the app can tell whether tilt can steer it. Firmware
    // from before positional motion declares no accelerometer axis: the round
    // is left on the pads with the reason on screen, rather than looking
    // steered while nothing moves.
    if (_inputMode == _InputMode.motion && !_tiltDrivesAxes) {
      _discardMotion();
      setState(() => _inputMode = _InputMode.manual);
      _showMessage("This mirror's firmware does not support tilt control; "
          'update the firmware to play with motion');
    }
    // The round exists now; keys belong to the pad rather than to whatever
    // button started it.
    _gameplayFocus.requestFocus();
    if (_phase != _PlayPhase.playing) {
      // The round is already over or paused: no heartbeat, no motion.
      _releaseMirrorInput();
      return;
    }
    if (interrupted) {
      // The app left the foreground, or the play surface lost focus, while
      // the start was in flight. Pause immediately - without a single frame
      // of unattended play - and with the interruption path's rules.
      unawaited(_pauseMirrorGame(automatic: _pendingInterruptionAutomatic));
      return;
    }
    _startMirrorSources();
  }

  /// Stop the mirror's game. The local round is cleared only once the device
  /// has acknowledged the stop: tapping Stop while the reply is in flight must
  /// not make the screen forget which round it is looking at.
  ///
  /// Returns true when the device acknowledged the stop (the screen is back
  /// at its setup view).
  Future<bool> _stopMirrorGame() async {
    final session = _connection.session;
    if (session == null) {
      if (mounted) setState(_clearMirrorPlay);
      return true;
    }
    if (_mirrorBusy) return false;
    // Nothing to stop: the device answers "game error no game", and the
    // screen must not sit in `stopping` over a round that never existed.
    if (_mirrorGame == null && _mirrorGameId == null) return true;
    final preparingGeneration = _opGeneration;
    await _closeDiagnostics();
    if (!_opStillValid(session, preparingGeneration) || _mirrorBusy) {
      return false;
    }
    final generation = ++_opGeneration;
    final previous = _phase;
    setState(() => _phase = _PlayPhase.stopping);
    _releaseMirrorInput();
    try {
      await session.stopGame();
    } on BlePushException catch (e) {
      // The device answered and refused: keep the last acknowledged state and
      // show why.
      if (!_opStillValid(session, generation)) return false;
      setState(() => _phase = previous);
      _showMessage('Could not stop the game: ${e.message}');
      return false;
    } on TimeoutException {
      if (!_opStillValid(session, generation)) return false;
      await _loseConnection();
      return false;
    } on FormatException {
      if (!_opStillValid(session, generation)) return false;
      await _loseConnection();
      return false;
    } catch (_) {
      if (!_opStillValid(session, generation)) return false;
      await _loseConnection();
      return false;
    }
    if (!_opStillValid(session, generation)) return false;
    setState(_clearMirrorPlay);
    return true;
  }

  /// Pause the mirror's round. The device freezes the simulation where it is;
  /// this screen releases every control and stops its own sources instead of
  /// drawing a paused-looking gamepad over a running game.
  ///
  /// [automatic] marks an interruption the player did not ask for. Firmware
  /// that refuses to pause is then stopped - unattended play is worse than an
  /// ended round - while a pause the player asked for reports the refusal and
  /// keeps playing.
  Future<void> _pauseMirrorGame({required bool automatic}) async {
    final session = _connection.session;
    if (session == null) return;
    if (_phase != _PlayPhase.playing) return;
    final preparingGeneration = _opGeneration;
    await _closeDiagnostics();
    if (!_opStillValid(session, preparingGeneration) ||
        _phase != _PlayPhase.playing) {
      return;
    }
    final generation = ++_opGeneration;
    setState(() => _phase = _PlayPhase.pausing);
    _releaseMirrorInput();
    try {
      await session.pauseGame();
    } on BlePushException catch (e) {
      if (!_opStillValid(session, generation)) return;
      if (e.message == _gameOverReason) {
        // The device says the round is finished; there is nothing to pause.
        _mirrorTerminalFromReply();
        return;
      }
      if (automatic &&
          e.message == 'Update the mirror firmware to use Pause.') {
        await _stopAfterPauseRefusal(session, generation);
        return;
      }
      // A pause the player asked for: the round is still live, so put the
      // heartbeat back with every control released and show the device's
      // reason - `Update the mirror firmware to use Pause.` for firmware that
      // has no pause at all. Nothing here pretends the game is paused.
      if (!_opStillValid(session, generation)) return;
      _restorePlayingAfterRefusal('Could not pause the game: ${e.message}');
      return;
    } on TimeoutException {
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    } on FormatException {
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    } catch (_) {
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    }
    if (!_opStillValid(session, generation)) return;
    if (_pendingOver) {
      // The round ended while the pause was in flight; the acknowledgment
      // must not bring it back as merely paused.
      _pendingOver = false;
      _mirrorTerminalFromReply();
      return;
    }
    setState(() => _phase = _PlayPhase.paused);
  }

  /// Firmware refused to pause an interruption. Stop the round instead: the
  /// player is not there to play it, and the mirror must not keep it running.
  /// Stopping is the acknowledged path, so the screen reports exactly what
  /// happened and returns to setup.
  Future<void> _stopAfterPauseRefusal(
      BleSession session, int generation) async {
    if (!_opStillValid(session, generation)) return;
    setState(() => _phase = _PlayPhase.stopping);
    try {
      await session.stopGame();
    } catch (_) {
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    }
    if (!_opStillValid(session, generation)) return;
    setState(_clearMirrorPlay);
    _showMessage('This firmware cannot pause; the game was stopped.');
  }

  /// A refusal of a pause the player asked for: the round never stopped, so
  /// the heartbeat comes back with every control released, and the reason
  /// stays on screen.
  void _restorePlayingAfterRefusal(String message) {
    setState(() {
      _phase = _PlayPhase.playing;
      _releaseAllInput();
    });
    _startMirrorSources();
    _showMessage(message);
  }

  /// Resume the mirror's round after the device acknowledged the pause. The
  /// sources that were stopped with the pause - the heartbeat and the sensor
  /// subscription - come back only here, so a resume that was never
  /// acknowledged leaves the round untouched and frozen.
  ///
  /// A motion round that has no mapper left - the app was suspended, or the
  /// player switched to motion just now - establishes neutral first, behind
  /// the same "hold the phone still" view the first start uses.
  Future<void> _resumeMirrorGame() async {
    final session = _connection.session;
    if (session == null) return;
    if (_phase != _PlayPhase.paused) return;
    final preparingGeneration = _opGeneration;
    await _closeDiagnostics();
    if (!_opStillValid(session, preparingGeneration) ||
        _phase != _PlayPhase.paused) {
      return;
    }
    if (!await _motionAllowsPlay()) return;
    if (!_opStillValid(session, preparingGeneration) ||
        _phase != _PlayPhase.paused) {
      return;
    }
    final generation = ++_opGeneration;
    setState(() => _phase = _PlayPhase.resuming);
    try {
      await session.resumeGame();
    } on BlePushException catch (e) {
      if (!_opStillValid(session, generation)) return;
      if (e.message == _gameOverReason) {
        // A terminal session cannot be resumed.
        _mirrorTerminalFromReply();
        return;
      }
      // Still paused on the device: keep the frozen view and say why.
      if (!_opStillValid(session, generation)) return;
      setState(() => _phase = _PlayPhase.paused);
      _showMessage('Could not resume the game: ${e.message}');
      return;
    } on TimeoutException {
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    } on FormatException {
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    } catch (_) {
      if (!_opStillValid(session, generation)) return;
      await _loseConnection();
      return;
    }
    if (!_opStillValid(session, generation)) return;
    if (_pendingOver) {
      _pendingOver = false;
      _mirrorTerminalFromReply();
      return;
    }
    final interrupted = _pendingInterruption;
    final interruptedAutomatic = _pendingInterruptionAutomatic;
    setState(() {
      _phase = _PlayPhase.playing;
      _pendingInterruption = false;
      _pendingInterruptionAutomatic = true;
      // Nothing held while paused may leak into the resumed round, and the
      // heartbeat starts a fresh interval.
      _releaseAllInput();
      _lastMirrorSendMs = 0;
      _ticks = 0;
    });
    _gameplayFocus.requestFocus();
    _startMirrorSources();
    if (interrupted) {
      // The player walked away again while the resume was in flight.
      unawaited(_pauseMirrorGame(automatic: interruptedAutomatic));
    }
  }

  /// Stop the mirror's game on the way out of the route. There is nothing
  /// left to report a rejection to, so the outcome is discarded.
  Future<void> _stopMirrorOnLeave(BleSession session) async {
    try {
      await session.stopGame();
    } catch (_) {
      // The route is gone; a rejection or a dead link has nowhere to go.
    }
  }

  /// Start over: one serialized stop-then-start for the round that is on
  /// screen, using the id captured before the stop so a replaced picker
  /// cannot redirect it.
  Future<void> _restartMirrorGame() async {
    final session = _connection.session;
    final id = _mirrorGame?.id ?? _mirrorGameId;
    if (session == null || id == null || _mirrorBusy) return;
    final generation = _opGeneration + 1;
    final stopped = await _stopMirrorGame();
    if (!stopped || !_opStillValid(session, generation)) return;
    // The stop must have been acknowledged on the same link before a new
    // round is opened; otherwise the screen shows what the device last
    // acknowledged.
    if (_phase != _PlayPhase.idle) return;
    if (!identical(_connection.session, session)) return;
    await _startMirrorGame(id);
  }

  /// Whether a round that is about to start may run with the current
  /// controller mode. Motion mode calibrates first: a mapper that never
  /// established neutral - or a sensor that failed - declines the start
  /// instead of starting a round nothing can steer.
  Future<bool> _ensureMotionReady() async {
    if (_inputMode != _InputMode.motion) return true;
    // A local round's controls are known from the catalogue before it starts,
    // so a game that declares no accelerometer axis is caught here rather than
    // started unsteerable. A mirror only reports its controls with the start
    // acknowledgment, which is why that path keeps its own check after the
    // reply.
    if (!_isControllerMode && !_tiltDrivesAxes) {
      _failMotion('This game does not take tilt; use the on-screen pads');
      return false;
    }
    if (_motion?.calibrated ?? false) return true;
    return _calibrateMotion();
  }

  /// Establish neutral for a motion round: build a fresh mapper, subscribe to
  /// the accelerometer, and wait for the player to hold the phone still long
  /// enough for its samples to define "level". Returns false when the player
  /// cancelled or the sensor never reported.
  ///
  /// The sensor is proven to report before any of that. A device without a
  /// working accelerometer cannot establish neutral, and asking its owner to
  /// hold still to discover that is time spent on nothing; the probe is shared
  /// by the screen, so the question is asked once for all of them.
  Future<bool> _calibrateMotion() async {
    if (_motionPhase == _MotionPhase.calibrating) return false;
    if (!await _tilt.present()) {
      if (!mounted) return false;
      _failMotion();
      return false;
    }
    if (!mounted) return false;
    // The await above is the one place another action can land first: a mode
    // change, or a round that went away while the sensor was being asked.
    if (_inputMode != _InputMode.motion) return false;
    _detachMotion();
    _calibrationSamples = 0;
    _motion = MotionControl();
    final request = Completer<bool>();
    _calibration = request;
    setState(() => _motionPhase = _MotionPhase.calibrating);
    _attachMotion();
    _restartCalibrationWatchdog(_motionGeneration);
    _restartStillTimer();
    final session = _connection.session;
    final generation = _opGeneration;
    final motionGeneration = _motionGeneration;
    final ok = await request.future;
    if (!_opStillValidSession(session) ||
        generation != _opGeneration ||
        motionGeneration != _motionGeneration) {
      return false;
    }
    if (identical(_calibration, request)) _calibration = null;
    _calibrationTimer?.cancel();
    _calibrationTimer = null;
    if (_motionPhase == _MotionPhase.calibrating) {
      setState(() => _motionPhase = _MotionPhase.off);
    }
    return ok;
  }

  /// Subscribe the mapper the round is steered by. Idempotent, so a resume
  /// re-attaches the subscription a pause detached without rebuilding the
  /// neutral the round was calibrated with.
  void _attachMotion() {
    final motion = _motion;
    if (motion == null || _motionSub != null) return;
    final generation = ++_motionGeneration;
    _motionSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(
      (event) => _onMotionSample(generation, motion, event),
      onError: (Object _) => _onMotionFailure(generation),
    );
    // The gyroscope is what lets the mapper tell a translation from a tilt: the
    // accelerometer alone reads the hand's acceleration as gravity. A device
    // without one is handled, not refused — see _onGyroFailure.
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(
      (event) => _onGyroSample(generation, motion, event),
      onError: (Object _) => _onGyroFailure(generation),
    );
  }

  /// Stop reading tilt but keep the mapper: a pause detaches the sensor and
  /// the resume carries on with the neutral this round already has.
  void _detachMotion() {
    _motionSub?.cancel();
    _motionSub = null;
    _gyroSub?.cancel();
    _gyroSub = null;
    // Anything already queued belongs to the subscription just dropped.
    _motionGeneration++;
  }

  /// Forget the mapper as well as the subscription: the round ended (or ended
  /// up manual), the app was suspended, or the player asked for a fresh
  /// calibration. The next motion round establishes neutral again.
  void _discardMotion() {
    _detachMotion();
    _motion = null;
    _calibrationTimer?.cancel();
    _calibrationTimer = null;
    _calibrationStillTimer?.cancel();
    _calibrationStillTimer = null;
    // Re-detected from the next round's own subscription: the message
    // (_gyroWarned) is said once, but whether this round has a gyroscope is a
    // question each round asks its own stream.
    _gyroUnavailable = false;
    _motionPhase = _MotionPhase.off;
    _finishCalibration(false);
  }

  /// Complete a pending calibration, if there is one. Cancelling and failing
  /// both report false, so no caller starts a round on a mapper that never
  /// established neutral.
  void _finishCalibration(bool ok) {
    final request = _calibration;
    _calibration = null;
    if (request != null && !request.isCompleted) request.complete(ok);
  }

  /// Restart the "the sensor went quiet" watchdog around a pending
  /// calibration. Two seconds without a sample means neutral is not going to
  /// arrive, and no game may start on a mapper that has none.
  void _restartCalibrationWatchdog(int generation) {
    _calibrationTimer?.cancel();
    _calibrationTimer =
        Timer(const Duration(seconds: 2), () => _onMotionFailure(generation));
  }

  /// Start the "this hold is not becoming still" budget. Unlike the watchdog,
  /// this one is not restarted by samples: it is the time the player gets to
  /// stop moving, and samples arriving is exactly what it is watching.
  void _restartStillTimer() {
    _calibrationStillTimer?.cancel();
    _calibrationStillTimer = Timer(_calibrationStill, _onCalibrationStalled);
  }

  /// The hold never became still enough for neutral to be established. Nothing
  /// is wrong with the sensors — the phone was moving throughout — so the
  /// round is left on motion mode for another attempt rather than pushed to
  /// manual controls.
  void _onCalibrationStalled() {
    if (!mounted || _motionPhase != _MotionPhase.calibrating) return;
    // _discardMotion only mutates: without a rebuild the calibration view would
    // stay on screen with nothing left driving it.
    setState(_discardMotion);
    _showMessage('Could not calibrate: hold the phone still');
  }

  /// One accelerometer sample. While neutral is still pending the sample only
  /// feeds the mapper (and the "hold still" progress); once the round is live
  /// the same values drive it through the ordinary source path.
  void _onMotionSample(
    int generation,
    MotionControl motion,
    AccelerometerEvent event,
  ) {
    if (!mounted || generation != _motionGeneration) return;
    motion.addAccelSample(event.x, event.y, event.z, stamp: event.timestamp);
    if (_motionPhase == _MotionPhase.calibrating) {
      if (!motion.calibrated) {
        // A sample also proves the sensor is reporting: the watchdog restarts.
        // The progress counts only the samples the mapper accepted, so a phone
        // moving through the hold reads as the hold it is: a player who moves
        // cannot be shown 20/20 and then steered from a wrong middle.
        _restartCalibrationWatchdog(generation);
        final int accepted = motion.calibrationProgress;
        if (accepted != _calibrationSamples) {
          setState(() => _calibrationSamples = accepted);
        }
        return;
      }
      _calibrationTimer?.cancel();
      _calibrationTimer = null;
      _calibrationStillTimer?.cancel();
      _calibrationStillTimer = null;
      _calibrationSamples = _calibrationTarget;
      setState(() => _motionPhase = _MotionPhase.off);
      _finishCalibration(true);
      // A missing gyroscope is said now rather than during the hold, where it
      // would be read over a count the player is trying to finish.
      _warnNoGyroscope();
      return;
    }
    // A paused, finished, or superseded round takes no input.
    if (_phase != _PlayPhase.playing) return;
    // The angle the phone is held at is the position the round is driven to.
    // Which axes a round takes is its own declaration, on the mirror and in
    // the local simulation alike: a round that declares no accelerometer axis
    // cannot be steered by tilt, and motion mode is refused before it starts
    // (see _motionUnavailable).
    _setAxis('TiltX', motion.posX);
    _setAxis('TiltY', motion.posY);
  }

  /// One gyroscope sample. It goes to the same mapper, which uses it to carry
  /// the estimate through a movement the accelerometer would read as a tilt;
  /// it is never the reason a round cannot be steered.
  void _onGyroSample(
    int generation,
    MotionControl motion,
    GyroscopeEvent event,
  ) {
    if (!mounted || generation != _motionGeneration) return;
    motion.addGyroSample(event.x, event.y, event.z, stamp: event.timestamp);
    if (_motionPhase == _MotionPhase.calibrating) return;
    if (_phase != _PlayPhase.playing) return;
    // A gyro sample can move the position on its own — that is the point of
    // fusing it — so it drives the axes exactly as an accelerometer sample
    // does. The 20 ms send throttle collapses the two streams into one write.
    _setAxis('TiltX', motion.posX);
    _setAxis('TiltY', motion.posY);
  }

  /// The gyroscope reported that this device has none. That is a degradation,
  /// not a failure: the mapper falls back to the accelerometer alone, the
  /// round runs, and the player is told.
  void _onGyroFailure(int generation) {
    if (!mounted || generation != _motionGeneration) return;
    _motion?.gyroscopeUnavailable();
    if (_gyroUnavailable) return;
    // The caption reads this, so it is a rebuild and not just a flag.
    setState(() => _gyroUnavailable = true);
    if (_motionPhase == _MotionPhase.calibrating) return;
    _warnNoGyroscope();
  }

  /// Say once that tilt is running on the accelerometer alone. Without a gyro
  /// the mapper cannot tell a brisk hand movement from a tilt, and pretending
  /// otherwise would be the silent degradation the motion contract exists to
  /// avoid.
  void _warnNoGyroscope() {
    if (!_gyroUnavailable || _gyroWarned) return;
    _gyroWarned = true;
    _showMessage(
        'No gyroscope on this device: moving the phone will still read as tilt');
  }

  /// The accelerometer failed, or stopped reporting while neutral was still
  /// pending. Guarded by the subscription generation: an error from a
  /// subscription already dropped belongs to the round that was replaced.
  void _onMotionFailure(int generation) {
    if (!mounted || generation != _motionGeneration) return;
    _failMotion();
  }

  /// Give up on tilt for the round on screen: the mapper and its sensor go,
  /// every held control is released, the round is put on the pads, and the
  /// player is told why. [message] names a reason the screen knows better than
  /// "motion is unavailable".
  void _failMotion(
      [String message = 'Motion unavailable; use manual controls']) {
    _discardMotion();
    _releaseAllInput();
    _sendReleasePacket();
    setState(() => _inputMode = _InputMode.manual);
    _showMessage(message);
  }

  /// The player declined to hold the phone still, or reached for the pad
  /// instead: stop reading tilt and leave the round where it was.
  void _cancelCalibration({required bool manual}) {
    _discardMotion();
    setState(() {
      if (manual) _inputMode = _InputMode.manual;
    });
  }

  /// The id of the round the pads and the keyboard are driving: the mirror's
  /// game while the mirror runs it, otherwise the local engine's.
  String? get _runningGameId =>
      _isControllerMode ? _mirrorGame?.id : _localGame?.id;

  /// The controls of the local round on screen, or of the game the picker has
  /// selected while nothing is running: the catalogue states a game's controls
  /// before its session exists, so motion can be refused for a game that
  /// declares no accelerometer axis without opening one.
  Iterable<GameControl> get _localCatalogueControls {
    final round = _localGame;
    if (round != null) return round.controls;
    final playable = _playableGames;
    if (playable.isEmpty || _gameIndex >= playable.length) {
      return const <GameControl>[];
    }
    return playable[_gameIndex].controls;
  }

  /// The tilt axes of the round on screen, by wire label. The mirror's
  /// controls and the local catalogue's are separate types - one comes off the
  /// wire, the other off the FFI - so each is walked as itself.
  Set<String> get _tiltAxes {
    final out = <String>{};
    if (_isControllerMode) {
      for (final control in _mirrorGame?.controls ?? const <MirrorControl>[]) {
        if (control.isAxis && _tiltLabels.contains(control.label)) {
          out.add(control.label);
        }
      }
      return out;
    }
    for (final control in _localCatalogueControls) {
      if (control.isAxis && _tiltLabels.contains(control.label)) {
        out.add(control.label);
      }
    }
    return out;
  }

  /// Whether the round on screen can be steered by tilt at all.
  bool get _tiltDrivesAxes => _tiltAxes.isNotEmpty;

  /// Why motion mode cannot be used for the round on screen, or null when it
  /// can. The device comes first, because a phone whose accelerometer does not
  /// report cannot steer anything, whatever the round declares and whatever the
  /// firmware supports. After that: a mirror running firmware that predates
  /// positional tilt declares no accelerometer axis, and is told so rather than
  /// left silently unsteerable.
  String? get _motionUnavailable {
    if (_tilt.status == false) {
      return 'No tilt sensor on this device: the on-screen pads steer the game.';
    }
    if (_isControllerMode) {
      final game = _mirrorGame;
      if (game == null) return null; // no round yet: setup offers both modes
      if (_tiltDrivesAxes) return null;
      return 'This mirror\'s firmware does not support tilt control. '
          'Update the firmware to play with motion.';
    }
    if (_localCatalogueControls.isEmpty) return null;
    if (_tiltDrivesAxes) return null;
    return 'This game does not take tilt.';
  }

  /// The human name of [wire] in [id], or null when the control is drawn under
  /// its own declared label.
  String? _aliasFor(String? id, String wire) =>
      id == null ? null : _gameCopy[id]?.aliases[wire];

  /// Set one of the round's tilt axes, by wire label, to a position in
  /// -32767..32767 ([MotionControl.idle] when nobody is driving it). The
  /// control's own index is found on whichever path the round runs on, so a
  /// local round and a mirror round are driven by the same code.
  ///
  /// Tilt is sampled far faster than either path needs, so a changed axis is
  /// sent at most once per 20 ms while the readout follows every sample; the
  /// 100 ms heartbeat carries the newest value in between.
  void _setAxis(String label, int value) {
    if (!_tiltLabels.contains(label)) return;
    final index = _indexOfWire(label);
    if (index == null || index >= _held.length) return;
    if (!_isAxisAt(index)) return;
    if (_axes[index] == value) return;
    _axes[index] = value;
    // The resolved state follows every sample; only the *send* is throttled.
    // Leaving this behind the throttle would leave the local ticker's frame
    // and the mirror's next heartbeat carrying a stale position.
    _recomputeHeld();
    if (mounted) setState(() {});
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastAxisSendMs < 20) return;
    _lastAxisSendMs = now;
    _dispatchInput();
  }

  /// The index of the control declared under [label] on the round on screen,
  /// or null when it declares none.
  int? _indexOfWire(String label) {
    if (_isControllerMode) {
      final game = _mirrorGame;
      if (game == null) return null;
      for (var i = 0; i < game.controls.length; i++) {
        if (game.controls[i].label == label) return i;
      }
      return null;
    }
    for (var i = 0; i < _localControls.length; i++) {
      if (_localControls[i].label == label) return i;
    }
    return null;
  }

  /// Send the current full input state to the mirror immediately. Edges call
  /// this on every press/release so a quick tap is never sampled away.
  ///
  /// [releasedControl] sends that one control as up for this single write while
  /// every other control keeps its held value; the held state itself is
  /// untouched, so the next frame carries it again.
  void _sendMirrorInput({int? releasedControl}) {
    final session = _connection.session;
    if (session == null || _mirrorGame == null) return;
    // Only a live round takes input: a paused, finished, or transitioning
    // session must never be moved by a stray held pad.
    if (_phase != _PlayPhase.playing) return;
    final values = releasedControl == null
        ? _held
        : (List<int>.of(_held)..[releasedControl] = 0);
    unawaited(session.sendGameInput(values));
  }

  // ------------------------------------------------- display & diagnostics

  /// Poll the mirror's latency numbers for the open Display & diagnostics
  /// sheet. One request at a time, best effort: a dead link or firmware that
  /// does not answer leaves the readout stale, and the sheet is the only
  /// caller - a plain round never polls.
  Future<void> _refreshLatency() async {
    final session = _connection.session;
    if (session == null) return;
    final generation = _opGeneration;
    try {
      final lat = await session.getLatency();
      if (!_opStillValid(session, generation) || !_diagSheetOpen) return;
      final rtt = await session.measureRoundTrip();
      if (!_opStillValid(session, generation) || !_diagSheetOpen) return;
      _latency = lat;
      _roundTripMs = rtt.inMilliseconds;
      _diagRevision.value++;
    } catch (_) {
      // A dead link or older firmware leaves the optional readout unchanged.
    }
  }

  /// Ask for one diagnostic exchange, unless one is already in flight: the
  /// sheet's numbers must not queue up behind each other.
  void _pollDiagnostics() {
    if (!_diagSheetOpen || _diagPending != null) return;
    final request = _refreshLatency();
    _diagPending = request;
    unawaited(request.whenComplete(() {
      if (identical(_diagPending, request)) _diagPending = null;
    }));
  }

  /// Start polling while the sheet is open. Latency is a diagnostic, not part
  /// of playing: nothing polls it unless the player is looking at it.
  void _startLatencyPoll() {
    _stopLatencyPoll();
    if (!_diagSheetOpen) return;
    _pollDiagnostics();
    _latencyTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollDiagnostics());
  }

  void _stopLatencyPoll() {
    _latencyTimer?.cancel();
    _latencyTimer = null;
  }

  /// Open the Display & diagnostics sheet: the panel size and the display
  /// settings that used to sit on the play surface, plus the round's tick
  /// count and the mirror's latency. The round is paused first, so nothing is
  /// running behind an open sheet.
  Future<void> _openDiagnostics() async {
    if (_diagSheetOpen) return;
    if (!await _pauseForModal() || !mounted) return;
    _diagSheetOpen = true;
    _startLatencyPoll();
    await _showModal<Object?>(
      () => showModalBottomSheet<Object?>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => _buildDiagnosticsSheet(),
      ),
    );
    if (!mounted) return;
    _diagSheetOpen = false;
    _stopLatencyPoll();
  }

  /// Close the sheet if it is up and wait for the diagnostic request in
  /// flight. Every game transition calls this first, so a latency exchange can
  /// never interleave with a start, stop, pause, or resume.
  Future<void> _closeDiagnostics() async {
    if (_diagSheetOpen) {
      _diagSheetOpen = false;
      _stopLatencyPoll();
      if (mounted) await Navigator.of(context).maybePop();
    }
    final pending = _diagPending;
    if (pending != null) await pending;
  }

  Widget _buildDiagnosticsSheet() {
    return AnimatedBuilder(
      // The controller carries the shared veneer/LED settings; the revision
      // carries the numbers this screen polls.
      animation: Listenable.merge(<Listenable>[_c, _diagRevision]),
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          key: const ValueKey<String>('diagnostics-sheet'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Display & diagnostics',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (_isControllerMode)
              _diagnosticsRow(
                'Panel',
                _connection.panelWidth > 0 && _connection.panelHeight > 0
                    ? '${_connection.panelWidth}x${_connection.panelHeight}'
                    : 'not reported',
              )
            else
              DropdownButton<int>(
                key: const ValueKey<String>('panel-size'),
                value: _sizeIndex,
                isExpanded: true,
                items: <DropdownMenuItem<int>>[
                  for (var i = 0; i < _panelSizes.length; i++)
                    DropdownMenuItem<int>(
                      value: i,
                      child: Text(_panelSizes[i].label),
                    ),
                ],
                onChanged: _localRound
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _sizeIndex = value);
                        _diagRevision.value++;
                      },
              ),
            _diagnosticsRow('Ticks', '$_ticks'),
            if (_isControllerMode)
              _diagnosticsRow('Link', _latencyRowValue())
            else
              _diagnosticsRow('Link', 'not connected'),
            const Divider(),
            Row(
              children: <Widget>[
                const Text('veneer', style: TextStyle(fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: _c.veneer,
                    min: 0,
                    max: 100,
                    onChanged: (v) => _c.veneer = v,
                  ),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                const Text('LED', style: TextStyle(fontSize: 12)),
                // A Switch rather than a SwitchListTile: the tile reserves its
                // own width, which a larger system text size turns into a
                // layout assertion.
                Switch(
                  value: _c.ledPixels,
                  onChanged: (v) => _c.ledPixels = v,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The mirror numbers as one line: round trip first, then what the device
  /// reports about its own connection and render path.
  String _latencyRowValue() {
    final lat = _latency;
    final parts = <String>[
      'RTT ${_roundTripMs}ms',
      if (lat != null) 'conn ${lat.connItvlMs}ms',
      if (lat != null)
        'input->render ${(lat.inputToRenderUs / 1000).toStringAsFixed(1)}ms',
    ];
    return parts.join('  |  ');
  }

  Widget _diagnosticsRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
              width: 72,
              child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ help sheet

  /// Open Help: what this round asks for, which controls do it, and the keys
  /// that reach them. The round is paused first and stays paused afterwards,
  /// so nothing runs while the player reads.
  Future<void> _openHelp() async {
    if (!await _pauseForModal() || !mounted) return;
    await _showModal<Object?>(
      () => showModalBottomSheet<Object?>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => _buildHelpSheet(),
      ),
    );
  }

  Widget _buildHelpSheet() {
    final id = _copyGameId;
    final name = id == null ? 'This build has no games' : _gameLabel(id);
    final goal = id == null ? null : _goalFor(id);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        key: const ValueKey<String>('game-help-sheet'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('Help', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(name, style: Theme.of(context).textTheme.titleSmall),
          if (goal != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(goal),
          ],
          const SizedBox(height: 12),
          _buildControlSummary(id),
          const SizedBox(height: 12),
          const Text(
            'Space starts or replays a round. In games with Shoot, press Space '
            'to fire. P or Escape pauses and resumes. Restart or Choose game '
            'asks before discarding an unfinished round.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  /// What the player can press, as the pads label it: the human name plus the
  /// keys that reach it. Axis controls are tilt, not buttons, and a game this
  /// build does not know has no controls to name.
  Widget _buildControlSummary(String? id, {String? keyName}) {
    if (id == null) return const SizedBox.shrink();
    final labels = _copyControlLabels(id);
    if (labels.isEmpty) return const SizedBox.shrink();
    return Column(
      key: keyName == null ? null : ValueKey<String>(keyName),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Controls',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        for (final wire in labels)
          Text(
            _controlLabel(id, wire),
            style: const TextStyle(fontSize: 13),
          ),
      ],
    );
  }

  /// One control as the copy lists it: the human name, the keys that reach it,
  /// or "tilt" for an axis that has no key.
  String _controlLabel(String id, String wire) {
    final name = _aliasFor(id, wire) ?? wire;
    final hint = _keyHints[wire];
    if (hint != null) return '$name  -  $hint';
    return _tiltLabels.contains(wire) ? '$name  -  tilt' : name;
  }

  /// The goal sentence as a widget, or nothing at all when this build has no
  /// copy for the game. A mirror game with an unknown id keeps its raw name
  /// and gets no invented instructions.
  List<Widget>? _goalWidget(String? goal) => goal == null
      ? null
      : <Widget>[
          Text(
            goal,
            key: const ValueKey<String>('game-goal'),
            style: const TextStyle(fontSize: 14),
          ),
        ];

  /// The controls to describe on screen: the running round's own when there is
  /// one, the local catalogue's for the selected game otherwise. A mirror game
  /// this build does not compile has no controls to name until it runs.
  List<String> _copyControlLabels(String id) {
    final mirror = _mirrorGame;
    if (_isControllerMode && mirror != null && mirror.id == id) {
      return <String>[for (final c in mirror.controls) c.label];
    }
    for (final game in _games) {
      if (game.id == id) {
        return <String>[for (final c in game.controls) c.label];
      }
    }
    return const <String>[];
  }

  /// The game the copy on screen describes: the round that is on screen when
  /// one is, otherwise whatever the picker currently selects.
  String? get _copyGameId {
    if (_isControllerMode) return _mirrorGame?.id ?? _mirrorPlayableSelection;
    final local = _localGame;
    if (local != null) return local.id;
    final playable = _playableGames;
    if (playable.isEmpty) return null;
    return playable[_gameIndex < playable.length ? _gameIndex : 0].id;
  }

  /// Display name for a game id: the local simulation's name when the app
  /// knows the id, otherwise the raw id.
  String _gameLabel(String id) {
    for (final g in _games) {
      if (g.id == id) return g.name;
    }
    return id;
  }

  void _onTick(Duration elapsed) {
    final mirrorGame = _mirrorGame;
    if (mirrorGame != null) {
      // Controller mode: press/release edges are sent immediately by the pad
      // handlers, so the ticker only keeps a slow heartbeat as loss recovery.
      // A held button keeps moving on the mirror without any resend: the game
      // retains the press until a release arrives.
      if (_phase != _PlayPhase.playing) return;
      _ticks++;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastMirrorSendMs >= 100) {
        _lastMirrorSendMs = now;
        _sendMirrorInput();
      }
      return;
    }

    final engine = _engine;
    if (engine == null || _phase != _PlayPhase.playing || _isControllerMode) {
      return;
    }

    _ticks++;
    final dt = _lastTime == Duration.zero
        ? const Duration(milliseconds: 16)
        : elapsed - _lastTime;
    _lastTime = elapsed;

    // Feed held state every frame so motion continues while held. The full
    // held state is delivered each frame (every control, pressed or not),
    // which is the contract the runtime's held-input tests pin down; the pad
    // and key edges have already sent their own transitions the moment they
    // arrived, so a short tap is not sampled away here.

    final ms = dt.inMilliseconds.clamp(1, 100);
    final bool over;
    try {
      _sendLocalInput();
      engine.step(ms);
      over = engine.isOver;
    } on StateError {
      _failLocalRound('the game stopped responding');
      return;
    }
    if (over) {
      // Terminal: the round stops stepping here, so nothing is simulated
      // past the state the player finished on. Its final panel still has to
      // be decoded once, which the request below does - directly if the
      // decode slot is free, otherwise the moment the one in flight frees it.
      setState(() => _phase = _PlayPhase.over);
      _sendLocalRelease();
      _releaseAllInput();
    }

    // The simulation keeps its cadence whether or not the decoder is busy;
    // only the copy-and-decode is skipped, so a slow decode costs the round
    // no time and the skipped frames cost it no allocation.
    _requestLocalFrame(engine);
  }

  // The onKeyEvent handler returns KeyEventResult.handled for the round's
  // keys, which consumes them before Flutter's directional focus traversal can
  // act on them. As long as the Focus wrapping the play surface is the primary
  // focus, arrows never escape to move focus between widgets.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // The play surface is only the gamepad while it is the primary focus. A
    // child control - a menu, a dropdown, a sheet button, or a pad button that
    // took focus itself - owns its keys, so hand them back instead of
    // consuming arrows and space as game input.
    if (FocusManager.instance.primaryFocus != node) {
      return KeyEventResult.ignored;
    }

    // Handle the key events of the round on every event type, including
    // KeyRepeatEvent. A held arrow key produces KeyDown then a stream of
    // KeyRepeatEvents; returning ignored for those lets Flutter's directional
    // focus traversal see the arrows and move focus to another widget,
    // stealing control mid-game. A repeat is still not a new press.
    if (event is! KeyDownEvent &&
        event is! KeyRepeatEvent &&
        event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final down = event is KeyDownEvent;
    final up = event is KeyUpEvent;

    // P and Escape toggle Pause/Resume for whichever round is on screen. Only
    // the key-down counts: holding the key down is still one request. Escape
    // never discards a round - Restart is the only way to throw one away.
    if (event.logicalKey == LogicalKeyboardKey.keyP ||
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (down) _togglePause();
      return KeyEventResult.handled;
    }

    // Space fires the round's Shoot control while it is live, and starts or
    // replays a round only when nothing is on screen. Space never restarts a
    // round that is being played, and its key repeat is not a new press.
    if (event.logicalKey == LogicalKeyboardKey.space) {
      const key = _KeySource(LogicalKeyboardKey.space);
      final shoot = _controlIndexForLabel('Shoot');
      if (shoot != null && _phase == _PlayPhase.playing) {
        if (down) _pressControl(shoot, key);
        if (up) _releaseControl(shoot, key);
      } else if (down &&
          (_phase == _PlayPhase.idle || _phase == _PlayPhase.over)) {
        _startFromSpace();
      }
      return KeyEventResult.handled;
    }

    // Direction keys map to the round's controls by label, so rally (Up/Down)
    // and snake (Up/Down/Left/Right) share one handler and a game that
    // reorders its controls keeps working - locally and on the mirror. In
    // Tetris the same keys drive Rotate and Soft drop, because those pads
    // carry the declared labels Up and Down.
    final control = _controlIndexFor(event.logicalKey);
    if (control != null) {
      final source = _KeySource(event.logicalKey);
      if (down) _pressControl(control, source);
      if (up) _releaseControl(control, source);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Space with nothing on screen: start the picker's game, replay the round
  /// that just finished, or start the mirror's selection. It never touches a
  /// round that is still being played.
  void _startFromSpace() {
    if (_isControllerMode) {
      if (_phase == _PlayPhase.over) {
        unawaited(_restartMirrorGame());
        return;
      }
      if (_mirrorGame != null || _mirrorGameId != null) return;
      unawaited(_startMirrorGame());
      return;
    }
    if (_phase == _PlayPhase.over) {
      unawaited(_replayOrStartLocal());
      return;
    }
    _startGame();
  }

  /// Play the local round again: the game that is on screen when one was
  /// started, otherwise the picker's selection. Restart, Play again and Space
  /// all go through this, so none of them can quietly swap the round for
  /// another game.
  Future<void> _replayOrStartLocal() async {
    // A round replayed after the app was suspended has no neutral left: the
    // suspension discarded it, so a motion replay asks for it again first.
    if (!await _motionAllowsPlay()) return;
    if (!mounted) return;
    final current = _localGame;
    if (current != null) {
      _startLocalGame(current);
      return;
    }
    _startGame();
  }

  @override
  Widget build(BuildContext context) {
    // Leaving the screen is a round decision like Restart or Choose game: a
    // round that is still live asks once before it is discarded. Terminal and
    // idle rounds have nothing to lose and just leave.
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_leaveRoute());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Games'),
          actions: <Widget>[
            // Pause/Resume for whichever round is on screen. It is the same
            // action as the P key, and the only way to freeze a mirror round
            // that the player is still holding.
            IconButton(
              key: const ValueKey<String>('game-pause'),
              icon: Icon(
                  _phase == _PlayPhase.paused ? Icons.play_arrow : Icons.pause),
              tooltip: _phase == _PlayPhase.paused ? 'Resume' : 'Pause',
              onPressed: _canTogglePause ? _togglePause : null,
            ),
            IconButton(
              key: const ValueKey<String>('game-help'),
              icon: const Icon(Icons.help_outline),
              tooltip: 'Help',
              onPressed: _openHelp,
            ),
            // Panel size, display settings, tick count and latency are a
            // sheet, closed by default: the play surface keeps its room for
            // the pads. Restart and Choose game live here while a round is
            // live and on the paused view, and each asks once before it
            // throws the round away.
            PopupMenuButton<_MenuAction>(
              key: const ValueKey<String>('game-menu'),
              tooltip: 'More actions',
              // The menu takes the gameplay focus while it is open, exactly
              // like a sheet or a dialog. It is treated as one of this
              // screen's modals, so merely looking at the actions does not
              // read as the player walking away from the round; whatever is
              // chosen from it pauses deliberately if it needs to.
              onOpened: _onMenuOpened,
              onCanceled: _onMenuClosed,
              onSelected: (item) {
                _onMenuClosed();
                switch (item) {
                  case _MenuAction.diagnostics:
                    unawaited(_openDiagnostics());
                  case _MenuAction.restart:
                    unawaited(_restartRound());
                  case _MenuAction.choose:
                    unawaited(_chooseGame());
                }
              },
              itemBuilder: (context) => <PopupMenuEntry<_MenuAction>>[
                // The panel size, the display settings and the round's
                // diagnostics are design-time knobs: the default view plays,
                // it does not tune.
                if (!widget.simplified)
                  const PopupMenuItem<_MenuAction>(
                    key: ValueKey<String>('menu-diagnostics'),
                    value: _MenuAction.diagnostics,
                    child: Text('Display & diagnostics'),
                  ),
                PopupMenuItem<_MenuAction>(
                  key: const ValueKey<String>('menu-restart'),
                  value: _MenuAction.restart,
                  enabled: _roundInProgress && !_mirrorBusy,
                  child: const Text('Restart'),
                ),
                PopupMenuItem<_MenuAction>(
                  key: const ValueKey<String>('menu-choose'),
                  value: _MenuAction.choose,
                  enabled: _roundInProgress && !_mirrorBusy,
                  child: const Text('Choose game'),
                ),
              ],
            ),
          ],
        ),
        // The play surface, local or mirror, is one Focus: it owns the keys the
        // round understands, it hands keys back to any child that takes focus,
        // and losing it is how the screen notices the player walked away.
        body: Focus(
          focusNode: _gameplayFocus,
          onKeyEvent: _onKey,
          onFocusChange: _onGameplayFocusChange,
          autofocus: true,
          child: _isControllerMode ? _buildControllerBody() : _buildLocalBody(),
        ),
      ),
    );
  }

  /// Leave the Games route. A nonterminal round asks once first, exactly like
  /// Restart and Choose game; cancelling keeps the round - paused, with
  /// nothing reset - and stays on the screen.
  Future<void> _leaveRoute() async {
    if (!mounted) return;
    final confirmed = await _confirmDiscard();
    if (!mounted || confirmed == null || confirmed != _opGeneration) return;
    final discarded = await _discardRound();
    if (!mounted || discarded == null || discarded != _opGeneration) return;
    Navigator.of(context).pop();
  }

  /// Throw the round on screen away without a question: the local preview's
  /// engine, or the mirror's session once it acknowledges the stop.
  Future<int?> _discardRound() async {
    if (_isControllerMode) {
      if (!await _stopMirrorGame() || !mounted) return null;
      return _opGeneration;
    }
    if (_localRound) _stopGame();
    return _opGeneration;
  }

  /// The local body: the setup view while nothing is on screen, and the
  /// landscape play surface - movement left, panel centre, actions right -
  /// once a round is there to drive.
  Widget _buildLocalBody() {
    if (_games.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _libraryError ?? 'No games compiled into this build.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // Neutral comes first: while it is being established there is no round to
    // show and nothing may start, on the preview exactly as on a mirror.
    if (_motionPhase == _MotionPhase.calibrating) return _buildCalibrationView();
    if (!_localRound) return _buildLocalSetup();
    // The panel is painted with the designer's veneer and LED settings, and
    // the round's controls are built from the same theme: listen to the
    // controller so a change repaints the frame instead of waiting for the
    // next tick to notice.
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => _buildLocalPlay(),
    );
  }

  /// The local setup view: pick a game and its panel, read what the game asks
  /// for and which controls do it, then start. Everything here scrolls on its
  /// own, so a small window never clips a control out of reach; the display
  /// settings live in the Display & diagnostics sheet.
  Widget _buildLocalSetup() {
    final playable = _playableGames;
    final selected = playable.isEmpty
        ? null
        : playable[_gameIndex < playable.length ? _gameIndex : 0];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_libraryError != null) ...<Widget>[
            Text(
              'The game library is unavailable: ${_libraryError!}',
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 12),
          ],
          // Where the game is shown: the panel painted right here, not the
          // mirror's hardware.
          const Text(
            'Preview',
            key: ValueKey<String>('game-destination'),
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              // The selected game. The key is the stable handle the widget
              // tests drive the picker through.
              DropdownButton<int>(
                key: const ValueKey<String>('game-picker'),
                value: _gameIndex < playable.length ? _gameIndex : 0,
                items: <DropdownMenuItem<int>>[
                  for (var i = 0; i < playable.length; i++)
                    DropdownMenuItem<int>(
                      value: i,
                      child: Text(playable[i].name),
                    ),
                ],
                onChanged: (v) {
                  setState(() => _gameIndex = v ?? 0);
                  _reclaimGameplayFocus();
                },
              ),
              // This screen has one input route, so a two-player game is
              // played against the runtime's AI.
              if (selected != null && selected.maxPlayers > 1)
                const Text('Solo vs computer'),
            ],
          ),
          const SizedBox(height: 12),
          if (selected != null) ...<Widget>[
            Text(
              selected.name,
              key: const ValueKey<String>('game-name'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            ...?_goalWidget(_goalFor(selected.id)),
            const SizedBox(height: 8),
            _buildControlSummary(selected.id, keyName: 'game-controls'),
            const SizedBox(height: 12),
          ],
          _buildInputModePicker(verbose: true),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey<String>('start-game'),
            onPressed:
                selected == null || _motionBusy ? null : _startLocalFromSetup,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start Game'),
          ),
          const SizedBox(height: 4),
          Text(
            _inputMode == _InputMode.motion
                ? (selected?.id == 'invaders'
                    ? 'Tilt steers; tap the play area to shoot.'
                    : 'Tilt steers; actions stay on the right.')
                : 'Movement on the left, actions on the right.',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  /// The local play surface: the round's name and state above the pads, the
  /// panel in the middle of them, and the round's actions below. Nothing here
  /// is discarded by accident - the round is thrown away only by Restart or
  /// Choose game, and both ask first while it is still live. The final frame
  /// stays on screen when the round finishes, with its actions beside it
  /// rather than a banner over it.
  Widget _buildLocalPlay() {
    final failure = _playError;
    if (failure != null) return _buildLocalFailure(failure);
    final game = _localGame;
    final terminal = _phase == _PlayPhase.over;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  game?.name ?? 'Game',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  switch (_phase) {
                    _PlayPhase.paused => 'Paused',
                    _PlayPhase.over => 'Round finished',
                    _ => 'Playing',
                  },
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        // Motion mode draws no movement pad - a pad under a thumb that is not
        // steering would fight the tilt - but the panel stays on screen, which
        // is where the probe's dot shows what the phone is doing.
        Expanded(
          child: _inputMode == _InputMode.motion
              ? _buildMotionGamepad(preview: _buildPreview())
              : _buildPlaySurface(preview: _buildPreview()),
        ),
        if (_phase == _PlayPhase.paused || terminal)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _buildRoundActions(terminal: terminal),
                // The way a paused round is steered is part of the same
                // decision as resuming it, exactly as on a mirror.
                if (!terminal) ...<Widget>[
                  const SizedBox(height: 4),
                  _buildInputModePicker(verbose: false),
                  if (_inputMode == _InputMode.motion)
                    OutlinedButton.icon(
                      key: const ValueKey<String>('paused-recalibrate'),
                      onPressed: () => unawaited(_recalibrate()),
                      icon: const Icon(Icons.screen_rotation),
                      label: const Text('Recalibrate'),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// The round on screen broke - the engine will not render, or a frame will
  /// not decode. Rather than a blank panel or a frozen controls surface that
  /// feeds nothing, this says what happened and offers the one action that
  /// still works: back to setup, where a fresh round can be started. The pads
  /// and the round's own actions are gone with it, so nothing here can feed a
  /// session that cannot draw a frame.
  Widget _buildLocalFailure(String reason) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              reason,
              key: const ValueKey<String>('play-error'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey<String>('play-error-back'),
              onPressed: _stopGame,
              child: const Text('Return to setup'),
            ),
          ],
        ),
      ),
    );
  }

  /// The controller-mode body: a gamepad for the game the mirror runs. The
  /// mirror is the display, so there is no simulated panel here.
  Widget _buildControllerBody() {
    if (_mirrorUnsupported) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "This mirror's firmware does not support games over Bluetooth. "
            'Update the firmware to enable the gamepad.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Tilt comes first: while neutral is being established there is no round
    // to show and nothing may start, and the player needs the one instruction
    // that makes it happen.
    if (_motionPhase == _MotionPhase.calibrating) {
      return _buildCalibrationView();
    }

    if (_phase == _PlayPhase.starting) {
      final id = _mirrorGameId;
      final label = id == null ? 'the game' : _gameLabel(id);
      return _transitionView('Starting $label...');
    }

    final game = _mirrorGame;
    if (game == null) return _buildMirrorSetup();

    if (_phase == _PlayPhase.stopping) {
      // The round is still the mirror's until it acknowledges the stop, but
      // the controls are dead while the command is in flight.
      return _transitionView('Stopping the game...');
    }

    if (_phase == _PlayPhase.pausing) {
      return _transitionView('Pausing the game...');
    }

    if (_phase == _PlayPhase.resuming) {
      return _transitionView('Resuming the game...');
    }

    if (_phase == _PlayPhase.paused) {
      return _buildMirrorPaused(game);
    }

    // The mirror pushed "game over <id>", or answered that the round it was
    // asked about had finished. The panel holds the result; this screen keeps
    // the ways to play it again or choose another.
    if (_phase == _PlayPhase.over) {
      return Column(
        children: <Widget>[
          Expanded(
            child: Center(
              child: Text(
                'Round finished',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            child: _buildRoundActions(terminal: true),
          ),
        ],
      );
    }

    if (_phase != _PlayPhase.playing) {
      // Every other phase returned above. A gamepad for a round that is not
      // running would be a control surface that lies about what it drives,
      // so an unexpected phase falls back to the picker.
      return _buildMirrorSetup();
    }

    return _inputMode == _InputMode.motion
        ? _buildMotionGamepad()
        : _buildPlaySurface(preview: null);
  }

  /// The "hold the phone still" view a motion round passes through before it
  /// starts or resumes. Nothing is started from here, and the pad stays one
  /// tap away for a player who would rather not use tilt at all.
  Widget _buildCalibrationView() {
    return Center(
      key: const ValueKey<String>('motion-calibration'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.screen_rotation, size: 48),
            const SizedBox(height: 16),
            Text(
              'Hold the phone still',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Establishing neutral from '
              '$_calibrationSamples/$_calibrationTarget samples. Tilt steers '
              'the game from there.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _calibrationTarget == 0
                  ? null
                  : _calibrationSamples / _calibrationTarget,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: <Widget>[
                OutlinedButton(
                  key: const ValueKey<String>('calibration-cancel'),
                  onPressed: () => _cancelCalibration(manual: false),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  key: const ValueKey<String>('calibration-manual'),
                  onPressed: () => _cancelCalibration(manual: true),
                  icon: const Icon(Icons.gamepad),
                  label: const Text('Use manual controls'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The mirror's setup view: a picker for the round to start, with each
  /// catalogue state shown as itself. Loading, an empty catalogue, an
  /// unsupported firmware, and a retryable listing error are four different
  /// answers and must not all read "Loading games...".
  Widget _buildMirrorSetup() {
    final ids = _mirrorGameIds;
    final error = _mirrorListError;

    final Widget catalogue;
    if (error != null) {
      catalogue = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            "Could not list the mirror's games: $error",
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _loadMirrorGames(force: true),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      );
    } else if (ids == null) {
      catalogue = const Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading games...'),
        ],
      );
    } else if (ids.isEmpty) {
      catalogue = const Text('No games on this mirror');
    } else {
      final playable = _mirrorPlayableIds;
      catalogue = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (playable.isEmpty)
            const Text('No games on this mirror')
          else
            DropdownButton<String>(
              key: const ValueKey<String>('game-picker'),
              value: _mirrorPlayableSelection ??
                  (playable.isEmpty ? null : playable.first),
              items: <DropdownMenuItem<String>>[
                for (final id in playable)
                  DropdownMenuItem<String>(
                    value: id,
                    child: Text(_gameLabel(id)),
                  ),
              ],
              onChanged: (v) {
                setState(() => _mirrorSelected = v);
                _reclaimGameplayFocus();
              },
            ),
          // What the selected game asks for and which controls do it, before
          // the round starts. A mirror game this build does not know keeps its
          // raw name and gets no invented instructions.
          if (_copyGameId != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _gameLabel(_copyGameId!),
              key: const ValueKey<String>('game-name'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ...?_goalWidget(_goalFor(_copyGameId!)),
            if (_copyControlLabels(_copyGameId!).isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              _buildControlSummary(_copyGameId, keyName: 'game-controls'),
            ],
          ],
          const SizedBox(height: 20),
          _buildInputModePicker(verbose: true),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey<String>('start-game'),
            onPressed: _mirrorBusy || playable.isEmpty || _motionBusy
                ? null
                : () => _startMirrorGame(),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start Game'),
          ),
        ],
      );
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Where the game is shown: the mirror's own panel, not this
            // screen. The same statement the local setup makes about its
            // preview.
            Text(
              'Playing on ${_connection.deviceName ?? 'the mirror'}',
              key: const ValueKey<String>('game-destination'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            catalogue,
            const SizedBox(height: 24),
            const Text(
              'The mirror shows the game on its panel; this phone is the '
              'gamepad.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// A transition is in flight; the round's controls stay off the screen so
  /// nothing can be pressed into a session that is being replaced.
  Widget _transitionView(String label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label),
        ],
      ),
    );
  }

  /// How the round on screen is steered: the pads and the keyboard, or the
  /// phone's tilt. Shared by the mirror path and the local preview, so the
  /// choice means the same thing on both and a round that cannot be steered by
  /// tilt says so instead of offering a mode that would do nothing.
  ///
  /// The default view has no choice to make - it steers by tilt and falls back
  /// to the pads by itself - so it draws nothing here, and the reason a round
  /// cannot take tilt is said where the game is chosen.
  Widget _buildInputModePicker({required bool verbose}) {
    if (widget.simplified) return const SizedBox.shrink();
    final problem = _motionUnavailable;
    if (problem != null) {
      return Text(
        problem,
        key: const ValueKey<String>('motion-unavailable'),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    return RadioGroup<_InputMode>(
      groupValue: _inputMode,
      onChanged: (v) => unawaited(_setInputMode(v ?? _InputMode.manual)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          RadioListTile<_InputMode>(
            value: _InputMode.manual,
            key: const ValueKey<String>('mode-manual'),
            title: Text(verbose ? 'Manual controls' : 'Manual'),
            contentPadding: EdgeInsets.zero,
          ),
          RadioListTile<_InputMode>(
            value: _InputMode.motion,
            key: const ValueKey<String>('mode-motion'),
            title: Text(verbose ? 'Motion controls' : 'Motion'),
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  /// The round is frozen on the mirror and every control here is released.
  /// The round itself is still live on the device, so the player chooses
  /// between continuing it, starting it over, and leaving it for the picker.
  /// The way it is steered is part of the same decision: switching to motion
  /// re-establishes neutral before the resume it leads to.
  Widget _buildMirrorPaused(MirrorGame game) {
    // How the round is steered is a decision the default view does not offer:
    // it is on tilt, and the pads are the fallback when the device cannot
    // report. Recalibrate stays either way - a fresh neutral is part of
    // playing, not a mode.
    final canRecalibrate =
        widget.simplified || _inputMode == _InputMode.motion;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('Paused', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '${_gameLabel(game.id)} is frozen on the mirror. It stays '
              'there until it is resumed, restarted, or left behind.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            _buildRoundActions(terminal: false),
            const SizedBox(height: 20),
            if (!widget.simplified) ...<Widget>[
              const Divider(),
              RadioGroup<_InputMode>(
                groupValue: _inputMode,
                onChanged: (v) =>
                    unawaited(_setInputMode(v ?? _InputMode.manual)),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    RadioListTile<_InputMode>(
                      value: _InputMode.manual,
                      key: ValueKey<String>('mode-manual'),
                      title: Text('Manual'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile<_InputMode>(
                      value: _InputMode.motion,
                      key: ValueKey<String>('mode-motion'),
                      title: Text('Motion'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
            ],
            if (canRecalibrate) ...<Widget>[
              const SizedBox(height: 8),
              // A fresh neutral for this round: the pause is kept, and the
              // resume stays the player's explicit next move.
              OutlinedButton.icon(
                key: const ValueKey<String>('paused-recalibrate'),
                onPressed: _mirrorBusy ? null : () => unawaited(_recalibrate()),
                icon: const Icon(Icons.screen_rotation),
                label: const Text('Recalibrate'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Re-establish neutral while the round is paused. Directions are cleared
  /// first - a stale tilt must not survive the new baseline - and the round
  /// stays frozen until the player resumes it.
  Future<void> _recalibrate() async {
    if (_phase != _PlayPhase.paused) return;
    if (_isControllerMode) {
      _releaseMirrorInput();
    } else {
      _sendLocalRelease();
      _releaseAllInput();
    }
    await _calibrateMotion();
  }

  // --------------------------------------------------------- control surface

  /// The play surface shared by a local round and a mirror round: the
  /// movement grid under the left thumb, the action column under the right,
  /// and the local panel in the middle - nothing there when the mirror is the
  /// display. Both modes size their buttons with the same formula, so a
  /// control is the same size wherever it is drawn.
  ///
  /// A surface that cannot give every button its 48-pixel minimum is refused
  /// rather than clipped: nothing is clamped upward into an overflow, and
  /// whatever was running is paused instead of stepping behind a pad nobody
  /// can reach.
  Widget _buildPlaySurface({required Widget? preview}) {
    final specs = _padSpecs();
    final axes = _axisSpecs();
    final directions = <_PadSpec>[
      for (final spec in specs)
        if (spec.isDirection) spec,
    ];
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = _padSide(
            availableWidth: constraints.maxWidth,
            availableHeight: constraints.maxHeight,
            withPreview: preview != null,
          );
          if (side < _minPadSide) {
            _noteInsufficientSpace();
            return _insufficientSpaceView();
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _MovementPad(
                specs: directions,
                side: side,
                gap: _padGap,
                heldAt: _heldAt,
                onTrack: _trackPadPointer,
                onEnd: _releasePointer,
                onActivate: _activatePad,
              ),
              const SizedBox(width: _padGap),
              Expanded(child: preview ?? const SizedBox.shrink()),
              const SizedBox(width: _padGap),
              _buildActionColumn(specs, axes, side),
            ],
          );
        },
      ),
    );
  }

  /// The action buttons under the right thumb, with the axis readouts of a
  /// round that takes tilt below them.
  Widget _buildActionColumn(
    List<_PadSpec> specs,
    List<_PadSpec> axes,
    double side,
  ) {
    final actions = <_PadSpec>[
      for (final spec in specs)
        if (!spec.isDirection) spec,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < actions.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: _padGap),
          _ActionButton(
            spec: actions[i],
            side: side,
            pressed: _heldAt(actions[i].index),
            onPress: _pressAction,
            onMove: _moveAction,
            onRelease: _releasePointer,
            onActivate: _activatePad,
          ),
        ],
        for (final axis in axes) ...<Widget>[
          const SizedBox(height: _padGap),
          _AxisReadout(spec: axis, side: side, value: _axes[axis.index] ?? 0),
        ],
      ],
    );
  }

  /// Motion mode: tilt steers, so no movement grid is drawn - a pad under a
  /// thumb that is not steering the game would fight the tilt. Action buttons
  /// stay reachable, and a round steered by tilt axes shows them as readouts.
  Widget _buildMotionGamepad({Widget? preview}) {
    final actions = <_PadSpec>[
      for (final spec in _padSpecs())
        if (!spec.isDirection) spec,
    ];
    final axes = _axisSpecs();
    // Which estimator is running is worth a word: without a gyroscope a brisk
    // hand movement still reads as tilt, and a round that cannot do better
    // should not look like one that can. Before a round has a mapper there is
    // nothing to claim either way, so it claims nothing.
    final MotionControl? motion = _motion;
    final String steerCaption = motion == null
        ? 'Tilt the phone to steer'
        : motion.gyroscopeAssisted
            ? 'Tilt the phone to steer — gyro-assisted'
            : 'Tilt the phone to steer — accelerometer only';
    final Widget body = SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = _padSide(
            availableWidth: constraints.maxWidth,
            availableHeight: constraints.maxHeight,
            withPreview: preview != null,
          );
          if (side < _minPadSide) {
            _noteInsufficientSpace();
            return _insufficientSpaceView();
          }
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    _runningGameId == null
                        ? 'Game'
                        : _gameLabel(_runningGameId!),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    steerCaption,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  // Invaders fires from the whole board in motion mode, so the
                  // caption has to say so: the Shoot pad is a shortcut, not
                  // the only way.
                  if (_runningGameId == 'invaders') ...<Widget>[
                    const SizedBox(height: 4),
                    const Text(
                      'Tap anywhere in the play area to shoot.',
                      key: ValueKey<String>('motion-shoot-hint'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ],
                  if (preview != null) ...<Widget>[
                    const SizedBox(height: 16),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: side * 4),
                      child: preview,
                    ),
                  ],
                  if (actions.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: _padGap,
                      runSpacing: _padGap,
                      alignment: WrapAlignment.center,
                      children: <Widget>[
                        for (final spec in actions)
                          _ActionButton(
                            spec: spec,
                            side: side,
                            pressed: _heldAt(spec.index),
                            onPress: _pressAction,
                            onMove: _moveAction,
                            onRelease: _releasePointer,
                            onActivate: _activatePad,
                          ),
                      ],
                    ),
                  ],
                  for (final axis in axes) ...<Widget>[
                    const SizedBox(height: 16),
                    _AxisReadout(
                      spec: axis,
                      side: side,
                      value: _axes[axis.index] ?? 0,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );

    // Invaders in motion mode: the play area itself is the Shoot control, so
    // the preview, the empty space around it, the captions and the readouts
    // all fire. The listener's box is this body only - the app bar, the
    // paused actions and the pickers sit outside it - and it is opaque so a
    // press on bare background still reaches it.
    if (_runningGameId != 'invaders') return body;
    return Listener(
      key: const ValueKey<String>('motion-shoot-surface'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: _pressMotionSurface,
      onPointerUp: (PointerUpEvent event) => _releasePointer(event.pointer),
      onPointerCancel: (PointerCancelEvent event) =>
          _releasePointer(event.pointer),
      child: body,
    );
  }

  /// The pad buttons of the round on screen, in control order. Axes are not
  /// buttons and never appear here.
  List<_PadSpec> _padSpecs() {
    final out = <_PadSpec>[];
    if (_isControllerMode) {
      final game = _mirrorGame;
      if (game == null) return out;
      for (var i = 0; i < game.controls.length; i++) {
        final control = game.controls[i];
        if (control.isAxis) continue;
        out.add(_specFor(i, control.label));
      }
      return out;
    }
    for (var i = 0; i < _localControls.length; i++) {
      if (_localControls[i].isAxis) continue;
      out.add(_specFor(i, _localControls[i].label));
    }
    return out;
  }

  /// The axis controls of the round on screen: readouts, never pads.
  List<_PadSpec> _axisSpecs() {
    final out = <_PadSpec>[];
    if (_isControllerMode) {
      final game = _mirrorGame;
      if (game == null) return out;
      for (var i = 0; i < game.controls.length; i++) {
        final control = game.controls[i];
        if (!control.isAxis) continue;
        out.add(_specFor(i, control.label));
      }
      return out;
    }
    for (var i = 0; i < _localControls.length; i++) {
      if (!_localControls[i].isAxis) continue;
      out.add(_specFor(i, _localControls[i].label));
    }
    return out;
  }

  /// One control as the pads draw it: the same wire label, the human name the
  /// round knows it by, and the keys it answers to.
  _PadSpec _specFor(int index, String wire) => _PadSpec(
        index: index,
        wire: wire,
        label: _aliasFor(_runningGameId, wire) ?? wire,
        hint: _keyHints[wire] ?? '',
      );

  /// Whether a control is held right now, for the pads' pressed state.
  bool _heldAt(int index) =>
      index >= 0 && index < _held.length && _held[index] != 0;

  /// The side every pad button shares: three movement rows, or four button
  /// widths across with the panel and the spacing reserved for it. The result
  /// is never clamped upward - a surface that cannot fit a 48 logical pixel
  /// button says so instead of overflowing.
  double _padSide({
    required double availableWidth,
    required double availableHeight,
    required bool withPreview,
  }) {
    final byHeight = (availableHeight - 2 * _padGap) / 3;
    final byWidth =
        (availableWidth - (withPreview ? 128 : 0) - 6 * _padGap) / 4;
    final side = byHeight < byWidth ? byHeight : byWidth;
    return side > _maxPadSide ? _maxPadSide : side;
  }

  /// The play layout cannot fit at its minimum button size. Shown instead of a
  /// cropped control surface, and scrollable on its own.
  Widget _insufficientSpaceView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.aspect_ratio, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              'More space needed to play',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Give the window more room - or turn the phone back to '
              'landscape - so every control gets at least 48 pixels.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// Every button needs its 48-pixel minimum and the build found a surface
  /// that cannot give it. Pause whatever was running: a round nobody can
  /// steer must not keep stepping (or keep a mirror game running) behind a
  /// layout with no controls. Scheduled after the frame, because it comes out
  /// of a build.
  void _noteInsufficientSpace() {
    if (_spacePauseScheduled) return;
    _spacePauseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _spacePauseScheduled = false;
      if (!mounted) return;
      if (_phase == _PlayPhase.playing) _interrupt(automatic: true);
    });
  }

  /// The local panel: the round's frame drawn with the same LED + veneer paint
  /// path the layout preview uses. Display-only - the pads are the only local
  /// input - so nothing here consumes a gesture.
  Widget _buildPreview() {
    final libraryError = _libraryError;
    if (libraryError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'The game library is unavailable: $libraryError',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final engine = _engine;
    final image = _image;
    if (engine == null || image == null) {
      return const Center(
        child: Text(
          'Preparing the game...',
          style: TextStyle(fontSize: 14, color: Colors.grey),
        ),
      );
    }

    final cw = engine.width;
    final ch = engine.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Fill the tighter axis exactly, like the layout preview: a
        // whole-number multiplier leaves dead space on a phone's screen.
        final zoom = fitGameZoom(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          canvasWidth: cw,
          canvasHeight: ch,
        );

        final w = cw * zoom;
        final h = ch * zoom;

        return Center(
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              SizedBox(
                width: w,
                height: h,
                child: CustomPaint(
                  isComplex: true,
                  painter: _GamePainter(
                    image: image,
                    frame: _frame,
                    zoom: zoom,
                    ledPixels: _c.ledPixels,
                    veneer: _c.veneer,
                    canvasWidth: cw,
                    canvasHeight: ch,
                  ),
                ),
              ),
              if (_phase == _PlayPhase.paused)
                // A frozen frame with no explanation reads as a hung game. A
                // corner label rather than a banner: the paused board is still
                // worth looking at, and Resume is one tap away.
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: Theme.of(context).colorScheme.primary),
                    ),
                    child: const Text(
                      'Paused - Resume to continue',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Map a key to the index of the control it drives, by control label.
  /// Not const: LogicalKeyboardKey overrides ==/hashCode, which a const map
  /// key cannot do.
  static final Map<LogicalKeyboardKey, String> _keyLabels =
      <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.arrowUp: 'Up',
    LogicalKeyboardKey.keyW: 'Up',
    LogicalKeyboardKey.arrowDown: 'Down',
    LogicalKeyboardKey.keyS: 'Down',
    LogicalKeyboardKey.arrowLeft: 'Left',
    LogicalKeyboardKey.keyA: 'Left',
    LogicalKeyboardKey.arrowRight: 'Right',
    LogicalKeyboardKey.keyD: 'Right',
  };

  /// The control labels of the round this screen is feeding: the mirror's
  /// declared controls while it runs the game, otherwise the controls of the
  /// local game whose engine is open. Keyboard labels are resolved from this,
  /// so the same keys drive a mirror round as drive a local one. A round that
  /// is not running has no controls of its own, and neither view borrows the
  /// other's.
  List<String> get _activeControlLabels {
    if (_isControllerMode) {
      final mirror = _mirrorGame;
      if (mirror == null) return const <String>[];
      return <String>[for (final c in mirror.controls) c.label];
    }
    return <String>[for (final c in _localControls) c.label];
  }

  /// Map a control label to its index in the round on screen, or null when
  /// that round has no such control.
  int? _controlIndexForLabel(String label) {
    final controls = _activeControlLabels;
    for (var i = 0; i < controls.length; i++) {
      if (controls[i] == label) return i;
    }
    return null;
  }

  int? _controlIndexFor(LogicalKeyboardKey key) {
    final label = _keyLabels[key];
    if (label == null) return null;
    return _controlIndexForLabel(label);
  }
}

// ------------------------------------------------------------ control pads

/// One pad button's face: the pressed state, the human label, the keys that
/// reach it, and the accessible name. Pointer handling belongs to the surface
/// that owns the geometry - the movement grid's single pointer surface, or an
/// action button's own rectangle - so this widget never reads a pointer.
class _PadFace extends StatelessWidget {
  const _PadFace({
    super.key,
    required this.spec,
    required this.side,
    required this.pressed,
    required this.onActivate,
  });

  final _PadSpec spec;
  final double side;
  final bool pressed;

  /// An accessibility or keyboard activation of this pad.
  final void Function(_PadSpec spec) onActivate;

  static const Set<String> _arrows = <String>{'Up', 'Down', 'Left', 'Right'};

  IconData get _icon => switch (spec.wire) {
        'Up' => Icons.keyboard_arrow_up,
        'Down' => Icons.keyboard_arrow_down,
        'Left' => Icons.keyboard_arrow_left,
        _ => Icons.keyboard_arrow_right,
      };

  /// A pad that has focus answers Enter and Space itself, so its activation
  /// never reaches the round as an unrelated press.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.select) {
      onActivate(spec);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = pressed ? scheme.onPrimary : scheme.onSurface;
    // A direction still drawn under its own name is an arrow. Everything else
    // - a human alias like Rotate, or an action like Shoot - is text, with the
    // keys that reach it underneath.
    final bool asArrow = spec.label == spec.wire && _arrows.contains(spec.wire);
    final Widget content = asArrow
        ? Icon(_icon, size: side * 0.52, color: foreground)
        : Padding(
            padding: const EdgeInsets.all(4),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    spec.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: foreground,
                    ),
                  ),
                  if (spec.hint.isNotEmpty)
                    Text(
                      spec.hint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        color: pressed ? scheme.onPrimary : Colors.grey,
                      ),
                    ),
                ],
              ),
            ),
          );

    return Semantics(
      container: true,
      button: true,
      label: spec.label,
      onTap: () => onActivate(spec),
      child: ExcludeSemantics(
        child: Focus(
          canRequestFocus: true,
          onKeyEvent: _onKey,
          child: SizedBox.square(
            dimension: side,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 70),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    pressed ? scheme.primary : scheme.surfaceContainerHighest,
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// The movement grid: one parent pointer surface over the visible direction
/// rectangles. Sliding from one direction onto the next changes direction,
/// the gaps and the empty centre are neutral, and a second pointer steers
/// independently of the first.
class _MovementPad extends StatelessWidget {
  const _MovementPad({
    required this.specs,
    required this.side,
    required this.gap,
    required this.heldAt,
    required this.onTrack,
    required this.onEnd,
    required this.onActivate,
  });

  /// The directions this round declares, keyed by their wire labels.
  final List<_PadSpec> specs;
  final double side;
  final double gap;

  /// Whether a control is held right now, for the pressed state.
  final bool Function(int index) heldAt;

  /// The pointer is over [index], or over nothing when [index] is null.
  final void Function(int pointer, int? index) onTrack;

  /// The pointer is gone: up or cancelled.
  final void Function(int pointer) onEnd;

  final void Function(_PadSpec spec) onActivate;

  /// Where one direction sits in the 3x3 grid. The centre is deliberately
  /// empty: a d-pad with no fifth button.
  Offset _cell(String wire) {
    final step = side + gap;
    switch (wire) {
      case 'Up':
        return Offset(step, 0);
      case 'Right':
        return Offset(2 * step, step);
      case 'Down':
        return Offset(step, 2 * step);
      case 'Left':
        return Offset(0, step);
      default:
        return Offset.zero;
    }
  }

  /// The direction whose rectangle contains [point], or null over the gaps,
  /// the empty centre, and anywhere outside the grid.
  int? _hit(Offset point) {
    for (final spec in specs) {
      final rect = _cell(spec.wire) & Size.square(side);
      if (rect.contains(point)) return spec.index;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final box = 3 * side + 2 * gap;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) =>
          onTrack(event.pointer, _hit(event.localPosition)),
      onPointerMove: (event) =>
          onTrack(event.pointer, _hit(event.localPosition)),
      onPointerUp: (event) => onEnd(event.pointer),
      onPointerCancel: (event) => onEnd(event.pointer),
      child: SizedBox(
        width: box,
        height: box,
        child: Stack(
          children: <Widget>[
            for (final spec in specs)
              Positioned(
                left: _cell(spec.wire).dx,
                top: _cell(spec.wire).dy,
                child: _PadFace(
                  key: ValueKey<String>('control-${spec.wire}'),
                  spec: spec,
                  side: side,
                  pressed: heldAt(spec.index),
                  onActivate: onActivate,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One action button: its own pointer rectangle. A press starts inside it, a
/// pointer that leaves the rectangle releases it and cannot press it again by
/// sliding back in, and up or cancel releases it wherever the pointer is.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.spec,
    required this.side,
    required this.pressed,
    required this.onPress,
    required this.onMove,
    required this.onRelease,
    required this.onActivate,
  });

  final _PadSpec spec;
  final double side;
  final bool pressed;

  /// The pointer went down inside this button.
  final void Function(int pointer, int index) onPress;

  /// The pointer moved: [inside] says whether it is still over the button.
  final void Function(int pointer, int index, bool inside) onMove;

  /// The pointer is gone: up or cancelled.
  final void Function(int pointer) onRelease;

  final void Function(_PadSpec spec) onActivate;

  @override
  Widget build(BuildContext context) {
    final rect = Offset.zero & Size.square(side);
    return Listener(
      key: ValueKey<String>('control-${spec.wire}'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => onPress(event.pointer, spec.index),
      onPointerMove: (event) => onMove(
        event.pointer,
        spec.index,
        rect.contains(event.localPosition),
      ),
      onPointerUp: (event) => onRelease(event.pointer),
      onPointerCancel: (event) => onRelease(event.pointer),
      child: _PadFace(
        spec: spec,
        side: side,
        pressed: pressed,
        onActivate: onActivate,
      ),
    );
  }
}

/// One axis control of the round on screen. An axis is not a button: the
/// mirror drives it from tilt, and this shows the value instead of offering
/// something to press.
class _AxisReadout extends StatelessWidget {
  const _AxisReadout({
    required this.spec,
    required this.side,
    required this.value,
  });

  final _PadSpec spec;
  final double side;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: ValueKey<String>('axis-${spec.wire}'),
      container: true,
      label: '${spec.label} axis',
      value: '$value',
      child: ExcludeSemantics(
        child: SizedBox(
          width: side,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  spec.label,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('$value', style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints the game frame as a pixel-exact LED panel.
///
/// Same two-pass approach as _PanelPainter in panel_view.dart: first the
/// emitter discs (or the crisp bitmap when LED is off), then the veneer scatter
/// pass for the diffusion that a wood face over the matrix would add.
class _GamePainter extends CustomPainter {
  _GamePainter({
    required this.image,
    required this.frame,
    required this.zoom,
    required this.ledPixels,
    required this.veneer,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  final ui.Image? image;
  final Uint8List? frame;
  final double zoom;

  /// Whether to draw discrete emitters rather than the smooth bitmap.
  final bool ledPixels;

  /// Veneer diffusion strength, 0 to 100.
  final double veneer;
  final int canvasWidth;
  final int canvasHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = const Color(0xFF000000));

    final img = image;
    if (img == null) return;

    // Calibrated so 100% is what 50% meant before the slider was rebased:
    // the diffusion strength is half the slider value.
    final v = veneer / 200;
    final src =
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, canvasWidth * zoom, canvasHeight * zoom);

    if (!ledPixels || frame == null || zoom < 3) {
      final paint = Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false;
      if (v <= 0) {
        canvas.drawImageRect(img, src, dst, paint);
      } else {
        canvas.saveLayer(
          bounds,
          Paint()
            ..imageFilter =
                ui.ImageFilter.blur(sigmaX: zoom * 8 * v, sigmaY: zoom * 8 * v),
        );
        canvas.drawImageRect(img, src, dst, paint);
        canvas.restore();
      }
      return;
    }

    _paintLed(canvas, img, bounds, v);
  }

  /// The panel as a field of point sources, ported from _PanelPainter.
  void _paintLed(Canvas canvas, ui.Image img, Rect bounds, double v) {
    final pixels = frame!;
    const emitterPitch = 0.68;
    final radius = zoom * emitterPitch / 2;
    final half = zoom * 0.5;
    final paint = Paint()..isAntiAlias = true;
    if (v > 0) {
      paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, zoom * 2 * v);
    }

    if (v > 0) {
      _drawScatter(canvas, img, bounds, zoom * 5 * v, 0.50 * v);
      _drawScatter(canvas, img, bounds, zoom * 1.8 * v, 0.65 * v);
    }

    for (var y = 0; y < canvasHeight; y++) {
      final cy = y * zoom + half;
      final row = y * canvasWidth * 4;
      for (var x = 0; x < canvasWidth; x++) {
        final i = row + x * 4;
        final r = pixels[i];
        final g = pixels[i + 1];
        final b = pixels[i + 2];
        if (r == 0 && g == 0 && b == 0) continue;
        paint.color = Color.fromARGB(255, r, g, b);
        canvas.drawCircle(Offset(x * zoom + half, cy), radius, paint);
      }
    }
  }

  void _drawScatter(
      Canvas canvas, ui.Image img, Rect bounds, double sigma, double opacity) {
    canvas.saveLayer(
      bounds,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, canvasWidth * zoom, canvasHeight * zoom),
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false
        ..colorFilter = ColorFilter.mode(
            Color.fromRGBO(255, 255, 255, opacity), BlendMode.modulate),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GamePainter old) =>
      old.image != image ||
      old.frame != frame ||
      old.zoom != zoom ||
      old.ledPixels != ledPixels ||
      old.veneer != veneer ||
      old.canvasWidth != canvasWidth ||
      old.canvasHeight != canvasHeight;
}

class _PanelPreset {
  const _PanelPreset(this.label, this.w, this.h);
  final String label;
  final int w, h;
}
