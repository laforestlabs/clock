// The wire: the level as the game reads it.
//
// The length is the contract - the game checks the blob against exactly this
// size - so the shipped level's 106 bytes are pinned here, and the runs that
// make them up are checked column by column. The other half of this contract,
// that the game accepts the bytes, is the fidelity test: it injects this blob
// and requires the frames to match a session opened on the compiled-in level.

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/jump_level.dart';
import 'package:jumpman_editor/src/wire.dart';

import 'support.dart';

void main() {
  test('the shipped level\'s blob is exactly what the game reads', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);
    final ground = groundRunsOf(level);
    final blocks = blockRunsOf(level);

    expect(ground, hasLength(7));
    expect(blocks, hasLength(7));

    final blob = encodeWire(level);
    expect(blob.length, 8 + 3 * 7 + 4 * 7 + 3 * 1 + 2 * 11 + 4 * 6);
    expect(blob.length, 106);

    expect(blob[0], 1);
    expect(blob[1], level.startX);
    expect(blob[2], level.checkpointX);
    expect(blob[3], 7); // ground runs
    expect(blob[4], 7); // block runs
    expect(blob[5], 1); // pipes
    expect(blob[6], 11); // coins
    expect(blob[7], 6); // enemies
  });

  test('the ground runs are the pits the level states, and nothing else', () {
    final level = readAuthoredLevel(readSpec());
    final ground = groundRunsOf(level);

    expect(ground.map((r) => r.x), [0, 105, 108, 174, 179, 217, 225]);
    expect(ground.map((r) => r.w), [105, 3, 66, 5, 38, 8, 31]);
    expect(ground.map((r) => r.surf), [19, kPit, 19, kPit, 19, kPit, 19]);
  });

  test('the runs cover every column exactly once, in ascending order', () {
    final level = readAuthoredLevel(readSpec());
    var x = 0;
    for (final run in groundRunsOf(level)) {
      expect(run.x, x);
      expect(run.w, greaterThan(0));
      x += run.w;
    }
    expect(x, level.cols);

    for (final run in blockRunsOf(level)) {
      expect(run.w, greaterThan(0));
      expect(run.x + run.w, lessThanOrEqualTo(level.cols));
    }
  });

  test('the block runs are the level\'s blocks merged per column', () {
    final level = readAuthoredLevel(readSpec());
    final runs = blockRunsOf(level);

    // The staircase's stacked stones are three columns, so the merged form is
    // three runs where the shipped table had six entries.
    expect(runs.map((r) => r.x), [2, 7, 35, 146, 244, 245, 247]);
    expect(runs.map((r) => r.w), [1, 4, 4, 4, 1, 2, 1]);
    expect(runs.map((r) => r.row), [6, 6, 6, 6, 15, 11, 15]);

    var columns = 0;
    for (final run in runs) {
      columns += run.w;
      for (var i = 0; i < run.w; i++) {
        expect(level.blocks[run.x + i], packBlock(run.kind, run.row));
      }
    }
    expect(columns, 17);
  });

  test('a run is written as records a width byte can hold', () {
    final spec = readSpec();

    // The New-level template is ground from end to end: 256 columns, which is
    // one more than a record's width byte holds. Written as one record it would
    // wrap to zero and the level would arrive with no ground at all.
    final level = JumpLevel.empty(spec);
    final runs = groundRunsOf(level);
    expect(runs.every((r) => r.w >= 1 && r.w <= kMaxRunColumns), isTrue);
    expect(runs.fold<int>(0, (n, r) => n + r.w), spec.cols);
    expect(runs, hasLength(2));

    final blob = encodeWire(level);
    expect(blob[3], 2);
    expect(blob[8 + 1], kMaxRunColumns);
    expect(blob[11 + 1], spec.cols - kMaxRunColumns);

    // And the same for a level that is one long pit.
    final allPit = level.clone();
    allPit.surface.fillRange(0, spec.cols, kPit);
    expect(
      groundRunsOf(allPit).every((r) => r.w >= 1 && r.w <= kMaxRunColumns),
      isTrue,
    );
  });

  test('every byte of the header is a column or a count the level has', () {
    final spec = readSpec();
    final level = JumpLevel.empty(spec);
    level.startX = 7;
    level.checkpointX = 9;
    level.pipes.add(JumpPipe(x: 20, h: 4, plant: 1));
    level.coins.add(JumpCoin(x: 30, y: 10));
    level.enemies.add(JumpEnemy(x: 40, row: 19, dir: -1, kind: 0));

    final blob = encodeWire(level);
    expect(blob[1], 7);
    expect(blob[2], 9);
    expect(blob[3], 2); // the level is all ground: 255 columns, then 1
    expect(blob[4], 0);
    expect(blob[5], 1);
    expect(blob[6], 1);
    expect(blob[7], 1);
    // The last enemy record's direction is two's complement.
    expect(blob[blob.length - 2], 0xFF);
  });
}
