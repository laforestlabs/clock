#!/usr/bin/env bash
#
# Launches the designer, rebuilding first only if sources have changed.
#
# This is what the desktop shortcut runs. The release bundle is self contained
# (RUNPATH is $ORIGIN/lib), so it starts from any working directory and does not
# need Flutter on PATH. Flutter is only needed when a rebuild is required.
#
# Usage:
#   ./run.sh                       launch, rebuilding if sources changed
#   MIRROR_NO_BUILD=1 ./run.sh     launch whatever is built, never rebuild
#   MIRROR_FORCE_BUILD=1 ./run.sh  rebuild even if nothing changed
#
# Any extra arguments are passed through to the app.

set -euo pipefail

cd "$(dirname "$0")"
DESIGNER="$(pwd)"
REPO="$(cd .. && pwd)"
BUNDLE="$DESIGNER/build/linux/x64/release/bundle"
BIN="$BUNDLE/mirror_designer"

# Freshness is tracked with an explicit stamp rather than the binary's mtime.
# The runner executable is only relinked when the C++ shell changes, so after a
# pure Dart or asset edit it keeps its old timestamp and every launch would look
# stale and rebuild.
STAMP="$DESIGNER/build/linux/.mirror-run-stamp"

# Desktop launchers get a bare environment, so look in the usual install spots
# rather than assuming PATH is set up the way an interactive shell has it.
find_flutter() {
  if command -v flutter >/dev/null 2>&1; then command -v flutter; return 0; fi
  local c
  for c in "$HOME/flutter/bin/flutter" "$HOME/development/flutter/bin/flutter" \
           "/opt/flutter/bin/flutter" "/usr/local/flutter/bin/flutter"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

notify() {
  command -v notify-send >/dev/null 2>&1 \
    && notify-send -a "Mirror Designer" -i mirror-designer "$@" || true
}

fail() {
  printf 'error: %s\n' "$1" >&2
  command -v zenity >/dev/null 2>&1 \
    && zenity --error --title="Mirror Designer" --width=420 --text="$1" 2>/dev/null || true
  exit 1
}

# ------------------------------------------------------------ staleness check

# Only real sources count. Generated platform directories and build output are
# excluded, since the build itself touches those and would look perpetually
# stale.
# A build run by hand, without this script, leaves no stamp. Seed one from the
# newest file already in the bundle so that build still counts as current.
ensure_stamp() {
  [ -f "$STAMP" ] && return 0
  [ -d "$BUNDLE" ] || return 1
  local newest
  newest="$(find "$BUNDLE" -type f -printf '%T@ %p\n' 2>/dev/null \
              | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$newest" ] && touch -r "$newest" "$STAMP" 2>/dev/null
}

sources_newer_than_stamp() {
  local roots=(
    "$DESIGNER/lib"
    "$DESIGNER/pubspec.yaml"
    "$DESIGNER/packages/mirror_core_ffi/lib"
    "$DESIGNER/packages/mirror_core_ffi/src"
    "$REPO/core/src"
    "$REPO/core/include"
    "$REPO/core/ffi"
    # Stock layouts are bundled as Flutter assets, so editing one needs a
    # rebuild before the app sees it.
    "$REPO/layouts"
  )
  local existing=()
  local r
  for r in "${roots[@]}"; do [ -e "$r" ] && existing+=("$r"); done
  [ ${#existing[@]} -eq 0 ] && return 1

  local hit
  hit="$(find "${existing[@]}" -type f \
           \( -name '*.dart' -o -name '*.c' -o -name '*.h' \
              -o -name '*.yaml' -o -name '*.json' -o -name 'CMakeLists.txt' \) \
           -newer "$STAMP" -print -quit 2>/dev/null)"
  [ -n "$hit" ]
}

need_build=0
if [ ! -x "$BIN" ]; then
  need_build=1
elif [ -n "${MIRROR_FORCE_BUILD:-}" ]; then
  need_build=1
elif ! ensure_stamp; then
  need_build=1
elif sources_newer_than_stamp; then
  need_build=1
fi

[ -n "${MIRROR_NO_BUILD:-}" ] && need_build=0

# -------------------------------------------------------------------- build

if [ "$need_build" -eq 1 ]; then
  FLUTTER="$(find_flutter || true)"

  if [ -z "$FLUTTER" ]; then
    # No toolchain. An existing binary is better than nothing, even if stale.
    [ -x "$BIN" ] || fail "Flutter is not installed and the designer has never been built.

Install Flutter, then run designer/setup.sh once:
  https://docs.flutter.dev/get-started/install/linux"
    notify "Launching without rebuilding" "Flutter was not found, so this may be an older build."
  else
    notify "Building the designer" "Sources changed since the last build."
    if "$FLUTTER" build linux --release >/tmp/mirror-designer-build.log 2>&1; then
      touch "$STAMP"
    else
      if [ -x "$BIN" ]; then
        notify "Build failed, launching the previous build" "See /tmp/mirror-designer-build.log"
      else
        fail "The build failed and there is no previous build to fall back on.

See /tmp/mirror-designer-build.log

$(tail -15 /tmp/mirror-designer-build.log 2>/dev/null)"
      fi
    fi
  fi
fi

[ -x "$BIN" ] || fail "The designer is not built and could not be built.

Try:
  cd $DESIGNER && ./setup.sh && flutter build linux --release"

# ------------------------------------------------------------------- launch

exec "$BIN" "$@"
