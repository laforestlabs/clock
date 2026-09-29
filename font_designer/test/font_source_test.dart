// The source format is shared with tools/fontgen.py, and the app's whole
// promise is that a touch-up is a small diff. Both are checked here against
// the real files in the tree rather than against a fixture, because the files
// are the thing that has to survive.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:font_designer/src/font_source.dart';

/// Every .font in the catalogue, as (relative path, contents).
List<(String, String)> catalogue() {
  final out = <(String, String)>[];
  for (final root in <String>['../fonts', '../gamekit/fonts']) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.font')) continue;
      out.add((entity.path, entity.readAsStringSync()));
    }
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

void main() {
  test('the catalogue is not empty', () {
    expect(catalogue(), isNotEmpty,
        reason: 'run this from font_designer/, next to the repository root');
  });

  test('every font parses and round trips byte for byte', () {
    for (final (path, text) in catalogue()) {
      final font = FontSource.parse(path, text);
      expect(font.serialize(), text, reason: '$path was rewritten unedited');
      expect(font.name, isNotEmpty);
      expect(font.glyphs, isNotEmpty);
      for (final glyph in font.glyphs) {
        expect(glyph.rows.length, font.height,
            reason: '$path glyph ${glyph.codepoint}');
        expect(glyph.rows.every((r) => r.length == glyph.width), isTrue);
      }
    }
  });

  test('editing one pixel rewrites one line and nothing else', () {
    final (path, text) = catalogue().firstWhere((e) => e.$1.endsWith('display8.font'));
    final font = FontSource.parse(path, text);
    final glyph = font.glyphs.firstWhere((g) => g.codepoint == 65);
    final before = List<String>.of(glyph.rows);

    // Flip the pixel under the first ink, so the edit is guaranteed to change
    // something whatever the art happens to be.
    var flipped = false;
    for (var y = 0; y < glyph.rows.length && !flipped; y++) {
      final x = glyph.rows[y].indexOf('#');
      if (x < 0) continue;
      glyph.rows[y] =
          '${glyph.rows[y].substring(0, x)}.${glyph.rows[y].substring(x + 1)}';
      flipped = true;
    }
    expect(flipped, isTrue, reason: 'A has no ink to flip');

    final written = font.serialize().split('\n');
    final original = text.split('\n');
    expect(written.length, original.length);

    final changed = <int>[
      for (var i = 0; i < original.length; i++)
        if (original[i] != written[i]) i,
    ];
    expect(changed.length, 1, reason: 'only the edited row may differ');
    expect(written[changed.single], startsWith('  |'));

    glyph.rows = before;
    expect(font.serialize(), text, reason: 'reverting restores the file');
  });

  test('a block glyph keeps the file\'s own row decoration', () {
    const source = '''
@name     tiny
@role     text
@height   2
@baseline 2
@gap      1
@family   tiny
@smooth   no

68
    |#.|
    |.#|
''';
    final font = FontSource.parse('tiny.font', source);
    final glyph = font.glyph(68)!;
    expect(glyph.rowPrefix, '    |');
    expect(glyph.rows, <String>['#.', '.#']);
    expect(font.serialize(), source);
  });

  test('the inline spelling is read and rewritten in place', () {
    const source = '''
@name     inline
@role     digits
@height   2
@baseline 2
@gap      1
@family   inline

48 .#/#.
49 #./.#
''';
    final font = FontSource.parse('inline.font', source);
    expect(font.glyphs.length, 2);
    expect(font.glyph(48)!.width, 2);
    expect(font.glyph(49)!.block, isFalse);
    expect(font.serialize(), source);

    font.glyph(49)!.rows = <String>['##', '.#'];
    expect(font.serialize(), contains('\n49 ##/.#\n'));
  });

  test('a font that fontgen would reject is reported with its line', () {
    const ragged = '''
@name     bad
@role     text
@height   2
@baseline 2

65
  |#|
  |##|
''';
    expect(
      () => FontSource.parse('bad.font', ragged),
      throwsA(isA<FontSourceError>().having(
          (e) => e.toString(), 'message', contains('ragged'))),
    );

    const noRole = '@name x\n@height 2\n65\n  |#|\n  |#|\n';
    expect(
      () => FontSource.parse('x.font', noRole),
      throwsA(isA<FontSourceError>().having(
          (e) => e.toString(), 'message', contains('missing @role'))),
    );

    const strayInk = '''
@name     y
@role     text
@height   1
@baseline 1
65
  |*|
''';
    expect(
      () => FontSource.parse('y.font', strayInk),
      throwsA(isA<FontSourceError>().having(
          (e) => e.toString(), 'message', contains('stray character'))),
    );
  });

  test('planes are read, and ink outside them is refused', () {
    const four = '''
@name     icons
@role     icons
@height   1
@baseline 1
@planes   4
48
  |#*~+|
''';
    final font = FontSource.parse('icons.font', four);
    expect(font.planes, 4);
    expect(font.inkChars, <String>['#', '*', '~', '+']);
    expect(font.glyph(48)!.usedInk, <String>{'#', '*', '~', '+'});
  });
}
