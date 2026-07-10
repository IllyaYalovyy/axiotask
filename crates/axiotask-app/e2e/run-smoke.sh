#!/usr/bin/env bash
# End-to-end smoke test runner.
#
# Launches the real release binary through tauri-driver + WebKitWebDriver inside
# a nested Xephyr X server (software rendering, no GPU needed — CI-friendly) and
# runs e2e/smoke.mjs against it. Exit 0 = the app actually works.
#
# Requires: tauri-driver (cargo install tauri-driver), WebKitWebDriver, Xephyr,
# node, and a release build made with `cargo tauri build --no-bundle`.
#
# It must be `cargo tauri build` — a plain `cargo build --release` bakes in the
# dev server URL, so the binary loads http://localhost:1420 and shows
# "Could not connect to localhost" instead of the app.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BIN="$ROOT/target/release/axiotask"
DISP=":97"
NATIVE_DRIVER="$(command -v WebKitWebDriver || echo /usr/bin/WebKitWebDriver)"

# Fully isolate this run: dirs::data_dir() AND WebKitGTK's storage both honor
# XDG_DATA_HOME, so pointing it at a fresh temp dir gives a clean DB + clean
# localStorage every time (no view/geometry state leaking between runs).
E2E_HOME="$(mktemp -d /tmp/axiotask-e2e.XXXXXX)"

cleanup() {
  [ -n "${DRIVER_PID:-}" ] && kill "$DRIVER_PID" 2>/dev/null
  pkill -f "target/release/axiotask" 2>/dev/null
  pkill -f "WebKitWebDriver" 2>/dev/null
  [ -n "${XEPHYR_PID:-}" ] && kill "$XEPHYR_PID" 2>/dev/null
  pkill -f "Xephyr $DISP" 2>/dev/null
  rm -rf "$E2E_HOME" 2>/dev/null
}
trap cleanup EXIT

if [ ! -x "$BIN" ]; then
  echo "release binary missing: $BIN"
  echo "build it first: cd crates/axiotask-app && cargo tauri build --no-bundle"
  exit 2
fi

pkill -f "Xephyr $DISP" 2>/dev/null; sleep 0.3
Xephyr "$DISP" -screen 1200x800 -ac -noreset >/tmp/e2e-xephyr.log 2>&1 &
XEPHYR_PID=$!
sleep 1.5

# Isolated data dir so we never touch real data; offline (no tokens).
env DISPLAY="$DISP" GDK_BACKEND=x11 WAYLAND_DISPLAY= \
  XDG_DATA_HOME="$E2E_HOME/share" \
  tauri-driver --native-driver "$NATIVE_DRIVER" >/tmp/e2e-tauri-driver.log 2>&1 &
DRIVER_PID=$!
sleep 2.5

AXIOTASK_BIN="$BIN" node "$HERE/smoke.mjs"
RC=$?

if [ $RC -ne 0 ]; then
  echo "--- tauri-driver log ---"; tail -20 /tmp/e2e-tauri-driver.log
fi
exit $RC
