# Mirror Designer

Device dashboard, layout designer and pixel-exact simulator for desktop and phone.

The app opens on **Devices**, without loading the native simulator or connecting
every remembered Bluetooth device. Tiles show actual framebuffer snapshots from
each mirror. Offline devices remain selectable, with a timestamped last-known
preview. Add devices through LAN discovery, a manual host and port, or an explicit
nearby Bluetooth scan. Android holds a multicast lock only during discovery.

Select a device for **Smart clock**, **Games**, **Picture display**, and device
settings. Opening its page or clock editor changes nothing on the panel. Actions
stay bound to that device; equal names do not merge identities. Legacy firmware
without a stable identity keeps separate LAN/Bluetooth records.
The device page keeps mode actions visible in compact cards; the info buttons
expand explanations without hiding connection or capability warnings. Landscape
and desktop windows place the preview beside its status and the modes in a row.

**Games** uses compact thumbnail-and-title tiles in both the device gamepad and
local simulator. Select a tile to see its description and controls once, beside
the picker in landscape or below it on a phone. **Start Game** stays in a fixed
footer, so extra games or larger text can scroll without hiding the action.
Screenshots are bundled for offline use; games from newer mirror firmware
remain selectable even when this app has no screenshot or instructions for them.
During motion play, the local board fits the available height and action buttons
and tilt readouts stay beside it rather than below a scrolling preview.

**Picture display** accepts one static PNG or JPEG (20 MiB / 40 million source
pixels maximum). After choosing a photo, **Crop / zoom** opens a frame locked to
the panel's aspect ratio. Pinch to zoom and drag to select the region; a zoom
slider and **Reset** are also available. **Use crop** applies the selection to
the pixel-exact framing preview; Back cancels without changing the picture.
The original photo is retained for subsequent edits. **Fit** preserves the
selected area with black bars; **Fill** covers the panel without stretching.
The framing preview is local and uncalibrated; the info icon explains framing
and color differences. Controls and previews use separate columns in landscape.
**Display on …** stays below the scrolling workspace, sends panel-sized RGB over
Wi-Fi and waits for persistence.
Saved pictures survive phone closure and mirror reboot. Selecting **Use smart
clock** retains the picture; **Show saved picture** restores it. Games temporarily
override either base display and restore it on Stop or Bluetooth disconnect.
Uploads and fresh previews require the phone and mirror on the same local network.

The app menu's **Layout designer / simulator** remains an explicitly local
workspace. Its preview uses the same C renderer as the ESP32 through `dart:ffi`.
Native-library failures affect that workspace, not home or picture upload.
The default clock editor places customization beside the preview in landscape;
on a phone the preview takes about a third of the available height, leaving
more room for layout and color choices. Small windows and large text retain
scrolling as a fallback rather than clipping controls.

## Setup

Flutter is required and is not bundled.

```sh
# 1. Install Flutter: https://docs.flutter.dev/get-started/install
# 2. On Fedora, the desktop build also needs:
sudo dnf install clang cmake ninja-build gtk3-devel pkgconf-pkg-config

# 3. Generate the platform build files and fetch packages
cd designer
./setup.sh                 # linux and android
./setup.sh linux,android,macos,windows,ios

# 4. Run
flutter run -d linux
flutter devices && flutter run -d <device-id>
```

### Phone installs: rebuild the APK explicitly

`flutter install -d <device-id>` can reuse a previously built
`build/app/outputs/flutter-apk/app-debug.apk` without recompiling Dart, so a
phone ends up running stale code. This happened 2026-08-16: a three-day-old
APK was installed and the new motion controls looked missing. Rebuild
explicitly, then install the fresh APK:

