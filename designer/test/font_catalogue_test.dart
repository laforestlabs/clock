// The font picker is populated from the engine, not from a list in Dart, so
// that dropping a .font file into fonts/ makes it selectable with no Dart
// change. That indirection is only worth anything if it actually holds, and a
// break in it looks like a picker that is merely missing an entry rather than
// like an error.
//
// Needs the native core, which is built as part of the app rather than by
// `flutter test`. Build the app once first:
//
//   flutter build linux --release
//   LD_LIBRARY_PATH=build/linux/x64/release/bundle/lib flutter test
//
// Without it these skip rather than fail, matching resize_gesture_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/engine/engine.dart';

MirrorEngine? _tryOpen() {
  try {
    return MirrorEngine.open();
  } catch (_) {
    return null;
  }
}

void main() {
  final engine = _tryOpen();
  final skip = engine == null
      ? 'native core not on the library path, see the header comment'
      : null;

  group('font catalogue', () {
    test('lists every font the build ships', () {
      final names = engine!.fonts.map((f) => f.name).toList();

      expect(
        names,
        containsAll(<String>[
          'tom5x7',
          'bold5x7',
          'tiny4x6',
          'digits10',
          'digits16',
          'digits32',
          'wx16',
        ]),
        reason: 'the picker reads this list straight from the engine, so a '
            'missing name means the .font never reached the build',
      );
    });

    test('reports the cell height each font was drawn at', () {
      final byName = <String, int>{
        for (final f in engine!.fonts) f.name: f.height,
      };

      expect(byName['tiny4x6'], 6);
      expect(byName['tom5x7'], 7);
      expect(byName['bold5x7'], 7);
      expect(byName['digits10'], 10);
      expect(byName['digits16'], 16);
      expect(byName['digits32'], 32);
    });

    test('reports the role each font declared', () {
      final byName = <String, FontRole>{
        for (final f in engine!.fonts) f.name: f.role,
      };

      expect(byName['tiny4x6'], FontRole.text);
      expect(byName['bold5x7'], FontRole.text);
      expect(byName['tom5x7'], FontRole.text);
      expect(byName['digits10'], FontRole.digits);
      expect(byName['digits16'], FontRole.digits);
      expect(byName['digits32'], FontRole.digits);
      expect(byName['wx16'], FontRole.icons);
    });

    test('the font picker leaves the pictograms out', () {
      // wx16 maps the ten digits onto weather symbols, so choosing it for a
      // label swaps the text for pictures. It is an icon set that reuses the
      // glyph machinery, not a typeface anybody would pick from a font menu.
      final fonts = engine!.fonts
          .where((f) => f.drawsText)
          .map((f) => f.name)
          .toList();

      expect(fonts, isNot(contains('wx16')));
      expect(
        fonts,
        containsAll(<String>[
          'tiny4x6',
          'bold5x7',
          'tom5x7',
          'digits10',
          'digits16',
          'digits32',
        ]),
        reason: 'a clock face is still a legitimate choice for a clock',
      );
    });

    test('the icon picker offers icon sets and nothing else', () {
      // Both pickers filter on the declared role. Height used to stand in for
      // it, which offered the clock faces as icon sets: an icon is indexed by
      // digit, so digits32 was accepted and drew the numeral, not the icon.
      final iconSets = engine!.fonts
          .where((f) => f.isIconSet)
          .map((f) => f.name)
          .toList();

      expect(iconSets, contains('wx16'));
      expect(iconSets, isNot(contains('digits10')));
      expect(iconSets, isNot(contains('digits16')));
      expect(iconSets, isNot(contains('digits32')));
      expect(iconSets, isNot(contains('tom5x7')));
      expect(iconSets, isNot(contains('bold5x7')));
      expect(iconSets, isNot(contains('tiny4x6')));
    });
  }, skip: skip);
}
