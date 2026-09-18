// Games screen: the control surface, checked against the real game simulation.
//
// The regressions here compare two runs of the screen with each other instead
// of against a frame recorded by hand. Two runs that take the same pumps
// simulate the same ticks, so the difference between their final panels is the
// input under test: a rotation that arrived between two ticks, a pointer that
// was cancelled, a release that took the second source with it. The bytes are
// taken where the screen hands a frame to its decoder - the RGBA8888 buffer the
// native game rendered - so nothing here asserts private screen state.
//
// That decoder is a seam the test owns. A regression can hold one decode open
// while the round underneath it is restarted, paused, or torn down, then let
// the answer arrive late and see what becomes of it: the frame the player is
// looking at is read off the painter, the frames that were asked for are read
// off the seam, every image handed back is checked for disposal, and the engine
// a frame came from is asked - through its public tick - whether the round kept
// simulating while its frame waited.
//
// Needs the native core, which is built as part of the app rather than by
// `flutter test`. Build the app once first:
//
//   flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib \
//       flutter test test/game_screen_test.dart
//
// Rebuild whenever gamekit's C sources change: a stale bundle keeps the old
// game rules, and a held Rotate then spins the piece every tick instead of
// once, which these tests catch the hard way.
//
// Choosing, playing, and leaving a round is one flow: the setup view names the
// selected game, says what it asks for and where it will be shown, and starts
// it; a live round keeps Pause and Help on the app bar with Restart and Choose
// game in the overflow menu; a paused round offers Resume/Restart/Choose game;
// and throwing a round away always asks once. The navigation regressions below
// drive that flow through the keys the screen exposes, so an action that moves
// or disappears shows up here rather than in a manual pass.
//
// Deliberately no native-library skip: without the library these must fail
// rather than quietly reduce the suite to nothing.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
// The semantics tree, for the accessible-button checks. Material does not
// re-export it.
import 'package:flutter/rendering.dart'
    show SemanticsAction, SemanticsData, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/controller.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/engine/game_engine.dart';
import 'package:mirror_designer/src/services/mirror_connection.dart';
import 'package:mirror_designer/src/ui/game_screen.dart';

/// A blank 64x32 layout. The Games screen only borrows the veneer and LED
/// settings from the designer, so its contents do not matter.
const String _blankLayout = '{"canvas":{"width":64,"height":32},'
    '"background":"#000000","widgets":[]}';

