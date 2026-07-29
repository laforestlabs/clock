// The panel preview.
//
// Draws the engine's frame at an integer zoom with nearest-neighbour sampling,
// then puts editor chrome on top as a separate layer. Selection outlines and
// mirror dimming are painted here rather than by the engine, so the image
// underneath stays exactly what the hardware would show.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../controller.dart';

class PanelView extends StatefulWidget {
  const PanelView({super.key, required this.controller});

  final DesignerController controller;

  @override
  State<PanelView> createState() => _PanelViewState();
}

class _PanelViewState extends State<PanelView> {
  Offset? _dragAnchor;

  DesignerController get _c => widget.controller;

  /// Maps a pointer position to a canvas pixel coordinate.
  Offset _toCanvas(Offset local) => Offset(
        local.dx / _c.zoom,
        local.dy / _c.zoom,
      );

  void _onTapDown(TapDownDetails details) {
    final p = _toCanvas(details.localPosition);
    _c.selectAt(p.dx.floor(), p.dy.floor());
  }

  void _onPanStart(DragStartDetails details) {
    final p = _toCanvas(details.localPosition);
    final x = p.dx.floor();
    final y = p.dy.floor();

    // Dragging empty space selects nothing and does not start a move.
    final hit = _c.engine.hitTest(x, y);
    if (hit < 0) {
      _c.select(-1);
      _dragAnchor = null;
      return;
    }

    _c.select(hit);
    // One undo entry for the whole gesture rather than one per pointer event.
    _c.beginGesture();
    _dragAnchor = p;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final anchor = _dragAnchor;
    if (anchor == null) return;

    final p = _toCanvas(details.localPosition);

    // Only act on whole-pixel movement. Sub-pixel deltas would either do
    // nothing or accumulate rounding drift over a long drag.
    final dx = p.dx.floor() - anchor.dx.floor();
    final dy = p.dy.floor() - anchor.dy.floor();
    if (dx == 0 && dy == 0) return;

    _c.nudgeSelected(dx, dy, coalesce: true);
    _dragAnchor = p;
  }

  void _onPanEnd(DragEndDetails details) => _dragAnchor = null;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final w = _c.doc.width * _c.zoom;
        final h = _c.doc.height * _c.zoom;

        Rect? selection;
        if (_c.selected >= 0 && _c.selected < _c.widgetInfo.length) {
          selection = _c.widgetInfo[_c.selected].rect;
        }

        return InteractiveViewer(
          // Panning is for phones, where the panel at a usable zoom is wider
          // than the screen. Scale stays at 1 because zoom is an integer
          // control; a fractional scale would reintroduce blurring.
          constrained: false,
          minScale: 1,
          maxScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _onTapDown,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            child: CustomPaint(
              size: Size(w, h),
              isComplex: true,
              painter: _PanelPainter(
                image: _c.image,
                zoom: _c.zoom,
                ledGrid: _c.ledGrid,
                transmission: _c.transmission,
                selection: selection,
                canvasWidth: _c.doc.width,
                canvasHeight: _c.doc.height,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PanelPainter extends CustomPainter {
  _PanelPainter({
    required this.image,
    required this.zoom,
    required this.ledGrid,
    required this.transmission,
    required this.selection,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  final ui.Image? image;
  final double zoom;
  final bool ledGrid;
  final double transmission;
  final Rect? selection;
  final int canvasWidth;
  final int canvasHeight;

  /// Scales RGB uniformly to approximate the fraction of light a two-way
  /// mirror passes. Applied to the view only; the engine's pixels are
  /// untouched.
  ColorFilter? get _transmissionFilter {
    if (transmission >= 100) return null;
    final t = transmission / 100.0;
    return ColorFilter.matrix(<double>[
      t, 0, 0, 0, 0, //
      0, t, 0, 0, 0, //
      0, 0, t, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF000000),
    );

    final img = image;
    if (img != null) {
      final paint = Paint()
        // Nearest neighbour is mandatory. Any interpolation blurs a 5x7 glyph
        // into unreadable grey and the preview stops matching the panel.
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false
        ..colorFilter = _transmissionFilter;

      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(0, 0, canvasWidth * zoom, canvasHeight * zoom),
        paint,
      );
    }

    if (ledGrid && zoom >= 3) _paintGrid(canvas);
    if (selection != null) _paintSelection(canvas, selection!);
  }

  /// Dark seams between pixels, so the preview reads as discrete LEDs rather
  /// than a continuous image. Worth having: text that looks solid as a bitmap
  /// can look sparse on a real panel with visible gaps.
  void _paintGrid(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0x66000000)
      ..strokeWidth = 1
      ..isAntiAlias = false;

    final w = canvasWidth * zoom;
    final h = canvasHeight * zoom;

    for (var x = 1; x <= canvasWidth; x++) {
      final dx = x * zoom - 0.5;
      canvas.drawLine(Offset(dx, 0), Offset(dx, h), paint);
    }
    for (var y = 1; y <= canvasHeight; y++) {
      final dy = y * zoom - 0.5;
      canvas.drawLine(Offset(0, dy), Offset(w, dy), paint);
    }
  }

  void _paintSelection(Canvas canvas, Rect r) {
    final scaled = Rect.fromLTWH(
      r.left * zoom,
      r.top * zoom,
      r.width * zoom,
      r.height * zoom,
    );

    // Dark halo first so the outline stays visible over bright content.
    canvas.drawRect(
      scaled.inflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xAA000000),
    );
    canvas.drawRect(
      scaled,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF00E5FF),
    );

    final handle = Paint()..color = const Color(0xFF00E5FF);
    const radius = 3.0;
    for (final corner in <Offset>[
      scaled.topLeft,
      scaled.topRight,
      scaled.bottomLeft,
      scaled.bottomRight,
    ]) {
      canvas.drawCircle(corner, radius, handle);
    }
  }

  @override
  bool shouldRepaint(_PanelPainter old) =>
      old.image != image ||
      old.zoom != zoom ||
      old.ledGrid != ledGrid ||
      old.transmission != transmission ||
      old.selection != selection ||
      old.canvasWidth != canvasWidth ||
      old.canvasHeight != canvasHeight;
}
