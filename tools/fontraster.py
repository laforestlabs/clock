#!/usr/bin/env python3
"""Rasterize a vector font into fonts/*.font ASCII art, one file per size.

fontgen.py compiles hand-edited pixel art into C tables, and that pipeline is
worth keeping: the .font file stays the source of truth, readable and
touch-up-able by hand. But a smooth family wants a cut at many sizes, and
drawing a dozen of those as pixel art is not a job for a person. This tool
renders an open-licensed TTF at each target cell height with FreeType (via
Pillow), thresholds the grayscale coverage to bits and writes the result as a
.font, so the human only edits the cuts that come out wrong.

The cell model matches the hand fonts: every glyph occupies a cell of @height
rows, sits on @baseline measured from the top, and advances by its own width,
which is what makes the family proportional. The FreeType size for a cell is
the largest whose ascent plus descent still fits the cell, so a sans14 cut
uses every row it is given rather than arriving letterboxed.

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

Example:
    python3 tools/fontraster.py /usr/share/fonts/open-sans/OpenSans-Regular.ttf \
        sans text 9 10 11 12 13 14 16 18 20 24 --family sans
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat

ROOT = Path(__file__).resolve().parent.parent
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


def rasterize_glyph(font: ImageFont.FreeTypeFont, ch: str, cell: int,
                    baseline: int, threshold: int, advance: int | None = None,
                    x_off: int = 0, sym: tuple[bool, bool] = (False, False)) -> list[str]:
    if advance is None:
        advance = max(1, round(font.getlength(ch)))
    img = Image.new("L", (advance, cell), 0)
    draw = ImageDraw.Draw(img)
    draw.text((x_off, baseline), ch, font=font, fill=255, anchor="ls")
    mirror_average(img, *sym)
    px = img.load()
    return [
        "".join("#" if px[x, y] >= threshold else "." for x in range(advance))
        for y in range(cell)
    ]


def emit(path: Path, name: str, role: str, family: str, cell: int,
         baseline: int, glyphs: dict[int, list[str]]) -> None:
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
    out.append("@gap      1")
    out.append(f"@family   {family}")
    out.append("@smooth   yes")
    out.append("")
    for cp in sorted(glyphs):
        label = chr(cp) if 32 < cp < 127 else "degree" if cp == DEGREE_SLOT else "space"
        out.append(f"# --- {cp} {label} ---")
        out.append(str(cp))
        for row in glyphs[cp]:
            out.append(f"  |{row}|")
        out.append("")
    path.write_text("\n".join(out))


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
    args = ap.parse_args()

    family = args.family or args.prefix
    cps = codepoints(args.codepoints or args.role)
    probe = "H09" if args.role == "digits" else "Hgyjq"
    # Symmetry is a property of the design, not of the cut size, so it is
    # probed once per glyph rather than once per cut.
    sym_cache: dict[str, tuple[bool, bool]] = {}

    for cell in sorted(args.heights):
        threshold = args.threshold if args.threshold is not None \
            else (80 if cell <= 11 else 128)
        font, baseline = fit_size(args.ttf, cell, probe)
        glyphs: dict[int, list[str]] = {}

        # A clock face takes tabular figures: every digit the same advance, so
        # a time or a placeholder never reflows as its digits change. Without
        # this Open Sans gives '1' a narrower cell than '0', and "--:--" does
        # not hold the width of the time it stands in for.
        tabular = 0
        if args.role == "digits":
            tabular = max(
                round(font.getlength(chr(cp))) for cp in cps if 48 <= cp <= 57
            )

        for cp in cps:
            ch = DEGREE_CHAR if cp == DEGREE_SLOT else chr(cp)
            if ch not in sym_cache:
                sym_cache[ch] = symmetry_axes(args.ttf, ch)
            sym = sym_cache[ch]
            if tabular and (48 <= cp <= 57 or cp == 45):
                own = round(font.getlength(ch))
                glyphs[cp] = rasterize_glyph(font, ch, cell, baseline, threshold,
                                             advance=tabular,
                                             x_off=(tabular - own) // 2, sym=sym)
            else:
                glyphs[cp] = rasterize_glyph(font, ch, cell, baseline, threshold,
                                             sym=sym)
        name = f"{args.prefix}{cell}"
        dest = FONT_SRC_DIR / f"{name}.font"
        emit(dest, name, args.role, family, cell, baseline, glyphs)
        print(f"  {name}: cell {cell}px, baseline {baseline}, threshold {threshold}, {len(cps)} glyphs")


if __name__ == "__main__":
    sys.exit(main())
