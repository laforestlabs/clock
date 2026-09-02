// Game fit: the simulated panel fills its box instead of sitting at a fixed
// size. Same arithmetic as the layout preview's fit, extracted so it can be
// tested without a native game engine.
//
// "Fit" means the multiplier that fills the tighter axis exactly, never below
// 1, so the panel uses every pixel of its box and is never shrunk past one
// screen pixel per cell.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/ui/game_screen.dart';

void main() {
  test('fills the tighter axis exactly when width is tighter', () {
    final zoom = fitGameZoom(
      maxWidth: 328,
      maxHeight: 208,
      canvasWidth: 128,
      canvasHeight: 64,
    );
    // 328/128 is 2.5625, 208/64 is 3.25; width wins.
    expect(zoom, 328 / 128);
    expect(128 * zoom, 328);
  });

  test('fills the tighter axis exactly when height is tighter', () {
    final zoom = fitGameZoom(
      maxWidth: 640,
      maxHeight: 160,
      canvasWidth: 64,
      canvasHeight: 32,
    );
    // 640/64 is 10, 160/32 is 5; height wins.
    expect(zoom, 5);
  });

  test('never goes below one screen pixel per cell', () {
    final zoom = fitGameZoom(
      maxWidth: 10,
      maxHeight: 10,
      canvasWidth: 128,
      canvasHeight: 64,
    );
    expect(zoom, 1);
  });

  test('an exact fit on both axes is left alone', () {
    final zoom = fitGameZoom(
      maxWidth: 640,
      maxHeight: 320,
      canvasWidth: 64,
      canvasHeight: 32,
    );
    expect(zoom, 10);
  });
}
