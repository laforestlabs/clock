// Parsing and encoding of the BLE game protocol, kept free of Flutter and
// plugin imports so it is unit testable like the rest of the protocol layer.
// The wire format is defined in firmware/main/net/ble.c:
//
//   game list          -> "games <id>[,<id>...]" (empty list: "games")
//   game start <id>    -> "game ok <id> <label>:<type>..."
//   game stop          -> "game stopped" | "game error no game"
//   game over <id>     -> pushed when the running game reaches its end
//
// Gamepad input rides a separate characteristic (gameInUuid in
// mirror_ble.dart), one write per frame carrying the full input state,
// little-endian: byte 0 is the control count (1..16, 0 = all released), then
// per control u8 code + i16 value. A button's value is 0/1, an axis's is
// -32768..32767. Max packet 49 bytes.

import 'dart:typed_data';

/// Parses a `games <id>[,<id>...]` status line into the mirror's game ids.
///
/// Returns null for anything else, including the "unknown command" an older
/// mirror answers to "game list", so the app can treat that as "no game
/// support".
List<String>? parseGameList(String line) {
  final parts = line.split(' ');
  if (parts.length != 2 || parts[0] != 'games') return null;
  return parts[1]
      .split(',')
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
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
  if (parts.length < 3 || parts[0] != 'game' || parts[1] != 'ok') return null;
  final controls = <MirrorControl>[];
  for (final tok in parts.sublist(3)) {
    final idx = tok.lastIndexOf(':');
    if (idx > 0 && idx == tok.length - 2) {
      final label = tok.substring(0, idx);
      final t = tok.substring(idx + 1);
      controls.add(MirrorControl(label,
          t == 'a' ? MirrorControlType.axis : MirrorControlType.button));
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
