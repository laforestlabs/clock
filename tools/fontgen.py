#!/usr/bin/env python3
"""Compile human-editable ASCII-art fonts into C glyph tables.

Bitmap fonts are the entire product on a 64px-tall panel, so they are authored
as readable pixel art in fonts/*.font rather than as hex blobs. Edit the .font
file, rerun this, and the change shows up in both the firmware and the desktop
simulator, because both link the same generated tables.

Source format
-------------
Directives, one per line, before any glyphs:

    @name     sans9        identifier used by layouts and ml_font_find()
    @role     text        text, digits or icons (see below)
    @height   9           rows per glyph cell
    @baseline 7           rows from the top of the cell down to the baseline
    @gap      1           horizontal pixels inserted between adjacent glyphs
    @family   pixel       style this cut belongs to (default: the @name)
    @smooth   no          yes: fractional scales anti-alias (default)
                          no:  box-derived scales floor to whole multiples

@family groups cuts into one style in many sizes. A layout naming a family
gets the cut that fills its box; naming a cut pins that cut. Every cut of a
family must agree on @role and @smooth, because those are what make the style
one style, and fontgen refuses to compile a family that splits on either.

@role is required, because it is the one property of a font that its bitmaps
cannot imply and the renderer cannot guess:

    text      the full printable range, safe to substitute for any string
    digits    a clock or temperature face: digits and a little punctuation
    icons     pictograms indexed by digit, never a stand-in for text

A clock face and an icon set carry the same ten codepoints, so without this the
renderer answering "what can draw 23?" cannot tell a numeral from a rain cloud.

Then one line per glyph:

    <codepoint> <row>/<row>/...

where each row uses '#' for a lit pixel and '.' for an unlit one. Every row of
a glyph must be the same width; that width becomes the glyph's advance. Widths
may differ between glyphs, which is what makes the font proportional. Blank
lines and lines starting with '#' in column one are comments.

Tall glyphs may instead be written as a block, which is the same data laid out
so it can actually be read and edited as the picture it is:

    48
      |......########......|
      |....############....|
      ...

A bare codepoint opens the block and the rows follow, each bracketed by '|'.
The bars are what make this unambiguous: '#' is the ink character, so without
them a row of solid ink would be indistinguishable from a comment. A blank
line, a comment or the next codepoint closes the block. Use the single-line
form for small glyphs, where it stays readable and stays compact.

Output
------
core/src/fonts/font_<name>.c   one per source font
core/src/fonts/font_registry.c the lookup table ml_font_find() walks

Glyph bitmaps are packed row-major, one bit per pixel, MSB first, each row
padded up to a whole byte. Byte-aligning rows costs a little flash and saves
the renderer from cross-byte bit shifting in its innermost loop.

Usage: python3 tools/fontgen.py [--check]
       --check verifies the generated files are up to date without writing.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FONT_SRC_DIR = ROOT / "fonts"
FONT_OUT_DIR = ROOT / "core" / "src" / "fonts"


class FontError(Exception):
    pass


# Source spelling to the ml_font_role enumerator it emits.
ROLES = {
    "text": "ML_FONT_TEXT",
    "digits": "ML_FONT_DIGITS",
    "icons": "ML_FONT_ICONS",
}


class Glyph:
    def __init__(self, codepoint: int, rows: list[str]):
        self.codepoint = codepoint
        self.rows = rows
        self.width = len(rows[0]) if rows else 0

    def pack(self, height: int) -> bytes:
        """Pack to row-major bits, MSB first, each row padded to a byte."""
        stride = (self.width + 7) // 8
        out = bytearray()
        for r in range(height):
            row = self.rows[r] if r < len(self.rows) else "." * self.width
            rowbytes = bytearray(stride)
            for x, ch in enumerate(row):
                if ch == "#":
                    rowbytes[x // 8] |= 0x80 >> (x % 8)
            out += rowbytes
        return bytes(out)


class Font:
    def __init__(self, path: Path):
        self.path = path
        self.name = ""
        self.role = ""
        self.height = 0
        self.baseline = 0
        self.gap = 1
        self.family = ""
        self.smooth = True
        self.downscale = False
        self.glyphs: dict[int, Glyph] = {}
        self._parse()
        self._validate()

    def _parse(self) -> None:
        pending: int | None = None
        rows: list[str] = []
        opened_at = 0

        def flush() -> None:
            nonlocal pending, rows
            if pending is not None:
                self._add_glyph(pending, rows, opened_at)
            pending, rows = None, []

        for lineno, raw in enumerate(self.path.read_text().splitlines(), 1):
            line = raw.strip()

            # A row of a block glyph. Tested before the comment rule on
            # purpose: '#' is the ink character, so a row of solid ink would
            # otherwise read as a comment.
            if line.startswith("|"):
                if pending is None:
                    raise FontError(
                        f"{self.path}:{lineno}: glyph row outside a block, "
                        f"expected a bare codepoint first"
                    )
                rows.append(line.strip("|"))
                continue

            if not line or line.startswith("#"):
                flush()
                continue

            if line.startswith("@"):
                flush()
                parts = line[1:].split(None, 1)
                if len(parts) != 2:
                    raise FontError(f"{self.path}:{lineno}: malformed directive")
                key, value = parts[0], parts[1].strip()
                if key == "name":
                    self.name = value
                elif key == "family":
                    self.family = value
                elif key == "smooth":
                    if value not in ("yes", "no"):
                        raise FontError(
                            f"{self.path}:{lineno}: @smooth expects yes or no"
                        )
                    self.smooth = value == "yes"
                elif key == "downscale":
                    if value not in ("yes", "no"):
                        raise FontError(
                            f"{self.path}:{lineno}: @downscale expects yes or no"
                        )
                    self.downscale = value == "yes"
                elif key == "role":
                    if value not in ROLES:
                        raise FontError(
                            f"{self.path}:{lineno}: unknown @role {value!r}, "
                            f"expected one of {', '.join(sorted(ROLES))}"
                        )
                    self.role = value
                elif key in ("height", "baseline", "gap"):
                    setattr(self, key, int(value))
                else:
                    raise FontError(f"{self.path}:{lineno}: unknown directive @{key}")
                continue

            parts = line.split(None, 1)
            try:
                codepoint = int(parts[0], 0)
            except ValueError as exc:
                raise FontError(f"{self.path}:{lineno}: bad codepoint {parts[0]!r}") from exc

            flush()
            if len(parts) == 1:
                pending, rows, opened_at = codepoint, [], lineno
            else:
                self._add_glyph(codepoint, parts[1].split("/"), lineno)

        flush()

    def _add_glyph(self, codepoint: int, rows: list[str], lineno: int) -> None:
        if not rows:
            raise FontError(f"{self.path}:{lineno}: glyph {codepoint} has no rows")

        widths = {len(r) for r in rows}
        if len(widths) != 1:
            raise FontError(
                f"{self.path}:{lineno}: glyph {codepoint} has ragged rows {sorted(widths)}"
            )
        bad = set("".join(rows)) - {"#", "."}
        if bad:
            raise FontError(
                f"{self.path}:{lineno}: glyph {codepoint} has stray characters {sorted(bad)}"
            )
        if len(rows) != self.height:
            raise FontError(
                f"{self.path}:{lineno}: glyph {codepoint} has {len(rows)} rows, "
                f"@height says {self.height}"
            )
        if codepoint in self.glyphs:
            raise FontError(f"{self.path}:{lineno}: duplicate codepoint {codepoint}")

        self.glyphs[codepoint] = Glyph(codepoint, rows)

    def _validate(self) -> None:
        if not self.name:
            raise FontError(f"{self.path}: missing @name")
        # A cut with no declared family is a family of one, named after itself,
        # so the runtime never has to handle a missing family.
        if not self.family:
            self.family = self.name
        # Deliberately not defaulted. Whichever way a default fell it would be
        # wrong for some font silently, and the whole point of the role is that
        # the glyphs never imply it.
        if not self.role:
            raise FontError(
                f"{self.path}: missing @role, expected one of "
                f"{', '.join(sorted(ROLES))}"
            )
        if self.height <= 0:
            raise FontError(f"{self.path}: missing or invalid @height")
        if not self.glyphs:
            raise FontError(f"{self.path}: no glyphs")
        if self.baseline > self.height:
            raise FontError(f"{self.path}: @baseline {self.baseline} exceeds @height")

        # The runtime indexes glyphs as (codepoint - first), so the range has to
        # be dense. Report the gaps rather than silently emitting blanks, since a
        # missing glyph shows up as a hole in rendered text.
        lo, hi = min(self.glyphs), max(self.glyphs)
        missing = [c for c in range(lo, hi + 1) if c not in self.glyphs]
        if missing:
            preview = ", ".join(f"{c} ({chr(c)!r})" for c in missing[:8])
            more = f" and {len(missing) - 8} more" if len(missing) > 8 else ""
            raise FontError(f"{self.path}: gap in codepoint range: {preview}{more}")

    @property
    def first(self) -> int:
        return min(self.glyphs)

    @property
    def count(self) -> int:
        return len(self.glyphs)

    def emit_c(self) -> str:
        ordered = [self.glyphs[c] for c in sorted(self.glyphs)]

        offsets: list[int] = []
        blob = bytearray()
        for glyph in ordered:
            offsets.append(len(blob))
            blob += glyph.pack(self.height)

        if len(blob) > 0xFFFF:
            raise FontError(f"{self.path}: bitmap exceeds the 64KB uint16 offset range")

        ident = self.name.replace("-", "_")
        out: list[str] = []
        out.append("/*")
        out.append(f" * font_{ident}.c - GENERATED FILE, DO NOT EDIT.")
        out.append(" *")
        out.append(f" * Source:      fonts/{self.path.name}")
        out.append(" * Regenerate:  python3 tools/fontgen.py")
        out.append(" *")
        out.append(f" * {self.count} glyphs, codepoints {self.first} to {max(self.glyphs)}, role {self.role}, ")
        out.append(f" * cell height {self.height}, baseline {self.baseline}, {len(blob)} bytes of bitmap.")
        out.append(" */")
        out.append('#include "mirror/font.h"')
        out.append("")

        out.append(f"static const uint8_t s_{ident}_bitmap[{len(blob)}] = {{")
        for glyph in ordered:
            stride = (glyph.width + 7) // 8
            packed = glyph.pack(self.height)
            label = repr(chr(glyph.codepoint)) if 32 < glyph.codepoint < 127 else ""
            out.append(f"    /* {glyph.codepoint} {label} width {glyph.width} */")
            for r in range(self.height):
                rowbytes = packed[r * stride:(r + 1) * stride]
                art = glyph.rows[r].replace(".", " ") if r < len(glyph.rows) else ""
                hexes = " ".join(f"0x{b:02X}," for b in rowbytes)
                out.append(f"    {hexes:<24}/* |{art}| */")
        out.append("};")
        out.append("")

        widths = ", ".join(str(g.width) for g in ordered)
        out.append(f"static const uint8_t s_{ident}_widths[{self.count}] = {{")
        for i in range(0, len(ordered), 16):
            chunk = ordered[i:i + 16]
            out.append("    " + " ".join(f"{g.width:2d}," for g in chunk))
        out.append("};")
        out.append("")

        out.append(f"static const uint16_t s_{ident}_offsets[{self.count}] = {{")
        for i in range(0, len(offsets), 12):
            chunk = offsets[i:i + 12]
            out.append("    " + " ".join(f"{o:5d}," for o in chunk))
        out.append("};")
        out.append("")

        out.append(f"const ml_font ml_font_{ident} = {{")
        out.append(f'    .name     = "{self.name}",')
        out.append(f"    .role     = {ROLES[self.role]},")
        out.append(f"    .first    = {self.first},")
        out.append(f"    .count    = {self.count},")
        out.append(f"    .height   = {self.height},")
        out.append(f"    .baseline = {self.baseline},")
        out.append(f"    .gap      = {self.gap},")
        out.append(f"    .widths   = s_{ident}_widths,")
        out.append(f"    .offsets  = s_{ident}_offsets,")
        out.append(f"    .bitmap   = s_{ident}_bitmap,")
        out.append(f'    .family   = "{self.family}",')
        out.append(f"    .smooth   = {'true' if self.smooth else 'false'},")
        out.append(f"    .downscale = {'true' if self.downscale else 'false'},")
        out.append("};")
        out.append("")
        del widths
        return "\n".join(out)


def emit_registry(fonts: list[Font]) -> str:
    out: list[str] = []
    out.append("/*")
    out.append(" * font_registry.c - GENERATED FILE, DO NOT EDIT.")
    out.append(" *")
    out.append(" * Regenerate: python3 tools/fontgen.py")
    out.append(" *")
    out.append(" * The first entry is the fallback returned by ml_font_default() when a")
    out.append(" * layout names a font that does not exist, so keep a readable small font")
    out.append(" * first in sort order.")
    out.append(" */")
    out.append('#include "mirror/font.h"')
    out.append("")
    for font in fonts:
        ident = font.name.replace("-", "_")
        out.append(f"extern const ml_font ml_font_{ident};")
    out.append("")
    out.append(f"const ml_font *const ml_font_registry[{len(fonts)}] = {{")
    for font in fonts:
        ident = font.name.replace("-", "_")
        out.append(f"    &ml_font_{ident},")
    out.append("};")
    out.append("")
    out.append(f"const int ml_font_registry_count = {len(fonts)};")
    out.append("")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    check_only = "--check" in argv

    sources = sorted(FONT_SRC_DIR.glob("*.font"))
    if not sources:
        print(f"fontgen: no .font files in {FONT_SRC_DIR}", file=sys.stderr)
        return 1

    try:
        fonts = [Font(path) for path in sources]
    except FontError as exc:
        print(f"fontgen: {exc}", file=sys.stderr)
        return 1

    names = [f.name for f in fonts]
    if len(set(names)) != len(names):
        print(f"fontgen: duplicate @name among {names}", file=sys.stderr)
        return 1

    # A family is one style in many sizes, so its cuts must agree on the two
    # things that define the style: the role (what it may be handed) and the
    # smoothness (how it scales). A cut that disagrees splits the family in a
    # way the runtime cannot see.
    by_family: dict[str, Font] = {}
    for font in fonts:
        first = by_family.setdefault(font.family, font)
        if (first.role != font.role or first.smooth != font.smooth or
                first.downscale != font.downscale):
            print(
                f"fontgen: {font.path.name}: family {font.family!r} splits on "
                f"role, @smooth or @downscale between {first.path.name} and it",
                file=sys.stderr,
            )
            return 1

    # Sort so the smallest-height font lands first and becomes the fallback.
    fonts.sort(key=lambda f: (f.height, f.name))

    FONT_OUT_DIR.mkdir(parents=True, exist_ok=True)
    outputs = {FONT_OUT_DIR / f"font_{f.name.replace('-', '_')}.c": f.emit_c() for f in fonts}
    outputs[FONT_OUT_DIR / "font_registry.c"] = emit_registry(fonts)

    stale = []
    for path, text in outputs.items():
        current = path.read_text() if path.exists() else None
        if current != text:
            stale.append(path)
            if not check_only:
                path.write_text(text)

    if check_only:
        if stale:
            for path in stale:
                print(f"fontgen: out of date: {path.relative_to(ROOT)}", file=sys.stderr)
            return 1
        print("fontgen: generated files are up to date")
        return 0

    for font in fonts:
        total = sum(((g.width + 7) // 8) * font.height for g in font.glyphs.values())
        print(
            f"fontgen: {font.name:<10} {font.role:<6} {font.count:3d} glyphs  "
            f"cell {font.height:2d}px  baseline {font.baseline:2d}  {total:5d} bytes"
        )
    print(f"fontgen: wrote {len(outputs)} files to {FONT_OUT_DIR.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
