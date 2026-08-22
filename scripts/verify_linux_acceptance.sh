#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf '%s\n' \
    "Usage: ${0##*/}" \
    "       ${0##*/} --human [--live-probes]" >&2
}

fail() {
  printf 'Linux acceptance failed: %s\n' "$1" >&2
  exit 1
}

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
human_review=false
live_probes=false
smoke_root=''
smoke_worktree=''
smoke_worktree_registered=false

cleanup_smoke_workspace() {
  if [[ "$smoke_worktree_registered" == true ]]; then
    if git -C "$repository_root" worktree remove --force \
      "$smoke_worktree" >/dev/null 2>&1; then
      smoke_worktree_registered=false
    else
      printf 'Linux acceptance warning: isolated smoke worktree cleanup failed.\n' >&2
      return
    fi
  fi
  if [[ -n "$smoke_root" && -d "$smoke_root" ]]; then
    rm -rf -- "$smoke_root"
  fi
}
trap cleanup_smoke_workspace EXIT

case $# in
  0) ;;
  1)
    [[ "$1" == '--human' ]] || {
      usage
      exit 2
    }
    human_review=true
    ;;
  2)
    [[ "$1" == '--human' && "$2" == '--live-probes' ]] || {
      usage
      exit 2
    }
    human_review=true
    live_probes=true
    ;;
  *)
    usage
    exit 2
    ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "required command '$1' is unavailable"
}

require_clean_worktree() {
  local worktree_state
  worktree_state=$(git -C "$repository_root" status --porcelain \
    --untracked-files=all)
  [[ -z "$worktree_state" ]] ||
    fail 'the release acceptance gate requires a clean worktree'
}

linux_bundle_path() {
  local mode=$1 root=$2 architecture
  case "$(uname -m)" in
    x86_64 | amd64) architecture=x64 ;;
    aarch64 | arm64) architecture=arm64 ;;
    *) fail 'this Linux architecture has no known Flutter bundle path' ;;
  esac
  printf '%s/build/linux/%s/%s/bundle/axiotask\n' \
    "$root" "$architecture" "$mode"
}

supported_linux_integrations=(
  integration_test/account_backup_linux_test.dart
  integration_test/bulk_capture_linux_test.dart
  integration_test/bulk_operations_linux_test.dart
  integration_test/create_publish_linux_test.dart
  integration_test/database_native_probe_test.dart
  integration_test/delete_publish_linux_test.dart
  integration_test/desktop_drag_reorder_linux_test.dart
  integration_test/diagnostics_linux_test.dart
  integration_test/hierarchy_commands_linux_test.dart
  integration_test/local_data_recovery_linux_test.dart
  integration_test/offline_list_edits_linux_test.dart
  integration_test/offline_task_edits_linux_test.dart
  integration_test/preferences_native_smoke_test.dart
  integration_test/quick_capture_linux_test.dart
  integration_test/read_slice_linux_test.dart
  integration_test/search_navigation_linux_test.dart
  integration_test/smart_views_restart_linux_test.dart
  integration_test/task_details_linux_test.dart
  integration_test/update_publish_linux_test.dart
)

opt_in_linux_integrations=(
  integration_test/google_tasks_contract_probe_test.dart
  integration_test/google_tasks_mutation_probe_test.dart
  integration_test/linux_auth_probe_test.dart
  integration_test/linux_secure_storage_probe_test.dart
)

validate_integration_inventory() {
  declare -A classified=()
  local integration
  for integration in "${supported_linux_integrations[@]}" \
    "${opt_in_linux_integrations[@]}"; do
    [[ -f "$repository_root/$integration" ]] ||
      fail "classified Linux integration test is missing: $integration"
    classified["$integration"]=1
  done

  while IFS= read -r integration; do
    [[ -v "classified[$integration]" ]] ||
      fail "Linux integration test has no safe or opt-in classification: $integration"
  done < <(
    find "$repository_root/integration_test" -maxdepth 1 -type f \
      -name '*_test.dart' -printf 'integration_test/%f\n' | sort
  )
}

