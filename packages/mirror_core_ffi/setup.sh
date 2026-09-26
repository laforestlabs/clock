#!/usr/bin/env bash
#
# Scaffolds the platform-specific build files for the shared native package.
#
# Flutter's plugin boilerplate (gradle files, podspecs, the runner CMakeLists)
# is version specific, so it is generated with the Flutter you have installed
# rather than checked into the repository. Everything that is actually ours
# (lib/, pubspec.yaml, src/CMakeLists.txt) is committed and is never touched by
# this script.
#
# Both applications that build against this package call this script -
# designer/setup.sh and jumpman_editor/setup.sh - so this is the one copy of
# the step they share.
#
# Safe to re-run. It only fills in what is missing.
#
# Usage:
#   ./setup.sh                      # linux
#   ./setup.sh linux,android,macos  # pick your own

set -euo pipefail

cd "$(dirname "$0")"
PACKAGE_DIR="$(pwd)"
REPO_ROOT="$(cd ../.. && pwd)"

PLATFORMS="${1:-linux}"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH.

Install it, then re-run this script:
  https://docs.flutter.dev/get-started/install/linux

On Fedora you will also want the desktop build dependencies:
  sudo dnf install clang cmake ninja-build gtk3-devel pkgconf-pkg-config"

[ -f "$REPO_ROOT/core/ffi/mirror_ffi.c" ] \
  || die "cannot find core/ffi/mirror_ffi.c. Run this from inside the repository."

# The package compiles the shared render core in place rather than vendoring a
# copy, so the generated glyph tables have to exist before anything builds.
if [ ! -f "$REPO_ROOT/core/src/fonts/font_registry.c" ]; then
  info "Generating font tables"
  (cd "$REPO_ROOT" && python3 tools/fontgen.py)
fi

# ------------------------------------------------------- platform scaffolding

info "Scaffolding the native plugin (compiles core/ and gamekit/)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

flutter create --platforms="$PLATFORMS" --template=plugin_ffi \
  --project-name mirror_core_ffi "$tmp/scaffold" >/dev/null

created=0
for platform in android ios linux macos windows; do
  if [ -d "$tmp/scaffold/$platform" ] && [ ! -d "$PACKAGE_DIR/$platform" ]; then
    cp -r "$tmp/scaffold/$platform" "$PACKAGE_DIR/$platform"
    info "  added $platform"
    created=1
  fi
done

[ "$created" -eq 0 ] && info "  platform files already present"

# The generated plugin ships a placeholder .c and matching Dart bindings that
# reference functions our core does not have. Left in place they break the
# build, so remove them; src/CMakeLists.txt is ours and points at core/.
rm -f "$PACKAGE_DIR/src/mirror_core_ffi.c" \
      "$PACKAGE_DIR/src/mirror_core_ffi.h" \
      "$PACKAGE_DIR/lib/mirror_core_ffi_bindings_generated.dart" \
      "$PACKAGE_DIR/ffigen.yaml"

# ------------------------------------------------------------------ packages

info "Fetching packages"
flutter pub get

cat <<EOF

Done. The package is built by whichever app depends on it:

  cd designer && ./setup.sh && flutter run -d linux
EOF
