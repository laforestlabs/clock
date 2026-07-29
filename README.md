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
| M1 PySide6 layout designer | Not started |
| M2 Panel bring-up on ESP32-S3 | Not started |
| M3 Data providers and calendar companion | Not started |
| M4 Hot-reload layout push | Not started |
| M5 Provisioning, brightness, OTA | Not started |

## Quick start

Nothing but `gcc` and `python3` is required. ESP-IDF is not needed for the host side.

```sh
make -C core -f Makefile.host          # build libmirrorcore.{a,so} and mirror-cli
make -C core -f Makefile.host test     # 81 checks including golden images

mkdir -p out
./core/build/host/mirror-cli layouts/dual.json --all -s 8 --led
```

That writes `out/dual-{typical,cold,overflow,evening}.png`. Useful flags:

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

    { "type": "agenda", "rect": [66, 9, 62, 26],
      "max_items": 3, "show_time": true, "accent": "#66D9EF" }
  ]
}
```

Widget types: `rect`, `line`, `text`, `clock`, `date`, `weather`, `icon`, `agenda`, `todo`.

Bindings are dotted paths into the model: `weather.temp_c`, `weather.label`,
`weather.code`, `now.hour`, `system.rssi`, `counts.events`, and so on. See
`ml_model_lookup()` in `core/src/model.c` for the full set.

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
| `tom5x7` | 7px cell, proportional | Full printable ASCII, plus a degree sign at codepoint 127 |
| `digits16` | 10x16 | `- . /` and `0-9 :`, for the clock |
| `wx16` | 16x16 | Ten weather icons, indexed by category |

Total font data is about 1.4 KB. `tom5x7` is proportional, which recovers several
characters per line versus a fixed cell: "Standup 10:00" is 63px, so it fits a 64px
column with a pixel to spare.

## Hardware

See [docs/hardware.md](docs/hardware.md) for the full pin map and power notes. The short
version:

- **ESP32-S3 N16R8.** Note that octal PSRAM consumes GPIO33 to GPIO37, so the pinout in
  the `esp-hub75` README does not work on this module.
- **Waveshare RGB-Matrix-P2.5-64x64**, 160x160mm, 1/32 scan (five address lines).
- **Power: 4A per panel.** Two panels is 40W worst case, so budget a 5V 10A supply with
  power injected into each panel separately.

## Repository layout

```
core/       portable C99 render engine. No platform dependencies. The contract.
  include/mirror/   public headers
  src/              canvas, fonts, json, layout, model, render, mock
  src/fonts/        GENERATED glyph tables
  host/             host-only: PNG writer and the CLI harness
  test/             unit tests and golden-image regression tests
fonts/      editable ASCII-art font sources
layouts/    stock layouts for 64x64, 128x64 and 128x128
tools/      fontgen, fontproof, gamma table generator
docs/       hardware notes
firmware/   ESP-IDF application (M2)
designer/   PySide6 layout designer (M1)
companion/  optional calendar helper service (M3)
```

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
