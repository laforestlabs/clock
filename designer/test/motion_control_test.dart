// MotionControl: the phone's orientation as a position in the game's travel,
// with the gyroscope and the accelerometer fused.
// Kept pure (no Flutter or plugin imports) so the fusion is testable without a
// device, like the rest of the protocol layer.
//
// The numbers asserted here were measured on a prototype of the same maths
// before the implementation was written (documented in
// docs/motion_gyro_fusion_plan.md, D3); they are what the design claims, so a
// test that fails here is a design or implementation change, not a stale
// expectation.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mirror_designer/src/services/motion_control.dart';

const double _g = 9.81;

/// [v] rotated about the unit vector [axis] by [theta] radians.
List<double> _rotate(List<double> v, List<double> axis, double theta) {
  final double c = math.cos(theta), s = math.sin(theta);
  final double dot = v[0] * axis[0] + v[1] * axis[1] + v[2] * axis[2];
  final List<double> cross = <double>[
    axis[1] * v[2] - axis[2] * v[1],
    axis[2] * v[0] - axis[0] * v[2],
    axis[0] * v[1] - axis[1] * v[0],
  ];
  return <double>[
    v[0] * c + cross[0] * s + axis[0] * dot * (1 - c),
    v[1] * c + cross[1] * s + axis[1] * dot * (1 - c),
    v[2] * c + cross[2] * s + axis[2] * dot * (1 - c),
  ];
}

/// The position the mapping gives for [deg] of tilt, so a test can say what it
/// expects in the same terms the game sees.
int _posFor(double deg) {
  final double rad = deg * math.pi / 180;
  const double travel = 20 * math.pi / 180;
  const double dead = 0.5 * math.pi / 180;
  if (rad.abs() <= dead) return 0;
  final double scaled = (rad.abs() - dead) / (travel - dead);
  final int value = ((scaled > 1 ? 1.0 : scaled) * MotionControl.full).round();
  return rad < 0 ? -value : value;
}

/// A phone that is still or rotating about one fixed device axis, emitting what
/// both sensors would read.
///
/// The rotation is about a **single axis**, which is the only case where the
/// body rate equals the derivative of the rotation vector — so the two streams
/// stay consistent by construction, and a test never feeds the fusion the
/// physically impossible thing the old tests did (an accelerometer step with no
/// rotation at all).
///
/// [linear] is the hand's acceleration. It goes into the accelerometer only:
/// that asymmetry is the whole subject of this file. Remember which axis it
/// corrupts — `[0, a, 0]` moves the *roll* (`posX`), `[a, 0, 0]` the *pitch*
/// (`posY`).
class _Rig {
  _Rig({required this.axis, this.angle = 0, List<double>? linear})
      : linear = linear ?? <double>[0, 0, 0];

  /// A rig that rotates about the device x axis, which is the axis the old
  /// tests called "roll" (posX).
  _Rig.roll({double angle = 0, List<double>? linear})
      : this(axis: <double>[1, 0, 0], angle: angle, linear: linear);

  /// A rig that rotates about the device y axis, which drives pitch (posY).
  _Rig.pitch({double angle = 0, List<double>? linear})
      : this(axis: <double>[0, 1, 0], angle: angle, linear: linear);

  final List<double> axis;

  /// Radians from the level reference the mapper is calibrated against.
  double angle;

  /// Hand acceleration in m/s², added to the accelerometer and to nothing else.
  List<double> linear;

  /// Whether the gyroscope is reporting at all: false models a device that has
  /// none, which is a different code path (the fallback gate).
  bool gyro = true;

  static const double _step = 0.02; // SensorInterval.gameInterval, 50 Hz
  double _t = 0;

  List<double> get _accel {
    // Device-frame gravity for this orientation — a fixed world vector seen
    // from a frame that turned — plus the hand's acceleration.
    final List<double> v = _rotate(<double>[0, 0, _g], axis, -angle);
    return <double>[
      v[0] + linear[0],
      v[1] + linear[1],
      v[2] + linear[2],
    ];
  }

