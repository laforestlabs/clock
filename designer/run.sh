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

# Freshness is tracked by hashing the contents of the sources, not by comparing
# timestamps. Two things defeat mtimes here. The runner executable is only
# relinked when the C++ shell changes, so a pure Dart or asset edit leaves it
# looking current. And git rewrites mtimes wholesale on checkout, rebase and
# pull, so any branch switch made an unchanged tree look stale and forced a
# rebuild that produced a byte identical bundle.
STAMP="$DESIGNER/build/linux/.mirror-run-stamp"
BUILD_LOG="/tmp/mirror-designer-build.log"

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
# excluded, since the build itself writes into those and they would never
# settle. Paths are listed relative to the repository root so that the digest
# survives moving or renaming the checkout.
SOURCE_ROOTS=(
  designer/lib
  designer/pubspec.yaml
  designer/packages/mirror_core_ffi/lib
  designer/packages/mirror_core_ffi/src
  core/src
  core/include
  core/ffi
  # The games compile into the same shared library as the render core, so a
  # physics change in gamekit must invalidate the bundle just the same.
  gamekit/src
  gamekit/include
  gamekit/ffi
  gamekit/examples
  # Stock layouts are bundled as Flutter assets, so editing one needs a
  # rebuild before the app sees it.
  layouts
)

# One digest over the whole source set, roughly 47 files and half a megabyte,
# which costs a couple of milliseconds per launch. Names go into the hash along
# with contents, so adding or deleting a file counts as a change even when no
# surviving file was edited.
source_hash() {
  local existing=() r
  for r in "${SOURCE_ROOTS[@]}"; do [ -e "$REPO/$r" ] && existing+=("$r"); done
  [ ${#existing[@]} -eq 0 ] && return 1

  local digest
  digest="$(cd "$REPO" && find "${existing[@]}" -type f \
              \( -name '*.dart' -o -name '*.c' -o -name '*.h' \
                 -o -name '*.yaml' -o -name '*.json' -o -name 'CMakeLists.txt' \) \
              -print0 2>/dev/null \
            | LC_ALL=C sort -z \
            | xargs -0 -r sha256sum 2>/dev/null \
            | sha256sum | cut -d' ' -f1)"

  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
}

# A stamp left by an older version of this script carries no digest, only an
# mtime. Anything that is not a bare hash reads as unknown, which costs one
# rebuild and writes the current format.
stored_hash() {
  [ -f "$STAMP" ] || return 1
  local h
  h="$(head -1 "$STAMP" 2>/dev/null || true)"
  [ ${#h} -eq 64 ] || return 1
  printf '%s\n' "$h"
}

# Both are read through || true so that a failure inside them cannot trip the
# errexit at the top of this file; an empty result is the signal instead.
CURRENT_HASH="$(source_hash || true)"
STORED_HASH="$(stored_hash || true)"

need_build=0
if [ ! -x "$BIN" ]; then
  need_build=1
elif [ -n "${MIRROR_FORCE_BUILD:-}" ]; then
  need_build=1
elif [ -z "$CURRENT_HASH" ]; then
  # The sources could not be read at all, so the checkout is in a state this
  # script cannot reason about. Attempting a build beats launching a bundle of
  # unknown vintage.
  need_build=1
elif [ "$CURRENT_HASH" != "$STORED_HASH" ]; then
  # Covers a missing stamp and a legacy one too, since both read as empty.
  need_build=1
fi

[ -n "${MIRROR_NO_BUILD:-}" ] && need_build=0

# -------------------------------------------------------------------- build

# Started from the launcher there is no terminal, so a build that only writes to
# a log file looks exactly like a launcher that did nothing at all. Put a window
# on screen in that case, and stay plain text when there is a terminal to read.
build_with_feedback() {
  if [ -t 1 ] || ! command -v zenity >/dev/null 2>&1; then
    printf 'Building the designer, sources changed. Log: %s\n' "$BUILD_LOG" >&2
    "$FLUTTER" build linux --release >"$BUILD_LOG" 2>&1
    return
  fi

  "$FLUTTER" build linux --release >"$BUILD_LOG" 2>&1 &
  local pid=$!
  # zenity pulses for as long as its stdin stays open and closes on end of
  # file, so the feeder subshell just has to outlive the build. Cancel is off
  # because nothing here can actually call the compiler back.
  ( while kill -0 "$pid" 2>/dev/null; do sleep 1; done ) \
    | zenity --progress --pulsate --auto-close --no-cancel \
        --title="Mirror Designer" --width=380 \
        --text="Building the designer, sources changed..." 2>/dev/null || true
  wait "$pid"
}

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
    # CURRENT_HASH was taken before the build started, deliberately. Recording
    # it afterwards would swallow any edit made while the compiler was running:
    # that edit would be hashed as though it had been built. Storing the older
    # digest just means one more rebuild, which is the safe direction to err.
    if build_with_feedback; then
      if [ -n "$CURRENT_HASH" ]; then
        printf '%s\n' "$CURRENT_HASH" >"$STAMP"
      fi
    else
      if [ -x "$BIN" ]; then
        notify "Build failed, launching the previous build" "See $BUILD_LOG"
      else
        fail "The build failed and there is no previous build to fall back on.

See $BUILD_LOG

$(tail -15 "$BUILD_LOG" 2>/dev/null)"
      fi
    fi
  fi
fi

[ -x "$BIN" ] || fail "The designer is not built and could not be built.

Try:
  cd $DESIGNER && ./setup.sh && flutter build linux --release"

# ------------------------------------------------------------------- launch

exec "$BIN" "$@"
