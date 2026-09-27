// The proof that the editor's model drives the real game.
//
// The editor could be right about the level and wrong about the wire, and the
// only way to know is to hand the game the bytes the editor produces and compare
// the playfield with a session opened on the compiled course. The campaign HUD
// intentionally differs from an editor's standalone run; the level itself must
// render identically, tick for tick, over the CLI's baked demo.
//
// Needs the native core, which the app's own build produces:
//
//   cd jumpman_editor && flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/jump_level.dart';
import 'package:jumpman_editor/src/playtest.dart';
import 'package:jumpman_editor/src/wire.dart';
import 'package:mirror_core_ffi/mirror_core_ffi.dart';

import 'support.dart';

/// `JUMPMAN_DEMO` from the CLI: {tick, code, value}. Codes are jumpman's own:
/// 0 Left, 1 Right, 2 Jump.
const List<List<int>> _demo = [
  [0, 1, 1],
  [4, 2, 1],
  [10, 2, 0],
  [22, 2, 1],
  [28, 2, 0],
  [40, 2, 1],
  [46, 2, 0],
  [58, 2, 1],
  [64, 2, 0],
  [76, 2, 1],
  [82, 2, 0],
];

void _feed(GameEngine engine, int tick) {
  for (final event in _demo) {
    if (event[0] != tick) continue;
    engine.input(playerId: 1, code: event[1], value: event[2]);
  }
}

GameEngine _open() => GameEngine.open(
      gameId: 'jumpman',
      panelWidth: 64,
      panelHeight: 32,
      seed: 1,
      players: 1,
    );

List<Uint8List> _frames(GameEngine engine) {
  final frames = <Uint8List>[];
  for (var t = 0; t < 90; t++) {
    _feed(engine, t);
    engine.step(25);
    frames.add(Uint8List.fromList(engine.renderBytes()!));
  }
  return frames;
}

void main() {
  test('the editor\'s level drives the real game, tick for tick', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);

    // A session opened without any injection plays the level compiled in.
    final plain = _open();
    late List<Uint8List> compiledFrames;
    try {
      compiledFrames = _frames(plain);
    } finally {
      plain.dispose();
    }

    expect(
      GameEngine.setLevel('jumpman', encodeWire(level)),
      isTrue,
      reason: 'the game refused the level the editor imported from its own '
          'source',
    );

    final injected = _open();
    late List<Uint8List> injectedFrames;
    try {
      injectedFrames = _frames(injected);
    } finally {
      injected.dispose();
    }

    final fieldOffset = (kPanelHeight - spec.rows) * kPanelWidth * 4;
    for (var t = 0; t < 90; t++) {
      expect(Uint8List.sublistView(injectedFrames[t], fieldOffset),
          orderedEquals(Uint8List.sublistView(compiledFrames[t], fieldOffset)),
          reason: 'playfield frame $t differs from the compiled course');
    }

    expect(GameEngine.setLevel('jumpman'), isTrue);
  });

  test('a malformed blob is refused and the shipped level is still played', () {
    final spec = readSpec();
    final blob = encodeWire(readAuthoredLevel(spec));
    final short = Uint8List.sublistView(blob, 0, blob.length - 1);

    expect(GameEngine.setLevel('jumpman', short), isFalse);
    expect(GameEngine.setLevel('jumpman'), isTrue);

    final engine = _open();
    try {
      expect(engine.stateInt('player_x'), 3);
    } finally {
      engine.dispose();
    }
  });

  test('a level that is ground from end to end is accepted and played', () {
    final spec = readSpec();
    // The editor's New-level template: 256 columns of one surface, which is one
    // column more than a run record's width byte holds. Encoded as a single run
    // it would arrive as no ground at all, and the run would fall out of the
    // world on its first tick.
    final level = JumpLevel.empty(spec);
    expect(GameEngine.setLevel('jumpman', encodeWire(level)), isTrue);

    final engine = _open();
    try {
      expect(engine.stateInt('player_x'), spec.startX);
      engine.input(code: kJumpmanRight, value: 1);
      for (var t = 0; t < 40; t++) {
        engine.step(25);
      }
      expect(engine.stateInt('lives'), 3);
      expect(engine.stateInt('player_x'), greaterThan(spec.startX + 30));
    } finally {
      engine.dispose();
      GameEngine.setLevel('jumpman');
    }
  });
}
