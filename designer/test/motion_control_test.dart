// MotionControl: maps phone accelerometer tilt to held direction buttons.
// Kept pure (no Flutter or plugin imports) so the mapping is testable
// without a device, like the rest of the protocol layer.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/motion_control.dart';

void main() {
  group('MotionControl', () {
    // Feed the calibration baseline: a flat, screen-up hold.
    void calibrate(MotionControl m) {
      for (var i = 0; i < m.calibrationSamples; i++) {
        m.addSample(0, 0, 9.81);
      }
    }

    // Feed one tilted sample enough times for the low-pass filter to settle.
    void tilt(MotionControl m, double x, double y) {
      for (var i = 0; i < 8; i++) {
        m.addSample(x, y, 9.81);
      }
    }

    test('is not calibrated and holds no direction before samples', () {
      final m = MotionControl();
      expect(m.calibrated, isFalse);
      expect(m.up, isFalse);
      expect(m.down, isFalse);
      expect(m.left, isFalse);
      expect(m.right, isFalse);
    });

    test('calibrates to a neutral flat hold', () {
      final m = MotionControl();
      calibrate(m);
      expect(m.calibrated, isTrue);
      expect(m.up, isFalse);
      expect(m.down, isFalse);
      expect(m.left, isFalse);
      expect(m.right, isFalse);
    });

    test('tilts right when y is positive', () {
      final m = MotionControl();
      calibrate(m);
      tilt(m, 0, 3.0);
      expect(m.right, isTrue);
      expect(m.left, isFalse);
      expect(m.up, isFalse);
      expect(m.down, isFalse);
    });

    test('tilts left when y is negative', () {
      final m = MotionControl();
      calibrate(m);
      tilt(m, 0, -3.0);
      expect(m.left, isTrue);
      expect(m.right, isFalse);
      expect(m.up, isFalse);
      expect(m.down, isFalse);
    });

    test('tilts up when x is positive and down when negative', () {
      final m = MotionControl();
      calibrate(m);

      tilt(m, 3.0, 0);
      expect(m.up, isTrue);
      expect(m.down, isFalse);

      tilt(m, -3.0, 0);
      expect(m.down, isTrue);
      expect(m.up, isFalse);
    });

    test('does not trigger inside the dead zone', () {
      final m = MotionControl();
      calibrate(m);
      tilt(m, 0, 0.5);
      expect(m.up, isFalse);
      expect(m.down, isFalse);
      expect(m.left, isFalse);
      expect(m.right, isFalse);
    });

    test('holds a direction through a small wobble (hysteresis)', () {
      final m = MotionControl();
      calibrate(m);
      tilt(m, 0, 3.0); // ~17 degrees: engages right
      expect(m.right, isTrue);
      // Wobble back to ~8 degrees: still held, above the release zone.
      tilt(m, 0, 1.4);
      expect(m.right, isTrue);
      // Return near center (~3 degrees): releases.
      tilt(m, 0, 0.5);
      expect(m.right, isFalse);
    });

    test('a single strong sample does not trigger (filtered)', () {
      final m = MotionControl();
      calibrate(m);
      m.addSample(0, 3.0, 9.81);
      expect(m.right, isFalse);
    });

    test('reports zero axes before calibration', () {
      final m = MotionControl();
      expect(m.tiltXAxis, 0);
      expect(m.tiltYAxis, 0);
    });

    test('maps tilt to signed axis values after calibration', () {
      final m = MotionControl();
      calibrate(m);
      tilt(m, 0, 3.0); // rightward tilt
      expect(m.tiltXAxis, greaterThan(0));
      expect(m.tiltYAxis, closeTo(0, 1));
    });
  });
}
