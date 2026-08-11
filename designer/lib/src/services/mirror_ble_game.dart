// Parsing and encoding of the BLE game protocol, kept free of Flutter and
// plugin imports so it is unit testable like the rest of the protocol layer.
// The wire format is defined in firmware/main/net/ble.c:
//
//   game list          -> "games <id>[,<id>...]" (empty list: "games")
//   game start <id>    -> "game ok <id> <label>..." | "game error <why>"
//   game stop          -> "game stopped" | "game error no game"
//
// Gamepad input rides a separate characteristic (gameInUuid in
// mirror_ble.dart), one write per frame carrying the full held state,
// little-endian: byte 0 is the control count (1..16, 0 = all released),
// then per control u8 code + i16 value (0/1). Max packet 49 bytes.

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

/// A game the mirror can run, with the control labels for the gamepad.
class MirrorGame {
  const MirrorGame(this.id, this.controls);

  /// The mirror's stable game id, e.g. "snake".
  final String id;

  /// Control labels in code order, e.g. ["Up", "Down", "Left", "Right"].
  /// The gamepad renders exactly these.
  final List<String> controls;
}

/// Parses a `game ok <id> <label>...` status line. Returns null for anything
/// else, including "game error ..." (the caller surfaces those separately)
/// and old firmware's "unknown command".
MirrorGame? parseGameOk(String line) {
  final parts = line.split(' ');
  if (parts.length < 3 || parts[0] != 'game' || parts[1] != 'ok') return null;
  return MirrorGame(parts[2], parts.sublist(3));
}

/// Encodes the full held state as one game_in packet: [held][i] is whether
/// control code i is pressed. The count byte is the number of controls, so
/// an empty list encodes to an empty packet (all released).
Uint8List encodeGameInput(List<bool> held) {
  final count = held.length;
  if (count == 0) return Uint8List(0);
  final p = Uint8List(1 + 3 * count);
  p[0] = count;
  for (var i = 0; i < count; i++) {
    p[1 + 3 * i] = i; // control code
    p[2 + 3 * i] = held[i] ? 1 : 0;
    p[3 + 3 * i] = 0; // i16 value, little-endian, high byte
  }
  return p;
}
