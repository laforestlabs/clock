#!/usr/bin/env python3
"""Rasterize a vector font into fonts/*.font ASCII art, one file per size.

fontgen.py compiles hand-edited pixel art into C tables, and that pipeline is
worth keeping: the .font file stays the source of truth, readable and
touch-up-able by hand. But a smooth family wants a cut at many sizes, and
drawing a dozen of those as pixel art is not a job for a person. This tool
renders an open-licensed TTF at each target cell height with FreeType (via
Pillow), thresholds the grayscale coverage to bits and writes the result as a
.font, so the human only edits the cuts that come out wrong. The cutoff belongs
to the cut rather than to the glyph: a stem narrower than a pixel peaks below
any fixed threshold, so the cut is made at the highest rung where no glyph of
it is blank (see cut_threshold). The marks that tell 1/l/I and , and ; from the
glyphs they are confused with at small sizes are drawn on top of the bits
(see distinguish), so regenerating a cut reproduces it exactly.

The cell model matches the hand fonts: every glyph occupies a cell of @height
rows, sits on @baseline measured from the top, and advances by its own width,
which is what makes the family proportional. The FreeType size for a cell is
the largest whose ascent plus descent still fits the cell, so a
display-thin14 cut uses every row it is given rather than arriving letterboxed.

With --compact, the body occupies the cell above a short descender reserve
(max(1, height // 8) rows). Capitals and figures fill row zero through
the baseline; round overshoot does not consume the descender reserve. The
6/7px cuts use explicit optical hints to keep bowls open and strokes connected.
Lowercase g uses a single bowl, and y continues the arms of v with a short tail.
--numerals takes the numeral source face, aligns its figures to the capitals,
and holds digits and the clock placeholder hyphen to a shared advance.

A glyph whose design is mirror-symmetric comes out exactly symmetric. FreeType
places glyphs at a fractional origin, and thresholding that render decides
which stem keeps a column, so a raw 0 has a 2px left stem and a 3px right one.
The display faces declare the expected axes for symmetric letters, figures
and symbols explicitly. Other glyphs are probed at high resolution (see
symmetry_axes). Matching coverage is averaged before thresholding; an 8 has
left/right symmetry but retains its different upper and lower bowls.

Usage:
    python3 tools/fontraster.py <ttf> <name-prefix> <role> <height...> \
        [--family NAME] [--codepoints text|digits] [--threshold N]

Example (rebuild the display catalogue, then review and compile):
    python3 tools/fontraster.py /usr/share/fonts/open-sans/OpenSans-Bold.ttf \
        display text 6 7 8 9 10 11 12 14 16 18 20 24 28 32 40 48 \
        --family display --smooth no --compact \
        --numerals /usr/share/fonts/open-sans/OpenSans-Semibold.ttf
    python3 tools/fontraster.py /usr/share/fonts/open-sans/OpenSans-Light.ttf \
        display-thin text 6 7 8 9 10 11 12 14 16 18 20 24 \
        --family display-thin --smooth no --compact
    python3 tools/fontreview.py
    python3 tools/fontgen.py

The .font sources remain editable. A rasterizer rerun replaces manual edits;
fontreview reapplies measured repairs and every write is journalled.

"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat

ROOT = Path(__file__).resolve().parent.parent

# Every write to the art is journalled, so a lost edit can be explained and
# undone: see tools/fontjournal.py. Imported both ways round because these
# tools run as scripts and are also importable as package modules.
try:
    from fontjournal import record, record_run, relpath
    from fontreview import holes
except ImportError:                        # pragma: no cover
    from tools.fontjournal import record, record_run, relpath
    from tools.fontreview import holes
FONT_SRC_DIR = ROOT / "fonts"

# Codepoint 127 is DEL and unused by the runtime, so every font here carries
# the degree sign there, matching the hand-authored fonts (see ML_DEGREE).
DEGREE_SLOT = 127
DEGREE_CHAR = "°"


def codepoints(kind: str) -> list[int]:
    if kind == "text":
        return list(range(32, 127)) + [DEGREE_SLOT]
    if kind == "digits":
        # '-', '.', '/', 0-9 and ':': what a clock or a temperature needs, and
        # nothing a label could mistake for letters. The degree sign is left
        # out: it lives at 127, and the runtime indexes glyphs by subtraction,
        # so carrying it would force a table full of blanks over 59-126.
        return list(range(45, 59))
    raise ValueError(kind)


def ink_metrics(font: ImageFont.FreeTypeFont, probe: str) -> tuple[int, int]:
    """Cap height and descender depth, measured on drawn ink.

    FreeType's ascent/descent are line metrics and run far taller than the
    actual glyph ink, so fitting a cell by them letterboxes the face. The
    probe string spans cap top to descender bottom, which is what the cell
    has to hold. A digits face probes without descenders, since no glyph it
    carries has one: the whole cell goes to the digits.
    """
    img = Image.new("L", (300, 300), 0)
    draw = ImageDraw.Draw(img)
    draw.text((0, 150), probe, font=font, fill=255, anchor="ls")
    bbox = img.getbbox()
    return (150 - bbox[1], bbox[3] - 150) if bbox else (0, 0)


def fit_size(path: str, cell: int, probe: str) -> tuple[ImageFont.FreeTypeFont, int]:
    """Largest FreeType size whose ink fits the cell height.

    Returns the font and the baseline row for that cell: the cap height,
    nudged to center any spare row.
    """
    for size in range(cell * 2, 0, -1):
        font = ImageFont.truetype(path, size)
        cap, desc = ink_metrics(font, probe)
        if cap + desc <= cell:
            return font, cap + (cell - cap - desc) // 2
    raise SystemExit(f"{path}: no size fits a {cell}px cell")


# The symmetry probe renders at a fixed large size. Symmetry is a property
# of the glyph design, and hinting noise shrinks with size: at 256pt a
# symmetric Open Sans glyph mirrors within a few percent while the least
# asymmetric letter differs by a third or more, a gap no cut size narrows.
PROBE_SIZE = 256

# These are design requirements for the display faces, not guesses from a
# vector outline. Hinting and optical compensation must not skew these shapes.
DISPLAY_HORIZONTAL = "AHIMOTUVWXYovwx08!+-:=^_|"
DISPLAY_VERTICAL = "HIOXox0+-:=|"

# Five-row optical hints. At 6/7px, thresholding the vector face collapses
# bowls and diagonals; even Bold must use 1px stems to keep its counters open.
SMALL_CAPS = {
    'A': '.#./#.#/###/#.#/#.#', 'B': '##./#.#/##./#.#/##.',
    'C': '.##/#../#../#../.##', 'D': '##./#.#/#.#/#.#/##.',
    'E': '###/#../##./#../###', 'F': '###/#../##./#../#..',
    'G': '.##/#../#.#/#.#/.##', 'H': '#.#/#.#/###/#.#/#.#',
    'I': '###/.#./.#./.#./###', 'J': '..#/..#/..#/#.#/.#.',
    'K': '#.#/#.#/##./#.#/#.#', 'L': '#../#../#../#../###',
    'M': '#...#/##.##/#.#.#/#...#/#...#',
    'N': '#...#/##..#/#.#.#/#..##/#...#',
    'O': '.#./#.#/#.#/#.#/.#.', 'P': '##./#.#/##./#../#..',
    'Q': '.#./#.#/#.#/#.#/.#.', 'R': '##./#.#/##./#.#/#.#',
    'S': '.##/#../.#./..#/##.', 'T': '###/.#./.#./.#./.#.',
    'U': '#.#/#.#/#.#/#.#/###', 'V': '#...#/#...#/.#.#./.#.#./..#..',
    'W': '#...#/#...#/#.#.#/#.#.#/.#.#.',
    'X': '#...#/.#.#./..#../.#.#./#...#',
    'Y': '#.#/#.#/.#./.#./.#.', 'Z': '###/..#/.#./#../###',
}
SMALL_DIGITS = {
    '0': '###/#.#/#.#/#.#/###', '1': '.#./##./.#./.#./###',
    '2': '##./..#/.#./#../###', '3': '##./..#/.#./..#/##.',
    '4': '#.#/#.#/###/..#/..#', '5': '###/#../##./..#/##.',
    '6': '.##/#../###/#.#/###', '7': '###/..#/.#./.#./.#.',
    '8': '###/#.#/###/#.#/###', '9': '###/#.#/###/..#/##.',
}
SMALL_LOWER = {
    'a': '.##/#.#/#.#/###', 'c': '.##/#../#../.##',
    'e': '.#./#.#/##./.##', 'm': '##.##/#.#.#/#.#.#/#.#.#',
    'n': '##./#.#/#.#/#.#', 'o': '.#./#.#/#.#/.#.',
    'r': '##./#.#/#../#..', 's': '.##/#../.##/##.',
    'u': '#.#/#.#/#.#/.##', 'v': '#...#/#...#/.#.#./..#..',
    'w': '#...#/#.#.#/#.#.#/.#.#.', 'x': '#.#/.#./.#./#.#',
    'z': '###/..#/.#./###',
}
SMALL_ASCENDERS = {
    'b': '#../##./#.#/#.#/##.', 'd': '..#/.##/#.#/#.#/.##',
    'f': '.##/.#./###/.#./.#.', 'h': '#../##./#.#/#.#/#.#',
    'i': '#/./#/#/#', 'j': '.#/../.#/.#/.#',
    'k': '#../#.#/##./#.#/#.#', 'l': '##./.#./.#./.#./.##',
    't': '.#./###/.#./.#./.##',
}
SMALL_DESCENDERS = {
    'g': '.##/#.#/.##/..#/##.', 'p': '##./#.#/##./#../#..',
    'q': '.##/#.#/.##/..#/..#', 'y': '#.#/#.#/.##/..#/##.',
}


def stretch_rows(rows, height):
    """Nearest row centres; symmetric input stays symmetric after resizing."""
    return [rows[min(len(rows) - 1, (2 * y + 1) * len(rows) // (2 * height))]
            for y in range(height)]


def display_metrics(glyphs, baseline, cell):
    """Capitals reach row zero; only genuine descenders use the tail reserve."""
    for cp in list(range(65, 91)) + list(range(48, 58)):
        rows = glyphs[cp]
        # Q keeps its tail; J is a capital, so its hook belongs above baseline.
        body = rows[:baseline] if cp == ord('Q') else rows
        ys = [y for y, row in enumerate(body) if '#' in row]
        if not ys:
            continue
        body = stretch_rows(body[min(ys):max(ys) + 1], baseline)
        tail = rows[baseline:] if cp == ord('Q') else ['.' * len(rows[0])] * (cell - baseline)
        glyphs[cp] = body + tail
    for ch in 'abcdefghiklmnorstuvwxz':
        rows = glyphs[ord(ch)]
        ys = [y for y, row in enumerate(rows) if '#' in row]
        if ys and max(ys) >= baseline:
            top = min(ys)
            glyphs[ord(ch)] = (rows[:top] +
                stretch_rows(rows[top:max(ys) + 1], baseline - top) +
                ['.' * len(rows[0])] * (cell - baseline))
    # A centered, serifed I needs equal room on both sides of the stem.
    hrow = glyphs[ord('H')][0].strip('.')
    stem = len(hrow) - len(hrow.lstrip('#'))
    stem = max(1, stem)
    serif = max(1, stem // 2)
    width = stem + 2 * serif
    glyphs[ord('I')] = [
        '#' * width if y < stem or y >= baseline - stem
        else '.' * serif + '#' * stem + '.' * serif
        for y in range(baseline)
    ] + ['.' * width] * (cell - baseline)
    if cell <= 7:
        for ch, art in {**SMALL_CAPS, **SMALL_DIGITS}.items():
            body = stretch_rows(art.split('/'), baseline)
            tail = ['.' * len(body[0])] * (cell - baseline)
            if ch == 'Q':
                tail[0] = '..#'
            glyphs[ord(ch)] = body + tail
        for ch, art in SMALL_LOWER.items():
            rows = art.split('/')
            blank = '.' * len(rows[0])
            glyphs[ord(ch)] = [blank] * (baseline - 4) + rows + [blank] * (cell - baseline)
        for ch, art in SMALL_ASCENDERS.items():
            body = stretch_rows(art.split('/'), baseline)
            tail = ['.' * len(body[0])] * (cell - baseline)
            if ch == 'j':
                tail[0] = '#.'
            glyphs[ord(ch)] = body + tail
        for ch, art in SMALL_DESCENDERS.items():
            rows = art.split('/')
            glyphs[ord(ch)] = ['.' * len(rows[0])] * (baseline - 4) + rows
    # The light 6 can lose the diagonal that seals its bowl. A rotated 9
    # supplies a conventional 6 with this cut's own weight and roundness.
    six = glyphs[ord('6')]
    if not holes([[v == '#' for v in row] for row in six]):
        nine = glyphs[ord('9')]
        glyphs[ord('6')] = [row[::-1] for row in nine[:baseline][::-1]] + nine[baseline:]


def symmetry_axes(path: str, ch: str) -> tuple[bool, bool]:
    """Whether the glyph design is mirror-symmetric, probed at PROBE_SIZE.

    Only designs that pass here are symmetrized in the final render. The top
    bowl of an 8 is smaller than the bottom one on purpose, and no threshold
    should second-guess that.
    """
    font = ImageFont.truetype(path, PROBE_SIZE)
    img = Image.new("L", (6 * PROBE_SIZE, 6 * PROBE_SIZE), 0)
    ImageDraw.Draw(img).text((PROBE_SIZE, 3 * PROBE_SIZE), ch,
                             font=font, fill=255, anchor="ls")
    bbox = img.getbbox()
    if not bbox:
        return False, False
    region = img.crop(bbox)
    ink = ImageStat.Stat(region).sum[0]
    if not ink:
        return False, False
    hdiff = ImageStat.Stat(ImageChops.difference(
        region, region.transpose(Image.Transpose.FLIP_LEFT_RIGHT))).sum[0]
    vdiff = ImageStat.Stat(ImageChops.difference(
        region, region.transpose(Image.Transpose.FLIP_TOP_BOTTOM))).sum[0]
    # Hinting at the probe size still quantizes a little: a symmetric design
    # measures a few percent (more on a tiny glyph like the dash), the least
    # asymmetric digit measures over 50. Ten percent separates them with room
    # to spare at every cut size.
    return hdiff * 10 < ink, vdiff * 10 < ink


def mirror_average(img: Image.Image, horizontal: bool, vertical: bool) -> None:
    """Average the ink with its mirror, inside its bounding box.

    FreeType places a glyph at a fractional origin, and thresholding that
    render decides which stem keeps a column: a 0 came out with a 2px left
    stem and a 3px right one although the outline is symmetric. Averaging
    with the mirror gives both sides identical coverage, so the threshold
    cuts them identically.
    """
    bbox = img.getbbox()
    if not bbox:
        return
    x0, y0, x1, y1 = bbox
    px = img.load()
    if horizontal:
        for y in range(y0, y1):
            for x in range(x0, (x0 + x1) // 2):
                m = x1 - 1 - (x - x0)
                avg = (px[x, y] + px[m, y] + 1) // 2
                px[x, y] = px[m, y] = avg
    if vertical:
        for x in range(x0, x1):
            for y in range(y0, (y0 + y1) // 2):
                m = y1 - 1 - (y - y0)
                avg = (px[x, y] + px[x, m] + 1) // 2
                px[x, y] = px[x, m] = avg


# Thresholds a cut may be made at, highest first. The nominal threshold is the
# top rung and a cut never goes above it, so a face is never emboldened by this;
# a cut that needs a lower rung only gets back ink it was losing.
THRESHOLD_LADDER = (128, 96, 80, 64, 48, 32, 24, 16)


def render_gray(font: ImageFont.FreeTypeFont, ch: str, cell: int, baseline: int,
                advance: int | None = None, x_off: int = 0,
                sym: tuple[bool, bool] = (False, False)):
    """Draw one glyph, unthresholded. Returns the image and its advance."""
    if advance is None:
        advance = max(1, round(font.getlength(ch)))
    img = Image.new("L", (advance, cell), 0)
    draw = ImageDraw.Draw(img)
    draw.text((x_off, baseline), ch, font=font, fill=255, anchor="ls")
    mirror_average(img, *sym)
    return img, advance


def compact_font(path: str, cell: int):
    """Spend roughly one eighth of the cell on short, recognizable tails."""
    descent = max(1, cell // 8)
    target = cell - descent
    for size in range(cell * 2, 0, -1):
        font = ImageFont.truetype(path, size)
        cap, _ = ink_metrics(font, "H09")
        if cap <= target:
            return font, target
    raise ValueError(f"no font fits {cell}px")


def readable_lowercase(glyphs, baseline, cell):
    """A single-storey g, and a visible dot on i/j even in the smallest cuts."""
    if ord('o') not in glyphs:
        return
    if cell > 7:
        # A y has the same arms as v. Continue their meeting point with a
        # short leftward tail instead of averaging away the thin connection.
        vee = glyphs[ord('v')]
        last = next(row for row in reversed(vee[:baseline]) if '#' in row)
        xs = [x for x, value in enumerate(last) if value == '#']
        tail = []
        for depth in range(1, cell - baseline + 1):
            lo, hi = max(0, min(xs) - depth), max(0, max(xs) - depth)
            if depth == cell - baseline:
                lo = max(0, lo - 1)
            tail.append('.' * lo + '#' * (hi - lo + 1) + '.' * (len(last) - hi - 1))
        glyphs[ord('y')] = vee[:baseline] + tail
    # q already has a single bowl and a connected right-hand descender.
    # Give it a leftward hook instead of q's straight tail.
    bowl = glyphs[ord('q')]
    width = len(bowl[0])
    out = list(bowl)
    xs = [x for row in bowl[baseline:] for x, v in enumerate(row) if v == '#']
    if not xs:
        xs = [x for x, v in enumerate(bowl[baseline - 1]) if v == '#']
    if xs:
        right = max(xs)
        stem = max(1, len(set(xs)))
        for y in range(baseline, cell - 1):
            out[y] = '.' * (right - stem + 1) + '#' * stem + '.' * (width - right - 1)
        start = max(0, right - max(stem + 1, width * 2 // 3))
        out[-1] = '.' * start + '#' * (right - start + 1) + '.' * (width - right - 1)
        glyphs[ord('g')] = out
    for cp in (ord('i'), ord('j')):
        rows = glyphs[cp]
        top = next((y for y, row in enumerate(rows) if '#' in row), None)
        if top is not None and baseline >= 4:
            gap = top + max(1, cell // 10)
            if gap < baseline - 1:
                rows[gap] = '.' * len(rows[0])


def align_numerals(glyphs):
    """Suppress round overshoot so figures occupy the same rows as capitals."""
    cap = [y for y, row in enumerate(glyphs[ord('H')]) if '#' in row]
    top, bottom = min(cap), max(cap)
    for cp in range(48, 58):
        rows = glyphs[cp]
        ink = [y for y, row in enumerate(rows) if '#' in row]
        first, last = min(ink), max(ink)
        height = bottom - top + 1
        body = [rows[first + min(last - first, (y * (last - first + 1)) // height)]
                for y in range(height)]
        # At five/six rows FreeType closes 6 and 8's counters. Hint these
        # bowls explicitly: a filled figure cannot be read on the panel.
        if height in (5, 6) and cp in (54, 56):
            body = (['.##', '#..', '###', '#.#', '###'] if cp == 54 else
                    ['###', '#.#', '###', '#.#', '###'])
            if height == 6:
                body.insert(-1, '#.#')
            width = len(rows[0])
            body = [row.center(width, '.') for row in body]
        blank = '.' * len(rows[0])
        glyphs[cp] = [blank] * top + body + [blank] * (len(rows) - bottom - 1)


def trim_glyphs(glyphs, tabular):
    """Drop redundant side bearings; keep figures and placeholder tabular."""
    group = [cp for cp in glyphs if 48 <= cp <= 57 or cp == 45] if tabular else []
    groups = [group] if group else []
    groups += [[cp] for cp in glyphs if cp not in group]
    for cps in groups:
        ink = [x for cp in cps for row in glyphs[cp]
               for x, value in enumerate(row) if value == '#']
        if ink:
            lo, hi = min(ink), max(ink) + 1
            for cp in cps:
                glyphs[cp] = [row[lo:hi] for row in glyphs[cp]]


def has_ink(px, advance: int, cell: int, t: int) -> bool:
    return any(px[x, y] >= t for y in range(cell) for x in range(advance))


def bits(px, advance: int, cell: int, t: int) -> list[str]:
    return ["".join("#" if px[x, y] >= t else "." for x in range(advance))
            for y in range(cell)]


def cut_threshold(gray: dict, nominal: int, cell: int) -> int:
    """The highest rung at which no glyph of the cut is blank.

    A face at a small cell has stems thinner than a pixel, and a fixed cutoff
    either erases them or doubles them: the Light hyphen at 8px loses its ends
    and survives as a stub, and its l vanishes outright. The cutoff is chosen
    once for the whole cut rather than per glyph, because it is a property of
    the size and not of a glyph. Choosing per glyph is what a face cannot
    afford: it leaves one stem emboldened and its neighbour not, and a rule
    sensitive enough to rescue a vanishing stem will also read antialiasing
    ghosts as marks and cut a well-formed X into two halves.

    Space is exempt; it is meant to be blank.
    """
    for t in THRESHOLD_LADDER:
        if t > nominal:
            continue
        if all(cp == 32 or has_ink(img.load(), adv, cell, t)
               for cp, (img, adv) in gray.items()):
            return t
    return THRESHOLD_LADDER[-1]


def _bbox(rows: list[str]):
    """The smallest box holding every inked pixel, or None for a blank glyph."""
    xs = [x for r in rows for x, ch in enumerate(r) if ch == "#"]
    ys = [y for y, r in enumerate(rows) if "#" in r]
    if not xs:
        return None
    return min(xs), min(ys), max(xs), max(ys)


def _room(rows: list[str], width: int, need: int):
    """Widen the glyph to at least `need`+1 columns so its mark has somewhere
    to go.

    A narrow glyph can fill its whole advance -- at 8px an I and an l are both
    two columns of stem -- and then there is nowhere to draw the mark that
    tells them apart. One or two columns of extra advance is the cheapest fix
    that keeps the letterforms intact; the alternative is leaving two letters
    that a reader cannot tell apart, which is the whole problem being solved.
    """
    if need <= width - 1:
        return rows, width
    pad = need - (width - 1)
    return [r + "." * pad for r in rows], width + pad


def _foot(rows: list[str], xlo: int, xhi: int, y: int) -> None:
    """Ink one row between two columns, inside the glyph's own advance."""
    for x in range(max(0, xlo), min(len(rows[0]) - 1, xhi) + 1):
        rows[y] = rows[y][:x] + "#" + rows[y][x + 1:]


