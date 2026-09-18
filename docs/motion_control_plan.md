# Plan: proportional motion controls, and the tilt visualiser

Audience: the agent implementing this. Read the whole document before editing.
It records what already exists (do not rebuild it), the contracts to add, the
exact files and call sites, and how to verify — on the host and on the device.

## Goal

1. **Motion input becomes positional, not thresholded.** Today the phone's tilt
   is turned into held `Up`/`Down`/`Left`/`Right` presses by a 10°/5° hysteresis
   (`designer/lib/src/services/motion_control.dart`), so a moving paddle moves
   in steps and only while a threshold is crossed. Instead, the tilt angle
   relative to the calibrated neutral must map **directly and linearly to the
   player's position inside the game's travel**:

   | phone angle (from neutral) | rally paddle |
   |---|---|
   | 0° (the starting hold) | exactly centred |
   | +15° | 75% of the way to the top |
   | +20° | top of the travel |
   | −20° | bottom of the travel |

   (The worked example was written at ±30°. Playing it cut the travel to ±20 and
   the dead zone to half a degree; see D2.)

   Deliberately implied by that table, and worth stating because it is the
   property the player actually feels: **the player changes position only while
   the angle is changing.** A held angle is a held position — no drift, no
   recentring, no spring, no repeat rate. Angle in, position out.

