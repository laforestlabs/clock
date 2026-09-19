# Plan: gyro-assisted tilt — isolating tilt from the phone's own motion

**Status: implemented 2026-09-18**, in `designer/lib/src/services/motion_control.dart`,
`designer/lib/src/ui/game_screen.dart`, and the two test files named below. The
code and its tests are the truth; this document is the reasoning behind them, and
"Why implementing this plan changed" below records the four places the plan was
wrong. Section "What already exists" describes the tree *before* the change.

Audience: the agent implementing this. Read the whole document before editing. It
records what already exists (do not rebuild), the contracts to add, the exact
files and call sites, and how to verify — in pure Dart and on the device.

This plan replaces the **sensor source** described in Phase 4 of
`docs/motion_control_plan.md`. Everything else in that plan — the positional
axis contract, `ML_AXIS_IDLE`, the six games, the wire — still stands and is
*not touched* by this work: nothing here changes the firmware, `gamekit`, or a
single byte on the wire.

## Goal

The reported defect: **moving the phone without changing its angle moves the
player.** That is not a bug in the mapping, it is the accelerometer being asked
a question it cannot answer.

The accelerometer measures *specific force* — gravity **plus** the phone's own
linear acceleration — and roll/pitch are read from that one vector
(`motion_control.dart:100-103`, `_angle` at 117-118). The apparent tilt error is
`atan(a_lin / g)`:

| hand movement | linear accel | apparent tilt error |
|---|---|---|
| slow drift | 0.5 m/s² | 2.9° (15% of the travel) |
| normal move | 1.5 m/s² | 8.7° (44% of the travel) |
| brisk move | 3 m/s² | 17° (85% of the travel) |

Rotation corrupts the same reading from the other side: the phone is held off
the wrist's pivot, so a fast flick adds centripetal and tangential acceleration
(0.3 m from the pivot at 3 rad/s ≈ 2.7 m/s², i.e. 15° of apparent tilt) exactly
while the player is steering.

The gyroscope is the sensor that separates the two: it measures *rate of
rotation* and is blind to linear acceleration, but it only ever gives a
derivative, so on its own it drifts. The two together are enough:

- **gyro** — high-frequency truth about rotation, immune to translation;
- **accelerometer** — absolute truth about gravity, but only trustworthy while
  the phone is not being accelerated by the hand.

Intended outcome: the tilt a game receives is a function of the phone's
**orientation alone**. Two consequences the player will feel:

1. A translation during a round stops moving the player: nothing at all for any
   movement a hand actually makes (measured: ≥1.4 m/s² is rejected outright),
   because the gyro carries the estimate while the accelerometer is disbelieved.
   What a *gentle sustained* movement can still do is stated exactly, with
   numbers, in D3 — this plan claims what it measures, not more.
2. Steering gets *more* responsive, not less: a wrist flick is tracked by the
   gyro at the sample rate instead of waiting for the accelerometer's gravity
   direction to settle.

Also in scope, because it is the same defect at a different moment:
**calibration latches whatever the accelerometer said during the hold.** The 20
samples are averaged (`motion_control.dart:88-99`), so a hold taken while the
phone was moving bakes that error into the neutral for the whole round, and
there is no way for the player to see it. Neutral is established only from
samples taken while the phone is at rest.

## What already exists (do not rebuild)

### The mapper — `designer/lib/src/services/motion_control.dart`

- Pure Dart, no Flutter or plugin imports (its header comment says why). Keep it
  that way: this plan's whole verification story depends on being able to drive
  it from synthetic samples.
- Public surface: `MotionControl({calibrationSamples, travel, deadZone,
  smoothing})`, `static const int idle = -32768`, `static const int full =
  32767`, `calibrated`, `posX`, `posY`, `addSample(x, y, z)`.
- Internals: accumulate `_sx/_sy/_sz` until `calibrationSamples`; `_baseRoll =
  _angle(by, bx, bz)`, `_basePitch = _angle(bx, by, bz)`; then per sample
  `_roll = smoothing * (_angle(y, x, z) - _baseRoll) + (1 - smoothing) * _roll`
  (same for pitch), and `_position()` applies the dead zone, the linear ramp to
  `travel`, saturation, and the ±32767 scaling (`posY = -position(pitch)`,
  `posX = +position(roll)`).
- `_angle(a, b, c) = atan2(a, sqrt(b*b + c*c))` — homogeneous in the vector, so
  it takes any vector's direction, not just a normalized one. That property is
  what lets this plan keep the two angle formulas exactly as they are.
- Constants in force: `travel` 20°, `deadZone` 0.5°, `smoothing` 0.4, 20
  calibration samples (`docs/motion_control_plan.md` D2, revised 2026-09-17).

### The screen — `designer/lib/src/ui/game_screen.dart`

- `_motion` (the mapper, 514), `_motionSub` (516), `_motionPhase` (519),
  `_calibrationSamples` / `_calibrationTarget = 20` (524-525), `_motionGeneration`
  (539), `_motionBusy` (579).
- Lifecycle: `_ensureMotionReady` 2251, `_calibrateMotion` 2261, `_attachMotion`
  2292 (subscribes `accelerometerEventStream` at
  `SensorInterval.gameInterval`, with one error handler for the whole mode),
  `_detachMotion` 2306, `_discardMotion` 2317, `_restartCalibrationWatchdog`
  2337, `_onMotionSample` 2347, `_onMotionFailure` 2384, `_cancelCalibration`
  2395.
- `_onMotionSample` calls `motion.addSample(event.x, event.y, event.z)`, drives
  the calibration view, and otherwise writes `_setAxis('TiltX', motion.posX)` /
  `_setAxis('TiltY', motion.posY)` (2463, 20 ms send throttle).
- The calibration view prints `_calibrationSamples/_calibrationTarget` with a
  `LinearProgressIndicator` (3443-3454).
