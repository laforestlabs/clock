// Selection handle geometry.
//
// Pure geometry, deliberately kept out of the widget. The painter and the hit
// test both go through this, so the handle you can grab is by construction the
// handle you can see; computed separately the two would drift.
//
// It is also the part of resizing most worth testing, and a plain function over
// rectangles can be tested without a render engine or a native library.

import 'dart:math' as math;
import 'dart:ui';

/// Which grab handle the pointer is on. Corners move two edges at once, the
/// side midpoints move one.
enum ResizeHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
}

class SelectionHandles {
  const SelectionHandles(this.rect);

  /// The selection in screen pixels, so already multiplied by zoom.
  final Rect rect;

  /// A side shorter than this gets no midpoint handle: it would land on top of
  /// the corner handles rather than between them.
  static const double edgeMin = 30;

  /// Smallest widget a resize will produce. The engine hit tests against the
  /// rect, so a zero-width widget would be invisible *and* unselectable.
  static const double minExtent = 1;

  /// Grab radius. Capped against the widget's own size so the handles of a
  /// small widget cannot cover it entirely, which would leave nowhere to press
  /// for a move.
  double get slop => math.min(11.0, math.max(4.0, rect.shortestSide / 3));

  List<ResizeHandle> get visible => <ResizeHandle>[
        ResizeHandle.topLeft,
        ResizeHandle.topRight,
        ResizeHandle.bottomLeft,
        ResizeHandle.bottomRight,
        if (rect.width >= edgeMin) ResizeHandle.top,
        if (rect.width >= edgeMin) ResizeHandle.bottom,
        if (rect.height >= edgeMin) ResizeHandle.left,
        if (rect.height >= edgeMin) ResizeHandle.right,
      ];

  Offset centerOf(ResizeHandle handle) {
    switch (handle) {
      case ResizeHandle.topLeft:
        return rect.topLeft;
      case ResizeHandle.top:
        return rect.topCenter;
      case ResizeHandle.topRight:
        return rect.topRight;
      case ResizeHandle.right:
        return rect.centerRight;
      case ResizeHandle.bottomRight:
        return rect.bottomRight;
      case ResizeHandle.bottom:
        return rect.bottomCenter;
      case ResizeHandle.bottomLeft:
        return rect.bottomLeft;
      case ResizeHandle.left:
        return rect.centerLeft;
    }
  }

  /// The handle under a point, or null. Nearest wins where two grab zones
  /// overlap, which they do on a small widget.
  ResizeHandle? hitTest(Offset point) {
    ResizeHandle? best;
    var bestDistance = slop;
    for (final handle in visible) {
      final distance = (centerOf(handle) - point).distance;
      if (distance <= bestDistance) {
        best = handle;
        bestDistance = distance;
      }
    }
    return best;
  }

  static bool movesLeft(ResizeHandle h) =>
      h == ResizeHandle.topLeft ||
      h == ResizeHandle.left ||
      h == ResizeHandle.bottomLeft;

  static bool movesRight(ResizeHandle h) =>
      h == ResizeHandle.topRight ||
      h == ResizeHandle.right ||
      h == ResizeHandle.bottomRight;

  static bool movesTop(ResizeHandle h) =>
      h == ResizeHandle.topLeft ||
      h == ResizeHandle.top ||
      h == ResizeHandle.topRight;

  static bool movesBottom(ResizeHandle h) =>
      h == ResizeHandle.bottomLeft ||
      h == ResizeHandle.bottom ||
      h == ResizeHandle.bottomRight;

  /// The rect a resize gesture produces, in canvas pixels.
  ///
  /// Takes the rect the gesture *started* on plus the total delta, rather than
  /// accumulating per-event deltas. Incremental application rounds at every
  /// step, and over a long drag the pinned edge visibly creeps away from where
  /// it started.
  ///
  /// Only the edges belonging to [handle] move. The rest stay exactly put,
  /// which is the whole point of grabbing a specific handle.
  static Rect resize({
    required Rect start,
    required ResizeHandle handle,
    required Offset delta,
    required Size canvas,
  }) {
    var left = start.left;
    var top = start.top;
    var right = start.right;
    var bottom = start.bottom;

    if (movesLeft(handle)) {
      left = (start.left + delta.dx).clamp(0.0, canvas.width);
    }
    if (movesRight(handle)) {
      right = (start.right + delta.dx).clamp(0.0, canvas.width);
    }
    if (movesTop(handle)) {
      top = (start.top + delta.dy).clamp(0.0, canvas.height);
    }
    if (movesBottom(handle)) {
      bottom = (start.bottom + delta.dy).clamp(0.0, canvas.height);
    }

    // Dragging an edge past the opposite one pins the widget at minimum size
    // rather than turning it inside out.
    if (right - left < minExtent) {
      if (movesLeft(handle)) {
        left = right - minExtent;
      } else {
        right = left + minExtent;
      }
    }
    if (bottom - top < minExtent) {
      if (movesTop(handle)) {
        top = bottom - minExtent;
      } else {
        bottom = top + minExtent;
      }
    }

    return Rect.fromLTRB(left, top, right, bottom);
  }
}
