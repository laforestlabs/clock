#!/usr/bin/env bash
#
# Scaffolds the platform-specific build files for the designer.
#
# Flutter's per-platform boilerplate (gradle files, podspecs, runner CMake) is
# version specific, so it is generated with the Flutter you have installed
# rather than checked into the repository. Everything that is actually ours
# (lib/, pubspec.yaml, the plugin's src/CMakeLists.txt) is committed and is
# never touched by this script.
#
# Safe to re-run. It only fills in what is missing.
#
# Usage:
#   ./setup.sh                      # linux and android
#   ./setup.sh linux,android,macos  # pick your own

set -euo pipefail

cd "$(dirname "$0")"
DESIGNER_DIR="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"

PLATFORMS="${1:-linux,android}"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- toolchain

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH.

Install it, then re-run this script:
  https://docs.flutter.dev/get-started/install/linux

On Fedora you will also want the desktop build dependencies:
  sudo dnf install clang cmake ninja-build gtk3-devel pkgconf-pkg-config"

info "Flutter: $(flutter --version 2>/dev/null | head -1)"

# The render core is compiled in place rather than vendored, so the repository
# layout has to be intact.
[ -f "$REPO_ROOT/core/ffi/mirror_ffi.c" ] \
  || die "cannot find core/ffi/mirror_ffi.c. Run this from inside the repository."

if [ ! -f "$REPO_ROOT/core/src/fonts/font_registry.c" ]; then
  info "Generating font tables"
  (cd "$REPO_ROOT" && python3 tools/fontgen.py)
fi

# ------------------------------------------------------- platform scaffolding

# Generates a throwaway project and lifts only its platform directories, so a
# regenerate can never clobber hand-written Dart or pubspec entries.
scaffold() {
  local target_dir="$1" template="$2" project_name="$3"
  local tmp created=0

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  local args=(create --platforms="$PLATFORMS" --project-name "$project_name")
  [ -n "$template" ] && args+=(--template="$template")

  flutter "${args[@]}" "$tmp/scaffold" >/dev/null

  for platform in android ios linux macos windows; do
    if [ -d "$tmp/scaffold/$platform" ] && [ ! -d "$target_dir/$platform" ]; then
      cp -r "$tmp/scaffold/$platform" "$target_dir/$platform"
      info "  added $(basename "$target_dir")/$platform"
      created=1
    fi
  done

  [ "$created" -eq 0 ] && info "  $(basename "$target_dir") platform files already present"
  return 0
}

info "Scaffolding the native plugin (compiles core/)"
scaffold "$DESIGNER_DIR/packages/mirror_core_ffi" "plugin_ffi" "mirror_core_ffi"

info "Scaffolding the app"
scaffold "$DESIGNER_DIR" "" "mirror_designer"

# "Save As" uses ACTION_CREATE_DOCUMENT because file_selector has no save
# support on Android. MainActivity.kt is ours; install it over the stub that
# `flutter create` generated (and regenerates) so the fix survives a fresh
# checkout. Guarded so `./setup.sh linux` without android is still safe.
if [ -d "$DESIGNER_DIR/android" ]; then
  cp "$DESIGNER_DIR/tool/MainActivity.kt" \
     "$DESIGNER_DIR/android/app/src/main/kotlin/com/example/mirror_designer/MainActivity.kt"
fi

# The generated plugin ships a placeholder .c and matching Dart bindings that
# reference functions our core does not have. Left in place they break the
# build, so remove them; src/CMakeLists.txt is ours and points at core/.
rm -f "$DESIGNER_DIR/packages/mirror_core_ffi/src/mirror_core_ffi.c" \
      "$DESIGNER_DIR/packages/mirror_core_ffi/src/mirror_core_ffi.h" \
      "$DESIGNER_DIR/packages/mirror_core_ffi/lib/mirror_core_ffi_bindings_generated.dart" \
      "$DESIGNER_DIR/packages/mirror_core_ffi/ffigen.yaml"

# -------------------------------------------------------------------- icons

# Android launcher icons are rendered from the committed icon layout rather
# than shipped as blobs, so generate them once the Android scaffolding exists.
if [ -d "$DESIGNER_DIR/android/app/src/main/res" ]; then
  info "Generating launcher icons"
  if ! python3 "$DESIGNER_DIR/tool/gen_icon.py"; then
    warn "icon generation failed; the stock launcher icon is left in place"
  fi
fi

# ------------------------------------------------------------------- assets

# Stock layouts are shared with the firmware and the CLI. Linked rather than
# copied so there is exactly one copy of each layout in the repository.
mkdir -p "$DESIGNER_DIR/assets"
if [ ! -e "$DESIGNER_DIR/assets/layouts" ]; then
  ln -s ../../layouts "$DESIGNER_DIR/assets/layouts"
  info "Linked assets/layouts -> layouts/"
fi

info "Fetching packages"
flutter pub get

cat <<EOF

Done. To run:

  cd designer
  flutter run -d linux          # desktop
  flutter run -d <device-id>    # phone, see: flutter devices

If the app opens on "The render engine did not load", the native library was
not built. Check that packages/mirror_core_ffi/<platform>/ exists and re-run
this script.
EOF