- Motion mode is reachable on both paths (local preview and mirror);
  `_tiltLabels = {'TiltX','TiltY'}` (334) decides which declared controls tilt
  drives.

### The sensor plugin — measured, not assumed

Facts read from the installed `sensors_plus-6.1.2` (lockfile version 6.1.2;
`pubspec.yaml:35` is `^6.1.0`):

- `gyroscopeEventStream({samplingPeriod})` exists and yields
  `GyroscopeEvent(x, y, z, timestamp)`, **rad/s**, in the same device frame as
  the accelerometer (`platform_interface/lib/src/gyroscope_event.dart:7-39`).
- `SensorInterval.gameInterval` is 20 ms, i.e. 50 Hz — already what the
  accelerometer is read at.
- A device without the sensor does not stay silent: `StreamHandlerImpl.onListen`
  calls `events.error("NO_SENSOR", "Sensor not found", …)` when
  `SensorManager.getDefaultSensor(TYPE_GYROSCOPE)` is null
  (`sensors_plus-6.1.2/android/.../StreamHandlerImpl.kt:27-40`). The Dart stream
  surfaces that as `onError`. **This is why a missing gyroscope must be handled
  explicitly**: the screen's existing `onError` handler means "the round cannot
  be steered" (`_onMotionFailure`), which would be the wrong answer here.
- The timestamp is `DateTime.fromMicrosecondsSinceEpoch(list[3])`, where the
  plugin sends `timestampMicroAtBoot + event.timestamp/1000` from Android's
  monotonic `elapsedRealtimeNanos` plus a fixed wall-clock offset computed once
  in the handler's constructor (`StreamHandlerImpl.kt:19, 76`;
  `method_channel_sensors.dart:63, 93`). All five handlers are constructed
  together in `setupEventChannels`, so accelerometer and gyroscope timestamps
  share one offset and are directly comparable, and both are monotonic within a
  subscription.
- The streams are broadcast and cached per sensor type
  (`method_channel_sensors.dart:32-33, 55, 86`), so cancelling every listener and
  re-listening re-registers the Android listener — the pause/resume behaviour
  the accelerometer already relies on works the same way for the gyroscope.
- `pubspec.yaml:33-35` documents motion as Android-only; nothing in this plan
  changes that.

## Decisions

Each can be overruled, but not silently: an implementing agent that changes one
updates the sections that depend on it.

**D1 — the estimate is a gravity *vector*, and the two angles stay exactly as
they are.** The mapper keeps one unit vector `gv` — its estimate of the
direction the accelerometer would read if the phone were at rest — and computes
`_roll`/`_pitch` from it with the existing `_angle()` calls (with `_baseRoll` /
`_basePitch` subtracted, `_position()` applied, signs unchanged). A per-axis
scalar fusion was rejected: which gyro axis belongs to which angle depends on
how the phone is held, is ill-conditioned near the two configurations where the
`atan2` denominators vanish, and would leave the two axes disagreeing about a
rotation that involves both. One vector, both axes, no new convention to
document.

**D2 — complementary filter: the gyro predicts, the accelerometer corrects, and
the accelerometer's weight is adaptive.**

```
predict (per sample, from the gyro):      gv ← rotate(gv, −ω·dt)   (ω in rad/s, device frame)
correct (per sample, from the accel):     gv ← normalize(gv + α·trust·(â − gv))
```

with `â = a/‖a‖`, `α = dt/τ`, **τ = 0.6 s**, and `trust ∈ [0, 1]` from D3. The
gyro path is unfiltered and therefore latency-free; the accelerometer path is a
slow absolute reference that removes gyro bias. The rotation is exact (Rodrigues
about `−ω·dt`), not a first-order approximation, and the result is normalized
every step so the estimate stays a unit vector.

**D3 — the gate is the *innovation*: how far the accelerometer's direction is
from the estimate the gyro just predicted.** `r = angle(â, ĝv)` is measured
**after** the prediction step, and `trust` ramps 1 → 0 as `r` goes from **1°**
to **5°**.

Why those edges, and why they are tighter than the 2°/8° this plan first chose:
the mapper tests showed that in the 2–8° band a *sustained* ~1 m/s² movement
still dragged the player — 5° past the true tilt over about a second, a quarter
of the travel — because a partial trust is still a pull, and it converges on the
corrupted direction. At 1°/5° that case freezes at the gyro-carried truth, and
everything the correction exists for still works: a 0.5°/s gyro bias settles at
0.3°, comfortably inside the 1° full-trust edge, so the loop that removes it
keeps running. The 5° reject edge means any movement from **0.86 m/s²** up is
refused outright.

Why that signal, and why the obvious one is not it:

- *The accelerometer's magnitude is nearly blind to the failure that matters.*
  For a translation perpendicular to gravity, `‖a‖` grows as `a_lin² / 2g` —
  second order. Measured: 0.5 / 1.5 / 3 m/s² of hand acceleration moves `‖a‖` by
  0.013 / 0.114 / 0.448 m/s², while the apparent tilt is 2.9° / 8.7° / 17°. No
  magnitude threshold that survives real accelerometer noise can separate an
  8.7° false tilt from a still phone. A magnitude test survives only where the
  phone is meant to be still anyway — calibration (D6).
- *The innovation is a direct measure of accelerometer corruption*, because with
  the correction running, the estimate tracks gravity to within the gyro's own
  error: a residual of degrees cannot come from gyro bias (D9 puts that at
  0.3°), so a large one means the accelerometer is the sensor that is wrong —
  which is exactly what a hand movement makes it.
- *It needs no history and clears itself.* The prediction step consumes a real
  rotation before the residual is measured, so a fast flick keeps `r` near the
  gyro's per-step error and **is** tracked, while a translation moves `â` and
  nothing else, so `r` jumps.

