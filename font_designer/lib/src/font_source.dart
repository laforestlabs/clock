// Reading and writing fonts/*.font.
//
// The source format is shared with tools/fontgen.py, which compiles these
// files into the C tables the engine draws with. This app is an editor for
// that source, so the file it writes has to stay exactly as fontgen expects
// it -- and, more importantly, has to stay the file the author wrote.
//
// That second requirement is why nothing here re-emits a whole font. A
// rasterized cut is a hundred glyphs of generated art with a header and a
// comment line per glyph; regenerating it from a model would rewrite every
// line the author never touched, turning a one-pixel fix into an unreviewable
// diff. Instead the file is held as its own lines, each glyph remembers which
// of them it occupies, and saving replaces only the rows that actually
// changed.
//
// Both spellings of a glyph are supported, because both exist in the tree.
// Generated cuts write a block:
//
//     # --- 65 A ---
//     65
//       |.#.|
//       |#.#|
//
// and the format also allows the same data inline, which the small
// hand-drawn cuts use:
//
//     65 .#./#.#
//
// A glyph edited in place keeps whichever spelling it came in as, including
// the indentation and the bars.

import 'dart:io';

/// Plane ink characters, in palette order, exactly as tools/fontgen.py has
/// them: '#' is plane 0, the colour a single-colour draw uses.
const String kInkChars = '#*~+';

/// The roles a font may declare. Required, because no bitmap can imply it.
const List<String> kRoles = <String>['text', 'digits', 'icons'];

/// A .font file that cannot be read as one, worded for the person who has to
/// fix it. Never thrown for anything the app can carry on from.
class FontSourceError implements Exception {
  FontSourceError(this.path, this.line, this.message);

  /// Repository-relative path, or the bare name for a file that never loaded.
  final String path;

  /// 1-based line number, or 0 when the problem is not a single line.
  final int line;
  final String message;

  @override
  String toString() => line > 0 ? '$path:$line: $message' : '$path: $message';
}

/// One glyph, and where in the file its pixels live.
class GlyphSource {
  GlyphSource({
    required this.codepoint,
    required this.rows,
    required this.line,
    required this.block,
    required this.rowLines,
    required this.rowPrefix,
    required this.rowSuffix,
  }) : original = List<String>.of(rows);

  final int codepoint;

  /// The cell, one string per row, each character one pixel: an ink character
  /// from [kInkChars] or '.'.
  List<String> rows;

  /// The rows as the file has them, for the dirty test and for reverting.
  final List<String> original;

  /// Index into [FontSource.lines] of the line that opens the glyph.
  final int line;

  /// Whether the rows are their own `|...|` lines.
  final bool block;

  /// For a block glyph, the line index of each row. Empty inline.
  final List<int> rowLines;

  /// The text before and after a row on its own line. Empty for an inline
  /// glyph, and for a block glyph it is the file's own decoration, so saving
  /// a block glyph writes `  |` + row + `|` exactly as it was read.
  final String rowPrefix;
  final String rowSuffix;

  int get width => rows.isEmpty ? 0 : rows.first.length;

  bool get dirty {
    if (rows.length != original.length) return true;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] != original[i]) return true;
    }
    return false;
  }

  /// The first and last column that hold ink, or null when the glyph holds
  /// none at all. A glyph with no ink is all spacing -- a space, or a slot an
  /// icon face leaves empty -- which is why this answers null rather than
  /// pretending its first column is its edge.
  (int, int)? get inkBounds {
    var left = width;
    var right = -1;
    for (final row in rows) {
      for (var x = 0; x < row.length; x++) {
        if (row[x] == '.') continue;
        if (x < left) left = x;
        if (x > right) right = x;
      }
    }
    return right < left ? null : (left, right);
  }

  /// Every listed ink character actually present, so a plane with no pixels
  /// is not offered as something to paint with.
  Set<String> get usedInk => <String>{
        for (final row in rows)
          for (final ch in row.split('')) if (ch != '.') ch,
      };

  void revert() => rows = List<String>.of(original);

  /// Take the current rows as what the file holds. Called after a successful
  /// write, so the glyph stops reporting itself as unsaved.
  void markSaved() {
    original
      ..clear()
      ..addAll(rows);
  }

  /// The glyph as a character where it has one, for labels.
  String get label {
    if (codepoint == 32) return 'space';
    if (codepoint >= 33 && codepoint < 127) return String.fromCharCode(codepoint);
    return 'U+${codepoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';
  }
}

/// One font, parsed. Immutable apart from the glyph rows, which are the
/// thing being edited.
class FontSource {
  FontSource._({
    required this.path,
    required this.lines,
    required this.name,
    required this.role,
    required this.family,
    required this.smooth,
    required this.downscale,
    required this.height,
    required this.baseline,
    required this.gap,
    required this.planes,
    required this.glyphs,
  });

