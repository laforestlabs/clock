// The gamma curve and the brightness rule are not the tool's to invent: the
// device applies them at scan-out and core/src/canvas.c applies them at
// export. This holds the Dart implementation against the committed C table,
// so a preview cannot quietly start disagreeing with the panel.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:font_designer/src/font_source.dart';
import 'package:font_designer/src/panel.dart';
import 'package:font_designer/src/ui/panel_view.dart';

/// The 256 entries of core/src/gamma_table.c, scraped from the initializer.
List<int> cTable() {
  final file = File('../core/src/gamma_table.c');
  expect(file.existsSync(), isTrue,
      reason: 'run this from font_designer/, next to the repository root');
  final text = file.readAsStringSync();
  final start = text.indexOf('{');
  final end = text.indexOf('}', start);
  return RegExp(r'\d+')
      .allMatches(text.substring(start, end))
      .map((m) => int.parse(m.group(0)!))
      .toList();
}

void main() {
  test('the CIE 1931 table matches core/src/gamma_table.c exactly', () {
    final table = cTable();
    expect(table.length, 256);
    for (var v = 0; v < 256; v++) {
      expect(kGammaTable[v], table[v], reason: 'entry $v');
    }
  });

  test('gamma is monotonic, black at zero and full at 255', () {
    expect(kGammaTable[0], 0);
    expect(kGammaTable[255], 255);
    for (var v = 1; v < 256; v++) {
      expect(kGammaTable[v], greaterThanOrEqualTo(kGammaTable[v - 1]));
    }
  });

  test('the mid grey the panel emits is a much larger screen byte', () {
    // A canvas value of 128 is 47/255 of full light on the panel: gamma comes
    // before the linear scale, and the curve is steep in its lower half. On a
    // screen that byte has to be sRGB encoded back up, or the preview shows a
    // grey far darker than the panel makes.
    expect(gamma8(128), 47);
    const full = PanelSpec();
    expect(full.duty(128), 47);
    final shown = full.displayed(0x808080);
    expect((shown >> 16) & 0xFF, inInclusiveRange(112, 120));
  });

  test('brightness scales after gamma, as the driver does', () {
    const half = PanelSpec(brightness: 128);
    expect(half.duty(255), scale8(255, 128));
    expect(half.duty(255), 128);
    // Scaling before gamma would land on gamma(128) = 47; after gamma it is
    // gamma(255) * 0.5 = 127.5 -> 128. The order is visible, which is why it
    // is pinned.
    expect(half.duty(255), isNot(gamma8(128)));

    const off = PanelSpec(brightness: 0);
    expect(off.duty(255), 0);
    expect(off.displayed(0xFFFFFF), 0);
  });

  test('a full-brightness white is untouched, so the bitmap is the picture', () {
    const full = PanelSpec();
    expect(full.displayed(0xFFFFFF), 0xFFFFFF);
    expect(full.displayed(0x000000), 0);
  });

  test('the geometry is the panel this product ships', () {
    const panel = PanelSpec();
    expect(panel.widthMm, 160);
    expect(panel.heightMm, 80);
    expect(panel.emitterMm, 1.25, reason: 'P2.5 with half the pitch dark');
    expect(panel.cellArcmin, closeTo(8.6, 0.1));
    expect(panel.eyeBlurCells, lessThan(0.1),
        reason: 'a 2.5mm cell at 1m is resolvable, which is the point');

    const far = PanelSpec(distanceM: 5);
    expect(far.eyeBlurCells, greaterThan(panel.eyeBlurCells * 4));
    expect(far.cellArcmin, closeTo(1.7, 0.05));
  });

  test('the plane colours cover every plane a font may declare', () {
    expect(kPlaneColours.length, kInkChars.length);
  });
}
