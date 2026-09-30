// The glyph tools: shifting, widening and narrowing a glyph, and undo. These
// are the operations that touch every row at once, so they are the ones where
// a ragged glyph or a lost column would go unnoticed until fontgen refused
// the file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:font_designer/src/designer_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _source = '''
@name     tiny
@role     text
@height   3
@baseline 3
@gap      1
@family   tiny
@smooth   no

65
  |#.|
  |##|
  |#.|

66
  |##|
  |..|
  |.#|

67
  |..#..|
  |.###.|
  |..#..|

68
  |..|
  |..|
  |..|
''';

/// A clock cut: its ten figures are tabular, one cell for all of them, and the
/// engine's `--:--` placeholder leans on the hyphen being the same width as a
/// figure -- `ml_text_width(clock, "--:--")` must equal the width of a real
/// time, or the layout reflows when the first SNTP sync lands.
const String _clock = '''
@name     tinyclock
@role     digits
@height   3
@baseline 3
@gap      1
@family   tinyclock
@smooth   no

45
  |...###...|
  |.........|
  |.........|

46
  |....|
  |....|
  |..#.|

47
  |...##|
  |..##.|
  |.##..|

48
  |..#####..|
  |.##...##.|
  |..#####..|

49
  |...###...|
  |....##...|
  |....##...|
