#!/usr/bin/env bash
# Launch a FULLY ISOLATED dev instance of axiotask.
#
# Redirects XDG_DATA_HOME to a dedicated dev root, so BOTH the SQLite database
# and the WebKitGTK storage (localStorage, cache, cookies) live under
#   ~/.local/share/axiotask-dev-home/
# instead of the production locations. This never reads or writes the real
# instance, so you can keep using the real app while this dev instance runs at
# the same time.
#
# Usage:
#   crates/axiotask-app/dev.sh              # cargo tauri dev, isolated
#   AXIOTASK_DEV_HOME=/path crates/axiotask-app/dev.sh   # custom dev root
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
export XDG_DATA_HOME="${AXIOTASK_DEV_HOME:-$HOME/.local/share/axiotask-dev-home}"
export AXIOTASK_PREFIX="${AXIOTASK_PREFIX:-dev}"   # also labels the window "axiotask (dev)"
mkdir -p "$XDG_DATA_HOME"

echo "axiotask DEV instance — data dir: $XDG_DATA_HOME (production untouched)"
cd "$HERE"
exec cargo tauri dev "$@"