**The gate cannot be permanent.** A residual past the reject edge is usually a
movement — but the same signature appears when the gyro keeps reporting while
the phone turns without it (a stream emitting garbage, or a rotation that lands
entirely between two samples), and an estimate gated forever leaves the player
stuck at the wrong position for the rest of the round. So: after **1 s** of
continuous gating, trust becomes **0.25**, *but only if* `| ‖a‖ − m₀ |` is
inside `escapeTolerance` — that second condition is what separates "the
gyroscope is wrong" (no linear acceleration to explain the disagreement) from
"the hand is accelerating the phone" (the magnitude moved), and without it this
hatch would undo the whole plan.

`escapeTolerance` is **0.02 m/s²**, deliberately far tighter than the fallback
gate's 0.15 m/s², and it is its own constant because the first draft borrowed
that one and the tests caught what it costs: a movement perpendicular to gravity
moves the *magnitude* only as `a²/2g`, so a sustained 1.5 m/s² — 0.11 m/s² — sat
inside a tolerance meant for something else, kept the hatch open, and crept the
player to the corrupted direction anyway. The hatch is only for a gyro that
talks nonsense, which is the case where the magnitude really is at rest.

A gyro that goes *silent* never reaches this path at all: `gyroStaleAfter` (D5)
switches to the accel-only gate, which tracks rotations.

Measured, and pinned by `designer/test/motion_control_test.dart` (each row is an
assertion, not an estimate; `posX`/`posY` are ±32767 across the travel):

| scenario | without the fusion | with it |
|---|---|---|
| holding 10°, then 1.5 m/s² of hand movement | jumps to 29991 (91% of travel) | **stays at 15963** |
| level hold, 1.5 / 3 m/s² for a second, and for ten | 13773 / 27742 | **0** / **0**, still 0 at ten |
| 0.3 m/s² sustained (its own apparent tilt is 2104) | 2104 | 2104 — the honest bound below |
| 0.5°/s gyro bias, 10 s still | — | 0 (the residual settles at 0.29°) |
| turn 10° in 200 ms, then hold | 15963 | 15963, exactly |
| turn to 10° *while* accelerating 1.0 m/s² | 25374 | **15963** |
| 500°/s flick | saturates | saturates |
| unexplained 10° step, gyro talking | 15963 | recovers to within 0.2° in 6 s |
| quiet hold with sensor noise, 6 s | 0 | 0 on both axes |

What is still wrong, stated as the *rate limiter* this is rather than a bound:

- **≥5° of apparent tilt (≥0.86 m/s² of hand acceleration)** — trust 0, so the
  player does not move at all, and keeps not moving while the acceleration
  lasts: the residual can only shrink through the correction, which is off.
  This is the case in the report, and the escape hatch does not open on it
  because the magnitude gives it away.
- **1°–5° (0.17–0.86 m/s²)** — the player moves by part of the apparent tilt as
  the ramp lets the correction through, converging on the apparent tilt's worth
  if the acceleration is sustained.
- **≤1° (≤0.17 m/s²)** — indistinguishable from gyro bias, so it is corrected
  exactly as if it were bias: a *sustained* gentle movement shifts the player by
  up to 1° (≈840 units, 2.6% of the travel) over about a second, and the dead
  zone absorbs half a degree of it. A *brief* one does not have time to.

If a device shows the gentle case matters, the refinement is a windowed version
of the rate comparison rejected below — accumulate the *unexplained change* in
`â` over ~100 ms, which averages the accelerometer noise down to ≈0.7° and can
see a 0.35 m/s² gust (1.75° in 100 ms). That is more state and one more
constant, so it does not go in until a measurement asks for it.

Rejected alternatives:

- *Frequency separation alone (filter the accelerometer harder).* Hand motion
  is 0.5–2 Hz, the same band as deliberate steering. There is no filter that
  keeps one and rejects the other.
- *Comparing the accelerometer's implied rate against the gyro's (`â_prev × â /
  dt` versus `ω`).* Sound, and equivalent in information to the innovation; it
  needs a differenced vector with a much worse noise floor and a threshold in
  rad/s that has to be tuned against that floor. The innovation is the same test
  with one number and no differentiation.
- *`userAccelerometerEventStream` (the platform's own gravity/linear split).*
  Vendor-dependent, a second subscription, and it hides what we are doing. The
  plan fuses the two raw sensors itself so the behaviour is one implementation
  that is testable in pure Dart.

The gate also behaves correctly *during* a flick: centripetal and tangential
acceleration push `â` away from what the gyro predicts, the residual grows, and
trust drops — which is the right call, because during a fast rotation the gyro
is the better sensor anyway.

**D4 — `dt` comes from the event timestamps, clamped, with the sampling period
as the fallback.** Each sensor sample advances the estimate by its own `dt`,
computed from the previous sample **of its own stream**: use it when it is in
(0, 100 ms], otherwise fall back to the nominal 20 ms. Per stream, not "either
stream" as this plan first said: the two are interleaved, so a shared previous
sample would make each stream's authority depend on how the driver happened to
deliver them — an accelerometer sample landing 1 ms after a gyro sample would
give the correction a 1 ms step and quietly stretch its 0.6 s time constant to
twelve seconds. Reasons for the clamp: batching can deliver events with an
unchanged or coarse timestamp, and every synthetic test and widget-test fake
passes a constant timestamp. The mapper takes `DateTime? stamp` and never calls
`DateTime.now()` — it stays pure and deterministic. Cross-stream differences are
safe: both streams share one wall-clock offset over one monotonic clock (see
"The sensor plugin" above).

**D5 — no gyroscope is a degradation, not a failure, and it needs its own
gate.** The gyro subscription has its own error handler: it marks the mapper
accel-only and reports once (`'No gyroscope on this device: moving the phone
will still read as tilt'`), and the round runs. The accelerometer's error and 2 s
silence keep their current meaning — the round cannot be steered at all —
because calibration and the watchdog are built on that stream.

The fallback cannot borrow D3's gate: without a gyro there is nothing to predict
the rotation, so a *real* rotation looks exactly like corruption and the
innovation gate would freeze the player instead of steering them. Accel-only
mode therefore trusts on magnitude (D3 measured why that is a weak test):
`| ‖a‖ − m₀ |` ramps 1 → 0 over 0.15 → 0.6 m/s², where `m₀` is the mean
magnitude of the accepted calibration samples, so the gate is immune to the
device's own accelerometer offset. That catches a brisk move (≈2–3.4 m/s² of
hand acceleration) and does nothing about a slow one — which is exactly the
honest claim in the message the player is shown, and the reason the caption says
which estimator is running.