''';

late Directory repo;
late DesignerState state;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    repo = Directory.systemTemp.createTempSync('font-designer-edit');
    Directory('${repo.path}/fonts').createSync();
    Directory('${repo.path}/tools').createSync();
    File('${repo.path}/tools/fontgen.py').writeAsStringSync('raise SystemExit(0)\n');
    File('${repo.path}/fonts/tiny.font').writeAsStringSync(_source);
    File('${repo.path}/fonts/tinyclock.font').writeAsStringSync(_clock);

    state = DesignerState();
    await state.open(repo.path);
  });

  tearDown(() => repo.deleteSync(recursive: true));

  List<String> rows() => state.glyph!.rows;

  test('every edit keeps the rows rectangular', () {
    state.insertColumn(1);
    expect(rows(), <String>['#..', '#.#', '#..'],
        reason: 'the blank column goes in at the index, not after it');
    state.deleteColumn(1);
    expect(rows(), <String>['#.', '##', '#.']);
    state.shiftGlyph(1);
    expect(rows(), <String>['.#', '.#', '.#'],
        reason: 'the right column fell off');
    state.shiftGlyph(-1);
    expect(rows(), <String>['#.', '#.', '#.'],
        reason: 'a shift does not round trip: what fell off the right is gone');
    state.clearGlyph();
    expect(rows(), <String>['..', '..', '..']);
  });

  test('shifting past the edge blanks the row rather than wrapping', () {
    state.shiftGlyph(4);
    expect(rows(), <String>['..', '..', '..']);
    state.undo();
    expect(rows(), <String>['#.', '##', '#.']);
  });

  test('a column cannot be deleted into a zero-width glyph', () {
    state.deleteColumn(1);
    expect(rows(), <String>['#', '#', '#']);
    state.deleteColumn(0);
    expect(rows(), <String>['#', '#', '#'],
        reason: 'width 1 is the floor; a zero-width glyph draws nothing');
  });

  test('undo follows the glyph it belongs to, not the selection', () {
    state.togglePixel(0, 1);
    expect(state.glyph!.codepoint, 65);
    expect(rows()[0], '##');

    state.selectGlyph(66);
    expect(state.glyph!.codepoint, 66);
    state.togglePixel(2, 0);
    expect(rows()[2], '##');

    state.undo();
    expect(state.glyph!.codepoint, 66, reason: 'undo stays on 66');
    expect(rows()[2], '.#');

    state.undo();
    expect(state.glyph!.codepoint, 65,
        reason: 'the next undo switches back to the glyph it changed');
    expect(rows()[0], '#.');

    state.redo();
    expect(rows()[0], '##');
  });

  test('reverting a glyph leaves the others alone', () {
    state.togglePixel(0, 1);
    state.selectGlyph(66);
    state.togglePixel(0, 1);
    expect(state.dirty, isTrue);

    state.revertGlyph();
    expect(state.glyph!.dirty, isFalse);
    expect(state.font!.glyph(65)!.dirty, isTrue);
    expect(state.font!.dirty, isTrue);

    state.revertAll();
    expect(state.font!.dirty, isFalse);
    expect(state.canUndo, isFalse);
  });

  test('a trim takes the blank edge columns and nothing else', () {
    state.selectGlyph(67);
    expect(state.canTrimGlyph, isTrue);
    expect(state.font!.glyph(65)!.width, 2, reason: 'A has ink at both edges');

    state.trimGlyph();
    expect(rows(), <String>['.#.', '###', '.#.']);
    expect(state.glyph!.dirty, isTrue);
    expect(state.canTrimGlyph, isFalse, reason: 'the edges are ink now');
  });

  test('a glyph with no ink keeps its width: a space is all advance', () {
    state.selectGlyph(68);
    expect(state.canTrimGlyph, isFalse);
    state.trimGlyph();
    expect(rows(), <String>['..', '..', '..'],
        reason: 'trimming the space would close the word gap');
    expect(state.glyph!.dirty, isFalse);
  });

  test('trimming the font is one undo step, and leaves the rest alone', () {
    state.trimAllGlyphs();
    expect(state.font!.glyph(67)!.rows, <String>['.#.', '###', '.#.']);
    expect(state.font!.glyph(65)!.rows, <String>['#.', '##', '#.'],
        reason: 'A needed no trimming');
    expect(state.font!.glyph(68)!.rows, <String>['..', '..', '..']);
    expect(state.status, contains('1 of 4 glyphs'));

    state.undo();
    expect(state.font!.glyph(67)!.rows, <String>['..#..', '.###.', '..#..']);
    expect(state.canUndo, isFalse, reason: 'the whole pass was one edit');
    expect(state.font!.dirty, isFalse);

    state.redo();
    expect(state.font!.glyph(67)!.rows, <String>['.#.', '###', '.#.']);
  });

  test('a narrowing edit keeps the marked column inside the glyph', () {
    state.selectGlyph(67);
    state.setCursorColumn(5);
    state.trimGlyph();
    expect(state.glyph!.width, 3);
    expect(state.cursorColumn, 2,
        reason: 'the column tools must not name a column that is gone');
  });

  test('a trim saves as the same file, three rows moved', () async {
    state.selectGlyph(67);
    state.trimGlyph();
    expect(await state.save(), isTrue);

    final written = File('${repo.path}/fonts/tiny.font').readAsStringSync();
    expect(written.split('\n').length, _source.split('\n').length);
    expect(
      written,
      _source.replaceFirst(
        '  |..#..|\n  |.###.|\n  |..#..|',
        '  |.#.|\n  |###|\n  |.#.|',
      ),
    );
  });

  test('a trim keeps a clock cut tabular, hyphen and all', () async {
    await state.selectFont(
        state.refs.firstWhere((r) => r.name == 'tinyclock'));
    final clock = state.font!;
    int width(int cp) => clock.glyph(cp)!.width;
    expect(<int>[width(0x30), width(0x31)], <int>[9, 9],
        reason: 'the two figures came in at one cell, and both are 9 wide');

    state.trimAllGlyphs();

    expect(width(0x30), 7, reason: 'held at the widest ink of the ten');
    expect(width(0x31), 7, reason: 'and the narrow 1 keeps the same cell');
    expect(width(0x2d), width(0x30),
        reason: 'the placeholder hyphen is as wide as a figure, which is what '
            'keeps "--" the width of a real time');
    expect(width(0x2e), 1, reason: 'punctuation is cut back to its ink');

    // The pass is a fixed point: running it again has nothing left to take.
    expect(state.canTrimAnyGlyph, isFalse);
    final before = clock.glyphs.map((g) => g.rows.join()).join();
    state.trimAllGlyphs();
    expect(clock.glyphs.map((g) => g.rows.join()).join(), before);
    expect(state.status, contains('No blank edge columns'));
  });

  test('an edit saves as the same file with one row changed', () async {
    state.togglePixel(1, 0);
    expect(await state.save(), isTrue);

    final written = File('${repo.path}/fonts/tiny.font').readAsStringSync();
    final before = _source.split('\n');
    final after = written.split('\n');
    expect(after.length, before.length);
    final changed = <int>[
      for (var i = 0; i < before.length; i++)
        if (before[i] != after[i]) i,
    ];
    expect(changed.length, 1);
    expect(after[changed.single], '  |.#|');
    // Byte for byte the file the author had, with one row replaced: the
    // header, the directives and the other glyph are untouched.
    expect(written, _source.replaceFirst('  |##|', '  |.#|'));
  });
}
