import 'dart:math' as math;

/// Maps the phone's orientation to an absolute position in a game's travel,
/// with the gyroscope and the accelerometer fused.
///
/// The angle the phone is held at *is* the player's position. Neutral — the
/// angle established at calibration, with the phone held still — is the middle
/// of the travel, [travel] radians to either side is one end of it, and the
/// mapping between is linear:
///
/// ```
///   -20 deg  ->  -32767   (one end)
///    -10 deg  ->  -16000   (a little under half)
///      0 deg  ->       0   (the middle)
///    +15 deg  ->  +24400   (three quarters of the way)
///    +20 deg  ->  +32767   (the other end)
/// ```
///
/// So a held angle is a held position: the player moves only while the phone
/// is moving, and nothing drifts or springs back while it is still.
///
/// [deadZone] radians either side of neutral reports exactly zero, so a hand
/// resting on the phone cannot shiver the player by a pixel. Inside the dead
/// zone the mapping is flat; outside it, everything from the edge of the dead
/// zone out to [travel] is used, so no part of the travel is unreachable. The
/// angle is low-pass filtered with [smoothing] first, which costs about 80 ms
/// of settling on a step change and removes hand jitter.
///
/// ## Why two sensors
///
/// The accelerometer alone cannot answer "which way is up" while the phone is
/// being moved: it measures gravity *plus* the hand's acceleration, and a hand
/// movement of 1.5 m/s² tilts that vector by 8.7° — most of the travel — while
/// the phone's angle has not changed at all. The gyroscope alone cannot answer
/// it either, because it measures rotation *rate* and any error in it
/// accumulates.
///
/// So this mapper carries one estimate of the gravity direction and fuses the
/// two:
///
/// - every [addGyroSample] **predicts** — it rotates the estimate by the
///   measured rate, which is immune to translation and therefore carries the
///   estimate through a movement;
/// - every [addAccelSample] **corrects** — it pulls the estimate toward the
///   measured direction, which is absolute and therefore removes the gyro's
///   slow drift, *when the accelerometer can be believed*.
///
/// Whether it can be believed is the whole design. The correction is weighted
/// by how far the measured direction sits from the estimate the gyro just
/// predicted: full trust inside [trustAngle], none past [trustReject]. A
/// trustworthy accelerometer keeps that disagreement near zero (a gyro bias of
/// 0.5°/s settles at 0.3°), so a disagreement of degrees means the
/// accelerometer is the sensor that is wrong — which is exactly what a hand
/// movement makes it. A sustained disagreement is not allowed to freeze the
/// estimate forever: past [escapeAfter] seconds of it, and only when the
/// measured *magnitude* shows no linear acceleration to explain the
/// disagreement, a small [escapeTrust] lets it recover, so a gyro that reports
/// nonsense cannot leave the player stuck at the wrong position.
///
/// With no gyroscope ([gyroscopeUnavailable], or no sample for
/// [gyroStaleAfter]) there is nothing to predict with, so a real rotation would
/// look exactly like corruption and the innovation test above would freeze the
/// player instead of steering them. The fallback trusts on magnitude alone:
/// inside [fallbackTolerance] of the calibrated magnitude, and never past
/// [fallbackReject]. That catches a brisk movement and does nothing about a
/// slow one — which is why the app says which estimator is running.
class MotionControl {
  MotionControl({
    this.calibrationSamples = 20,
    this.travel = _defaultTravel,
    this.deadZone = _defaultDeadZone,
    this.smoothing = 0.4,
    this.correctionSeconds = 0.6,
    this.fallbackCorrectionSeconds = 0.08,
    this.trustAngle = _defaultTrustAngle,
    this.trustReject = _defaultTrustReject,
    this.fallbackTolerance = 0.15,
    this.fallbackReject = 0.6,
    this.gyroStaleAfter = const Duration(milliseconds: 200),
    this.escapeAfter = const Duration(seconds: 1),
    this.escapeTolerance = 0.02,
    this.escapeTrust = 0.25,
    this.restRate = 0.15,
    this.restTolerance = 0.3,
    this.nominalStep = const Duration(milliseconds: 20),
  }) : assert(deadZone >= 0 && deadZone < travel),
       assert(smoothing > 0 && smoothing <= 1),
       assert(trustReject > trustAngle && trustAngle >= 0),
       assert(fallbackReject > fallbackTolerance && fallbackTolerance >= 0),
       assert(correctionSeconds > 0),
       assert(fallbackCorrectionSeconds > 0),
       assert(nominalStep > Duration.zero),
       assert(escapeTrust >= 0 && escapeTrust < 1);

