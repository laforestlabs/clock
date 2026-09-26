#!/usr/bin/env bash
#
# Launches the Jumpman level editor, rebuilding first only if sources changed.
#
# The release bundle is self contained (RUNPATH is $ORIGIN/lib), so it starts
# from any working directory and does not need Flutter on PATH. Flutter is only
# needed when a rebuild is required.
#
# Usage:
#   ./run.sh                       launch, rebuilding if sources changed
#   MIRROR_NO_BUILD=1 ./run.sh     launch whatever is built, never rebuild
#   MIRROR_FORCE_BUILD=1 ./run.sh  rebuild even if nothing changed
#
# Any extra arguments are passed through to the app.

set -euo pipefail

cd "$(dirname "$0")"
EDITOR="$(pwd)"
REPO="$(cd .. && pwd)"
BUNDLE="$EDITOR/build/linux/x64/release/bundle"
BIN="$BUNDLE/jumpman_editor"

# Freshness is tracked by hashing the contents of the sources, not by comparing
# timestamps: the runner executable is only relinked when the C++ shell changes,
# and git rewrites mtimes wholesale on checkout, rebase and pull.
STAMP="$EDITOR/build/linux/.jumpman-run-stamp"
BUILD_LOG="/tmp/jumpman-editor-build.log"

# Launchers get a bare environment, so look in the usual install spots rather
# than assuming PATH is set up the way an interactive shell has it.
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
    && notify-send -a "Jumpman Level Editor" "$@" || true
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# ------------------------------------------------------------ staleness check

# Only real sources count. Generated platform directories and build output are
# excluded, since the build itself writes into those and they would never
# settle. Paths are listed relative to the repository root so that the digest
# survives moving or renaming the checkout.
SOURCE_ROOTS=(
  jumpman_editor/lib
  jumpman_editor/pubspec.yaml
  packages/mirror_core_ffi/lib
  packages/mirror_core_ffi/src
  core/src
  core/include
  core/ffi
  # The games compile into the same shared library as the render core, so a
  # physics change in gamekit has to invalidate the bundle just the same: the
  # editor plays the real game.
  gamekit/src
  gamekit/include
  gamekit/ffi
  gamekit/examples
)

# One digest over the whole source set. Names go into the hash along with
# contents, so adding or deleting a file counts as a change even when no
# surviving file was edited.
source_hash() {
  local existing=() r
  for r in "${SOURCE_ROOTS[@]}"; do [ -e "$REPO/$r" ] && existing+=("$r"); done
  [ ${#existing[@]} -eq 0 ] && return 1

  local digest
  digest="$(cd "$REPO" && find "${existing[@]}" -type f \
              \( -name '*.dart' -o -name '*.c' -o -name '*.h' \
                 -o -name '*.yaml' -o -name 'CMakeLists.txt' \) \
              -print0 2>/dev/null \
            | LC_ALL=C sort -z \
            | xargs -0 -r sha256sum 2>/dev/null \
            | sha256sum | cut -d' ' -f1)"

  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
}

stored_hash() {
  [ -f "$STAMP" ] || return 1
  local h
  h="$(head -1 "$STAMP" 2>/dev/null || true)"
  [ ${#h} -eq 64 ] || return 1
  printf '%s\n' "$h"
}

CURRENT_HASH="$(source_hash || true)"
STORED_HASH="$(stored_hash || true)"

need_build=0
if [ ! -x "$BIN" ]; then
  need_build=1
elif [ -n "${MIRROR_FORCE_BUILD:-}" ]; then
  need_build=1
elif [ -z "$CURRENT_HASH" ]; then
  need_build=1
elif [ "$CURRENT_HASH" != "$STORED_HASH" ]; then
  need_build=1
fi

[ -n "${MIRROR_NO_BUILD:-}" ] && need_build=0

# -------------------------------------------------------------------- build

if [ "$need_build" -eq 1 ]; then
  FLUTTER="$(find_flutter || true)"

  if [ -z "$FLUTTER" ]; then
    # No toolchain. An existing binary is better than nothing, even if stale.
    [ -x "$BIN" ] || fail "Flutter is not installed and the editor has never been built.

Install Flutter, then run jumpman_editor/setup.sh once:
  https://docs.flutter.dev/get-started/install/linux"
    notify "Launching without rebuilding" "Flutter was not found, so this may be an older build."
  else
    notify "Building the level editor" "Sources changed since the last build."
    printf 'Building the level editor, sources changed. Log: %s\n' "$BUILD_LOG" >&2
    # CURRENT_HASH was taken before the build started, deliberately: recording
    # it afterwards would swallow an edit made while the compiler was running.
    if "$FLUTTER" build linux --release >"$BUILD_LOG" 2>&1; then
      [ -n "$CURRENT_HASH" ] && printf '%s\n' "$CURRENT_HASH" >"$STAMP"
    else
      if [ -x "$BIN" ]; then
        notify "Build failed, launching the previous build" "See $BUILD_LOG"
      else
        fail "The build failed and there is no previous build to fall back on.

See $BUILD_LOG"
      fi
    fi
  fi
fi

[ -x "$BIN" ] || fail "The level editor is not built and could not be built.

Try:
  cd $EDITOR && ./setup.sh && flutter build linux --release"

# ------------------------------------------------------------------- launch

exec "$BIN" "$@"
