// The trip out to the C tables and back.
//
// The contract is semantic, not textual: re-importing the text an export wrote
// must yield the level it was written from, and the level must be the columns
// the source resolves to. Nothing here pins how an export splits its runs - that
// is why an export of an unedited level is a small, explainable diff.

import 'package:flutter_test/flutter_test.dart';
import 'package:jumpman_editor/src/jump_level.dart';
import 'package:jumpman_editor/src/jumpman_spec.dart';
import 'package:jumpman_editor/src/level_source.dart';

import 'support.dart';

void main() {
  test('the shipped level survives the trip through the tables', () {
    final spec = readSpec();
    final source = readGameSource();
    final path = gameSourceFile.path;

    final authored =
        LevelSource.importFrom(source: source, spec: spec, path: path);
    final text =
        LevelSource.apply(level: authored, source: source, spec: spec, path: path);
    final again = LevelSource.importFrom(source: text, spec: spec, path: path);

    expect(again, authored);
    expect(again.surface, authored.surface);
    expect(again.blocks, authored.blocks);
    expect(again.startX, authored.startX);
    expect(again.checkpointX, authored.checkpointX);
    expect(again.pipes, authored.pipes);
    expect(again.coins, authored.coins);
    expect(again.enemies, authored.enemies);
  });

  test('the imported level is the columns the source resolves to', () {
    final spec = readSpec();
    final level = readAuthoredLevel(spec);
    final resolved = _resolveColumns(readGameSource(), spec);

    for (var x = 0; x < spec.cols; x++) {
      expect(level.surfaceAt(x), resolved.surface[x], reason: 'column $x surface');
      expect(level.blocks[x], resolved.blocks[x], reason: 'column $x block');
    }
    expect(level.startX, spec.startX);
    expect(level.checkpointX, spec.checkpointX);
    expect(level.pipes.single.x, 66);
    expect(level.pipes.single.h, 5);
    expect(level.coins, hasLength(11));
    expect(level.enemies, hasLength(6));
  });

  test('the exported block table is the merged runs, and the width follows', () {
    final spec = readSpec();
    final source = readGameSource();
    final text = LevelSource.apply(
      level: readAuthoredLevel(spec),
      source: source,
      spec: spec,
      path: gameSourceFile.path,
    );

    // The shipped table states the staircase as three columns of stacked stone;
    // a level stored per column has that as three runs, and the sum of the run
    // widths is what the game's own fit assert checks.
    expect(text, contains('#define JM_LEVEL_BLOCK_COLS 17'));
    final block = LevelSource.tables(text, gameSourceFile.path)
        .firstWhere((t) => t.kind == 'block');
    expect(RegExp(r'\{[^{}]*\}').allMatches(block.body).length, 7);

    final ground = LevelSource.tables(text, gameSourceFile.path)
        .firstWhere((t) => t.kind == 'ground');
    expect(RegExp(r'\{[^{}]*\}').allMatches(ground.body).length, 7);
  });

  test('the export leaves every other byte of the file alone', () {
    final spec = readSpec();
    final source = readGameSource();
    final path = gameSourceFile.path;
    final text = LevelSource.apply(
      level: readAuthoredLevel(spec),
      source: source,
      spec: spec,
      path: path,
    );

    // Everything outside the five tables and the three #defines has to be the
    // same text: comments, the vtable, the physics, all of it.
    expect(_withoutLevel(text), _withoutLevel(source));

    // And an export of what an export wrote is the same text again: the writer
    // has no state of its own to drift.
    final again = LevelSource.apply(
      level: LevelSource.importFrom(source: text, spec: spec, path: path),
      source: text,
      spec: spec,
      path: path,
    );
    expect(again, text);
  });

  test('a level with no coins, pipes, enemies or blocks still writes legal C',
      () {
    final spec = readSpec();
    final source = readGameSource();
    final path = gameSourceFile.path;
    final empty = JumpLevel.empty(spec);
    final text = LevelSource.apply(
        level: empty, source: source, spec: spec, path: path);
    final again = LevelSource.importFrom(source: text, spec: spec, path: path);

    expect(again, empty);
    expect(again.coins, isEmpty);
    expect(again.pipes, isEmpty);
    expect(again.enemies, isEmpty);
    expect(again.blocks.every((b) => b == kNoBlock), isTrue);
    expect(text, contains('#define JM_LEVEL_BLOCK_COLS 0'));
    // Every table is still a declaration with at least one record in it, which
    // is what C requires of an array.
    for (final table in LevelSource.tables(text, path)) {
      expect(RegExp(r'\{[^{}]*\}').allMatches(table.body), isNotEmpty,
          reason: '${table.name} has no records');
    }
  });

  test('a synthetic level survives the trip field by field', () {
    final spec = readSpec();
    final source = readGameSource();
    final path = gameSourceFile.path;
    final level = readAuthoredLevel(spec).clone();

    // A thirty-column pit, a five-row pipe with a plant, one coin, every enemy
    // kind, and the checkpoint moved.
    for (var x = 40; x < 70; x++) {
      level.surface[x] = kPit;
    }
    level.pipes
      ..clear()
      ..add(JumpPipe(x: 90, h: 5, plant: 1));
    level.coins
      ..clear()
      ..add(JumpCoin(x: 27, y: 11));
    level.enemies
      ..clear()
      ..addAll([
        for (final kind in spec.enemyKinds)
          JumpEnemy(x: 60 + kind.value * 7, row: 19, dir: -1, kind: kind.value),
      ]);
    level.blocks.fillRange(0, spec.cols, kNoBlock);
    level.blocks[2] = packBlock(spec.blockKindBySuffix('MUSH')!.value, 6);
    level.startX = 5;
    level.checkpointX = 200;

    final text = LevelSource.apply(
        level: level, source: source, spec: spec, path: path);
    final again = LevelSource.importFrom(source: text, spec: spec, path: path);

    expect(again, level);
    expect(again.surface[39], spec.groundRow);
    expect(again.surface[40], kPit);
    expect(again.surface[69], kPit);
    expect(again.surface[70], spec.groundRow);
    expect(again.pipes.single.plant, 1);
    expect(again.enemies.map((e) => e.kind), [0, 1, 2]);
    expect(again.checkpointX, 200);
    expect(again.startX, 5);
    expect(again.blockKindAt(2), spec.blockKindBySuffix('MUSH')!.value);
  });

  test('an export refuses a source it cannot find the tables in', () {
    final spec = readSpec();
    final source = readGameSource().replaceFirst(
      RegExp(r'static const jm_ground_def jm_level_ground\[\] = \{[^;]*\};',
          dotAll: true),
      '',
    );
    expect(
      () => LevelSource.apply(
        level: readAuthoredLevel(spec),
        source: source,
        spec: spec,
        path: 'game_jumpman.c',
      ),
      throwsA(isA<LevelSourceException>()
          .having((e) => e.message, 'message', contains('ground'))),
    );
  });
}

