# games: a framework for games on arbitrary size screens

The smart-mirror render core answers one question well: given a layout and some
data, what pixels go on the panel? It answers it portably and deterministically,
so the desktop preview and the ESP32 framebuffer agree byte for byte. A toy is
the harder twin of that question: given a shared game state and some player
inputs, what pixels go on the panel, *and what state comes next*, frame after
frame, on displays that range from a 64x32 clock to a 128x128 mirror, with one
player on a phone or several players on several phones?

This document is the design for `gamekit/`: the simulation and the architecture
for writing games that run on any of the project's panels today, without
hardware, and that reach a phone as a controller over the LAN. Firmware
integration is a later phase and is intentionally out of scope here. What is in
scope is the contract every game signs, the runtime that drives it, the
abstraction that makes any panel size work, and the multiplayer model that keeps
those properties honest when more than one player joins.

## The principle the framework inherits

The render core has one rule that nothing else is allowed to break: there is
exactly one renderer, it is portable C99 with no platform dependencies, and given
the same inputs it produces byte-identical pixels on the ESP32 and on the host.
That is the only reason the layout designer's preview can be trusted, and it is
enforced by a test that diffs the device's framebuffer against a host render.

Games add time and state to that picture, which is where most game frameworks
lose determinism without noticing. So the framework carries the same rule once
removed:

> A game frame is a pure function of game state and a view. Game state advances
> as a pure function of the previous state, the inputs, and a tick counter.
> Nothing the game touches reads a wall clock, floats the host way, allocates, or
> depends on the machine it runs on.

Concretely:

- **Fixed-timestep simulation.** The runtime advances the game in whole ticks of
  a game-chosen period (typically 33ms). Wall clock only governs *how many* ticks
  to run; it never enters the math. 30Hz and 60Hz panels therefore disagree only
  in draw rate, never in outcome.
- **Integer logic, integer randomness.** Positions and velocities are fixed-point
  integers (Q8.8 by convention), collisions are integer, and the PRNG is a
  seeded 32-bit xorshift owned by the runtime. The ESP32-S3 has no double-precision
  FPU and the host does, so as soon as a game does `sinf` in `update()` the two
  can drift. Fixed-point keeps `update` and `draw` byte-portable, which is what
  lets a golden-frame replay assert on host and mean something about the device.
- **No allocation in the loop.** Game state lives in a fixed POD arena the runtime
  hands out, sized by `state_size` in the vtable. The draw path draws into the
  existing `ml_canvas`, which never allocates unless asked. A game that mallocs in
  `update()` is a bug, caught by the host stress runner under a leak guard.
- **Time and randomness arrive through seams.** Just as widget rendering gets
  `now` from `ml_model` rather than `time()`, a game gets the tick counter and the
  PRNG from `ml_game_ctx`, never from the OS. `ml_model` is also passed through,
  read-only, so a game can theme itself on real weather or the clock the same way
  a widget does, without ever being able to tell firmware from simulator.

The payoff is the same as for layouts: a recorded input stream, replayed on the
host, reproduces the exact frames the device would show, and a multi-player
session reduces (for simulation and test) to a deterministic function of a seed
and a script.

## What a game is: the vtable

A game is a single C translation unit exporting one constant of type
`ml_game_vt` (see `gamekit/include/mirror/game.h`). It never links against the
runtime; the runtime links against it. That inversion is deliberate: the firmware
links only the games it ships, and the host links whatever it wants to test, and
neither has to know the other's set.

```
const ml_game_vt ml_game_rally = {
    .id        = "rally",
    .pref_w    = 0, .pref_h = 0,        /* 0 means adaptive */
    .fit       = ML_FIT_ADAPTIVE,
    .tick_ms   = 33,
    .max_players = 2,
    .state_size  = sizeof(rally_state),
    .controls    = rally_controls,
    .init   = rally_init,
    .reset  = rally_reset,
    .join   = rally_join,
    .input  = rally_input,
    .update = rally_update,
    .draw   = rally_draw,
    .snapshot = rally_snapshot,
    .restore  = rally_restore,
};
```

The callbacks split cleanly along the determinism rule:

| Callback | Reads | Writes | Called by | Must be |
|---|---|---|---|---|
| `init` | cfg, ctx | state | once at load | deterministic given seed |
| `reset` | seed, ctx | state | on (re)start | deterministic |
| `join` / `leave` | player caps | state | on net events | deterministic |
| `input` | one event, ctx | state | on net input | deterministic |
| `update` | state, tick, ctx | state | each tick (host) | deterministic |
| `draw` | state, view, canvas, ctx | canvas | each frame, every peer | pure |
| `snapshot` | state | byte buffer | host, periodically | canonical, compact |
| `restore` | byte buffer | state | peer, on packet | inverse of snapshot |

