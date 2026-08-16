#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

scenarios=(
  desktop-interactions-1024-light
  desktop-interactions-1280-dark
  search-results-light
  search-results-dark
  task-details-light
  task-details-dark
  task-workflows-light
  task-workflows-dark
  smart-views-light
  smart-views-dark
  quick-capture-light
  quick-capture-dark
  bulk-capture-preview-light
  bulk-capture-preview-dark
  bulk-capture-result-light
  bulk-capture-result-dark
  health-cached-pending
  health-partial-failed
  health-first-good
  health-stale-failed
  health-no-authorization
  health-sync-stopped
  health-retry-waiting
  health-retry-executing
  health-retry-exhausted
  list-create-pending
  list-rename-sync-stopped
  task-create-pending
  task-content-sync-stopped
  delete-undo
  delete-list-confirmation
  hierarchy-controls
  hierarchy-unsupported-error
)

for scenario in "${scenarios[@]}"; do
  flutter run -d linux --debug -t lib/main_health_screenshot.dart \
    --dart-define="AXIOTASK_SCREENSHOT_SCENARIO=$scenario"
done

flutter run -d linux --debug -t lib/main_database_recovery_screenshot.dart

printf 'Synthetic Linux screenshots written beneath screenshots/actual/.\n'
