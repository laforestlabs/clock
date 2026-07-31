// Selection handle geometry.
//
// This is the part of resizing most likely to be subtly wrong: which edges a
// handle moves, what happens at the canvas boundary, and what happens when a
// drag crosses the opposite edge. All of it is pure, so none of it needs the
// render engine or the native library.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/ui/handles.dart';

void main() {
  // 128x64 is the two-panel layout the stock designs use.
  const canvas = Size(128, 64);

  group('which handles exist', () {
    test('a large selection gets all eight', () {
      const h = SelectionHandles(Rect.fromLTWH(0, 0, 40, 40));
      expect(h.visible.length, 8);
    });

    test('a narrow selection drops the top and bottom midpoints', () {
      // Width under edgeMin: a midpoint would land on top of the corners.
      const h = SelectionHandles(Rect.fromLTWH(0, 0, 20, 40));
      expect(h.visible, isNot(contains(ResizeHandle.top)));
      expect(h.visible, isNot(contains(ResizeHandle.bottom)));
      expect(h.visible, contains(ResizeHandle.left));
      expect(h.visible, contains(ResizeHandle.right));
    });

    test('a tiny selection keeps only the corners', () {
      const h = SelectionHandles(Rect.fromLTWH(0, 0, 12, 12));
      expect(h.visible.length, 4);
      expect(h.visible, contains(ResizeHandle.topLeft));
    });
  });

  group('grab radius', () {
    test('never exceeds the cap on a big selection', () {
      const h = SelectionHandles(Rect.fromLTWH(0, 0, 500, 500));
      expect(h.slop, 11.0);
    });

    test('shrinks with the widget so there is room left to press for a move',
        () {
      const big = SelectionHandles(Rect.fromLTWH(0, 0, 500, 500));
      const small = SelectionHandles(Rect.fromLTWH(0, 0, 18, 18));
      expect(small.slop, lessThan(big.slop));
      expect(small.slop, greaterThanOrEqualTo(4.0));
    });
  });

  group('hit testing', () {
    const h = SelectionHandles(Rect.fromLTWH(0, 0, 40, 40));

    test('finds each corner', () {
      expect(h.hitTest(const Offset(0, 0)), ResizeHandle.topLeft);
      expect(h.hitTest(const Offset(40, 0)), ResizeHandle.topRight);
      expect(h.hitTest(const Offset(0, 40)), ResizeHandle.bottomLeft);
      expect(h.hitTest(const Offset(40, 40)), ResizeHandle.bottomRight);
    });

    test('finds the side midpoints', () {
      expect(h.hitTest(const Offset(20, 0)), ResizeHandle.top);
      expect(h.hitTest(const Offset(0, 20)), ResizeHandle.left);
    });

    test('misses the middle, so a drag there still moves the widget', () {
      expect(h.hitTest(const Offset(20, 20)), isNull);
    });

    test('misses well outside the selection', () {
      expect(h.hitTest(const Offset(200, 200)), isNull);
    });

    test('nearest wins where two grab zones overlap', () {
      // Exactly at edgeMin, so topLeft (0,0) and top (15,0) both exist and
      // their radii overlap. A point at x=7 is nearer the corner.
      const tight = SelectionHandles(Rect.fromLTWH(0, 0, 30, 30));
      expect(tight.hitTest(const Offset(7, 0)), ResizeHandle.topLeft);
      expect(tight.hitTest(const Offset(13, 0)), ResizeHandle.top);
    });
  });

  group('resize', () {
    const start = Rect.fromLTWH(10, 10, 40, 16);

    test('a zero delta changes nothing', () {
      final r = SelectionHandles.resize(
        start: start,
        handle: ResizeHandle.bottomRight,
        delta: Offset.zero,
        canvas: canvas,
      );
      expect(r, start);
    });

    test('bottom-right grows both axes and holds the origin', () {
      final r = SelectionHandles.resize(
        start: start,
        handle: ResizeHandle.bottomRight,
        delta: const Offset(5, 4),
        canvas: canvas,
      );
      expect(r, const Rect.fromLTRB(10, 10, 55, 30));
    });

    test('top-left moves the origin and holds the far corner', () {
      final r = SelectionHandles.resize(
        start: start,
        handle: ResizeHandle.topLeft,
        delta: const Offset(5, 4),
        canvas: canvas,
      );
      expect(r, const Rect.fromLTRB(15, 14, 50, 26));
    });

    test('a side handle moves one edge only', () {
      // A large dy must not affect a horizontal handle.
      final r = SelectionHandles.resize(
        start: start,
        handle: ResizeHandle.right,
        delta: const Offset(5, 99),
        canvas: canvas,
      );
      expect(r, const Rect.fromLTRB(10, 10, 55, 26));
    });

    test('stops at the canvas edge instead of growing past the panel', () {
      final r = SelectionHandles.resize(
        start: const Rect.fromLTWH(100, 10, 20, 16),
        handle: ResizeHandle.bottomRight,
        delta: const Offset(500, 500),
        canvas: canvas,
      );
      expect(r.right, canvas.width);
      expect(r.bottom, canvas.height);
    });

    test('dragging an edge past the opposite one pins to minimum, not inverted',
        () {
      final r = SelectionHandles.resize(
        start: start,
        handle: ResizeHandle.right,
        delta: const Offset(-500, 0),
        canvas: canvas,
      );
      expect(r.width, SelectionHandles.minExtent);
      expect(r.left, 10, reason: 'the handle that was not grabbed must not move');
      expect(r.width, greaterThan(0));
    });

    test('dragging top-left past the far corner pins both axes', () {
      final r = SelectionHandles.resize(
        start: start,
        handle: ResizeHandle.topLeft,
        delta: const Offset(500, 500),
        canvas: canvas,
      );
      expect(r.width, SelectionHandles.minExtent);
      expect(r.height, SelectionHandles.minExtent);
      expect(r.right, start.right, reason: 'the far corner stays put');
      expect(r.bottom, start.bottom);
    });

    test('is anchored, so applying the same delta twice is idempotent', () {
      const delta = Offset(7, 3);
      final once = SelectionHandles.resize(
        start: start,
        handle: ResizeHandle.bottomRight,
        delta: delta,
        canvas: canvas,
      );
      final twice = SelectionHandles.resize(
        start: start,
        handle: ResizeHandle.bottomRight,
        delta: delta,
        canvas: canvas,
      );
      expect(once, twice);
    });
  });
}