2. **Every game is steered that way**: rally (paddle vertical), breakout and
   invaders (paddle/cannon horizontal), tetris (the falling piece's column),
   probe (the dot, both axes), and snake — which has no continuous position, so
   it gets the honest equivalent: the tilt *vector* picks a heading, and the
   game turns at its next cell (see D4).

3. **The tilt visualiser comes back as a game mode.** The probe (a red dot
   driven by raw input, `gamekit/examples/probe/game_probe.c`) is no longer
   offered in the app's game list: 7016ac0 moved it behind a separate
   "Controller diagnostic" button (`_playableGames` filters it out,
   `game_screen.dart:669-677`). It goes back into the picker as a selectable
   mode, and — this is the part that never worked — it must be steerable by
   tilt **in the app's own local preview**, not only on a mirror.

## What already exists (do not rebuild)

### The input contract — `gamekit/include/mirror/game.h`

- `ml_input_type`: `ML_INPUT_BUTTON` (value 0/1), `ML_INPUT_AXIS`
  (value −32768..32767), `ML_INPUT_TOUCH` (game.h:70-74).
- `ml_control_def {label[16], code, caps, type}` (game.h:100-109); a game
  declares its controller surface, and the client draws exactly that.
- `ML_INPUT_CODE_COUNT 16` / `ML_INPUT_MAX_CODE 15` (game.h:87-88).
- The runtime is a pure dispatcher: `route_one_input` stamps the host tick and
  calls `game->input()` directly (runtime.c:172-178). No type logic, no scaling,
  no per-code special cases — interpretation belongs to the game.
- `ml_game_ctx` exposes only tick, PRNG, model and emit hooks (gamerun.h:35-48).
  It does **not** expose the panel size: a game that needs its extents keeps
  them in its own state (all six do).

### The wire — no change is needed for any of this

- Catalogue: `game list` → `games <id>,<id>...`; `game start <id>` →
  `game ok <id> <label>:<type> ...` where `a` = `ML_INPUT_AXIS`, `b`/absent =
  button (firmware `game_runner.c:351-362`; parser `mirror_ble_game.dart:187-212`;
  limits `char line[256]`, controls in code order).
- Frame: one write to `game_in` (`ble.c:785-842`): `u8 count`, then per control
  `u8 code` + `i16 value` little-endian, ≤16 controls, ≤49 bytes
  (`mirror_ble_game.dart:226-238` encodes it).
- **The type is not on the wire.** Both sides resolve it from the running game's
  `controls[]` table (firmware `ble.c:824` → `game_runner_control_type`
  `game_runner.c:521-534`), and the firmware passes an axis value through raw
  while coercing a button to 0/1 (`ble.c:825`). So games that declare more axes
  need no protocol change at all.
- App sends the **full state** every frame; a 100 ms heartbeat re-asserts it
  (`game_screen.dart:2764-2778`), and 500 ms of silence freezes the round
  (`game_runner.c:480-486`).

### Firmware runner — `firmware/main/games/game_runner.c`

- `request_input_frame` validates every code against the running game, else
  rejects the whole frame (263-295); a rejected frame does not refresh the
  silence watchdog.
- Pause (`session_freeze`, 214-221) calls `release_declared_controls`
  (178-196), which synthesizes **value 0 with each control's own type**; the
  `count == 0` "all released" expansion does the same (284-286). For an axis,
  value 0 currently means *centre* — see P3.
- Input queue `INPUT_Q_DEPTH 64` (69); a full-state frame needs N free slots.

### The app's motion pipeline — `designer/lib/src/ui/game_screen.dart`

- `MotionControl`: neutral from 20 samples, EMA `smoothing 0.4`, hysteresis
  booleans `up/down/left/right` (10°/5°), and analog `tiltXAxis`/`tiltYAxis`
  saturating at 0.5 rad (`motion_control.dart:20-49, 55-71`).
- Lifecycle: `_ensureMotionReady` 2200, `_calibrateMotion` 2210, `_attachMotion`
  2241, `_detachMotion` 2255, `_discardMotion` 2265, watchdog 2 s 2288,
  `_onMotionSample` 2295-2339, `_onMotionFailure` 2345.
- Tilt → input: `_onMotionSample:2322-2338` — axes path when `_tiltDrivesAxes`
  (2365) writes `TiltX`/`TiltY` through `_setMirrorAxis` (2413-2427, 20 ms
  throttle); otherwise directions through `_setTiltHeld` (2397) with
  `_tiltDrivesVertical` (2385) suppressing tetris's Up/Down via the alias table
  (`_gameCopy` 361-365).
- Resolved state: `_recomputeHeld` (1060-1074) zeroes every slot, sets 1 for
  every source-owned button, overlays `_axes` raw, and neutralises opposing
  direction pairs. `_dispatchInput` (1088-1095) → mirror `sendGameInput(_held)`
  (2432-2439) or local `engine.button(...)`, which **collapses every value to
  0/1** (1101-1107). Release paths send zeros: `_sendReleasePacket` 1235-1240,
  `_sendLocalRelease` 1113-1120.
- Motion mode is **mirror-only**: the only `mode-motion` radios are in
  `_buildMirrorSetup` (3466-3483) and `_buildMirrorPaused` (3579-3595), and
  `_onMotionSample` returns early while `_mirrorGame == null` (2320-2321). In a
  local round the tilt axes are structurally unreachable, and the probe's
  `TiltX`/`TiltY` readouts (`_axisSpecs` 3812-3829) sit pinned at 0.
- `_axisLabels = {'TiltX','TiltY'}` (344) is how the *local* catalogue is
  sniffed for axes, because the FFI exports labels only (see below).

### The FFI — `gamekit/ffi/game_ffi.{c,h}`

- Catalogue accessors expose `label` only: `ml_game_control_label`
  (game_ffi.c:84-92); `GameInfo.controls` is `List<String>`
  (`game_bindings.dart:146-152`). No codes, no types.
- `ml_game_button(s, player_id, code, value)` takes an `int16_t` but hardcodes
  `e.type = ML_INPUT_BUTTON` (game_ffi.c:158), so **no axis event can ever reach
  a local session** — even though probe's handler would accept the raw value.
- `GameEngine.button` (game_engine.dart:120-123) is the only input call site in
  Dart, and `_sendLocalInput` throws the magnitude away.

### The visualiser — `gamekit/examples/probe/game_probe.c`

- Four direction buttons plus `TiltX`/`TiltY` (`ML_INPUT_AXIS`,
  `ML_CAP_ACCEL`) drive one red circle (controls 41-48; input 102-115; update
  117-146). Its axes are a **rate** (`dx += tilt_x * sp / 32768`, 131-132), so
  the dot drifts while tilted and stops when level — not the positional
  behaviour this plan wants.
- It is compiled everywhere: host CLI/tests, the Flutter shared library
  (`designer/packages/mirror_core_ffi/src/CMakeLists.txt`), and the firmware
  (`gamekit/CMakeLists.txt`, `fw/game_registry.c:15-24`). It appears in
  `game list` from a real mirror.
- What 7016ac0 removed was its **entry in the app's game picker**, not the game.

### Test harnesses that already exist

- `gamekit/Makefile.host`: `make -f Makefile.host check` builds and runs
  `host/*_test.c` against the FFI (`TEST_BIN` list, ~line 40); the pattern to
  copy is `held_input_test.c` (drives a session through `ml_game_button`).
- `designer/test/motion_control_test.dart`: 11 pure-Dart tests pinning the
  current hysteresis (they will be rewritten).
- `designer/test/game_screen_session_test.dart`: the motion contract —
  calibration gating (214), sensor failure (235), cancel, tetris
  horizontal-only tilt, pause keeps neutral vs suspension recalibrates (426).
- `designer/test/game_screen_test.dart`: local setup and picker behaviour.
- Native-lib-dependent Dart tests skip when the library is missing; the interim
  trick from `docs/improvement_backlog.md` (I6) is
  `LD_LIBRARY_PATH=<dir with libmirror_core_ffi.so> flutter test`.

## Decisions

These are the calls this plan makes. Each can be overruled, but not silently:
an implementing agent that changes one updates the sections that depend on it.

**D1 — an axis is an absolute position request.** `ML_INPUT_AXIS` gets one
documented meaning in `game.h`: `0` is the middle of the game's travel, `±32767`
are its ends, and **`ML_AXIS_IDLE` (−32768) means "the controller is not driving
this axis"** — the game holds whatever position it has. Buttons stay levels
(0/1) with the game owning edges. This is what lets one frame carry both a
manual pad's rate-driven buttons and a motion round's positional axis, and lets
the game pick per frame: axis engaged → position, axis idle → buttons.

**D2 — one travel, fixed constants, in the app.** Saturation at **30°** from
neutral (the user's number), a **dead zone of 5% of travel** (≈1.5°) that holds
exactly `0` for sensor noise around neutral, and the existing EMA
(`smoothing 0.4`) before the mapping. The dead zone is the only threshold left,
it is at the centre only, and it compresses nothing at the ends: outside it, the
mapping is linear to the saturated ends. Smoothing means a step change of angle
converges over ~80 ms; a *held* angle converges to a held position, which is the
property in the Goal.

**Revised after playing it (2026-09-17):** saturation at **20°** — 30° is a
forearm movement, and steering should cost a wrist — and the dead zone becomes an
absolute **±0.5°**, not a share of the travel, so retuning the travel never
loosens the rest position. The one constant that is not in the app is snake's
turn threshold: it is expressed in axis units, so it moved to half the travel
(≈10° of phone) to keep the snake turning where it used to.

**D3 — sign convention, pinned in one place and verified on the probe.**
`MotionControl` reports canvas-convention axes: `posX` positive = the player
moves right, `posY` positive = the player moves down. Physically:

| gesture | result |
|---|---|
| right edge of the phone tips down (roll, `y > 0` today) | `posX > 0`, player right |
| left edge tips down | `posX < 0`, player left |
| the gesture that today reads `x > 0` and used to press `Up` | `posY < 0`, player up |

`posY = −position(pitch)` and `posX = +position(roll)` is the whole of it;
`motion_control_test.dart` pins both signs with synthetic gravity, and the probe
is the on-device reference (P7). This is a genuine inconsistency being fixed:
today `tiltYAxis` documents "positive Y is down" while `_up = _ud > engageZone`
(`motion_control.dart:65-70`) treats positive as up, and probe's dot maths
(`game_probe.c:132`) treats it as down again. Games see one convention when this
lands.

**D4 — discrete games own their discretisation.** Snake has no continuous
position (its state is a heading and a one-cell-per-step ring buffer), so it
takes the tilt *vector* and derives a heading: the component with the larger
magnitude, if it exceeds 30% of full travel (≈9°), becomes the requested
direction; the existing reverse-block and per-cell-step rules then apply
unchanged. That logic lives in the **game**, not the app, so it is deterministic,
replayable and testable — and it removes the last per-game special case from the
app (the tetris alias hack, D8).

**D5 — no protocol change.** Extra axes ride the existing frame (an i16 per
control) and the existing `:a` suffix. A per-control *semantic* token is
deliberately not added: gamekit has exactly one axis semantic (D1), and inventing
a second one before it exists is speculative surface. If a future control needs
rate semantics, that is when the token is added.

**D6 — older firmware is refused honestly, not shimmed.** A mirror whose game
declares no accelerometer axis (any firmware before this change) cannot be
steered positionally. Motion mode then reports "update the mirror's firmware for
tilt" and stays off the round, exactly as the pause path already refuses
pre-Pause firmware (`docs/games.md`, "Shipped BLE session protocol"). Manual
pads keep working. The timing this forces: a mirror states a game's controls
only in its `game ok` reply, so the app cannot know before starting whether a
round takes tilt. The check runs on that reply and the round drops to manual
with the message - the first moment the app can tell. The hysteresis code is deleted rather than kept as a
fallback: it is the behaviour being removed. The app bundles the matching
firmware and OTA is already wired, so this is a one-tap fix for the owner.

**D7 — the probe returns to the picker.** It is a selectable mode again, and the
separate "Controller diagnostic" button is deleted (one way in, not two). It
stays out of *defaults*: a fresh mirror round still starts on a scoring game
(`_mirrorPlayableSelection`), and the probe is never auto-picked.

**D8 — manual play is untouched.** Pads and keys keep driving the buttons at the
rates they always did; the alias table keeps renaming tetris's `Up`/`Down` to
Rotate/Soft drop in the UI. What disappears is tilt-as-buttons: with tilt always
driving axes, `_tiltDrivesVertical` and its alias-table dependency go away.

**D9 — the FFI grows exactly two entry points,** and loses one:
`ml_game_control_type(gi, ci)` so the app can stop sniffing labels, and
`ml_game_input(session, player_id, code, value)` replacing `ml_game_button`,
resolving the event type from the session's game table the way the firmware
does. `ML_CAP_ACCEL` on the new axes declares they are accelerometer-driven.

## Phase 1 — gamekit: the contract and the six games

### 1a. `gamekit/include/mirror/game.h`

Add, next to `ml_input_type`:

```c
/*
 * An ML_INPUT_AXIS value is an absolute position request inside the game's own
 * travel: 0 is the middle, +32767 and -32767 are the ends. ML_AXIS_IDLE is not
 * a position - it means the controller is not driving this axis at all (manual
 * controls are in use, or the round is paused), and the game must hold the
 * position it has rather than recentre.
 */
#define ML_AXIS_IDLE ((int16_t)-32768)

/* Whether a controller is driving this axis in the frame just received. */
static inline bool ml_axis_engaged(int16_t value) { return value != ML_AXIS_IDLE; }

/*
 * Centre-anchored, saturating map of an engaged axis into [lo, hi]: 0 is the
 * middle of the travel, the ends are exact. Integer only, so a replay on the
 * host and a tick on the ESP32 agree. Never call it with ML_AXIS_IDLE.
 */
static inline int32_t ml_axis_map(int16_t value, int32_t lo, int32_t hi)
{
    const int32_t span = hi - lo;
    const int32_t mid  = lo + span / 2;
    int32_t v = value;
    if (v >  32767) v =  32767;
    if (v < -32767) v = -32767;
    /* An odd travel is split the way its centre is: the leftover unit belongs
     * to the far side, so BOTH ends land exactly on lo and hi. */
    if (v >= 0) return mid + v * (span - span / 2) / 32767;
    return mid + v * (span / 2) / 32767;
}
```

`ml_axis_map` is the one implementation of the mapping rule; no game
re-derives it. `state_size`/snapshot changes below must not push any game's
serialized `snapshot` past 1020 bytes (`runtime.c:288` refuses above that, and
the largest game is already at 1018 — see `docs/improvement_backlog.md`, M12).

### 1b. Per game

Each game gains the axis control(s) its motion round needs, latches the value in
`input()`, and consumes it in `update()`. Buttons keep their existing meaning and
code numbers; new codes go after them, so existing code→index assumptions in the
Bluetooth frame stay true (the app writes the control index as the code).

| game | new control | mapping in `update()` |
|---|---|---|
| rally | `TiltY` code 2, `ML_CAP_ACCEL` | `y = ml_axis_map(v, 0, panel_h - ph)`; paddle `y` is written, and `paddle_v = y - previous_y` so the bounce spin term (rally.c:190) still sees the paddle's velocity |
| breakout | `TiltX` code 2 | `px = ml_axis_map(v, 0, panel_w - paddle_w)` |
| invaders | `TiltX` code 3 | `px = ml_axis_map(v, 0, panel_w - INV_SPRITE_W)`; `Shoot` stays a button |
| tetris | `TiltX` code 4 | target column for the piece's left edge, `tx = ml_axis_map(v, -3, bw - 1)` (the range `tetris_collide` treats as valid, tetris.c:70-83); step `px` one column per tick toward `tx`, and only when `!tetris_collide(...)` — a tilt may walk the piece but never teleport it through the stack, and the walk stops early at a wall or stack (bw/bh are already in state, tetris.c:33-34) |
| snake | `TiltX` code 4, `TiltY` code 5 | heading from the larger-magnitude component above 30% of full travel; `next_dir` is set, and the existing reverse block and cell step (snake.c:152-197) do the rest |
| probe | (already has `TiltX`/`TiltY`) | axes become positional: `x = ml_axis_map(v, r, panel_w - 1 - r)`, `y` likewise, `<< FX`; the button path applies only while the axis is idle, and the clamp uses the same bound so the whole circle stays on the panel |

Rules that apply to every game:

- Axis state is an `int16_t` field, initialised to `ML_AXIS_IDLE` in `init`/
  `reset`: a fresh round is not driven by tilt until the phone says something,
  and a manual round is never dragged to the centre of the travel by a stale
  axis value.
- The branch is per axis: `if (ml_axis_engaged(s->steer)) { positional } else
  { existing rate/discrete path }`. Axes and buttons therefore coexist in one
  frame, and switching between motion and manual mid-round continues from the
  current position instead of jumping.
- The new field joins `snapshot`/`restore`, so a display peer reproduces it.
- No floats, no allocation, no wall clock: the axis is just another input.

### 1c. Host tests — new `gamekit/host/motion_axis_test.c`

Add it to `TEST_BIN` in `gamekit/Makefile.host`. It drives sessions through the
FFI (like `held_input_test.c`) and asserts, per game:

- neutral axis (`0`) held for many ticks → the player sits at the centre of its
  travel and **does not move between ticks** (this is the regression test for
  the complaint: assert the position is byte-identical after 10 ticks at the
  same axis value);
- `+32767` → the positive end of the travel, `−32767` → the negative end, and
  the ends are exact (no off-by-one from the integer map);
- a half-travel value lands halfway (±1 unit of rounding), and the map is monotone
  across a sweep of values;
- `ML_AXIS_IDLE` after a positional frame → the player holds that position while
  the frame repeats, and the buttons still move it;
- for tetris: an axis aimed at a column behind the stack walks toward it and
  stops at the first collision (no teleport);
- for snake: a tilt vector under the dead zone never turns the snake, a strong
  one turns it once, and a 180° request is refused;
- a map unit test for `ml_axis_map` covering odd spans (e.g. `lo=0, hi=3`) and
  saturation past ±32767.

## Phase 2 — gamekit FFI

`gamekit/ffi/game_ffi.h` / `game_ffi.c`:

1. `int ml_game_control_type(int game_index, int control_index)` — returns the
   `ml_control_def.type`, so the app stops deciding "is this an axis?" from a
   hardcoded label set.
2. `void ml_game_input(ml_game_session *s, uint16_t player_id, uint16_t code,
   int16_t value)` replacing `ml_game_button`. It resolves the control's declared
   type from the session's game table and stamps the event type accordingly,
   coercing buttons to 0/1 and passing axes through raw — the same rule the
   firmware applies at `ble.c:824-825`, so a local round and a mirror round
   interpret one frame identically.
   `ml_game_button` is deleted rather than kept alongside; its callers are the
   three C tests (`host/game_ffi_test.c`, 22 calls; `host/tetris_input_test.c`,
   11; `host/held_input_test.c`, 4 — `host/game_cli.c` and
   `host/breakout_progression_test.c` do not use it) and
   `designer/lib/src/engine/game_bindings.dart:84` plus the `GameEngine.button`
   wrapper at `game_engine.dart:120-123`.

## Phase 3 — firmware

`firmware/main/games/game_runner.c` — an axis is never "released" by writing
zero, because zero is the centre of the travel:

1. `release_declared_controls` (178-196): synthesize `ML_AXIS_IDLE` for an
   `ML_INPUT_AXIS` control and `0` for a button, so pausing holds the paddle
   where it is instead of snapping it to centre on resume.
2. The `count == 0` "all released" expansion in `request_input_frame` (284-286):
   same per-type value.
3. `firmware/CMakeLists.txt`: bump `project(smart_mirror VERSION …)` to the next
   patch version (0.2.26 unless something newer landed) — the repo rule is one
   version per firmware change.
4. Rebuild and stage the bundled image (`tools/bundle_firmware.sh`, which the
   Android build already runs automatically, or
   `. $HOME/esp/esp-idf-v5.5/export.sh && tools/bundle_firmware.sh`). The app
   ships this image, and OTA is what an older mirror needs.

## Phase 4 — the app's tilt mapper (`designer/lib/src/services/motion_control.dart`)

Rewrite around one public idea: an angle becomes a position.

```dart
class MotionControl {
  MotionControl({
    this.calibrationSamples = 20,
    this.travel = 0.349066, // radians: 20 degrees saturates the travel (D2)
    this.deadZone = 0.008727, // radians: half a degree holds exactly zero
    this.smoothing = 0.4,   // EMA coefficient on the angle
  });

  /// The wire value for an axis nobody is driving (game.h: ML_AXIS_IDLE).
  static const int idle = -32768;

  int get posX; // canvas convention: positive = the player moves right
  int get posY; // canvas convention: positive = the player moves down
  bool get calibrated;
}
```

- Keep: neutral from `calibrationSamples` samples, the roll/pitch `_angle`
  geometry, the EMA, `calibrated`.
- Mapping per axis, on the filtered offset: dead zone → exactly `0`; then linear
  from the dead-zone edge to `travel`; clamp at the ends; scale to
  `[-32767, 32767]` with `posY = −position(pitch)`, `posX = +position(roll)` (D3).
- Delete: `up`, `down`, `left`, `right`, `engageZone`, `releaseZone`, `_dir`,
  the old `tiltXAxis`/`tiltYAxis` and the 0.5 rad saturation constant. Nothing
  else in the app uses them.
- Rewrite `designer/test/motion_control_test.dart`: neutral is `0`; 20° is
  `±32767` and 45° is still `±32767`; 15° is about three quarters (D2); half a
  degree is exactly `0` and one degree is just inside 1000; both physical signs
  (D3); a single sample does not jump the output; a *held* angle converges and
  stops (assert the value is identical across further samples once settled);
  `idle` is only ever sent by the screen, never produced by the mapper; before
  calibration both are `0`. Feed enough samples (~30) for the EMA to settle and
  compare with a tolerance.

## Phase 5 — the app's game screen (`designer/lib/src/ui/game_screen.dart`)

### 5a. One axis path, local and mirror

- Replace `_setMirrorAxis` with `_setAxis(String wire, int value)`: resolve the
  index from the **active** control surface (mirror `MirrorControl.isAxis`, local
  the FFI type accessor), so a local round drives axes too. Keep the 20 ms send
  throttle and the per-sample readout.
- The two send throttles already have separate timestamps - `_lastMirrorSendMs`
  for the 100 ms heartbeat (`_onTick`) and `_lastAxisSendMs` for the 20 ms axis
  throttle - so nothing needs changing there. (Checked while implementing: the
  earlier note that they shared one stamp was wrong.)
- `_onMotionSample` (2295-2339): delete the `_mirrorGame == null` early return and
  the whole direction branch. In motion mode, write `posX`/`posY` into whichever
  tilt axes the active round declares (`_tiltDrivesAxes` becomes "declares a
  `TiltX`/`TiltY` axis"); in manual mode, send nothing. Delete
  `_tiltDrivesVertical`, `_setTiltHeld` and `_TiltSource` if nothing else uses it.
- `_recomputeHeld` (1060-1074): buttons start at `0` and axis slots start at
  `MotionControl.idle`; `_axes` overlays the driven values. Opposing-direction
  neutralisation stays for buttons.
- `_sendLocalInput` (1101-1107): send `_held[i]` itself (the FFI now resolves the
  type), not `!= 0 ? 1 : 0`.
- Release paths: `_sendReleasePacket` (1235-1240) and `_sendLocalRelease`
  (1113-1120) send `idle` for axis slots and `0` for buttons, matching P3.
- `_tiltDrivesAxes` for a mirror round with no accelerometer axis → motion mode
  is refused with D6's message; on a local round the axes always exist (same
  build), so this only ever triggers against older firmware.

### 5b. Motion mode in the local preview

- Add the `mode-manual` / `mode-motion` radios to `_buildLocalSetup`
  (3070-3163) and to a local paused view, mirroring `_buildMirrorSetup`
  (3466-3483) and `_buildMirrorPaused` (3579-3595), including Recalibrate.
- `_startLocalGame` (780-806) gates on `_ensureMotionReady()` the way
  `_startMirrorGame` does; `_pauseLocalGame` (807-826) detaches the sensor after
  `_sendLocalRelease`; `_resumeLocalGame` (827-841) re-attaches it when the mode
  is motion, and so must the start itself: opening the round disposes the local
  session, which detaches the subscription the calibration was just reading.
  Without that re-attach a local motion round renders and steers nothing, which
  is exactly what it looked like the first time round. Keep the existing rules: an ordinary pause retains neutral, app
  suspension discards it, a sensor that never reports declines the start.
- `_buildLocalPlay` (3184-3230): in motion mode show the motion surface
  (`_buildMotionGamepad`, 3717-3782) alongside the panel preview instead of the
  movement pad, so the probe's dot is visible while it is steered.

### 5c. The probe back in the picker

- `_playableGames` (669-677): stop filtering it out; delete `_startProbe` (733),
  both `probe-diagnostic` buttons (local 3147-3156, mirror 3495-3503, the latter
  gated on the mirror's `game list` containing `probe`), and the
  `_mirrorPlayableIds` filter (691-699) — while keeping `_mirrorPlayableSelection`
  (its "first playable game" default) from ever auto-picking probe.
- `_gameCopy['probe']` (373-375): state what it is now — the dot follows the
  phone, so the tilt path can be seen and calibrated before a round matters.
- Update `designer/test/game_screen_test.dart` (picker contents) and the README
  text that says the probe lives behind its own button.

## Phase 6 — documentation

- `game.h`: the axis semantic and both helpers land with the doc comments above.
- `docs/games.md`: add the input-frame layout (it currently lives only in
  `ble.c:774-784` and `mirror_ble_game.dart:17-22`), the axis semantic and
  `ML_AXIS_IDLE`, the app's travel/dead-zone/EMA constants and the sign
  convention, and the rule for discrete games (D4).
- `designer/README.md` "Games": motion mode available in the local preview and
  on a mirror; the probe is the tilt visualiser and lives in the game list; a
  mirror older than this change must be updated for tilt.
- `firmware/README.md`: nothing new beyond the version rule already stated.

## Phase 7 — verification

Host, in this order:

```sh
make -C core -f Makefile.host test          # render core, unchanged
make -C gamekit -f Makefile.host check      # includes motion_axis_test
make -C core -f Makefile.host check         # fonts, bindings
cd designer && LD_LIBRARY_PATH=<lib dir> flutter test
```

The mapping itself can also be eyeballed without a phone: `game-cli` renders a
panel for a game, and the new host test drives a sweep of axis values and reads
the frames back, which is the cheapest way to see "neutral centred, ends exact,
monotone in between" before touching hardware.

One thing to know when testing the app: the send throttles compare wall-clock
timestamps (`DateTime.now()`), which do not advance with the test binding's fake
clock. Assert on *the set of frames* the screen sent after a phase, never on
"the last frame" - which frame is last depends on real elapsed time, and a test
that assumes otherwise goes flaky.

On the device (Pixel/Android, mirror over BLE, firmware flashed from the tree):

1. **Probe first — it is the visualiser and the sign reference.** Start it, and
   with the phone still the dot sits centred. Rolling the right edge down moves
   the dot right; the gesture that used to press Up moves it up. Tilting 20°
   reaches the edge, 15° about three quarters. Holding a tilt holds the dot: no
   drift, no spring back. The point of this pass is the feel: 20° is a wrist
   movement, and the dot must not shiver while the phone rests.
2. **Rally**: the paddle starts centred, follows the tilt, reaches the top and
   bottom of its travel at ±20°, and stays put when the phone is still. Bounce
   spin still responds to a fast sweep.
3. **Breakout / invaders**: the paddle/cannon follows the horizontal tilt, with
   the same hold-still-holds-position property.
4. **Tetris**: tilt walks the piece toward the target column and stops at the
   stack; Rotate and Soft drop still work as buttons.
5. **Snake**: tilt under ~5° never turns it, a deliberate tilt (about 10°) turns
   it once, it never reverses into itself.
6. **Pause/resume**: pause a rally round mid-tilt, resume — the paddle is where
   it was, not at the centre (this is P3's whole point). Suspending the app still
   requires recalibration.
7. **Manual mode**: pads and keys behave exactly as before, in every game.
8. **Older firmware**: point the new app at a mirror still running 0.2.25, select
   motion, and confirm the honest refusal rather than a silently dead round.

## Acceptance

- Rally's paddle position is a direct function of the phone's tilt: centred at
  the calibrated neutral, top/bottom of travel at ±20°, proportionally between,
  and constant while the angle is constant. Same for breakout and invaders
  horizontally, probe on both axes, tetris's column and snake's heading.
- No hysteresis remains in `motion_control.dart`, and no game reads a direction
  from tilt.
- The probe is selectable from the app's game list and is steerable by tilt in
  both the local preview and on a mirror.
- `make -C gamekit -f Makefile.host check` and `flutter test` pass; the new host
  test fails against the pre-change games (the "same axis, many ticks, position
  unchanged" assertion and the end-of-travel assertions).
- Firmware is bumped and the bundled image restaged; the app and the firmware in
  the tree agree.

## Out of scope

- Per-game or user-configurable sensitivity (the travel and dead zone are
  constants; a settings screen is a separate change).
- Rate/slider axis semantics, or any new wire token (D5).
- Multi-player tilt, touch input, and the LAN/peer architecture.
- The unrelated gamekit items in `docs/improvement_backlog.md` (M12, F5) beyond
  the two FFI entry points this plan needs.
- Reworking `game-cli --replay` (it compares nothing today, M12).
