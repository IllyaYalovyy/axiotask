#!/usr/bin/env bash
# axiotask — build & install the Linux desktop app FOR THE CURRENT USER.
#
# No sudo, nothing outside your home directory. This is the non-RPM path; for a
# system-wide package use tool/build_rpm.sh (or fastforge, see
# distribute_options.yaml). The two install the same set of files, one under
# /usr, this one under ~/.local.
#
# What is installed (and why there):
#   ~/.local/lib/axiotask/                    the whole release bundle
#   ~/.local/bin/axiotask                     symlink -> the bundle's binary
#   ~/.local/share/applications/io.github.illyayalovyy.axiotask.desktop
#   ~/.local/share/icons/hicolor/<size>/apps/axiotask.png  (+ scalable SVG)
#   ~/.local/share/metainfo/io.github.illyayalovyy.axiotask.metainfo.xml
#
# The desktop entry is named after the application id, NOT after the binary:
# GNOME on Wayland gives a running window its icon by looking up a desktop file
# whose basename equals the window's app_id (the APPLICATION_ID the runner sets
# with g_set_prgname). Under any other name the dash shows a blank icon (#227).
#
# The bundle deliberately goes to ~/.local/lib/axiotask and NOT to
# ~/.local/share/axiotask: that path is the app's own XDG DATA directory (the
# SQLite database, tokens, prefs and backups live there — see
# lib/src/app/platform_paths.dart). Installing over it would put user data and
# program files in one directory, and an upgrade, which replaces the program
# directory wholesale, would take the database with it. This script never
# writes to, and never deletes, ~/.local/share/axiotask*, ~/.config/axiotask*
# or any other data location — uninstall included.
#
# Usage:
#   tool/install.sh                     build a release bundle, then install
#   tool/install.sh --bundle DIR        install an already-built bundle
#   tool/install.sh --uninstall         remove everything this script installed
#   tool/install.sh --help
#
# Honors $HOME and $XDG_DATA_HOME, so an install can be exercised against a
# throwaway home (that is how test/packaging/linux_distribution_test.dart runs
# it without touching the real one).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="axiotask"
APP_ID="io.github.illyayalovyy.axiotask"
ICON_SIZES="16 24 32 48 64 128 256 512"

# Whether this build compiles the OAuth client credentials in, so the install
# can sign in out of the box (#229). Nothing is bundled unless the operator
# created the gitignored credentials file; see tool/oauth_defines.sh.
# shellcheck source=tool/oauth_defines.sh
. "$ROOT/tool/oauth_defines.sh"

SRC_DESKTOP="linux/packaging/${APP_ID}.desktop"
SRC_ICONS="linux/packaging/icons/hicolor"
SRC_METAINFO="linux/packaging/${APP_ID}.metainfo.xml"
BUILD_BUNDLE="build/linux/x64/release/bundle"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LIB_DIR="$HOME/.local/lib/$APP_NAME"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$DATA_HOME/applications"
ICON_ROOT="$DATA_HOME/icons/hicolor"
METAINFO_DIR="$DATA_HOME/metainfo"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The header comment block IS the help text — one place to keep current.
usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
}

# The one place a mistake would be unrecoverable: LIB_DIR is removed wholesale
# on install and uninstall, so prove first that it is not a data directory.
assert_lib_dir_is_safe() {
  case "$LIB_DIR" in
    "$DATA_HOME/$APP_NAME"|"$DATA_HOME/$APP_NAME-"*|"$HOME"|"$HOME/"|/|"")
      die "refusing to use $LIB_DIR as the program directory — it is (or contains) user data"
      ;;
  esac
  [ "${LIB_DIR%/$APP_NAME}" != "$LIB_DIR" ] \
    || die "internal error: program directory $LIB_DIR is not app-owned"
}

app_version() {
  local raw
  raw=$(grep -E '^version:' pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//; s/[[:space:]]*#.*$//')
  echo "${raw%%+*}"
}

refresh_caches() {
  if command -v update-desktop-database >/dev/null; then
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  fi
  if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -f -t "$ICON_ROOT" 2>/dev/null || true
  fi
}

uninstall() {
  assert_lib_dir_is_safe
  info "Removing installed files (user data is NOT touched)..."
  rm -rf "$LIB_DIR"
  rm -f "$BIN_DIR/$APP_NAME"
  rm -f "$DESKTOP_DIR/${APP_ID}.desktop"
  # An install made before #227 renamed the entry left ${APP_NAME}.desktop
  # behind; without this it survives as a duplicate app-menu entry forever.
  rm -f "$DESKTOP_DIR/${APP_NAME}.desktop"
  rm -f "$METAINFO_DIR/${APP_ID}.metainfo.xml"
  # Icons are removed file by file — never a recursive delete inside a shared
  # theme directory that other applications also populate.
  for s in $ICON_SIZES; do
    rm -f "$ICON_ROOT/${s}x${s}/apps/${APP_NAME}.png"
  done
  rm -f "$ICON_ROOT/scalable/apps/${APP_NAME}.svg"
  refresh_caches
  info "Uninstalled."
  info "Your tasks, tokens and settings were left in place:"
  info "  $DATA_HOME/$APP_NAME  and  ${XDG_CONFIG_HOME:-$HOME/.config}/$APP_NAME"
}

# ── Arguments ───────────────────────────────────────────────────────────────
BUNDLE=""
ACTION="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) ACTION="uninstall"; shift ;;
    --bundle)    BUNDLE="${2:-}"; [ -n "$BUNDLE" ] || die "--bundle needs a directory"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown argument: $1 (use: --bundle DIR | --uninstall | --help)" ;;
  esac
