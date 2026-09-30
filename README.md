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
| M3 Data providers | Weather, air quality and commute traffic done; todos pending, calendar deferred |
| M4 Hot-reload layout push | Done: LAN API (status/layout) and BLE push from the designer, layout survives reboot in SPIFFS |
| M5 Provisioning, brightness, OTA | Provisioning and brightness done in M2/M4; OTA done: image streamed over Bluetooth, with automatic rollback |

There is no companion service. Weather, air quality and the multi-day forecast
come straight from Open-Meteo, which needs no API key. Commute traffic is the
one feature that needs a third-party credential: the owner's TomTom Routing key,
pushed from the phone app over Bluetooth and kept in NVS, never in `sdkconfig`.
Until a route and a key are both stored the traffic provider makes no request
at all. Calendar was deferred rather than solved with a helper box,
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
weather layout. Swap in `single`, `dual` or `quad` for denser 64x32 arrangements: every
stock layout targets the 64x32 panel, the only size the hardware ships today. Useful flags:

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

Widget types: `rect`, `line`, `text`, `clock`, `date`, `weather`, `icon`, `agenda`,
`todo`, `countdown`, `precip`, `wind`, `air`, `traffic`, `sun`, `moon`, `forecast`.

`precip` plots the precipitation chance over the next 12 hours as a bar chart:
one bar per hour, height proportional to the 0..100 chance, on a baseline with
faint 50% and 100% reference lines. It reads `weather.precip_hourly` from the
model, which Open-Meteo fills from its hourly forecast, so a mirror that has
not fetched a forecast yet draws just the baseline rather than a flat zero.

