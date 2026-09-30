#!/usr/bin/env python3
"""Review every .font cut and repair the pixels that lose a reader.

fontraster.py draws a cut from a vector face and fontgen.py compiles the art
into C tables, but neither one looks at the result. This does: it walks every
source under fonts/ and gamekit/fonts/, measures each cut the way the panel
shows it (one source pixel is one emitter, so the 1x art *is* what a reader
sees -- a whole-multiple scale only replicates it), and then repairs the glyphs
whose pixels have lost something the design needs.

The review
----------
Per glyph, on the authored pixels:

  blank        ink nowhere, on a glyph that draws something
  counter      a glyph whose master encloses a counter and whose art encloses
               none: the rasterizer's cutoff is lowered until no glyph of a
               cut is blank, and at a small cell that is low enough to fill an
               aperture in entirely -- a 7px 0 drawn as a solid blob.
  stroke       the cut's thinnest run and how many glyphs are built from it,
               beside the modal stem the rest of the cut is drawn at. A glyph
               a rung under that weight is what the stem-weight repair below
               acts on.
  jog          a stem that steps a column sideways between two rows, which
               reads as a kink in an otherwise straight stroke. Reported only:
               which column the stem should land on is the design's call.
  confusable   the pairs that cost readers (0/O, 1/l/I/|, 5/S, ...), by the
               pixels that actually carry a difference between them, compared
               from the same pen origin. A pair with fewer than --distinct such
               pixels cannot be told apart.

The structure line also carries the cut's thinnest run and its smallest counter,
which are the measurements the C audit reports for the same art.

The repairs
-----------
Each repair is offered only where a measurement says the art is wrong, and is
taken only when the result measurably improves what it targets and costs
nothing else. Nothing is ever re-drawn from taste:

  aperture     Reopen the counters and apertures the cutoff filled in. The
               glyph's master -- the largest cut of the same family, where the
               shape survives -- boxed down to this cut's ink box says which
               cells should be background, and only cells the glyph's own ink
               rings on all four sides may be cleared, so no stroke can be lost
               and the silhouette cannot change. Refused if it would fragment
               the glyph, invent a counter the design lacks, or leave a
               confusable pair a reader could no longer tell apart. This is the
               pass that restores most of the counters in the catalogue.
  stem-weight  Widen a stem the cut drew a rung thinner than the rest of its
               own cut, in a glyph that is a stem -- letters and digits only,
               since a bracket's thin part is a drawing decision.

The master is display-thin24 for display-thin7, digits48 for digits14, and so on. It is the
design at a size where the shape survives, so it is what "this glyph, if the
rasterizer had not over-thickened it" means. Repairing against it is also what
keeps a fixed cut in its family's style rather than in the repairer's.

Everything else the review finds is reported and left alone. Two defect classes
are deliberately *not* claimed: a lone inked pixel, because a stray artifact
and the dot of an i are the same thing to any measurement; and a glyph's
position within its advance, because a proportional face moves a glyph off
centre on purpose (a J hangs left, an f leans in).

Idempotent: art this has already reviewed is a fixed point, so --check is a
usable gate -- it fails when a fontraster.py rerun has dropped the touch-ups.

Usage
-----
    python3 tools/fontreview.py                 # review and repair every cut
    python3 tools/fontreview.py --check         # fail if any repair is pending
    python3 tools/fontreview.py --dry-run       # show the plan, write nothing
    python3 tools/fontreview.py --json          # machine-readable review
    python3 tools/fontreview.py --font display-thin7 display-thin9
    python3 tools/fontreview.py --only aperture # run one repair pass
    python3 tools/fontreview.py --dir fonts     # review one directory

The pipeline order is fontraster.py (draw) -> fontreview.py (touch up) ->
fontgen.py (compile). Regenerating a cut with a plain fontraster rerun loses
the touch-ups, which is what --check is for.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Every write to the art is journalled, so a lost edit can be explained and
# undone: see tools/fontjournal.py. Imported both ways round because these
# tools run as scripts and are also importable as package modules.
try:
    from fontjournal import record, record_run, relpath
except ImportError:                        # pragma: no cover
    from tools.fontjournal import record, record_run, relpath
FONT_SRC_DIR = ROOT / "fonts"
# The game faces live apart because fontgen compiles them into a different
# directory: they never enter the layout registry, but they are still pixels
# drawn for the same panel and get the same review.
GAME_FONT_SRC_DIR = ROOT / "gamekit" / "fonts"

# Coverage a master cell must reach before it counts as ink when a glyph is
# boxed down to a smaller cut. 0.4 is where a one-pixel stroke at the master's
# scale survives: at 0.5 a 2-of-24px stem rounds away and the glyph comes back
# full of holes, at 0.3 its antialiased shoulder keeps a column the design does
# not have. Every 7px digit of display-thin7 reproduced by hand matches at 0.4.
MASTER_COVERAGE = 0.4

# Smallest counter, in master pixels, that counts as a counter at all. The
# largest cut is where the design is drawn plainly, but even there hinting
# leaves a stray enclosed pixel wherever a stroke meets another: display-thin24's N
# reports a one-pixel hole, digits48's 9 a second one. Every real counter in
# every master measures 9px or more, so the floor separates the two cleanly.
MASTER_COUNTER_MIN = 4

# Codepoints the stem pass may touch: letters and digits, whose stroke weight
# is the face's. A bracket, a bar or a slash is a symbol whose thin part is a
# drawing decision -- carrying an I's serif width down a [ turns the bracket
# into a filled block -- so punctuation is left alone and only reported.
def _is_letter_or_digit(cp):
    return (0x30 <= cp <= 0x39 or 0x41 <= cp <= 0x5A or 0x61 <= cp <= 0x7A)


# Fewest pixels that tell a confusable pair apart. Three is where a reader
# starts having something to go on: one pixel is noise, two are a hint.
DISTINCT_MIN = 3

# --------------------------------------------------------------- source model

# The pairs that cost a reader on a small panel, the same list the C audit
# carries so the two agree on what to report. Only groups whose codepoints are
# all present in a font are tested.
CONFUSE = [
    "0O", "0o", "Oo", "1Il|", "5S", "8B", "6G", "9gq", "2Z", "uv",
    "Vv", "CX", "KX", "Pp", "QO", "ce", "sz", "7?", "L1", "t1",
    ",.", "':", ";:", "-_",
]


class FontError(Exception):
    pass


class Glyph:
    """One glyph, and where in the file its pixels live."""

    __slots__ = ("cp", "rows", "line", "block", "row_lines", "row_prefix",
                 "row_suffix", "original")

    def __init__(self, cp, rows, line, block, row_lines, row_prefix, row_suffix):
        self.cp = cp
        self.rows = rows
        self.line = line
        self.block = block
        self.row_lines = row_lines
        self.row_prefix = row_prefix
        self.row_suffix = row_suffix
        self.original = list(rows)

    @property
    def width(self):
        return len(self.rows[0]) if self.rows else 0

    @property
    def dirty(self):
        return self.rows != self.original

    def label(self):
        if self.cp == 32:
            return "space"
        if 32 < self.cp < 127:
            return chr(self.cp)
        return "U+%04X" % self.cp


class Font:
    """One .font source. Immutable apart from the glyph rows."""

    def __init__(self, path):
        self.path = path
        self.lines = path.read_text().split("\n")
        self.name = ""
        self.role = ""
        self.family = ""
        self.smooth = True
        self.downscale = False
        self.height = 0
        self.baseline = 0
        self.gap = 1
        self.planes = 1
        self.glyphs: list[Glyph] = []
        self._parse()
        if not self.family:
            self.family = self.name

    def glyph(self, cp):
        for g in self.glyphs:
            if g.cp == cp:
                return g
        return None

    @property
    def cps(self):
        return [g.cp for g in self.glyphs]

    def _parse(self):
        open_cp = None
        open_rows: list[str] = []
        open_lines: list[int] = []
        row_prefix = row_suffix = ""

        def close():
            nonlocal open_cp, open_rows, open_lines
            if open_cp is None:
                return
            self.glyphs.append(Glyph(open_cp, list(open_rows), open_line,
                                     True, list(open_lines), row_prefix,
                                     row_suffix))
            open_cp, open_rows, open_lines = None, [], []

        for i, raw in enumerate(self.lines):
            line = raw.strip()
            # A row of a block glyph, tested before the comment rule: '#' is
            # the ink character, so a row of solid ink would read as a comment.
            if line.startswith("|"):
                if open_cp is None:
                    raise FontError(f"{self.path}:{i + 1}: glyph row outside a block")
                if len(line) < 2 or not line.endswith("|"):
                    raise FontError(f"{self.path}:{i + 1}: glyph row needs | at both ends")
                if not open_rows:
                    indent = raw[:len(raw) - len(raw.lstrip())]
                    row_prefix, row_suffix = indent + "|", "|"
                open_rows.append(line[1:-1])
                open_lines.append(i)
                continue
            if not line or line.startswith("#"):
                close()
                continue
            if line.startswith("@"):
                close()
                key, _, value = line[1:].partition(" ")
                value = value.strip()
                if not value:
                    raise FontError(f"{self.path}:{i + 1}: malformed directive")
                if key == "name":
                    self.name = value
                elif key == "family":
                    self.family = value
                elif key == "smooth":
                    self.smooth = value == "yes"
                elif key == "downscale":
                    self.downscale = value == "yes"
                elif key == "role":
                    self.role = value
                elif key == "planes":
                    self.planes = int(value)
                elif key in ("height", "baseline", "gap"):
                    setattr(self, key, int(value))
                continue
            parts = line.split(None, 1)
            cp = int(parts[0], 0)
            close()
            if len(parts) == 1:
                open_cp, open_rows, open_lines = cp, [], []
                open_line = i
                row_prefix = row_suffix = ""
            else:
                open_line = i
                self.glyphs.append(Glyph(cp, parts[1].split("/"), i, False,
                                         [], "", ""))
        close()

    def render(self):
        """The file with only the glyph rows that changed replaced."""
        out = list(self.lines)
        for g in self.glyphs:
            if not g.dirty:
                continue
            if g.block:
                for k, li in enumerate(g.row_lines):
                    out[li] = g.row_prefix + g.rows[k] + g.row_suffix
            else:
                out[g.line] = "%d %s" % (g.cp, "/".join(g.rows))
        return "\n".join(out)


# -------------------------------------------------------------------- metrics


def mask(rows):
    """Ink per cell, whichever plane carries it."""
    return [[ch != "." for ch in row] for row in rows]


def bbox(m):
    ys = [y for y, row in enumerate(m) if any(row)]
    if not ys:
        return None
    xs = [x for row in m for x, on in enumerate(row) if on]
    return min(xs), min(ys), max(xs), max(ys)


def _flood(m, sx, sy, want, seen, w, h, conn=4):
    stack = [(sx, sy)]
    seen[sy][sx] = True
    area = 0
    xs0 = ys0 = 10 ** 9
    xs1 = ys1 = -1
    if conn == 8:
        steps = ((1, 0), (-1, 0), (0, 1), (0, -1),
                 (1, 1), (1, -1), (-1, 1), (-1, -1))
    else:
        steps = ((1, 0), (-1, 0), (0, 1), (0, -1))
    while stack:
        x, y = stack.pop()
        area += 1
        xs0 = min(xs0, x); ys0 = min(ys0, y)
        xs1 = max(xs1, x); ys1 = max(ys1, y)
        for dx, dy in steps:
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and m[ny][nx] == want:
                seen[ny][nx] = True
                stack.append((nx, ny))
    return area, (xs0, ys0, xs1, ys1)


def components(m, want=True, conn=8):
    """Connected regions of ink.

    Eight-connected, because that is how the art reads: the caps of a 7px 0
    touch its ring only at the corners, and counting those as three pieces
    would call a keyhole 0 a broken glyph.
    """
    h, w = len(m), len(m[0])
    seen = [[False] * w for _ in range(h)]
    out = []
    for y in range(h):
        for x in range(w):
            if not seen[y][x] and m[y][x] == want:
                out.append(_flood(m, x, y, want, seen, w, h, conn))
    return out


def holes(m):
    """Background regions the glyph encloses, with their boxes and areas.

    Padded so the outside is one region even when the art touches every edge.
    Four-connected on purpose: the background has to be sealed against a
    corner-to-corner leak, which is what closes a counter.
    """
    h, w = len(m), len(m[0])
    pad = [[False] * (w + 2) for _ in range(h + 2)]
    for y in range(h):
        for x in range(w):
            pad[y + 1][x + 1] = m[y][x]
    hh, ww = h + 2, w + 2
    seen = [[False] * ww for _ in range(hh)]
    _flood(pad, 0, 0, False, seen, ww, hh)
    out = []
    for y in range(hh):
        for x in range(ww):
            if not seen[y][x] and not pad[y][x]:
                area, box = _flood(pad, x, y, False, seen, ww, hh)
                out.append((area, (box[0] - 1, box[1] - 1, box[2] - 1, box[3] - 1)))
    return out


def strokes(m):
    """Vertical stroke widths, as the row runs that persist down a column band.

    A run in one row is a stroke's width only if the rows under it carry the
    same run: that is what tells a 2px stem from a 1px bar that happens to be
    two pixels long.
    """
    h, w = len(m), len(m[0])
    runs = []  # (y, x0, x1)
    for y in range(h):
        x = 0
        while x < w:
            if not m[y][x]:
                x += 1
                continue
            x0 = x
            while x < w and m[y][x]:
                x += 1
            runs.append((y, x0, x - 1))
    widths = []
    for i, (y, x0, x1) in enumerate(runs):
        tall = 1
        for (y2, a0, a1) in runs[i + 1:]:
            if y2 != y + tall or a0 != x0 or a1 != x1:
                break
            tall += 1
        if tall >= 3 and tall > (x1 - x0 + 1):
            widths.append(x1 - x0 + 1)
    return widths


class Stats:
    """Everything the review measures about one glyph's art."""

    def __init__(self, rows):
        self.rows = rows
        self.m = mask(rows)
        self.h = len(self.m)
        self.w = len(self.m[0]) if self.m else 0
        self.ink = sum(1 for row in self.m for on in row if on)
        self.box = bbox(self.m)
        self.comps = components(self.m)
        self.holes = holes(self.m)
        self.widths = strokes(self.m)
        self.min_stroke = min(self.widths) if self.widths else 0
        self.modal_stroke = max(set(self.widths), key=self.widths.count) if self.widths else 0

    @property
    def density(self):
        if not self.box:
            return 0.0
        x0, y0, x1, y1 = self.box
        return self.ink / float((x1 - x0 + 1) * (y1 - y0 + 1))

    @property
    def minor_run(self):
        """Thinnest run in either direction, the hairline the cut is built on."""
        best = None
        for row in self.m:
            run = 0
            for on in row + [False]:
                if on:
                    run += 1
                elif run:
                    best = run if best is None else min(best, run)
                    run = 0
        for x in range(self.w):
            run = 0
            for y in range(self.h + 1):
                if y < self.h and self.m[y][x]:
                    run += 1
                else:
                    if run:
                        best = run if best is None else min(best, run)
                    run = 0
        return best or 0


