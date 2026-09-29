// The panel, drawn as a field of emitters.
//
// A LED matrix is not a display with sub-pixel edges. Each cell is one
// emitter with dead space around it, so this paints discs (or squares) at the
// panel's real pitch and gap rather than pixels. Everything the tool is for
// depends on that: a stroke one cell wide does not soften on this panel, it
// dims, and a shape only reads the way the panel shows it here.
//
// Two conversions happen between the frame and the screen, and both are
// physics rather than taste:
//
//   The frame holds the colours the layout author typed. The panel shows them
//   through a CIE 1931 curve and then dims linearly for brightness; that is
//   PanelSpec.duty, the LED's on-time.
//
//   A monitor byte is sRGB encoded, so writing a duty straight into it would
//   emit far less light than the panel does -- an 18% panel grey would come
//   out as 2.7%. PanelSpec.screenValue undoes that, so what is on screen is
//   the light the emitters actually make.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../font_source.dart';
import '../frame.dart';
import '../panel.dart';

/// Colours for the four planes, so an author can see which plane a pixel
/// belongs to. Plane 0 is the colour a single-colour draw uses.
const List<Color> kPlaneColours = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFF4FC3F7),
  Color(0xFFBA68C8),
  Color(0xFF81C784),
];

const Color kDeadSpace = Color(0xFF000000);
const Color kBackdrop = Color(0xFF14161A);
const Color kGridLine = Color(0x22FFFFFF);

/// Where a [columns]x[rows] grid lands inside [room] at [zoom] screen pixels
/// per cell, centred.
Rect cellRect(Size room, int columns, int rows, double zoom) {
  final width = columns * zoom;
  final height = rows * zoom;
  return Rect.fromLTWH((room.width - width) / 2, (room.height - height) / 2,
      width, height);
}

/// One emitter, centred in its cell.
void _emitter(
  Canvas canvas,
  Offset centre,
  double pitch,
  PanelSpec spec,
  Color colour,
) {
  final paint = Paint()
    ..color = colour
    ..isAntiAlias = true;
  final extent = math.max(0.7, pitch * (1 - spec.gapShare));
  switch (spec.shape) {
    case EmitterShape.round:
      canvas.drawCircle(centre, extent / 2, paint);
    case EmitterShape.square:
      canvas.drawRect(
        Rect.fromCenter(center: centre, width: extent, height: extent),
        paint,
      );
  }
}

/// Paints a [Frame] as the panel presents it.
///
/// Repaints are driven by the owning widget's rebuild rather than by a
/// comparison here: a frame's pixels are mutated in place, so the painter
/// cannot tell an edited frame from the one it was given last.
class PanelPainter extends CustomPainter {
  PanelPainter({
    required this.frame,
    required this.spec,
    required this.zoom,
    required this.showOutlines,
    this.drawPanelBox = true,
  });

  final Frame frame;
  final PanelSpec spec;
  final double zoom;
  final bool showOutlines;
  final bool drawPanelBox;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kBackdrop);

    final rect = cellRect(size, frame.width, frame.height, zoom);
    if (drawPanelBox) {
      canvas.drawRect(rect, Paint()..color = kDeadSpace);
    }

    final outline = Paint()
      ..color = kGridLine
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var y = 0; y < frame.height; y++) {
      for (var x = 0; x < frame.width; x++) {
        final centre = Offset(
          rect.left + (x + 0.5) * zoom,
          rect.top + (y + 0.5) * zoom,
        );
        final rgb = frame.at(x, y);
        if (rgb == 0) {
          if (showOutlines) {
            // Unlit cells are what an author cannot otherwise see, so they are
            // outlined rather than left to the imagination.
            final extent = math.max(1.0, zoom * (1 - spec.gapShare));
            canvas.drawRect(
              Rect.fromCenter(center: centre, width: extent, height: extent),
              outline,
            );
          }
          continue;
        }
        _emitter(canvas, centre, zoom, spec,
            Color(0xFF000000 | spec.displayed(rgb)));
      }
    }
  }

  @override
  bool shouldRepaint(PanelPainter old) => true;
}

/// The pixel editor's lattice: the same emitters, plus the cell outline, the
/// baseline and the advance, so a pixel is a thing that can be aimed at.
class GlyphEditorPainter extends CustomPainter {
  GlyphEditorPainter({
    required this.glyph,
    required this.spec,
    required this.zoom,
    required this.cursor,
    required this.baseline,
    required this.gap,
  });

  final GlyphSource glyph;
  final PanelSpec spec;
  final double zoom;

  /// The cell under the pointer as (column, row), or null.
  final Offset? cursor;

  /// Rows from the top of the cell to the baseline, as the source declares it.
  final int baseline;

  /// The font's gap, so the line the next glyph starts on can be drawn too.
  final int gap;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = cellRect(size, glyph.width, glyph.rows.length, zoom);
    canvas.drawRect(rect, Paint()..color = kDeadSpace);

    final grid = Paint()
      ..color = kGridLine
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var y = 0; y < glyph.rows.length; y++) {
      for (var x = 0; x < glyph.width; x++) {
        final centre =
            Offset(rect.left + (x + 0.5) * zoom, rect.top + (y + 0.5) * zoom);
        canvas.drawRect(
          Rect.fromCenter(center: centre, width: zoom, height: zoom),
          grid,
        );

        final ink = glyph.rows[y][x];
        if (ink == '.') continue;
        final plane = kInkChars.indexOf(ink);
        _emitter(
          canvas,
          centre,
          zoom,
          spec,
          plane >= 0 && plane < kPlaneColours.length
              ? kPlaneColours[plane]
              : const Color(0xFFFFFFFF),
        );
      }
    }

    // The ink edge, then the pen the next glyph starts on. Between them is the
    // gap, which is what an author widens when two letters run together.
    canvas.drawLine(
      Offset(rect.right, rect.top),
      Offset(rect.right, rect.bottom),
      Paint()
        ..color = const Color(0x55FFFFFF)
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      Offset(rect.right + gap * zoom, rect.top),
      Offset(rect.right + gap * zoom, rect.bottom),
      Paint()
        ..color = const Color(0x55FF5252)
        ..strokeWidth = 1.5,
    );

    // The baseline: where a glyph's rows sit relative to the line it is set on.
    if (baseline > 0 && baseline <= glyph.rows.length) {
      canvas.drawLine(
        Offset(rect.left, rect.top + baseline * zoom),
        Offset(rect.right, rect.top + baseline * zoom),
        Paint()
          ..color = const Color(0x66FFD166)
          ..strokeWidth = 1,
      );
    }

    final at = cursor;
    if (at != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          rect.left + at.dx * zoom,
          rect.top + at.dy * zoom,
          zoom,
          zoom,
        ).deflate(1),
        Paint()
          ..color = const Color(0xCC64B5F6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(GlyphEditorPainter old) => true;
}