def distinguish(cp: int, rows: list[str]) -> list[str]:
    """Add the mark that tells this glyph from the ones it is confused with.

    At 8px a proportional face draws '1', 'l', 'I' and '|' as the same stem. No
    amount of hinting separates them, because the difference is a design
    decision, not a rendering one, so the reader is given the conventional mark:
    a foot on the 1, a serif on the I, a tail on the l, and a tail below a , and
    a ;.

    A zero keeps the shape the face draws and is never slashed, and a seven is
    never barred: both were tried and both were hated on sight at the panel's
    size, which is the author's call to make -- distinguish() draws only what
    was asked for. 0/O and 7/? are left for the legibility audit to report.

    Every mark is drawn inside the glyph's existing advance and only ever adds
    ink, so widths, layout and the whole-multiple fit are untouched. A glyph with
    no room for its mark (a cell whose last row is its ink) is left as it was
    rather than smudged.
    """
    box = _bbox(rows)
    if box is None:
        return rows
    xlo, ylo, xhi, yhi = box
    out = list(rows)
    width = len(rows[0])

    # The stem the glyph stands on: the columns inked in its lowest rows.
    band = range(max(ylo, yhi - 2), yhi + 1)
    stem = [x for y in band for x, ch in enumerate(rows[y]) if ch == "#"]
    sxlo, sxhi = (min(stem), max(stem)) if stem else (xlo, xhi)

    if cp == 49:                                   # 1 -- baseline foot
        if sxhi - sxlo <= 1:                       # a narrow stem, so it tells
            _foot(out, sxlo - 1, sxhi + 1, yhi)
    elif cp == 73:                                 # I -- top and bottom serifs
        out, width = _room(out, width, sxhi + 1)
        _foot(out, sxlo, sxhi + 1, ylo)
        _foot(out, sxlo, sxhi + 1, yhi)
    elif cp in (44, 59):                           # , ; -- tail below the mark
        if yhi + 1 < len(rows):
            x = xhi + 1 if xhi + 1 < width else xhi
            out[yhi + 1] = out[yhi + 1][:x] + "#" + out[yhi + 1][x + 1:]
    elif cp == 108:                                # l -- tail to the right
        out, width = _room(out, width, sxhi + 1)
        x = sxhi + 1
        for y in (yhi, yhi - 1):
            out[y] = out[y][:x] + "#" + out[y][x + 1:]
        _foot(out, sxhi, x, yhi)
    return out