It also needs its own, **much shorter** correction time constant
(`fallbackCorrectionSeconds`, 0.08 s against the assisted path's 0.6 s). With a
gyro in the loop the accelerometer is only a slow absolute reference — the gyro
carries every movement, so a long constant costs nothing and averages noise
away. Without one the accelerometer *is* the movement, and 0.6 s would lag every
tilt by a third of a second where the mapper it replaces tracked it directly;
the magnitude gate is what rejects the movements, so the loop can be fast.

A gyro stream that goes quiet mid-round (> 200 ms without a sample) is treated
as absent, so the fallback is not only about hardware.

**D6 — calibration accepts only at-rest, self-consistent samples.** A sample
counts toward the 20 only while all three hold:

1. `| ‖a‖ − 9.80665 | ≤ 0.3 m/s²` — the phone is not being accelerated along
   gravity (a lift changes only the magnitude; D3);
2. the latest gyro rate is ≤ 0.15 rad/s (≈8.6°/s) — the phone is not rotating;
3. its direction is within 2° of the running mean of the samples accepted so
   far — a translation during the hold is a *direction* change with no gyro
   rate (D3's second-order problem, measured), so this is the test that
   actually protects the neutral, and it is the same "believe the accelerometer
   only while the other evidence agrees" rule the round uses.

Accepted samples are averaged as *unit* vectors (so a magnitude anomaly cannot
skew the mean), and the estimate is seeded from that mean, so the mapper starts
the round at exactly the neutral angle. The progress bar counts accepted
samples, which makes the view honest: it says 4/20 while the player is moving
the phone, not 20/20 with a wrong neutral. A hold that never settles cannot hang
the view: a 5 s timer ends the calibration with `'Could not calibrate: hold the
phone still'`, motion mode stays selected, and Start or Recalibrate tries again.
The 2 s no-samples watchdog is unchanged and keeps its meaning (the sensor is
not reporting).

**D7 — nothing outside the app changes.** No firmware, no `gamekit`, no FFI, no
wire format, no bundled-firmware restage, no version bump. `ML_INPUT_AXIS`,
`ML_AXIS_IDLE`, the control surface and the 20 ms axis send throttle are
untouched; this plan changes only what the phone believes the angle is, never
what it sends.

**D8 — the output EMA stays.** `smoothing 0.4` on the angle (`motion_control.dart`
102-103) is kept. The fusion changes the angle's *source*; the output filter is
what keeps a resting hand from shivering the player, and removing it would
re-open a settled question (and invalidate the mapper tests that pin it). The
responsiveness this plan adds comes from the gyro path being unfiltered *inside*
the fusion, not from deleting the last stage.

**D9 — no explicit gyro-bias estimator.** The accelerometer correction *is* the
bias loop. Error budget at τ = 0.6 s: a residual bias of 0.5°/s settles at 0.3°
of steady-state error, and a 300 ms gate-closed window contributes 0.15°.
Both are inside the 0.5° dead zone, and inside the 1° edge below which the
accelerometer is fully trusted (D3) — so the correction keeps running while the
phone is still, which is what holds the bias down in the first place. Revisit
only if a device shows drift that the dead zone does not absorb.

## What implementing this plan changed

Four things in the plan above were wrong, and the tests found each of them. They
are corrected in place; this is the record of what they cost, so the next agent
does not have to rediscover them.

1. **The escape hatch borrowed the wrong tolerance.** D3's hatch opened on
   `fallbackTolerance` (0.15 m/s²), and a movement *perpendicular* to gravity
   moves the magnitude only as `a²/2g` — 1.5 m/s² is 0.11 m/s² — so a sustained
   1.5 m/s² kept the hatch open and crept the player away over ten seconds. The
   hatch has its own `escapeTolerance = 0.02` now.
2. **The trust ramp was too wide.** At 2°/8° a sustained ~1 m/s² movement pulled
   the player 5° past the true tilt while turning. It is 1°/5°, which freezes
   that case and still leaves the bias loop running (0.3° ≪ 1°).
3. **`dt` has to be per stream.** "The previous sample of either stream" makes
   each sensor's authority depend on how the driver interleaves them: an
   accelerometer sample arriving 1 ms after a gyro sample would give the
   correction a 1 ms step, stretching its 0.6 s time constant to twelve seconds.
4. **The output EMA must run on gated samples.** Skipping it when the gate
   refuses a sample — which reads like an obvious saving — freezes the filter
   mid-convergence, and the position stays short of the true tilt for as long as
   the gate is shut. After a gated movement the player was left 1.5° off with
   nothing to correct it.

The accel-only path also needed its own correction constant (D5): with the gyro
carrying every movement, 0.6 s costs nothing, but without one it *is* the
movement, and the mapper it replaces tracked it directly.

Two things in Phase 2/3 needed care for the same reason, and are worth stating
where an implementer will hit them:

- `_discardMotion` only mutates; every caller must rebuild. A new caller that
  does not (the stalled-calibration path did not) leaves the calibration view on
  screen with nothing driving it.
- The widget-test harnesses must mock the gyroscope event channel even for
  rounds that never send a gyro sample: without a mock the subscription itself
  throws `MissingPluginException`, which is not what a phone without the sensor
  does, and the test framework fails the test on the unexpected exception.

## Phase 1 — the estimator (`designer/lib/src/services/motion_control.dart`)

Rewrite the class around the gravity estimate. Keep the file's public contract
(`idle`, `full`, `calibrated`, `posX`, `posY`, `travel`, `deadZone`, `smoothing`,
`calibrationSamples`), the calibration-to-neutral geometry, `_position()`, and
`_angle()` unchanged in meaning.

Every constant below was prototyped and measured before this document was
written — D3's table is that measurement, and Phase 3b pins the same numbers as
assertions. They are a starting point with evidence, not a guess, so if you
change one, re-measure and update D3.

```dart
/// Maps the phone's orientation to a position in a game's travel, using the
/// gyroscope and the accelerometer together.
///
/// The accelerometer alone cannot answer "which way is up" while the phone is
/// being moved: it measures gravity plus the hand's acceleration, so a
/// translation reads as a tilt. The gyroscope cannot answer it alone either:
/// it measures rotation rate, so any error in it accumulates. Each covers the
/// other's blind spot — the gyro carries the estimate through a movement, and
/// the accelerometer removes the gyro's slow drift whenever the phone is not
/// being accelerated by the hand.
class MotionControl {
  MotionControl({
    this.calibrationSamples = 20,
    this.travel = _defaultTravel,        // 20 degrees, unchanged
    this.deadZone = _defaultDeadZone,    // half a degree, unchanged
    this.smoothing = 0.4,                // output EMA, unchanged (D8)
    this.correctionSeconds = 0.6,        // accel authority, gyro-assisted (D2)
    this.fallbackCorrectionSeconds = 0.08, // accel authority, gyro-less (D5)
    this.trustAngle = 1 * math.pi / 180, // rad: full accel trust below this (D3)
    this.trustReject = 5 * math.pi / 180,// rad: no accel trust above this (D3)
    this.fallbackTolerance = 0.15,       // m/s^2: accel-only gate edge (D5)
    this.fallbackReject = 0.6,           // m/s^2: accel-only gate off (D5)
    this.gyroStaleAfter = const Duration(milliseconds: 200),  // D5
    this.escapeAfter = const Duration(seconds: 1),            // D3 recovery
    this.escapeTolerance = 0.02,         // m/s^2: the hatch's own test (D3)
    this.escapeTrust = 0.25,             // D3 recovery rate
    this.restRate = 0.15,                // rad/s: "at rest" for calibration (D6)
    this.restTolerance = 0.3,            // m/s^2: "at rest" for calibration (D6)
    this.nominalStep = const Duration(milliseconds: 20),
  });

  static const int idle = -32768;
  static const int full = 32767;

  bool get calibrated;
  int get calibrationProgress;     // accepted samples of calibrationSamples (D6)
  bool get gyroscopeAssisted;      // a gyro sample has fed the estimate (D5)
  int get posX;                    // canvas convention, as today
  int get posY;

  /// One accelerometer sample (m/s^2, gravity included).
  void addAccelSample(double x, double y, double z, {DateTime? stamp});

  /// One gyroscope sample (rad/s, same device frame).
  void addGyroSample(double x, double y, double z, {DateTime? stamp});

  /// The gyroscope reported NO_SENSOR: accel-only from here (D5).
  void gyroscopeUnavailable();
}
```

These are the defaults as shipped. Note `gyroscopeAssisted` means "a gyro sample
has arrived and none has been declared unavailable" — it is what the surface
prints, and it is deliberately not the same thing as the *live* test the gate
uses (a gyro that goes quiet mid-round degrades the gate without changing what
has been seen).

Behaviour, in order:

1. **Calibration.** While `!_calibrated`, an accelerometer sample is tested
   (D6) and, if accepted, added to a running sum of the *normalized* reading
   plus a count of accepted samples. On reaching `calibrationSamples`:
   `gv = normalize(sum of unit vectors)`, `_baseRoll = _angle(gv.y, gv.x, gv.z)`,
   `_basePitch = _angle(gv.x, gv.y, gv.z)`, `_roll = _pitch = 0`, `calibrated =
   true`. Gyro samples received before calibration update only the "at rest"
   test input (their rate, and the timestamp); they do not move the estimate.
2. **Gyro sample (post-calibration).** `dt` per D4; if `‖ω‖·dt > 0`, rotate:
   with `θ = ‖ω‖ dt` and `û = ω/‖ω‖` (a *unit* axis — the angle is the only place
   `dt` belongs), `gv ← gv·cosθ − (û × gv)·sinθ + û(û·gv)(1 − cosθ)` then
   normalize. Snap tiny values (`θ < 1e-6`) to a no-op. Then recompute the two
   angles through the EMA and the position mapping — the gyro sample is allowed
   to *move* the reported position, which is what makes a flick track at the
   sample rate.
3. **Accelerometer sample (post-calibration).** `dt` per D4. **Choose the gate
   by whether the gyro is live** — a gyro sample within `gyroStaleAfter` and no
   `gyroscopeUnavailable()` call:
   - *gyro live (D3)*: with `â = a/‖a‖` and `d = 1 − â·gv` (the innovation as a
     dot product, so no `acos` on the hot path),
     `trust = clamp((d_reject − d) / (d_reject − d_tolerate), 0, 1)` with
     `d_tolerate = 1 − cos(trustAngle)`, `d_reject = 1 − cos(trustReject)`, and
     `α = dt / correctionSeconds`.
   - *accel-only (D5)*: `trust` from `| ‖a‖ − m₀ |` over
     `fallbackTolerance → fallbackReject`, where `m₀` is the mean magnitude of
     the accepted calibration samples, and `α = dt / fallbackCorrectionSeconds`
     — the fallback's own, much shorter constant (D5).

   If `trust > 0` and `‖a‖ > 1e-3`: `gv ← normalize(gv + α·trust·(â − gv))`.
   Note the order: `gv` here is the **post-prediction** estimate when gyro
   samples have been arriving, which is what makes the residual measure
   accelerometer corruption rather than the phone's own rotation (D3).
4. **The output filter runs on every accelerometer sample, gated or not.** This
   is not cosmetic: the EMA is a filter *converging on the estimate*, so a
   refused sample that skips it leaves the position frozen mid-convergence and
   short of the true tilt, permanently, for as long as the gate stays shut —
   after a gated movement the dot sat 1.5° off with nothing to correct it.
   A held estimate is a filter input that must still be allowed to settle.
5. **The escape hatch (D3), only on the gyro-live path.** When the ramp gives
   exactly 0, add `dt` to a gated-time counter; once it reaches `escapeAfter`
   **and** `| ‖a‖ − m₀ | ≤ escapeTolerance` (the hatch's own tight constant, not
   the fallback gate's), use `escapeTrust` for this sample instead. Any sample
   with a positive ramp value resets the counter to 0. This is the only reason
   `m₀` is needed on the gyro-live path, and it is what keeps a gyro that talks
   nonsense from freezing the player for the rest of the round.
6. **Guards.** No `NaN` ever reaches `posX`/`posY`: skip a sample whose reading
   is not finite or whose magnitude is degenerate, and never divide by zero.
   No allocation on the hot path (the vector math is three doubles plus locals).
7. **Order of the EMA.** The EMA stays where it is today — applied to the
   *angle offset*, after the fusion — so `_roll`/`_pitch` keep their meaning as
   filtered offsets from neutral.

The accelerometer stream drives both the calibration progress and the round, as
it does today; the gyro stream only advances the estimate. Both are 50 Hz, so
the estimate advances at up to 100 steps/s without either stream waiting on the
other.

## Phase 2 — the screen (`designer/lib/src/ui/game_screen.dart`)

### 2a. Subscribe to both streams

- Add `StreamSubscription<GyroscopeEvent>? _gyroSub` next to `_motionSub` (516),
  and a `bool _gyroUnavailable = false` (per round, cleared by `_discardMotion`).
- `_attachMotion` (2292) must stop early only when *both* subscriptions exist,
  subscribe `gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)`,
  and route its events to `_onGyroSample(generation, motion, event)`. Keep the
  shared `++_motionGeneration` guard: a sample from a detached subscription is
  dropped exactly as today.
- `_detachMotion` (2306) cancels both. `_discardMotion` (2317) clears
  `_gyroUnavailable` with everything else.
- The gyro subscription's `onError` goes to a new `_onGyroFailure(generation)`,
  **not** `_onMotionFailure`: set `_gyroUnavailable`, call
  `motion.gyroscopeUnavailable()`, and tell the player once (D5). If the gyro
  error arrives while calibrating, calibration continues and completes on
  accelerometer samples; the message is shown when the calibration view closes,
  so it is read rather than flashed.

### 2b. Feed the mapper, and let the calibration count be the mapper's

- `_onMotionSample` (2347): `motion.addAccelSample(event.x, event.y, event.z,
  stamp: event.timestamp)`. Replace the counter's own bookkeeping
  (`_calibrationSamples++`, 2357-2359) with a read of
  `motion.calibrationProgress`, `setState`-ing only when it changed. On
  completion set `_calibrationSamples = _calibrationTarget` as today (2364).
- New `_onGyroSample`: same generation/mounted guard, then
  `motion.addGyroSample(event.x, event.y, event.z, stamp: event.timestamp)`;
  if the round is playing, `_setAxis('TiltX', motion.posX)` and
  `_setAxis('TiltY', motion.posY)` exactly as the accelerometer path does. The
  20 ms send throttle already coalesces the two streams, and the 100 ms
  heartbeat is unchanged.
- Add the still-hold timer (D6): a `_calibrationStillTimer` started in
  `_calibrateMotion` (2261) beside the existing watchdog, cancelled on
  completion, failure, cancel and `_discardMotion`. On expiry:
  `_discardMotion()`, leave `_inputMode` on motion, `_showMessage('Could not
  calibrate: hold the phone still')`. The existing
  `_restartCalibrationWatchdog` (2330) and its 2 s meaning are untouched.

### 2c. Say which estimator is running (D5)

- `_buildMotionGamepad` (3821) caption: `'Tilt the phone to steer'` (3853-3856)
  becomes
  `'Tilt the phone to steer — gyro-assisted'` or `'— accelerometer only'` from
  `_motion?.gyroscopeAssisted` / `_gyroUnavailable`. One `Text`, no new state
  beyond the flag.
- Nothing else in the mode picker, the paused view or the game list changes.

### 2d. What does *not* change

`_ensureMotionReady`, `_calibrateMotion`'s shape, `_onMotionFailure`,
`_cancelCalibration`, `_motionUnavailable`, `_tiltAxes`, `_setAxis`,
`_recomputeHeld`, the release paths and every send throttle. The failure
semantics are deliberately left alone: only the gyro's *absence* is new, and it
is not a failure.

## Phase 3 — tests

### 3a. The rig (`designer/test/motion_control_test.dart`)

Replace the hand-written `_rollSample`/`_pitchSample` helpers with a small
synthetic rig that keeps one orientation and emits *consistent* samples from
it, because inconsistent samples are exactly what a fusion bug hides behind:

```dart
/// A still or rotating phone, emitting what both sensors would read.
///
/// The orientation is a rotation about **one fixed device axis**, which is the
/// only case where the body rate equals the derivative of the rotation vector —
/// so every test rotates about one axis at a time and the two streams stay
/// consistent by construction. [linear] is the hand's acceleration, which the
/// accelerometer sees and the gyroscope does not: that asymmetry is this file's
/// subject.
class _Rig {
  _Rig({required this.axis, this.angle = 0, List<double>? linear});

  final List<double> axis;                 // unit rotation axis, device frame
  double angle;                            // radians from the reference
  double rate;                             // rad/s while a turn is running
  List<double> linear;                     // m/s^2, accelerometer only

  /// Rotate by [deg] over [samples] samples, then hold that angle.
  void turn(MotionControl m, double deg, {int samples = 10});

  /// Hold the orientation (and [linear]) for [samples] samples.
  void hold(MotionControl m, {int samples = 10});

  // Per emitted sample, in this order: advance [angle] by [rate] * 20 ms,
  // addGyroSample(axis * rate), addAccelSample(rotateInverse(axis, angle,
  // (0, 0, g)) + linear), both stamped 20 ms apart so `dt` is real.
}
```

Keep every existing assertion's *intent* (neutral is 0; 20° saturates; the dead
zone; both physical signs; a held angle converges and stops; a single strong
sample does not jump the travel; `idle` only before calibration), rewriting them
onto the rig, and mind the two traps the prototype hit:

- **Rotations go through `turn()`** (gyro and accelerometer consistent). A step
  change in the accelerometer with `rate = 0` is *not* a rotation — it is
  physically impossible, and the gate correctly treats it as corruption. The
  current tests are full of such steps (`m.addSample(sample[0], sample[1], …)`
  with the angle jumping); they must become `turn()`s, and the assertions that
  were about the mapping rather than the sensors should hold the rig still.
- **Put the linear term on the axis under test.** `linear = [0, 1.5, 0]`
  corrupts the *roll* (`posX`); `[1.5, 0, 0]` corrupts the *pitch* (`posY`). The
  prototype's first pass measured `posX` while pushing the phone along its own
  x axis and concluded, wrongly, that nothing had moved.

### 3b. New mapper tests

Assertions marked *(measured)* are the prototype's numbers from D3's table; they
are the expected values, and the tests should pin them to within a unit or two
rather than re-deriving them.

1. **The regression — a translation is not a tilt.** `turn()` to +10° of roll and
   hold, note `posX` (15963 *(measured)*), then hold the orientation while
   `linear = [0, 1.5, 0]` for 25 samples, then release it. `posX` must be
   **exactly** unchanged during and after the movement. Comment, not assertion:
   the same trace through the accelerometer alone is 29991 — the false swing the
   report is about.
2. **Brisk and sustained translations do nothing.** At a level hold, 1 s of
   `linear = [0, a, 0]` for a = 1.5 and a = 3 gives exactly 0 *(measured)*; the
   same traces through the accelerometer alone are 13773 and 27742. Then 10 s at
   3 m/s², still exactly 0 — the anti-creep property of D3's first bullet.
3. **A gentle translation is bounded by its own apparent tilt.** `linear =
   [0, 0.3, 0]` for 6 s: `posX` converges to 2104 *(measured)* — the apparent
   tilt's worth, never more. This test is what makes D3's stated residual error
   visible if someone retunes the ramp.
4. **Without a gyro, a brisk move freezes and a rotation still steers.** Never
   feed a gyro sample (`gyroscopeAssisted == false`). A 4 m/s² linear burst
   (0.8 m/s² of magnitude deviation, past `fallbackReject`) leaves the position
   unchanged; a `turn()` to +10° afterwards is tracked (14623 after 60 hold
   samples, converging on 15963 *(measured)*).
5. **Rotation is tracked, with the right sign, at both speeds.** `turn()` +10°
   over 10 samples then hold, and the same over 3 samples (≈500°/s): both settle
   on what an accel-only mapper reports for that orientation (15963 and 32767
   *(measured)*) — the test that catches an inverted cross product or a swapped
   gyro axis. Then the same turn *while* `linear = [0, 1, 0]`: still 15963.
6. **A sustained explanation-free residual recovers (D3's escape hatch).** Hold
   the orientation, then step the accelerometer to +10° while the gyro keeps
   reporting zero rate — a gyro that talks nonsense. The position must move off
   its old value and reach within 0.2° of the truth within 6 s, not stay stuck.
   With the same step *and* a magnitude that shows acceleration, it must stay
   stuck (that is the difference the hatch keys on).
7. **Bias drift is bounded.** Static rig, gyro reporting a constant 0.5°/s about
   one axis with the accelerometer held still (a bias is exactly gyro-without-
   rotation — do not advance the rig's angle here), 500 samples: the position
   stays exactly 0, with the residual settling at 0.29° *(measured)*. That is
   inside both the 0.5° dead zone and the 1° trust edge, which is D9's claim.
8. **Timestamp robustness (D4).** Constant, absent, duplicate and backwards
   stamps, and a 500 ms gap: no `NaN`, no saturated jump, and a gap does not
   integrate more than the clamped 100 ms.
9. **Calibration rejects movement (D6).** Hold the rig still for 10 accepted
   samples, then move it and assert `calibrationProgress` never advances and the
   finished neutral equals the still-hold angle — with **both** sizes:
   0.5 m/s² perpendicular to gravity, which leaves the magnitude within 0.013
   m/s² of rest (second order) and can only be caught by condition 3, and
   3 m/s², which fails condition 1 as well. Then a *tilted* hold calibrates to
   that tilt (neutral is where the phone was, not level).
10. **Quiet hold with noise.** A still rig plus Gaussian sensor noise (0.05 m/s²,
    0.005 rad/s) for 300 samples: both axes stay exactly 0 *(measured)*.
11. **Before calibration** gyro samples do not move the estimate; a sample after
    `gyroscopeUnavailable()` is ignored without throwing; `posX`/`posY` stay
    `idle` until calibrated and never take the value `idle` afterwards.

### 3c. Widget tests (`designer/test/game_screen_session_test.dart`)

- Add the gyro channel to the harness: `const gyroChannel =
  'dev.fluttercommunity.plus/sensors/gyroscope'`, mocked in `setUp`/`tearDown`
  beside the accelerometer one (132-148), plus a `sampleGyro(tester, x, y, z)`
  helper mirroring `sample` (150-156). Leaving it *unmocked* is also a case:
  no platform handler means no samples, which is the accel-only path every
  existing motion test then exercises unchanged.
- New: `gyroscope absence continues in motion mode` — begin calibration, push
  the gyro channel's `NO_SENSOR` error envelope, feed 20 accelerometer samples,
  and assert the round starts, the mode stays motion, and the message is shown
  once.
- New: `a still hold that never happens fails with its own message` — feed
  samples that are never still, advance 5 s of fake time, assert no round
  started, motion mode still selected, and the message text.
- Existing: `missing motion samples fail without starting a remote game` and
  `sensor errors leave setup usable without starting` must keep passing
  untouched — they pin the accelerometer's failure meaning (D5).
- The widget fakes pass timestamp `0`; the D4 clamp is what keeps them working.
  Do not "fix" the helper by inventing a clock — a device does not guarantee
  increasing stamps either.
- Worth knowing when a widget test surprises you: with the gyro channel
  unmocked, every existing motion test drives the **accel-only** gate (D5), and
  that gate trusts any direction change, so those tests keep their present
  meaning. The fusion itself is covered by the mapper suite (3b), not here.

## Phase 4 — documentation

- `docs/games.md`, "A tilt axis is a position, not a direction" (255-290): the
  phone-side paragraph gains the estimator — gyro and accelerometer fused, the
  accelerometer disbelieved while the phone is being moved, calibration from
  at-rest samples only, and the degraded accel-only path on a device with no
  gyroscope.
- `designer/README.md`, the motion paragraphs (213-231): "20 accelerometer
  samples" becomes "20 samples taken while the phone is still"; the gyro-assisted
  behaviour and the no-gyro fallback are stated where it lists what the player
  sees.
- `docs/motion_control_plan.md`: no edit. Add nothing there — this plan
  supersedes its Phase 4 sensor source and says so at the top; D2's travel, dead
  zone and EMA are all unchanged, so the two documents do not disagree.
- No firmware README, no changelog, no version bump (D7).

## Phase 5 — verification

On this machine:

```sh
cd designer && flutter analyze
cd designer && flutter test test/motion_control_test.dart test/game_screen_session_test.dart
cd designer && LD_LIBRARY_PATH=<lib dir> flutter test     # the whole suite
```

The mapper suite is the proof of the defect being fixed, and it is also the
cheapest way to tune: every number in D2/D3/D6 can be moved and re-measured
without a phone. `make -C core -f Makefile.host check` and
`make -C gamekit -f Makefile.host check` must stay green (they are untouched;
run them once at the end to prove it).

On the device (Pixel/Android, mirror over BLE, firmware from the tree; build the
APK per `designer/README.md`):

1. **The reported defect, directly.** Start the probe. Hold the phone at a
   steady angle and *move it* — sideways, up and down, a brisk hand sweep — and
   watch the dot: it must stay put, where today it swings and springs. Repeat
   with the dot off-centre (a held tilt) to prove it is not just the dead zone.
2. **Rotation still tracks, and feels faster.** Roll and pitch to the ends of
   the travel (±20°), check the ends are exact, and confirm a quick flick
   reaches the right position without the old slow catch-up.
3. **Held angle, held position.** Stop moving at an angle: the dot settles and
   stops, with no drift over 30 s (the accel correction is doing its job).
4. **Calibration honesty.** Move the phone while the calibration view counts:
   the count must stall, not advance; the view must finish only from a still
   hold; on a hold that never settles, the 5 s message and a retry.
5. **Fallback.** On a device (or an emulator image) with no gyroscope, motion
   mode still starts, the caption reads "accelerometer only", the message is
   shown once, and a translation freezes the dot instead of swinging it.
6. **The stated limits, on real hardware.** Shake the phone continuously for a
   few seconds: a brisk shake must leave the dot frozen, not creeping (D3's
   first bullet — the escape hatch must not open, because the magnitude gives
   the movement away). Then a *gentle* sustained slide (a slow hand sweep that
   never stops): the dot may move by up to ~2°, which is the documented limit,
   not a defect — if it moves more than that, the ramp needs re-tuning (D3).
7. **A real round.** Rally: the paddle follows the tilt, and does not move when
   the phone is moved without tilting. Tetris and snake: unchanged except for
   the new steadiness.
8. **Manual mode, pause/resume, older firmware**: unchanged from
   `docs/motion_control_plan.md` Phase 7 — re-run its steps 6-8 to prove this
   change did not disturb them.

## Acceptance

- A translation during a round no longer moves the player: nothing at all for a
  movement that reaches 0.86 m/s² or more (asserted on the mapper, observed on
  the probe), and no more than D3's stated bound below that. With no gyroscope,
  a brisk movement freezes the player instead of swinging them, and says so.
- Rotation is tracked with the correct sign on both axes, by the gyro, and the
  reported position after a rotation matches the accelerometer's own reading of
  that final orientation.
- Neutral is established only from samples taken at rest; a hold that never
  settles fails with its own message instead of latching a wrong neutral.
- A device with no gyroscope still runs motion mode, says so, and freezes rather
  than swinging during a movement.
- `motion_control_test.dart`, `game_screen_session_test.dart` and the full
  designer suite pass; `make -C core -f Makefile.host check` and
  `make -C gamekit -f Makefile.host check` are untouched and green.
- No change to `gamekit`, `firmware`, the FFI, the wire, or the bundled image.

## Out of scope

- An explicit gyro-bias estimator, magnetometer yaw, or any full AHRS (D9).
- Device-specific gyro scale/axis calibration, or per-device tuning UI.
- Changing `travel`, the dead zone, the output EMA, or the positional axis
  contract — the plan that fixed those is `docs/motion_control_plan.md` and its
  decisions still hold.
- The `userAccelerometer` stream, barometer, and every other sensor (D3).
- Touch input, multi-player tilt, the LAN/peer architecture, and the unrelated
  `docs/improvement_backlog.md` items.
