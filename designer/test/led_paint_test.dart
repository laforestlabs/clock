// LED pixel rendering: the preview draws the frame as discrete emitter discs
// with dead space between them, and the veneer control spreads each emitter's
// light into that space. These probe the rasterised panel rather than the
// painter calls, so they pin what the user actually sees.
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
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/controller.dart';
import 'package:mirror_designer/src/engine/engine.dart';
import 'package:mirror_designer/src/ui/panel_view.dart';

// A 4x4 panel with a white 2x2 block in the middle, small enough that the
// probes below can name exact output pixels.
const String _doc = '{"canvas":{"width":4,"height":4},'
    '"background":"#000000","widgets":['
    '{"type":"rect","id":"block","rect":[1,1,2,2],"color":"#FFFFFF"}]}';

// Pinned zoom, so a cell is a 20x20 block and the lit discs are centred at
// (30,30), (50,30), (30,50) and (50,50) in the captured image.
const double _zoom = 20;

/// Centre of the top left emitter.
const _discCentre = Offset(30, 30);

/// Halfway between two adjacent emitters, and the corner where four cells
/// meet. Both sit outside every disc, so without diffusion they stay dark.
const _deadColumn = Offset(40, 30);
const _deadCorner = Offset(40, 40);

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
  // testWidgets takes a plain bool, so the reason lives in the header comment.
  final skip = probe == null;
  probe?.dispose();
  if (skip) {
    // ignore: avoid_print
    print('skipping LED paint tests: native core not loadable, '
        'see the header of this file');
  }

  /// Rasterises the panel as painted right now and reads the luminance at
  /// each named probe point.
  Future<Map<String, int>> probePanel(WidgetTester tester) async {
    final out = <String, int>{};
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.descendant(
          of: find.byType(PanelView),
          matching: find.byType(RepaintBoundary),
        ),
      );
      final shot = await boundary.toImage();
      final data = await shot.toByteData(format: ui.ImageByteFormat.rawRgba);

      int lum(Offset at) {
        final i = (at.dy.round() * shot.width + at.dx.round()) * 4;
        final d = data!;
        return (d.getUint8(i) + d.getUint8(i + 1) + d.getUint8(i + 2)) ~/ 3;
      }

      out['centre'] = lum(_discCentre);
      out['column'] = lum(_deadColumn);
      out['corner'] = lum(_deadCorner);
      shot.dispose();
    });
    return out;
  }

  testWidgets(
      'lit cells are discs with dead space; full veneer diffuses the field',
      (tester) async {
    late DesignerController c;
    await tester.runAsync(() async {
      c = DesignerController(MirrorEngine.open());
      await c.loadJson(_doc);
    });
    addTearDown(c.dispose);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PanelView(controller: c))),
    );
    c.zoom = _zoom;
    c.veneer = 0;
    await tester.pump();

    final sharp = await probePanel(tester);

    c.veneer = 100;
    await tester.pump();

    final diffused = await probePanel(tester);

    // At zero veneer each emitter is a crisp disc at full brightness.
    expect(sharp['centre'], greaterThan(240));

    // Without diffusion the space between emitters is genuinely dark: the
    // discs do not fill their cells.
    expect(sharp['column'], lessThan(20));
    expect(sharp['corner'], lessThan(20));

    // At full veneer the emitters themselves blur: the once-crisp core is no
    // longer at full brightness, because the light has spread. This is the
    // behaviour that makes 100% read as a real blur rather than as dots with
    // filled gaps.
    expect(diffused['centre'], lessThan(sharp['centre']!));

    // The dead space is now lit by the scatter.
    expect(diffused['column'], greaterThan(30));
    expect(diffused['corner'], greaterThan(30));

    // And the field is diffuse enough that an emitter and the corner where
    // four cells meet are close in brightness, not starkly contrasted.
    expect(
        (diffused['centre']! - diffused['corner']!).abs(), lessThan(40));
  }, skip: skip);
}
