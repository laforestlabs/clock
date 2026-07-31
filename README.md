# smart-mirror

A two-way mirror with a HUB75 RGB LED matrix behind it, driven by an ESP32-S3 over
WiFi, showing time, weather, calendar and todos. The layout is user-configurable and
designed in a desktop GUI that previews it exactly.

## The idea that shapes the architecture

A layout designer is only useful if its preview is trustworthy. If the simulator and
the firmware are two separate renderers, they drift, and the preview quietly stops
predicting what the panel shows.

So there is exactly one renderer. It is portable C99 with no platform dependencies,
and it gets compiled twice: once into the ESP32 firmware, once into a host shared
library that the desktop GUI calls. Layout is data (JSON), never code, so it can be
pushed to a running mirror over the LAN without a reflash.

```
             layout.json  +  ml_model
                        |
                  ml_render()          <-- one implementation, core/
                  /            \
        firmware (ESP32-S3)   libmirrorcore.so
              |                      |
        HUB75 panel            PySide6 designer
```

The seam is `ml_model` in `core/include/mirror/model.h`. The firmware fills it from
network providers; the designer fills it from `ml_model_mock()`. Rendering cannot tell
the difference. A test diffs the device's real framebuffer against a host render of the
same inputs, which is what keeps the two honest.

## Status

**Milestone 0 is complete: the render core, host build and CLI harness.** No hardware
is needed to run any of it today.

| Milestone | State |
|---|---|
| M0 Core, host build, CLI, golden tests | Done |
| M1 Flutter layout designer (desktop and mobile) | Done, builds and runs on Linux |
| M2 Panel bring-up on ESP32-S3 | Firmware written, awaiting hardware |
| M3 Data providers | Weather done; todos pending, calendar deferred |
| M4 Hot-reload layout push | Not started |
| M5 Provisioning, brightness, OTA | Not started |

There is no companion service. Weather comes straight from Open-Meteo, which
needs no API key. Calendar was deferred rather than solved with a helper box,
because expanding ICS recurrence rules is impractical on an MCU and the helper
would need a machine that is always on. The route back is Google Calendar's
`singleEvents=true`, which expands recurrences server-side.

The designer is Flutter rather than a desktop-only toolkit so the same app runs
on a phone and on a PC. It calls the C core through `dart:ffi`, which covers
Android, iOS, Linux, macOS and Windows. Flutter web is the one target it cannot
reach, since web has no FFI; that would need a second build of the core through
Emscripten.

## Quick start

Nothing but `gcc` and `python3` is required. ESP-IDF is not needed for the host side.

```sh
make -C core -f Makefile.host          # build libmirrorcore.{a,so} and mirror-cli
make -C core -f Makefile.host test     # 148 checks including golden images

mkdir -p out
./core/build/host/mirror-cli layouts/mini.json --all -s 8 --led
```

That writes `out/mini-{typical,cold,overflow,evening}.png`, the default 64x32 clock and
weather layout. Swap in `single`, `dual` or `quad` for the larger canvases. Useful flags:

| Flag | Effect |
|---|---|
| `-m <variant>` | Mock data: `typical`, `cold`, `overflow`, `evening` |
| `--all` | Render every variant |
| `-s <n>` | Pixel scale, default 6 |
| `--led` | Draw inter-pixel gaps so it reads as discrete LEDs |
| `--mirror <pct>` | Simulate two-way mirror transmission, e.g. `--mirror 20` |
| `--ascii` | Print to the terminal as well |
| `--dump <path>` | Raw RGB888 bytes, for diffing against the device |

`--mirror` is the one to use before buying glass. Two-way mirror film passes roughly 10
to 30 percent of light, and text that is crisp at full brightness can be unreadable
through it.

The four mock variants exist to exercise the paths that break in the field:
`cold` is a freshly booted mirror with no data yet, so every placeholder shows;
`overflow` has deliberately overlong calendar titles and sub-zero temperatures.

## Layout schema

