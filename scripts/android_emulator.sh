#!/usr/bin/env bash
# Foreground launcher: keep this terminal open for the emulator's lifetime.
set -euo pipefail

if [[ ${1:-} == --help ]]; then
  echo 'Usage: bash scripts/android_emulator.sh [AVD [PORT]]'
  echo 'Defaults: axiotask_api36, 5580. Set EMULATOR_WINDOW=1 for a window.'
  echo 'Cold boots with host GLES, Vulkan disabled, and disposable AVD writes.'
  exit 0
fi
[[ $# -le 2 ]] || { echo 'Expected at most AVD and PORT.' >&2; exit 2; }
avd=${1:-axiotask_api36}
port=${2:-5580}
[[ $port =~ ^[0-9]{4}$ ]] && (( port >= 5554 && port <= 5682 && port % 2 == 0 )) || {
  echo 'PORT must be an even number from 5554 through 5682.' >&2
  exit 2
}
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}
emulator=$sdk/emulator/emulator
[[ -x $emulator ]] || { echo "Emulator not found: $emulator" >&2; exit 1; }
"$emulator" -accel-check
window=(-no-window)
[[ ${EMULATOR_WINDOW:-0} != 1 ]] || window=()
exec "$emulator" -avd "$avd" -port "$port" -read-only \
  "${window[@]}" -no-audio -no-boot-anim -no-snapshot \
  -gpu host -feature -Vulkan -memory 2048 -cores 2 -no-metrics