  /// The wire value for an axis nobody is driving, matching `ML_AXIS_IDLE` in
  /// `gamekit/include/mirror/game.h`: the game holds its position.
  static const int idle = -32768;

  /// The value at either end of the travel.
  static const int full = 32767;

  /// 20 degrees: tilting the phone this far from the angle it was calibrated
  /// at puts the player at the end of its travel. Small enough to steer with a
  /// wrist rather than an arm, which is what 30 degrees turned out to cost.
  static const double _defaultTravel = 20 * math.pi / 180;

  /// Half a degree either side of neutral reports zero. An absolute angle, not
  /// a share of the travel, so tightening or loosening [travel] leaves the
  /// rest position exactly as steady as it was.
  static const double _defaultDeadZone = 0.5 * math.pi / 180;

  /// One degree of disagreement between the accelerometer and what the gyro
  /// just predicted is where the accelerometer stops being fully believed. A
  /// gyro bias of 0.5°/s settles inside this, so the correction that removes it
  /// keeps running; a hand movement of only 0.9 m/s² already reaches the edge.
  static const double _defaultTrustAngle = 1 * math.pi / 180;

  /// Five degrees of it and it is not believed at all: 5° is what a 0.86 m/s²
  /// hand movement looks like, and no hand movement may move the player.
  static const double _defaultTrustReject = 5 * math.pi / 180;

  /// The Earth's gravity, as the accelerometer should read it on a still phone.
  static const double _gravityEarth = 9.80665;

  /// Samples accepted at rest to establish neutral. The player holds the phone
  /// still for a moment, and that hold becomes the middle of the travel.
  final int calibrationSamples;

  /// Radians of tilt from neutral that saturate the travel.
  final double travel;

  /// Radians either side of neutral that report exactly zero.
  final double deadZone;

  /// EMA coefficient applied to the tilt angle, in (0, 1].
  final double smoothing;

  /// Time constant of the accelerometer's authority over the estimate. The
  /// gyro's own error is removed at this rate, so it must be slow enough to
  /// average sensor noise away and fast enough to beat the gyro's bias.
  final double correctionSeconds;

  /// The same thing without a gyroscope, and deliberately far shorter. With a
  /// gyro in the loop the accelerometer is only a slow reference — the gyro
  /// carries the movement, so a long time constant costs nothing. Without one,
  /// the accelerometer *is* the movement: the long constant would lag every
  /// tilt, so the fallback tracks it directly and lets the magnitude gate do
  /// the rejecting.
  final double fallbackCorrectionSeconds;

  /// Radians of disagreement trusted completely.
  final double trustAngle;

  /// Radians of disagreement not trusted at all.
  final double trustReject;

  /// m/s² of magnitude deviation trusted completely without a gyroscope.
  final double fallbackTolerance;

  /// m/s² of magnitude deviation not trusted at all without a gyroscope.
  final double fallbackReject;

  /// How long the estimate may go without a gyroscope sample before the
  /// fallback gate takes over.
  final Duration gyroStaleAfter;

  /// How long a complete disagreement may last before [escapeTrust] lets the
  /// estimate recover.
  final Duration escapeAfter;

