#!/usr/bin/env bash
#
# axiotask — build & install for the current user.
#
# Builds the PRODUCTION binary the correct way (`cargo tauri build`, which embeds
# the frontend — a plain `cargo build` makes a dev-only binary that fails with
# "Could not connect to localhost") and installs it for your user:
#   - binary   -> ~/.local/bin/axiotask         (on your PATH)
#   - icon     -> ~/.local/share/icons/...
#   - launcher -> ~/.local/share/applications/axiotask.desktop  (app menu)
#
# Usage:
#   ./install.sh            build + install
#   ./install.sh uninstall  remove everything this script installed
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT/crates/axiotask-app"
BIN_SRC="$ROOT/target/release/axiotask"

BIN_DIR="${AXIOTASK_BIN_DIR:-$HOME/.local/bin}"
ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/axiotask.desktop"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

uninstall() {
  info "Removing installed files..."
  rm -fv "$BIN_DIR/axiotask" "$ICON_DIR/axiotask.png" "$DESKTOP_FILE"
  update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
  info "Uninstalled. (User data in ~/.local/share/axiotask was left untouched.)"
}

if [ "${1:-}" = "uninstall" ]; then uninstall; exit 0; fi
if [ "${1:-}" != "" ]; then die "unknown argument: $1 (use: install.sh [uninstall])"; fi

# --- Prerequisites ---------------------------------------------------------
command -v cargo >/dev/null || die "cargo not found — install Rust (https://rustup.rs)"
command -v npm   >/dev/null || die "npm not found — install Node.js 18+"
cargo tauri --version >/dev/null 2>&1 || die "tauri-cli not found — run: cargo install tauri-cli"

# --- Frontend dependencies -------------------------------------------------
if [ ! -d "$APP_DIR/ui/node_modules" ]; then
  info "Installing frontend dependencies..."
  ( cd "$APP_DIR/ui" && { npm ci || npm install; } )
fi

# --- Build (the right way) -------------------------------------------------
info "Building production binary (cargo tauri build)..."
( cd "$APP_DIR" && cargo tauri build )
[ -x "$BIN_SRC" ] || die "build did not produce $BIN_SRC"

# --- Install binary --------------------------------------------------------
install -Dm755 "$BIN_SRC" "$BIN_DIR/axiotask"
info "Installed binary   -> $BIN_DIR/axiotask"

# --- Install icon ----------------------------------------------------------
if [ -f "$APP_DIR/icons/icon.png" ]; then
  install -Dm644 "$APP_DIR/icons/icon.png" "$ICON_DIR/axiotask.png"
  gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
  info "Installed icon     -> $ICON_DIR/axiotask.png"
fi

# --- Install desktop launcher ---------------------------------------------
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=axiotask
GenericName=Task Manager
Comment=Keyboard-driven, offline-first Google Tasks client
Exec=$BIN_DIR/axiotask
Icon=axiotask
Terminal=false
Categories=Utility;Office;ProjectManagement;
StartupWMClass=axiotask
EOF
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
info "Installed launcher -> $DESKTOP_FILE"

# --- PATH sanity note ------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\033[1;33mnote:\033[0m %s is not on your PATH — add it, or run %s directly.\n' "$BIN_DIR" "$BIN_DIR/axiotask" ;;
esac

info "Done. Launch 'axiotask' from a terminal or your application menu."
