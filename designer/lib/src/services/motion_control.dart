import 'dart:math' as math;

/// Maps phone accelerometer tilt to held direction buttons.
///
/// Calibrates a neutral baseline from the first [calibrationSamples] samples
/// (the player holds the phone still for ~0.4s after starting), then reports
/// which of Up/Down/Left/Right are held.
///
/// The tilt angles are low-pass filtered with [smoothing] to remove hand
/// jitter, and each direction uses hysteresis: it turns on only past
/// [engageZone] and stays on until the tilt falls back inside [releaseZone].
/// At the 20 ms sampling rate the screen subscribes with, this reads as a
/// stable, responsive tilt without flickering at the boundary.
class MotionControl {
  MotionControl({
    this.calibrationSamples = 20,
    this.engageZone = 0.1745, // radians, ~10 degrees
    this.releaseZone = 0.0873, // radians, ~5 degrees
    this.smoothing = 0.4,
  });

  final int calibrationSamples; // 20
  final double engageZone; // radians, ~10 degrees
  final double releaseZone; // radians, ~5 degrees, must be < engageZone
  final double smoothing; // EMA coefficient in (0, 1]

  int _n = 0;
  double _sx = 0, _sy = 0, _sz = 0;
  double _baseLeftRight = 0, _baseUpDown = 0;
  double _lr = 0, _ud = 0; // filtered tilt offsets
  bool _calibrated = false;

  bool _up = false, _down = false, _left = false, _right = false;

  bool get calibrated => _calibrated;
  bool get up => _up;
  bool get down => _down;
  bool get left => _left;
  bool get right => _right;

  /// One accelerometer sample (x, y, z in m/s², gravity included).
  void addSample(double x, double y, double z) {
    if (!_calibrated) {
      _sx += x;
      _sy += y;
      _sz += z;
      _n++;
      if (_n < calibrationSamples) return;
      final bx = _sx / _n, by = _sy / _n, bz = _sz / _n;
      _baseLeftRight = _angle(by, bx, bz); // roll  about short edge
      _baseUpDown = _angle(bx, by, bz); // pitch about long edge
      _calibrated = true;
      return;
    }
    final lr = _angle(y, x, z) - _baseLeftRight;
    final ud = _angle(x, y, z) - _baseUpDown;
    _lr = smoothing * lr + (1 - smoothing) * _lr;
    _ud = smoothing * ud + (1 - smoothing) * _ud;
    _right = _dir(_lr, _right);
    _left = _dir(-_lr, _left);
    _up = _dir(_ud, _up);
    _down = _dir(-_ud, _down);
  }

  /// Hysteresis for one signed axis value. A direction engages only past
  /// [engageZone] and, once engaged, releases only below [releaseZone].
  bool _dir(double value, bool held) =>
      held ? value > releaseZone : value > engageZone;

  static double _angle(double a, double b, double c) =>
      math.atan2(a, math.sqrt(b * b + c * c));
}
