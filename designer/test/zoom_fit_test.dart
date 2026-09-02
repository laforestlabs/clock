// Zoom fit: the preview fills its window instead of sitting at a fixed size.
//
// "Fit" means the multiplier that fills the tighter axis exactly, so the panel
// uses every pixel of its box. These pin the arithmetic, that the tighter axis
// is the one that decides, and the handover between following the window and
// holding a manual choice.
//
// The two widget tests at the end cover the other half: that the view measures
// itself and reports it, without which the arithmetic would never run at all.
//
// Needs the native core, which is built as part of the app rather than by
// `flutter test`. Build the app once first:
//
//   flutter build linux --debug
//   LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test
//
// Without it these skip rather than fail, so a plain `flutter test` still
// passes on a machine that has never built the desktop bundle.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/controller.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/ui/panel_view.dart';

const String _doc64x32 = '{"canvas":{"width":64,"height":32},'
    '"background":"#000000","widgets":[]}';
const String _doc128x64 = '{"canvas":{"width":128,"height":64},'
    '"background":"#000000","widgets":[]}';

MirrorEngine? _tryOpen() {
  try {
    return MirrorEngine.open();
  } catch (_) {
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final probe = _tryOpen();
  // test() takes a plain bool, so the reason lives in the header comment.
  final skip = probe == null;
  probe?.dispose();
  if (skip) {
    // ignore: avoid_print
    print('skipping zoom fit tests: native core not loadable, '
        'see the header of this file');
  }

  Future<DesignerController> boot(String doc) async {
    final c = DesignerController(MirrorEngine.open());
    await c.loadJson(doc);
    return c;
  }

  test('fit fills the window when both axes come out the same', () async {
    final c = await boot(_doc64x32);
    // 640/64 and 320/32 are both 10.
    c.reportViewport(const ui.Size(640, 320));
    expect(c.zoom, 10);
    expect(c.zoomFitsWindow, isTrue);
  }, skip: skip);

  test('fit is decided by width when width is the tighter axis', () async {
    final c = await boot(_doc64x32);
    // 320/64 is 5, 1000/32 is 31.25. The smaller wins.
    c.reportViewport(const ui.Size(320, 1000));
    expect(c.zoom, 5);
  }, skip: skip);

  test('fit is decided by height when height is the tighter axis', () async {
    final c = await boot(_doc64x32);
    // 6400/64 is 100, 160/32 is 5.
    c.reportViewport(const ui.Size(6400, 160));
    expect(c.zoom, 5);
  }, skip: skip);

  test('fit fills the tighter axis exactly, never overflowing its box',
      () async {
    final c = await boot(_doc64x32);
    // Both axes give 10.9375, which fills both exactly rather than wasting
    // the fraction a whole-number multiplier would leave behind.
    c.reportViewport(const ui.Size(700, 350));
    expect(c.zoom, 10.9375);
    expect(64 * c.zoom, lessThanOrEqualTo(700));
    expect(32 * c.zoom, lessThanOrEqualTo(350));
  }, skip: skip);

  test('fit stops at the maximum zoom on a huge window', () async {
    final c = await boot(_doc64x32);
    c.reportViewport(const ui.Size(100000, 100000));
    expect(c.zoom, DesignerController.maxZoom);
  }, skip: skip);

  test('fit stops at the minimum zoom on a tiny window', () async {
    final c = await boot(_doc64x32);
    // 10/64 is well under 1, and zoom is never allowed below 1.
    c.reportViewport(const ui.Size(10, 10));
    expect(c.zoom, DesignerController.minZoom);
  }, skip: skip);

  test('an unmeasurable window is ignored rather than acted on', () async {
    final c = await boot(_doc64x32);
    c.reportViewport(const ui.Size(640, 320));
    c.reportViewport(const ui.Size(double.infinity, double.infinity));
    expect(c.zoom, 10);
  }, skip: skip);

  test('a manual zoom pins, and survives a later resize', () async {
    final c = await boot(_doc64x32);
    c.reportViewport(const ui.Size(640, 320));
    expect(c.zoom, 10);

    c.zoom = 3;
    expect(c.zoomFitsWindow, isFalse);

    // The window changing must not overrule a deliberate choice.
    c.reportViewport(const ui.Size(1280, 640));
    expect(c.zoom, 3);
  }, skip: skip);

  test('fit to window releases a pinned zoom', () async {
    final c = await boot(_doc64x32);
    c.reportViewport(const ui.Size(640, 320));
    c.zoom = 3;
    expect(c.zoomFitsWindow, isFalse);

    c.fitToWindow();
    expect(c.zoom, 10);
    expect(c.zoomFitsWindow, isTrue);
  }, skip: skip);

  test('a resize re-fits while the zoom is still following the window',
      () async {
    final c = await boot(_doc64x32);
    c.reportViewport(const ui.Size(640, 320));
    expect(c.zoom, 10);

    c.reportViewport(const ui.Size(1280, 640));
    expect(c.zoom, 20);
  }, skip: skip);

  test('opening another document fits it, pinned or not', () async {
    final c = await boot(_doc64x32);
    c.reportViewport(const ui.Size(640, 320));
    c.zoom = 3;
    expect(c.zoomFitsWindow, isFalse);

    // A zoom chosen for the previous layout says nothing about this one.
    await c.loadJson(_doc128x64);
    expect(c.zoomFitsWindow, isTrue);
    expect(c.zoom, 5);
  }, skip: skip);

  test('a new blank layout fits its own dimensions', () async {
    final c = await boot(_doc64x32);
    c.reportViewport(const ui.Size(640, 320));
    expect(c.zoom, 10);

    await c.newLayout(width: 128, height: 64);
    expect(c.zoom, 5);
  }, skip: skip);

  test('the fit tracks a change in panel size', () async {
    final c = await boot(_doc64x32);
    c.reportViewport(const ui.Size(640, 320));
    expect(c.zoom, 10);

    // Same window, twice the panel, so half the multiplier.
    await c.loadJson(_doc128x64);
    expect(c.zoom, 5);
  }, skip: skip);

  test('zoom stays clamped when driven past its limits by hand', () async {
    final c = await boot(_doc64x32);
    c.zoom = 1000;
    expect(c.zoom, DesignerController.maxZoom);
    c.zoom = -5;
    expect(c.zoom, DesignerController.minZoom);
  }, skip: skip);

  // The arithmetic above is only half of it. This is the wiring: that the view
  // actually measures itself and tells the controller, without which the app
  // would still open at the old fixed zoom no matter how good the maths is.
  testWidgets('the panel measures itself and fits without being asked',
      (tester) async {
    late DesignerController c;
    await tester.runAsync(() async {
      c = DesignerController(MirrorEngine.open());
      await c.loadJson(_doc64x32);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 640,
              height: 320,
              child: PanelView(controller: c),
            ),
          ),
        ),
      ),
    );
    // The report lands in a post-frame callback, so it takes one more frame.
    await tester.pump();

    expect(c.zoom, 10);
    expect(c.zoomFitsWindow, isTrue);
  }, skip: skip);

  testWidgets('the panel re-fits when its box changes size', (tester) async {
    late DesignerController c;
    await tester.runAsync(() async {
      c = DesignerController(MirrorEngine.open());
      await c.loadJson(_doc64x32);
    });

    Widget at(double w, double h) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: w,
                height: h,
                child: PanelView(controller: c),
              ),
            ),
          ),
        );

    await tester.pumpWidget(at(640, 320));
    await tester.pump();
    expect(c.zoom, 10);

    await tester.pumpWidget(at(320, 160));
    await tester.pump();
    expect(c.zoom, 5);
  }, skip: skip);
}