run_isolated_bundle_smoke() {
  smoke_root=$(mktemp -d /tmp/axiotask-linux-acceptance-XXXXXX) ||
    fail 'could not create the isolated smoke workspace'
  smoke_worktree="$smoke_root/worktree"
  git -C "$repository_root" worktree add --detach "$smoke_worktree" HEAD
  smoke_worktree_registered=true

  (
    cd "$smoke_worktree"
    flutter pub get --offline
    flutter build linux --debug -t lib/main_test.dart \
      --dart-define=AXIOTASK_TEST_INSTANCE=release-acceptance-smoke
  )

  local bundle status
  bundle=$(linux_bundle_path debug "$smoke_worktree")
  [[ -x "$bundle" ]] ||
    fail 'the isolated synthetic Linux bundle was not produced'
  mkdir -p "$smoke_root/xdg-data" "$smoke_root/xdg-config" \
    "$smoke_root/xdg-cache" "$smoke_root/xdg-state"

  set +e
  XDG_DATA_HOME="$smoke_root/xdg-data" \
    XDG_CONFIG_HOME="$smoke_root/xdg-config" \
    XDG_CACHE_HOME="$smoke_root/xdg-cache" \
    XDG_STATE_HOME="$smoke_root/xdg-state" \
    timeout --signal=TERM --kill-after=2s 10s "$bundle"
  status=$?
  set -e
  [[ $status -eq 124 ]] ||
    fail "the isolated synthetic bundle exited before the bounded smoke completed (status $status)"

  git -C "$repository_root" worktree remove --force "$smoke_worktree"
  smoke_worktree_registered=false
  rm -rf -- "$smoke_root"
  smoke_root=''
  smoke_worktree=''
}

run_noninteractive_gate() {
  [[ "$(uname -s)" == 'Linux' ]] || fail 'this command supports Linux only'
  require_command flutter
  require_command find
  require_command git
  require_command timeout

  require_clean_worktree
  validate_integration_inventory

  cd "$repository_root"
  ./scripts/quality.sh
  ./scripts/deep_sync.sh

  local integration
  for integration in "${supported_linux_integrations[@]}"; do
    flutter test "$integration" -d linux
  done

  ./scripts/privacy_check.sh
  run_isolated_bundle_smoke
  ./scripts/linux_app.sh build debug
  ./scripts/linux_app.sh build release
  ./scripts/linux_app.sh build-dev debug
  require_clean_worktree
  printf 'Noninteractive Linux acceptance evidence passed.\n'
}

print_human_checklist() {
  cat <<'EOF'
Human acceptance checklist (review the real production app):
1. Connect/reauthorize works; No authorization, Pending, Failed, offline, and stale states never appear green.
2. A forced or scheduled successful verification becomes green; failures become red immediately with useful diagnostics.
3. Offline list/task edits remain usable, then reconnect and converge without silent loss or repeated oscillation.
4. Stop prevents Google work without blocking edits; Resume verifies and publishes pending work.
5. List, task, subtask, due/completion, order/move, quick capture, bulk, search, and undo workflows behave correctly.
6. Diagnostics are reachable and useful; production display/export remains redacted and contains no credentials.
7. Backup export/import and Reset Local Data show accurate scope, confirmations, and non-destructive failure behavior.
8. Google Tasks recurrence escape hatch and ordinary external links open the intended destination.
Close the app when review is complete. No approval is recorded by this command.
EOF
}

run_human_review() {
  print_human_checklist

  local release_bundle
  release_bundle=$(linux_bundle_path release "$repository_root")
  [[ -x "$release_bundle" ]] ||
    fail 'the configured production release bundle is missing'
  "$release_bundle"

  if [[ "$live_probes" == true ]]; then
    "$repository_root/scripts/preflight_capability_gate.sh" linux-auth
    AXIOTASK_RUN_LINUX_AUTH_PROBE=1 \
      "$repository_root/scripts/probe_linux_auth.sh"
    AXIOTASK_RUN_LINUX_SECURE_STORAGE_PROBE=1 \
      "$repository_root/scripts/probe_linux_secure_storage.sh"
    AXIOTASK_RUN_GOOGLE_CONTRACT=1 \
      "$repository_root/scripts/test_google.sh"
  fi

  printf 'Automated evidence completed. No approval is recorded by this command.\n'
}

run_noninteractive_gate
if [[ "$human_review" == true ]]; then
  run_human_review
fi