`update` runs on exactly one machine per session: the authoritative host. `draw`
runs everywhere: on the host (which is also a display) and on every peer. Peers
never call `update`; they render snapshots and interpolate only with deterministic
integer easing if they want smoother motion. This keeps a peer from ever deciding
game truth and so keeps the simulation single-source even across a LAN.

## The runtime drives the loop

`gamekit/src/runtime.c` owns the loop and the services games reach for through
`ml_game_ctx`. There is one host build of it (used by the CLI and tests) and the
firmware will get the same source later. Its responsibilities:

1. **Tick pacing.** Accumulate wall-clock delta, step `update` in fixed
   `tick_ms` increments, cap the catch-up at a few ticks to avoid spiral-of-death
   on a stalled peer, then `draw` once. On the host the wall clock is real; on
   the device it is the same `xTaskGetTickCount` the panel already uses.
2. **The PRNG.** `ml_ctx_rng(ctx)` returns the next xorshift32 value. Seeded once
   per session from the host's `ml_rand_seed`, agreed across peers in the hello
   handshake so a peer that ever needs to predict uses the same stream.
3. **Input routing.** The net layer hands framed input events to the runtime,
   which delivers them to `game->input` tagged with the tick they apply to, in
   order, before the matching `update`. Late inputs are queued for the next tick
   rather than dropped, so a 50ms jitter over WiFi cannot desync a deterministic
   game; it can only add a frame of latency.
4. **Snapshot broadcast.** Every N ticks the host calls `game->snapshot` and the
   runtime frames and ships the bytes to every peer. N is small enough that a
   peer rejoined mid-match sees the board within a frame, and the buffer is capped
   (`ML_SNAPSHOT_MAX`) so a game cannot wedge a peer by serializing the world.
5. **The view.** Before each `draw`, the runtime computes an `ml_view` from the
   game's preferred size, the physical canvas, and the fit mode, and passes it in.
   The game draws in its own coordinate space; the view is the bridge to whatever
   panel it actually lives on. (See below.)
6. **Recording and replay.** Every input event and every seed is appended to a
   journal. `--replay` re-feeds the same stream into a fresh runtime from the same
   seed and asserts frame hashes match. This is the game-side analogue of the
   render core's golden-image diff: a pinned input script is a test.

`ml_game_ctx` is the runtime's handle back to the game. It is deliberately small
and deliberately read-mostly: the only state it exposes that can change a frame is
the tick counter (fixed), the PRNG (deterministic), the read-only `ml_model`, and
emit hooks for sound and discrete game events. A game cannot, through `ctx`,
touch the network, the filesystem, or another peer's state. That is what keeps a
game portable onto a firmware that has none of those.

## Arbitrary size: the view

The project already supports 64x32, 64x64, 128x64 and 128x128 from the same
firmware, because geometry is a config value, not compiled in. Games must do the
same: the same game binary must play on the tiny clock and the big mirror without
a rebuild. The `ml_view` is how.

A game declares a preferred logical size and a fit mode. The runtime fits the
logical space into the physical canvas:

| `ml_fit_mode` | Meaning | Use when |
|---|---|---|
| `ML_FIT_ADAPTIVE` | The game reads the physical size and lays itself out. `pref` is 0. | The game is panel-shaped (clock faces, full-field games). Default. |
| `ML_FIT_LETTERBOX` | The game renders at `pref`, the runtime integer-upscales to the largest multiple that fits and centers it, painting margins with the layout background. | Pixel art authored at one size that must stay crisp. |
| `ML_FIT_STRETCH` | As letterbox but non-integer, blurring pixels. | Avoid on LED matrices; present only so a game can opt in knowingly. |
| `ML_FIT_CLIP` | Render `pref` in the top-left, clip the overflow. | A scroll designed to spill off the edge. |

`ML_FIT_ADAPTIVE` is the default and the one the example uses, because most games
on these panels are full-field (a play area that *is* the panel) and adapt better
by branching on width than by scaling. `ML_FIT_LETTERBOX` keeps authoring at a
canonical size cheap: integer-nearest upscaling of bitmap art stays sharp, and
the same offscreen logical canvas can be diffed against a golden image regardless
of physical size. `ML_FIT_STRETCH` exists only so a game can choose it; nothing in
the runtime selects it by default, because a blurred pixel is exactly the kind of
defect the preview should expose rather than hide.

The view also carries the active rectangle and the integer scale, so `draw` can
(always) just draw into the canvas the runtime hands it and let the translation,
scaling and clipping happen once, at the boundary, not scattered through game
code. A game never divides by the physical size inside its own math; it asks the
view, or it was authored adaptive and reads the canvas directly.

## Players and input: phones are the controllers

