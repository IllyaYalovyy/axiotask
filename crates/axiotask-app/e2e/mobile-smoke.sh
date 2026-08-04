#!/usr/bin/env bash
# Android emulator smoke gate (#161) — OPT-IN.
#
# This is the mobile sibling of the desktop e2e smoke (run-smoke.sh). It proves
# the real Android app launches and that a quick-add round-trips through the
# backend on a live device/emulator. It is NOT wired into the automatic quality
# gate (.ktask/verify.sh) because it needs the Android SDK plus a running
# emulator or attached device; run it deliberately:
#
#   cd crates/axiotask-app/ui && npm run mobile:smoke
#   # or directly:
#   crates/axiotask-app/e2e/mobile-smoke.sh
#
# What it does, all through `adb`:
#   1. builds (unless AXIOTASK_APK points at a prebuilt debug apk) and installs
#      the DEBUG apk for com.axiotask.app
#   2. clears logcat, launches .MainActivity, and asserts the startup line
#      ("starting default instance") appears in logcat  → app launched, Rust ran
#   3. drives a quick-add via `adb shell input` (focus the quick-add field via
#      the FAB, type a title, press Enter) and asserts the backend's
#      "create_task: created task" marker appears in logcat  → IPC round-tripped
#
# Exit codes: 0 = passed. 1 = ran and an assertion failed (a real product/app
# bug). 2 = could not run (no adb / no device / SDK or apk missing) — this is a
# skipped gate, not a pass, so an operator can tell "green" from "never ran".
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"          # crates/axiotask-app
ROOT="$(cd "$APP/../.." && pwd)"

PKG="com.axiotask.app"
ACTIVITY="$PKG/.MainActivity"
TAG="axiotask"                          # paranoid_android logcat tag (src/lib.rs)
LAUNCH_MARK="starting default instance" # emitted by init in src/lib.rs
QUICKADD_MARK="create_task: created task" # emitted by commands::create_task
SIGNIN_MARK="starting Play Services sign-in" # emitted by AppState::start_login_mobile
TITLE="MobileSmoke $$"                  # unique-ish per run
# Step 4 (RFC-010): also assert the sign-in gesture reaches the Play Services
# plugin (the native account sheet appears). Needs a Google-APIs emulator image
# (Play Services present); opt in with AXIOTASK_SMOKE_SIGNIN=1 because the
# default AVD used for the quick-add check has no Play Services.
SMOKE_SIGNIN="${AXIOTASK_SMOKE_SIGNIN:-0}"

skip() { echo "mobile-smoke: SKIPPED (opt-in) — $1" >&2; exit 2; }

command -v adb >/dev/null 2>&1 || skip "adb not on PATH (install the Android SDK platform-tools)"

# Exactly one device/emulator must be attached so we drive a known target.
mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
if [ "${#DEVICES[@]}" -eq 0 ]; then
  skip "no emulator/device attached (start one: emulator -avd <name>)"
elif [ "${#DEVICES[@]}" -gt 1 ]; then
  skip "more than one device attached; set ANDROID_SERIAL to pick one"
fi
SERIAL="${ANDROID_SERIAL:-${DEVICES[0]}}"
adb() { command adb -s "$SERIAL" "$@"; }
echo "mobile-smoke: target device $SERIAL"

# ── Resolve the debug apk (build it unless one was provided) ─────────────────
APK="${AXIOTASK_APK:-}"
if [ -z "$APK" ]; then
  echo "mobile-smoke: building debug apk (cargo tauri android build --debug --apk)"
  ( cd "$APP" && cargo tauri android build --debug --apk ) \
    || skip "android build failed (need Android SDK + NDK; see ui/package.json android:init)"
  # Prefer a universal apk; otherwise take whatever single debug apk exists.
  OUT="$APP/gen/android/app/build/outputs/apk"
  APK="$(find "$OUT" -name '*universal*debug*.apk' 2>/dev/null | head -1)"
  [ -z "$APK" ] && APK="$(find "$OUT" -name '*debug*.apk' 2>/dev/null | head -1)"