  /// m/s² of magnitude deviation that still counts as "no linear acceleration
  /// is happening" for that recovery. Deliberately far tighter than
  /// [fallbackTolerance], because a movement perpendicular to gravity moves the
  /// *magnitude* only as `a² / 2g` — 1.5 m/s² is 0.11 m/s² — so a hatch gated on
  /// the fallback tolerance stays open for exactly the movement it exists to
  /// refuse, and a sustained hand movement creeps the player away again.
  final double escapeTolerance;

  /// The trust used by that recovery, in [0, 1).
  final double escapeTrust;

  /// rad/s: the most the phone may be rotating for a calibration sample —
  /// or the round's own accelerometer samples — to be treated as at rest.
  final double restRate;

  /// m/s²: how far the magnitude may sit from Earth's gravity for a
  /// calibration sample to be treated as at rest.
  final double restTolerance;

  /// The step used when a sample carries no usable timestamp.
  final Duration nominalStep;

  // Calibration: the accepted samples' unit directions, their magnitudes, and
  // how many there are.
  int _accepted = 0;
  double _sumX = 0, _sumY = 0, _sumZ = 0, _sumMag = 0;
  double _baseRoll = 0, _basePitch = 0;

  // The estimate: a unit vector in the device frame, pointing the way the
  // accelerometer reads gravity on a still phone, plus the filtered angles
  // derived from it.
  double _gx = 0, _gy = 0, _gz = 1;
  double _roll = 0, _pitch = 0;
  bool _calibrated = false;

  /// The magnitude the accelerometer reads at rest, from the calibration hold.
  /// The device's own offset and scale are in here, which is why the fallback
  /// gate compares against this rather than against Earth's gravity.
  double _m0 = _gravityEarth;

  /// Seconds of continuous disagreement, for the escape hatch (see the class
  /// comment).
  double _gated = 0;

  // Sensor liveness. `_gyroLive` is set by each gyro sample and cleared when an
  // accelerometer sample arrives more than [gyroStaleAfter] after the last one,
  // so a stream that stops mid-round degrades the same way an absent sensor
  // does. Stamps are what detect that; without them a gyro sample counts as
  // live.
  bool _gyroSeen = false;
  bool _gyroLive = false;
  bool _gyroUnavailable = false;
  double _gyroRate = 0;
  DateTime? _gyroStamp;

  /// The stamp of the previous accelerometer sample, and of the previous
  /// gyroscope sample.
  DateTime? _lastAccelStamp;
  DateTime? _lastGyroStamp;
  late final double _nominalSeconds = nominalStep.inMicroseconds / 1e6;
  late final int _staleMicros = gyroStaleAfter.inMicroseconds;
  late final double _escapeSeconds = escapeAfter.inMicroseconds / 1e6;
  late final double _dTolerate = 1 - math.cos(trustAngle);
  late final double _dReject = 1 - math.cos(trustReject);

  /// Whether neutral has been established. Until it has, there is no angle to
  /// report and both axes are [idle].
  bool get calibrated => _calibrated;

  /// How many samples have been accepted toward [calibrationSamples]. Samples
  /// taken while the phone is being moved are not accepted, so this is what the
  /// "hold still" view shows the player.
  int get calibrationProgress => _calibrated ? calibrationSamples : _accepted;

  /// Whether the gyroscope is feeding the estimate. False without one, and
  /// false once one has reported itself unavailable.
  bool get gyroscopeAssisted => _gyroSeen && !_gyroUnavailable;

  /// Position on the horizontal axis, in canvas terms: positive moves the
  /// player right, negative left. [idle] before calibration.
  int get posX => _calibrated ? _position(_roll) : idle;

  /// Position on the vertical axis, in canvas terms: positive moves the player
  /// down, negative up. [idle] before calibration.
  int get posY => _calibrated ? -_position(_pitch) : idle;

