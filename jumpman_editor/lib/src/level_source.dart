// The level's tables inside the game's own source.
//
// game_jumpman.c holds the level as five `static const` tables plus the three
// `#define`s that are not tables: where a run starts, where a death returns the
// player to, and how many columns of block the table places. Import reads those
// out and export writes them back, replacing nothing else in the file - every
// other byte, comments included, is preserved.
//
// The round trip is semantic, not textual. Re-importing what an export wrote
// yields the level it was written from; whitespace, comments and where the runs
// are split may differ, because the editor stores a level per column and
// re-derives the runs. An export of an unedited level is therefore a small,
// explainable diff rather than a no-op: the shipped block table's stacked stones
// collapse into the columns they resolve to.
//
// One case needs a word: a level may have no coins at all, and C has no empty
// array. A table with no records is written as a single record that is not one -
// a run of no columns, a pipe standing no rows, a box outside the field - which
// the game ignores for the same reason the wire's check refuses it. See
// jm_load_level, and _emptyRecord below.

import 'dart:typed_data';

import 'jump_level.dart';
import 'jumpman_spec.dart';
import 'wire.dart';

/// Thrown when the game's source cannot be read as a level, or when an export
/// would not find what it is replacing. The message names the file and what is
/// wrong with it, and nothing is written on the way out.
class LevelSourceException implements Exception {
  const LevelSourceException(this.message);
  final String message;
  @override
  String toString() => 'LevelSourceException: $message';
}

/// One of the five level tables, as it appears in the source.
class LevelTable {
  const LevelTable({
    required this.kind,
    required this.name,
    required this.start,
    required this.end,
    required this.body,
  });

  /// `ground`, `block`, `pipe`, `coin` or `enemy`.
  final String kind;

  /// The table's own symbol, e.g. `jm_level_ground`.
  final String name;

  final int start;
  final int end;
  final String body;
}

/// Reading a level out of the game's source, and writing one back into it.
class LevelSource {
  const LevelSource._();

  /// The tables a level is stated as, in the order the source declares them.
  static const List<String> kinds = [
    'ground',
    'block',
    'pipe',
    'coin',
    'enemy',
  ];

  static final RegExp _declaration = RegExp(
    r'static const jm_(ground|block|pipe|coin|enemy)_def\s+(jm_level_\w+)\[\]\s*=\s*\{[^;]*\};',
    multiLine: true,
    dotAll: true,
  );

  static final RegExp _entry = RegExp(r'\{([^{}]*)\}');

  /// The five declarations in [source]. Throws when one is absent or appears
  /// twice: an export must know exactly what it is replacing.
  static List<LevelTable> tables(String source, String path) {
    final found = <String, List<LevelTable>>{};
    for (final m in _declaration.allMatches(source)) {
      final kind = m.group(1)!;
      found.putIfAbsent(kind, () => <LevelTable>[]).add(LevelTable(
            kind: kind,
            name: m.group(2)!,
            start: m.start,
            end: m.end,
            body: m.group(0)!,
          ));
    }

    final out = <LevelTable>[];
    for (final kind in kinds) {
      final list = found[kind] ?? const <LevelTable>[];
      if (list.isEmpty) {
        throw LevelSourceException(
          '$path has no `static const jm_${kind}_def jm_level_*[]` table. Every '
          'level is stated as five tables, and the editor will not guess one.',
        );
      }
      if (list.length > 1) {
        throw LevelSourceException(
          '$path declares ${list.length} ${kind} tables '
          '(${list.map((t) => t.name).join(', ')}). The level must be one of '
          'each, or an export would pick for you.',
        );
      }
      out.add(list.first);
    }
    return out;
  }

  // -------------------------------------------------------------- importing

