// One playtest: the level being edited, handed to the real game and played.
//
// The session is opened the way the designer opens a round, against the same
// native library: the level's wire blob is injected first (ml_game_set_level),
// then the session is opened on it. Nothing is simulated here - the frames the
// panel shows are the game's own 64x32 RGBA8888 frames, which is the whole point
// of playing it in the editor rather than trusting a drawing of it.
//
// The game has no reset entry point, so a restart is a new session with the
// level injected again. That is what makes "play from here" work at all: it is
// the same level with a different start column.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:mirror_core_ffi/mirror_core_ffi.dart';

import 'jump_level.dart';
import 'jumpman_spec.dart';
import 'wire.dart';

/// The game this editor hands levels to.
const String kJumpmanGameId = 'jumpman';

/// The frame a jumpman session renders: what the mirror's panel shows.
const int kPanelWidth = 64;
const int kPanelHeight = 32;

/// Jumpman's input codes, from its own control table (JM_IN_*).
const int kJumpmanLeft = 0;
const int kJumpmanRight = 1;
const int kJumpmanJump = 2;

/// Jumpman's `JM_*` status values, from the same source.
const int kStatusPlaying = 0;
const int kStatusDying = 1;
const int kStatusWon = 2;
const int kStatusOver = 3;

/// Thrown when the game refuses the editor's own level. That is a bug in the
/// editor's model or its encoder, not something a user did, so it is reported
/// rather than ignored.
class PlaytestException implements Exception {
  const PlaytestException(this.message);
  final String message;
  @override
  String toString() => 'PlaytestException: $message';
}

/// A live session playing [level].
class Playtest {
  Playtest._(this._engine, this.spec, this.level);

  final GameEngine _engine;

  /// The shape the session was opened for.
  final JumpmanSpec spec;

  /// The level this session plays, as it was handed over: the editor's model
  /// with the start column the session was opened for.
  final JumpLevel level;

  int _accumMicros = 0;
  bool _jumpDown = false;
  bool _leftDown = false;
  bool _rightDown = false;

  /// The column the player died on, once a death has been seen: the column they
  /// were in on the tick before the life went.
  int? deathColumn;

  /// The session's tick count.
  int get tick => _engine.tick;

  /// The player's left column.
  int get playerX => _engine.stateInt('player_x');

  /// The player's top row.
  int get playerY => _engine.stateInt('player_y');

  /// Whether the player is standing on something, which is when a jump can be
  /// pressed: a press in the air is thrown away by the game.
  bool get onGround => _engine.stateInt('on_ground') > 0;

  /// How many columns ahead the nearest awake enemy at the player's row is, or
  /// -1: an enemy walks, so only the game knows where it is.
  int get enemyGap => _engine.stateInt('enemy_gap');

  /// The kind of the enemy [enemyGap] is to, or -1: how tall it is decides how
  /// early a jump at it has to start.
  int get enemyKind => _engine.stateInt('enemy_kind');

  /// How many rows of itself the next pipe's plant has out, 0 when it is hidden.
  /// A planted pipe has to be waited out rather than walked into, and only the
  /// game knows where in its cycle the plant is.
  int get plantOut => _engine.stateInt('plant_out');

  /// The column drawn at the left of the panel.
  int get camera => _engine.stateInt('camera');

  int get lives => _engine.stateInt('lives');

  /// `0` playing, `1` dying, `2` won, `3` over.
  int get status => _engine.stateInt('status');

  bool get isOver => status == kStatusWon || status == kStatusOver;

  /// Hand [level] to the game and open a session on it. [startX] overrides the
  /// level's own start column, which is how "play from here" is expressed.
  static Playtest open({
    required JumpLevel level,
    required JumpmanSpec spec,
    int? startX,
  }) {
    final playing = startX == null || startX == level.startX
        ? level
        : (level.clone()..startX = startX);
    if (startX != null &&
        (startX < 0 || startX >= spec.cols || playing.isPit(startX))) {
      throw PlaytestException(
        'column $startX is not somewhere a run can start.',
      );
    }

    final blob = encodeWire(playing);
    if (!GameEngine.setLevel(kJumpmanGameId, blob)) {
      throw PlaytestException(
        'the game refused the editor\'s own level (${blob.length} bytes). That '
        'is a bug in the editor, not in the level: nothing was played.',
      );
    }
    final engine = GameEngine.open(
      gameId: kJumpmanGameId,
      panelWidth: kPanelWidth,
      panelHeight: kPanelHeight,
      seed: 1,
      players: 1,
    );
    return Playtest._(engine, spec, playing);
  }

  void dispose() => _engine.dispose();

  // ------------------------------------------------------------------ input