```json
{
  "canvas": { "width": 128, "height": 64 },
  "background": "#000000",
  "brightness": 200,
  "widgets": [
    { "type": "clock", "rect": [0, 0, 62, 17],
      "font": "digits16", "format": "%H:%M",
      "color": "#00E5FF", "align": "center" },

    { "type": "text", "rect": [20, 32, 42, 7],
      "bind": "weather.temp_c", "format": "%.0f°C" },

    { "type": "date", "rect": [0, 40, 64, 21],
      "fit": true },

    { "type": "agenda", "rect": [66, 9, 62, 26],
      "max_items": 3, "show_time": true, "accent": "#66D9EF" }
  ]
}
```

Widget types: `rect`, `line`, `text`, `clock`, `date`, `weather`, `icon`, `agenda`, `todo`.

Bindings are dotted paths into the model: `weather.temp_c`, `weather.label`,
`weather.code`, `now.hour`, `system.rssi`, `counts.events`, and so on. See
`ml_model_lookup()` in `core/src/model.c` for the full set.

### Sizing text

Bitmap glyphs have no in-between sizes, so text grows by whole-pixel
replication: `"scale": 3` draws every glyph pixel as a 3x3 block. Scale is
capped at 8 and defaults to 1, so any layout written before it existed renders
byte for byte as it always did.

`"fit": true` derives the scale from the box instead, picking the largest whole
multiple of the font that still fits the widget's height. That is what makes
dragging a widget taller in the designer grow the text inside it. It overrides
`scale` when both are set.

Neither replaces choosing a font. `fit` scales the font the widget names, so a
`tom5x7` clock stays chunky at 4x where `digits16` would be smoother; and a box
too short for even one unscaled row still falls back to a smaller font, as it
always has.

Two rules worth knowing:

- **Unknown widget types are skipped with a warning, never rejected.** A newer designer
  must not be able to brick an older mirror by pushing a layout it does not fully
  understand.
- **`format` strings never reach a variadic formatter.** They are parsed by hand in
  `core/src/render.c`, because layouts arrive over the network and a stray `%s` against
  a double would otherwise be a remote crash.

## Fonts

Fonts are authored as readable pixel art in `fonts/*.font` and compiled to C tables by
`tools/fontgen.py`. Edit the art, not the generated tables.

```sh
python3 tools/fontgen.py                    # regenerate core/src/fonts/
python3 tools/fontgen.py --check            # fail if the tables are stale
python3 tools/fontproof.py tom5x7 "Wed 29 Jul"   # see it in the terminal
```

| Font | Size | Contents |
|---|---|---|
| `tom5x7` | 7px cell, proportional | Full printable ASCII, plus a degree sign at codepoint 127. The default body font |
| `bold5x7` | 7px cell, proportional | The same set with 2px stems, for legibility through the glass |
| `tiny4x6` | 6px cell, proportional | The same set at 3px caps, for dense rows |
| `digits10` | 6x10 | `- . /` and `0-9 :`, a clock for the 64x32 panel |
| `digits16` | 10x16 | The same set, the clock for a 64px-tall panel |
| `digits32` | 20x32 | The same set again, for a 128x128 build |
| `wx16` | 16x16 | Ten weather icons, indexed by category |

Total glyph data is about 3.9 KB, of which `digits32` alone is 1.2 KB. Drop a font you
do not use and it stops being compiled in: the build discovers `core/src/fonts/*.c`
rather than listing them.

The three body fonts share a codepoint range and a degree sign, so a widget can swap
between them without a layout changing. They are not interchangeable in width, though.
The same string "Standup 10:00 Design" measures **73px** in `tiny4x6`, **94px** in
`tom5x7` and **123px** in `bold5x7`, so switching to bold can push a line into
truncation that previously fit.

Which to reach for:

- **`tom5x7`** unless there is a reason not to.
- **`bold5x7`** when the mirror is the problem. Two-way film passes 10 to 30 percent of
  the light, and a 1px stem is the first thing it takes. Check with `--mirror 20`.
