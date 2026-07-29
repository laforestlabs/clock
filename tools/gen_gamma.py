#!/usr/bin/env python3
"""Generate the CIE 1931 lightness table used by the render core.

The panel driver (esp-hub75) applies a CIE 1931 perceptual curve when it builds
its bit-plane data. The simulator has to apply the identical curve or the
desktop preview will not predict what the panel looks like, which is the whole
point of sharing a renderer.

Emitting this as a committed table rather than computing it at runtime keeps
ml_gamma8() a pure lookup, with no math.h dependency and no lazy init.

Usage: python3 tools/gen_gamma.py > core/src/gamma_table.c
"""

import sys


def cie1931(value: int) -> int:
    """Map a linear 0..255 input to a perceptually corrected 0..255 output."""
    lightness = value / 255.0 * 100.0
    if lightness <= 8.0:
        y = lightness / 903.3
    else:
        y = ((lightness + 16.0) / 116.0) ** 3
    return min(255, max(0, round(y * 255.0)))


def main() -> int:
    table = [cie1931(v) for v in range(256)]

    out = sys.stdout
    out.write("/*\n")
    out.write(" * gamma_table.c - GENERATED FILE, DO NOT EDIT.\n")
    out.write(" *\n")
    out.write(" * Regenerate with: python3 tools/gen_gamma.py > core/src/gamma_table.c\n")
    out.write(" *\n")
    out.write(" * CIE 1931 perceptual lightness curve, matching what esp-hub75 applies\n")
    out.write(" * on device. See tools/gen_gamma.py for the formula.\n")
    out.write(" */\n")
    out.write('#include "mirror/color.h"\n\n')
    out.write("const uint8_t ml_gamma_table[256] = {\n")
    for row_start in range(0, 256, 16):
        row = table[row_start:row_start + 16]
        out.write("    " + " ".join(f"{v:3d}," for v in row) + "\n")
    out.write("};\n\n")
    out.write("uint8_t ml_gamma8(uint8_t v) { return ml_gamma_table[v]; }\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