/// The centre of the probe's red dot, read off the frame the round rendered.
/// -1,-1 when there is no dot, so a missing one fails the assertion that reads
/// it rather than passing quietly.
Offset _redDotCentre(Uint8List rgba) {
  var minX = -1, maxX = -1, minY = -1, maxY = -1;
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 64; x++) {
      final int i = (y * 64 + x) * 4;
      if (rgba[i] > 150 && rgba[i + 1] < 90 && rgba[i + 2] < 90) {
        if (minX < 0 || x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (minY < 0 || y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (minX < 0) return const Offset(-1, -1);
  return Offset((minX + maxX) / 2, (minY + maxY) / 2);
}

/// Display name of a game in the shipped catalogue.
String _name(String id) =>
    GameEngine.games.firstWhere((GameInfo game) => game.id == id).name;

/// The wire labels a game declares, in code order.
List<String> _wires(String id) => <String>[
      for (final control
          in GameEngine.games
              .firstWhere((GameInfo game) => game.id == id)
              .controls)
        control.label,
    ];

/// The wire labels a game declares as axes (its tilt controls).
Set<String> _axisWires(String id) => <String>{
      for (final control
          in GameEngine.games
              .firstWhere((GameInfo game) => game.id == id)
              .controls)
        if (control.isAxis) control.label,
    };

/// The human name a pad shows for a wire label. The wire label itself is never
/// rewritten: it is what the firmware, the pad ValueKeys, and the input codes
/// speak.
String _alias(String id, String wire) {
  if (id == 'tetris') {
    if (wire == 'Up') return 'Rotate';
    if (wire == 'Down') return 'Soft drop';
  }
  return wire;
}

/// One pointer held from [down] until the end of the run.
class _Touch {
  const _Touch(this.wire, this.down);

  final String wire;
  final int down;
}

/// The semantics node carrying exactly [label], for the button checks below.
/// Exact equality: a pad's label is an accessible name, not a substring match
/// against whatever text happens to sit near it.
SemanticsNode _semantics(String label) => find.semantics
    .byPredicate((SemanticsNode node) => node.label == label)
    .evaluate()
    .single;

bool _onScreen(Rect rect, Size surface) =>
    rect.left >= 0 &&
    rect.top >= 0 &&
    rect.right <= surface.width &&
    rect.bottom <= surface.height;

/// Pump [duration] in fixed 50 ms frames. A live round schedules a frame on
/// every tick, so `pumpAndSettle` would wait for ever: the menus, dialogs and
/// sheets here are advanced by a fixed amount instead.
Future<void> _pumpFor(
  WidgetTester tester, [
  Duration duration = const Duration(milliseconds: 400),
]) async {
  const Duration step = Duration(milliseconds: 50);
  for (Duration left = duration; left > Duration.zero; left -= step) {
    await tester.pump(left < step ? left : step);
  }
}

/// How long a real decode is given to land off the test's own clock. Every
/// frame the round renders is decoded by `dart:ui` for real, which only
/// completes inside [WidgetTester.runAsync]; the wait is the same everywhere so
/// no two helpers disagree about how long "decoded" takes.
const Duration _decodeSettle = Duration(milliseconds: 10);

/// Whether two panels are the same frame, byte for byte.
bool _sameFrame(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One frame the screen handed to the decode seam: the exact bytes the native
/// game rendered, and the engine that rendered them.
class _Request {
  _Request(this.engine, this.bytes);

  /// The engine the frame came from. Its public [GameEngine.tick] is how a
  /// regression shows whether the round was still being stepped while its
  /// frame waited.
  final GameEngine engine;

  /// The RGBA8888 panel the native game rendered.
  final Uint8List bytes;

  /// The image the test handed back for this frame, once it was answered.
  ui.Image? image;
}

/// A decode the test has not answered yet.
class _Hold {
  final Completer<ui.Image?> answer = Completer<ui.Image?>();
  late _Request request;
}

/// The screen's decoding seam, owned by the test: every frame the screen asked
/// to have decoded, every image it was handed, and the ability to keep one
/// answer back until the round underneath it has moved on.
class _Decodes {
  /// Every frame the screen submitted, oldest first.
  final List<_Request> requests = <_Request>[];

  /// Images the teardown had to dispose because the screen went away still
  /// holding them. A regression asserts this is zero: a leak must not pass as
  /// a teardown detail.
  int leaked = 0;

  _Hold? _arm;
  _Hold? _held;
  bool _nullNext = false;
  Object? _throwNext;

  /// How many frames the screen has asked to have decoded.
  int get asked => requests.length;

  /// The newest frame the screen handed to the seam.
  Uint8List get latest => requests.last.bytes;

  /// The newest frame the screen has been given an answer for. Its engine's
  /// frame is the one the round is showing, unless a later answer arrived too
  /// late to be drawn.
  ui.Image? get answeredImage {
    for (var i = requests.length - 1; i >= 0; i--) {
      final ui.Image? image = requests[i].image;
      if (image != null) return image;
    }
    return null;
  }

  /// The frame the screen is waiting for an answer to, if one is held back.
  _Hold? get held => _held;

  /// Hold the answer to the next frame the screen submits.
  void holdNext() => _arm = _Hold();

  /// Answer the next frame with no image at all.
  void returnNullNext() => _nullNext = true;

  /// Fail the next frame's decode from the seam call itself.
  void throwNext(Object error) => _throwNext = error;

  /// The seam. How many requests the screen keeps in the air is its own
  /// business, and exactly what [requests] is here to record.
  Future<ui.Image?> call(GameEngine engine, Uint8List bytes) {
    final _Request request = _Request(engine, bytes);
    requests.add(request);

    final Object? error = _throwNext;
    if (error != null) {
      _throwNext = null;
      throw error;
    }
    if (_nullNext) {
      _nullNext = false;
      return Future<ui.Image?>.value();
    }
    final _Hold? arm = _arm;
    if (arm != null) {
      _arm = null;
      arm.request = request;
      _held = arm;
      return arm.answer.future;
    }
    return _decode(request);
  }

  /// Answer the held frame with a real decode of the bytes it was asked for.
  /// The image comes back so the caller can see whether the screen kept it or
  /// threw it away.
  Future<ui.Image> release() {
    final _Hold hold = _held!;
    _held = null;
    return _decode(hold.request).then((ui.Image? image) {
      hold.answer.complete(image);
      return image!;
    });
  }

  /// Dispose every image the screen left behind when it went away.
  void disposeLeftovers() {
    for (final _Request request in requests) {
      final ui.Image? image = request.image;
      if (image == null || image.debugDisposed) continue;
      leaked++;
      image.dispose();
    }
  }

  /// Decode [request] for real, through the same engine call the app's default
  /// seam uses, and record the image the screen was handed.
  Future<ui.Image?> _decode(_Request request) async {
    final ui.Image? image = await request.engine.decodeImage(request.bytes);
    request.image = image;
    return image;
  }
}

/// One run of the Games screen: a fresh local round, a script, and the panel
/// the script left on screen.
class _Scene {
  _Scene._(this.tester, this.controller, this.connection, this.decodes);

  static Future<_Scene> open(
    WidgetTester tester, {
    Size surface = const Size(1000, 600),
    double textScale = 1,
    double inset = 0,
    _Decodes? decodes,
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(
      left: inset,
      top: inset / 2,
      right: inset,
      bottom: inset / 2,
    );
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final controller = DesignerController(MirrorEngine.open());
    final connection = MirrorConnection();
    final seam = decodes ?? _Decodes();
    await tester.runAsync(() => controller.loadJson(_blankLayout));
    await tester.pumpWidget(
      MaterialApp(
        home: GameScreen(
          controller: controller,
          connection: connection,
          decodeFrame: seam.call,
        ),
      ),
    );
    await tester.pump();
    return _Scene._(tester, controller, connection, seam);
  }

  final WidgetTester tester;
  final DesignerController controller;
  final MirrorConnection connection;

  /// The decoding seam the screen is wired to. Every frame the round renders
  /// comes through it, so a regression can hold one answer back and watch what
  /// the screen does with the round underneath.
  final _Decodes decodes;

  bool _closed = false;

  /// The game picker: the dropdown, then the item. Only reachable while no
  /// round is on screen, which is exactly when a round's game may change.
  Future<void> pick(String id) async {
    final picker = find.byKey(const ValueKey<String>('game-picker'));
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text(_name(id)).last);
    await tester.pumpAndSettle();
  }

  /// Start the selected game from the setup view.
  Future<void> start() async {
    final start = find.byKey(const ValueKey<String>('start-game'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
  }

  /// Open the app bar's overflow menu and take [item]: 'menu-restart',
  /// 'menu-choose', or 'menu-diagnostics'. The items live in the tree only
  /// while the menu is open, so this is the only way to reach them.
  Future<void> menu(String item) async {
    await tester.tap(find.byKey(const ValueKey<String>('game-menu')));
    await _pumpFor(tester);
    await tester.tap(find.byKey(ValueKey<String>(item)));
    await _pumpFor(tester);
  }

  /// Answer the question that guards a nonterminal round: Cancel keeps it,
  /// Discard throws it away.
  Future<void> answerDiscard({required bool discard}) async {
    expect(find.byKey(const ValueKey<String>('discard-round-dialog')),
        findsOneWidget);
    await tester.tap(find.byKey(
        ValueKey<String>(discard ? 'discard-confirm' : 'discard-cancel')));
    await _pumpFor(tester);
  }

  /// Start the round on screen over: the overflow menu's Restart, confirmed.
  Future<void> restart() async {
    await menu('menu-restart');
    await answerDiscard(discard: true);
  }

  /// Leave the round for the picker: the overflow menu's Choose game,
  /// confirmed. Stop is gone from the play surface, so this is the way out.
  Future<void> chooseGame() async {
    await menu('menu-choose');
    await answerDiscard(discard: true);
  }

  /// The app bar's Pause/Resume: the same one toggle as the P key, and the
  /// state it lands in is visible through [paused].
  Future<void> togglePause() async {
    await tester.tap(find.byKey(const ValueKey<String>('game-pause')));
    await tester.pump();
  }

  /// Whether the round on screen is frozen: the paused view's own actions are
  /// up, and they exist only while it is paused.
  bool get paused =>
      find.byKey(const ValueKey<String>('round-resume')).evaluate().isNotEmpty;

  /// One ticker frame, with the real decode given a chance to land. The pump
  /// pair is the screen's own frame cadence: 25 ms of wall time, then the
  /// frame the decoded image is drawn on.
  Future<void> frame([int milliseconds = 25]) async {
    await tester.pump(Duration(milliseconds: milliseconds));
    await tester.runAsync(() => Future<void>.delayed(_decodeSettle));
    await tester.pump();
  }

  /// A frame the round has not aged into: the same decode chance as [frame],
  /// with no time on the clock. Two runs that each stop here show the board
  /// their engine was dealt, which is how a new session's opening position is
  /// told from the one before it.
  Future<void> frameZero() async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(_decodeSettle));
    await tester.pump();
  }

  Future<void> advance(int frames) async {
    for (var i = 0; i < frames; i++) {
      await frame();
    }
  }

  Finder pad(String wire) => find.byKey(ValueKey<String>('control-$wire'));

  Offset padCenter(String wire) => tester.getCenter(pad(wire));

  /// The newest frame the screen handed to the seam: the RGBA8888 buffer the
  /// native game rendered. A decode that is still in flight has been asked for
  /// but not drawn, so [displayed] rather than this is what the player sees;
  /// [displayedIndex] ties the two together.
  Uint8List pixels() => decodes.latest;

  /// The frame the player is looking at: the bytes of the decode the screen
  /// accepted, read off the painter that draws them. While an answer is being
  /// withheld this is the frame before it, which is the whole point of asking.
  Uint8List displayed() {
    final dynamic painter = _gamePainter();
    return Uint8List.fromList(painter.frame as Uint8List);
  }

  /// The image the panel is drawing. Identity rather than bytes: two frames of
  /// a slow game can be identical pixel for pixel, and the question this
  /// answers is which frame the screen kept, not what it looks like.
  ui.Image? displayedImage() => _gamePainter()?.image as ui.Image?;

  /// The play surface's painter, which is where the accepted frame lives: its
  /// image and its bytes are set together from the decode the screen kept.
  dynamic _gamePainter() => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .where((paint) => paint.painter.runtimeType.toString() == '_GamePainter')
      .firstOrNull
      ?.painter;

  /// Where the frame on the panel came from: the index, in the seam's log, of
  /// the newest frame the screen asked to decode that is the same as the one it
  /// is drawing. -1 when the panel is showing a frame the seam was never asked
  /// for, which would mean the screen invented one.
  int displayedIndex() {
    final Uint8List shown = displayed();
    for (var i = decodes.requests.length - 1; i >= 0; i--) {
      if (_sameFrame(decodes.requests[i].bytes, shown)) return i;
    }
    return -1;
  }

  /// Whether the round on screen has finished: its own actions are up.
  bool get terminal => find
      .byKey(const ValueKey<String>('over-play-again'))
      .evaluate()
      .isNotEmpty;

  /// Whether the play surface is showing a render failure rather than a panel.
  bool get failed =>
      find.byKey(const ValueKey<String>('play-error')).evaluate().isNotEmpty;

  /// Hold the answer to the next frame the round submits.
  void holdNext() => decodes.holdNext();

  /// Answer the held frame with a real image of the bytes it asked for, and let
  /// the screen's own completion run. The image comes back so the caller can
  /// see whether the screen kept it or threw it away.
  ///
  /// The decode is started and then drained in real time rather than awaited
  /// directly: it is answered off the frame cadence, and waiting on the future
  /// inside [WidgetTester.runAsync] can wait for a completion that the test's
  /// own clock never delivers. The pump afterwards is what draws the result.
  Future<ui.Image> releaseHeld() async {
    ui.Image? image;
    await tester.runAsync(() async {
      unawaited(decodes.release().then<void>((ui.Image decoded) {
        image = decoded;
      }));
      for (var waited = Duration.zero;
          waited < const Duration(seconds: 1) && image == null;
          waited += _decodeSettle) {
        await Future<void>.delayed(_decodeSettle);
      }
    });
    await tester.pump();
    if (image == null) {
      throw StateError('the held frame was never decoded');
    }
    return image!;
  }

  /// Answer a decode a script left parked, so no future is left hanging.
  Future<void> answerHeld() async {
    if (decodes.held == null) return;
    await releaseHeld();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
    connection.dispose();
  }
}

/// Open a scene, run [script], and tear the scene down again even if the
/// script throws.
///
/// Teardown is exhaustive: a decode the script left parked is answered, and
/// whatever the screen went away holding is counted and released rather than
/// leaked into the next test. A regression asserts [decodes.leaked] is zero, so
/// the count is what tells a screen that cleaned up from one that did not.
Future<void> _scene(
  WidgetTester tester,
  Future<void> Function(_Scene scene) script, {
  Size surface = const Size(1000, 600),
  double textScale = 1,
  double inset = 0,
  _Decodes? decodes,
}) async {
  final scene = await _Scene.open(
    tester,
    surface: surface,
    textScale: textScale,
    inset: inset,
    decodes: decodes,
  );
  try {
    await script(scene);
  } finally {
    await scene.close();
    await scene.answerHeld();
    scene.decodes.disposeLeftovers();
  }
}

/// Play an Invaders round with [touches] held at their scripted frames, and
/// return the panel it ends on.
Future<Uint8List> _invaders(
  WidgetTester tester,
  List<_Touch> touches, {
  int frames = 12,
}) async {
  late Uint8List panel;
  await _scene(tester, (scene) async {
    await scene.pick('invaders');
    await scene.start();
    final live = <_Touch, TestGesture>{};
    for (var frame = 0; frame < frames; frame++) {
      for (final touch in touches) {
        if (touch.down == frame) {
          live[touch] = await tester.startGesture(scene.padCenter(touch.wire));
        }
      }
      await scene.frame();
    }
    panel = scene.pixels();
    for (final gesture in live.values) {
      await gesture.up();
    }
  });
  return panel;
}

/// Play the second local Tetris round - seed 2, the T piece; seed 1 deals the
/// rotation-invariant O - and press Rotate [presses] times between two ticks.
/// The first round is restarted out of the way, which deals the second.
/// [held] presses once and keeps the key down, which is what a thumb and a
/// repeating keyboard both do.
Future<Uint8List> _tetris(
  WidgetTester tester, {
  required int presses,
  bool held = false,
}) async {
  late Uint8List panel;
  await _scene(tester, (scene) async {
    await scene.pick('tetris');
    await scene.start();
    await scene.restart();
    await scene.advance(4);
    if (held) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      }
    } else {
      for (var i = 0; i < presses; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      }
    }
    await scene.advance(6);
    panel = scene.pixels();
  });
  return panel;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a held Space does not restart a live Snake round',
      (tester) async {
    late Uint8List plain;
    await _scene(tester, (scene) async {
      await scene.pick('snake');
      await scene.start();
      await scene.advance(12);
      plain = scene.pixels();
    });

    late Uint8List withSpace;
    await _scene(tester, (scene) async {
      await scene.pick('snake');
      await scene.start();
      await scene.advance(6);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      }
      await scene.advance(6);
      withSpace = scene.pixels();

      // ...and keys do reach this round: P is the same handler path and it
      // pauses it. Without this the equality above could hold because nothing
      // was listening at all.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
      await scene.advance(1);
      expect(scene.paused, isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    });

    // Snake declares no Shoot, so Space while a round is live is not an
    // action and not a start: the round must be exactly where it was.
    expect(withSpace, orderedEquals(plain));

    // The comparison is only worth something if a restart shows up in the
    // panel, so the explicit Restart - asked for and confirmed - must deal a
    // round that is not the one that was on screen.
    late Uint8List beforeRestart;
    late Uint8List restarted;
    await _scene(tester, (scene) async {
      await scene.pick('snake');
      await scene.start();
      await scene.advance(6);
      beforeRestart = scene.pixels();
      await scene.restart();
      await scene.advance(6);
      restarted = scene.pixels();
    });
    expect(restarted, isNot(orderedEquals(beforeRestart)));
  });

  testWidgets(
      'Space starts an idle game from the key-down, and a held key never restarts it',
      (tester) async {
    late Uint8List held;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');

      // Invaders declares a Shoot control, and nothing is running: Space is
      // the start here, not a fire into a round that does not exist.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      }
      await scene.advance(10);
      expect(find.byKey(const ValueKey<String>('start-game')), findsNothing);
      expect(scene.pad('Left'), findsOneWidget);
      expect(scene.pad('Right'), findsOneWidget);
      expect(scene.pad('Shoot'), findsOneWidget);
      held = scene.pixels();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    });

    late Uint8List tapped;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await scene.advance(10);
      tapped = scene.pixels();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    });

    // The repeats are the same key still held: they press nothing into the
    // round and never start a second one over the first.
    expect(held, orderedEquals(tapped));
  });

  testWidgets('Space fires while a round with a Shoot control is playing',
      (tester) async {
    late Uint8List quiet;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      await scene.advance(6);
      quiet = scene.pixels();
    });

    late Uint8List fired;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      await scene.advance(6);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await scene.advance(4);
      fired = scene.pixels();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    });

    expect(fired, isNot(orderedEquals(quiet)));
  });

  testWidgets(
      'a Rotate press and release between ticks is exactly one rotation',
      (tester) async {
    final none = await _tetris(tester, presses: 0);
    final one = await _tetris(tester, presses: 1);
    final two = await _tetris(tester, presses: 2);
    final heldOne = await _tetris(tester, presses: 1, held: true);

    // The press must reach the engine on its own edge: no tick separates the
    // down from the up, so a screen that sampled held state once per frame
    // would send nothing.
    expect(one, isNot(orderedEquals(none)));
    expect(two, isNot(orderedEquals(none)));

    // The release re-arms the next press, and only the press rotates - the
    // full held state sent every tick, and the key repeat, do not spin the
    // piece again.
    expect(two, isNot(orderedEquals(one)));
    expect(heldOne, orderedEquals(one));
  });

  testWidgets('movement and Shoot are held at once by two pointers',
      (tester) async {
    final leftOnly = await _invaders(tester, const <_Touch>[_Touch('Left', 0)]);
    final shootOnly =
        await _invaders(tester, const <_Touch>[_Touch('Shoot', 0)]);
    final both = await _invaders(
      tester,
      const <_Touch>[_Touch('Left', 0), _Touch('Shoot', 0)],
    );

    // Neither pointer may cancel the other: a single-source pad would leave
    // one of these frames equal to the run that never held the second control.
    expect(both, isNot(orderedEquals(leftOnly)));
    expect(both, isNot(orderedEquals(shootOnly)));
  });

  testWidgets('releasing one of two sources leaves the other holding',
      (tester) async {
    late Uint8List silent;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      await scene.advance(10);
      silent = scene.pixels();
    });

    late Uint8List keyOnly;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await scene.advance(10);
      keyOnly = scene.pixels();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    });
    expect(keyOnly, isNot(orderedEquals(silent)));

    // The pointer arrives and leaves while the key stays down.
    late Uint8List keyKept;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      final TestGesture pointer =
          await tester.startGesture(scene.padCenter('Left'));
      await scene.advance(5);
      await pointer.up();
      await scene.advance(5);
      keyKept = scene.pixels();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    });
    expect(keyKept, orderedEquals(keyOnly));

    late Uint8List pointerOnly;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      final TestGesture pointer =
          await tester.startGesture(scene.padCenter('Left'));
      await scene.advance(10);
      pointerOnly = scene.pixels();
      await pointer.up();
    });
    expect(pointerOnly, isNot(orderedEquals(silent)));

    // ...and the other way round: the key leaves, the pointer stays.
    late Uint8List pointerKept;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      final TestGesture pointer =
          await tester.startGesture(scene.padCenter('Left'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await scene.advance(5);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await scene.advance(5);
      pointerKept = scene.pixels();
      await pointer.up();
    });
    expect(pointerKept, orderedEquals(pointerOnly));
  });

  testWidgets('cancelling a pointer releases the control it held',
      (tester) async {
    late Uint8List steering;
    late Uint8List released;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      final TestGesture pointer =
          await tester.startGesture(scene.padCenter('Left'));
      await scene.advance(5);
      steering = scene.pixels();
      await pointer.up();
      await scene.advance(5);
      released = scene.pixels();
    });

    // Holding the pad steers the round, so the pointer really is on it, and
    // letting it go leaves the round where it stands.
    late Uint8List quiet;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      await scene.advance(5);
      quiet = scene.pixels();
    });
    expect(steering, isNot(orderedEquals(quiet)));

    late Uint8List cancelled;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      final TestGesture pointer =
          await tester.startGesture(scene.padCenter('Left'));
      await scene.advance(5);
      await pointer.cancel();
      await scene.advance(5);
      cancelled = scene.pixels();
    });
    // A cancelled pointer releases what it held, exactly like a pointer-up.
    expect(cancelled, orderedEquals(released));
  });

  testWidgets('sliding off the movement pad neither steers nor fires',
      (tester) async {
    late Uint8List steering;
    late Uint8List released;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      final TestGesture pointer =
          await tester.startGesture(scene.padCenter('Left'));
      await scene.advance(5);
      steering = scene.pixels();
      await pointer.up();
      await scene.advance(5);
      released = scene.pixels();
    });

    late Uint8List quiet;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      await scene.advance(5);
      quiet = scene.pixels();
    });
    expect(steering, isNot(orderedEquals(quiet)));

    late Uint8List slid;
    await _scene(tester, (scene) async {
      await scene.pick('invaders');
      await scene.start();
      final TestGesture pointer =
          await tester.startGesture(scene.padCenter('Left'));
      await scene.advance(5);
      await pointer.moveTo(scene.padCenter('Shoot'));
      await scene.advance(5);
      slid = scene.pixels();
      await pointer.up();
    });

    // Leaving the movement pad's rectangles is neutral, and an action button
    // is not armed by sliding into it.
    expect(slid, orderedEquals(released));
  });

  testWidgets(
      'an accessibility activation holds a movement control across a tick',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      late Uint8List still;
      await _scene(tester, (scene) async {
        await scene.pick('rally');
        await scene.start();
        await scene.advance(10);
        still = scene.pixels();
      });

      late Uint8List moved;
      await _scene(tester, (scene) async {
        await scene.pick('rally');
        await scene.start();
        await scene.advance(4);
        tester.semantics.tap(find.semantics.byPredicate(
          (SemanticsNode node) =>
              node.label == 'Up' &&
              node.getSemanticsData().hasAction(SemanticsAction.tap),
        ));
        await scene.advance(6);
        moved = scene.pixels();
      });

      // Rally's paddle only moves while Up is held, so this moves at all only
      // because a discrete activation spans a game tick instead of being an
      // immediate press and release.
      expect(moved, isNot(orderedEquals(still)));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Pause freezes the native frame and Resume continues the round',
      (tester) async {
    late Uint8List paused;
    late Uint8List resumedAfterWait;
    await _scene(tester, (scene) async {
      await scene.pick('rally');
      await scene.start();
      await scene.advance(8);
      await scene.togglePause();
      await scene.frame();
      expect(scene.paused, isTrue);
      paused = scene.pixels();

      // Five seconds of pause: the board must not move on, and the engine
      // must not have been stepped at all.
      await scene.frame(5000);
      expect(scene.pixels(), orderedEquals(paused));

      await scene.togglePause();
      await scene.frame();
      expect(scene.paused, isFalse);
      resumedAfterWait = scene.pixels();
    });

    late Uint8List resumedAtOnce;
    await _scene(tester, (scene) async {
      await scene.pick('rally');
      await scene.start();
      await scene.advance(8);
      await scene.togglePause();
      await scene.frame();
      await scene.togglePause();
      await scene.frame();
      resumedAtOnce = scene.pixels();
    });

    // The time spent paused is not simulated as elapsed time: resuming after
    // five seconds is the same frame as resuming at once, with no catch-up
    // jump to make up for it.
    expect(resumedAfterWait, orderedEquals(resumedAtOnce));
  });

  testWidgets('a live round carries on after Resume', (tester) async {
    await _scene(tester, (scene) async {
      await scene.pick('rally');
      await scene.start();
      await scene.advance(8);
      await scene.togglePause();
      await scene.frame();
      final Uint8List paused = scene.pixels();
      await scene.togglePause();
      await scene.advance(8);
      expect(scene.pixels(), isNot(orderedEquals(paused)));
    });
  });

  testWidgets(
      'cancelling the discard question keeps the round paused where it was',
      (tester) async {
    late Uint8List asked;
    late Uint8List cancelled;
    await _scene(tester, (scene) async {
      await scene.pick('tetris');
      await scene.start();
      await scene.advance(6);

      // Restart asks once while a round is on screen. Asking is what paused
      // it, so the board stops while the question is up.
      await scene.menu('menu-restart');
      expect(find.byKey(const ValueKey<String>('discard-round-dialog')),
          findsOneWidget);
      asked = scene.pixels();

      await scene.answerDiscard(discard: false);
      expect(scene.paused, isTrue,
          reason: 'Cancel leaves the round paused, not running');
      cancelled = scene.pixels();

      // Five seconds later it is the same board: nothing was reset and
      // nothing was stepped.
      await scene.frame(5000);
      expect(scene.pixels(), orderedEquals(asked));
    });
    expect(cancelled, orderedEquals(asked));
  });

  testWidgets(
      'a confirmed Restart deals a fresh round instead of the paused one',
      (tester) async {
    // What the first round is dealt, before anything has stepped it.
    late Uint8List firstDeal;
    await _scene(tester, (scene) async {
      await scene.pick('tetris');
      await scene.start();
      await scene.frameZero();
      firstDeal = scene.pixels();
    });

    late Uint8List asked;
    late Uint8List secondDeal;
    await _scene(tester, (scene) async {
      await scene.pick('tetris');
      await scene.start();
      await scene.advance(6);
      await scene.togglePause();
      asked = scene.pixels();

      // The paused view's Restart asks the same question, and asking does not
      // touch the board it is asking about.
      await tester.tap(find.byKey(const ValueKey<String>('round-restart')));
      await _pumpFor(tester, const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey<String>('discard-round-dialog')),
          findsOneWidget);
      expect(scene.pixels(), orderedEquals(asked));

      // Confirming deals the next session, and it is given exactly the frames
      // the first run above gave its own fresh round: same age, so the only
      // thing left that can tell the two boards apart is the deal.
      await tester.tap(find.byKey(const ValueKey<String>('discard-confirm')));
      await tester.pump();
      await scene.frameZero();
      secondDeal = scene.pixels();
    });

    // The confirmed answer deals the round again from the top - not the board
    // that was on screen - and it is a new session rather than the same one
    // replayed: at the same age, the second seed's piece is not the first
    // seed's. (The rotation regressions above rest on that same seed order.)
    expect(secondDeal, isNot(orderedEquals(asked)));
    expect(secondDeal, isNot(orderedEquals(firstDeal)));
  });

  testWidgets('Choose game asks once and the confirmed answer returns to setup',
      (tester) async {
    await _scene(tester, (scene) async {
      await scene.pick('rally');
      await scene.start();
      await scene.advance(6);

      // Cancelled: still the same round, still on screen, frozen.
      await scene.menu('menu-choose');
      final Uint8List asked = scene.pixels();
      await scene.answerDiscard(discard: false);
      expect(scene.paused, isTrue);
      expect(scene.pixels(), orderedEquals(asked));

      // The paused view offers the same way out, and it asks the same
      // question before it throws the round away.
      await tester.tap(find.byKey(const ValueKey<String>('round-choose')));
      await _pumpFor(tester);
      await scene.answerDiscard(discard: true);

      // The picker is back, and the round with it is gone rather than left
      // running behind the setup view.
      expect(find.byKey(const ValueKey<String>('start-game')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('game-picker')), findsOneWidget);
      expect(scene.paused, isFalse);
      expect(scene.pad(_wires('rally').first), findsNothing);
    });
  });

  testWidgets('Help pauses the round and leaves it paused when it closes',
      (tester) async {
    late Uint8List reading;
    late Uint8List afterClose;
    await _scene(tester, (scene) async {
      await scene.pick('snake');
      await scene.start();
      await scene.advance(6);

      await tester.tap(find.byKey(const ValueKey<String>('game-help')));
      await _pumpFor(tester);
      expect(find.byKey(const ValueKey<String>('game-help-sheet')),
          findsOneWidget);

      // Nothing runs behind the sheet: five seconds of reading is five
      // seconds of a frozen board.
      reading = scene.pixels();
      await scene.frame(5000);
      expect(scene.pixels(), orderedEquals(reading));

      // Dismissing the sheet is not a resume: the round waits for the player
      // to ask for it, and the paused view is what says so.
      await tester.tapAt(const Offset(4, 4));
      await _pumpFor(tester);
      expect(
          find.byKey(const ValueKey<String>('game-help-sheet')), findsNothing);
      expect(scene.paused, isTrue);
      await scene.advance(6);
      afterClose = scene.pixels();
    });
    expect(afterClose, orderedEquals(reading));
  });

  testWidgets('diagnostics stay closed while playing and open from the menu',
      (tester) async {
    await _scene(tester, (scene) async {
      await scene.pick('rally');
      await scene.start();
      await scene.advance(6);

      // Playing shows the round and its controls: the panel size, the display
      // settings, and the link numbers wait in a sheet nobody opened.
      expect(find.byKey(const ValueKey<String>('diagnostics-sheet')),
          findsNothing);
      expect(find.text('veneer'), findsNothing);
      expect(scene.pad('Up'), findsOneWidget);

      await scene.menu('menu-diagnostics');
      expect(find.byKey(const ValueKey<String>('diagnostics-sheet')),
          findsOneWidget);
      expect(find.text('veneer'), findsOneWidget);
      await scene.frameZero();
      final Uint8List frozen = scene.pixels();

      await tester.tapAt(const Offset(4, 4));
      await _pumpFor(tester);
      expect(find.byKey(const ValueKey<String>('diagnostics-sheet')),
          findsNothing);
      expect(scene.paused, isTrue, reason: 'closing the sheet is not a resume');
      await scene.advance(4);
      expect(scene.pixels(), orderedEquals(frozen));

      // ...and the round it paused is still there to resume.
      await scene.togglePause();
      expect(scene.pad('Up'), findsOneWidget);
    });
  });

  testWidgets('motion steers the preview: the probe dot follows the phone',
      (tester) async {
    // The whole tilt path in the app's own preview: neutral from the
    // accelerometer, the app's angle-to-position mapping, the native round,
    // and the pixels the dot is drawn with. Before this, motion mode was
    // mirror-only, so a preview round could not be steered by the phone at all
    // and the probe's readouts sat pinned at zero.
    const sensorChannel = 'dev.fluttercommunity.plus/sensors/accelerometer';
    const sensorMethods = MethodChannel('dev.fluttercommunity.plus/sensors/method');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(sensorMethods, (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel(sensorChannel), (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(sensorMethods, null);
      messenger.setMockMethodCallHandler(
          const MethodChannel(sensorChannel), null);
    });

    Future<void> sample(WidgetTester t, double x, double y, double z) async {
      await t.binding.defaultBinaryMessenger.handlePlatformMessage(
          sensorChannel,
          const StandardMethodCodec()
              .encodeSuccessEnvelope(<double>[x, y, z, 0]),
          (_) {});
      await t.pump(const Duration(milliseconds: 20));
    }

    await _scene(tester, (scene) async {
      await scene.pick('probe');
      await tester.tap(find.byKey(const ValueKey<String>('mode-motion')));
      await tester.pump();
      await scene.start();

      // Neutral first: hold the phone still and the round starts from it.
      expect(find.text('Hold the phone still'), findsOneWidget);
      for (var i = 0; i < 20; i++) {
        await sample(tester, 0, 0, 9.8);
      }
      await scene.advance(2);
      expect(find.text('Hold the phone still'), findsNothing);
      await sample(tester, 0, 0, 9.8);
      await scene.advance(2);
      final Offset centre = _redDotCentre(scene.pixels());
      expect(centre.dx, closeTo(31, 2), reason: 'neutral centres the dot');
      expect(centre.dy, closeTo(15, 2), reason: 'neutral centres the dot');

      // Rolled right: the dot goes right, and holding that angle holds it
      // there rather than driving it into the edge.
      for (var i = 0; i < 12; i++) {
        await sample(tester, 0, 5, 9.8);
      }
      await scene.advance(2);
      final Offset right = _redDotCentre(scene.pixels());
      expect(right.dx, greaterThan(centre.dx + 10),
          reason: 'a roll moves the dot the way the phone went');
      for (var i = 0; i < 12; i++) {
        await sample(tester, 0, 5, 9.8);
      }
      await scene.advance(2);
      expect(_redDotCentre(scene.pixels()).dx, closeTo(right.dx, 1),
          reason: 'a held angle holds the position');

      // Tipped up: the vertical axis is a position too. The canvas axis runs
      // downwards, so up is a smaller y.
      for (var i = 0; i < 12; i++) {
        await sample(tester, 5, 0, 9.8);
      }
      await scene.advance(2);
      expect(_redDotCentre(scene.pixels()).dy, lessThan(right.dy - 4),
          reason: 'tipping the phone up moves the dot up');
    });
  });

  for (final Size surface in const <Size>[Size(640, 360), Size(800, 360)]) {
    testWidgets(
        'every control of every game is reachable and labelled on '
        '${surface.width.toInt()}x${surface.height.toInt()} with safe-area '
        'insets at 1.5x text', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _scene(
          tester,
          (scene) async {
            for (final String id in const <String>[
              'rally',
              'snake',
              'tetris',
              'breakout',
              'invaders',
              // The tilt visualiser is picked like any other game: it is how a
              // player sees what motion control is doing.
              'probe',
            ]) {
              await scene.pick(id);
              final Finder startButton =
                  find.byKey(const ValueKey<String>('start-game'));
              expect(startButton, findsOneWidget, reason: '$id setup');
              await tester.ensureVisible(startButton);
              await tester.pump();
              expect(_onScreen(tester.getRect(startButton), surface), isTrue,
                  reason: '$id Start Game must be on screen');

              await scene.start();
              await scene.advance(3);
              expect(startButton, findsNothing, reason: '$id started');
              // A live round keeps Pause and Help on the app bar; Restart and
              // Choose game live behind the overflow menu.
              final Finder pause =
                  find.byKey(const ValueKey<String>('game-pause'));
              final Finder help =
                  find.byKey(const ValueKey<String>('game-help'));
              expect(pause, findsOneWidget, reason: '$id pause');
              expect(help, findsOneWidget, reason: '$id help');
              expect(_onScreen(tester.getRect(pause), surface), isTrue,
                  reason: '$id pause on screen');
              expect(_onScreen(tester.getRect(help), surface), isTrue,
                  reason: '$id help on screen');
              expect(tester.takeException(), isNull, reason: '$id overflow');

              for (final String wire in _wires(id)) {
                if (_axisWires(id).contains(wire)) {
                  // An axis is not a pad: it is the phone's tilt, so it shows
                  // as a readout with no tap target of its own.
                  final Finder readout =
                      find.byKey(ValueKey<String>('axis-$wire'));
                  expect(readout, findsOneWidget, reason: '$id $wire readout');
                  final SemanticsData axis =
                      _semantics('$wire axis').getSemanticsData();
                  expect(axis.flagsCollection.isButton, isFalse,
                      reason: '$id $wire is not a button');
                  continue;
                }
                final Finder pad = scene.pad(wire);
                expect(pad, findsOneWidget, reason: '$id $wire pad');
                final Rect rect = tester.getRect(pad);
                expect(rect.shortestSide, greaterThanOrEqualTo(48.0),
                    reason: '$id $wire is a tap target');
                expect(_onScreen(rect, surface), isTrue,
                    reason: '$id $wire on screen');
                final SemanticsData data =
                    _semantics(_alias(id, wire)).getSemanticsData();
                expect(data.flagsCollection.isButton, isTrue,
                    reason: '$id $wire is a button');
                expect(data.hasAction(SemanticsAction.tap), isTrue,
                    reason: '$id $wire can be activated');
              }

              // The paused view's own actions - the way back into the round,
              // the way to start it over, and the way out - stay reachable on
              // the same surface, and nothing overflows while they show.
              await scene.togglePause();
              await scene.advance(1);
              expect(scene.paused, isTrue, reason: '$id paused');
              for (final String key in const <String>[
                'round-resume',
                'round-restart',
                'round-choose',
              ]) {
                final Finder action = find.byKey(ValueKey<String>(key));
                expect(action, findsOneWidget, reason: '$id $key');
                await tester.ensureVisible(action);
                await tester.pump();
                expect(_onScreen(tester.getRect(action), surface), isTrue,
                    reason: '$id $key on screen');
              }
              expect(tester.takeException(), isNull,
                  reason: '$id paused overflow');

              await scene.togglePause();
              await scene.advance(1);
              expect(scene.paused, isFalse, reason: '$id resumed');
              expect(scene.pad(_wires(id).first), findsOneWidget,
                  reason: '$id controls are back after Resume');
              expect(tester.takeException(), isNull,
                  reason: '$id resumed overflow');

              // Choose game is the way out of a round: it asks once, and the
              // confirmed answer puts the picker back.
              await scene.chooseGame();
              await scene.advance(1);
              expect(startButton, findsOneWidget, reason: '$id back at setup');
              expect(scene.pad(_wires(id).first), findsNothing,
                  reason: '$id round is gone');
              expect(tester.takeException(), isNull,
                  reason: '$id discarded overflow');
            }
          },
          surface: surface,
          textScale: 1.5,
          inset: 48,
        );
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
      'a frame decoded across a restart never draws over the round that replaced it',
      (tester) async {
    final decodes = _Decodes();
    late Uint8List abandoned;
    await _scene(
      tester,
      (scene) async {
        await scene.pick('tetris');
        await scene.start();
        await scene.advance(6);
        final Uint8List playing = scene.displayed();

        // The screen asks for a frame and the test keeps the answer back: this
        // is the decode that will still be in flight when the round is
        // restarted.
        scene.holdNext();
        await scene.frame();
        expect(scene.decodes.held, isNotNull,
            reason: 'the frame the round asked for is held back');
        abandoned = scene.pixels();
        final int asked = scene.decodes.asked;
        expect(scene.displayed(), orderedEquals(playing),
            reason: 'a frame that has not been decoded is not on the panel');

        // Restart: the round that asked for the frame is gone and its decode is
        // unanswered. The slot that decode occupies is not freed by the round it
        // belonged to, so the new round cannot decode until the answer arrives.
        await scene.restart();
        await scene.advance(6);
        expect(scene.decodes.asked, asked,
            reason: 'the decode slot stays taken until the answer arrives');

        // Pause the new round before answering. A paused round asks for nothing
        // more, so the answer cannot be covered up by a frame the new round
        // decodes straight after it - whatever the panel shows when the answer
        // lands is what the screen did with that answer.
        await scene.togglePause();
        expect(scene.paused, isTrue);

        // The answer arrives, for the round that is gone. It is thrown away,
        // and the panel is not showing it.
        final ui.Image stale = await scene.releaseHeld();
        expect(stale.debugDisposed, isTrue,
            reason: 'a frame from the round that is gone is disposed');
        expect(identical(scene.displayedImage(), stale), isFalse,
            reason: 'the abandoned frame never reaches the panel');
        expect(scene.decodes.asked, asked,
            reason: 'answering it decodes nothing for the paused round');

        // Resume: the restarted round draws its own frames again, and none of
        // them is the frame that was abandoned.
        await scene.togglePause();
        expect(scene.paused, isFalse);
        await scene.advance(4);
        expect(scene.pixels(), isNot(orderedEquals(abandoned)),
            reason: 'the restarted round has moved past the abandoned frame');
        expect(scene.displayedIndex(), greaterThan(asked - 1),
            reason: 'the panel is showing a frame of the restarted round');
        expect(scene.terminal, isFalse);
      },
      decodes: decodes,
    );
    expect(decodes.leaked, 0,
        reason: 'no image outlives the round that drew it');
  });

  testWidgets(
      'a decode that began before Pause is thrown away even when Resume lands first',
      (tester) async {
    final decodes = _Decodes();
    await _scene(
      tester,
      (scene) async {
        await scene.pick('rally');
        await scene.start();
        await scene.advance(8);
        final Uint8List playing = scene.displayed();

        scene.holdNext();
        await scene.frame();
        final int asked = scene.decodes.asked;
        expect(scene.decodes.held, isNotNull);

        // Pause with the decode still in flight: the panel keeps the frame the
        // pause froze, and a paused round asks for nothing more.
        await scene.togglePause();
        expect(scene.paused, isTrue);
        expect(scene.displayed(), orderedEquals(playing),
            reason: 'the pause froze the frame that was already decoded');
        await scene.frame(2000);
        expect(scene.decodes.asked, asked,
            reason: 'a paused round wants no frames');
        expect(scene.displayed(), orderedEquals(playing),
            reason: 'the frozen frame is still the one on the panel');

        // Resume before the answer arrives, and hold the frame the resumed
        // round asks for as well: with nothing drawn behind it, whatever the
        // panel shows when the answer lands is what the screen did with that
        // answer.
        await tester.tap(find.byKey(const ValueKey<String>('game-pause')));
        scene.holdNext();
        final ui.Image before = await scene.releaseHeld();
        expect(scene.paused, isFalse, reason: 'the tap resumed the round');
        expect(before.debugDisposed, isTrue,
            reason: 'a frame from before the pause is thrown away');
        expect(identical(scene.displayedImage(), before), isFalse,
            reason:
                'the pre-pause frame is not the image put back on the panel');
        expect(scene.decodes.held, isNotNull,
            reason: 'the resumed round is asking for a frame of its own');
        await scene.releaseHeld();
        await scene.frame();
        expect(scene.decodes.asked, greaterThan(asked),
            reason: 'the resumed round decodes again');
        expect(scene.displayedIndex(), greaterThan(asked - 1),
            reason: 'the panel is showing a frame the resumed round decoded');
      },
      decodes: decodes,
    );
    expect(decodes.leaked, 0);
  });

  testWidgets('the round keeps simulating while its frame waits to be decoded',
      (tester) async {
    final decodes = _Decodes();
    await _scene(
      tester,
      (scene) async {
        await scene.pick('snake');
        await scene.start();
        await scene.advance(6);
        final Uint8List showing = scene.displayed();

        scene.holdNext();
        await scene.frame();
        expect(scene.decodes.held, isNotNull);
        final _Request waiting = scene.decodes.requests.last;
        final int asked = scene.decodes.asked;
        final int ticks = waiting.engine.tick;

        // However far the round runs, the decoder is not handed a backlog: the
        // slot stays taken until the answer arrives, and the game goes on
        // without it.
        await scene.advance(8);
        expect(scene.decodes.asked, asked,
            reason: 'one decode in flight, not one per simulated frame');
        expect(waiting.engine.tick, greaterThan(ticks),
            reason: 'the round keeps simulating while its frame waits');
        expect(scene.displayed(), orderedEquals(showing),
            reason: 'the panel keeps the last frame it decoded');

        // The answer frees the slot, and what is decoded then is the state the
        // round has reached rather than the frame that waited.
        final ui.Image superseded = await scene.releaseHeld();
        await scene.frame();
        expect(scene.pixels(), isNot(orderedEquals(waiting.bytes)),
            reason: 'the round moved on while its frame waited');
        expect(scene.displayedIndex(), greaterThan(asked - 1),
            reason: 'the panel is showing a frame decoded once the slot freed');
        expect(superseded.debugDisposed, isTrue,
            reason: 'a frame the round has moved past is disposed');
      },
      decodes: decodes,
    );
    expect(decodes.leaked, 0);
  });

  testWidgets('a finished round decodes its last frame once and then stops',
      (tester) async {
    await _scene(tester, (scene) async {
      await scene.pick('snake');
      await scene.start();

      // Nothing steers the snake off the line it starts on, so it runs into the
      // wall and the round ends by itself. Each pump is a hundred milliseconds
      // of the game's clock, which is a cell.
      var pumps = 0;
      while (!scene.terminal && pumps < 120) {
        await scene.frame(100);
        pumps++;
      }
      expect(scene.terminal, isTrue,
          reason: 'the snake reaches the wall and the round finishes');
      // One more frame for the ending to be drawn on: the round has stopped,
      // so this only gives the last decode its chance to land.
      await scene.frame(100);

      final Uint8List finished = scene.pixels();
      final int asked = scene.decodes.asked;
      final _Request ending = scene.decodes.requests.last;
      final int ticks = ending.engine.tick;
      expect(scene.displayed(), orderedEquals(finished),
          reason: 'the board the round ended on is what is on screen');
      expect(
        scene.decodes.requests
            .where((_Request request) => _sameFrame(request.bytes, finished))
            .length,
        1,
        reason: 'the frame the round ended on is decoded once',
      );

      // Nothing runs on behind the ending: no more frames are asked for, the
      // round is not stepped again, and the finished board stays put.
      await scene.advance(20);
      expect(scene.decodes.asked, asked,
          reason: 'a finished round asks for no more frames');
      expect(ending.engine.tick, ticks,
          reason: 'a finished round is not stepped again');
      expect(scene.displayed(), orderedEquals(finished),
          reason: 'the finished board stays on screen');
      expect(scene.terminal, isTrue);
    });
  });

  testWidgets('a decode still in flight when the screen goes away is disposed',
      (tester) async {
    final decodes = _Decodes();
    await _scene(
      tester,
      (scene) async {
        await scene.pick('rally');
        await scene.start();
        await scene.advance(4);
        final ui.Image? showing = scene.decodes.answeredImage;
        expect(showing, isNotNull, reason: 'the round has a frame on screen');

        scene.holdNext();
        await scene.frame();
        expect(scene.decodes.held, isNotNull);

        // The screen is torn down while its decoder still owes it an answer.
        await scene.close();

        // The answer arrives afterwards. Nobody is left to draw it, and it is
        // still the screen's frame to dispose.
        final ui.Image orphaned = await scene.releaseHeld();
        await tester.pump();
        expect(orphaned.debugDisposed, isTrue,
            reason: 'a frame a screen that is gone asked for is disposed');
        expect(showing!.debugDisposed, isTrue,
            reason: 'the frame the round was showing is disposed with it');
        expect(tester.takeException(), isNull);
      },
      decodes: decodes,
    );
    expect(decodes.leaked, 0,
        reason: 'the screen released what it was holding when it went away');
  });

  testWidgets(
      'a decode that comes back empty offers a way back, not a blank panel',
      (tester) async {
    final decodes = _Decodes();
    await _scene(
      tester,
      (scene) async {
        await scene.pick('rally');
        await scene.start();
        await scene.advance(4);
        final ui.Image? showing = scene.decodes.answeredImage;
        expect(showing, isNotNull);

        // The decoder hands back nothing at all.
        scene.decodes.returnNullNext();
        await scene.frame();

        expect(scene.failed, isTrue,
            reason: 'a frame that could not be decoded says so');
        expect(scene.pad(_wires('rally').first), findsNothing,
            reason: 'a round that is not being drawn takes no input');
        expect(tester.takeException(), isNull);

        // The way back destroys the round and returns to setup...
        await tester.tap(find.byKey(const ValueKey<String>('play-error-back')));
        await _pumpFor(tester);
        expect(scene.failed, isFalse);
        expect(
            find.byKey(const ValueKey<String>('start-game')), findsOneWidget);
        expect(showing!.debugDisposed, isTrue,
            reason: 'the round and the frame it was showing are destroyed');

        // ...and playing again from there works.
        await scene.start();
        await scene.frame();
        expect(scene.failed, isFalse);
        expect(scene.pad(_wires('rally').first), findsOneWidget);
        expect(scene.displayedIndex(), greaterThanOrEqualTo(0),
            reason: 'the new round is drawing a frame it decoded');
      },
      decodes: decodes,
    );
    expect(decodes.leaked, 0);
  });

  testWidgets('a decode that throws is caught and offers the same way back',
      (tester) async {
    final decodes = _Decodes();
    await _scene(
      tester,
      (scene) async {
        await scene.pick('snake');
        await scene.start();
        await scene.advance(4);

        decodes.throwNext(StateError('the decoder fell over'));
        await scene.frame();

        expect(scene.failed, isTrue,
            reason: 'a decoder that throws leaves the failure surface up');
        expect(tester.takeException(), isNull,
            reason: 'a failed decode does not escape the screen');
        expect(scene.pad(_wires('snake').first), findsNothing);

        await tester.tap(find.byKey(const ValueKey<String>('play-error-back')));
        await _pumpFor(tester);
        expect(
            find.byKey(const ValueKey<String>('start-game')), findsOneWidget);
        expect(scene.failed, isFalse);
        expect(tester.takeException(), isNull);
      },
      decodes: decodes,
    );
    expect(decodes.leaked, 0);
  });
}