  /// Parse [text] as the contents of [path]. [path] is only used in messages.
  static FontSource parse(String path, String text) {
    final lines = text.split('\n');

    var name = '';
    var role = '';
    var family = '';
    var smooth = true;
    var downscale = false;
    var height = 0;
    var baseline = 0;
    var gap = 1;
    var planes = 1;

    final glyphs = <GlyphSource>[];

    // The block being read, or null between glyphs.
    int? openCodepoint;
    int openLine = 0;
    final openRows = <String>[];
    final openRowLines = <int>[];
    var rowPrefix = '';
    var rowSuffix = '';

    void closeBlock() {
      if (openCodepoint == null) return;
      final cp = openCodepoint!;
      if (height <= 0) {
        throw FontSourceError(path, openLine + 1,
            'glyph $cp appears before @height is declared');
      }
      if (openRows.length != height) {
        throw FontSourceError(
            path,
            openLine + 1,
            'glyph $cp has ${openRows.length} rows, @height says $height');
      }
      glyphs.add(GlyphSource(
        codepoint: cp,
        rows: List<String>.of(openRows),
        line: openLine,
        block: true,
        rowLines: List<int>.of(openRowLines),
        rowPrefix: rowPrefix,
        rowSuffix: rowSuffix,
      ));
      openCodepoint = null;
      openRows.clear();
      openRowLines.clear();
    }

    void addInline(int lineno, int cp, List<String> rows) {
      if (height <= 0) {
        throw FontSourceError(
            path, lineno, 'glyph $cp appears before @height is declared');
      }
      if (rows.length != height) {
        throw FontSourceError(path, lineno,
            'glyph $cp has ${rows.length} rows, @height says $height');
      }
      glyphs.add(GlyphSource(
        codepoint: cp,
        rows: rows,
        line: lineno - 1,
        block: false,
        rowLines: const <int>[],
        rowPrefix: '',
        rowSuffix: '',
      ));
    }

    for (var i = 0; i < lines.length; i++) {
      final lineno = i + 1;
      final line = lines[i].trim();

      // A row of a block glyph. Tested before the comment rule on purpose:
      // '#' is the ink character, so a row of solid ink would otherwise read
      // as a comment. Same order as fontgen.py.
      if (line.startsWith('|')) {
        if (openCodepoint == null) {
          throw FontSourceError(path, lineno,
              'glyph row outside a block: expected a bare codepoint first');
        }
        if (line.length < 2 || !line.endsWith('|')) {
          throw FontSourceError(
              path, lineno, 'glyph row must be bracketed by | on both ends');
        }
        if (openRows.isEmpty) {
          // The first row is where the file's own indentation is read from,
          // so every row of the glyph is written back exactly as it was.
          final trimmed = lines[i].trimLeft();
          rowPrefix = '${lines[i].substring(0, lines[i].length - trimmed.length)}|';
          rowSuffix = '|';
        }
        openRows.add(line.substring(1, line.length - 1));
        openRowLines.add(i);
        continue;
      }

      if (line.isEmpty || line.startsWith('#')) {
        closeBlock();
        continue;
      }

      if (line.startsWith('@')) {
        closeBlock();
        final space = line.indexOf(RegExp(r'\s'));
        if (space < 0) {
          throw FontSourceError(path, lineno, 'malformed directive');
        }
        final key = line.substring(1, space);
        final value = line.substring(space).trim();
        switch (key) {
          case 'name':
            name = value;
          case 'family':
            family = value;
          case 'role':
            if (!kRoles.contains(value)) {
              throw FontSourceError(path, lineno,
                  'unknown @role $value, expected one of ${kRoles.join(', ')}');
            }
            role = value;
          case 'smooth':
          case 'downscale':
            if (value != 'yes' && value != 'no') {
              throw FontSourceError(
                  path, lineno, '@$key expects yes or no, found $value');
            }
            if (key == 'smooth') {
              smooth = value == 'yes';
            } else {
              downscale = value == 'yes';
            }
          case 'planes':
            final n = int.tryParse(value);
            if (n == null || n < 1 || n > kInkChars.length) {
              throw FontSourceError(path, lineno,
                  '@planes expects 1..${kInkChars.length}, found $value');
            }
            planes = n;
          case 'height':
          case 'baseline':
          case 'gap':
            final n = int.tryParse(value);
            if (n == null) {
              throw FontSourceError(path, lineno, '@$key expects a number');
            }
            if (key == 'height') {
              height = n;
            } else if (key == 'baseline') {
              baseline = n;
            } else {
              gap = n;
            }
          default:
            // An unknown directive is kept verbatim by the writer, so the
            // only thing to decide here is whether to draw it. Not knowing it
            // is not a reason to refuse the file.
            break;
        }
        continue;
      }

      closeBlock();
      final space = line.indexOf(RegExp(r'\s'));
      final head = space < 0 ? line : line.substring(0, space);
      final codepoint = int.tryParse(head);
      if (codepoint == null) {
        throw FontSourceError(path, lineno, 'bad codepoint $head');
      }
      if (space < 0) {
        openCodepoint = codepoint;
        openLine = i;
        continue;
      }
      addInline(lineno, codepoint, line.substring(space).trim().split('/'));
    }
    closeBlock();

    if (name.isEmpty) {
      throw FontSourceError(path, 0, 'missing @name');
    }
    if (role.isEmpty) {
      throw FontSourceError(path, 0,
          'missing @role, expected one of ${kRoles.join(', ')}');
    }
    if (height <= 0) {
      throw FontSourceError(path, 0, 'missing or invalid @height');
    }
    if (glyphs.isEmpty) {
      throw FontSourceError(path, 0, 'no glyphs');
    }

    final byCodepoint = <int, GlyphSource>{};
    final allowed = '${kInkChars.substring(0, planes)}.';
    for (final glyph in glyphs) {
      if (byCodepoint.containsKey(glyph.codepoint)) {
        throw FontSourceError(
            path, glyph.line + 1, 'duplicate codepoint ${glyph.codepoint}');
      }
      final widths = glyph.rows.map((r) => r.length).toSet();
      if (widths.length > 1) {
        throw FontSourceError(path, glyph.line + 1,
            'glyph ${glyph.codepoint} has ragged rows $widths');
      }
      for (final row in glyph.rows) {
        for (final ch in row.split('')) {
          if (!allowed.contains(ch)) {
            throw FontSourceError(
                path,
                glyph.line + 1,
                'glyph ${glyph.codepoint} has stray character $ch '
                    '(the font declares $planes plane(s): '
                    '${kInkChars.substring(0, planes)})');
          }
        }
      }
      byCodepoint[glyph.codepoint] = glyph;
    }

    // The runtime indexes glyphs as (codepoint - first), so the range has to
    // be dense. fontgen refuses a gap too; catching it here means the author
    // sees it while editing rather than at the next build.
    final lo = byCodepoint.keys.reduce((a, b) => a < b ? a : b);
    final hi = byCodepoint.keys.reduce((a, b) => a > b ? a : b);
    final missing = <int>[
      for (var c = lo; c <= hi; c++)
        if (!byCodepoint.containsKey(c)) c,
    ];
    if (missing.isNotEmpty) {
      final preview = missing
          .take(8)
          .map((c) => '$c (${String.fromCharCode(c)})')
          .join(', ');
      final more = missing.length > 8 ? ' and ${missing.length - 8} more' : '';
      throw FontSourceError(
          path, 0, 'gap in codepoint range: $preview$more');
    }

    return FontSource._(
      path: path,
      lines: lines,
      name: name,
      role: role,
      family: family.isEmpty ? name : family,
      smooth: smooth,
      downscale: downscale,
      height: height,
      baseline: baseline,
      gap: gap,
      planes: planes,
      glyphs: glyphs,
    );
  }