fi
[ -n "$APK" ] && [ -f "$APK" ] || skip "debug apk not found (set AXIOTASK_APK=/path/to/app-debug.apk)"
echo "mobile-smoke: apk $APK"

cleanup() { adb uninstall "$PKG" >/dev/null 2>&1 || true; }
trap cleanup EXIT

adb uninstall "$PKG" >/dev/null 2>&1 || true
adb install -r -g "$APK" >/dev/null || { echo "mobile-smoke: FAIL adb install"; exit 1; }

# Wait for a logcat line under our tag, tolerating startup latency.
wait_for_log() {
  local needle="$1" label="$2" attempts="${3:-40}"
  for ((i = 0; i < attempts; i++)); do
    if adb logcat -d -s "$TAG:*" 2>/dev/null | grep -qF "$needle"; then
      echo "mobile-smoke: ok — $label"
      return 0
    fi
    sleep 0.5
  done
  echo "mobile-smoke: FAIL — timed out waiting for $label (\"$needle\")"
  echo "--- last logcat ($TAG) ---"
  adb logcat -d -s "$TAG:*" 2>/dev/null | tail -40
  return 1
}

# ── 1) launch ────────────────────────────────────────────────────────────────
adb logcat -c || true
adb shell am start -n "$ACTIVITY" >/dev/null || { echo "mobile-smoke: FAIL am start"; exit 1; }
wait_for_log "$LAUNCH_MARK" "app launched and Rust init ran" || exit 1

# ── 2) quick-add via adb input ───────────────────────────────────────────────
# The quick-add field lives in the top toolbar; the FAB (bottom-right on touch)
# focuses it. Compute tap coordinates from the real screen size so this works on
# any emulator profile. Tap the FAB, type the title, press Enter to submit.
SIZE="$(adb shell wm size 2>/dev/null | sed -n 's/.*Physical size: \([0-9]*x[0-9]*\).*/\1/p' | tail -1)"
W="${SIZE%x*}"; H="${SIZE#*x}"
if [ -z "${W:-}" ] || [ -z "${H:-}" ]; then
  echo "mobile-smoke: FAIL — could not read screen size (wm size)"; exit 1
fi
# FAB sits ~10% in from the bottom-right corner (see .mobile-fab in App.svelte).
FAB_X=$(( W - W / 10 )); FAB_Y=$(( H - H / 10 ))
sleep 1                                   # let first paint settle
adb shell input tap "$FAB_X" "$FAB_Y"
sleep 1
adb shell input text "${TITLE// /%s}"     # %s = space for `input text`
sleep 0.5
adb shell input keyevent 66               # KEYCODE_ENTER → submits the form
wait_for_log "$QUICKADD_MARK" "quick-add round-tripped through create_task" || exit 1

# ── 3) Play Services sign-in gesture (RFC-010 Step 4) ────────────────────────
# On a Google-APIs image, tapping sign-in must reach the plugin and surface the
# native account sheet. We assert the Rust marker AppState::start_login_mobile
# emits when the gesture reaches the Play Services plugin; the sheet itself is
# Google's own UI (not observable in logcat). Full consent still requires the
# live on-device merge gate (G5) — this only proves the gesture is wired.
if [ "$SMOKE_SIGNIN" = "1" ]; then
  # The sign-in action lives in the account/settings area of the top toolbar
  # (top-right). Coordinates are a best effort; adjust per AVD profile if needed.
  SIGNIN_X=$(( W - W / 12 )); SIGNIN_Y=$(( H / 20 ))
  sleep 0.5
  adb shell input tap "$SIGNIN_X" "$SIGNIN_Y"
  wait_for_log "$SIGNIN_MARK" "sign-in gesture reached the Play Services plugin" || exit 1
else
  echo "mobile-smoke: sign-in gesture check SKIPPED (set AXIOTASK_SMOKE_SIGNIN=1 on a Google-APIs image)"
fi

echo
echo "MOBILE SMOKE TEST PASSED"
