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

    test('the icon picker filter still selects only the tall fonts', () {
      // inspector.dart offers height >= 8 as icon sets. The body fonts must
      // stay out of that list, and wx16 must stay in it.
      final iconish = engine!.fonts
          .where((f) => f.height >= 8)
          .map((f) => f.name)
          .toList();

      expect(iconish, contains('wx16'));
      expect(iconish, isNot(contains('tom5x7')));
      expect(iconish, isNot(contains('bold5x7')));
      expect(iconish, isNot(contains('tiny4x6')));
    });
  }, skip: skip);
}
