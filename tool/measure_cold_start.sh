#!/usr/bin/env bash
# Release-build cold-start measurement (T2.5 / RESEARCH §"Startup": measure
# release-build cold start against the 2s budget as an early gate).
#
#   bash tool/measure_cold_start.sh [iterations]
#
# What it measures: wall-clock from PROCESS SPAWN to the first rendered frame of
# the RELEASE Linux build — the true cold start (process creation + engine init
# + Dart bootstrap + first frame). The app signals the frame by printing the
# AXIOTASK_FIRST_FRAME marker (see lib/src/app/startup_trace.dart) when launched
# with AXIOTASK_STARTUP_TRACE=1; this script times spawn → that marker against
# an ALREADY-RUNNING Xvfb display, so the display server's own boot is excluded.
#
# Isolation (isolate-from-production rule): every run gets a throwaway
# XDG_DATA_HOME / XDG_CONFIG_HOME and an AXIOTASK_PREFIX, so it never touches the
# user's real axiotask data.
#
# The FIRST iteration is the genuine cold start (cold OS file cache); later
# iterations are warm. We report every sample plus the cold value and the warm
# median, and FAIL if the cold start exceeds the 2000 ms budget.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUDGET_MS=2000
ITERS="${1:-5}"
BIN=build/linux/x64/release/bundle/axiotask

step() { printf '\n━━ %s\n' "$1"; }
fail() { printf '\nCOLD-START MEASUREMENT FAILED: %s\n' "$1"; exit 1; }

command -v flutter  >/dev/null || fail "flutter not on PATH"
command -v Xvfb     >/dev/null || fail "Xvfb missing (sudo dnf install xorg-x11-server-Xvfb)"

step "flutter build linux --release"
flutter build linux --release || fail "release build failed"
[ -x "$BIN" ] || fail "release binary not found at $BIN"

# A dedicated Xvfb we start ONCE and reuse, so its boot is not in any sample.
DISPLAY_NUM=99
Xvfb ":$DISPLAY_NUM" -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB_PID=$!
cleanup() { kill "$XVFB_PID" 2>/dev/null; }
trap cleanup EXIT
sleep 1.5  # let the display settle — NOT part of any measurement

step "measuring $ITERS cold/warm launches (budget ${BUDGET_MS} ms)"
samples=()
for i in $(seq 1 "$ITERS"); do
  TMP=$(mktemp -d)
  OUT="$TMP/out.log"
  start_ns=$(date +%s%N)
  env DISPLAY=":$DISPLAY_NUM" \
      XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config" \
      AXIOTASK_PREFIX="coldstart" AXIOTASK_STARTUP_TRACE=1 \
      "$BIN" >"$OUT" 2>&1 &
  APP_PID=$!
  end_ns=""
  for _ in $(seq 1 600); do          # up to ~3s of polling at 5ms
    if grep -q AXIOTASK_FIRST_FRAME "$OUT" 2>/dev/null; then
      end_ns=$(date +%s%N); break
    fi
    sleep 0.005
  done
  if [ -z "$end_ns" ]; then
    kill "$APP_PID" 2>/dev/null; rm -rf "$TMP"
    fail "iteration $i never printed AXIOTASK_FIRST_FRAME (app failed to reach first frame)"
  fi
  spawn_ms=$(( (end_ns - start_ns) / 1000000 ))
  dart_ms=$(grep -o 'main_to_first_frame_ms=[0-9]*' "$OUT" | head -1 | cut -d= -f2)
  label=$([ "$i" -eq 1 ] && echo "cold" || echo "warm")
  printf '  iter %d (%-4s): spawn→frame %4d ms   (dart main→frame %s ms)\n' \
    "$i" "$label" "$spawn_ms" "${dart_ms:-?}"
  samples+=("$spawn_ms")
  kill "$APP_PID" 2>/dev/null
  rm -rf "$TMP"
done

cold_ms=${samples[0]}
# Median of the warm samples (iterations 2..N), if any.
warm=("${samples[@]:1}")
warm_median="n/a"
if [ ${#warm[@]} -gt 0 ]; then
  IFS=$'\n' sorted=($(printf '%s\n' "${warm[@]}" | sort -n)); unset IFS
  warm_median=${sorted[$(( ${#sorted[@]} / 2 ))]}
fi

step "result"
printf '  cold start:  %d ms   (budget %d ms)\n' "$cold_ms" "$BUDGET_MS"
printf '  warm median: %s ms\n' "$warm_median"
if [ "$cold_ms" -ge "$BUDGET_MS" ]; then
  fail "cold start ${cold_ms} ms is over the ${BUDGET_MS} ms budget"
fi
printf '\n━━ COLD START WITHIN BUDGET (%d ms < %d ms)\n' "$cold_ms" "$BUDGET_MS"
