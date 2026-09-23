#!/usr/bin/env python3
"""Keep one firmware version per image.

firmware/CMakeLists.txt states the rule: bump the version on every firmware
change. The version is what /api/status, the BLE pong and the OTA filename
report, so two different images under one version cannot be told apart once
either is on the board - which is exactly the case the rule exists to prevent.

A rule in a comment is easy to forget, so this enforces it. The image is
compiled from firmware/, core/, gamekit/, fonts/ and layouts/ (the games and
the render core are built in, not linked from a package), so the hash of those
sources is recorded against the version it was stamped for. When they no longer
match, the version was not bumped for the change.

Usage:
    tools/firmware_version.py check            # is the tree consistent?
    tools/firmware_version.py check --staged   # ...and is the bundled image it?
    tools/firmware_version.py stamp            # record the sources as this version

Both firmware build paths run it: firmware/CMakeLists.txt at configure time
(so no idf.py build starts on a stale stamp) and tools/bundle_firmware.sh,
which every Android build and `tools/bundle_firmware.sh` stage through. After
changing anything the image is built from:

    1. bump  firmware/CMakeLists.txt: project(smart_mirror VERSION x.y.z)
    2. tools/firmware_version.py stamp
    3. build  - the app's firmware bundle and the OTA image both restage

The sources are enumerated with git, so .gitignore is the one place that says
what is not a source (build output, the component manager's managed_components
and dependencies.lock, the local sdkconfig) and a new file counts from the
moment it exists rather than the moment it is staged. Outside a git checkout
there is nothing to enumerate against, so the check reports that it could not
run instead of pretending it passed.
"""

from __future__ import annotations

import hashlib
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CMAKE = ROOT / "firmware" / "CMakeLists.txt"
LOCK = ROOT / "firmware" / "version.lock"
STAGED = ROOT / "designer" / "assets" / "firmware" / "smart_mirror.bin"

# Everything the firmware image is compiled from. core/ and gamekit/ are in it
# because firmware/components/ holds symlinks to those two directories: the
# image contains their sources, so changing them changes the image.
INPUTS = ("firmware", "core", "gamekit", "fonts", "layouts")

# The record cannot hash itself.
UNHASHED = {LOCK}

# Documentation is not built into the image. A README edit is not a firmware
# change, and demanding a version bump for one would turn the version into a
# diary of the working tree instead of the identity of a build. Excluding a
# suffix rather than listing the ones that count keeps the rule fail-closed:
# a file kind nobody thought about is still hashed.
UNHASHED_SUFFIXES = (".md",)

# esp_app_desc_t starts 32 bytes into a firmware image (the 24-byte image header
# plus the 8-byte segment header), opens with a magic word, and its version[32]
# begins 16 bytes in.
DESC_MAGIC = 0xABCD5432
DESC_MAGIC_OFFSET = 32
DESC_VERSION_OFFSET = DESC_MAGIC_OFFSET + 16
DESC_VERSION_LEN = 32


def declared_version() -> str:
    """The version firmware/CMakeLists.txt declares."""
    match = re.search(r"^project\(smart_mirror VERSION ([^)\s]+)\)",
                      CMAKE.read_text(), re.M)
    if not match:
        raise SystemExit("could not read the version from firmware/CMakeLists.txt")
    return match.group(1)


def next_version(version: str) -> str:
    """The version after [version], for the message that asks for a bump."""
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    if not match:
        return version
    return f"{match.group(1)}.{match.group(2)}.{int(match.group(3)) + 1}"


def input_files() -> list[Path]:
    """Every source the image is built from, in a stable order."""
    result = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard",
         "--", *INPUTS],
        cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(
            "firmware version check could not run: this is not a git checkout, "
            f"so what the image is built from cannot be enumerated "
            f"({result.stderr.strip()})")
    return [ROOT / name for name in sorted(n for n in result.stdout.split("\0") if n)]