```sh
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

A stale build succeeds with no error, so there is no other signal. If in
doubt, check the APK timestamp postdates the last edit.

The app also bundles the firmware image for the normal OTA flow
(`assets/firmware/smart_mirror.bin`, version read from the image itself).
Every Android build refreshes that asset before packaging: the gradle task in
`tool/firmware_bundle.gradle` runs `tools/bundle_firmware.sh`, which rebuilds
the firmware with ESP-IDF whenever its sources changed. No manual staging
step remains to forget; a machine without ESP-IDF fails the build with an
explanation (opt out for one deliberate build with
`flutter build apk -PskipFirmwareBundle`).

That script also refuses to stage an image whose version the firmware tree does
not declare, and refuses to build at all when the sources changed without a
version bump (`tools/firmware_version.py`; see `firmware/README.md`,
Versioning). One version describes one image, so the version the mirror reports
after an OTA is evidence about exactly one build.

Opening a device page compares its reported version with the bundled image and
offers an update when it is older. The offer is once per `(device, version)` per
run; background tile polling never opens update dialogs. Declining is an answer,
and the next launch asks again. Current, newer, or unreadable versions are left
alone. Updates and reconnects stay bound to that device.

## Launching it without a terminal

`flutter run` is the development path, for hot reload and console output. To
just open the app, install a desktop launcher once:

```sh
./install-shortcut.sh --desktop
```

That adds **Mirror Designer** to the application grid, where it can be pinned,
and a double-clickable shortcut on the Desktop. Both run `run.sh`, which starts
the prebuilt release bundle. That bundle is self contained, so it opens in well
under a second and does not need Flutter on PATH.

`run.sh` rebuilds first, but only when the sources have really changed. It
hashes their contents: `.dart`, `.c` or `.h` under `lib/`,
`packages/mirror_core_ffi/` or the repository's `core/`, plus the stock
`layouts/*.json`, which are bundled as assets. Contents rather than timestamps,
because git rewrites mtimes on every checkout, rebase and pull, which used to
leave an untouched tree looking stale and rebuilding for nothing. An edit is
never silently missed, and an unchanged tree never pays for a build.

A rebuild started from the launcher opens a progress window. There is no
terminal to watch in that case, and a build that only wrote to a log file was
indistinguishable from a launcher that had done nothing at all.

| Want | Do |
|---|---|
| Launch, rebuilding only if sources changed | `./run.sh` |
| Never rebuild, fastest start | `MIRROR_NO_BUILD=1 ./run.sh` |
| Rebuild unconditionally | `MIRROR_FORCE_BUILD=1 ./run.sh` |
| Remove the launcher again | `./install-shortcut.sh --uninstall` |

The middle two are also on the launcher's right-click menu.

The launcher icon is a dedicated layout, `assets/icon.json`: a framed mirror
panel showing a clock and weather, rendered by the core rather than kept as a
raster. Linux renders it once per icon size, since a 5x7 glyph does not survive
resampling. Android ships committed PNGs at fixed densities that are not
multiples of the 64x64 canvas, so `tool/gen_icon.py` renders one 1024px master
and resamples it: the icon's display face is anti-aliased, so Lanczos stays
crisp where the hard pixel glyphs would not.

## Tests

```sh
flutter test          # handle geometry
```

The resize gesture tests additionally drive the real engine, which is built as
part of the app rather than by `flutter test`. They skip unless it is on the
library path:

```sh
flutter build linux --debug
LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test
```

`setup.sh` is safe to re-run and only fills in what is missing.

## How the native side is wired

```
designer/
  lib/src/engine/bindings.dart   hand-written dart:ffi declarations
  lib/src/engine/engine.dart     safe wrapper, owns the native handle
  packages/mirror_core_ffi/
    src/CMakeLists.txt           compiles ../../../../core in place
    pubspec.yaml                 declares ffiPlugin for each platform
    {android,linux,...}/         GENERATED by setup.sh, not committed
```

The C is compiled straight out of the repository's `core/` directory rather
than copied in. Two copies would drift, and the whole point is that the
designer and the panel run the same renderer.

Platform boilerplate (gradle files, podspecs, runner CMake) is version specific,
so `setup.sh` generates it with your installed Flutter instead of committing a
snapshot that goes stale.

## Why the FFI surface is so small

The engine takes JSON and returns pixels. That is nearly the whole API.

Binding `ml_layout` directly would mean replicating C struct layout and padding
in Dart, which breaks silently the first time a field is added to the middle of
a struct. Instead Dart owns editing (a few lines of `dart:convert`) and C owns
rendering, so the pixel-exactness guarantee survives while the binding stays
about thirty flat functions.

`LayoutWidget` keeps the raw decoded JSON map rather than a typed struct, so
keys this build does not recognise survive an open-edit-save cycle instead of
being silently dropped.

## What is deliberately not in the engine's pixels

Several things are drawn by the view layer, never by C:

**Selection outlines.** The moment editor chrome lands in the framebuffer the
preview stops being what the panel shows, and the shared-renderer design stops
being worth anything.

**LED emitters.** The panel is not a smooth display: each lit cell is a disc
smaller than the cell pitch, with dead space between pixels. That is purely a
presentation of the same frame, so the view draws it per cell from the frame
bytes rather than asking the engine for it.

**Wood veneer diffusion.** A veneer face over the matrix scatters each
emitter's light into the dead space around it. The view adds that as blurred
passes of the frame underneath the discs; the engine's pixels stay untouched.

Brightness is applied after gamma by the core. Actual device snapshots already
include brightness and physical orientation; the dashboard applies neither again.

**Panel orientation** is a device setting, not a preview trick. The Settings
screen's *Upside down* toggle pushes `flip180` over Bluetooth and reads the
mirror's value back when it connects, so what you design against is what an
upside-down panel shows. The panel rotates the frame at its own last step
before the shift registers; the view rotates the preview the same way,
including the pointer mapping, so a click still lands on the widget under the
cursor.

One more detail that matters: the image is drawn with `FilterQuality.none`. Any
smoothing turns a 5x7 glyph into grey mush.

## Picking a layout

Select **Edit clock** on a device to load its current LAN layout without sending
anything. If it cannot be downloaded, the workspace explicitly labels its local
draft and offers Retry. The local simulator never connects a remembered device.

In a device-bound workspace, **Layout** chips and the developer **Stock** menu
send the selected preset to that device. The simulator only previews the selection.
Sending a layout does not switch picture mode to clock; use **Use smart clock**
explicitly. (`src/services/layout_pusher.dart`.)

A push writes the layout to the mirror exactly as **Push layout** does, so the
preset the picker ends on is the one the mirror keeps; there is no separate
preview-only mode. Picks are allowed to outpace the radio, so they are queued:
one transfer at a time, and a pick made while one is in flight replaces any
other that is waiting, because only the layout picked last is worth showing.
Every push that goes out is reported - *Pushed weather*, or the mirror's own
reason when it refuses - and a pick that a newer one replaced says nothing.

The presets offered are filtered to the connected panel's size, so a pick is
always something the mirror can render.

## Games

Choose **Games** on a device page. Pairing confirms the Bluetooth device's hardware
identity before attaching it to the LAN record. Catalogue browsing is read-only;
**Start Game** runs the round on that mirror and turns the phone into its controller.
Missing or lost Bluetooth never starts a local substitute. Local **Preview**
games remain available only through the explicit simulator workspace.

Tilt is the controller. A round establishes neutral first, by having the phone
held still, and the angle it is then held at *is* the player's position, so a
held angle holds the player where they are. The app finds out whether the
device's accelerometer reports before it asks for any of that: a device without
one (a desktop, or a phone with no working sensor) goes to the on-screen pads
instead, says so once, and never spends a round waiting for a sensor that is not
there. Developer mode in Settings adds the choice between tilt and the pads, and
the panel size, display settings, tick count and latency that the default view
leaves out.

Choose Rally, Snake, Tetris, Breakout, Invaders, **Probe**, **Tilt Racer**,
**Cave Flyer**, **Maze Collector**, or **Target Gallery**, read its goal and
controls, then press **Start Game**. The ten compact tiles scroll while Start
Game stays pinned. This screen has one player; Rally is
solo against the computer. Probe is the tilt visualiser rather than a round: a
red dot that sits where the phone points, which is how you see what motion
control is doing - and how you check the sign of a tilt - before a round depends
on it. It is never picked for you: Start uses a game played for score.

| Input | Behavior |
|---|---|
| Direction pad / arrows / WASD | Declared movement controls; opposite directions cancel |
| Tilt (motion mode) | Position within the round's travel; a held angle holds the player |
| Tetris Rotate / Up / W | One rotation per press, not per repeated held packet |
| Tetris Soft drop / Down / S | Hold to fall faster |
| Invaders Shoot / Space | One shot per press; a bullet in the air never blocks the next |
| Invaders in motion mode | Tap anywhere in the play area to shoot; the Shoot pad works too |
| Gallery Shoot / Space | Hold to fire every eight ticks; consecutive hits build a score multiplier |
| Space at setup or after a round | Start / Play again; holding Space never restarts |
| P / Escape | Pause or Resume |

In Tetris's motion mode, Rotate fills the left side and Soft drop fills the
right side, with the local preview between them. Both touch areas extend almost
the full height of the play area; when controlling the mirror, each fills nearly
half the available width.

Pause retains the round. Returning from app suspension does not resume it.
Help and **Display & diagnostics** pause before opening and leave the round paused
when dismissed. The overflow menu contains Restart, Choose game, and diagnostics;
discarding a nonterminal round asks for confirmation. Finished rounds offer
**Play again** and **Choose game** without hiding the panel's result.

Diagnostics contains the local panel-size selector (before starting), veneer,
LED presentation, ticks, and mirror latency. Latency is polled only while open.
Controls remain at least 48 logical pixels; setup and paused content scroll.
An undersized play area pauses and asks for more space rather than clipping pads.

**Motion controls** are offered in the local preview and on a mirror. The phone
establishes neutral by averaging 20 samples (about 0.4 seconds) before the round
starts. Hold it comfortably: ordinary hand wobble is allowed, and the average
angle becomes the middle of the round's travel. A larger grip change or shake
restarts that short window at the new orientation instead of leaving calibration
stuck on the first samples. Sustained shaking still times out without starting
the game; motion mode stays selected for another try.
Cancel or Manual controls leaves setup usable. A sensor error, or two seconds
without samples, prevents starting in motion mode. While paused, switch
Manual/Motion or Recalibrate, then explicitly Resume. An ordinary pause retains
neutral; app suspension requires recalibration.

Tilt is a **position**, not a direction: 20 degrees from neutral reaches the end
of the travel, the middle is where the phone was held at the start, and a held
angle holds the player still. Half a degree either side of that middle is a dead
zone, so a resting hand does not shiver the player. So Rally's paddle sits centred at neutral and
follows the phone from there; Breakout's and Invaders' paddles follow the
horizontal tilt; Tetris's piece walks toward the column the phone points at and
stops at a wall or the stack (Rotate and Soft drop stay buttons); Snake, which is
a grid game with a heading rather than a coordinate, turns only on a deliberate
tilt. Invaders in motion mode takes its Shoot from the whole play area: a tap on
the board is a shot, and the Shoot pad is one of the places to find it. The pads
and keys are unchanged when Manual is selected, and switching modes mid-round
continues from wherever the player is.

Tilt Racer follows horizontal tilt to dodge traffic; Cave Flyer follows vertical
tilt without gravity, with three crashes ending either run. Full Cave tilt reaches
the walls: modest angles keep the ship in the opening. Target Gallery follows
both axes while Shoot remains a separate held action. Maze Collector uses
deliberate tilt to choose a passage, stops at neutral, and gives each of its three
key-collecting rounds 60 seconds. All four retain pad and keyboard fallback.

The angle is fused from the accelerometer **and the gyroscope**, so moving the
phone without tilting it no longer steers: the accelerometer alone reads the
hand's acceleration as gravity, which is what a sideways move used to be sent
as. The gyroscope carries the estimate through the movement and the
accelerometer keeps it from drifting, and neither is believed when the two
disagree by more than a few degrees. On a device with no gyroscope the round
still runs on the accelerometer alone — the surface says "accelerometer only"
and the app says so once on screen, because in that mode a brisk movement still
reads as tilt.

A mirror whose game declares no tilt axis - any firmware from before positional
motion - leaves the round on the pads and says so, rather than looking steered
while nothing moves. Games requests landscape-left orientation and restores the
app's orientation policy on exit.

Real mirror pause requires updated firmware. Older firmware rejects manual Pause
honestly; an automatic interruption or Help stops the game instead. A lost or
unacknowledged transition disconnects rather than guessing the remote state.
See [the game protocol](../docs/games.md#shipped-ble-session-protocol).

## Using it

| Action | How |
|---|---|
| Select a widget | Tap it on the canvas, or pick it from the list |
| Move it | Drag on the canvas, arrow keys, or type exact values |
| Nudge by 5 | Shift plus arrow key |
| Resize it | Drag any of the eight handles on the selection |
| Resize by key | Ctrl plus arrow key, or Ctrl and Shift for 5 |
| Undo / redo | Ctrl+Z, Ctrl+Shift+Z |
| Duplicate | Ctrl+D |
| Save | Ctrl+S |
| Reorder paint order | Drag the handle in the widget list |

The **Veneer** slider spreads each pixel's light into the gaps around it, the
way a wood veneer face over the matrix diffuses the emitters. Check small text
against the veneer thickness you plan to use: a stroke that reads as a
hairline through thick veneer needs a bolder font or a bigger box.

The LED toggle switches between the emitter view, discrete discs with dead
space, and the raw engine bitmap. The bitmap is the reference; the emitter
view is how the panel actually reads.

Resizing a box does not by itself make the text in it bigger: an explicit
**Scale** pins the text to that whole-pixel multiple. The pin only multiplies
the glyphs; it never changes which cut is in use. The engine picks the cut
for the box at 1x and the slider scales that face, so every step of the
slider draws the same style one multiple larger, clipping at the box edge
when the text outgrows the room. Turn on **Fit to box** and the box drives
instead: the engine derives the scale from the box, width and height, and
between whole multiples the glyphs anti-alias, so the text grows one panel
pixel at a time as you drag instead of jumping when the box crosses the next
multiple. Both are engine fields, so the preview and the panel agree on the
result rather than the designer approximating it.

While you drag, the inspector follows what the engine is actually drawing:
the Scale readout shows the derived figure as "Scale: 2.4 (fit)" instead of
the parked slider value, and the Font field names the cut in use under the
dropdown, "Drawing digits16". Both come from the engine on every refresh, so
the current state of the selected widget is visible without letting go of the
handle.

### Choosing a font

The inspector's **Font** dropdown lists font *families*, read from the engine
rather than from a list in Dart: `sans` and `digits`, both rasterized from
Open Sans in many sizes, plus the `wx` icon set kept to its own picker.
Choosing a family chooses a style; the engine chooses the size cut that fills
the widget's box. A layout that names an exact cut (`sans9`, `digits16`)
still pins it, and the dropdown shows such a value even though it is not a
family.

A box smaller than the named font steps down to a shorter cut of the same
family and stops at the family's shortest, clipped, so resizing never changes
the style, only the size. The search only leaves the family when no cut in it
can draw the string at all.

The catalogue is sourced from the engine through `ml_sim_family_name`, so
adding a `.font` to the repository's `fonts/`, running `tools/fontgen.py` and
rebuilding is all it takes for a new cut to join its family here. Smooth
families come from `tools/fontraster.py`, which renders a TTF into `.font`
art at each size. There is a test for the indirection in
`test/font_catalogue_test.dart`, because a break in it looks like a picker
quietly missing an entry rather than like an error.

The list includes the clock and icon fonts, which cover only digits or only
icons. Picking one for a body of text is not prevented, and does not need to
be: the preview is the real renderer, so the text visibly empties out the
moment you choose it. The **Icon set** dropdown is filtered separately, to
the icon role, which keeps the body fonts out of it.

The **Smoothing** control is a tri-state over the layout's `smooth` key. Auto
writes nothing and lets the font decide, which today means every text and
clock face anti-aliases between whole-pixel steps while the icon set keeps
hard pixels. Smooth and Blocky write the key and overrule the font in either
direction: a smoothed icon grows a fraction of a pixel at a time, a blocky
text face steps in whole-pixel multiples.

**Auto font** hands the size *and* style choice to the engine, which picks
whichever font fills the box best out of those that can render the string,
measured in the ink the string actually draws rather than in cell heights.
Drag a clock box wider with it on and the face changes, not just the size. It
is offered on text, clock, date and weather, and withheld from icons, agendas
and todos, where the engine ignores it. A switch that leaves the preview
unchanged is worse than no switch.

## Platform support

`dart:ffi` covers Android, iOS, Linux, macOS and Windows. It does **not** work
on Flutter web, which has no FFI. Supporting web would mean a second build of
the core through Emscripten to WebAssembly and a separate JS interop path.
Worth doing if a browser version is wanted; it is not needed for phone plus PC.
