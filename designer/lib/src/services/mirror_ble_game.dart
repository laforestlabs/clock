// Parsing and encoding of the BLE game protocol, kept free of Flutter and
// plugin imports so it is unit testable like the rest of the protocol layer.
// The wire format is defined in firmware/main/net/ble.c:
//
//   game list          -> "games <id>[,<id>...]" (empty list: "games")
//   game start <id>    -> "game ok <id> <label>:<type>..."
//   game stop          -> "game stopped" | "game error no game"
//   game error <why>   -> the device refused a game command
//   game over <id>     -> pushed when the running game reaches its end
//
// Game commands are answered out of band: `game over <id>` is pushed with no
// command behind it, and the device answers `unknown command` to a command
// an older firmware does not have. The predicates here and
// [waitForGameReply] let a caller wait for the line that actually answers its
// command instead of the next line to arrive.
//
// Gamepad input rides a separate characteristic (gameInUuid in
// mirror_ble.dart), one write per frame carrying the full input state,
// little-endian: byte 0 is the control count (1..16, 0 = all released), then
// per control u8 code + i16 value. A button's value is 0/1, an axis's is
// -32768..32767. Max packet 49 bytes.

import 'dart:async';
import 'dart:typed_data';

/// The line firmware answers to a command it does not implement. Without
/// game support every `game *` command gets it, so the app reads it as "this
/// firmware cannot do that" rather than as a device rejection.
const String unknownCommandReply = 'unknown command';

/// The prefix of a `game error <reason>` rejection.
const String gameErrorPrefix = 'game error';

/// Parses a `games <id>[,<id>...]` status line into the mirror's game ids.
///
/// Both `games` (a supported mirror with no games installed) and `games `
/// parse to an empty list. Returns null for anything else, including the
/// "unknown command" an older mirror answers to "game list", so the app can
/// treat that as "no game support".
List<String>? parseGameList(String line) {
  final parts = line.split(' ');
  if (parts[0] != 'games' || parts.length > 2) return null;
  if (parts.length == 1 || parts[1].isEmpty) return const <String>[];
  final ids = parts[1].split(',');
  if (ids.any((id) => id.isEmpty)) return null;
  return ids;
}

/// The device's own words from a `game error <reason>` line, or the line
/// itself when no reason follows the prefix.
String gameErrorReason(String line) {
  if (!line.startsWith(gameErrorPrefix)) return line;
  final reason = line.substring(gameErrorPrefix.length).trim();
  return reason.isEmpty ? line : reason;
}

/// Whether [line] can answer `game list`: a `games ...` catalogue, a device
/// rejection, or the `unknown command` of firmware that has no games.
bool isGameListReply(String line) =>
    line == 'games' ||
    line.startsWith('games ') ||
    line.startsWith('$gameErrorPrefix ') ||
    line == unknownCommandReply;

/// Whether [line] can answer `game start <id>`: `game ok ...` (whoever calls
/// this still has to compare the id), a device rejection, or
/// `unknown command`.
///
/// A `game ok` naming another game is accepted here on purpose: the caller
/// then finds out at once, instead of waiting out a timeout during which the
/// mirror is already running something.
bool isGameStartReply(String line) =>
    line.startsWith('game ok ') ||
    line.startsWith('$gameErrorPrefix ') ||
    line == unknownCommandReply;

/// Whether [line] can answer `game stop`: `game stopped`, a device rejection
/// (`game error no game` means there was nothing to stop), or
/// `unknown command`.
bool isGameStopReply(String line) =>
    line == 'game stopped' ||
    line.startsWith('$gameErrorPrefix ') ||
    line == unknownCommandReply;