/// The source with the level's five tables and three #defines taken out, so two
/// texts can be compared for "everything else is unchanged".
String _withoutLevel(String text) {
  final spans = <List<int>>[
    for (final t in LevelSource.tables(text, 'game_jumpman.c')) [t.start, t.end],
  ];
  final defineRe = RegExp(
    r'^#define[ \t]+(JM_LEVEL_BLOCK_COLS|JM_LEVEL_START_X|JM_LEVEL_CHECKPOINT_X)[ \t]+[^\n]*',
    multiLine: true,
  );
  for (final m in defineRe.allMatches(text)) {
    spans.add([m.start, m.end]);
  }
  spans.sort((a, b) => b[0].compareTo(a[0]));
  var out = text;
  for (final span in spans) {
    out = out.replaceRange(span[0], span[1], '');
  }
  return out;
}

/// The source's own runs resolved per column: later entries win, which is the
/// rule the file's comment states for the staircase's stacked stones. This is
/// independent of the editor's importer on purpose.
class _Resolved {
  _Resolved(this.surface, this.blocks);
  final List<int> surface;
  final List<int> blocks;
}

_Resolved _resolveColumns(String source, JumpmanSpec spec) {
  final cols = spec.cols;
  final groundRow = spec.groundRow;
  final surface = List<int>.filled(cols, kPit);
  final blocks = List<int>.filled(cols, kNoBlock);

  final groundBody = RegExp(
          r'static const jm_ground_def\s+\w+\[\]\s*=\s*\{([^;]*)\};', dotAll: true)
      .firstMatch(source)!
      .group(1)!;
  for (final entry in RegExp(r'\{([^{}]*)\}').allMatches(groundBody)) {
    final f = entry.group(1)!.split(',').map((s) => s.trim()).toList();
    final x = int.parse(f[0]);
    final w = int.parse(f[1]);
    final surf = f[2] == 'JML_PIT' ? kPit : int.parse(f[2]);
    if (surf == kPit) continue;
    for (var i = 0; i < w; i++) {
      surface[x + i] = surf;
    }
  }

  // Pipes raise their columns, exactly as the game does when it loads them.
  final pipeBody = RegExp(
          r'static const jm_pipe_def\s+\w+\[\]\s*=\s*\{([^;]*)\};', dotAll: true)
      .firstMatch(source)!
      .group(1)!;
  for (final entry in RegExp(r'\{([^{}]*)\}').allMatches(pipeBody)) {
    final f = entry.group(1)!.split(',').map((s) => s.trim()).toList();
    final x = int.parse(f[0]);
    final h = int.parse(f[1]);
    for (var i = 0; i < 3; i++) {
      surface[x + i] = groundRow - h;
    }
  }

  final blockBody = RegExp(
          r'static const jm_block_def\s+\w+\[\]\s*=\s*\{([^;]*)\};', dotAll: true)
      .firstMatch(source)!
      .group(1)!;
  for (final entry in RegExp(r'\{([^{}]*)\}').allMatches(blockBody)) {
    final f = entry.group(1)!.split(',').map((s) => s.trim()).toList();
    final x = int.parse(f[0]);
    final w = int.parse(f[1]);
    final row = int.parse(f[2]);
    final kind = _blockKind(f[3]);
    for (var i = 0; i < w; i++) {
      blocks[x + i] = (kind << 5) | row;
    }
  }

  return _Resolved(surface, blocks);
}

int _blockKind(String symbol) {
  const kinds = {
    'BM_BRICK': 1,
    'BM_COIN': 2,
    'BM_MUSH': 3,
    'BM_STONE': 4,
    'BM_USED': 5,
    'BM_BROKEN': 6,
  };
  return kinds[symbol]!;
}
