# Font Designer

A desktop tool for editing the panel's bitmap fonts and seeing what they look
like on the hardware they are for.

It is a Flutter application for Linux, separate from `designer/` (which is the
Android app), and it deliberately does one job: `fonts/*.font` in, a simulated
RGB matrix out. It never touches the C core, the layouts or the firmware.

```sh
cd font_designer
./setup.sh      # once, with Flutter on PATH
./run.sh        # builds if sources changed, then launches
```

## Why it exists

The fonts here are pixel art drawn for a HUB75 matrix, and the panel is not a
display with sub-pixel edges: each cell is a full-size emitter with dead space
around it, so a partly lit cell is a *dimmer dot*, not a softer edge. Judging
a glyph by looking at a bitmap in an editor tells you very little about
whether it reads on the panel — the dead space, the emitter shape and the
gamma curve all change the answer. So this tool draws the panel as a field of
emitters at a real pitch, and the glyph at the size it is really drawn.

## The window

Three columns, left to right:

**Fonts.** Every `.font` under `fonts/` and `gamekit/fonts/`, with a filter.
Selecting one loads it for editing. The game faces are listed separately
because `fontgen` compiles them into a different directory: they never enter
the layout registry.

**The panel.** The simulated matrix, showing either the sample string or the
whole character set. The toolbar picks the view, sets the sample text, the
integer scale and the ink colour. Under the panel is the zoom, which is pinned
by the slider and released by **Fit**.

**The glyph.** The strip is every glyph in the open font; clicking one selects
it for editing. The grid below is the glyph, one emitter per pixel. Click to
paint the selected ink, click a lit pixel to clear it, and drag to paint a
stroke. The yellow line is the baseline and the red one is where the next
glyph's pen starts, so the gap is visible as the space between them.

**Columns.** The right button opens a menu on the cell it was pressed on:
insert a column before or after it, delete it, trim the glyph's edges, or
clear that one pixel. The three small buttons on the grid's edge do the same
for the column the pointer marked, which is the tinted one in the grid and the
one named above it ("Column 3 of 8"); they stay lit so a button pressed after
the pointer left the grid still shows what it is about.

**Trim edges**, in the title bar, drops the blank columns at both edges of
every glyph in the open font. The pen already adds the font's gap between
glyphs, so a column left blank at an edge is spacing counted twice, and it is
the advance that inflates which throws a line's kerning out. This is the pass
to run before judging a cut's spacing — as one undo step, so a look at the
result costs one keystroke.

Two cases are held back, because their blank columns are not slack:

- A glyph with no ink at all is left alone. A space is nothing but advance,
  and trimming it would close the word gap.
- The ten digits of a cut are trimmed together, to the width the widest of
  them needs. They are tabular — a clock must not reflow as its digits change —
  and in a cut that draws one the hyphen goes with them, since the engine's
  `--:--` placeholder has to be exactly as wide as a real time. The pass takes
  the slack off the set as a whole and never leaves the ten at different
  widths.

The rest of the tools shift the glyph, clear it, or put it back the way the
file has it. The title bar's arrows undo and redo.

**Save + build** writes the `.font` and runs `tools/fontgen.py`, so the
tables the engine links match the art. The status bar says when the C tables
are behind the sources.

Every save is journalled to `out/font-journal/`: the glyphs it changed with the
rows they held before and after, and the bytes of the file it replaced. The log
is shared with the tools that rewrite the same art, so
`python3 tools/fontjournal.py log` says which of them a change came from and
`restore` puts a version back. See the **Fonts** section of the root README.

## The panel model

The panel is described by the numbers the hardware comes in, not by taste.

| Control | Default | What it does |
|---|---|---|
| Columns, rows | 64 x 32 | The matrix. A 64x32 panel at P2.5 is 160x80mm. |
| Pitch | P2.5 | Millimetres between cell centres. |
| Dead space | 50% of pitch | The dark share of each cell. The rest is the emitter. |
| Brightness | 255 | Applied after gamma, as the driver does. |
| Eye distance | 1.0m | How far the viewer is. The pitch and the distance together give the angle one cell subtends, and the eye's own one-arcminute blur is applied at that much. |
| Emitter | Round | A round die loses the corners of a cell and a square one does not, which decides whether a diagonal stroke reads. |

Two conversions between the frame and the screen are physics rather than
style, and they are worth knowing about because they are the difference
between a picture of the panel and a picture of its bytes:

- The panel applies a CIE 1931 lightness curve to each channel and then dims
  linearly for brightness (`core/src/canvas.c` does the same at export, from
  the table `tools/gen_gamma.py` generates). The preview reuses that curve,
  and `test/panel_test.dart` holds it against the committed C table.
- A monitor byte is sRGB encoded while the panel's on-time is proportional to
  emitted light, so a duty is written back through the sRGB transfer function.
  Without that an 18% panel grey would be shown as 2.7%.

## What it does to the file

Saving is a small diff, on purpose. A cut is a hundred glyphs of generated art
with a header and a comment line each; re-emitting the whole font from a model
would rewrite every line the author did not touch and turn a one-pixel fix
into an unreviewable diff. So the file is held as its own lines, each glyph
remembers which of them it owns, and only the rows that changed are replaced —
in the spelling they came in as, block or inline, with the file's own
indentation. `test/font_source_test.dart` checks the round trip against every
font in the catalogue: parse, serialize, byte for byte.

What the diff is taken *against* is the file as it stands at that moment, not
the text the font was opened with. The session's edits are merged into a fresh
read, so every other glyph keeps the line the file has right now — including
rows a second instance, a repair from `fontreview.py` or a rasterizer rerun
wrote since this window opened. Serialising from the opened text instead puts
those rows back, and takes this session's own earlier saves with them the
moment a glyph stops being dirty: the first save of a sitting survived, the
second restored the art as it had been at open. Both halves of that are real
losses, seen in `out/font-journal/` and pinned in `editor_flow_test.dart`.

The tool refuses exactly what `tools/fontgen.py` refuses, and reports it with
the line number: a missing `@role`, ragged rows, a stray ink character for the
declared planes, a duplicate codepoint, or a gap in the codepoint range.

## Layout

```
lib/src/font_source.dart      reading and writing .font, and the diffing
       frame.dart             the pen rules, and the character sheet's paging
       panel.dart             pitch, gap, the gamma curve, the eye's blur
       repo.dart              finding the checkout, listing fonts, fontgen
       designer_state.dart    what is open and what has changed
       ui/panel_view.dart     the emitters, and the editor's lattice
       ui/glyph_inspector.dart  the picker strip and the pixel grid
       ui/app.dart            the window
```

## Testing

```sh
flutter test
```

The suite checks the source format against the real catalogue, the pen rules
against what `core/src/font.c` does, the gamma table against the committed C
table, what a trim does to a glyph's rows and advance, and the
click-paint-save path against a throwaway checkout in the system temp
directory — never against the working tree, because this tool edits the art
the product ships. That path includes what a second save in one session does
to the first, and what it leaves of a glyph another writer changed between
them.

## Verification on this machine

There is no automated screenshot of the window. To run it and look, the app
starts under a virtual X server as well as on a real desktop:

```sh
Xvfb :99 -screen 0 1920x1080x24 &
cd font_designer && DISPLAY=:99 GDK_BACKEND=x11 ./run.sh
DISPLAY=:99 ffmpeg -y -f x11grab -video_size 1920x1080 -i :99 -frames:v 1 /tmp/shot.png
```
