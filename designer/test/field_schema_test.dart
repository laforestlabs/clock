// The inspector's field list is presentation metadata, so it can drift from
// what the engine actually honours without anything failing. The cases below
// are the ones where the two deliberately disagree, and where the disagreement
// reads like an oversight to anyone tidying up later.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/model/field_schema.dart';

Iterable<String> keysFor(String type) => fieldsFor(type).map((f) => f.key);

void main() {
  group('field schema', () {
    test('sizing fields are offered wherever the engine scales', () {
      for (final type in <String>[
        'text',
        'clock',
        'date',
        'weather',
        'icon',
        'agenda',
        'todo',
      ]) {
        expect(keysFor(type), contains('scale'), reason: '$type has no scale');
        expect(keysFor(type), contains('fit'), reason: '$type has no fit');
        expect(keysFor(type), contains('min_scale'), reason: '$type min');
        expect(keysFor(type), contains('max_scale'), reason: '$type max');
      }
    });

    test('auto font is offered where the engine acts on it', () {
      for (final type in <String>['text', 'clock', 'date', 'weather']) {
        expect(keysFor(type), contains('auto_font'), reason: type);
      }
    });

    test('and withheld where it would do nothing or do harm', () {
      // icon: indexed by digit, and every body font has digits, so substituting
      // would draw a numeral instead of the weather glyph. agenda and todo are
      // sized on height alone because they clip each row by design, so the
      // engine never reaches the auto_font branch for them.
      for (final type in <String>['icon', 'agenda', 'todo']) {
        expect(
          keysFor(type),
          isNot(contains('auto_font')),
          reason: '$type does not honour auto_font, so offering it would put a '
              'switch in the inspector that leaves the preview unchanged',
        );
      }
    });

    test('scale bounds allow 0, which is how the engine spells unset', () {
      final min = fieldsFor('text').firstWhere((f) => f.key == 'min_scale');
      final max = fieldsFor('text').firstWhere((f) => f.key == 'max_scale');

      expect(min.min, 0);
      expect(max.min, 0);
      expect(min.max, 8);
      expect(max.max, 8);
    });
  });
}
