#!/usr/bin/env bash
# Build the OTA firmware image and optionally serve it on the LAN so the
# phone's "Download from URL" flow in the app can fetch it without a cable.
#
# Usage:
#   tools/build_ota.sh               build only, print size and SHA-256
#   tools/build_ota.sh --serve       build and serve on port 8000
#   tools/build_ota.sh --serve 9000  build and serve on port 9000
#
# The version comes from the project() call in firmware/CMakeLists.txt; the
# same version is baked into the image and reported by the mirror after the
# update, which is what makes an OTA verifiable end to end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESP_IDF="${ESP_IDF:-$HOME/esp/esp-idf-v5.5}"

SERVE=0
PORT=8000
while [ $# -gt 0 ]; do
    case "$1" in
        --serve)
            SERVE=1
            shift
            if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
                PORT="$1"
                shift
            fi
            ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $1 (try --help)" >&2
            exit 1
            ;;
    esac
done

VERSION="$(sed -n 's/^project(smart_mirror VERSION \([^)]*\)).*/\1/p' \
    "$ROOT/firmware/CMakeLists.txt")"
if [ -z "$VERSION" ]; then
    echo "could not read the version from firmware/CMakeLists.txt" >&2
    exit 1
fi

if [ ! -f "$ESP_IDF/export.sh" ]; then
    echo "ESP-IDF not found at $ESP_IDF (set ESP_IDF to override)" >&2
    exit 1
fi
. "$ESP_IDF/export.sh" >/dev/null

idf.py -C "$ROOT/firmware" build

SRC="$ROOT/firmware/build/smart_mirror.bin"
OUT_DIR="$ROOT/firmware/build/ota"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/smart_mirror-$VERSION.bin"
cp "$SRC" "$OUT"

SIZE="$(stat -c %s "$OUT")"
SHA="$(sha256sum "$OUT" | cut -d' ' -f1)"
echo "OTA image: $OUT"
echo "version:   $VERSION"
echo "size:      $SIZE bytes"
echo "SHA-256:   $SHA"

if [ "$SERVE" -eq 1 ]; then
    # The primary interface address is what the phone must reach, so bind the
    # server to it (0.0.0.0 would also work but hides typos).
    LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p')"
    if [ -z "$LAN_IP" ]; then
        LAN_IP="$(hostname -I 2>/dev/null | cut -d' ' -f1)"
    fi
    if [ -z "$LAN_IP" ]; then
        echo "could not detect the LAN address; serving on all interfaces" >&2
        LAN_IP="0.0.0.0"
        URL_IP="<your-ip>"
    else
        URL_IP="$LAN_IP"
    fi

    echo
    echo "Serving $OUT_DIR on http://$LAN_IP:$PORT/"
    echo "In the app: Update firmware > Download from URL >"
    echo "  http://$URL_IP:$PORT/smart_mirror-$VERSION.bin"
    echo "(the phone and the mirror must be on the same WiFi as this PC)"
    echo
    exec python3 -m http.server "$PORT" --directory "$OUT_DIR" --bind "$LAN_IP"
fi