- **`tiny4x6`** when the rows are the problem, typically an agenda on the 64x32 panel.
  Its counters are one pixel wide, so it is the worst of the three behind dark glass.

`tom5x7` is proportional, which recovers several characters per line versus a fixed
cell: "Standup 10:00" is 63px, so it fits a 64px column with a pixel to spare.

The clock faces exist so the time can suit the panel rather than the panel suiting the
time. "09:41" is 30px in `digits10`, 52px in `digits16` and 104px in `digits32`. All
three keep the placeholder `--:--` exactly as wide as a real time, so nothing reflows
when the first SNTP sync lands.

Tall glyphs are written as a block rather than one long line, which is the same data
laid out so it can be read:

```
48
  |......########......|
  |....############....|
```

## Firmware

```sh
. $HOME/esp/esp-idf-v5.5/export.sh
idf.py -C firmware set-target esp32s3
idf.py -C firmware menuconfig        # Smart Mirror menu: WiFi, timezone, panel
idf.py -C firmware flash monitor
```

See [firmware/README.md](firmware/README.md) for the bring-up checklist, which is
worth following in order.

**ESP-IDF 5.4 or newer is required.** `esp-hub75` sets two GDMA fields behind a
`#if ESP_IDF_VERSION >= 5.0.0` guard, but both were only added in 5.4, so it cannot
compile on 5.0 through 5.3. Upstream CI covers 4.4.8, 5.5.2 and 6.0 and skips that
range entirely, which is why it has gone unnoticed.

## Hardware

See [docs/hardware.md](docs/hardware.md) for the full pin map and power notes. The short
version:

- **ESP32-S3 N16R8.** Note that octal PSRAM consumes GPIO33 to GPIO37, so the pinout in
  the `esp-hub75` README does not work on this module.
- **Waveshare RGB-Matrix-P2.5-64x32**, 160x80mm, 1/16 scan. Four address lines, so the
  E line is not wired. A 64x64 panel is 1/32 scan and does need it.
- **Power: roughly 2A for the default panel**, so a 5V 4A supply is comfortable. Two
  64x64 panels instead is 40W worst case and wants a 5V 10A supply, with power injected
  into each panel separately.

## Repository layout

```
core/       portable C99 render engine. No platform dependencies. The contract.
  include/mirror/   public headers
  src/              canvas, fonts, json, layout, model, render, mock
  src/fonts/        GENERATED glyph tables
  ffi/              narrow JSON-in-pixels-out facade for the designer
  host/             host-only: PNG writer and the CLI harness
  test/             unit tests and golden-image regression tests
fonts/      editable ASCII-art font sources
layouts/    stock layouts for 64x32 (the default), 64x64, 128x64 and 128x128
tools/      fontgen, fontproof, gamma table generator
docs/       hardware notes
firmware/   ESP-IDF application: panel, wifi, clock, data providers
designer/   Flutter layout designer, desktop and mobile
```

## Designer

```sh
cd designer
./setup.sh              # generates platform build files, needs Flutter
flutter run -d linux

./install-shortcut.sh --desktop   # optional, adds a launcher and a Desktop shortcut
```

See [designer/README.md](designer/README.md). The short version of how it stays
honest: the app renders through the same `core/` C compiled for the host, so
the preview is the panel. Selection outlines and two-way-mirror dimming are
drawn by the view layer and never enter the engine's framebuffer, because the
moment editor chrome lands in those pixels the preview stops being trustworthy.

## Testing

```sh
make -C core -f Makefile.host test
```

Golden tests hash the exact gamma-corrected RGB888 bytes the panel would receive, across
three layouts and four mock variants. Any change to glyphs, gamma, parsing or widget
drawing is caught. On a mismatch the actual frame is written to `out/<key>-actual.png`
so the difference can be looked at rather than argued about.

After an intentional rendering change:

```sh
MIRROR_UPDATE_GOLDEN=1 make -C core -f Makefile.host test
```
