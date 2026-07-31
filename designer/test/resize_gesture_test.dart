// End to end resize: a real drag on the canvas, through the real engine.
//
// handles_test.dart pins the arithmetic exactly. This covers the wiring around
// it, which is the other half of the bug surface: that a press lands on a
// handle rather than starting a move, that the gesture reaches the controller,
// that the opposite edge stays put, and that a whole drag is one undo entry.
//
// These assert direction and invariants rather than exact pixel counts, because
// how much of a synthetic drag is consumed starting the pan is the test
// harness's business, not the widget's. What matters here is which edges moved,
// which did not, and that the result stays on the canvas.
//
// Needs the native core, which is built as part of the app rather than by
// `flutter test`. Build the app once first:
//
//   flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test
//
// Without it these skip rather than fail, so a plain `flutter test` still
// passes on a machine that has never built the desktop bundle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/controller.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/ui/panel_view.dart';

/// One 20x20 widget at (10, 10) on a 64x64 canvas.
const String _doc = '{"canvas":{"width":64,"height":64},'
    '"background":"#000000","widgets":['
    '{"type":"rect","rect":[10,10,20,20],"color":"#FFFFFF"}]}';

const Rect _start = Rect.fromLTWH(10, 10, 20, 20);
const double _zoom = 8;

MirrorEngine? _tryOpen() {
  try {
    return MirrorEngine.open();
  } catch (_) {
    return null;
  }
}

void main() {
  final probe = _tryOpen();
  // testWidgets takes a plain bool, so the reason lives in the header comment.
  final skip = probe == null;
  probe?.dispose();
  if (skip) {
    // ignore: avoid_print
    print('skipping resize gesture tests: native core not loadable, '
        'see the header of this file');
  }

  Future<DesignerController> boot(WidgetTester tester) async {
    // The initial load decodes a real image, which only completes outside the
    // fake-async zone a widget test runs in. Later renders are fire and forget:
    // the rect is updated synchronously before the decode is awaited, so no
    // assertion below depends on one landing.
    late DesignerController c;
    await tester.runAsync(() async {
      c = DesignerController(MirrorEngine.open());
      await c.loadJson(_doc);
    });

    c.zoom = _zoom;
    c.select(0);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PanelView(controller: c))),
    );
    await tester.pump();
    return c;
  }

  /// Canvas pixel to screen position. The InteractiveViewer pins its child to
  /// the top left, so the widget's own origin is the canvas origin.
  Offset at(WidgetTester tester, double x, double y) =>
      tester.getTopLeft(find.byType(PanelView)) + Offset(x * _zoom, y * _zoom);

  /// A drag driven like a real pointer: press, move, move, release.
  ///
  /// Single-shot helpers such as [WidgetTester.dragFrom] deliver the whole
  /// movement in one event, which the pan recogniser spends on starting the
  /// gesture, leaving nothing for the update. A real finger sends a stream.
  Future<void> dragBy(WidgetTester tester, Offset from, Offset step) async {
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(step);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
  }

  testWidgets('dragging the bottom-right handle grows both axes', (tester) async {
    final c = await boot(tester);
    expect(c.doc.widgetAt(0)!.rect, _start);

    await dragBy(tester, at(tester, 30, 30), const Offset(2 * _zoom, 2 * _zoom));

    final r = c.doc.widgetAt(0)!.rect;
    expect(r.width, greaterThan(_start.width));
    expect(r.height, greaterThan(_start.height));
    expect(r.topLeft, _start.topLeft, reason: 'the origin must not move');
    c.dispose();
  }, skip: skip);

  testWidgets('dragging the top-left handle holds the far corner', (tester) async {
    final c = await boot(tester);

    await dragBy(tester, at(tester, 10, 10), const Offset(2 * _zoom, 2 * _zoom));

    final r = c.doc.widgetAt(0)!.rect;
    expect(r.left, greaterThan(_start.left));
    expect(r.top, greaterThan(_start.top));
    expect(r.right, _start.right, reason: 'the opposite corner must stay put');
    expect(r.bottom, _start.bottom);
    c.dispose();
  }, skip: skip);

  testWidgets('a side handle moves one axis only', (tester) async {
    final c = await boot(tester);

    // Grab the right edge midpoint and drag diagonally. The vertical component
    // must be ignored entirely.
    await dragBy(tester, at(tester, 30, 20), const Offset(2 * _zoom, 2 * _zoom));

    final r = c.doc.widgetAt(0)!.rect;
    expect(r.width, greaterThan(_start.width));
    expect(r.top, _start.top);
    expect(r.bottom, _start.bottom, reason: 'a horizontal handle cannot resize vertically');
    c.dispose();
  }, skip: skip);

  testWidgets('dragging the middle moves rather than resizes', (tester) async {
    final c = await boot(tester);

    await dragBy(tester, at(tester, 20, 20), const Offset(2 * _zoom, 2 * _zoom));

    final r = c.doc.widgetAt(0)!.rect;
    expect(r.size, _start.size, reason: 'a move must not resize');
    expect(r.left, greaterThan(_start.left));
    expect(r.top, greaterThan(_start.top));
    c.dispose();
  }, skip: skip);

  testWidgets('a whole drag is one undo step', (tester) async {
    final c = await boot(tester);

    await dragBy(tester, at(tester, 30, 30), const Offset(2 * _zoom, 2 * _zoom));
    expect(c.doc.widgetAt(0)!.rect, isNot(_start));

    // Awaited undo re-renders, and the decode inside that only completes
    // outside the fake-async zone.
    await tester.runAsync(() => c.undo());
    await tester.pump();
    expect(c.doc.widgetAt(0)!.rect, _start, reason: 'one gesture, one undo');
    c.dispose();
  }, skip: skip);

  testWidgets('resizing stops at the canvas edge', (tester) async {
    final c = await boot(tester);

    await dragBy(tester, at(tester, 30, 30), const Offset(400, 400));

    final r = c.doc.widgetAt(0)!.rect;
    expect(r.right, lessThanOrEqualTo(64));
    expect(r.bottom, lessThanOrEqualTo(64));
    expect(r.width, greaterThan(_start.width), reason: 'it still grew');
    c.dispose();
  }, skip: skip);

  testWidgets('a widget cannot be inverted by dragging past its far edge',
      (tester) async {
    final c = await boot(tester);

    // Drag the right edge far to the left, past the left edge.
    await dragBy(tester, at(tester, 30, 20), const Offset(-30 * _zoom, 0));

    final r = c.doc.widgetAt(0)!.rect;
    expect(r.width, greaterThan(0));
    expect(r.left, lessThanOrEqualTo(r.right));
    c.dispose();
  }, skip: skip);
}
