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
      }
    });

    test('automatic substitution is hidden in the single-font designer', () {
      for (final type in <String>[
        'text',
        'clock',
        'date',
        'weather',
        'icon',
        'agenda',
        'todo'
      ]) {
        expect(
          keysFor(type),
          isNot(contains('auto_font')),
          reason: '$type should keep the display face while its box resizes',
        );
      }
    });
  });
}
