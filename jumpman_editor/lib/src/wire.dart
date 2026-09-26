// The wire: a level as the game's own byte stream.
//
// This is what crosses into gamekit (ml_game_set_level) before a playtest or a
// scan. It is a byte stream rather than a struct because the boundary rule in
// game_ffi.h is that Dart never touches a C struct.
//
//   offset  field
//   0       version, must be 1
//   1       start_x
//   2       checkpoint_x
//   3       ground_n
//   4       block_n
//   5       pipe_n
//   6       coin_n
//   7       enemy_n
//   8 ...   ground_n x { x, w, surf }             surf 255 = pit
//   then    block_n  x { x, w, row, kind }
//   then    pipe_n   x { x, h, plant }
//   then    coin_n   x { x, y }
//   then    enemy_n  x { x, row, dir, kind }      dir two's complement
//
// The runs are maximal: consecutive columns with the same ground surface (and
// the same packed block byte) become one record, and the ground runs cover
// 0..cols-1 with no gaps - the invariant the authored table states, so a gap
// between runs is a pit and nothing else. Runs are written in ascending x, and
// a level's size is exactly
// 8 + 3*ground_n + 4*block_n + 3*pipe_n + 2*coin_n + 4*enemy_n, which is what
// the game checks the blob against.

import 'dart:typed_data';

import 'jump_level.dart';

/// The version of the wire form this editor writes.
const int kWireVersion = 1;

/// One run of columns sharing a ground surface. [surf] is [kPit] for a pit.
class GroundRun {
  const GroundRun({required this.x, required this.w, required this.surf});
  final int x;
  final int w;
  final int surf;
}

/// One run of columns sharing a packed block byte.
class BlockRun {
  const BlockRun({
    required this.x,
    required this.w,
    required this.row,
    required this.kind,
  });
  final int x;
  final int w;
  final int row;
  final int kind;
}

/// The most columns one run record can state: a record's width is one byte.
const int kMaxRunColumns = 255;

/// The level's ground in maximal runs, covering every column.
///
/// A run longer than [kMaxRunColumns] is written as several records, because
/// that is all a width byte holds - a 256-column level that is ground from end
/// to end is two runs, not one whose width wraps to zero.
List<GroundRun> groundRunsOf(JumpLevel level) {
  final runs = <GroundRun>[];
  var x = 0;
  while (x < level.cols) {
    final surf = level.surface[x];
    var w = 1;
    while (x + w < level.cols && level.surface[x + w] == surf) {
      w++;
    }
    x = _emit(runs, x, w, (at, len) => GroundRun(x: at, w: len, surf: surf));
  }
  return runs;
}

/// The level's blocks in maximal runs, skipping the columns that hold none: a
/// run is a span of columns the game writes one packed byte to.
List<BlockRun> blockRunsOf(JumpLevel level) {
  final runs = <BlockRun>[];
  var x = 0;
  while (x < level.cols) {
    final v = level.blocks[x];
    if (v == kNoBlock) {
      x++;
      continue;
    }
    var w = 1;
    while (x + w < level.cols && level.blocks[x + w] == v) {
      w++;
    }
    x = _emit(
      runs,
      x,
      w,
      (at, len) => BlockRun(
          x: at, w: len, row: blockRowOf(v), kind: blockKindOf(v)),
    );
  }
  return runs;
}

/// Split one maximal run into records and return the next column to look at.
int _emit<T>(List<T> runs, int x, int w, T Function(int at, int len) record) {
  while (w > kMaxRunColumns) {
    runs.add(record(x, kMaxRunColumns));
    x += kMaxRunColumns;
    w -= kMaxRunColumns;
  }
  runs.add(record(x, w));
  return x + w;
}

/// The level as the game reads it. Throws when a count cannot be written in the
/// single byte the form gives it, which [validate] reports before an export
/// ever gets this far.
Uint8List encodeWire(JumpLevel level) {
  final ground = groundRunsOf(level);
  final blocks = blockRunsOf(level);

  _fits(ground.length, 'ground runs');
  _fits(blocks.length, 'block runs');
  _fits(level.pipes.length, 'pipes');
  _fits(level.coins.length, 'coins');
  _fits(level.enemies.length, 'enemies');

  final size = 8 +
      3 * ground.length +
      4 * blocks.length +
      3 * level.pipes.length +
      2 * level.coins.length +
      4 * level.enemies.length;
  final out = Uint8List(size);
  var at = 0;

  out[at++] = kWireVersion;
  out[at++] = level.startX;
  out[at++] = level.checkpointX;
  out[at++] = ground.length;
  out[at++] = blocks.length;
  out[at++] = level.pipes.length;
  out[at++] = level.coins.length;
  out[at++] = level.enemies.length;

  for (final r in ground) {
    out[at++] = r.x;
    out[at++] = r.w;
    out[at++] = r.surf;
  }
  for (final r in blocks) {
    out[at++] = r.x;
    out[at++] = r.w;
    out[at++] = r.row;
    out[at++] = r.kind;
  }
  for (final p in level.pipes) {
    out[at++] = p.x;
    out[at++] = p.h;
    out[at++] = p.plant;
  }
  for (final c in level.coins) {
    out[at++] = c.x;
    out[at++] = c.y;
  }
  for (final e in level.enemies) {
    out[at++] = e.x;
    out[at++] = e.row;
    out[at++] = e.dir & 0xFF;
    out[at++] = e.kind;
  }

  return out;
}

void _fits(int count, String what) {
  if (count > 255) {
    throw StateError(
      'A level cannot carry $count $what: the wire counts them in one byte.',
    );
  }
}