def emit(path: Path, name: str, role: str, family: str, cell: int,
         baseline: int, gap: int, smooth: bool, downscale: bool,
         glyphs: dict[int, list[str]]) -> None:
    out: list[str] = []
    out.append(f"# {name} - GENERATED by tools/fontraster.py, edit with care.")
    out.append("#")
    out.append("# Regenerate rather than hand-edit whole glyphs; touch up individual")
    out.append("# pixels only where the rasterizer misjudged the size.")
    out.append("")
    out.append(f"@name     {name}")
    out.append(f"@role     {role}")
    out.append(f"@height   {cell}")
    out.append(f"@baseline {baseline}")
    out.append(f"@gap      {gap}")
    out.append(f"@family   {family}")
    out.append(f"@smooth   {'yes' if smooth else 'no'}")
    if downscale:
        out.append("@downscale yes")
    out.append("")
    for cp in sorted(glyphs):
        label = chr(cp) if 32 < cp < 127 else "degree" if cp == DEGREE_SLOT else "space"
        out.append(f"# --- {cp} {label} ---")
        out.append(str(cp))
        for row in glyphs[cp]:
            out.append(f"  |{row}|")
        out.append("")
    text = "\n".join(out)
    before = path.read_text() if path.exists() else ""
    path.write_text(text)
    record(relpath(path), before, text, "fontraster", "rasterize")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("ttf", help="path to the source .ttf")
    ap.add_argument("prefix", help="output name prefix; files are <prefix><height>.font")
    ap.add_argument("role", choices=["text", "digits"])
    ap.add_argument("heights", type=int, nargs="+", help="cell heights to generate")
    ap.add_argument("--family", help="family name (default: the prefix)")
    ap.add_argument("--codepoints", choices=["text", "digits"],
                    help="glyph set (default: the role)")
    ap.add_argument("--threshold", type=int, default=None,
                    help="grayscale cutoff for ink, 0-255 (default: 80 up to "
                         "11px cells, 128 above; small cells need the lower "
                         "cutoff or sub-pixel stems vanish)")
    ap.add_argument("--gap", type=int, default=1,
                    help="source-pixel gap between glyph advances")
    ap.add_argument("--tabular-digits", action="store_true",
                    help="give digits and '-' one common advance in a text face")
    ap.add_argument("--numerals", help="TTF for baseline-aligned tabular numerals")
    ap.add_argument("--compact", action="store_true",
                    help="short descenders and a single-storey lowercase g")
    ap.add_argument("--smooth", choices=["yes", "no"], default="yes",
                    help="whether a fitted scale may anti-alias. 'no' makes "
                         "the cut a set size: fit floors to a whole multiple "
                         "(default: yes)")
    ap.add_argument("--no-distinguish", dest="distinguish", action="store_false",
                    help="skip the conventional marks that tell 1/l/I from the "
                         "glyphs they are confused with at small sizes")
    ap.add_argument("--downscale", action="store_true",
                    help="mark this cut as a high-resolution scaling master")
    args = ap.parse_args()

    family = args.family or args.prefix
    cps = codepoints(args.codepoints or args.role)
    probe = "H09" if args.role == "digits" else "Hgyjq"
    # Symmetry is a property of the design, not of the cut size, so it is
    # probed once per glyph rather than once per cut.
    sym_cache: dict[tuple[str, str], tuple[bool, bool]] = {}

    for cell in sorted(args.heights):
        nominal = args.threshold if args.threshold is not None \
            else (80 if cell <= 11 else 128)
        font, baseline = fit_size(args.ttf, cell, probe)
        if args.compact:
            font, baseline = compact_font(args.ttf, cell)
        numeral_font = font
        if args.numerals:
            cap, _ = ink_metrics(font, "H")
            numeral_font, _ = fit_size(args.numerals, cap, "H09")

        # A clock face takes tabular figures: every digit the same advance, so
        # a time or a placeholder never reflows as its digits change. Without
        # this Open Sans gives '1' a narrower cell than '0', and "--:--" does
        # not hold the width of the time it stands in for.
        tabular = 0
        if args.role == "digits" or args.tabular_digits or args.numerals:
            tabular = max(
                round(numeral_font.getlength(chr(cp))) for cp in cps if 48 <= cp <= 57
            )

        # Every glyph is drawn once, unthresholded, and the cut is made
        # afterwards at a single level -- see cut_threshold for why the level
        # belongs to the size and not to the glyph.
        gray: dict[int, tuple] = {}
        for cp in cps:
            ch = DEGREE_CHAR if cp == DEGREE_SLOT else chr(cp)
            numeric = args.numerals and 45 <= cp <= 58
            face = numeral_font if numeric else font
            source = args.numerals if numeric else args.ttf
            key = (source, ch)
            if key not in sym_cache:
                sym_cache[key] = symmetry_axes(source, ch)
            sym = sym_cache[key]
            if args.compact:
                sym = (ch in DISPLAY_HORIZONTAL or sym[0],
                       ch in DISPLAY_VERTICAL or sym[1])
            # Render the full tail first, then compress just the rows below
            # the baseline. This prevents clipping j/y and enlarges the body.
            _, desc = ink_metrics(face, ch)
            render_cell = max(cell, baseline + desc) if args.compact else cell
            if tabular and (48 <= cp <= 57 or cp == 45):
                own = round(face.getlength(ch))
                gray[cp] = render_gray(face, ch, render_cell, baseline,
                                       advance=tabular,
                                       x_off=(tabular - own) // 2, sym=sym)
            else:
                gray[cp] = render_gray(face, ch, render_cell, baseline, sym=sym)
            if render_cell > cell:
                img, advance = gray[cp]
                tail = img.crop((0, baseline, advance, render_cell)).resize(
                    (advance, cell - baseline), Image.Resampling.BOX)
                img = img.crop((0, 0, advance, cell))
                img.paste(tail, (0, baseline))
                gray[cp] = img, advance

        threshold = cut_threshold(gray, nominal, cell)
        glyphs = {cp: bits(px.load(), adv, cell, threshold)
                  for cp, (px, adv) in gray.items()}

        if args.distinguish:
            glyphs = {cp: distinguish(cp, rows) for cp, rows in glyphs.items()}
        if args.numerals:
            align_numerals(glyphs)
        if args.compact:
            display_metrics(glyphs, baseline, cell)
            readable_lowercase(glyphs, baseline, cell)
            if tabular:
                # Optical hints may change a figure's width, but time and
                # --:-- must still occupy exactly the same advance.
                width = max(len(glyphs[cp][0]) for cp in range(48, 58))
                for cp in [45, *range(48, 58)]:
                    glyphs[cp] = [row.center(width, '.') for row in glyphs[cp]]
        trim_glyphs(glyphs, bool(tabular))

        name = f"{args.prefix}{cell}"
        dest = FONT_SRC_DIR / f"{name}.font"
        emit(dest, name, args.role, family, cell, baseline, args.gap,
             args.smooth == "yes", args.downscale, glyphs)
        print(f"  {name}: cell {cell}px, baseline {baseline}, "
              f"threshold {threshold}, {len(cps)} glyphs")


if __name__ == "__main__":
    sys.exit(main())
