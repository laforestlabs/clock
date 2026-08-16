import 'dart:math' as math;

/// Maps phone accelerometer tilt to held direction buttons.
///
/// Calibrates a neutral baseline from the first [calibrationSamples] samples
/// (the player holds the phone still for ~0.4s after starting), then reports
/// which of Up/Down/Left/Right are held beyond [deadZone].
class MotionControl {
  MotionControl({this.calibrationSamples = 20, this.deadZone = 0.1745});

  final int calibrationSamples; // 20
  final double deadZone; // radians, 0.1745 ~ 10 degrees

  int _n = 0;
  double _sx = 0, _sy = 0, _sz = 0;
  double _baseLeftRight = 0, _baseUpDown = 0;
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
    _right = lr > deadZone;
    _left = lr < -deadZone;
    _up = ud > deadZone;
    _down = ud < -deadZone;
  }

  static double _angle(double a, double b, double c) =>
      math.atan2(a, math.sqrt(b * b + c * c));
}
