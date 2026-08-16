// MotionControl: maps phone accelerometer tilt to held direction buttons.
// Kept pure (no Flutter or plugin imports) so the mapping is testable
// without a device, like the rest of the protocol layer.

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/motion_control.dart';

void main() {
  group('MotionControl', () {
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
      for (var i = 0; i < m.calibrationSamples; i++) {
        m.addSample(0, 0, 9.81);
      }
      expect(m.calibrated, isTrue);
      expect(m.up, isFalse);
      expect(m.down, isFalse);
      expect(m.left, isFalse);
      expect(m.right, isFalse);
    });

    test('tilts right when y is positive', () {
      final m = MotionControl();
      for (var i = 0; i < m.calibrationSamples; i++) {
        m.addSample(0, 0, 9.81);
      }
      m.addSample(0, 3.0, 9.81);
      expect(m.right, isTrue);
      expect(m.left, isFalse);
      expect(m.up, isFalse);
      expect(m.down, isFalse);
    });

    test('tilts left when y is negative', () {
      final m = MotionControl();
      for (var i = 0; i < m.calibrationSamples; i++) {
        m.addSample(0, 0, 9.81);
      }
      m.addSample(0, -3.0, 9.81);
      expect(m.left, isTrue);
      expect(m.right, isFalse);
      expect(m.up, isFalse);
      expect(m.down, isFalse);
    });

    test('tilts up when x is positive and down when negative', () {
      final m = MotionControl();
      for (var i = 0; i < m.calibrationSamples; i++) {
        m.addSample(0, 0, 9.81);
      }

      m.addSample(3.0, 0, 9.81);
      expect(m.up, isTrue);
      expect(m.down, isFalse);
      expect(m.left, isFalse);
      expect(m.right, isFalse);

      m.addSample(-3.0, 0, 9.81);
      expect(m.down, isTrue);
      expect(m.up, isFalse);
      expect(m.left, isFalse);
      expect(m.right, isFalse);
    });

    test('does not trigger inside the dead zone', () {
      final m = MotionControl();
      for (var i = 0; i < m.calibrationSamples; i++) {
        m.addSample(0, 0, 9.81);
      }
      m.addSample(0, 0.5, 9.81);
      expect(m.up, isFalse);
      expect(m.down, isFalse);
      expect(m.left, isFalse);
      expect(m.right, isFalse);
    });
  });
}
