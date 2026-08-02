#!/usr/bin/env python3
"""Render sample text from a .font source straight to the terminal.

Editing pixel art blind is miserable. This reads the same source fontgen.py
consumes and shows what a string actually looks like, so a misplaced pixel is
obvious before it ends up in a golden image.

Usage:
    python3 tools/fontproof.py tom5x7 "Wed 29 Jul"
    python3 tools/fontproof.py digits16 "09:41"
    python3 tools/fontproof.py tom5x7 --all
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

ON, OFF = "██", "··"


def load(name: str) -> tuple[dict[int, list[str]], int, int]:
    path = ROOT / "fonts" / f"{name}.font"
    if not path.exists():
        available = sorted(p.stem for p in (ROOT / "fonts").glob("*.font"))
        raise SystemExit(f"no such font {name!r}. Available: {', '.join(available)}")

    glyphs: dict[int, list[str]] = {}
    height = gap = 0
    pending: int | None = None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line.startswith("|"):
            if pending is not None:
                glyphs.setdefault(pending, []).append(line.strip("|"))
            continue
        if not line or line.startswith("#"):
            pending = None
            continue
        if line.startswith("@"):
            pending = None
            key, _, value = line[1:].partition(" ")
            if key == "height":
                height = int(value)
            elif key == "gap":
                gap = int(value)
            continue
        parts = line.split(None, 1)
        cp = int(parts[0], 0)
        if len(parts) == 1:
            pending = cp
            glyphs[cp] = []
        else:
            pending = None
            glyphs[cp] = parts[1].split("/")
    return glyphs, height, gap


def render(glyphs: dict[int, list[str]], height: int, gap: int, text: str) -> None:
    chosen = [glyphs[ord(c)] for c in text if ord(c) in glyphs]
    missing = sorted({c for c in text if ord(c) not in glyphs})
    if not chosen:
        print("  (no renderable glyphs)")
        return
    for row in range(height):
        cells = [g[row] for g in chosen]
        line = ("." * gap).join(cells)
        print("  " + "".join(ON if ch == "#" else OFF for ch in line))
    width = sum(len(g[0]) for g in chosen) + gap * (len(chosen) - 1)
    print(f"  -> {width}px wide, {height}px tall")
    if missing:
        print(f"  !! not in this font: {missing}")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2

    name, arg = argv[0], argv[1]
    glyphs, height, gap = load(name)

    if arg == "--all":
        printable = sorted(c for c in glyphs if 32 < c < 127)
        for start in range(0, len(printable), 16):
            chunk = "".join(chr(c) for c in printable[start:start + 16])
            print(f"\n{chunk!r}")
            render(glyphs, height, gap, chunk)
        return 0

    print(f"\n{name}: {arg!r}")
    render(glyphs, height, gap, arg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
