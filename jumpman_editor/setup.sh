#!/usr/bin/env bash
#
# Scaffolds the platform-specific build files for the Jumpman level editor.
#
# Flutter's per-platform boilerplate (the runner CMakeLists, the GTK shell) is
# version specific, so it is generated with the Flutter you have installed rather
# than checked into the repository. Everything that is actually ours (lib/,
# pubspec.yaml) is committed and is never touched by this script.
#
# The editor builds against the shared native package at ../packages/
# mirror_core_ffi, so this also scaffolds that (there is one copy of that step,
# with the package).
#
# Safe to re-run. It only fills in what is missing.
#
# Usage:
#   ./setup.sh          # linux, the only platform this app is built for
#   ./setup.sh linux

set -euo pipefail

cd "$(dirname "$0")"
EDITOR_DIR="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"

PLATFORMS="${1:-linux}"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH.

Install it, then re-run this script:
  https://docs.flutter.dev/get-started/install/linux

On Fedora you will also want the desktop build dependencies:
  sudo dnf install clang cmake ninja-build gtk3-devel pkgconf-pkg-config"

info "Flutter: $(flutter --version 2>/dev/null | head -1)"

[ -f "$REPO_ROOT/gamekit/examples/jumpman/game_jumpman.c" ] \
  || die "cannot find gamekit/examples/jumpman/game_jumpman.c. Run this from inside the repository."

# Generates a throwaway project and lifts only its platform directories, so a
# regenerate can never clobber hand-written Dart or pubspec entries.
scaffold() {
  local target_dir="$1" project_name="$2"
  local tmp created=0

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  flutter create --platforms="$PLATFORMS" --project-name "$project_name" \
    "$tmp/scaffold" >/dev/null

  for platform in linux macos windows; do
    if [ -d "$tmp/scaffold/$platform" ] && [ ! -d "$target_dir/$platform" ]; then
      cp -r "$tmp/scaffold/$platform" "$target_dir/$platform"
      info "  added $(basename "$target_dir")/$platform"
      created=1
    fi
  done

  [ "$created" -eq 0 ] && info "  $(basename "$target_dir") platform files already present"
  return 0
}

info "Scaffolding the shared native package"
"$REPO_ROOT/packages/mirror_core_ffi/setup.sh" "$PLATFORMS"

info "Scaffolding the editor"
scaffold "$EDITOR_DIR" "jumpman_editor"

# The GTK window is the generated runner's, so its size is the one thing about
# the app that cannot be set from Dart. flutter create writes a fixed 1280x720;
# a playtest window needs nearly the whole screen, because the panel it renders
# is 64x32 and the pixels are the point. Patched here rather than committed
# because linux/ is generated (and gitignored) - the same rule the designer's
# setup.sh follows for the Android scaffolding. Idempotent: it looks for its own
# marker and leaves an already-patched file alone.
runner="$EDITOR_DIR/linux/runner/my_application.cc"
if [ -f "$runner" ]; then
  info "  sizing the playtest window in $(basename "$runner")"
  python3 - "$runner" <<'PY'
import sys

path = sys.argv[1]
with open(path) as fh:
    text = fh.read()

MARK = '/* jumpman_editor: a playtest window opens nearly maximized */'
if MARK in text:
    sys.exit(0)

anchor = ("      GTK_WINDOW(gtk_application_window_new("
          "GTK_APPLICATION(application)));\n")
if anchor not in text:
    sys.exit("error: the generated runner does not look like a Flutter one "
             "(no gtk_application_window_new). Re-run flutter create.")

text = text.replace(anchor, anchor + "\n"
    "  " + MARK + "\n"
    "  // The editor launches itself with --playtest for a playtest window, so\n"
    "  // the arguments this application was started with say which one it is.\n"
    "  gboolean playtest = FALSE;\n"
    "  for (gchar** arg = self->dart_entrypoint_arguments; arg && *arg; arg++) {\n"
    "    if (g_strcmp0(*arg, \"--playtest\") == 0) playtest = TRUE;\n"
    "  }\n", 1)

text = text.replace(
    'gtk_header_bar_set_title(header_bar, "jumpman_editor");',
    'gtk_header_bar_set_title(header_bar, playtest ? "Jumpman playtest"\n'
    '                                              : "jumpman_editor");')
text = text.replace(
    'gtk_window_set_title(window, "jumpman_editor");',
    'gtk_window_set_title(window, playtest ? "Jumpman playtest" : "jumpman_editor");')

old_size = "  gtk_window_set_default_size(window, 1280, 720);\n"
if old_size not in text:
    sys.exit("error: the generated runner states no default size.")
text = text.replace(old_size, """  if (playtest) {
    // Nearly the whole work area. A window that is not quite full screen keeps
    // its title bar, so it is still a window the user can move or close, and it
    // leaves the panel edges visible on a tiling compositor.
    GdkDisplay* display = gdk_display_get_default();
    GdkMonitor* monitor =
        display ? gdk_display_get_monitor(display, 0) : nullptr;
    if (monitor) {
      GdkRectangle work;
      gdk_monitor_get_workarea(monitor, &work);
      gtk_window_set_default_size(window, (gint)(work.width * 0.94),
                                  (gint)(work.height * 0.94));
      gtk_window_set_position(window, GTK_WIN_POS_CENTER);
    }
  } else {
    gtk_window_set_default_size(window, 1280, 720);
  }
""", 1)

with open(path, 'w') as fh:
    fh.write(text)
PY
fi

info "Fetching packages"
flutter pub get

cat <<EOF

Done. To run:

  cd jumpman_editor
  ./run.sh                       # the built app, rebuilt if sources changed
  flutter run -d linux           # the development path, for hot reload

If the app opens on "The game simulation did not load", the native library was
not built. Check that ../packages/mirror_core_ffi/<platform>/ exists and re-run
this script.
EOF
