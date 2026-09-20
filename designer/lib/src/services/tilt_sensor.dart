// Whether this device's accelerometer actually reports.
//
// A round steered by tilt cannot start without a working sensor, and the one
// thing worse than refusing to start is asking the player to hold the phone
// still first: the calibration that needs those samples is not what discovers
// that there is no sensor, so the ask has to come after the proof. This probe
// is that proof - subscribe, take the first sample as evidence, and read a
// stream error or a deadline with no sample at all as "this device has no
// tilt".
//
// One instance belongs to one Games screen, and answers once: whether the
// accelerometer reports is a fact about the device, not about the round, so a
// second round, a resume, or a recalibrate pays nothing for it. It is
// deliberately not a process global. A sensor that a driver reload or a reboot
// brings back must not stay written off, and one test's device must never be
// the next test's.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// How long a subscription that never delivers anything is given before the
/// device is written off. A phone with an accelerometer delivers a sample in
/// about 20 ms; a platform whose plugin is missing fails the subscription
/// outright, well inside this.
const Duration kTiltProbeDeadline = Duration(milliseconds: 1500);

/// Whether this platform can have the plugin at all. `sensors_plus` registers
/// on Android and iOS; anywhere else - the desktop builds the designer also
/// runs on - subscribing raises a `MissingPluginException` that the services
/// layer reports, so the answer is known without asking.
bool _platformHasSensors() =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// One question about this device's accelerometer, asked once.
class TiltSensor {
  /// How long a silent subscription is given.
  static const Duration deadline = kTiltProbeDeadline;

  /// Whether the platform is one the plugin runs on, for the widget tests that
  /// register its channels themselves on a host the plugin does not support.
  @visibleForTesting
  static bool? debugPlatformSupported;

  Future<bool>? _answer;
  Completer<bool>? _pending;
  StreamSubscription<AccelerometerEvent>? _sub;
  Timer? _timer;
  bool? _status;

  /// Whether the accelerometer reports, or null while the question is still
  /// open. The UI reads this to explain why tilt is not on offer, so it is
  /// only ever set by an answer - never by a guess.
  bool? get status => _status;

  /// Whether the accelerometer reports. Callers share the one probe, so the
  /// sensor is asked however many rounds are started.
  Future<bool> present() => _answer ??= _ask();

  /// Stop asking. A probe still in flight ends as "no sensor": the screen that
  /// asked is going away, and nothing may be left awaiting an answer that will
  /// never come.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel() ?? Future<void>.value());
    _settle(false);
  }

  Future<bool> _ask() {
    final pending = _pending = Completer<bool>();
    // A platform the plugin does not run on has no sensor to find: the
    // question is answered without a subscription that would only raise.
    if (!(debugPlatformSupported ?? _platformHasSensors())) {
      _settle(false);
      return pending.future;
    }
    _timer = Timer(deadline, () => _settle(false));
    try {
      _sub = accelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen((_) => _settle(true), onError: (Object _) => _settle(false));
    } catch (_) {
      // A platform with no sensor implementation can fail the subscription
      // itself rather than the stream, and that is an answer too.
      _settle(false);
    }
    return pending.future;
  }

  /// Record the answer, if there is not one already, and let go of the sensor:
  /// the probe is over either way, and a sample arriving after it has been
  /// answered belongs to the round's own subscription, not to this one.
  void _settle(bool present) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    _timer?.cancel();
    _timer = null;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel() ?? Future<void>.value());
    _status = present;
    pending.complete(present);
  }
}