`wind` is the conditions block for wind: speed, then the cardinal the wind
comes from with the gust, then humidity and the feels-like temperature, with a
compass arrow on the left. The text names the direction the wind blows from
and the arrow points where it is going, see
[Wind arrows point downwind](#wind-arrows-point-downwind).

`air` shows outdoor air quality: the AQI number with its band name, the UV
index, the worst of the three pollen counts, and a bar per plant on a 60
grains/m³ full scale. `"us_aqi": true` switches the number and the bands to the
U.S. scale, which is a widget field rather than a device setting because the
two scales disagree about what counts as bad and a layout may reasonably show
either. Pollen is a Europe-only series, so `pollen` and `pollen_type` come back
unavailable elsewhere and the bars are simply not drawn.

`traffic` is the commute: travel time, how much of it is delay ("on time" under
a minute either way), and the route's label. It needs a route and an API key,
both set from the phone app; until then the widget draws its placeholder and
the provider makes no request at all.

`sun` draws the day as a track with the elapsed daylight filled in, the sunrise
and sunset times under it and the length of the day. `moon` draws the current
phase as a lit limb with its illumination and name. Neither invents anything
when the data is missing: with no sun times the track is drawn empty, and with
no synced clock the moon widget shows `--`.

`forecast` is a multi-day strip: one column per day, a weather icon above the
day's high and low. The column slots are fixed at three so the strip does not
reflow as days arrive; columns with no data are left empty.

```json
{ "type": "wind", "rect": [0, 8, 64, 24],
  "font": "display-thin", "fit": true,
  "color": "#FFFFFF", "accent": "#66D9EF" }
```

Bindings are dotted paths into the model: `weather.temp`, `weather.label`,
`weather.code`, `now.hour`, `system.rssi`, `counts.events`, and so on. The new
widgets add `weather.wind`/`wind_gust`/`wind_gust_kph`/`wind_dir`/
`wind_dir_name`/`feels` (`wind_kph` was already there),
`weather.sunrise`/`sunset`/`sunrise_min`/`sunset_min`,
`air.aqi_eu`/`aqi_us`/`label_eu`/`label_us`/`pm25`/`pm10`/`uv_index`/`pollen`/
`pollen_type`, `traffic.travel_min`/`delay_min`/`free_flow_min`/`label`, and
`moon.phase`/`illum`/`label`. See `ml_model_lookup()` in `core/src/model.c`
for the full set.

#### Wind arrows point downwind

`weather.wind_dir` and the `wind` widget's text follow the meteorological
convention: the direction the wind blows **from**, so a north-westerly reads
`NW`. The arrow points the other way, where the air is going, which is what
makes it a picture of what is happening rather than a label. One constant in
`wind_arrow_dir()` decides it.

Clock and temperature display follow the device settings, not the layout: a
clock widget without an explicit `format` shows 12-hour or 24-hour time per
the mirror's `clock12h` setting, and the display-facing temp bindings
(`weather.temp`, `weather.temp_min`, `weather.temp_max`) serve the unit the
mirror is set to (`temp_unit`). Both default to 12-hour and Fahrenheit, and
are set from the phone app over Bluetooth. A layout that pins its own clock
`format` or binds the raw `weather.temp_c` paths opts out of those settings
deliberately.

The weather's coordinates and place label, and the commute's two endpoints,
label and routing API key, are device settings for the same reason: one layout
can be pointed at a different home, or a different drive, without being edited.

### Fonts: ladders of set sizes

Every text face is a ladder of set sizes, drawn at whole-pixel multiples, so a
box steps to the cut that fits rather than stretching one drawing to any size.
That is not a stylistic preference: a 1px stem rescaled by a fraction covers two
panel cells part-way, and on a HUB75 panel a partly covered cell is a full-size
emitter at part brightness. Measured across the stock layouts, the old 24px
`display` masters drew at 0.29x to 0.33x and left 89 to 94 percent of their
light in part-lit cells. Whole-multiple cuts put it at zero.

There are exactly two faces to draw text with: `display-thin`, the minimal
readable one, and `display`, the bold one. Each is a ladder from 6 to 24px, so
picking a style is the author's call and picking the size is the box's. The
other three families are not a style choice: `digits` is the clock and
temperature face, whose figures are tabular so a time never reflows as its
digits change, `wx` is the weather pictograms, and `micro` is the 3x7 score
face a game draws into a margin too narrow for any of the ladders.

| family | role | cuts | source |
|---|---|---|---|
| `display` | all text and digits | 6 to 24px | Open Sans Bold |
| `display-thin` | all text and digits | 6 to 24px | Open Sans Light |
| `digits` | digits | 10 to 48px, tabular figures | Open Sans SemiBold |
| `micro` | digits | 3x7, hand-drawn | for a game HUD margin |
| `wx` | icons | one 16px scaling master | hand-drawn |

Text used to be drawn from three Open Sans ladders -- Bold, Light and Regular --
and a layout author had to tell Regular from Light to choose a body face. The
Regular ladder is gone: it was never offered by the designer's Font dropdown,
which has always shown these two, and it was the face nothing named.

A cut reserves rows under the baseline for the tails of `y`, `q`, `j`, `g` and
`p`, and a line of prose pays for that reserve on every row whether the row has
a tail or not. Half of it comes off before the cut is written: the ink below the
baseline moves up by that much and the cell shrinks to meet it, while `@baseline`
and everything above it stays put. So `display12` is a 12px cell asked for and
an 11px cell drawn, and the cut keeps its name for the layouts that pin it. A
glyph keeps its deepest row, so a shallow tail is trimmed less than a deep one
rather than deleted, and the `_`, which is drawn low by design, keeps its ink.

The weather symbols are the one face that still scales continuously, with
gamma-compensated area coverage, including boxes smaller than their 16px
master. Every other cut is drawn at whole multiples only.

### Making small text legible

Two things a vector face cannot do at 8px, and what the rasterizer does about
them.

**A stroke thinner than a pixel.** A Light stem at 8px peaks below any fixed
cutoff, so the cutoff either erases it (a blank `l`) or doubles it. The cutoff
is chosen once per cut rather than per glyph — the level is a property of the
size, and a per-glyph rule leaves one stem emboldened and its neighbour not, or
reads antialiasing ghosts as marks and cuts a well-formed `X` in half. The cut
takes the highest rung at which no glyph is blank; a short bar like a hyphen
loses its ends and survives as a stub, which the same rule recovers.

**Glyphs a reader cannot tell apart.** At 8px a proportional face draws `1`,
`l`, `I` and `|` as the same stem, and `0` as the same oval as `O`. No amount
of hinting separates those, because the difference is a design decision, not a
rendering one. The rasterizer draws the marks that are cheap and conventional: a
foot on the `1`, a serif on the `I`, a tail on the `l`, and a tail below `,` and
`;`. Each mark is drawn inside the glyph's advance and only ever adds ink; where
a narrow glyph fills its whole advance and leaves nowhere for a mark, the
advance grows by a column or two rather than leaving two letters
indistinguishable.

A zero is never slashed and a seven is never barred. Both marks were tried and
both were rejected on the panel: a slash through every `0` and a bar across
every `7` spends ink on two pairs a reader rarely meets mid-word, and it changes
the shape of two very common glyphs to do it. `0`/`O` and `7`/`?` are left to
the audit below to report rather than to the rasterizer to paper over.

`make -f core/Makefile.host audit` measures both, and its confusability table
reports the pixels that actually carry a difference between two glyphs, compared
from the same pen origin — a footed `1` and a tailed `l` are 90% identical by
area and unmistakable to the eye, so overlap alone cannot judge them.

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
layout written before families existed renders as it always did. Every cut is
rasterized from Open Sans at build time by `tools/fontraster.py` into
ASCII-art `.font` sources, so a bad glyph can be touched up by hand and
everything still compiles through `tools/fontgen.py`.

### Sizing text

Bitmap glyphs grow by whole-pixel replication: `"scale": 3` draws every glyph
pixel as a 3x3 block. Scale is capped at 8 and defaults to 1, so any layout
written before it existed renders byte for byte as it always did.

`"fit": true` derives the scale from the box instead, taking the largest scale
that fits **both** the widget's width and its height. That scale is a whole
multiple: every text face here is a ladder of set sizes, so a box steps to the
next cut rather than stretching one drawing across a fraction of a pixel. On a
HUB75 panel a partly covered cell is a full-size emitter at part brightness,
not a sub-pixel edge, so a fractional scale does not soften the text — it
dims two thirds of it. A box with no cut small enough to fit falls to the
family's shortest, clipped; the style is the author's and only the size is the
box's.

Which cut a box gets is decided by inked height, not by cell height. Cells are
padded for ascenders and descenders and the padding is not the same share at
every size, so ranking by cell let a 32px box draw *smaller* figures than the
30px box before it. Ranked by ink, growing a box can only ever add candidates.

`"smooth"` overrides that per widget, as a tri-state. Unset, the font decides,
and every text and clock cut asks for whole-pixel steps. `"smooth": true`
restores fractional anti-aliasing for a widget that wants it, which is
supported for hand-authored layouts; the weather icon set is the one face that
still scales continuously, since a pictogram has no strokes to smear.

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

In a 64x32 box `digits16` is held to 1.28x by its 50px of width, and to 2x by
the box's height, so whole-pixel steps draw it at 1x and fill 16 of the 32
rows. `digits10` is narrower at 1.64x of width, which leaves the box free to
put its height into a taller cut: with `auto_font` the engine works that out
and draws `digits24` here, and without it the named font stands.

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
draw this?" would answer `display-thin9` and put the numeral 3 where the rain icon
belongs.

Neither replaces choosing a font. `fit` scales the font the widget names, so a
`display-thin` clock stays a text face where `digits` draws tabular figures.

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
python3 tools/fontproof.py display-thin9 "Wed 29 Jul"    # see it in the terminal
python3 tools/fontreview.py                 # review every cut, repair the pixels
python3 tools/fontreview.py --check         # fail if a cut has lost its touch-ups
make -f core/Makefile.host audit            # legibility audit of every cut
cd font_designer && ./run.sh                # edit the art against a simulated panel
```

### Editing the art

`font_designer/` is a Linux desktop tool for touching up a cut pixel by pixel and seeing
the result on a simulated RGB matrix — real pitch, real dead space between the emitters,
the panel's own gamma. It edits `fonts/*.font` in place, writing back only the rows that
changed, and can run `tools/fontgen.py` so the tables match the art. Its **Trim edges**
pass drops the blank columns at the edges of a cut's glyphs: the pen already adds `@gap`
between glyphs, so a blank edge column is spacing counted twice. Two things it holds
back — a glyph with no ink at all, since a space is nothing but advance, and the ten
digits of a cut, which stay tabular (with the hyphen alongside them in a clock face, so
the `--:--` placeholder stays the width of a real time). See its README.

### Reviewing and repairing the art

`tools/fontreview.py` is the machine pass over the same art: it measures every cut of
`fonts/` and of `gamekit/fonts/`, then repairs the glyphs whose pixels have lost
something the design needs. It sits between the two existing tools — `fontraster.py`
draws a cut, `fontreview.py` touches it up, `fontgen.py` compiles it — and it is
idempotent, so art it has already reviewed is a fixed point and `--check` is a usable
gate (which is what `make -f core/Makefile.host fontreview-check` runs).

The measurement is one source pixel per panel cell, which is what a reader sees: these
cuts are `@smooth no`, so a fitted scale floors to a whole multiple and a 2x draw only
replicates the art. Per glyph it reports a blank glyph, a counter the design encloses
and the cut does not, a cut's thinnest run and the glyphs built from it, a stem that
steps sideways between two rows, and the confusable pairs by the pixels that actually
tell them apart.

Two defect classes are deliberately not claimed. A lone inked pixel is not reported,
because a stray artifact and the dot of an `i` are the same thing to any measurement —
the first version of this tool "cleaned" 27 such pixels and every one was the mark of a
grave accent, a semicolon or a comma. Nor is a glyph's position inside its own advance,
because a proportional face moves a glyph off centre on purpose: a `J` hangs left and an
`f` leans in.

Two repairs are offered automatically, and each is taken only when a measurement says
the art is wrong *and* the result measurably improves it:

- **aperture** — the rasterizer lowers its cutoff until no glyph of a cut is blank, and
  at a small cell that is low enough to fill an aperture in entirely: a 7px `0` comes
  out a solid blob. The glyph's *master* — the largest cut of the same family, where the
  shape survives — boxed down to this cut's ink box says which cells should be
  background. Only cells the glyph's own ink rings on all four sides are cleared, so no
  stroke can be lost and the silhouette cannot change, and the repair is refused if it
  would duplicate a glyph, invent a counter the design lacks, or leave a confusable pair
  a reader could no longer tell apart. This is what restores 61 counters across the
  catalogue, and it is also why `0`/`O`, `8`/`B` and `9`/`g` gained distinguishing
  pixels at 6 to 9px.
- **stem-weight** — a stem the cut drew a rung thinner than the rest of its own cut, in
  a glyph that *is* a stem (the display10 `I` came out a 1px hairline under 2px serifs
  in a cut whose every other stem is 2px). Letters and digits only: a bracket's or a
  bar's thin part is a drawing decision.

Everything else the review finds is reported and left alone, because the judgement is
the author's: a stem that jogs a column, a pair still under `--distinct` pixels, a cut
whose stroke weight steps away from its ladder. `--only aperture` runs one pass,
`--dry-run` prints the plan, `--json` is for tooling, and `--font` narrows the review to
named cuts without losing the family they are measured against.

### Auditing legibility

Editing pixel art blind is one problem; knowing whether a cut survives being scaled is
another. `core/host/font_audit.c` renders every glyph of every registered font through
the real renderer and reports three things:

- **1x structure** — thinnest stroke, counter count, and the smallest counter. A 1px
  counter is the one that closes first.
- **Scale sweep** — for each scale the engine can actually pick, the *grey load* (share
  of emitted light landing in partially lit cells), whether any ink fell below half
  light, whether a stroke split, and whether a counter closed. Only relevant scales are
  swept: a non-smooth cut's fitted scale floors to a whole multiple, and a scale below
  1x is clamped to 1x unless the cut declares `@downscale`, so those rows would just
  re-report the 1x render.
- **Confusability** — for the pairs that cost readers (`0/O`, `1/l/I/|`, `5/S`, `8/B`,
  …), the pixels that actually carry a difference between the two glyphs, fewest first.
  That list is the concrete redraw order.

Why distinguishing pixels rather than a similarity score: a footed `1` and a tailed `l`
are about 90% identical by area and unmistakable to the eye, so any figure normalised by
overlap calls the marks pointless. The two are rendered from the same pen origin and
compared cell by cell, because aligning them by ink box throws away the vertical position
that separates `P` from `p` and a hyphen from an underscore. A pair under `--distinct`
pixels (default 3) is flagged `AMBIGUOUS` and wants a mark, an advance widened, or a
redrawn letterform.

Why grey load: a whole-multiple scale replicates each glyph pixel into a block and
scores 0%, but a fractional scale splits a 1px stroke across two cells. On a HUB75
panel a partially covered cell is a *full-size emitter at part brightness*, not a
sub-pixel edge — a 25%-lit cell is a quarter-bright dot. Half-light is the threshold the
tool calls ink, so `FAINT` counts glyphs with a cell the eye may read as background.

Grey load, `FAINT` and confusability are advisory. A split stroke, a closed counter and a
blank glyph are structural, and `--strict` fails on those:

```sh
core/build/host/font-audit --font display-thin8 --scales 0.5,0.75,1  # one cut
core/build/host/font-audit --json | jq .                             # for tooling
core/build/host/font-audit --strict                                  # gate
```

This audit and `tools/fontreview.py` answer different halves of the same question, and
they are meant to be read together. The audit renders through the real engine and says
what a *compiled* cut does across scales, including the fractional ones this review
cannot see; the reviewer works on the art and can therefore repair it. So the reviewer
reports the defects it can fix, and the audit is the independent check that a repair
did not cost the cut anything the engine cares about — which is how the 61 restored
counters above were confirmed to come with no new stale counter, split stroke or blank
glyph, and with two *fewer* ambiguous pairs.

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
| `display6` to `display24`, `display-thin6` to `display-thin24` | 6 to 24px cells | Full printable ASCII, plus a degree sign at codepoint 127. Bold and Light strokes |
| `display-thin6` to `display-thin24` | 6 to 24px cells, proportional | Full printable ASCII, plus a degree sign at codepoint 127. `display-thin9` is the default body font |
| `digits10` to `digits48` | 10 to 48px cells | `- . /` and `0-9 :`, tabular figures, eleven cuts |
| `micro7` | 7px cells, hand-drawn | The ten digits, `0-9`, for a HUD margin and nothing else |
| `wx16` | 16x16 master | Ten continuously scalable weather icons in four colour planes, indexed by category |

Drop a font you do not use and it stops being compiled in: the build discovers
`core/src/fonts/*.c` rather than listing them.

One typeface everywhere is the point: body text, dates, temperatures and the
clock share a design, differing only in size and, for the clock, in weight.
Both families are proportional, which recovers several characters per line
versus a fixed cell: "Standup 10:00" is 67px in `display-thin8`.

`micro7` is the deliberate exception, and it is a game HUD rather than a
typeface: a 3x7 digit costs 4px of advance, so the five figures a score can
reach fit the 20px column beside a 10-cell board, where `digits10` would need
44px and answer the overflow with an ellipsis. It carries the ten digits and
no punctuation, which also keeps it out of the `auto_font` search that would
otherwise fit it to a clock string in a narrow box.

The clock faces exist so the time can suit the panel rather than the panel suiting the
time. "09:41" is 39px in `digits10`, 50px in `digits16` and 86px in `digits32`. All
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
  host/             host-only: PNG writer, CLI harness, font audit
  test/             unit tests and golden-image regression tests
fonts/      editable ASCII-art font sources
layouts/    stock layouts, all 64x32 (the default); larger panels ship as size-suffixed presets
tools/      fontraster, fontreview, fontgen, fontproof, gamma table generator
docs/       hardware notes
firmware/   ESP-IDF application: panel, wifi, clock, data providers
designer/   Flutter layout designer, desktop and mobile
font_designer/  Flutter tool for editing the fonts against a simulated RGB matrix
```

## Designer

```sh
cd designer
./setup.sh              # generates platform build files, needs Flutter
flutter run -d linux

./install-shortcut.sh --desktop   # optional, adds a launcher and a Desktop shortcut
```

The app opens on a remembered device dashboard with actual framebuffer previews,
including timestamped images for offline mirrors. Mirrors that are answering now
are highlighted, and the first render orders the tiles by how recently each one
answered — an order that is then fixed, so a poll never moves a tile. While the
app is in the foreground the dashboard holds one Bluetooth link, to the mirror
used most recently, so a mirror reachable only over Bluetooth reads as reachable
there instead of waiting for its page to be opened. Select a
device for its clock, BLE games, or persisted PNG/JPEG picture display with
aspect-locked pinch/drag cropping and Fit/Fill framing. Actions
remain bound to that device. The layout designer/simulator is a separate app-menu
destination, using the same `core/` C renderer as the panel.

See [designer/README.md](designer/README.md) for workflows and
[firmware/README.md](firmware/README.md#device-identity-pictures-and-actual-previews)
for the display API. Editor chrome never enters the framebuffer; actual device
snapshots already include gamma, brightness and orientation.

Panel orientation is the one setting that is genuinely the device's: the
Settings screen's **Upside down** toggle pushes `flip180` over Bluetooth and
reads the device's value back when it connects, so the preview shows what a
panel mounted upside down actually displays. The panel compensates at the last
step before the shift registers, which is why the golden-image bytes are
untouched by it.

## Testing

```sh
make -C core -f Makefile.host test
```

Golden tests hash the exported gamma-corrected RGB888 frame at each layout's own
brightness — what the designer's preview draws — across five layouts and four mock variants.
Any change to glyphs, gamma, parsing or widget drawing is caught. On a mismatch the actual
frame is written to `out/<key>-actual.png` so the difference can be looked at rather than
argued about.

The device is sent the same frame at full scale and dims in the driver, which is the form
`mirror-cli --dump` writes for comparing a host render against the panel.

After an intentional rendering change:

```sh
MIRROR_UPDATE_GOLDEN=1 make -C core -f Makefile.host test
```
