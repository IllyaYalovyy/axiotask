#!/usr/bin/env bash

set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
suite="$repository_root/scripts/test_google.sh"
cleanup="$repository_root/scripts/cleanup_google_contract.sh"
fixture_root=$(mktemp -d /tmp/axiotask-google-contract-script-XXXXXX)
trap 'rm -rf -- "$fixture_root"' EXIT

assert_fails_with() {
  local expected=$1
  shift
  local output
  if output=$("$@" 2>&1); then
    printf 'Google contract script unexpectedly passed: %s\n' "$expected" >&2
    exit 1
  fi
  [[ "$output" == *"$expected"* ]] || {
    printf 'Google contract script did not report: %s\n' "$expected" >&2
    exit 1
  }
}

[[ -x "$suite" && -x "$cleanup" ]] || {
  printf 'Google contract scripts must be executable\n' >&2
  exit 1
}
assert_fails_with 'set AXIOTASK_RUN_GOOGLE_CONTRACT=1 to opt in' "$suite"
assert_fails_with 'set AXIOTASK_RUN_GOOGLE_CONTRACT_CLEANUP=1 to opt in' "$cleanup"
assert_fails_with 'provide one exact Axiotask contract-probe prefix' \
  env AXIOTASK_RUN_GOOGLE_CONTRACT_CLEANUP=1 \
  AXIOTASK_GOOGLE_CONTRACT_CLEANUP_PREFIX=unsafe-prefix "$cleanup"

private_config="$fixture_root/google_contract.env"
printf '%s\n' 'AXIOTASK_GOOGLE_CONTRACT_UNEXPECTED=value' >"$private_config"
chmod 600 "$private_config"
assert_fails_with 'private configuration is not ignored by Git' \
  env AXIOTASK_RUN_GOOGLE_CONTRACT=1 \
  AXIOTASK_STAGE7_GATE_CONFIG="$private_config" "$suite"

if ! git -C "$repository_root" check-ignore -q -- .ktask/gates/stage7.env ||
  ! git -C "$repository_root" check-ignore -q -- .ktask/gates/linux-auth-subject; then
  printf 'Google contract private sources must stay ignored\n' >&2
  exit 1
fi

printf 'Google contract script safety tests passed\n'
