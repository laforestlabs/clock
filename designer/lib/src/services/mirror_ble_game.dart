// Parsing and encoding of the BLE game protocol, kept free of Flutter and
// plugin imports so it is unit testable like the rest of the protocol layer.
// The wire format is defined in firmware/main/net/ble.c:
//
//   game list          -> "games <id>[,<id>...]" (empty list: "games")
//   game start <id> [1|2] -> "game ok <id> <label>:<type>..." (starter only)
//   game join          -> "game joined <player> <id> <label>:<type>..."
//   game session       -> "game session none"
//                      | "game session <id> <seats> <need> <state> <me>"
//   game stop          -> "game stopped" | "game error no game"
//   game error <why>   -> the device refused a game command
//   game over <id>     -> pushed when the running game reaches its end
//   game players <seats> <need> -> pushed when the seat count changes
//
// Two phones can hold one round: `game start <id> 2` opens a round that waits
// for a second link, and `game join` seats the phone that asks for one. The
// `game ok`/`game joined`/`game session` replies and the `game error` refusals
// go to the link that asked (so the predicates below say what can answer a
// command), while `game stopped`, `game paused`, `game resumed`, `game over`
// and `game players` are broadcast to every link and must never be read as a
// reply to anything.
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

/// Whether [line] can answer `game session`: either session shape, a device
/// rejection, or `unknown command` (which the caller reads as "this firmware
/// cannot tell me", not as a device error).
///
/// `game players ...` is deliberately not accepted: it is broadcast to every
/// link, so it can arrive while this command is outstanding without being its
/// answer.
bool isGameSessionReply(String line) =>
    line.startsWith('game session ') ||
    line.startsWith('$gameErrorPrefix ') ||
    line == unknownCommandReply;

/// Whether [line] can answer `game join`: `game joined ...` (the joiner's
/// controls; a link that already holds a seat is answered the same way, so
/// joining twice is harmless), a device rejection, or `unknown command`.
bool isGameJoinReply(String line) =>
    line.startsWith('game joined ') ||
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

/// A `game session ...` reply: the round the device is running, how many
/// seats it was started with, how many are filled, and which seat this phone
/// holds.
class MirrorSessionInfo {
  const MirrorSessionInfo({this.id, required this.seats, required this.need,
      required this.state, required this.me});

  /// The running game's id, or null for `game session none` — a mirror with
  /// no round, where the other fields are zero and [state] is "none".
  final String? id;

  /// Seats filled, and the seats the round was started with.
  final int seats, need;

  /// waiting | playing | paused | over, or none for an idle mirror. A two
  /// phone round is `waiting` until every seat it was started with is filled.
  final String state;

  /// This link's player id, 0 when it holds no seat.
  final int me;
}

/// The controls of a `game ok`/`game joined` tail: `<label>` for a button,
/// `<label>:b` or `<label>:a` when the firmware types them. Null when a token
/// is malformed, so a caller can reject the whole line.
List<MirrorControl>? _parseControls(List<String> tokens) {
  final controls = <MirrorControl>[];
  for (final tok in tokens) {
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
  return controls;
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
  final controls = _parseControls(parts.sublist(3));
  if (controls == null) return null;
  return MirrorGame(parts[2], controls);
}

/// Parses a `game joined <player> <id> <label>:<type>...` status line into
/// the seat's player id and the game's controls, the join counterpart of
/// [parseGameOk]. Returns null for anything else, so an unsolicited line
/// never seats anyone.
({int playerId, MirrorGame game})? parseGameJoined(String line) {
  final parts = line.split(' ');
  if (parts.length < 4 ||
      parts[0] != 'game' ||
      parts[1] != 'joined' ||
      parts[3].isEmpty) {
    return null;
  }
  final playerId = int.tryParse(parts[2]);
  // Seat ids are 1-based; 0 is the device's way of saying "no seat".
  if (playerId == null || playerId < 1) return null;
  final controls = _parseControls(parts.sublist(4));
  if (controls == null) return null;
  return (playerId: playerId, game: MirrorGame(parts[3], controls));
}

/// Parses a `game session ...` status line. Both shapes are valid replies:
/// `game session none` (an idle mirror, id null) and
/// `game session <id> <seats> <need> <state> <me>`. Returns null for anything
/// else, including a malformed or unknown state, so a caller never acts on a
/// round it cannot describe.
MirrorSessionInfo? parseGameSession(String line) {
  final parts = line.split(' ');
  if (parts.length < 3 || parts[0] != 'game' || parts[1] != 'session') {
    return null;
  }
  if (parts.length == 3 && parts[2] == 'none') {
    return const MirrorSessionInfo(seats: 0, need: 0, state: 'none', me: 0);
  }
  if (parts.length != 7 || parts[2].isEmpty) return null;
  final seats = int.tryParse(parts[3]);
  final need = int.tryParse(parts[4]);
  final me = int.tryParse(parts[6]);
  if (seats == null || need == null || me == null) return null;
  if (seats < 0 || need < 0 || me < 0) return null;
  final state = parts[5];
  if (state != 'waiting' &&
      state != 'playing' &&
      state != 'paused' &&
      state != 'over') {
    return null;
  }
  return MirrorSessionInfo(
      id: parts[2], seats: seats, need: need, state: state, me: me);
}

/// Parses a `game players <seats> <need>` status line, the broadcast that
/// says how full the round is. Returns null for anything else.
({int seats, int need})? parseGamePlayers(String line) {
  final parts = line.split(' ');
  if (parts.length != 4 || parts[0] != 'game' || parts[1] != 'players') {
    return null;
  }
  final seats = int.tryParse(parts[2]);
  final need = int.tryParse(parts[3]);
  if (seats == null || need == null || seats < 0 || need < 0) return null;
  return (seats: seats, need: need);
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

/// Encodes a `game start` command line: `game start <id>` for a solo round
/// ([players] == 1, the line older firmware already understands) and
/// `game start <id> <players>` for a round that waits for that many seats to
/// be filled.
String encodeGameStart(String id, int players) =>
    players == 1 ? 'game start $id' : 'game start $id $players';

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
