// The level, in the form the editor edits it.
//
// One byte per column for the ground surface and one for the block, exactly as
// the game stores them, plus the small lists. Per-column is what painting edits
// and what an export merges back into runs.
//
// Two things are worth stating because they are easy to get wrong:
//
// - `surface` holds ground only. A pipe's columns keep their ground surface and
//   the pipe is applied on top of it, exactly as jm_load_level does, so
//   [JumpLevel.surfaceAt] - not `surface` - is the row the game ends up with.
// - A block byte is packed the way the game packs it: kind in the top three
//   bits, row in the low five. The bit arithmetic is the game's own rule; the
//   kinds themselves come from the parsed source (see jumpman_spec.dart).
//
// The level carries the two shape numbers that a pipe and a paint stroke need -
// the ground row and the pipe width - because a level is a level of some shape.
// Everything else about the shape belongs to the spec, which is where the
// editor asks before it builds one.

import 'dart:typed_data';

import 'jumpman_spec.dart';

/// The ground surface byte that means "no ground in this column".
const int kPit = 0xFF;

/// The block byte that means "no block in this column".
const int kNoBlock = 0xFF;

/// `jm_blk_make`: the game's packing of a block's kind and row into one byte.
int packBlock(int kind, int row) => (kind << 5) | row;

/// `jm_blk_kind`.
int blockKindOf(int packed) => packed >> 5;

/// `jm_blk_row`.
int blockRowOf(int packed) => packed & 31;

/// A pipe: [x] is its left column, [h] how many rows it stands above the ground
/// row, [plant] whether a piranha plant lives in it.
class JumpPipe {
  JumpPipe({required this.x, required this.h, required this.plant});

  int x;
  int h;
  int plant;

  JumpPipe clone() => JumpPipe(x: x, h: h, plant: plant);

  Map<String, Object?> toJson() => {'x': x, 'h': h, 'plant': plant};

  @override
  bool operator ==(Object other) =>
      other is JumpPipe && other.x == x && other.h == h && other.plant == plant;

  @override
  int get hashCode => Object.hash(x, h, plant);

  @override
  String toString() => 'Pipe(x: $x, h: $h, plant: $plant)';
}

/// A coin: the top-left of its 2x2 box, in world pixels.
class JumpCoin {
  JumpCoin({required this.x, required this.y});

  int x;
  int y;

  JumpCoin clone() => JumpCoin(x: x, y: y);

  Map<String, Object?> toJson() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      other is JumpCoin && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Coin(x: $x, y: $y)';
}

/// An enemy: [x] its left column, [row] the surface its feet rest on, [dir] -1,
/// 0 or 1, and [kind] the game's own enemy kind value.
class JumpEnemy {
  JumpEnemy({
    required this.x,
    required this.row,
    required this.dir,
    required this.kind,
  });

  int x;
  int row;
  int dir;
  int kind;

  JumpEnemy clone() => JumpEnemy(x: x, row: row, dir: dir, kind: kind);

  Map<String, Object?> toJson(JumpmanSpec spec) {
    final k = spec.enemyKindByValue(kind);
    return {'x': x, 'row': row, 'dir': dir, 'kind': k?.suffix ?? kind};
  }

  @override
  bool operator ==(Object other) =>
      other is JumpEnemy &&
      other.x == x &&
      other.row == row &&
      other.dir == dir &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(x, row, dir, kind);

  @override
  String toString() => 'Enemy(x: $x, row: $row, dir: $dir, kind: $kind)';
}

/// Thrown when a level file cannot be read. The message names the file and what
/// is wrong with it; the editor never silently truncates a level.
class LevelFormatException implements Exception {
  const LevelFormatException(this.message);
  final String message;
  @override
  String toString() => 'LevelFormatException: $message';
}

/// The format name a project file carries, and the version this editor writes.
const String kLevelFormat = 'jumpman-level';
const int kLevelVersion = 1;

/// One level.
class JumpLevel {
  JumpLevel({
    required this.surface,
    required this.blocks,
    required this.startX,
    required this.checkpointX,
    required this.groundRow,
    required this.pipeW,
    required List<JumpPipe> pipes,
    required List<JumpCoin> coins,
    required List<JumpEnemy> enemies,
  })  : pipes = pipes,
        coins = coins,
        enemies = enemies;

  /// The ground surface row of each column, or [kPit]. Pipes do not appear
  /// here: see [surfaceAt].
  final Uint8List surface;

  /// The packed block byte of each column, or [kNoBlock].
  final Uint8List blocks;

  /// The column a run starts on.
  int startX;

