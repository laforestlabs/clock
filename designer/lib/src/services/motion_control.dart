import 'dart:math' as math;

/// Maps the phone's accelerometer to an absolute position in a game's travel.
///
/// The angle the phone is held at *is* the player's position. Neutral — the
/// angle established at calibration, with the phone held still — is the middle
/// of the travel, [travel] radians to either side is one end of it, and the
/// mapping between is linear:
///
/// ```
///   -30 deg  ->  -32767   (one end)
///      0 deg  ->       0   (the middle)
///   +15 deg  ->  +16383   (three quarters of the way)
///   +30 deg  ->  +32767   (the other end)
/// ```
///
/// So a held angle is a held position: the player moves only while the phone
/// is moving, and nothing drifts or springs back while it is still. That is
/// the whole point of this mapper — the games it steers are positional, and a
/// position that kept changing under a still phone would be unusable.
///
/// A dead zone of [deadZone] of the travel around neutral reports exactly
/// zero, so a hand resting on the phone cannot shiver the player by a pixel.
/// Inside the dead zone the mapping is flat; outside it, everything from the
/// edge of the dead zone to [travel] is used, so no part of the travel is
/// unreachable. The angle is low-pass filtered with [smoothing] first, which
/// costs about 80 ms of settling on a step change and removes hand jitter.
class MotionControl {
  MotionControl({
    this.calibrationSamples = 20,
    this.travel = _defaultTravel,
    this.deadZone = 0.05,
    this.smoothing = 0.4,
  }) : assert(deadZone >= 0 && deadZone < 1),
       assert(smoothing > 0 && smoothing <= 1);

  /// The wire value for an axis nobody is driving, matching `ML_AXIS_IDLE` in
  /// `gamekit/include/mirror/game.h`: the game holds its position.
  static const int idle = -32768;

  /// The value at either end of the travel.
  static const int full = 32767;

  /// 30 degrees: tilting the phone this far from the angle it was calibrated
  /// at puts the player at the end of its travel.
  static const double _defaultTravel = 30 * math.pi / 180;

  /// Samples averaged to establish neutral: the player holds the phone still
  /// for a moment, and that hold becomes the middle of the travel.
  final int calibrationSamples;

  /// Radians of tilt from neutral that saturate the travel.
  final double travel;

  /// Fraction of [travel] either side of neutral that reports exactly zero.
  final double deadZone;

  /// EMA coefficient applied to the tilt angle, in (0, 1].
  final double smoothing;

  int _n = 0;
  double _sx = 0, _sy = 0, _sz = 0;
  double _baseRoll = 0, _basePitch = 0;
  double _roll = 0, _pitch = 0; // filtered tilt offsets, radians
  bool _calibrated = false;

  /// Whether neutral has been established. Until it has, there is no angle to
  /// report and both axes are [idle].
  bool get calibrated => _calibrated;

  /// Position on the horizontal axis, in canvas terms: positive moves the
  /// player right, negative left. [idle] before calibration.
  int get posX => _calibrated ? _position(_roll) : idle;

  /// Position on the vertical axis, in canvas terms: positive moves the player
  /// down, negative up. [idle] before calibration.
  int get posY => _calibrated ? -_position(_pitch) : idle;

  /// One accelerometer sample (x, y, z in m/s², gravity included).
  void addSample(double x, double y, double z) {
    if (!_calibrated) {
      _sx += x;
      _sy += y;
      _sz += z;
      _n++;
      if (_n < calibrationSamples) return;
      final bx = _sx / _n, by = _sy / _n, bz = _sz / _n;
      _baseRoll = _angle(by, bx, bz); // roll, about the short edge
      _basePitch = _angle(bx, by, bz); // pitch, about the long edge
      _calibrated = true;
      return;
    }
    final roll = _angle(y, x, z) - _baseRoll;
    final pitch = _angle(x, y, z) - _basePitch;
    _roll = smoothing * roll + (1 - smoothing) * _roll;
    _pitch = smoothing * pitch + (1 - smoothing) * _pitch;
  }

  /// One filtered tilt offset, as a position in the travel. Zero inside the
  /// dead zone, linear from its edge out to [travel], saturated past it.
  int _position(double radians) {
    final double zone = deadZone * travel;
    final double magnitude = radians.abs();
    if (magnitude <= zone) return 0;
    final double scaled = (magnitude - zone) / (travel - zone);
    final double clamped = scaled > 1.0 ? 1.0 : scaled;
    final int value = (clamped * full).round();
    return radians < 0 ? -value : value;
  }

  static double _angle(double a, double b, double c) =>
      math.atan2(a, math.sqrt(b * b + c * c));
}
