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
| M4 Hot-reload layout push | Done: LAN API (status/layout) and BLE push from the designer, layout survives reboot in SPIFFS |
| M5 Provisioning, brightness, OTA | Provisioning and brightness done in M2/M4; OTA done: POST /api/ota with automatic rollback |

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
make -C core -f Makefile.host test     # 208 checks including golden images

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
      "font": "digits16",
      "color": "#00E5FF", "align": "center" },

    { "type": "text", "rect": [20, 32, 42, 7],
      "bind": "weather.temp" },

    { "type": "date", "rect": [0, 40, 64, 21],
      "fit": true },

    { "type": "agenda", "rect": [66, 9, 62, 26],
      "max_items": 3, "show_time": true, "accent": "#66D9EF" }
  ]
}
```

Widget types: `rect`, `line`, `text`, `clock`, `date`, `weather`, `icon`, `agenda`, `todo`.

Bindings are dotted paths into the model: `weather.temp`, `weather.label`,
`weather.code`, `now.hour`, `system.rssi`, `counts.events`, and so on. See
`ml_model_lookup()` in `core/src/model.c` for the full set.

Clock and temperature display follow the device settings, not the layout: a
clock widget without an explicit `format` shows 12-hour or 24-hour time per
the mirror's `clock12h` setting, and the display-facing temp bindings
(`weather.temp`, `weather.temp_min`, `weather.temp_max`) serve the unit the
mirror is set to (`temp_unit`). Both default to 12-hour and Fahrenheit, and
are set from the phone app over Bluetooth. A layout that pins its own clock
`format` or binds the raw `weather.temp_c` paths opts out of those settings
deliberately.

### Fonts: continuously scalable display faces

New and stock layouts use the `display` family, with `display-thin` available
as a lighter-stroked alternative. Each is stored once at 24px and area-resampled
at render time, so dragging a box changes its scale continuously instead of
switching cuts or jumping between integer multiples. Their figures are tabular,
keeping clocks stable as digits change.

Older font names remain registered so saved layouts continue to open:

| family | role | cuts | source |
|---|---|---|---|
| `display` | all text and digits | one 24px scaling master | Open Sans Bold |
| `display-thin` | all text and digits | one 24px scaling master | Open Sans Light |
| `sans` | text | 8 to 24px | Open Sans Regular |
| `digits` | digits | 10 to 48px, tabular figures | Open Sans SemiBold |
| `wx` | icons | one 16px scaling master | hand-drawn |

The display master scales both below and above its source size. Area coverage
preserves counters and stroke proportions while gamma compensation prevents
partially covered LED pixels from becoming too dim after panel correction.
The weather symbols use the same continuous area-resampling and
gamma-compensated coverage, including boxes smaller than their 16px master.

The weather icons are multi-colour: `wx16` carries four colour planes (sun,
cloud, precipitation, snow), each drawn in its own colour when the icon widget
provides a `colors` array:

```json
{ "type": "icon", "rect": [0, 26, 16, 16], "icon_set": "wx16",
  "bind": "weather.code",
  "color": "#FFD24D",
  "colors": ["#C9CDD6", "#5AA0E0", "#E8EEF4"] }
```

`color` is plane 0 (the sun, and the lightning bolt); `colors` fills planes 1
to 3 in order (cloud, rain, snow). A layout without `colors` tints every plane
with its single colour, so the icons remain legible from any layout that
predates palettes.

Naming a family leaves the size to the engine, which picks the cut that fills
the widget's box and scales it the rest of the way:

```json
{ "type": "clock", "rect": [0, 0, 64, 32], "font": "display", "fit": true }
```

Naming an exact cut, `"font": "digits16"`, still pins that cut, so every
layout written before families existed renders as it always did. The `sans`
and `digits` cuts are rasterized from Open Sans at build time by
`tools/fontraster.py` into ASCII-art `.font` sources, so a bad glyph can be
touched up by hand and everything still compiles through `tools/fontgen.py`.

### Sizing text

Bitmap glyphs grow by whole-pixel replication: `"scale": 3` draws every glyph
pixel as a 3x3 block. Scale is capped at 8 and defaults to 1, so any layout
written before it existed renders byte for byte as it always did.

`"fit": true` derives the scale from the box instead, taking the largest scale
that fits **both** the widget's width and its height. The derived scale is not
limited to whole multiples: between them the glyphs anti-alias, each panel
pixel inked in proportion to the area the scaled glyph covers, so dragging a
widget in the designer grows its text one pixel at a time rather than parking
at one size until the box reaches the next multiple. `fit` overrides `scale`
when both are set.

`"smooth"` controls that anti-aliasing per widget, as a tri-state. Unset, the
font decides: the display and weather masters scale continuously, while legacy
fonts retain their declared behavior. `"smooth": false` remains supported in
hand-authored layouts for deliberate whole-pixel rendering.

Width counts as much as height. Fitting on height alone was fine while every
`fit` widget held one short string, and wrong the moment one did not: a 64x32
clock box put `digits16` at 2x on height and then drew 104px of `09:41` into
64px of box. Widgets that draw a list, `agenda` and `todo`, are still sized on
height, because they clip each row with an ellipsis by design and fitting the
whole widget to its longest entry would shrink every row to suit one long title.

### Letting the engine choose the font

`"auto_font": true` picks the font as well as the size, out of those that can
render the string in question:

```json
{ "type": "clock", "rect": [0, 0, 64, 32], "font": "digits16",
  "fit": true, "auto_font": true }
