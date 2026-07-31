// The document model has to be at least as forgiving as the engine it feeds.
//
// A layout is a file people hand edit, so 'widgets' turns up as null, or as an
// object, or missing entirely. The C core treats all three as an empty widget
// list and renders a blank canvas, on the principle that a layout should never
// be able to make the mirror refuse to draw. The designer used to disagree: the
// key exists, so putIfAbsent left it alone, and the first read of it threw a
// TypeError. That throw did not come out of the decode, where the caller
// catches FormatException, but out of a widget build, so a file the mirror
// would happily display crashed the tool for editing it.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/model/layout.dart';

void main() {
  group('layout doc', () {
    const canvas = '"canvas":{"width":64,"height":32}';

    test('accepts a null widgets key', () {
      final doc = LayoutDoc.decode('{$canvas,"widgets":null}');
      expect(doc.widgetCount, 0);
      expect(doc.widgets, isEmpty);
    });

    test('accepts a widgets key that is not a list', () {
      final doc = LayoutDoc.decode('{$canvas,"widgets":{"a":1}}');
      expect(doc.widgetCount, 0);
    });

    test('accepts a missing widgets key', () {
      final doc = LayoutDoc.decode('{$canvas}');
      expect(doc.widgetCount, 0);
    });

    test('normalised documents still re-encode as valid JSON', () {
      final doc = LayoutDoc.decode('{$canvas,"widgets":null}');
      final again = LayoutDoc.decode(doc.encode());
      expect(again.widgetCount, 0);
      expect(again.width, 64);
    });

    test('a real widget list is left alone', () {
      final doc = LayoutDoc.decode(
        '{$canvas,"widgets":[{"type":"text","rect":[0,0,64,7]}]}',
      );
      expect(doc.widgetCount, 1);
      expect(doc.widgets.single.type, 'text');
    });

    // Keys this build does not model must survive an open-and-save cycle, which
    // is the whole reason the document is backed by the raw map.
    test('unknown keys survive a round trip', () {
      final doc = LayoutDoc.decode(
        '{$canvas,"widgets":[{"type":"text","rect":[0,0,64,7],"sparkle":7}]}',
      );
      expect(LayoutDoc.decode(doc.encode()).widgets.single.raw['sparkle'], 7);
    });
  });
}