  /// The level the game's source states.
  static JumpLevel importFrom({
    required String source,
    required JumpmanSpec spec,
    required String path,
  }) {
    final byKind = {
      for (final t in tables(source, path)) t.kind: t,
    };

    final surface = Uint8List(spec.cols)..fillRange(0, spec.cols, kPit);
    final blocks = Uint8List(spec.cols)..fillRange(0, spec.cols, kNoBlock);

    final blockKinds = {
      for (final k in spec.blockKinds) k.symbol: k.value,
    };
    final enemyKinds = {
      for (final k in spec.enemyKinds) k.symbol: k.value,
    };
    const groundSymbols = {'JML_PIT': kPit};

    for (final fields in _fields(byKind['ground']!, path)) {
      _need(fields, 3, 'ground', byKind['ground']!, path);
      final x = _number(fields[0], path: path, what: 'a ground column');
      final w = _number(fields[1], path: path, what: 'a ground run width');
      final surf = _number(fields[2],
          path: path, what: 'a ground surface', symbols: groundSymbols);
      if (w == 0) continue; // a record that is not a run: see the file's header
      if (x < 0 || x + w > spec.cols) {
        throw LevelSourceException(
          '$path: the ground run at column $x is $w columns wide and leaves the '
          '${spec.cols}-column level.',
        );
      }
      if (surf == kPit) continue;
      surface.fillRange(x, x + w, surf);
    }

    for (final fields in _fields(byKind['block']!, path)) {
      _need(fields, 4, 'block', byKind['block']!, path);
      final x = _number(fields[0], path: path, what: 'a block column');
      final w = _number(fields[1], path: path, what: 'a block run width');
      final row = _number(fields[2], path: path, what: 'a block row');
      final kind = _number(fields[3],
          path: path, what: 'a block kind', symbols: blockKinds);
      if (w == 0) continue;
      if (x < 0 || x + w > spec.cols) {
        throw LevelSourceException(
          '$path: the block run at column $x is $w columns wide and leaves the '
          '${spec.cols}-column level.',
        );
      }
      // Later entries win, which is the rule the file's own comment states for
      // the staircase's stacked stones.
      blocks.fillRange(x, x + w, packBlock(kind, row));
    }

    final pipes = <JumpPipe>[];
    for (final fields in _fields(byKind['pipe']!, path)) {
      _need(fields, 3, 'pipe', byKind['pipe']!, path);
      final x = _number(fields[0], path: path, what: 'a pipe column');
      final h = _number(fields[1], path: path, what: 'a pipe height');
      final plant = _number(fields[2], path: path, what: 'a pipe flag');
      if (h == 0) continue;
      if (x < 0 || x + spec.pipeW > spec.cols) {
        throw LevelSourceException(
          '$path: the pipe at column $x does not fit the ${spec.cols}-column '
          'level.',
        );
      }
      pipes.add(JumpPipe(x: x, h: h, plant: plant));
    }

    final coins = <JumpCoin>[];
    for (final fields in _fields(byKind['coin']!, path)) {
      _need(fields, 2, 'coin', byKind['coin']!, path);
      final x = _number(fields[0], path: path, what: 'a coin column');
      final y = _number(fields[1], path: path, what: 'a coin row');
      if (x + 2 > spec.cols || y + 2 > spec.rows) continue;
      coins.add(JumpCoin(x: x, y: y));
    }

    final enemies = <JumpEnemy>[];
    for (final fields in _fields(byKind['enemy']!, path)) {
      _need(fields, 4, 'enemy', byKind['enemy']!, path);
      final x = _number(fields[0], path: path, what: 'an enemy column');
      final row = _number(fields[1], path: path, what: 'an enemy row');
      final dir = _number(fields[2], path: path, what: 'an enemy direction');
      final kind = _number(fields[3],
          path: path, what: 'an enemy kind', symbols: enemyKinds);
      if (x >= spec.cols || row >= spec.rows) continue;
      enemies.add(JumpEnemy(x: x, row: row, dir: dir, kind: kind));
    }

    return JumpLevel(
      surface: surface,
      blocks: blocks,
      // The run's two columns are part of the level, not of the game's
      // constants: the source states them with the tables, so the level's own
      // #defines are what an import reads.
      startX: _define(source, 'JM_LEVEL_START_X', path),
      checkpointX: _define(source, 'JM_LEVEL_CHECKPOINT_X', path),
      groundRow: spec.groundRow,
      pipeW: spec.pipeW,
      pipes: pipes,
      coins: coins,
      enemies: enemies,
    );
  }