  static Future<FontSource> read(File file, String path) async =>
      FontSource.parse(path, await file.readAsString());

  /// Repository-relative, with forward slashes.
  final String path;

  /// The file verbatim, so an unedited glyph survives a save byte for byte.
  final List<String> lines;

  final String name;
  final String role;
  final String family;
  final bool smooth;
  final bool downscale;
  final int height;
  final int baseline;
  final int gap;
  final int planes;

  /// In file order, which for a generated cut is codepoint order.
  final List<GlyphSource> glyphs;

  bool get dirty => glyphs.any((g) => g.dirty);

  /// The file as it would be written: the lines it was read from, with the
  /// changed glyph rows replaced.
  String serialize() {
    final out = List<String>.of(lines);
    for (final glyph in glyphs) {
      if (!glyph.dirty) continue;
      if (glyph.block) {
        for (var i = 0; i < glyph.rows.length; i++) {
          out[glyph.rowLines[i]] =
              '${glyph.rowPrefix}${glyph.rows[i]}${glyph.rowSuffix}';
        }
      } else {
        out[glyph.line] = '${glyph.codepoint} ${glyph.rows.join('/')}';
      }
    }
    return out.join('\n');
  }

  GlyphSource? glyph(int codepoint) {
    for (final g in glyphs) {
      if (g.codepoint == codepoint) return g;
    }
    return null;
  }

  /// Adopt the glyphs [other] has changed, leaving everything else spelled as
  /// this source has it.
  ///
  /// A save merges a session's edits into the file as it stands now, rather
  /// than into the text the font was opened with, so that a glyph this
  /// session did not touch keeps whatever the file holds -- including rows
  /// another session or a tool saved since this one opened it.
  void absorb(FontSource other) {
    for (final glyph in other.glyphs) {
      if (!glyph.dirty) continue;
      final mine = this.glyph(glyph.codepoint);
      if (mine != null) mine.rows = List<String>.of(glyph.rows);
    }
  }

  /// The ink characters this font may use, plane 0 first.
  List<String> get inkChars => kInkChars.substring(0, planes).split('');

  /// One line of prose describing the cut, for the header under the picker.
  String get summary {
    final smoothness = smooth ? 'fractional scales anti-alias' : 'whole-pixel steps';
    final scaled = downscale ? ', downscales below 1x' : '';
    return '$family · $role · cell $height, baseline $baseline, gap $gap · '
        '$planes plane${planes == 1 ? '' : 's'} · $smoothness$scaled';
  }
}
