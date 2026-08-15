#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

scenarios=(
  health-cached-pending
  health-partial-failed
  health-first-good
  health-stale-failed
  health-no-authorization
  health-sync-stopped
  list-create-pending
  list-rename-sync-stopped
  task-create-pending
  task-content-sync-stopped
)

for scenario in "${scenarios[@]}"; do
  flutter run -d linux --debug -t lib/main_health_screenshot.dart \
    --dart-define="AXIOTASK_SCREENSHOT_SCENARIO=$scenario"
done

printf 'Synthetic Linux screenshots written beneath screenshots/actual/.\n'