A mirror is a wall device with no usable local touch, and a clock even more so.
So input comes from the thing the player already holds: a phone. The framework
treats the phone as a controller and the mirror as the display, and lets the same
phone be both (a one-player handheld game on a clock).

An input is one `ml_input_event`:

```
typedef struct {
    uint16_t player_id;     /* assigned by the host at join */
    uint16_t seq;           /* per-player sequence, rejects repeated and stale */
    uint16_t code;          /* ML_INPUT_* game-defined control code */
    int16_t  value;         /* 0/1 for buttons, -32768..32767 for axes */
    uint32_t tick;          /* the host tick this applies to */
} ml_input_event;
```

Input is discrete and timestamped at the host tick, not the controller. The phone
records the device-local time it sent the event; the host stamps it with the tick
of the next update, and the `seq + tick` pair is what lets the host reject a
repeated or out-of-order packet over a flaky link without ever trusting the
controller's clock.

A game declares its controls as a static array (`ml_control_def`) of buttons,
D-pads, joysticks or sliders, each with a `code` and a cap bitmask. The phone
controller client renders exactly those controls and nothing else, which is how a
clock game with one button and a mirror game with a steering joystick share one
client. The cap also lets the host refuse a join from a controller that cannot
provide what the game needs (most firmly: a touch-only phone into a game that
needs an accelerometer), and swap players into roles each can actually play.

### How many players

One player is the floor; the example targets two because that is the smallest
nontrivial case and the one that forces the networking to be honest. The design
scales past it for free up to `max_players`, with these consequences:

- **One player, one display.** The mirror is the display, one phone is the
  controller, the mirror is also the host. Lowest latency, simplest session. This
  is what a clock game is.
- **Two to N players, one shared display.** The mirror is the sole display and the
  host; every phone is a controller. This is a party game on the wall. The shared
  display is why the host is authoritative: there is exactly one source of truth
  and exactly one screen to keep honest.
- **A device as both controller and display** (a clock you hold and play). The
  same runtime, the host running locally on the device, the controller surface
  rendered beside the game. No second peer needed; the loopback transport handles
  it without ever touching the radio.

### Bluetooth or WiFi

Both, behind one interface, chosen by the session not by the game:

- **WiFi is the default for more than one player.** The mirror is already on WiFi
  for weather, it has the bandwidth for snapshot broadcasts, and several phones
  join with no pairing ceremony: discovery is mDNS/Bonjour, control is a small
  UDP flow, and a snapshot fits comfortably in a few packets. Two or more players
  is what WiFi is here for.
- **Bluetooth (BLE) is the default for exactly one player and for pairing.** A
  single phone, a single mirror, no router needed: BLE GATT is enough for one
  controller's input stream and keeps the bar to a working game as low as a
  clock. Pairing over BLE also hands the phone the WiFi credentials, the same
  way the project will provision the mirror, so BLE is the on-ramp even when the
  game itself runs over WiFi.

The game never chooses and never knows. Transports implement `ml_net` (next); the
session picks one at hello time from what both ends advertise. For simulation,
neither radio exists: the in-process loopback bus is the transport, which is how
multiplayer is tested and replayed today without a single byte on the air.

## Networking: one authoritative host, snapshots for the rest

The session has one authoritative host. A host may also be a display (the mirror)
or may be headless (a phone hosting while the mirror shows). Everything else is a
peer in one of two roles:

- **Controller**: sends `input` events, renders its own control surface, receives
  lightweight game events for haptics and sound. Does not render the board.
- **Replica/display**: receives `snapshot` packets, calls `game->restore`, then
  `game->draw`. May also be a controller (phone showing a scoreboard while
  controlling). Never simulates.

Diagrams help only long enough to fix the direction of truth:

```
 phones (controllers)                  mirror (host + display)
   |  input events                            |
   +----------------------------------------->|  game->input -> update -> snapshot
   |                                          |  game->draw (local canvas) -> panel
   |  snapshot / events                       |
   +<-----------------------------------------+  (also to replica displays)
```

Truth flows one way. A peer that wants to render at lower latency than the
snapshot rate may run a *deterministic replica*: apply the same inputs to the same
restored state locally and `draw` that, snapping back to the host snapshot when one
arrives. The framework supports this because it kept `update` deterministic, but
it does not require it: a plain replica that just draws snapshots is correct and
cheaper and is what the example peer uses.

### The wire is small and fixed

Frames are compact and fixed-layout so an ESP32 can parse them without a JSON
reader, and so a peer can resync from any one packet:

