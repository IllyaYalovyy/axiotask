#!/usr/bin/env bash

set -euo pipefail

google_contract_fail() {
  printf 'Google contract cleanup failed: %s\n' "$1" >&2
  exit 1
}

[[ "${AXIOTASK_RUN_GOOGLE_CONTRACT_CLEANUP:-}" == '1' ]] ||
  google_contract_fail 'set AXIOTASK_RUN_GOOGLE_CONTRACT_CLEANUP=1 to opt in'
prefix=${AXIOTASK_GOOGLE_CONTRACT_CLEANUP_PREFIX:-}
[[ "$prefix" =~ ^axiotask-contract-probe-[0-9]{8}T[0-9]{6}Z-[a-z0-9]{6,32}$ ]] ||
  google_contract_fail 'provide one exact Axiotask contract-probe prefix'

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
  google_contract_fail 'run this command from the Axiotask worktree'
[[ "$(uname -s)" == 'Linux' ]] || google_contract_fail 'this command supports Linux only'

# shellcheck source=scripts/google_contract_common.sh
source "$repository_root/scripts/google_contract_common.sh"
"$repository_root/scripts/preflight_capability_gate.sh" linux-auth
define_file=$(mktemp /tmp/axiotask-google-contract-cleanup-XXXXXX.json)
trap 'rm -f -- "$define_file"' EXIT
chmod 600 "$define_file"
google_contract_write_defines "$repository_root" "$define_file" "$prefix"

cd "$repository_root"
flutter test integration_test/google_tasks_contract_probe_test.dart -d linux \
  --dart-define-from-file="$define_file"
printf 'Google contract cleanup passed with zero matching prefix resources.\n'
