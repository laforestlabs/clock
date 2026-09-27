// A safe Dart face over the gamekit simulation.
//
// Owns the native game session handle and every allocation that crosses the
// boundary. The rest of the app never touches dart:ffi. Same pattern as
// MirrorEngine: the session is opaque, rendering returns RGBA8888 bytes the
// Flutter paint path decodes, and stepping is driven by a ticker in the UI.
//
// The contract: [renderBytes] returns exactly what the LED panel would display
// for the current game state. No game chrome, no soft buttons. Those are drawn
// on top by the view layer, because the pixel-exactness guarantee is the same
// one the layout preview relies on.

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

import 'game_bindings.dart';
export 'game_bindings.dart' show GameControl, GameControlType, GameInfo;

/// One game session: a host, a canvas, and (for each player) a controller.
///
/// Create with [GameEngine.open], then drive with [step] and [button], and
/// render with [renderBytes] / [decodeImage]. One session at a time.
class GameEngine {
  GameEngine._(this._b, this._handle, this._width, this._height);

  final GameBindings _b;
  final Pointer<Void> _handle;
  final int _width;
  final int _height;
  bool _disposed = false;

  /// Opens a game session. game_id selects the game ("rally"); panel size sets
  /// the canvas; seed drives the deterministic PRNG; players attaches that many
  /// local controllers (capped by the game's max_players).
  ///
  /// Throws [GameLibraryException] if the game id is unknown or the session
  /// could not be created.
  /// [course] explicitly selects a built-in Jumpman course, bounded by the
  /// highest course earned in trusted storage, [unlockedCourse]. Leave it null
  /// for editor-injected single-course runs and games without a campaign.
  factory GameEngine.open({
    required String gameId,
    required int panelWidth,
    required int panelHeight,
    int seed = 1,
    int players = 1,
    int? course,
    int unlockedCourse = 1,
  }) {
    final bindings = GameBindings.instance();
    final id = gameId.toNativeUtf8();
    try {
      final handle =
          bindings.gameOpen(id, panelWidth, panelHeight, seed, players);
      if (handle == nullptr) {
        throw GameLibraryException(
          'ml_game_open returned null for game "$gameId" '
          'at ${panelWidth}x$panelHeight.',
        );
      }
      if (course != null &&
          bindings.gameStartCourse(handle, course, unlockedCourse) == 0) {
        bindings.gameClose(handle);
        throw GameLibraryException(
          'Cannot start course $course of "$gameId" '
          '(highest unlocked: $unlockedCourse).',
        );
      }
      final w = bindings.gameWidth(handle);
      final h = bindings.gameHeight(handle);
      return GameEngine._(bindings, handle, w, h);
    } finally {
      calloc.free(id);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.gameClose(_handle);
  }

  void _assertLive() {
    if (_disposed) throw StateError('GameEngine used after dispose()');
  }

  /// One-based active course; zero for non-campaign sessions.
  int get course {
    _assertLive();
    return _b.gameCourse(_handle);
  }

  /// Highest unlocked course. Persist increases immediately after [step],
  /// rather than waiting for the player to finish or lose the campaign.
  int get unlockedCourse {
    _assertLive();
    return _b.gameUnlocked(_handle);
  }

  // ------------------------------------------------------------ catalogue

  /// Games compiled into this build, for the picker.
  static List<GameInfo> get games {
    final b = GameBindings.instance();
    return List<GameInfo>.generate(
      b.gameCount(),
      (i) {
        final maxP = b.gameMaxPlayers(i);
        final ctrlCount = b.gameControlCount(i);
        final controls = List<GameControl>.generate(
          ctrlCount,
          (c) => GameControl(
            b.gameControlLabel(i, c).toDartString(),
            _controlType(b.gameControlType(i, c)),
          ),
          growable: false,
        );
        return GameInfo(
          b.gameId(i).toDartString(),
          b.gameName(i).toDartString(),
          maxP,
          controls,
        );
      },
      growable: false,
    );
  }

  /// The declared type of one control, from the `ml_input_type` value the
  /// native catalogue reports.
  static GameControlType _controlType(int value) {
    if (value == 1) return GameControlType.axis;
    if (value == 2) return GameControlType.touch;
    return GameControlType.button;
  }

  // -------------------------------------------------------------- geometry

  int get width => _width;
  int get height => _height;
  ui.Size get canvasSize => ui.Size(_width.toDouble(), _height.toDouble());

  /// Current simulation tick. Monotonic per session.
  int get tick {
    _assertLive();
    return _b.gameTick(_handle);
  }

  // ------------------------------------------------------------ simulation

  /// Feed one control of the round's full state. [value] is 1/0 for a button
  /// and -32768..32767 for an axis; the control's declared type decides which
  /// (see [GameControlType]), resolved natively from the game's own table.
  /// For multiplayer, playerId selects which controller (1-based).
  void input({int playerId = 1, int code = 0, int value = 1}) {
    _assertLive();
    _b.gameInput(_handle, playerId, code, value);
  }

  /// Advance the simulation by ms of wall time (fixed-timestep internally).
  void step(int ms) {
    _assertLive();
    _b.gameStep(_handle, ms);
  }

  /// Whether the game has reached its terminal state (game over, or the win
  /// state where a game has one). Read after [step]; stays true until the
  /// session is reopened.
  bool get isOver {
    _assertLive();
    return _b.gameIsOver(_handle) != 0;
  }

  // ------------------------------------------------------------- rendering

  /// Copies the current frame as RGBA8888. The native buffer is reused, so this
  /// copies. Returns null on failure.
  Uint8List? renderBytes() {
    _assertLive();
    final ptr = _b.gameRenderRgba(_handle);
    if (ptr == nullptr) return null;

    final size = _b.gameRgbaSize(_handle);
    if (size <= 0) return null;

    return Uint8List.fromList(ptr.asTypedList(size));
  }

  /// Decodes a frame from [renderBytes] into an image for the canvas.
  /// Draw with FilterQuality.none: smoothing turns crisp pixels into mush.
  Future<ui.Image?> decodeImage(Uint8List bytes) async {
    if (_width <= 0 || _height <= 0) return null;

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      _width,
      _height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  // --------------------------------------------------------- authored levels

  /// Hands game [gameId] one of its levels, in that game's own wire form,
  /// before the session that plays it is opened. Returns false when the game has
  /// no authored level or the blob was malformed, in which case the game keeps
  /// the level it had. A null or empty [blob] restores the shipped level.
  ///
  /// A development call: it is what the level editor hands a game it painted a
  /// level for, and a device never makes it.
  static bool setLevel(String gameId, [Uint8List? blob]) {
    final bindings = GameBindings.instance();
    final id = gameId.toNativeUtf8();
    Pointer<Uint8> data = nullptr;
    final length = blob?.length ?? 0;
    try {
      if (length > 0) {
        data = calloc<Uint8>(length);
        data.asTypedList(length).setAll(0, blob!);
      }
      return bindings.gameSetLevel(id, data, length) != 0;
    } finally {
      if (data != nullptr) calloc.free(data);
      calloc.free(id);
    }
  }

  /// One integer of this session's live game state, by name, or -1 when the game
  /// publishes no such value. The names a game publishes are its own; jumpman
  /// answers "player_x", "camera", "lives" and "status".
  ///
  /// A development call, like [setLevel].
  int stateInt(String name) {
    _assertLive();
    final ptr = name.toNativeUtf8();
    try {
      return _b.gameStateInt(_handle, ptr);
    } finally {
      calloc.free(ptr);
    }
  }
}
