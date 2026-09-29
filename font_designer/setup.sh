#!/usr/bin/env bash
#
# Scaffolds the Linux build files for Font Designer.
#
# Flutter's per-platform boilerplate (the runner CMakeLists, the GTK shell) is
# version specific, so it is generated with the Flutter you have installed
# rather than checked into the repository. Everything that is actually ours
# (lib/, test/, pubspec.yaml) is committed and is never touched by this script.
#
# Safe to re-run. It only fills in what is missing.
#
# Usage:
#   ./setup.sh          # linux, the only platform this app is built for
#   ./setup.sh linux

set -euo pipefail

cd "$(dirname "$0")"
TOOL_DIR="$(pwd)"
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

[ -f "$REPO_ROOT/tools/fontgen.py" ] \
  || die "cannot find tools/fontgen.py. Run this from inside the repository."

# Generates a throwaway project and lifts only its platform directories, so a
# regenerate can never clobber hand-written Dart or pubspec entries.
tmp="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$tmp'" EXIT

flutter create --platforms="$PLATFORMS" --project-name font_designer \
  "$tmp/scaffold" >/dev/null

for platform in linux macos windows; do
  if [ -d "$tmp/scaffold/$platform" ] && [ ! -d "$TOOL_DIR/$platform" ]; then
    cp -r "$tmp/scaffold/$platform" "$TOOL_DIR/$platform"
    info "  added font_designer/$platform"
  fi
done

# The GTK window is the generated runner's, so its size and title are the two
# things about the app that cannot be set from Dart. flutter create writes a
# fixed 1280x720; this tool is three columns of controls around a 64x32 panel,
# so it wants a large window but not the whole screen. Patched here rather
# than committed because linux/ is generated (and gitignored), the same rule
# the designer's and the Jumpman editor's setup.sh follow. Idempotent: it
# looks for its own marker and leaves an already-patched file alone.
runner="$TOOL_DIR/linux/runner/my_application.cc"
if [ -f "$runner" ]; then
  info "  sizing and titling the window in $(basename "$runner")"
  python3 - "$runner" <<'PY'
import sys

path = sys.argv[1]
with open(path) as fh:
    text = fh.read()

MARK = '/* font_designer: three columns and a panel need the room */'
if MARK in text:
    sys.exit(0)

anchor = ("      GTK_WINDOW(gtk_application_window_new("
          "GTK_APPLICATION(application)));\n")
if anchor not in text:
    sys.exit("error: the generated runner does not look like a Flutter one "
             "(no gtk_application_window_new). Re-run flutter create.")
text = text.replace(anchor, anchor + "\n  " + MARK + "\n", 1)

old_size = "  gtk_window_set_default_size(window, 1280, 720);\n"
if old_size not in text:
    sys.exit("error: the generated runner states no default size.")
text = text.replace(old_size, """  GdkDisplay* display = gdk_display_get_default();
  GdkMonitor* monitor = display ? gdk_display_get_monitor(display, 0) : nullptr;
  if (monitor) {
    GdkRectangle work;
    gdk_monitor_get_workarea(monitor, &work);
    gint width = (gint)(work.width * 0.9);
    gint height = (gint)(work.height * 0.9);
    if (width < 1024) width = work.width;
    if (height < 720) height = work.height;
    gtk_window_set_default_size(window, width, height);
    gtk_window_set_position(window, GTK_WIN_POS_CENTER);
  } else {
    gtk_window_set_default_size(window, 1500, 950);
  }
""", 1)

text = text.replace('gtk_header_bar_set_title(header_bar, "font_designer");',
                    'gtk_header_bar_set_title(header_bar, "Font Designer");')
text = text.replace('gtk_window_set_title(window, "font_designer");',
                    'gtk_window_set_title(window, "Font Designer");')

with open(path, 'w') as fh:
    fh.write(text)
PY
fi

info "Fetching packages"
flutter pub get

cat <<EOF

Done. To run:

  cd font_designer
  ./run.sh                       # the built app, rebuilt if sources changed
  flutter run -d linux           # the development path, for hot reload
EOF
