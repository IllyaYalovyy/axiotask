#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

runs="${AXIOTASK_DEEP_SYNC_RUNS:-2}"
if ! [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then
  printf 'AXIOTASK_DEEP_SYNC_RUNS must be a positive integer.\n' >&2
  exit 2
fi

started=$SECONDS
printf 'Running deterministic deep synchronization evidence (%s pass(es))...\n' "$runs"

flutter test \
  test/support/fake_google_tasks_service_test.dart \
  test/support/multi_host_test.dart \
  test/support/reference_model_test.dart \
  test/support/replay_seed_test.dart

for ((pass = 1; pass <= runs; pass += 1)); do
  printf 'Deep synchronization pass %s/%s...\n' "$pass" "$runs"
  flutter test test/sync/deep_sync_state_machine_test.dart
done

flutter test \
  test/sync/content_reconciliation_multi_host_test.dart \
  test/sync/structure_reconciliation_multi_host_test.dart \
  test/sync/process_death_recovery_test.dart \
  test/sync/read_sync_process_death_test.dart

printf 'Deep synchronization evidence passed in %ss.\n' "$((SECONDS - started))"
