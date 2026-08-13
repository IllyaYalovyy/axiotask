#!/usr/bin/env bash

set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
preflight="$repository_root/scripts/preflight_capability_gate.sh"
fixture_root=$(mktemp -d /tmp/axiotask-capability-gate-XXXXXX)
config_path="$repository_root/.ktask/gates/preflight-test-$BASHPID.env"
trap 'rm -rf -- "$fixture_root"; rm -f -- "$config_path"' EXIT

fail() {
  printf 'capability gate test failed: %s\n' "$1" >&2
  exit 1
}

assert_fails_with() {
  local expected=$1
  shift
  local output
  if output=$("$@" 2>&1); then
    fail "command unexpectedly passed: $expected"
  fi
  [[ "$output" == *"$expected"* ]] || fail "missing failure: $expected"
}

[[ -x "$preflight" ]] || fail 'preflight is missing or not executable'
assert_fails_with 'Usage:' "$preflight"
assert_fails_with 'private configuration is missing' \
  env AXIOTASK_STAGE7_GATE_CONFIG="$config_path" "$preflight" android-auth

mkdir -p "${config_path%/*}" "$fixture_root/bin"
printf '%s\n' \
  'AXIOTASK_AUTH_PROBE_ACCOUNT_SUBJECT=subject-output-canary' \
  'AXIOTASK_ANDROID_AUTH_CLIENT_ID=android-output-canary.apps.googleusercontent.com' \
  'AXIOTASK_LINUX_AUTH_CLIENT_ID=linux-output-canary.apps.googleusercontent.com' \
  'AXIOTASK_LINUX_AUTH_CLIENT_SECRET=secret-output-canary' \
  >"$config_path"

chmod 644 "$config_path"
assert_fails_with 'permissions must be 600' \
  env AXIOTASK_STAGE7_GATE_CONFIG="$config_path" "$preflight" android-auth
chmod 600 "$config_path"

# The generated fake expands its positional arguments when the preflight runs.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == devices ]]; then' \
  "  printf 'List of devices attached\\nphysical-fixture device product:fixture model:fixture\\n'" \
  '  exit 0' \
  'fi' \
  'if [[ "${1:-}" == -s && "${3:-}" == shell && "${4:-}" == pm ]]; then' \
  "  printf 'package:/synthetic/google-play-services.apk\\n'" \
  '  exit 0' \
  'fi' \
  'exit 1' \
  >"$fixture_root/bin/adb"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "printf '[{\"id\":\"physical-fixture\"}]\\n'" \
  >"$fixture_root/bin/flutter"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fixture_root/bin/gdbus"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fixture_root/bin/secret-tool"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fixture_root/bin/xdg-open"
chmod +x "$fixture_root/bin/"*

common_env=(
  env
  "PATH=$fixture_root/bin:$PATH"
  "AXIOTASK_STAGE7_GATE_CONFIG=$config_path"
)

android_output=$("${common_env[@]}" "$preflight" android-auth)
linux_output=$(
  "${common_env[@]}" DBUS_SESSION_BUS_ADDRESS=synthetic-session \
    "$preflight" linux-auth
)

[[ "$android_output" == 'Capability gate passed: Android authorization prerequisites are available.' ]] ||
  fail 'Android success output changed or disclosed configuration'
[[ "$linux_output" == 'Capability gate passed: Linux authorization prerequisites are available.' ]] ||
  fail 'Linux success output changed or disclosed configuration'

printf 'capability gate tests passed\n'