  /// One of the level's own `#define`s. Throws when it is missing, doubled or
  /// not a number: a level that does not say where its run starts is not one the
  /// editor will guess at.
  static int _define(String source, String name, String path) {
    final re = RegExp(r'^#define[ \t]+' + name + r'[ \t]+([^\n]*)', multiLine: true);
    final matches = re.allMatches(source).toList();
    if (matches.isEmpty) {
      throw LevelSourceException(
        '$path does not define $name, so it does not state what the level is.',
      );
    }
    if (matches.length > 1) {
      throw LevelSourceException('$path defines $name ${matches.length} times.');
    }
    final value = _stripComment(matches.first.group(1)!).trim();
    final parsed = int.tryParse(value);
    if (parsed == null) {
      throw LevelSourceException(
        '$path states $name as "$value", which is not a column.',
      );
    }
    return parsed;
  }

  /// The `{ ... }` records of a table, as trimmed field lists.
  static List<List<String>> _fields(LevelTable table, String path) {
    final out = <List<String>>[];
    for (final m in _entry.allMatches(table.body)) {
      final text = m.group(1)!.trim();
      if (text.isEmpty) continue;
      out.add([
        for (final f in text.split(','))
          _stripComment(f).trim(),
      ]);
    }
    return out;
  }

  static String _stripComment(String text) {
    final block = text.indexOf('/*');
    final line = text.indexOf('//');
    var cut = text.length;
    if (block >= 0) cut = block;
    if (line >= 0 && line < cut) cut = line;
    return text.substring(0, cut);
  }

  static void _need(List<String> fields, int n, String kind, LevelTable table,
      String path) {
    if (fields.length != n) {
      throw LevelSourceException(
        '$path: a ${table.name} record has ${fields.length} fields and a $kind '
        'record has $n.',
      );
    }
  }

