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
          'display-thin8',
          'display-thin9',
          'display-thin24',
          'digits10',
          'digits16',
          'digits32',
          'wx16',
          'digits48',
          'display24',
          'display6',
        ]),
        reason: 'the picker reads this list straight from the engine, so a '
            'missing name means the .font never reached the build',
      );
    });

    test('offers exactly two faces to draw text with', () {
      // The catalogue is deliberately down to one minimal readable face and
      // one bold one, each a ladder of sizes. A third text ladder is a third
      // thing to choose between for no gain -- and the picker has always
      // offered only these two, so anything else registered is a file that
      // survived a cleanup.
      final text = engine!.families
          .where((f) => f.role == FontRole.text)
          .map((f) => f.name)
          .toList()
        ..sort();

      expect(text, <String>['display', 'display-thin'],
          reason: 'a text face is a choice the layout author has to make; '
              'two is the number the product decided on');
    });

    test('lists the families the picker offers', () {
      // The picker sells styles, not sizes: a family stands for its whole
      // ladder of cuts and the engine picks the size the box calls for.
      final names = engine!.families.map((f) => f.name).toList();

      expect(
          names,
          containsAll(<String>[
            'display',
            'display-thin',
            'digits',
            'micro',
            'wx',
          ]));

      final roleByName = <String, FontRole>{
        for (final f in engine.families) f.name: f.role,
      };
      expect(roleByName['display'], FontRole.text);
      expect(roleByName['display-thin'], FontRole.text);
      expect(roleByName['digits'], FontRole.digits);
      expect(roleByName['wx'], FontRole.icons);
    });

    test('reports the cell height each cut was drawn at', () {
      // A cut is named for the cell it is drawn in, and it is drawn in exactly
      // that cell: display-thin8 is eight rows, and the rows under the baseline
      // its descenders need are part of those eight rather than slack taken
      // back from them.
      final fonts = engine!.fonts;
      final byName = <String, int>{
        for (final f in fonts) f.name: f.height,
      };

      expect(byName['display-thin8'], 8);
      expect(byName['display-thin9'], 9);
      expect(byName['display-thin24'], 24);
      expect(byName['digits10'], 10);
      expect(byName['digits16'], 16);
      expect(byName['digits32'], 32);
      expect(byName['display24'], 24);

      // The rule behind those numbers: the cell is the size the name claims,
      // for every cut in the catalogue.
      final suffix = RegExp(r'(\d+)$');
      for (final f in fonts) {
        final match = suffix.firstMatch(f.name);
        if (match == null) continue;
        final nominal = int.parse(match.group(1)!);
        expect(f.height, nominal,
            reason: '${f.name} is drawn at ${f.height}px, not its name');
      }
    });

    test('reports the role each font declared', () {
      final byName = <String, FontRole>{
        for (final f in engine!.fonts) f.name: f.role,
      };

      expect(byName['display-thin8'], FontRole.text);
      expect(byName['display-thin9'], FontRole.text);
      expect(byName['display-thin24'], FontRole.text);
      expect(byName['digits10'], FontRole.digits);
      expect(byName['digits16'], FontRole.digits);
      expect(byName['digits32'], FontRole.digits);
      expect(byName['wx16'], FontRole.icons);
      expect(byName['display24'], FontRole.text);
      expect(byName['display-thin24'], FontRole.text);
    });

    test('the font picker leaves the pictograms out', () {
      // wx maps the ten digits onto weather symbols, so choosing it for a
      // label swaps the text for pictures. It is an icon set that reuses the
      // glyph machinery, not a typeface anybody would pick from a font menu.
      final families = engine!.families
          .where((f) => f.drawsText)
          .map((f) => f.name)
          .toList();

      expect(families, isNot(contains('wx')));
      expect(
        families,
        containsAll(<String>['display', 'display-thin', 'digits']),
        reason: 'a clock face is still a legitimate choice for a clock',
      );
    });

    test('the icon picker offers icon sets and nothing else', () {
      // Both pickers filter on the declared role. Height used to stand in for
      // it, which offered the clock faces as icon sets: an icon is indexed by
      // digit, so a digits cut was accepted and drew the numeral, not the icon.
      final iconSets = engine!.families
          .where((f) => f.isIconSet)
          .map((f) => f.name)
          .toList();

      expect(iconSets, contains('wx'));
      expect(iconSets, isNot(contains('digits')));
      expect(iconSets, isNot(contains('display-thin')));
      expect(iconSets, isNot(contains('pixel')));
    });
  }, skip: skip);
}