| Frame | Direction | Carries |
|---|---|---|
| `ML_NET_HELLO` | controller/display -> host | role, device caps, transport list, controller caps |
| `ML_NET_WELCOME` | host -> peer | assigned `player_id`, session seed, tick origin, view hint |
| `ML_NET_INPUT` | controller -> host | one `ml_input_event` |
| `ML_NET_SNAPSHOT` | host -> replicas | tick, `game->snapshot` bytes, ack tag |
| `ML_NET_EVENT` | host -> peers | game-defined discrete events (score, spawn, death) for sfx/haptics |
| `ML_NET_BYE` | either | graceful leave |

`ML_SNAPSHOT_MAX` bounds the payload; a game that exceeds it serializes a delta
instead of the whole state, which the runtime supports by letting `snapshot` read
the previous-sent hash. Late join is just `WELCOME` then the next `SNAPSHOT`, so a
phone joining mid-match sees the board within one snapshot interval, never needing
the whole history.

## The simulation, today

Firmware is deferred, but the simulation is the load-bearing part: it is what
proves the architecture before any hardware is bought, and what keeps proving it
as games are written. `gamekit/` is host-only for now, built by the same plain
make-and-gcc rule as the render core, linking only `core/` for `ml_canvas`,
`ml_color`, `ml_font` and the read-only `ml_model`.

### Layout

```
gamekit/
  include/mirror/
    game.h        the vtable, ctx, view, input, control defs (the contract)
    gamerun.h     the host runtime loop API
    gamenet.h     the transport abstraction + loopback
  src/
    view.c        ml_view fit (adaptive / letterbox / stretch / clip)
    runtime.c     fixed-timestep loop, rng, ctx services, journal, replay
    net_loopback.c   in-process message bus (the only transport for now)
    shapes.c      sprite blit + integer scaler + helpers over ml_canvas
  host/
    game_cli.c    run a game: PNG/ASCII frames, size sweep, replay, N clients
  examples/
    rally/        a two-player paddle game that adapts to any panel size
```

### `game-cli`

The harness mirrors `mirror-cli` deliberately, so the feedback loop is the one
the project already knows. From a single command it can:

- run a game to a PNG frame (`-o`), a `--panel WxH` for any supported size, an
  `-s` pixel scale and `--led`/`--mirror` exactly as the layout CLI does;
- sweep a list of panel sizes in one run, writing one frame per size, which is
  the arbitrary-size guarantee made visible (`--sizes 64x32,128x128`);
- spin up N in-process clients over the loopback bus (`--players 2`) and feed them
  a recorded input script, proving the multiplayer path with zero radios;
- `--replay <journal>` a pinned input stream and `--check <hash>` the resulting
  frame, so a game ships a golden frame exactly the way the render core ships a
  golden image;
- `--record <journal>` capture a live keyboard session as a deterministic script
  for later replay, since a human on the keyboard is the cheapest "phone".

What it deliberately does *not* do yet is open a window. A live GLFW view is an
obvious next phase, but the PNG/ASCII path is enough to prove determinism and
arbitrary sizing, and it keeps the build at "nothing but gcc", which is the same
promise the host core makes.

### Why the example is a two-player rally

Pong-and-friends is the smallest game that is honest about both of the things
this framework exists to solve: the board must fit any panel (adaptive view), and
two players must share one host (multiplayer). The example `rally` gives each
player a paddle on opposing walls, a ball in integer fixed-point physics, and a
score drawn with the existing bitmap fonts. It runs on 64x32, 128x64 and 128x128
from the same binary by reading the canvas size, and it runs single-player (left
paddle static, right paddle human) and two-player (two keyboard mappings over the
loopback bus) from the same binary. It is small enough to read in one sitting and
is the reference for every vtable callback.

## Phases (firmware deliberately last)

| Phase | Builds | Proves |
|---|---|---|
| **G0 (now)** | `gamekit` headers, deterministic runtime, view, loopback net, `game-cli`, `rally` example | the contract, arbitrary sizing, multiplayer, golden-frame replay, all host-only |
| **G1** | live GLFW window for `game-cli`, recorded scripts as tests, sound/haptic event stub forwarded to a synth | fast authoring loop, deterministic test fixtures |
| **G2** | phone controller reference client (Flutter, reusing the designer's FFI to `core`) | a real controller on a real phone, over loopback first then LAN |
| **G3** | WiFi transport (`ml_net` over mDNS+UDP) and the session/host handshake on device | real multiplayer on the LAN |
| **G4** | BLE transport for one-player and provisioning | single-phone games, onboarding |
| **G5 (firmware)** | the `gamekit` runtime as an ESP-IDF component on the S3, the same `update`/`draw` called from the panel task, OTA of games as data | the guarantee: same frames on device as on host |

G5 is last because everything G0 through G4 does is making the claim that G5 is a
port, not a rewrite. If G5 ever needs the game to know it is on a device, the
determinism rule broke earlier and the framework failed.