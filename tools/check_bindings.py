#!/usr/bin/env python3
"""Verify the Dart FFI bindings against the compiled render core.

The Dart/C boundary is the seam most likely to break silently: a renamed C
function or a typo in a symbol name compiles cleanly on both sides and only
fails at runtime, on device, as a missing-symbol crash.

This compares the symbol names designer/lib/src/engine/bindings.dart looks up
against those the shared library actually exports, in both directions.

Usage:
    make -C core -f Makefile.host        # build the library first
    python3 tools/check_bindings.py
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINDINGS = ROOT / "designer" / "lib" / "src" / "engine" / "bindings.dart"
LIBRARY = ROOT / "core" / "build" / "host" / "libmirrorcore.so"
HEADER = ROOT / "core" / "ffi" / "mirror_ffi.h"

PREFIX = "ml_sim_"


def dart_symbols() -> set[str]:
    """Symbol names passed to lookupFunction in the bindings."""
    source = BINDINGS.read_text()
    return set(re.findall(r"lookupFunction<[^>]*>\(\s*'([A-Za-z0-9_]+)'", source))


def library_symbols() -> set[str]:
    result = subprocess.run(
        ["nm", "-D", "--defined-only", str(LIBRARY)],
        capture_output=True,
        text=True,
        check=True,
    )
    return {
        line.split()[-1]
        for line in result.stdout.splitlines()
        if line.strip() and line.split()[-1].startswith(PREFIX)
    }


def header_symbols() -> set[str]:
    """Names declared ML_EXPORT in the public header."""
    source = HEADER.read_text()
    return set(re.findall(r"ML_EXPORT[^;]*?\b(" + PREFIX + r"[a-z0-9_]+)\s*\(", source))


def main() -> int:
    if not LIBRARY.exists():
        print(f"error: {LIBRARY.relative_to(ROOT)} not found.", file=sys.stderr)
        print("Build it first: make -C core -f Makefile.host", file=sys.stderr)
        return 2

    dart = dart_symbols()
    lib = library_symbols()
    header = header_symbols()

    print(f"bindings.dart  {len(dart):3d} symbols")
    print(f"library        {len(lib):3d} exported {PREFIX}*")
    print(f"header         {len(header):3d} declared ML_EXPORT")
    print()

    failures = 0

    missing = sorted(dart - lib)
    if missing:
        failures += len(missing)
        print("FAIL: Dart references symbols the library does not export.")
        print("      These crash at runtime, not at build time.")
        for name in missing:
            print(f"      {name}")
        print()

    undeclared = sorted(lib - header)
    if undeclared:
        print("warning: exported but not declared ML_EXPORT in the header:")
        for name in undeclared:
            print(f"      {name}")
        print()

    unbound = sorted(lib - dart)
    if unbound:
        # Not a failure. New C API that Dart has not adopted yet is fine.
        print("note: exported but unused by the designer:")
        for name in unbound:
            print(f"      {name}")
        print()

    if failures:
        print(f"{failures} broken binding(s)")
        return 1

    print("OK: every symbol the designer binds exists in the library")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
