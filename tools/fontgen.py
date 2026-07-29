#!/usr/bin/env python3
"""Compile human-editable ASCII-art fonts into C glyph tables.

Bitmap fonts are the entire product on a 64px-tall panel, so they are authored
as readable pixel art in fonts/*.font rather than as hex blobs. Edit the .font
file, rerun this, and the change shows up in both the firmware and the desktop
simulator, because both link the same generated tables.

Source format
-------------
Directives, one per line, before any glyphs:

    @name     tom5x7      identifier used by layouts and ml_font_find()
    @height   7           rows per glyph cell
    @baseline 6           rows from the top of the cell down to the baseline
    @gap      1           horizontal pixels inserted between adjacent glyphs

Then one line per glyph:

    <codepoint> <row>/<row>/...

where each row uses '#' for a lit pixel and '.' for an unlit one. Every row of
a glyph must be the same width; that width becomes the glyph's advance. Widths
may differ between glyphs, which is what makes the font proportional. Blank
lines and lines starting with '#' in column one are comments.

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
        self.height = 0
        self.baseline = 0
        self.gap = 1
        self.glyphs: dict[int, Glyph] = {}
        self._parse()
        self._validate()

    def _parse(self) -> None:
        for lineno, raw in enumerate(self.path.read_text().splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue

            if line.startswith("@"):
                parts = line[1:].split(None, 1)
                if len(parts) != 2:
                    raise FontError(f"{self.path}:{lineno}: malformed directive")
                key, value = parts[0], parts[1].strip()
                if key == "name":
                    self.name = value
                elif key in ("height", "baseline", "gap"):
                    setattr(self, key, int(value))
                else:
                    raise FontError(f"{self.path}:{lineno}: unknown directive @{key}")
                continue

            parts = line.split(None, 1)
            if len(parts) != 2:
                raise FontError(f"{self.path}:{lineno}: expected '<codepoint> <rows>'")
            try:
                codepoint = int(parts[0], 0)
            except ValueError as exc:
                raise FontError(f"{self.path}:{lineno}: bad codepoint {parts[0]!r}") from exc

            rows = parts[1].split("/")
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
        out.append(f" * {self.count} glyphs, codepoints {self.first} to {max(self.glyphs)}, ")
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
        out.append(f"    .first    = {self.first},")
        out.append(f"    .count    = {self.count},")
        out.append(f"    .height   = {self.height},")
        out.append(f"    .baseline = {self.baseline},")
        out.append(f"    .gap      = {self.gap},")
        out.append(f"    .widths   = s_{ident}_widths,")
        out.append(f"    .offsets  = s_{ident}_offsets,")
        out.append(f"    .bitmap   = s_{ident}_bitmap,")
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
            f"fontgen: {font.name:<10} {font.count:3d} glyphs  "
            f"cell {font.height:2d}px  baseline {font.baseline:2d}  {total:5d} bytes"
        )
    print(f"fontgen: wrote {len(outputs)} files to {FONT_OUT_DIR.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