  /// One 20 ms step at [rate] rad/s. The gyroscope reports the rate that step
  /// is taken at and the accelerometer the orientation it ends at, so the two
  /// streams describe the same rotation: a real phone's do, and a rig that
  /// disagreed with itself would be testing the fusion's tolerance for
  /// impossible input instead of its behaviour.
  void sample(MotionControl m, {double rate = 0}) {
    final DateTime stamp =
        DateTime.fromMicrosecondsSinceEpoch((_t * 1e6).round());
    if (gyro) {
      m.addGyroSample(axis[0] * rate, axis[1] * rate, axis[2] * rate,
          stamp: stamp);
    }
    angle += rate * _step;
    final List<double> a = _accel;
    m.addAccelSample(a[0], a[1], a[2], stamp: stamp);
    _t += _step;
  }

  /// Rotate by [deg] over [samples] samples, then hold the new angle for
  /// [settle] samples.
  void turn(MotionControl m, double deg, {int samples = 10, int settle = 0}) {
    final double rate = deg * math.pi / 180 / (samples * _step);
    for (var i = 0; i < samples; i++) {
      sample(m, rate: rate);
    }
    hold(m, settle);
  }

  /// Hold the current orientation for [samples] samples.
  void hold(MotionControl m, [int samples = 60]) {
    for (var i = 0; i < samples; i++) {
      sample(m);
    }
  }
}

