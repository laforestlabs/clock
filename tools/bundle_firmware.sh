#!/usr/bin/env bash
# Rebuild the firmware from the working tree and stage it as the app's bundled
# OTA image (designer/assets/firmware/smart_mirror.bin).
#
# This is the single sync point behind the guarantee that an APK never ships
# stale firmware: designer/tool/firmware_bundle.gradle (applied into the
# Android build by designer/setup.sh) runs this script before Flutter packs
# assets into the APK, so the bundled image is always the one the firmware
# sources describe. Run it by hand only when you want to stage the image
# without doing an app build; tools/build_ota.sh also calls it.
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