# ------------------------------------------------------------- master lookup


def masters(fonts):
    """The largest cut of each family, which is the design at a legible size."""
    out = {}
    for f in fonts:
        cur = out.get(f.family)
        if cur is None or f.height > cur.height:
            out[f.family] = f
    return out


def master_counters(glyph):
    """The counters a master glyph really has, hinting artifacts excluded.

    The master is where the design is drawn plainly, but even at 24px a stroke
    meeting another leaves a stray enclosed pixel -- display-thin24's N reports one --
    so only regions a reader would see as a counter are counted.
    """
    return [box for area, box in holes(mask(glyph.rows)) if area >= MASTER_COUNTER_MIN]


def box_down(master_rows, shape, coverage=MASTER_COVERAGE):
    """The master glyph boxed down to `shape`, by area coverage.

    Each destination cell takes the share of its box the master inks, and is
    inked when that share reaches `coverage`. Box-averaging is what keeps a
    one-pixel stroke alive: the master's stem covers a third of a destination
    cell at 7px and still reads as ink, where nearest-neighbour sampling would
    step over it and drop the stroke entirely.
    """
    m = mask(master_rows)
    box = bbox(m)
    if box is None:
        return None
    x0, y0, x1, y1 = box
    crop = [row[x0:x1 + 1] for row in m[y0:y1 + 1]]
    ch, cw = len(crop), len(crop[0])
    sh, sw = shape
    out = []
    for i in range(sh):
        row = []
        for j in range(sw):
            ylo, yhi = i * ch / sh, (i + 1) * ch / sh
            xlo, xhi = j * cw / sw, (j + 1) * cw / sw
            acc = 0.0
            for yy in range(int(ylo), int(yhi - 1e-9) + 1):
                fy = min(yhi, yy + 1) - max(ylo, yy)
                if fy <= 0 or yy >= ch:
                    continue
                for xx in range(int(xlo), int(xhi - 1e-9) + 1):
                    fx = min(xhi, xx + 1) - max(xlo, xx)
                    if fx <= 0 or xx >= cw:
                        continue
                    if crop[yy][xx]:
                        acc += fx * fy
            row.append(acc / ((yhi - ylo) * (xhi - xlo)) >= coverage)
        out.append(row)
    return out