void main() {
  group('MotionControl', () {
    /// A calibrated mapper facing a still, level rig.
    (MotionControl, _Rig) calibrated({_Rig? rig}) {
      final m = MotionControl();
      final r = rig ?? _Rig.roll();
      for (var i = 0; i < m.calibrationSamples; i++) {
        r.sample(m);
      }
      expect(m.calibrated, isTrue);
      return (m, r);
    }

    test('reports idle on both axes before neutral is established', () {
      final m = MotionControl();
      expect(m.calibrated, isFalse);
      expect(m.calibrationProgress, 0);
      expect(m.posX, MotionControl.idle);
      expect(m.posY, MotionControl.idle);
    });

    test('calibrates to a neutral hold at the middle of the travel', () {
      final (m, _) = calibrated();
      expect(m.posX, 0);
      expect(m.posY, 0);
      expect(m.calibrationProgress, m.calibrationSamples);
      expect(m.gyroscopeAssisted, isTrue);
    });

    test('the hold that was calibrated becomes the middle of the travel', () {
      final m = MotionControl();
      final r = _Rig.roll(angle: 20 * math.pi / 180);
      for (var i = 0; i < m.calibrationSamples; i++) {
        r.sample(m);
      }
      // The tilted hold is the middle, not level.
      r.hold(m);
      expect(m.posX, 0);
      // And 20 degrees further is the end of the travel.
      r.turn(m, 20, settle: 60);
      expect(m.posX, MotionControl.full);
      // While 20 degrees back toward level is the other end.
      r.turn(m, -40, samples: 40, settle: 60);
      expect(m.posX, -MotionControl.full);
    });

    test('rolls right with the phone and left the other way', () {
      final (m, r) = calibrated();
      r.turn(m, 30, settle: 60);
      expect(m.posX, MotionControl.full);
      expect(m.posY, 0);

      // The rig turns are relative: +30 then back through level to -30.
      r.turn(m, -60, samples: 30, settle: 60);
      expect(m.posX, -MotionControl.full);
      expect(m.posY, 0);
    });

    test('tips the player down when the phone tips the other way', () {
      final (m, r) = calibrated(rig: _Rig.pitch());
      // A rotation about +y moves the "pitch" angle negative, and the canvas
      // convention inverts that again: the player goes down. Both signs are
      // pinned here because the fusion has a sign of its own to get right.
      r.turn(m, 30, settle: 60);
      expect(m.posY, MotionControl.full);
      expect(m.posX, 0);

      r.turn(m, -60, samples: 30, settle: 60);
      expect(m.posY, -MotionControl.full);
      expect(m.posX, 0);
    });

    test('maps the angle proportionally between the middle and the end', () {
      final (m, r) = calibrated();

      r.turn(m, 3, settle: 60);
      final int three = m.posX;
      r.turn(m, 3, settle: 60);
      final int six = m.posX;
      r.turn(m, 4, settle: 60);
      final int ten = m.posX;
      r.turn(m, 5, settle: 60);
      final int fifteen = m.posX;

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
      final (m, r) = calibrated();
      r.turn(m, 45, settle: 60);
      expect(m.posX, MotionControl.full);
      r.turn(m, -25, samples: 25, settle: 60);
      expect(m.posX, MotionControl.full);
    });

    test('holds exactly zero inside the dead zone', () {
      final (m, r) = calibrated();
      r.turn(m, 0.5, settle: 60); // the dead zone is half a degree
      expect(m.posX, 0);

      // Just outside it the position moves, but only a little: a degree of
      // tilt is about 840 of the 32767, on a 20 degree travel.
      r.turn(m, 0.5, settle: 60);
      expect(m.posX, closeTo(840, 60));
      expect(m.posX, lessThan(MotionControl.full ~/ 10));
    });

    test('a held angle converges to a held position', () {
      final (m, r) = calibrated();
      r.turn(m, 15, settle: 100);
      final int settled = m.posX;
      for (var i = 0; i < 50; i++) {
        r.sample(m);
        expect(m.posX, settled,
            reason: 'the position drifted under a still phone');
      }
    });

    test('a quiet hold with sensor noise stays exactly centred', () {
      final (m, r) = calibrated();
      final noise = math.Random(7);
      for (var i = 0; i < 300; i++) {
        final List<double> a = r._accel;
        m.addAccelSample(
            a[0] + noise.nextDouble() * 0.1 - 0.05,
            a[1] + noise.nextDouble() * 0.1 - 0.05,
            a[2] + noise.nextDouble() * 0.1 - 0.05);
        m.addGyroSample(
            noise.nextDouble() * 0.01 - 0.005,
            noise.nextDouble() * 0.01 - 0.005,
            noise.nextDouble() * 0.01 - 0.005);
      }
      expect(m.posX, 0);
      expect(m.posY, 0);
    });

    test('never reports the idle value once neutral is established', () {
      final (m, r) = calibrated();
      for (var deg = -60; deg <= 60; deg += 10) {
        r.turn(m, deg.toDouble() - r.angle * 180 / math.pi, settle: 20);
        expect(m.posX, isNot(MotionControl.idle));
      }
    });

    // The defect this work exists for. A translation moves the accelerometer's
    // gravity reading and nothing else, and used to move the player with it.
    test('a translation while holding an angle moves nothing', () {
      final (m, r) = calibrated();
      r.turn(m, 10, settle: 60);
      final int held = m.posX;
      expect(held, closeTo(_posFor(10), 20));

      // 1.5 m/s² of hand movement along the axis that corrupts the roll: 8.7
      // degrees of apparent tilt. Through the accelerometer alone this report
      // would be posX 29991, a swing across 91% of the travel.
      r.linear = <double>[0, 1.5, 0];
      r.hold(m, 25);
      expect(m.posX, held,
          reason: 'the player moved with the hand, not the tilt');

      r.linear = <double>[0, 0, 0];
      r.hold(m, 25);
      expect(m.posX, held);
    });

    test('brisk and sustained translations move nothing', () {
      for (final double accel in <double>[1.5, 3.0]) {
        final (m, r) = calibrated();
        r.linear = <double>[0, accel, 0];
        r.hold(m, 50); // one second
        expect(m.posX, 0, reason: '$accel m/s² for a second moved the player');
        r.hold(m, 450); // and nine more
        expect(m.posX, 0, reason: '$accel m/s² sustained moved the player');
      }
    });

    test('a gentle translation is bounded by its own apparent tilt', () {
      // 0.3 m/s² is 1.75 degrees of apparent tilt: below the 2 degree edge the
      // accelerometer is fully believed, so this is the one case the fusion
      // cannot separate from gyro bias, and its limit is that apparent tilt.
      final (m, r) = calibrated();
      r.linear = <double>[0, 0.3, 0];
      r.hold(m, 300);
      expect(m.posX, closeTo(_posFor(1.75), 40));
      expect(m.posX, lessThan(_posFor(2.0) + 40));
    });

    test('a rotation is tracked, with the right sign, at either speed', () {
      for (final int samples in <int>[10, 3]) {
        final (m, r) = calibrated();
        r.turn(m, 10, samples: samples, settle: 150);
        expect(m.posX, closeTo(_posFor(10), 20),
            reason: 'a $samples-sample turn to 10 degrees');
      }
      // A 500 deg/s flick saturates the travel.
      final (fast, rf) = calibrated();
      rf.turn(fast, 30, samples: 3, settle: 100);
      expect(fast.posX, MotionControl.full);
    });

    test('a turn while the hand is accelerating still tracks', () {
      final (m, r) = calibrated();
      r.linear = <double>[0, 1.0, 0];
      r.turn(m, 10, settle: 150);
      expect(m.posX, closeTo(_posFor(10), 20));
    });

    test('gyro bias does not drift the player', () {
      final (m, r) = calibrated();
      // A bias is a rate with no rotation: the gyro reports 0.5 deg/s forever
      // while the phone sits still. It must not become a position. (The rig's
      // own turn cannot express this: it moves the accelerometer with the
      // gyro.) The accelerometer's correction is what removes it, and the
      // residual it settles at — 0.3 degrees — is inside the dead zone.
      const double bias = 0.5 * math.pi / 180;
      for (var i = 0; i < 500; i++) {
        m.addGyroSample(bias, 0, 0);
        final List<double> a = r._accel;
        m.addAccelSample(a[0], a[1], a[2]);
        expect(m.posX, 0, reason: 'bias turned into a position');
      }
    });

    test('without a gyroscope a brisk movement freezes and a turn still steers',
        () {
      final m = MotionControl();
      final r = _Rig.roll()..gyro = false;
      for (var i = 0; i < m.calibrationSamples; i++) {
        r.sample(m);
      }
      expect(m.gyroscopeAssisted, isFalse);

      // 4 m/s²: past the magnitude the fallback gate believes.
      r.linear = <double>[0, 4, 0];
      r.hold(m, 25);
      expect(m.posX, 0, reason: 'the fallback let a brisk movement through');
      r.linear = <double>[0, 0, 0];

      // A rotation is still tracked: without a gyro there is nothing to
      // predict with, and the gate must not mistake it for corruption.
      r.turn(m, 10, settle: 200);
      expect(m.posX, closeTo(_posFor(10), 60));
    });

    test('a gyro that talks nonsense cannot freeze the player forever', () {
      final (m, r) = calibrated();
      final int before = m.posX;
      // The accelerometer steps 10 degrees while the gyro keeps reporting no
      // rotation at all, with a magnitude that shows no acceleration: only the
      // gyro can be wrong here.
      r.angle = 10 * math.pi / 180;
      for (var i = 0; i < 300; i++) {
        r.sample(m);
      }
      expect(m.posX, greaterThan(before));
      expect(m.posX, closeTo(_posFor(10), 300));
    });

    test('an acceleration signature keeps the escape hatch shut', () {
      final (m, r) = calibrated();
      // The same unexplained step, but the magnitude says the hand is moving:
      // this is the case the fusion must refuse to follow.
      r.angle = 10 * math.pi / 180;
      r.linear = <double>[0, 3, 0];
      for (var i = 0; i < 300; i++) {
        r.sample(m);
      }
      expect(m.posX, 0);
    });

    test('timestamps that are absent, stale or backwards cannot break it', () {
      final (m, r) = calibrated();

      // No stamps at all.
      for (var i = 0; i < 30; i++) {
        final List<double> a = r._accel;
        m.addGyroSample(0, 0, 0);
        m.addAccelSample(a[0], a[1], a[2]);
      }
      expect(m.posX, 0);

      // Constant, duplicate, backwards, and a half-second gap.
      final DateTime t0 = DateTime.fromMicrosecondsSinceEpoch(1000000);
      for (var i = 0; i < 40; i++) {
        final List<double> a = r._accel;
        m.addGyroSample(0, 0, 0, stamp: t0);
        m.addAccelSample(a[0], a[1], a[2], stamp: t0);
      }
      expect(m.posX, 0);
      m.addGyroSample(0, 0, 0, stamp: t0.subtract(const Duration(seconds: 5)));
      m.addAccelSample(0, 0, _g,
          stamp: t0.subtract(const Duration(seconds: 5)));
      expect(m.posX, 0);
      final DateTime gap = t0.add(const Duration(milliseconds: 500));
      m.addGyroSample(0, 0, 0, stamp: gap);
      m.addAccelSample(0, 0, _g, stamp: gap);
      expect(m.posX, 0);
      expect(m.posY, 0);
    });

    test('neutral averages ordinary hand wobble rather than timing out', () {
      final m = MotionControl();
      final r = _Rig.roll(angle: 20 * math.pi / 180);
      for (var i = 0; i < 20; i++) {
        // A small wrist oscillation plus half a m/s² of hand acceleration.
        r.linear = <double>[0, 0, i.isEven ? 0.5 : -0.5];
        r.sample(m, rate: i < 5 || i >= 15 ? 0.4 : -0.4);
      }
      expect(m.calibrated, isTrue);
      r.linear = <double>[0, 0, 0];
      r.hold(m);
      expect(m.posX.abs(), lessThan(_posFor(1)));
      expect(m.posY, 0);
    });

    test('a changed grip replaces the old partial neutral hold', () {
      final m = MotionControl();
      final r = _Rig.roll();
      r.hold(m, 8);
      r.turn(m, 25, samples: 10);
      expect(m.calibrated, isFalse);
      r.hold(m, 20);
      expect(m.calibrated, isTrue);
      r.hold(m);
      expect(m.posX, 0);
      expect(m.posY, 0);
    });

    test('a stale rotating gyro cannot block neutral calibration', () {
      final m = MotionControl();
      final stamp = DateTime.fromMillisecondsSinceEpoch(0);
      m.addGyroSample(2, 0, 0, stamp: stamp);
      for (var i = 0; i < 20; i++) {
        m.addAccelSample(0, 0, _g,
            stamp: stamp.add(Duration(milliseconds: 300 + i * 20)));
      }
      expect(m.calibrated, isTrue);
      expect(m.posX, 0);
    });

    test('a hold that never stops moving never establishes neutral', () {
      final m = MotionControl();
      final r = _Rig.roll();
      for (var i = 0; i < 200; i++) {
        // Always being shaken: the direction never agrees for long.
        r.linear = <double>[0, 3.0 * (i.isEven ? 1 : -1), 0];
        r.sample(m);
      }
      expect(m.calibrated, isFalse);
      expect(m.posX, MotionControl.idle);
    });

    test('gyro samples before neutral do not move the estimate', () {
      final m = MotionControl();
      final r = _Rig.roll();
      // A rate with no matching rotation: nothing but liveness may come of it.
      for (var i = 0; i < m.calibrationSamples; i++) {
        m.addGyroSample(3, 0, 0);
        final List<double> a = r._accel;
        m.addAccelSample(a[0], a[1], a[2]);
      }
      // Every sample was rejected as "at rest" only because the rate test saw
      // it: the phone was rotating, so neutral is not established yet.
      expect(m.calibrated, isFalse);
      for (var i = 0; i < m.calibrationSamples; i++) {
        r.sample(m);
      }
      expect(m.calibrated, isTrue);
      r.hold(m, 60);
      expect(m.posX, 0);
    });

    test('a device with no gyroscope reports itself as unassisted', () {
      final (m, r) = calibrated();
      expect(m.gyroscopeAssisted, isTrue);
      m.gyroscopeUnavailable();
      expect(m.gyroscopeAssisted, isFalse);
      // Late samples from a stream that declared itself unavailable are
      // ignored rather than half-used.
      final int held = m.posX;
      r.hold(m, 5);
      for (var i = 0; i < 20; i++) {
        m.addGyroSample(1.5, 0, 0);
      }
      expect(m.posX, held);
    });
  });
}