  static int _number(
    String text, {
    required String path,
    required String what,
    Map<String, int> symbols = const {},
  }) {
    final t = text.trim();
    if (RegExp(r'^-?[0-9]+$').hasMatch(t)) return int.parse(t);
    if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(t)) {
      return int.parse(t.substring(2), radix: 16);
    }
    final named = symbols[t];
    if (named == null) {
      throw LevelSourceException(
        '$path: "$t" is neither a number nor a symbol this game declares as '
        '$what.',
      );
    }
    return named;
  }

  // -------------------------------------------------------------- exporting

  /// [source] with the level's tables and the three `#define`s replaced by
  /// [level]. Throws - before anything is written - when a table or a define is
  /// missing or appears twice.
  static String apply({
    required JumpLevel level,
    required String source,
    required JumpmanSpec spec,
    required String path,
  }) {
    if (level.cols != spec.cols) {
      throw LevelSourceException(
        'the level is ${level.cols} columns wide and $path is compiled for '
        '${spec.cols}.',
      );
    }

    tables(source, path); // every table must be there, exactly once

    var out = source;
    for (final kind in kinds) {
      // Each replacement changes the text's length, so the declarations are
      // found again by name rather than by tracking a delta.
      final table = tables(out, path).firstWhere((t) => t.kind == kind);
      out = out.replaceRange(
        table.start,
        table.end,
        _tableText(
          kind: kind,
          name: table.name,
          spec: spec,
          level: level,
        ),
      );
    }

    out = _replaceDefine(out, 'JM_LEVEL_BLOCK_COLS',
        _blockColumns(level).toString(), path);
    out = _replaceDefine(
        out, 'JM_LEVEL_START_X', level.startX.toString(), path);
    out = _replaceDefine(
        out, 'JM_LEVEL_CHECKPOINT_X', level.checkpointX.toString(), path);

    return out;
  }

  /// The number of columns the block table places, which is what the game's own
  /// fit assert checks it against.
  static int _blockColumns(JumpLevel level) {
    var total = 0;
    for (final run in blockRunsOf(level)) {
      total += run.w;
    }
    return total;
  }

  static String _replaceDefine(
      String source, String name, String value, String path) {
    final re = RegExp(r'^(#define[ \t]+' + name + r'[ \t]+)([^\n]*)',
        multiLine: true);
    final matches = re.allMatches(source).toList();
    if (matches.isEmpty) {
      throw LevelSourceException(
        '$path does not define $name, so an export would not know where to '
        'state it.',
      );
    }
    if (matches.length > 1) {
      throw LevelSourceException(
        '$path defines $name ${matches.length} times.',
      );
    }
    final m = matches.first;
    final rest = m.group(2)!;
    final comment = RegExp(r'/\*|//').firstMatch(rest);
    final tail = comment == null ? '' : ' ${rest.substring(comment.start)}';
    return source.replaceRange(
        m.start, m.end, '${m.group(1)!}$value$tail');
  }

  static String _tableText({
    required String kind,
    required String name,
    required JumpmanSpec spec,
    required JumpLevel level,
  }) {
    final entries = <String>[];
    switch (kind) {
      case 'ground':
        for (final r in groundRunsOf(level)) {
          entries.add('{ ${r.x.toString().padLeft(4)}, '
              '${r.w.toString().padLeft(3)}, '
              '${r.surf == kPit ? 'JML_PIT' : r.surf} }');
        }
        if (entries.isEmpty) {
          entries.add('{ ${0.toString().padLeft(4)}, '
              '${0.toString().padLeft(3)}, ${spec.groundRow} }');
        }
        break;
      case 'block':
        final first = spec.blockKinds.first.symbol;
        for (final r in blockRunsOf(level)) {
          final symbol = spec.blockKindByValue(r.kind)?.symbol ?? first;
          entries.add('{ ${r.x.toString().padLeft(4)}, ${r.w}, '
              '${r.row.toString().padLeft(2)}, $symbol }');
        }
        if (entries.isEmpty) entries.add('{    0, 0, 0, $first }');
        break;
      case 'pipe':
        for (final p in level.pipes) {
          entries.add('{ ${p.x.toString().padLeft(4)}, ${p.h}, ${p.plant} }');
        }
        if (entries.isEmpty) entries.add('{    0, 0, 0 }');
        break;
      case 'coin':
        for (final c in level.coins) {
          entries.add('{ ${c.x.toString().padLeft(4)}, '
              '${c.y.toString().padLeft(2)} }');
        }
        if (entries.isEmpty) entries.add('{ 255, 255 }');
        break;
      case 'enemy':
        final first = spec.enemyKinds.first.symbol;
        for (final e in level.enemies) {
          final symbol = spec.enemyKindByValue(e.kind)?.symbol ?? first;
          entries.add('{ ${e.x.toString().padLeft(4)}, '
              '${e.row.toString().padLeft(2)}, '
              '${e.dir.toString().padLeft(2)}, $symbol }');
        }
        if (entries.isEmpty) entries.add('{ 255, 255,  0, $first }');
        break;
    }

    return 'static const jm_${kind}_def $name[] = {${_entryList(entries)}\n};';
  }

  /// Four entries to a line, each with its trailing comma, the way the file
  /// states its tables today.
  static String _entryList(List<String> entries) {
    final out = StringBuffer();
    for (var i = 0; i < entries.length; i++) {
      out.write(i % 4 == 0 ? '\n    ' : ' ');
      out.write('${entries[i]},');
    }
    return out.toString();
  }
}