done

if [ "$ACTION" = "uninstall" ]; then uninstall; exit 0; fi

# ── Install ─────────────────────────────────────────────────────────────────
assert_lib_dir_is_safe

# Everything the packaging step needs must exist before anything is written,
# so a broken checkout or a bad --bundle leaves the system exactly as it was.
[ -f "$SRC_DESKTOP" ]  || die "desktop entry missing at $SRC_DESKTOP"
[ -f "$SRC_METAINFO" ] || die "AppStream metainfo missing at $SRC_METAINFO"
for s in $ICON_SIZES; do
  [ -f "$SRC_ICONS/${s}x${s}/apps/${APP_NAME}.png" ] \
    || die "hicolor icon ${s}x${s} missing — run tool/gen_icons.py"
done
[ -f "$SRC_ICONS/scalable/apps/${APP_NAME}.svg" ] \
  || die "scalable icon missing — run tool/gen_icons.py"

if [ -z "$BUNDLE" ]; then
  command -v flutter >/dev/null || die "flutter not on PATH (or pass --bundle DIR)"
  oauth_define_args
  info "$(oauth_defines_report)"
  info "Building release bundle (flutter build linux --release)..."
  flutter build linux --release ${OAUTH_DEFINES+"${OAUTH_DEFINES[@]}"} \
    || die "flutter build linux --release failed"
  BUNDLE="$BUILD_BUNDLE"
fi
[ -d "$BUNDLE" ] || die "release bundle directory not found: $BUNDLE"
[ -x "$BUNDLE/$APP_NAME" ] || die "release bundle has no executable $APP_NAME: $BUNDLE"

VERSION="$(app_version)"

# Program directory: replaced wholesale, so an upgrade cannot leave stale
# libraries or assets from the previous bundle behind.
rm -rf "$LIB_DIR"
mkdir -p "$LIB_DIR" || die "could not create $LIB_DIR"
cp -a "$BUNDLE/." "$LIB_DIR/" || die "could not copy the bundle to $LIB_DIR"
info "Installed bundle   -> $LIB_DIR"

mkdir -p "$BIN_DIR"
ln -sfn "$LIB_DIR/$APP_NAME" "$BIN_DIR/$APP_NAME"
info "Installed launcher -> $BIN_DIR/$APP_NAME"

# Exec= gets the ABSOLUTE launcher path: ~/.local/bin is not on every user's
# PATH, and the desktop environment does not read shell profiles.
mkdir -p "$DESKTOP_DIR"
sed "s|^Exec=.*|Exec=$BIN_DIR/$APP_NAME|" "$SRC_DESKTOP" \
  > "$DESKTOP_DIR/${APP_ID}.desktop" || die "could not write the desktop entry"
chmod 644 "$DESKTOP_DIR/${APP_ID}.desktop"
# Drop the pre-#227 entry so upgrading an old install does not leave the app
# listed twice in the menu.
rm -f "$DESKTOP_DIR/${APP_NAME}.desktop"
info "Installed launcher entry -> $DESKTOP_DIR/${APP_ID}.desktop"

for s in $ICON_SIZES; do
  install -Dm644 "$SRC_ICONS/${s}x${s}/apps/${APP_NAME}.png" \
    "$ICON_ROOT/${s}x${s}/apps/${APP_NAME}.png" || die "could not install the ${s}x${s} icon"
done
install -Dm644 "$SRC_ICONS/scalable/apps/${APP_NAME}.svg" \
  "$ICON_ROOT/scalable/apps/${APP_NAME}.svg" || die "could not install the scalable icon"
info "Installed icons    -> $ICON_ROOT"

install -Dm644 "$SRC_METAINFO" "$METAINFO_DIR/${APP_ID}.metainfo.xml" \
  || die "could not install the AppStream metainfo"
info "Installed metadata -> $METAINFO_DIR/${APP_ID}.metainfo.xml"

refresh_caches

case ":${PATH:-}:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH — launch from the app menu, or run $BIN_DIR/$APP_NAME" ;;
esac

info "axiotask $VERSION installed for $(id -un). Launch it from your app menu."
