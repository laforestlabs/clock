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

/// A clock naming the single display family with Fit on. The mock time is
/// 09:41; resizing changes scale continuously without changing font cuts.
const String _doc = '{"canvas":{"width":64,"height":64},'
    '"background":"#000000","widgets":['
    '{"type":"clock","rect":[0,0,64,32],"font":"display",'
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
        '{"type":"clock","rect":[0,0,64,32],"font":"sans9",'
        '"scale":2,"color":"#FFFFFF"}]}');

    final info = engine.widgets().single;
    expect(info.font, 'sans9');
    expect(info.scale, 2.0);
    engine.dispose();
  }, skip: skip);

  test('shrinking the box continuously rescales the same font', () {
    final engine = MirrorEngine.open();
    engine.load(_doc);
    final wide = engine.widgets().single;
    // A family names a style; the engine picks the cut. The stock display
    // family has a single scaling master, so the cut does not change here.
    expect(wide.font, 'display24');

    // The same edit a resize drag makes: reload with a shorter box.
    engine.load(_doc.replaceAll('[0,0,64,32]', '[0,0,64,12]'));
    final short = engine.widgets().single;
    expect(short.font, wide.font, reason: 'the same box keeps the same cut');

    // Behavior, not a pinned number: text in a shorter box draws smaller, and
    // the scale is derived continuously rather than snapped to whole
    // multiples, which is what makes a resize grow the text a pixel at a time
    // instead of parking at one size until the next multiple.
    expect(short.scale, lessThan(wide.scale));
    expect(wide.scale, isNot(wide.scale.roundToDouble()),
        reason: 'the derived scale is not restricted to whole multiples');
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

    // What a drag to that size would have updated the inspector to.
    final short = c.engine.widgets().single;
    expect(short.scale, lessThan(wide.scale));
    expect(shownScale(), closeTo(short.scale, 0.05));
  }, skip: skip);
}
