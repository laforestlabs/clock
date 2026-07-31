#!/usr/bin/env bash
#
# Installs a desktop launcher for the designer, so it can be started from the
# application grid or a double click instead of a terminal.
#
# Paths are derived from where this script lives, so the repository can be
# moved or cloned somewhere else and a re-run fixes the launcher up.
#
# The icon is rendered by the render core itself, once per icon size, rather
# than by scaling one image down. A 5x7 glyph does not survive resampling, so a
# downscaled icon turns to mush while a native render at each size stays crisp.
#
# Usage:
#   ./install-shortcut.sh                only the application grid entry
#   ./install-shortcut.sh --desktop      also drop a shortcut on the Desktop
#   ./install-shortcut.sh --uninstall    remove everything this installs

set -euo pipefail

cd "$(dirname "$0")"
DESIGNER="$(pwd)"
REPO="$(cd .. && pwd)"

APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
ENTRY="$APPS/mirror-designer.desktop"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
DESKTOP_LINK="$DESKTOP_DIR/Mirror Designer.desktop"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

WANT_DESKTOP=0
case "${1:-}" in
  --desktop) WANT_DESKTOP=1 ;;
  --uninstall)
    rm -f "$ENTRY" "$DESKTOP_LINK"
    rm -f "$ICONS"/*/apps/mirror-designer.png
    update-desktop-database "$APPS" 2>/dev/null || true
    gtk-update-icon-cache -f -t "$ICONS" 2>/dev/null || true
    info "Removed the launcher, the Desktop shortcut and the icons."
    exit 0 ;;
  "") ;;
  *) warn "unknown option '$1', ignoring" ;;
esac

# ---------------------------------------------------------------------- icon

# mirror-cli is host only and needs nothing but gcc, so build it if it is
# missing rather than shipping the icon as a binary blob in the repository.
CLI="$REPO/core/build/host/mirror-cli"
if [ ! -x "$CLI" ]; then
  info "Building mirror-cli to render the icon"
  make -C "$REPO/core" -f Makefile.host >/dev/null 2>&1 || true
fi

if [ -x "$CLI" ]; then
  info "Rendering icons"
  # 64px is the raw framebuffer, so the small icon is pixel exact. The large
  # one gets --led, which reads as an LED panel at desktop icon sizes.
  # Rendered from the square 64x64 layout rather than the 64x32 default,
  # because icons are square and a 2:1 render would sit letterboxed in the
  # application grid.
  render() {  # size, scale, extra flags
    local size="$1" scale="$2"; shift 2
    mkdir -p "$ICONS/${size}x${size}/apps"
    ( cd "$REPO" && "$CLI" layouts/single.json -m typical -s "$scale" "$@" >/dev/null )
    cp "$REPO/out/single-typical.png" "$ICONS/${size}x${size}/apps/mirror-designer.png"
  }
  render 64 1
  render 128 2
  render 256 4 --led
  # Leave out/ holding the plain default render the README documents.
  ( cd "$REPO" && "$CLI" layouts/single.json -m typical >/dev/null ) || true
  ICON_NAME="mirror-designer"
else
  warn "could not build mirror-cli, falling back to a stock icon"
  ICON_NAME="applications-graphics"
fi

# --------------------------------------------------------------- desktop entry

chmod +x "$DESIGNER/run.sh"
mkdir -p "$APPS"

# StartupWMClass has to match the GTK application id that runner/my_application.cc
# passes to g_set_prgname, otherwise the window does not associate with this
# entry and the shell shows a generic icon next to a running app.
WMCLASS="$(sed -n 's/^set(APPLICATION_ID "\(.*\)")$/\1/p' "$DESIGNER/linux/CMakeLists.txt" 2>/dev/null || true)"
[ -n "$WMCLASS" ] || WMCLASS="com.example.mirror_designer"

cat > "$ENTRY" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Mirror Designer
GenericName=LED Matrix Layout Designer
Comment=Design and preview smart mirror layouts, pixel exact
Exec=$DESIGNER/run.sh
Icon=$ICON_NAME
Terminal=false
StartupNotify=true
StartupWMClass=$WMCLASS
Categories=Development;
Keywords=mirror;led;matrix;layout;esp32;hub75;
Actions=NoBuild;Rebuild;

[Desktop Action NoBuild]
Name=Launch without rebuilding
Exec=env MIRROR_NO_BUILD=1 $DESIGNER/run.sh

[Desktop Action Rebuild]
Name=Rebuild and launch
Exec=env MIRROR_FORCE_BUILD=1 $DESIGNER/run.sh
EOF

info "Installed $ENTRY"

if [ "$WANT_DESKTOP" -eq 1 ]; then
  if [ -d "$DESKTOP_DIR" ]; then
    cp "$ENTRY" "$DESKTOP_LINK"
    chmod +x "$DESKTOP_LINK"
    # GNOME refuses to run a desktop file it has not been told to trust, and
    # shows it as a text file until then.
    gio set "$DESKTOP_LINK" metadata::trusted true 2>/dev/null || true
    info "Installed $DESKTOP_LINK"
  else
    warn "no Desktop directory at $DESKTOP_DIR, skipping the desktop shortcut"
  fi
fi

update-desktop-database "$APPS" 2>/dev/null || true
gtk-update-icon-cache -f -t "$ICONS" 2>/dev/null || true

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$ENTRY" || warn "desktop-file-validate reported the above"
fi

cat <<EOF

Done. "Mirror Designer" is in the application grid, and can be pinned.

  first launch may build         if the app has never been built
  ./run.sh                       same thing from a shell
  MIRROR_NO_BUILD=1 ./run.sh     skip the up to date check entirely

EOF
