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

The cell a cut asks for is the cell it gets: @height is the number in the
name, so a display14 cut is fourteen rows and a layout that pins it gets the
size the name claims. The rows under the baseline that only y, q, j, g, p and
the brackets use are part of that cell rather than slack taken back from it:
a cut named for a box is the size of the box, and a line of prose keeps the
reserve the face's own descenders need.

A glyph whose design is mirror-symmetric comes out exactly symmetric. FreeType
places glyphs at a fractional origin, and thresholding that render decides
which stem keeps a column, so a raw 0 has a 2px left stem and a 3px right one.
Each glyph is probed for symmetry at 8x resolution (see symmetry_axes), and a
glyph that passes is averaged with its mirror before thresholding. Designs
that are asymmetric on purpose, like the smaller top bowl of an 8, fail the
probe and are left alone.

Usage:
    python3 tools/fontraster.py <ttf> <name-prefix> <role> <height...> \
        [--family NAME] [--codepoints text|digits] [--threshold N]

Example (the commands that build the shipped catalogue):
    python3 tools/fontraster.py /usr/share/fonts/open-sans/OpenSans-Semibold.ttf \
        digits digits 10 12 14 16 18 20 24 28 32 40 48 --family digits --smooth no
    python3 tools/fontraster.py /usr/share/fonts/open-sans/OpenSans-Bold.ttf \
        display text 6 7 8 9 10 11 12 14 16 18 20 24 --family display --smooth no
    python3 tools/fontraster.py /usr/share/fonts/open-sans/OpenSans-Light.ttf \
        display-thin text 6 7 8 9 10 11 12 14 16 18 20 24 --family display-thin --smooth no

Every family is passed --smooth no: each is a ladder of set sizes, and a
fractional scale would split a 1px stem across two panel cells. Regenerating
these reproduces the committed .font sources byte for byte.
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
except ImportError:                        # pragma: no cover
    from tools.fontjournal import record, record_run, relpath
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
    return 150 - bbox[1], bbox[3] - 150


def fit_size(path: str, cell: int, probe: str) -> tuple[ImageFont.FreeTypeFont, int]:
    """Largest FreeType size whose ink fits the cell height.

    Returns the font and the baseline row for that cell: the cap height,
    nudged to center any spare row.
    """
    for size in range(cell + 4, 0, -1):
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
    sym_cache: dict[str, tuple[bool, bool]] = {}

    for cell in sorted(args.heights):
        nominal = args.threshold if args.threshold is not None \
            else (80 if cell <= 11 else 128)
        font, baseline = fit_size(args.ttf, cell, probe)

        # A clock face takes tabular figures: every digit the same advance, so
        # a time or a placeholder never reflows as its digits change. Without
        # this Open Sans gives '1' a narrower cell than '0', and "--:--" does
        # not hold the width of the time it stands in for.
        tabular = 0
        if args.role == "digits" or args.tabular_digits:
            tabular = max(
                round(font.getlength(chr(cp))) for cp in cps if 48 <= cp <= 57
            )

        # Every glyph is drawn once, unthresholded, and the cut is made
        # afterwards at a single level -- see cut_threshold for why the level
        # belongs to the size and not to the glyph.
        gray: dict[int, tuple] = {}
        for cp in cps:
            ch = DEGREE_CHAR if cp == DEGREE_SLOT else chr(cp)
            if ch not in sym_cache:
                sym_cache[ch] = symmetry_axes(args.ttf, ch)
            sym = sym_cache[ch]
            if tabular and (48 <= cp <= 57 or cp == 45):
                own = round(font.getlength(ch))
                gray[cp] = render_gray(font, ch, cell, baseline,
                                       advance=tabular,
                                       x_off=(tabular - own) // 2, sym=sym)
            else:
                gray[cp] = render_gray(font, ch, cell, baseline, sym=sym)

        threshold = cut_threshold(gray, nominal, cell)
        glyphs = {cp: bits(px.load(), adv, cell, threshold)
                  for cp, (px, adv) in gray.items()}

        if args.distinguish:
            glyphs = {cp: distinguish(cp, rows) for cp, rows in glyphs.items()}

        name = f"{args.prefix}{cell}"
        dest = FONT_SRC_DIR / f"{name}.font"
        emit(dest, name, args.role, family, cell, baseline, args.gap,
             args.smooth == "yes", args.downscale, glyphs)
        print(f"  {name}: cell {cell}px, baseline {baseline}, "
              f"threshold {threshold}, {len(cps)} glyphs")


if __name__ == "__main__":
    sys.exit(main())