def inputs_hash() -> str:
    """sha256 over the path and the content of every build input."""
    digest = hashlib.sha256()
    for path in input_files():
        if path in UNHASHED or path.suffix in UNHASHED_SUFFIXES:
            continue
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(b"\0")
        if path.is_symlink():
            # The component symlinks only say which source tree the image was
            # built from; the sources they point at are hashed as core/ and
            # gamekit/ in their own right.
            digest.update(b"symlink\0")
            digest.update(os.readlink(path).encode())
        elif path.exists():
            digest.update(b"file\0")
            digest.update(path.read_bytes())
        else:
            # Tracked but deleted in the working tree: an absent source is part
            # of what the tree says the image is built from.
            digest.update(b"absent\0")
        digest.update(b"\0")
    return digest.hexdigest()


def read_lock() -> dict[str, str]:
    """The recorded version and inputs hash, empty when nothing is stamped."""
    if not LOCK.exists():
        return {}
    fields: dict[str, str] = {}
    for line in LOCK.read_text().splitlines():
        if line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def staged_version() -> str | None:
    """The version baked into the image the app bundles, or None without one."""
    if not STAGED.exists():
        return None
    blob = STAGED.read_bytes()
    if len(blob) < DESC_VERSION_OFFSET + DESC_VERSION_LEN:
        return None
    magic, = struct.unpack_from("<I", blob, DESC_MAGIC_OFFSET)
    if magic != DESC_MAGIC:
        return None
    raw = blob[DESC_VERSION_OFFSET:DESC_VERSION_OFFSET + DESC_VERSION_LEN]
    return raw.split(b"\0", 1)[0].decode("ascii", "replace")


def fail(reason: str, version: str) -> int:
    """Report a version the tree and the images disagree about."""
    print(f"firmware version check failed: {reason}.", file=sys.stderr)
    print(
        "\nThe version is what the board reports and what an OTA is named for,\n"
        "so one version cannot describe two images. Bump it for this change,\n"
        "then record the sources it was stamped against:\n"
        "\n"
        f"    firmware/CMakeLists.txt:  project(smart_mirror VERSION {next_version(version)})\n"
        "    tools/firmware_version.py stamp\n",
        file=sys.stderr)
    return 1


def check(staged: bool) -> int:
    version = declared_version()
    recorded = read_lock()
    if not recorded:
        return fail("firmware/version.lock is missing, so nothing is stamped", version)
    digest = inputs_hash()
    if recorded.get("inputs") != digest:
        return fail("the sources the image is built from changed after "
                    f"{recorded.get('version', 'it')} was stamped", version)
    if recorded.get("version") != version:
        return fail(f"the sources were stamped for {recorded['version']}, and "
                    f"firmware/CMakeLists.txt now declares {version}", version)
    if staged:
        baked = staged_version()
        if baked is None:
            return fail("the app has no bundled firmware image to check", version)
        if baked != version:
            return fail(f"the app bundles {baked} while the tree declares {version}", version)
    print(f"firmware {version}: lock ok"
          + (", bundled image matches" if staged else ""))
    return 0


def stamp() -> int:
    version = declared_version()
    digest = inputs_hash()
    LOCK.write_text(
        "# Firmware version lock - written by tools/firmware_version.py stamp.\n"
        "#\n"
        "# The hash covers every source the image is compiled from: firmware/,\n"
        "# core/, gamekit/, fonts/ and layouts/, less documentation, which is\n"
        "# not built into it. A mismatch means those sources changed after this\n"
        "# version was stamped, so the version was not bumped for them - see\n"
        "# firmware/README.md, Versioning.\n"
        "#\n"
        "# Editing this file by hand does not change the firmware; it only\n"
        "# tells the check what the image is expected to be built from.\n"
        f"version = {version}\n"
        f"inputs = {digest}\n")
    print(f"stamped {version} over the sources now in the tree ({digest[:12]})")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if any(a in ("-h", "--help") for a in args):
        print(__doc__.strip())
        return 0
    staged = "--staged" in args
    command = next((a for a in args if not a.startswith("-")), "check")
    if command == "check":
        return check(staged)
    if command == "stamp":
        return stamp()
    print(f"unknown command: {command} (try --help)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
