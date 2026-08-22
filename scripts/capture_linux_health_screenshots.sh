#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

scenarios=(
  bulk-delete-undo-light
  clear-completed-confirmation-dark
  bulk-operation-selection-light
  bulk-operation-result-dark
  bulk-operation-confirmation-light
  bulk-operation-success-light
  drag-preview-light
  drag-failure-dark
  drag-rejection-dark
  drag-cleared-light
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

# S36B review captures use both desktop widths and themes. They are synthetic
# and intentionally remain in the ignored screenshot output directory.
health_review_scenarios=(
  health-first-good
  health-cached-pending
  health-partial-failed
  health-no-authorization
  health-stale-failed
  health-sync-stopped
)

for width in 1024 1355; do
  for theme in light dark; do
    for scenario in "${health_review_scenarios[@]}"; do
      flutter run -d linux --debug -t lib/main_health_screenshot.dart \
        --dart-define="AXIOTASK_SCREENSHOT_SCENARIO=$scenario" \
        --dart-define="AXIOTASK_SCREENSHOT_SIZE=${width}x800" \
        --dart-define="AXIOTASK_SCREENSHOT_THEME=$theme" \
        --dart-define="AXIOTASK_SCREENSHOT_OUTPUT_SUFFIX=${width}-${theme}"
    done
  done
done

flutter run -d linux --debug -t lib/main_database_recovery_screenshot.dart

printf 'Synthetic Linux screenshots written beneath screenshots/actual/.\n'
