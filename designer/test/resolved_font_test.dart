// The inspector shows what a widget actually draws with: the font cut the
// engine picked for a family or with Auto font on, and the scale Fit derives
// from the box. That state moves while a resize drag is in flight, so it has
// to come from the engine on every refresh rather than from the JSON, which
// only holds what the user configured.
//
// Needs the native core, which is built as part of the app rather than by
// `flutter test`. Build the app once first:
//
//   flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test
//
// Without it these skip rather than fail, matching resize_gesture_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/controller.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/ui/inspector.dart';

/// A clock naming the display family with Fit on. The mock time is 09:41;
/// shrinking the box steps the cut down while the scale stays 1x, because a box
/// the ladder reaches gets a cut of its own size, unscaled.
const String _doc = '{"canvas":{"width":64,"height":64},'
    '"background":"#000000","widgets":['
    '{"type":"clock","rect":[0,0,64,20],"font":"display",'
    '"format":"%H:%M","color":"#FFFFFF","fit":true}]}';

MirrorEngine? _tryOpen() {
  try {
    return MirrorEngine.open();
  } catch (_) {
    return null;
  }
}

void main() {
  final probe = _tryOpen();
  final skip = probe == null;
  probe?.dispose();
  if (skip) {
    // ignore: avoid_print
    print('skipping resolved font tests: native core not loadable, '
        'see the header of this file');
  }

  test('a pinned cut and scale report themselves', () {
    final engine = MirrorEngine.open();
    engine.load('{"canvas":{"width":64,"height":64},'
        '"background":"#000000","widgets":['
        '{"type":"clock","rect":[0,0,64,32],"font":"display-thin9",'
        '"scale":2,"color":"#FFFFFF"}]}');

    final info = engine.widgets().single;
    expect(info.font, 'display-thin9');
    expect(info.scale, 2.0);
    engine.dispose();
  }, skip: skip);

  test('a box steps to the cut of its own size, and never draws larger text', () {
    final engine = MirrorEngine.open();
    final heights = <String, int>{for (final f in engine.fonts) f.name: f.height};

    // A family names a style, not a size: what comes back is the cut the
    // engine picked to fill the box, never the family name, so the inspector
    // can say what actually draws.
    //
    // The cut is chosen by the box's own height, so a shorter box can only ever
    // step down to a shorter cut: stepping the box down never grows the text it
    // draws. Which cut that lands on moves with the catalogue's own metrics, so
    // the rule is what is pinned here, not a name.
    int? previous;
    for (final int rows in <int>[20, 16, 12, 8]) {
      final String doc = _doc.replaceAll('[0,0,64,20]', '[0,0,64,$rows]');
      engine.load(doc);
      final info = engine.widgets().single;
      expect(info.font, startsWith('display'));
      expect(info.font, isNot('display'),
          reason: 'a family resolves to the cut that fills the box');
      // Every text cut is a set size, so a fitted scale is a whole multiple:
      // a box steps to another cut rather than smearing one drawing across a
      // fraction of a pixel, which on a HUB75 panel would light two cells
      // dimly instead of one fully.
      expect(info.scale, info.scale.roundToDouble(),
          reason: 'a fitted scale on a set-size face is a whole multiple');
      final drawn = heights[info.font]! * info.scale.round();
      if (previous != null) {
        expect(drawn, lessThanOrEqualTo(previous),
            reason: 'a $rows-row box draws taller text than the one above it');
      }
      previous = drawn;
    }
    engine.dispose();
  }, skip: skip);

  test('a widget with no text reports none', () {
    final engine = MirrorEngine.open();
    engine.load('{"canvas":{"width":64,"height":64},'
        '"background":"#000000","widgets":['
        '{"type":"rect","rect":[0,0,64,10],"color":"#202020"}]}');

    final info = engine.widgets().single;
    expect(info.font, isEmpty);
    expect(info.scale, 0.0);
    engine.dispose();
  }, skip: skip);

  testWidgets('the inspector follows the resolved state across a resize',
      (tester) async {
    // Tall enough that the ListView builds every field: it only builds the
    // ones on screen, and Font sits below the fold of the default surface.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late DesignerController c;
    // The load and the resize decode real images, which only completes
    // outside the fake-async zone a widget test runs in.
    await tester.runAsync(() async {
      c = DesignerController(MirrorEngine.open());
      await c.loadJson(_doc);
    });
    c.select(0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InspectorPanel(controller: c)),
      ),
    );
    await tester.pump();

    // The family names a style; the engine picked the cut for this box. The
    // inspector has to report what the engine resolved rather than what the
    // JSON holds, so this compares the two instead of pinning a font name and
    // a scale that only hold for one set of glyph metrics.
    double shownScale() {
      final line = tester
          .widgetList<Text>(find.textContaining('Scale: '))
          .map((t) => t.data!)
          .firstWhere((s) => s.contains('(fit)'));
      return double.parse(line.split(': ')[1].split(' ')[0]);
    }

    final wide = c.engine.widgets().single;
    expect(find.text('Drawing ${wide.font}'), findsOneWidget);
    expect(shownScale(), closeTo(wide.scale, 0.05));

    await tester.runAsync(() async {
      await c.resizeSelected(const Rect.fromLTWH(0, 0, 64, 12));
    });
    await tester.pump();

    // What a drag to that size would have updated the inspector to. The
    // resize has to have moved the resolved state, and the panel has to be
    // showing it; which cut and scale it lands on is the catalogue's
    // business, not the inspector's.
    final short = c.engine.widgets().single;
    expect(short.font != wide.font || short.scale != wide.scale, isTrue,
        reason: 'the resize left the resolved state unchanged, so the '
            'inspector is not being asked to follow anything');
    expect(shownScale(), closeTo(short.scale, 0.05));
  }, skip: skip);
}