  /// The player's held state. Jumpman reads left and right as levels and jump
  /// as an edge, so a jump is a press and a release.
  void setLeft(bool down) {
    if (down == _leftDown) return;
    _leftDown = down;
    _engine.input(code: kJumpmanLeft, value: down ? 1 : 0);
  }

  void setRight(bool down) {
    if (down == _rightDown) return;
    _rightDown = down;
    _engine.input(code: kJumpmanRight, value: down ? 1 : 0);
  }

  void pressJump() {
    if (_jumpDown) return;
    _jumpDown = true;
    _engine.input(code: kJumpmanJump, value: 1);
  }

  void releaseJump() {
    if (!_jumpDown) return;
    _jumpDown = false;
    _engine.input(code: kJumpmanJump, value: 0);
  }

  /// Release everything: what pausing has to do, or the player comes back to a
  /// key that is still held.
  void releaseAll() {
    setLeft(false);
    setRight(false);
    releaseJump();
  }

  // ---------------------------------------------------------------- playing

  /// Advance the session by [elapsed] of real time, one fixed tick at a time, the
  /// way the mirror paces a round. Returns the number of ticks stepped.
  int advance(Duration elapsed) {
    _accumMicros += elapsed.inMicroseconds;
    final stepMicros = spec.tickMs * 1000;
    var steps = 0;
    while (_accumMicros >= stepMicros) {
      _accumMicros -= stepMicros;
      step();
      steps++;
    }
    return steps;
  }

  /// Step exactly one tick, and notice a death.
  void step() {
    final before = lives;
    final x = playerX;
    _engine.step(spec.tickMs);
    if (lives < before) deathColumn = x;
  }

  // -------------------------------------------------------------- rendering

  /// The current frame as RGBA8888, the panel's own pixels.
  Uint8List? frame() => _engine.renderBytes();

  /// Decodes a frame for the canvas. Draw it with FilterQuality.none: smoothing
  /// turns crisp pixels into mush.
  Future<ui.Image?> decode(Uint8List bytes) => _engine.decodeImage(bytes);
}

/// What a playtest window tells the editor that opened it.
///
/// The window runs in its own process (the game's level injection is
/// process-wide, so a window of its own is what keeps a playtest from moving the
/// level a scan is probing), so this is how the editor's map can still follow
/// the run: the window writes it out, the editor reads it.
///
/// When the computer is driving, the same report is what the auto playtest found:
/// how far it got, and whether it came unstuck somewhere.
class PlaytestReport {
  const PlaytestReport({
    required this.tick,
    required this.playerX,
    required this.playerY,
    required this.camera,
    required this.lives,
    required this.status,
    required this.auto,
    required this.reached,
    required this.deaths,
    this.diedAt,
    this.stuckAt,
  });

  final int tick;
  final int playerX;
  final int playerY;
  final int camera;
  final int lives;

  /// Jumpman's `JM_*`: 0 playing, 1 dying, 2 won, 3 over.
  final int status;

  /// Whether the computer is driving.
  final bool auto;

  /// The furthest column the run has reached.
  final int reached;

  /// How many times it has died, and where the last death was.
  final int deaths;
  final int? diedAt;

  /// Where an auto playtest stopped making progress: the column it could not get
  /// past. Null while it is still moving.
  final int? stuckAt;

  bool get isWon => status == kStatusWon;
  bool get isOver => status == kStatusWon || status == kStatusOver;

  Map<String, Object?> toJson() => {
        'tick': tick,
        'player_x': playerX,
        'player_y': playerY,
        'camera': camera,
        'lives': lives,
        'status': status,
        'auto': auto,
        'reached': reached,
        'deaths': deaths,
        'died_at': diedAt,
        'stuck_at': stuckAt,
      };

  /// Read a report, or null when the file is not one: a half-written file is a
  /// reader's problem, not a crash.
  static PlaytestReport? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    int? at(String key) => json[key] is int ? json[key] as int : null;
    final tick = at('tick');
    final playerX = at('player_x');
    final lives = at('lives');
    final status = at('status');
    if (tick == null || playerX == null || lives == null || status == null) {
      return null;
    }
    return PlaytestReport(
      tick: tick,
      playerX: playerX,
      playerY: at('player_y') ?? 0,
      camera: at('camera') ?? 0,
      lives: lives,
      status: status,
      auto: json['auto'] == true,
      reached: at('reached') ?? playerX,
      deaths: at('deaths') ?? 0,
      diedAt: at('died_at'),
      stuckAt: at('stuck_at'),
    );
  }

  /// What the auto playtest found, in one line.
  String summary() {
    final parts = <String>['reached column $reached'];
    if (deaths > 0) {
      parts.add('died $deaths×${diedAt == null ? '' : ' (last at $diedAt)'}');
    }
    if (stuckAt != null) parts.add('stuck at column $stuckAt');
    if (isWon) parts.add('won');
    return parts.join(', ');
  }
}