  /// The column a death after the checkpoint puts the player back on.
  int checkpointX;

  /// The row plain ground sits on: what a pipe's height is measured from.
  final int groundRow;

  /// How many columns a pipe covers.
  final int pipeW;

  final List<JumpPipe> pipes;
  final List<JumpCoin> coins;
  final List<JumpEnemy> enemies;

  int get cols => surface.length;

  /// A level with nothing in it but ground: every column solid, the start and
  /// the checkpoint where the game's own level puts them.
  factory JumpLevel.empty(JumpmanSpec spec) => JumpLevel(
        surface: Uint8List(spec.cols)..fillRange(0, spec.cols, spec.groundRow),
        blocks: Uint8List(spec.cols)..fillRange(0, spec.cols, kNoBlock),
        startX: spec.startX,
        checkpointX: spec.checkpointX,
        groundRow: spec.groundRow,
        pipeW: spec.pipeW,
        pipes: <JumpPipe>[],
        coins: <JumpCoin>[],
        enemies: <JumpEnemy>[],
      );

  JumpLevel clone() => JumpLevel(
        surface: Uint8List.fromList(surface),
        blocks: Uint8List.fromList(blocks),
        startX: startX,
        checkpointX: checkpointX,
        groundRow: groundRow,
        pipeW: pipeW,
        pipes: pipes.map((p) => p.clone()).toList(),
        coins: coins.map((c) => c.clone()).toList(),
        enemies: enemies.map((e) => e.clone()).toList(),
      );

  // ---------------------------------------------------------------- lookup

  /// The surface row the game ends up with at [x]: a pipe's top for a column
  /// inside a pipe, otherwise the ground.
  int surfaceAt(int x) =>
      pipeTopAt(x) ?? ((x < 0 || x >= cols) ? kPit : surface[x]);

  /// The pipe covering [x], if any.
  JumpPipe? pipeAt(int x) {
    for (final p in pipes) {
      if (x >= p.x && x < p.x + pipeW) return p;
    }
    return null;
  }

  /// The top row of the pipe covering [x], if any. A pipe stands [JumpPipe.h]
  /// rows above the ground row.
  int? pipeTopAt(int x) {
    final p = pipeAt(x);
    return p == null ? null : groundRow - p.h;
  }

  bool isPit(int x) => x >= 0 && x < cols && surface[x] == kPit;

  /// The block byte at [x], or [kNoBlock].
  int blockAt(int x) => (x < 0 || x >= cols) ? kNoBlock : blocks[x];

  /// The block kind at [x], or null when the column holds no block.
  int? blockKindAt(int x) {
    final v = blockAt(x);
    return v == kNoBlock ? null : blockKindOf(v);
  }

  /// The block's top row at [x], or null.
  int? blockRowAt(int x) {
    final v = blockAt(x);
    return v == kNoBlock ? null : blockRowOf(v);
  }

  /// The coin whose 2x2 box covers the world pixel ([x], [y]).
  JumpCoin? coinAt(int x, int y) {
    for (final c in coins) {
      if (x >= c.x && x < c.x + 2 && y >= c.y && y < c.y + 2) return c;
    }
    return null;
  }

  /// The enemy standing at column [x], if any.
  JumpEnemy? enemyAt(int x) {
    for (final e in enemies) {
      if (e.x == x) return e;
    }
    return null;
  }

  // ------------------------------------------------------------------ JSON

  /// The project file for this level. Kinds are written by their game-source
  /// suffix, so the file reads like the game's own table.
  Map<String, Object?> toJson(JumpmanSpec spec, String name) => {
        'format': kLevelFormat,
        'version': kLevelVersion,
        'name': name,
        'cols': cols,
        'start_x': startX,
        'checkpoint_x': checkpointX,
        'surface': surface.toList(),
        'blocks': blocks.toList(),
        'pipes': pipes.map((p) => p.toJson()).toList(),
        'coins': coins.map((c) => c.toJson()).toList(),
        'enemies': enemies.map((e) => e.toJson(spec)).toList(),
      };

