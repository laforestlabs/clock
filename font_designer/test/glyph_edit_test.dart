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