```

In a 64x32 box `digits16` is held to 1.23x by its 47px of width and fills
about 20 of the 32 rows. `digits10` is narrower, reaches a higher scale and
fills more. With `auto_font` the engine works that out; without it, the named
font stands.

Membership is decided by what a font can actually draw, not by the family it
belongs to: a font is a candidate when it has a glyph for every character of
the string, and when its `@role` is not an icon set. Coverage keeps the clock
faces out of a label, and it means a new `.font` joins the right group on its
own. The role is what coverage cannot supply, since an icon set carries the
ten digits and nothing else: measure `wx16` however you like and no
measurement reveals that its glyphs are rain clouds. Ties go to the font the
layout named, since choosing the size is a service and quietly overruling a
deliberate choice for no gain is not.

It is off by default and ignored on `icon`, `agenda` and `todo`. An icon is
indexed by digit and every body font has digits, so a naive "which font can
draw this?" would answer `sans9` and put the numeral 3 where the rain icon
belongs.

Neither replaces choosing a font. `fit` scales the font the widget names, so a
`sans` clock stays a text face where `digits` draws tabular figures.

A box too small for the font it names falls back to the tallest cut of the
same family that does fit, and under that to the family's shortest, clipped:
the style is the author's choice and only the size is the box's, so resizing a
widget never changes what its text looks like. A 5px box naming `digits16`
draws five rows of `digits10`, not a smaller face of a different style. Only
when no cut of the family can draw the string at all, a word asked of a
digits-only clock face, does the search widen to another family. Shrinking a
widget past the point where text can fit degrades; it does not break.

Two rules worth knowing:

- **Unknown widget types are skipped with a warning, never rejected.** A newer designer
  must not be able to brick an older mirror by pushing a layout it does not fully
  understand.
- **`format` strings never reach a variadic formatter.** They are parsed by hand in
  `core/src/render.c`, because layouts arrive over the network and a stray `%s` against
  a double would otherwise be a remote crash.
- **Text is folded to what the fonts can actually draw.** A degree sign may be written
  either as `°` or as a literal `°`, since a JSON encoder is free to escape
  non-ASCII or not and Dart's does not. Both land on codepoint 127, where the fonts
  keep the glyph. Anything else outside ASCII becomes a visible `?` rather than being
  dropped, because a character that silently shortens a line is far harder to diagnose
  than one that shows up wrong.

## Fonts

Fonts are authored as readable pixel art in `fonts/*.font` and compiled to C tables by
`tools/fontgen.py`. Edit the art, not the generated tables.

```sh
python3 tools/fontgen.py                    # regenerate core/src/fonts/
python3 tools/fontgen.py --check            # fail if the tables are stale
python3 tools/fontproof.py sans9 "Wed 29 Jul"    # see it in the terminal
```

Every source declares a `@role`, which is required because it is the one thing
about a font its bitmaps cannot imply:

| Role | Meaning |
|---|---|
| `text` | The full printable range. Substitutable for any string |
| `digits` | A clock or temperature face: digits and a little punctuation |
| `icons` | Pictograms indexed by digit. Never a stand-in for text |

A clock face and an icon set carry the same ten codepoints, so without this the
renderer asking "what can draw `23`?" cannot tell a numeral from a rain cloud.
The designer filters on it too: an icon set is offered in the icon-set picker
and kept out of the font picker, where choosing it would silently replace a
label with weather symbols.

| Font | Size | Contents |
|---|---|---|
| `sans8` to `sans24` | 8 to 24px cells, proportional | Full printable ASCII, plus a degree sign at codepoint 127. `sans9` is the default body font |
| `digits10` to `digits48` | 10 to 48px cells | `- . /` and `0-9 :`, tabular figures, eleven cuts |
| `wx16` | 16x16 master | Ten continuously scalable weather icons in four colour planes, indexed by category |

Drop a font you do not use and it stops being compiled in: the build discovers
`core/src/fonts/*.c` rather than listing them.

One typeface everywhere is the point: body text, dates, temperatures and the
clock share a design, differing only in size and, for the clock, in weight.
Both families are proportional, which recovers several characters per line
versus a fixed cell: "Standup 10:00" is 67px in `sans8`.

The clock faces exist so the time can suit the panel rather than the panel suiting the
time. "09:41" is 40px in `digits10`, 54px in `digits16` and 98px in `digits32`. All
cuts keep the placeholder `--:--` exactly as wide as a real time, so nothing reflows
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
idf.py -C firmware menuconfig        # Smart Mirror menu: WiFi, timezone, display, panel
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