# ------------------------------------------------------------------- repairs


def _density(shape):
    return sum(1 for row in shape for on in row if on) / float(
        len(shape) * len(shape[0]))


def surrounded(m, x, y):
    """Whether a cell is ringed by ink on all four sides."""
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nx, ny = x + dx, y + dy
        if not (0 <= ny < len(m) and 0 <= nx < len(m[0])) or not m[ny][nx]:
            return False
    return True


def _mirror_symmetric(m):
    w = len(m[0]) if m else 0
    return all(row[x] == row[w - 1 - x]
               for row in m for x in range(w // 2))


def _symmetrize(shape, x0, width):
    """Keep only the cells a shape and its mirror, about the glyph's axis,
    both ink. The axis is the glyph's, not the box's, so a glyph drawn off
    centre in its advance is still mirrored about the right column."""
    out = [row[:] for row in shape]
    for i, row in enumerate(shape):
        for j in range(len(row)):
            mx = width - 1 - (x0 + j)
            jm = mx - x0
            out[i][j] = row[j] and 0 <= jm < len(row) and shape[i][jm]
    return out


def _keeps_distinct(font, cp, st, new, ctx):
    """Whether a rewrite leaves every confusable pair as tellable apart.

    A glyph may be redrawn, and a pair that already had a margin may lose some
    of it: opening a 0's counter and a 4's at the same time moves several
    pairs both ways. What a rewrite may not do is *create* an ambiguity --
    leave two glyphs a reader could not tell apart where it could before --
    because that is legibility lost for the sake of a metric.
    """
    for group in CONFUSE:
        for ch in group:
            if ch == chr(cp) or not font.glyph(ord(ch)):
                continue
            other = font.glyph(ord(ch))
            was = _distinct(st.m, mask(other.rows))
            now = _distinct(mask(new), mask(other.rows))
            if now < was and now < ctx["distinct"]:
                return False
    return True


def repair_aperture(font, g, st, ctx, out):
    """Reopen the apertures a filled-in glyph has lost, from its master.

    The rasterizer lowers its cutoff until no glyph of a cut is blank, and at
    a small cell that is low enough to fill an aperture in entirely: a 7px 0
    comes out a solid blob and a 7px 5 a 3x3 block. The master -- the family's
    largest cut, where the shape survives -- boxed down to this glyph's ink
    box says which cells should be background.

    Only cells the glyph's own ink rings on all four sides may be cleared, so
    no stroke can be lost and the silhouette cannot change: what the pass can
    do is open a hole, never take a corner off. That is what separates the
    7px 2, 4 and 7 -- where boxing the master down loses a diagonal, and any
    removal from the outline would cost the glyph a stroke -- from the 0, 5
    and 8, where the master marks interior cells the artifact has filled.
    """
    master = ctx["master"]
    if font.role == "icons" or master is None or master is font or not st.box:
        return
    mg = master.glyph(g.cp)
    if not mg:
        return
    # The gate is the master's own counter: a glyph the design encloses
    # background in, that encloses none, is one the cutoff filled in. Density
    # alone cannot say it -- an apostrophe is a solid 2x2 mark by design, and
    # a 1's foot is a solid bar -- so a glyph with no counter in its master is
    # never opened here.
    if st.holes or not master_counters(mg):
        return
    x0, y0, x1, y1 = st.box
    w, h = x1 - x0 + 1, y1 - y0 + 1
    if w < 3 or h < 3:
        return
    candidate = box_down(mg.rows, (h, w))
    if candidate is None:
        return
    # A glyph that is mirror-symmetric is meant to stay so. A master can carry
    # ink on one flank only -- display24's B has the rail that tells it from an
    # 8 -- and boxing that down leaves the mark's residue in a cut that draws
    # no mark at all; keeping only the cells both halves agree on drops it and
    # leaves the aperture symmetric.
    if _mirror_symmetric(st.m):
        candidate = _symmetrize(candidate, x0, st.w)
    cut = [(x0 + j, y0 + i)
           for i in range(h) for j in range(w)
           if not candidate[i][j] and surrounded(st.m, x0 + j, y0 + i)]
    if not cut:
        return
    rows = [list(r) for r in g.rows]
    for x, y in cut:
        rows[y][x] = "."
    new = ["".join(r) for r in rows]
    after = Stats(new)
    cand_ink = sum(1 for row in candidate for on in row if on)
    if after.ink == 0 or after.ink >= st.ink or after.ink < cand_ink:
        return
    if not after.holes or len(after.holes) > len(master_counters(mg)):
        return
    if len(after.comps) > len(st.comps) or len(after.comps) > len(components(candidate)):
        return
    if not _keeps_distinct(font, g.cp, st, new, ctx):
        return
    g.rows = new
    out.append(("aperture", g, "density %.2f -> %.2f (master %.2f)"
                % (st.density, after.density, _density(candidate))))


def repair_stem_weight(font, g, st, ctx, out):
    """Widen a stem the cut drew thinner than the rest of its own cut.

    A face has one stroke weight, and a glyph that renders a rung under it is
    the rasterizer losing a sub-pixel stem, not a lighter letter: the display10
    I came out a 1px hairline under 2px serifs in a family whose every other
    stem is 2px. The repair is the one that I took by hand -- run the foot's
    columns down the whole glyph -- and it is confined to glyphs that *are* a
    stem, so a bar or a bowl is never thickened.
    """
    if font.role == "icons" or not st.box or ctx["stroke"] < 2:
        return
    if not _is_letter_or_digit(g.cp):
        return
    target = ctx["stroke"]
    x0, y0, x1, y1 = st.box
    if not st.widths or min(st.widths) >= target:
        return
    # A stem glyph is one whose ink box is barely wider than the stroke it
    # should carry: anything wider is a bar, a bowl or a diagonal, where the
    # thin run is a join rather than a lost stem.
    if (x1 - x0 + 1) > target + 1:
        return
    band = set()
    for y in range(y0, y1 + 1):
        band.update(x for x in range(x0, x1 + 1) if st.m[y][x])
    if len(band) != target:
        return
    rows = [list(r) for r in g.rows]
    for y in range(y0, y1 + 1):
        for x in band:
            rows[y][x] = "#"
    new = ["".join(r) for r in rows]
    after = Stats(new)
    if after.ink <= st.ink or after.density > 1.0:
        return
    if not _keeps_distinct(font, g.cp, st, new, ctx):
        return
    g.rows = new
    out.append(("stem-weight", g, "%dpx stem raised to the cut's %dpx"
                % (min(st.widths), target)))


# Repair passes, in the order they run. The aperture pass reopens what the
# rasterizer filled; the stem pass restores a stroke the cut lost. Each one
# re-measures the glyph before deciding, so a later pass sees what an earlier
# one did.
REPAIRS = {
    "aperture": (repair_aperture, 90),
    "stem-weight": (repair_stem_weight, 70),
}


# -------------------------------------------------------------------- review


def cut_stroke(font):
    """The stroke weight this cut is drawn at, as its commonest stem.

    Per cut, not per family: a cut has one weight, and the glyphs that break
    it are the rasterizer losing a sub-pixel stem -- one hairline in a cut
    whose every other stem is 2px. Taking the weight across the family instead
    would compare a 7px cut's deliberate 1px strokes against a 24px cut's 3px
    ones and thicken the whole small end of the ladder.
    """
    widths = []
    for g in font.glyphs:
        widths.extend(Stats(g.rows).widths)
    return max(set(widths), key=widths.count) if widths else 0


def jog(rows):
    """Row pairs where the stem's column band steps sideways by a pixel.

    A stem that jumps a column between one row and the next is the rasterizer
    quantizing a slant, and the step reads as a kink in an otherwise straight
    stroke. Reported, not repaired: which side the stem should land on is the
    design's call.
    """
    m = mask(rows)
    h = len(m)
    w = len(m[0]) if m else 0
    runs = []
    for y in range(h):
        x = 0
        while x < w:
            if not m[y][x]:
                x += 1
                continue
            x0 = x
            while x < w and m[y][x]:
                x += 1
            runs.append((y, x0, x - 1))
    steps = []
    for y, x0, x1 in runs:
        for y2, a0, a1 in runs:
            if y2 == y + 1 and (a1 - a0) == (x1 - x0) and a0 != x0:
                steps.append((y, x0, a0))
    return steps


def review_font(font, ctx, opts, apply_repairs):
    """Measure one cut, then offer it every repair whose measurement says so."""
    master = ctx["master"]
    repairs = []
    stats = {g.cp: Stats(g.rows) for g in font.glyphs}

    blanks = [g for g in font.glyphs if g.cp != 32 and stats[g.cp].ink == 0]
    hairlines = [g for g in font.glyphs if stats[g.cp].ink and stats[g.cp].minor_run == 1]
    holesizes = [a for g in font.glyphs for a, _box in stats[g.cp].holes]
    jogs = [(g, jog(g.rows)) for g in font.glyphs if jog(g.rows)]

    # A glyph the design encloses background in, that does not enclose any.
    counter_want = []
    counter_bearing = 0
    for g in font.glyphs:
        st = stats[g.cp]
        if g.cp == 32 or st.ink == 0:
            continue
        if st.holes:
            counter_bearing += 1
        elif master is not None and master is not font:
            mg = master.glyph(g.cp)
            if mg and master_counters(mg):
                counter_want.append(g)

    ambiguous = []
    for group in CONFUSE:
        present = [c for c in group if font.glyph(ord(c))]
        for i in range(len(present)):
            for j in range(i + 1, len(present)):
                d = _distinct(stats[ord(present[i])].m, stats[ord(present[j])].m)
                if d < opts.distinct:
                    ambiguous.append((d, present[i], present[j]))

    if apply_repairs:
        for g in font.glyphs:
            if g.cp == 32:
                continue
            st = stats[g.cp]
            for name in opts.only:
                before = g.rows
                REPAIRS[name][0](font, g, st, ctx, repairs)
                if g.rows != before:
                    st = Stats(g.rows)

    return {
        "font": font,
        "stats": stats,
        "blanks": blanks,
        "hairlines": hairlines,
        "min_hole": min(holesizes, default=0),
        "counter_bearing": counter_bearing,
        "counter_want": counter_want,
        "jogs": jogs,
        "ambiguous": sorted(ambiguous),
        "repairs": repairs,
    }


def _distinct(ma, mb):
    """Cells exactly one of the two inks, compared from the same origin.

    From the same origin on purpose: aligning by ink box would throw away the
    vertical position that separates a hyphen from an underscore.
    """
    h = max(len(ma), len(mb))
    w = max(len(ma[0]) if ma else 0, len(mb[0]) if mb else 0)
    n = 0
    for y in range(h):
        for x in range(w):
            a = ma[y][x] if y < len(ma) and x < len(ma[0]) else False
            b = mb[y][x] if y < len(mb) and x < len(mb[0]) else False
            if a != b:
                n += 1
    return n


# ------------------------------------------------------------------- reports


def report_text(rev, out=sys.stdout):
    font = rev["font"]
    print(f"=== {font.name}  [{font.role}]  cell {font.height}px  "
          f"family {font.family}  {len(font.glyphs)} glyphs", file=out)
    st = rev["stats"]
    inks = [st[g.cp].ink for g in font.glyphs]
    print(f"    structure: ink {sum(inks)}, min stroke "
          f"{min((s.minor_run for s in st.values() if s.ink), default=0)}px, "
          f"{len(rev['hairlines'])} hairline glyph(s), "
          f"{rev['counter_bearing']} counter(s), smallest {rev['min_hole']}px",
          file=out)
    for g in rev["blanks"]:
        print(f"    !! blank: #{g.cp} {g.label()}", file=out)
    for g in rev["counter_want"]:
        print(f"    !! counter closed: #{g.cp} {g.label()}", file=out)
    if rev["jogs"]:
        cps = " ".join("#%d %s" % (g.cp, g.label()) for g, _ in rev["jogs"][:8])
        print(f"    !  stem jogs (report only): {cps}", file=out)
    if rev["ambiguous"]:
        print("    !  confusable (fewest distinguishing pixels first):", file=out)
        for d, a, b in rev["ambiguous"][:8]:
            print(f"      {d:3d}px distinct  '{a}' / '{b}'   AMBIGUOUS", file=out)
    for name, g, note in rev["repairs"]:
        print(f"    -> {name:12s} #{g.cp} {g.label():<5s} {note}", file=out)
    if not rev["repairs"]:
        print("    clean: no repair pending", file=out)


def report_json(rev):
    font = rev["font"]
    st = rev["stats"]
    return {
        "name": font.name,
        "role": font.role,
        "family": font.family,
        "height": font.height,
        "baseline": font.baseline,
        "gap": font.gap,
        "glyphs": len(font.glyphs),
        "min_stroke": min((s.min_stroke for s in st.values() if s.ink), default=0),
        "hairlines": len(rev["hairlines"]),
        "counters": rev["counter_bearing"],
        "min_counter": rev["min_hole"],
        "counter_closed": [g.cp for g in rev["counter_want"]],
        "jogs": [g.cp for g, _ in rev["jogs"]],
        "blank": [g.cp for g in rev["blanks"]],
        "ambiguous": [{"distinct": d, "a": ord(a), "b": ord(b)}
                      for d, a, b in rev["ambiguous"]],
        "repairs": [{"pass": n, "codepoint": g.cp, "note": note}
                    for n, g, note in rev["repairs"]],
    }


# -------------------------------------------------------------------- driver


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dir", nargs="+", default=None,
                    help="directories of .font sources "
                         "(default: fonts/ and gamekit/fonts/)")
    ap.add_argument("--check", action="store_true",
                    help="write nothing; exit 1 if any repair is pending")
    ap.add_argument("--dry-run", action="store_true",
                    help="show the repairs but write nothing")
    ap.add_argument("--json", action="store_true", help="machine-readable review")
    ap.add_argument("--font", nargs="*", default=None,
                    help="review only these cuts (default: all of the directory)")
    ap.add_argument("--only", nargs="*", default=list(REPAIRS),
                    choices=sorted(REPAIRS), help="run only these repair passes")
    ap.add_argument("--distinct", type=int, default=DISTINCT_MIN,
                    help="fewest distinguishing pixels a confusable pair may have")
    ap.add_argument("--quiet", action="store_true",
                    help="print only the summary")
    opts = ap.parse_args(argv)

    dirs = [Path(d) for d in opts.dir] if opts.dir else [
        d for d in (FONT_SRC_DIR, GAME_FONT_SRC_DIR) if d.is_dir()]
    all_paths = sorted(p for d in dirs for p in d.glob("*.font"))
    paths = all_paths
    if opts.font:
        want = set(opts.font)
        paths = [p for p in all_paths if p.stem in want]
        missing = want - {p.stem for p in paths}
        if missing:
            raise SystemExit(f"no such font: {', '.join(sorted(missing))}")

    # The family context -- which cut is the master -- is read from the whole
    # directory even when only some cuts are reviewed, or a one-cut review
    # would compare that cut with itself.
    family = [Font(p) for p in all_paths]
    if not family:
        raise SystemExit("no .font sources in " + ", ".join(str(d) for d in dirs))
    design = masters(family)

    fonts = [Font(p) for p in paths]

    write = not (opts.check or opts.dry_run)
    reports = []
    changed = 0
    for font in fonts:
        ctx = {"master": design.get(font.family), "stroke": cut_stroke(font),
               "distinct": opts.distinct}
        rev = review_font(font, ctx, opts, apply_repairs=True)
        reports.append(rev)
        if any(g.dirty for g in font.glyphs):
            changed += 1
            if write:
                text = font.render()
                before = font.path.read_text() if font.path.exists() else ""
                font.path.write_text(text)
                record(relpath(font.path), before, text,
                       "fontreview", "repair")
        if not opts.json and not opts.quiet:
            report_text(rev)

    if opts.json:
        print(json.dumps({
            "fonts": [report_json(r) for r in reports],
        }, indent=2))

    pending = sum(len(r["repairs"]) for r in reports)
    state = "written" if write else ("pending" if pending else "clean")
    note = (f"reviewed {len(fonts)} cut(s): {pending} repair(s) {state}, "
            f"{changed} file(s) {'changed' if write else 'would change'}")
    print(note, file=sys.stderr if opts.json else sys.stdout)

    if opts.check and pending:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