  /// One accelerometer sample (x, y, z in m/s², gravity included).
  ///
  /// Before calibration it is a candidate for the neutral hold; after it, it
  /// corrects the estimate unless the fusion says it cannot be believed.
  void addAccelSample(double x, double y, double z, {DateTime? stamp}) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) return;
    final double dt = _step(stamp, _lastAccelStamp);
    _lastAccelStamp = stamp;
    final double mag = math.sqrt(x * x + y * y + z * z);
    if (mag < 1e-3) return;
    if (!_calibrated) {
      _acceptForNeutral(x, y, z, mag);
      return;
    }
    // A gyro that has gone quiet is no gyro: nothing can predict with it, so
    // the fallback gate takes over rather than the innovation gate freezing
    // every rotation.
    if (_gyroLive &&
        _gyroStamp != null &&
        stamp != null &&
        stamp.difference(_gyroStamp!).inMicroseconds > _staleMicros) {
      _gyroLive = false;
    }
    final double ax = x / mag, ay = y / mag, az = z / mag;
    final bool assisted = _gyroLive;
    final double trust = _trust(ax, ay, az, mag, dt);
    if (trust > 0) {
      final double tau =
          assisted ? correctionSeconds : fallbackCorrectionSeconds;
      final double a = dt / tau * trust;
      final double nx = _gx + a * (ax - _gx);
      final double ny = _gy + a * (ay - _gy);
      final double nz = _gz + a * (az - _gz);
      final double norm = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (norm < 1e-9) return;
      _gx = nx / norm;
      _gy = ny / norm;
      _gz = nz / norm;
    }
    // The filter runs on every sample, gated or not: a refused sample means the
    // estimate holds, and a held estimate is a filter input that must still be
    // allowed to settle onto it. Skipping this left the position short after a
    // gated movement — mid-convergence and stuck there.
    _updateAngles();
  }

  /// One gyroscope sample (x, y, z in rad/s, in the device frame the
  /// accelerometer uses).
  void addGyroSample(double x, double y, double z, {DateTime? stamp}) {
    if (_gyroUnavailable) return;
    if (!x.isFinite || !y.isFinite || !z.isFinite) return;
    final double dt = _step(stamp, _lastGyroStamp);
    _lastGyroStamp = stamp;
    _gyroSeen = true;
    _gyroLive = true;
    _gyroStamp = stamp;
    _gyroRate = math.sqrt(x * x + y * y + z * z);
    if (!_calibrated) return; // it still counts as liveness and as "at rest".
    final double theta = _gyroRate * dt;
    if (theta < 1e-6) return;
    final double ux = x / _gyroRate, uy = y / _gyroRate, uz = z / _gyroRate;
    // Rotating the phone by w moves the device-frame gravity estimate by
    // -w x gv: a fixed world direction, seen from a frame that turned.
    final double cx = uy * _gz - uz * _gy;
    final double cy = uz * _gx - ux * _gz;
    final double cz = ux * _gy - uy * _gx;
    final double dot = ux * _gx + uy * _gy + uz * _gz;
    final double c = math.cos(theta), s = math.sin(theta);
    final double keep = dot * (1 - c);
    final double nx = _gx * c - cx * s + ux * keep;
    final double ny = _gy * c - cy * s + uy * keep;
    final double nz = _gz * c - cz * s + uz * keep;
    final double norm = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (norm < 1e-9) return;
    _gx = nx / norm;
    _gy = ny / norm;
    _gz = nz / norm;
    _updateAngles();
  }

  /// The gyroscope reported `NO_SENSOR`: this device has none. The estimate
  /// falls back to the accelerometer alone and no gyro sample is used again.
  void gyroscopeUnavailable() {
    _gyroUnavailable = true;
    _gyroLive = false;
  }

  /// The step since the previous sample of *this* stream, or the nominal
  /// period when there is nothing usable to measure — each sensor's authority
  /// has to come from its own sampling interval, or the correction's time
  /// constant would quietly depend on how the two streams interleave. Clamped,
  /// because batching can deliver events that share a stamp and a queued event
  /// can arrive late.
  double _step(DateTime? stamp, DateTime? previous) {
    if (stamp == null || previous == null) return _nominalSeconds;
    final double dt = stamp.difference(previous).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 0.1) return _nominalSeconds;
    return dt;
  }

  /// How much the accelerometer is believed this sample, in [0, 1]; also
  /// advances the escape hatch. See the class comment for why either gate is
  /// the one it is.
  double _trust(double ax, double ay, double az, double mag, double dt) {
    if (_gyroLive) {
      final double d = 1 - (ax * _gx + ay * _gy + az * _gz);
      final double ramp = (_dReject - d) / (_dReject - _dTolerate);
      if (ramp > 0) {
        _gated = 0;
        return ramp < 1 ? ramp : 1;
      }
      _gated += dt;
      // A disagreement this large that the gyro cannot explain is either the
      // hand accelerating the phone (the magnitude moved with it) or a gyro
      // that is talking nonsense. Only the second may be recovered from, and
      // only a magnitude that is at rest answers the question.
      if (_gated >= _escapeSeconds &&
          (mag - _m0).abs() <= escapeTolerance) {
        return escapeTrust;
      }
      return 0;
    }
    final double deviation = (mag - _m0).abs();
    final double ramp =
        (fallbackReject - deviation) / (fallbackReject - fallbackTolerance);
    return ramp.clamp(0.0, 1.0);
  }

  /// Take one sample into the neutral hold, if the phone is at rest by all
  /// three tests: gravity magnitude, no rotation, and a direction that agrees
  /// with the samples already taken. The third one is what a translation
  /// during the hold fails — a movement changes the direction and nothing
  /// else.
  void _acceptForNeutral(double x, double y, double z, double mag) {
    if ((mag - _gravityEarth).abs() > restTolerance) return;
    if (_gyroSeen && _gyroRate > restRate) return;
    final double ax = x / mag, ay = y / mag, az = z / mag;
    if (_accepted > 0) {
      final double norm = math.sqrt(_sumX * _sumX + _sumY * _sumY + _sumZ * _sumZ);
      if (norm < 1e-9) return;
      final double d =
          1 - (ax * _sumX + ay * _sumY + az * _sumZ) / norm;
      if (d > _dTolerate) return;
    }
    _sumX += ax;
    _sumY += ay;
    _sumZ += az;
    _sumMag += mag;
    _accepted++;
    if (_accepted < calibrationSamples) return;
    final double norm = math.sqrt(_sumX * _sumX + _sumY * _sumY + _sumZ * _sumZ);
    if (norm < 1e-9) return; // degenerate hold: neutral stays unestablished.
    _gx = _sumX / norm;
    _gy = _sumY / norm;
    _gz = _sumZ / norm;
    _m0 = _sumMag / _accepted;
    _baseRoll = _angle(_gy, _gx, _gz);
    _basePitch = _angle(_gx, _gy, _gz);
    _roll = 0;
    _pitch = 0;
    _calibrated = true;
  }

  /// The two angle offsets from neutral, low-pass filtered. The estimate is
  /// already smoothed by the fusion; this is what keeps a resting hand from
  /// shivering the player.
  void _updateAngles() {
    final double roll = _angle(_gy, _gx, _gz) - _baseRoll;
    final double pitch = _angle(_gx, _gy, _gz) - _basePitch;
    _roll = smoothing * roll + (1 - smoothing) * _roll;
    _pitch = smoothing * pitch + (1 - smoothing) * _pitch;
  }

  /// One filtered tilt offset, as a position in the travel. Zero inside the
  /// dead zone, linear from its edge out to [travel], saturated past it.
  int _position(double radians) {
    final double magnitude = radians.abs();
    if (magnitude <= deadZone) return 0;
    final double scaled = (magnitude - deadZone) / (travel - deadZone);
    final double clamped = scaled > 1.0 ? 1.0 : scaled;
    final int value = (clamped * full).round();
    return radians < 0 ? -value : value;
  }

  static double _angle(double a, double b, double c) =>
      math.atan2(a, math.sqrt(b * b + c * c));
}
