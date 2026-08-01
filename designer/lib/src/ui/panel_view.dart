// The panel preview.
//
// Draws the engine's frame at an integer zoom with nearest-neighbour sampling,
// then puts editor chrome on top as a separate layer. Selection outlines and
// mirror dimming are painted here rather than by the engine, so the image
// underneath stays exactly what the hardware would show.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../controller.dart';
import 'handles.dart';

class PanelView extends StatefulWidget {
  const PanelView({super.key, required this.controller});

  final DesignerController controller;

  @override
  State<PanelView> createState() => _PanelViewState();
}

class _PanelViewState extends State<PanelView> {
  Offset? _dragAnchor;

  /// Set for the duration of a resize gesture, along with the rect and pointer
  /// position it started from.
  ResizeHandle? _resizing;
  Rect? _resizeStartRect;
  Offset? _resizeStartCanvas;

  /// Handle currently under the mouse. Drives the cursor only.
  ResizeHandle? _hover;

  /// Where the pointer actually went down.
  ///
  /// Not the same as the pan's start position: a drag is only recognised once
  /// the pointer has travelled the touch slop, which is further than a handle
  /// is wide. Hit testing the later position misses the handle nearly every
  /// time, because a resize drag moves away from the handle by definition.
  Offset? _pressLocal;

  DesignerController get _c => widget.controller;

  /// Maps a pointer position to a canvas pixel coordinate.
  Offset _toCanvas(Offset local) => Offset(
        local.dx / _c.zoom,
        local.dy / _c.zoom,
      );

  /// Handles for the current selection, or null when nothing is selected.
  SelectionHandles? get _selectionHandles {
    final index = _c.selected;
    if (index < 0 || index >= _c.widgetInfo.length) return null;
    final r = _c.widgetInfo[index].rect;
    return SelectionHandles(
      Rect.fromLTWH(
        r.left * _c.zoom,
        r.top * _c.zoom,
        r.width * _c.zoom,
        r.height * _c.zoom,
      ),
    );
  }

  void _onTapDown(TapDownDetails details) {
    // A press on a handle is aimed at the current selection, not at whatever
    // sits under it. Grab zones overhang the widget edge, so without this a tap
    // on the outer half of a handle would select the widget behind.
    if (_selectionHandles?.hitTest(details.localPosition) != null) return;

    final p = _toCanvas(details.localPosition);
    _c.selectAt(p.dx.floor(), p.dy.floor());
  }

  void _onPanStart(DragStartDetails details) {
    // What the gesture is aimed at is decided by where the finger landed, not
    // by where the pan happened to be recognised: see [_pressLocal]. The delta
    // is still measured from the pan start, so nothing jumps by the slop the
    // instant the drag is recognised.
    final press = _pressLocal ?? details.localPosition;
    final anchor = _toCanvas(details.localPosition);

    // Handles win over the widget underneath, otherwise the outer half of every
    // handle would start a move instead of a resize.
    final handle = _selectionHandles?.hitTest(press);
    if (handle != null) {
      _resizing = handle;
      _resizeStartRect = _c.widgetInfo[_c.selected].rect;
      _resizeStartCanvas = anchor;
      _dragAnchor = null;
      // One undo entry for the whole gesture rather than one per pointer event.
      _c.beginGesture();
      return;
    }

    final p = _toCanvas(press);
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
    _c.beginGesture();
    _dragAnchor = anchor;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final handle = _resizing;
    if (handle != null) {
      _applyResize(handle, _toCanvas(details.localPosition));
      return;
    }

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

  /// Applies a resize for the current pointer position.
  ///
  /// The geometry lives in [SelectionHandles.resize] so it can be tested
  /// without a render engine; this only supplies the gesture's starting state.
  void _applyResize(ResizeHandle handle, Offset canvasPos) {
    final start = _resizeStartRect;
    final from = _resizeStartCanvas;
    if (start == null || from == null) return;

    _c.resizeSelected(
      SelectionHandles.resize(
        start: start,
        handle: handle,
        delta: canvasPos - from,
        canvas: Size(_c.doc.width.toDouble(), _c.doc.height.toDouble()),
      ),
      coalesce: true,
    );
  }

  void _endGesture() {
    _dragAnchor = null;
    _resizing = null;
    _resizeStartRect = null;
    _resizeStartCanvas = null;
  }

  void _onPanEnd(DragEndDetails details) => _endGesture();

  void _setHover(ResizeHandle? handle) {
    if (handle == _hover) return;
    setState(() => _hover = handle);
  }

  /// Directional cursor over a handle. This is what makes the handles
  /// discoverable with a mouse, since nothing else advertises them.
  MouseCursor get _cursor {
    switch (_hover) {
      case null:
        return MouseCursor.defer;
      case ResizeHandle.topLeft:
      case ResizeHandle.bottomRight:
        return SystemMouseCursors.resizeUpLeftDownRight;
      case ResizeHandle.topRight:
      case ResizeHandle.bottomLeft:
        return SystemMouseCursors.resizeUpRightDownLeft;
      case ResizeHandle.top:
      case ResizeHandle.bottom:
        return SystemMouseCursors.resizeUpDown;
      case ResizeHandle.left:
      case ResizeHandle.right:
        return SystemMouseCursors.resizeLeftRight;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The controller decides the zoom but cannot see the window, so hand it
        // the box this view was given. Reported after the frame rather than
        // during it, because a re-fit notifies listeners and doing that in the
        // middle of a build is an error.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _c.reportViewport(constraints.biggest);
        });
        return _buildPanel();
      },
    );
  }

  Widget _buildPanel() {
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
          child: MouseRegion(
            cursor: _cursor,
            onHover: (event) =>
                _setHover(_selectionHandles?.hitTest(event.localPosition)),
            onExit: (_) => _setHover(null),
            // GestureDetector does not expose the pointer-down position, and by
            // the time a pan is recognised the pointer has already left the
            // handle. This records where the press actually landed.
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) => _pressLocal = event.localPosition,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: _onTapDown,
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                onPanCancel: _endGesture,
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

    // Built from the same geometry the hit test uses, so every handle drawn
    // here is one that can actually be grabbed.
    final handles = SelectionHandles(scaled);
    final fill = Paint()..color = const Color(0xFF00E5FF);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xCC000000);

    const radius = 3.5;
    for (final handle in handles.visible) {
      final centre = handles.centerOf(handle);
      canvas.drawCircle(centre, radius, fill);
      canvas.drawCircle(centre, radius, edge);
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