/// Awaits the first line of [statuses] that [accepts] approves, subscribing
/// before [write] runs because the device may deliver the reply before the
/// write itself reports completion (Android does exactly that for a pong).
///
/// Unlike `Stream.firstWhere`, the subscription is cancelled as soon as the
/// wait ends — success, write failure, timeout, stream closure — so a later
/// command cannot be answered by a line meant for this one. Other listeners
/// on a broadcast [statuses] stream are left alone: this only reads.
///
/// Throws [TimeoutException] when no accepted line arrives within [timeout],
/// [StateError] when the stream closes first, and the write's own error when
/// [write] fails.
Future<String> waitForGameReply({
  required Stream<String> statuses,
  required Future<void> Function() write,
  required bool Function(String) accepts,
  Duration timeout = const Duration(seconds: 10),
}) {
  final result = Completer<String>();
  StreamSubscription<String>? subscription;
  Timer? timer;
  String? reply;
  var written = false;

  void cancel() {
    timer?.cancel();
    unawaited(subscription?.cancel());
  }

  void fail(Object error, StackTrace stack) {
    if (result.isCompleted) return;
    cancel();
    result.completeError(error, stack);
  }

  void complete() {
    if (result.isCompleted || !written || reply == null) return;
    cancel();
    result.complete(reply!);
  }

  subscription = statuses.listen(
      (line) {
        if (result.isCompleted || reply != null) return;
        try {
          if (!accepts(line)) return;
          reply = line;
          unawaited(subscription?.cancel());
          complete();
        } catch (error, stack) {
          fail(error, stack);
        }
      },
      onError: fail,
      onDone: () {
        if (reply == null) {
          fail(StateError('status stream closed'), StackTrace.current);
        }
      });
  timer = Timer(timeout, () {
    fail(TimeoutException('no reply within ${timeout.inMilliseconds} ms'),
        StackTrace.current);
  });
  // Attach error handling immediately: the deadline also covers a stalled
  // write, and a late write failure must never become an unhandled exception.
  unawaited(Future<void>.sync(write).then((_) {
    written = true;
    complete();
  }, onError: fail));
  return result.future;
}

/// What kind of input a game control expects.
enum MirrorControlType { button, axis }

/// One control the gamepad renders.
class MirrorControl {
  const MirrorControl(this.label, this.type);

  final String label;
  final MirrorControlType type;

  bool get isAxis => type == MirrorControlType.axis;
}

/// A game the mirror can run, with the controls for the gamepad.
class MirrorGame {
  const MirrorGame(this.id, this.controls);

  /// The mirror's stable game id, e.g. "snake".
  final String id;

  /// Controls in code order, e.g. Up, Down, Left, Right.
  final List<MirrorControl> controls;
}

/// Parses a `game ok <id> <label>:<type>...` status line. Returns null for
/// anything else, including "game error ..." (the caller surfaces those
/// separately) and old firmware's "unknown command".
///
/// A token with no `:t` suffix (old firmware) is a button; new firmware
/// appends `:b` for button and `:a` for axis.
MirrorGame? parseGameOk(String line) {
  final parts = line.split(' ');
  if (parts.length < 3 ||
      parts[0] != 'game' ||
      parts[1] != 'ok' ||
      parts[2].isEmpty) {
    return null;
  }
  final controls = <MirrorControl>[];
  for (final tok in parts.sublist(3)) {
    if (tok.isEmpty) return null;
    final idx = tok.lastIndexOf(':');
    if (idx >= 0) {
      if (idx == 0 || idx != tok.length - 2) return null;
      final label = tok.substring(0, idx);
      final t = tok.substring(idx + 1);
      if (t != 'a' && t != 'b') return null;
      controls.add(MirrorControl(
          label, t == 'a' ? MirrorControlType.axis : MirrorControlType.button));
    } else {
      controls.add(MirrorControl(tok, MirrorControlType.button));
    }
  }
  return MirrorGame(parts[2], controls);
}

/// Parses a `game over <id>` status line into the game's id. Returns null
/// for anything else, so unrelated status lines never trip the gamepad.
String? parseGameOver(String line) {
  final parts = line.split(' ');
  if (parts.length != 3 || parts[0] != 'game' || parts[1] != 'over') {
    return null;
  }
  return parts[2];
}

/// Encodes the full input state as one game_in packet: [values][i] is the
/// i16 value for control code i (0/1 for buttons, -32768..32767 for axes).
/// An empty list encodes to an empty packet.
Uint8List encodeGameInput(List<int> values) {
  final count = values.length;
  if (count == 0) return Uint8List(0);
  final p = Uint8List(1 + 3 * count);
  p[0] = count;
  for (var i = 0; i < count; i++) {
    final v = values[i];
    p[1 + 3 * i] = i; // control code
    p[2 + 3 * i] = v & 0xff; // i16 value, little-endian
    p[3 + 3 * i] = (v >> 8) & 0xff;
  }
  return p;
}
