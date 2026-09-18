// MotionControl: the phone's angle as a position in the game's travel.
// Kept pure (no Flutter or plugin imports) so the mapping is testable
// without a device, like the rest of the protocol layer.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/motion_control.dart';

/// Gravity, and the two gestures a player makes, as the accelerometer sees
/// them. A roll sample holds the phone's right edge down by [deg]; a pitch
/// sample tips its top edge away by [deg].
const double _g = 9.81;

List<double> _rollSample(double deg) {
  final r = deg * math.pi / 180;
  return <double>[0, _g * math.sin(r), _g * math.cos(r)];
}

List<double> _pitchSample(double deg) {
  final r = deg * math.pi / 180;
  return <double>[math.sin(r) * _g, 0, _g * math.cos(r)];
}

void main() {
  group('MotionControl', () {
    /// Establish neutral from a level, screen-up hold.
    void calibrate(MotionControl m) {
      for (var i = 0; i < m.calibrationSamples; i++) {
        m.addSample(0, 0, _g);
      }
    }

    /// Feed one tilt until the filter has settled (the EMA converges in well
    /// under this many samples).
    void settle(MotionControl m, List<double> sample, [int n = 60]) {
      for (var i = 0; i < n; i++) {
        m.addSample(sample[0], sample[1], sample[2]);
      }
    }

    test('reports idle on both axes before neutral is established', () {
      final m = MotionControl();
      expect(m.calibrated, isFalse);
      expect(m.posX, MotionControl.idle);
      expect(m.posY, MotionControl.idle);
    });

    test('calibrates to a neutral hold at the middle of the travel', () {
      final m = MotionControl();
      calibrate(m);
      expect(m.calibrated, isTrue);
      expect(m.posX, 0);
      expect(m.posY, 0);
    });

    test('rolls right with the phone and left the other way', () {
      final m = MotionControl();
      calibrate(m);

      settle(m, _rollSample(30));
      expect(m.posX, MotionControl.full);
      expect(m.posY, 0);

      settle(m, _rollSample(-30));
      expect(m.posX, -MotionControl.full);
      expect(m.posY, 0);
    });

    test('tips the player up when the phone tips away', () {
      final m = MotionControl();
      calibrate(m);

      // Canvas convention: up is negative, so the pitch reads back inverted.
      settle(m, _pitchSample(30));
      expect(m.posY, -MotionControl.full);
      expect(m.posX, 0);

      settle(m, _pitchSample(-30));
      expect(m.posY, MotionControl.full);
      expect(m.posX, 0);
    });

    test('maps the angle proportionally between the middle and the end', () {
      final m = MotionControl();
      calibrate(m);

      settle(m, _rollSample(3));
      final int three = m.posX;
      settle(m, _rollSample(6));
      final int six = m.posX;
      settle(m, _rollSample(10));
      final int ten = m.posX;
      settle(m, _rollSample(15));
      final int fifteen = m.posX;

      // Monotone all the way up, and the end is not reached short of 20
      // degrees.
      expect(three, lessThan(six));
      expect(six, lessThan(ten));
      expect(ten, lessThan(fifteen));
      expect(fifteen, lessThan(MotionControl.full));

      // Half the travel sits a little under half the range and three quarters
      // a little over: the half degree of dead zone comes off the bottom of
      // the scale, so every angle reads slightly higher than its share.
      expect(ten, closeTo(16000, 400));
      expect(fifteen, closeTo(24400, 400));
    });

    test('saturates at the ends rather than running past them', () {
      final m = MotionControl();
      calibrate(m);
      settle(m, _rollSample(45));
      expect(m.posX, MotionControl.full);
      settle(m, _rollSample(20));
      expect(m.posX, MotionControl.full);
    });

    test('holds exactly zero inside the dead zone', () {
      final m = MotionControl();
      calibrate(m);
      settle(m, _rollSample(0.5)); // the dead zone is half a degree
      expect(m.posX, 0);
      settle(m, _pitchSample(-0.5));
      expect(m.posY, 0);

      // Just outside it the position moves, but only a little: a degree of
      // tilt is about 840 of the 32767, on a 20 degree travel.
      settle(m, _rollSample(1));
      expect(m.posX, closeTo(840, 60));
      expect(m.posX, lessThan(MotionControl.full ~/ 10));
    });

    test('a held angle converges to a held position', () {
      final m = MotionControl();
      calibrate(m);
      settle(m, _rollSample(15));
      final int settled = m.posX;
      for (var i = 0; i < 10; i++) {
        m.addSample(0, _g * math.sin(15 * math.pi / 180),
            _g * math.cos(15 * math.pi / 180));
        expect(m.posX, settled, reason: 'the position drifted under a still phone');
      }
    });

    test('a single strong sample does not jump the whole travel', () {
      final m = MotionControl();
      calibrate(m);
      // One 40 degree sample: the filter takes it a fraction of the way.
      m.addSample(0, _g * math.sin(40 * math.pi / 180),
          _g * math.cos(40 * math.pi / 180));
      expect(m.posX, lessThan(MotionControl.full));
      expect(m.posX, greaterThan(0));
    });

    test('the hold that was calibrated becomes the middle of the travel', () {
      final m = MotionControl();
      for (var i = 0; i < m.calibrationSamples; i++) {
        m.addSample(0, _g * math.sin(20 * math.pi / 180),
            _g * math.cos(20 * math.pi / 180));
      }
      settle(m, _rollSample(20));
      expect(m.posX, 0);
      settle(m, _rollSample(50));
      expect(m.posX, MotionControl.full);
    });

    test('never reports the idle value once neutral is established', () {
      final m = MotionControl();
      calibrate(m);
      for (var deg = -60; deg <= 60; deg += 2) {
        settle(m, _rollSample(deg.toDouble()), 20);
        expect(m.posX, isNot(MotionControl.idle));
        settle(m, _pitchSample(deg.toDouble()), 20);
        expect(m.posY, isNot(MotionControl.idle));
      }
    });
  });
}