  /// Read a project file. [path] only names the file in an error.
  static JumpLevel fromJson(
    Map<String, Object?> json,
    JumpmanSpec spec, {
    required String path,
  }) {
    if (json['format'] != kLevelFormat) {
      throw LevelFormatException(
        '$path is not a $kLevelFormat project (it says "${json['format']}").',
      );
    }
    if (json['version'] != kLevelVersion) {
      throw LevelFormatException(
        '$path is version ${json['version']} of the $kLevelFormat format; this '
        'editor reads version $kLevelVersion.',
      );
    }
    final cols = _int(json, 'cols', path);
    if (cols != spec.cols) {
      throw LevelFormatException(
        '$path is $cols columns wide; the game is compiled for ${spec.cols}. '
        'The editor will not silently truncate or pad a level.',
      );
    }
    final surface = _bytes(json, 'surface', spec.cols, path);
    final blocks = _bytes(json, 'blocks', spec.cols, path);

    for (var x = 0; x < spec.cols; x++) {
      final v = blocks[x];
      if (v == kNoBlock) continue;
      final kind = blockKindOf(v);
      if (spec.blockKindByValue(kind) == null) {
        throw LevelFormatException(
          '$path: column $x holds block byte $v, whose kind $kind is not one of '
          "the game's blocks.",
        );
      }
    }

    final pipes = <JumpPipe>[];
    for (final raw in _objects(json, 'pipes', path)) {
      pipes.add(JumpPipe(
        x: _int(raw, 'x', path),
        h: _int(raw, 'h', path),
        plant: _int(raw, 'plant', path),
      ));
    }

    final coins = <JumpCoin>[];
    for (final raw in _objects(json, 'coins', path)) {
      coins.add(JumpCoin(x: _int(raw, 'x', path), y: _int(raw, 'y', path)));
    }

    final enemies = <JumpEnemy>[];
    for (final raw in _objects(json, 'enemies', path)) {
      final name = raw['kind'];
      final kind = name is String ? spec.enemyKindBySuffix(name) : null;
      if (kind == null) {
        throw LevelFormatException(
          '$path names the enemy kind "$name", which the game source does not '
          'declare.',
        );
      }
      enemies.add(JumpEnemy(
        x: _int(raw, 'x', path),
        row: _int(raw, 'row', path),
        dir: _int(raw, 'dir', path),
        kind: kind.value,
      ));
    }

    return JumpLevel(
      surface: surface,
      blocks: blocks,
      startX: _int(json, 'start_x', path),
      checkpointX: _int(json, 'checkpoint_x', path),
      groundRow: spec.groundRow,
      pipeW: spec.pipeW,
      pipes: pipes,
      coins: coins,
      enemies: enemies,
    );
  }

  static int _int(Map<String, Object?> json, String key, String path) {
    final v = json[key];
    if (v is! int) {
      throw LevelFormatException(
        '$path: "$key" is $v, and it must be an integer.',
      );
    }
    return v;
  }

  static Uint8List _bytes(
      Map<String, Object?> json, String key, int want, String path) {
    final list = json[key];
    if (list is! List) {
      throw LevelFormatException('$path: "$key" is not a list of columns.');
    }
    if (list.length != want) {
      throw LevelFormatException(
        '$path: "$key" has ${list.length} columns and the level has $want.',
      );
    }
    final out = Uint8List(want);
    for (var i = 0; i < want; i++) {
      final v = list[i];
      if (v is! int || v < 0 || v > 255) {
        throw LevelFormatException(
          '$path: "$key" column $i is $v, which is not a byte.',
        );
      }
      out[i] = v;
    }
    return out;
  }

  static List<Map<String, Object?>> _objects(
      Map<String, Object?> json, String key, String path) {
    final list = json[key] ?? const <Object?>[];
    if (list is! List) {
      throw LevelFormatException('$path: "$key" is not a list.');
    }
    final out = <Map<String, Object?>>[];
    for (final item in list) {
      if (item is! Map<String, Object?>) {
        throw LevelFormatException('$path: "$key" holds $item, not an object.');
      }
      out.add(item);
    }
    return out;
  }

  // ------------------------------------------------------------ comparison

  @override
  bool operator ==(Object other) {
    if (other is! JumpLevel) return false;
    if (other.cols != cols ||
        other.startX != startX ||
        other.checkpointX != checkpointX) {
      return false;
    }
    for (var i = 0; i < cols; i++) {
      if (other.surface[i] != surface[i] || other.blocks[i] != blocks[i]) {
        return false;
      }
    }
    return _sameList(other.pipes, pipes) &&
        _sameList(other.coins, coins) &&
        _sameList(other.enemies, enemies);
  }

  static bool _sameList<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(surface),
        Object.hashAll(blocks),
        startX,
        checkpointX,
        Object.hashAll(pipes),
        Object.hashAll(coins),
        Object.hashAll(enemies),
      );

  @override
  String toString() => 'JumpLevel($cols columns, ${pipes.length} pipes, '
      '${coins.length} coins, ${enemies.length} enemies)';
}
