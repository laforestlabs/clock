#!/usr/bin/env bash
# Rebuild the firmware from the working tree and stage it as the app's bundled
# OTA image (designer/assets/firmware/smart_mirror.bin).
#
# This is the single sync point behind the guarantee that an APK never ships
# stale firmware: designer/tool/firmware_bundle.gradle (applied into the
# Android build by designer/setup.sh) runs this script before Flutter packs
# assets into the APK, so the bundled image is always the one the firmware
# sources describe. Run it by hand only when you want to stage the image
# without doing an app build.
#
# Cheap when nothing changed: the gradle task only invokes this after hashing
# everything the image consumes (firmware/, core/, gamekit/, fonts/, the
# embedded layout), the idf.py build is incremental, and the staged copy is
# rewritten only when its bytes actually differ.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESP_IDF="${ESP_IDF:-$HOME/esp/esp-idf-v5.5}"

IMAGE="$ROOT/firmware/build/smart_mirror.bin"
STAGED="$ROOT/designer/assets/firmware/smart_mirror.bin"

# One version per image, before anything is built: the version is what the
# board reports and what an OTA is named for, so an image built from these
# sources under a version another image already claimed cannot be told apart
# from it. This is the Android build's and the OTA build's own gate; the
# firmware's CMakeLists has the same one.
python3 "$ROOT/tools/firmware_version.py" check

# The generated font tables in core/src/fonts are compiled into the image, so
# a fonts/*.font edit must be regenerated before the build sees it.
if ! python3 "$ROOT/tools/fontgen.py" --check >/dev/null 2>&1; then
    echo "bundle_firmware: font tables out of date; regenerating"
    python3 "$ROOT/tools/fontgen.py" >/dev/null
fi

if [ ! -f "$ESP_IDF/export.sh" ]; then
    echo "bundle_firmware: ESP-IDF not found at $ESP_IDF (set ESP_IDF to override)." >&2
    echo "An Android build must bundle current firmware; refusing to silently" >&2
    echo "ship the previously staged image. Install ESP-IDF, or opt out for a" >&2
    echo "one-off build with: flutter build apk -PskipFirmwareBundle" >&2
    exit 1
fi
. "$ESP_IDF/export.sh" >/dev/null

idf.py -C "$ROOT/firmware" build

if [ ! -f "$IMAGE" ]; then
    echo "bundle_firmware: the build produced no $IMAGE" >&2
    exit 1
fi

mkdir -p "$(dirname "$STAGED")"
if [ -f "$STAGED" ] && cmp -s "$IMAGE" "$STAGED"; then
    echo "bundle_firmware: staged image already current ($(stat -c %s "$STAGED") bytes)"
else
    cp "$IMAGE" "$STAGED"
    echo "bundle_firmware: staged $(basename "$IMAGE") -> ${STAGED#"$ROOT"/}"
fi

# What the app will ship is the version the tree declares - the other half of
# the guarantee this script exists for, and the half a stale or wrongly named
# staged copy would break without anything else noticing.
python3 "$ROOT/tools/firmware_version.py" check --staged
