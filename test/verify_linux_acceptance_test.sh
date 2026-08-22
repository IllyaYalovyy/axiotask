#!/usr/bin/env bash

set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
fixture_root=$(mktemp -d /tmp/axiotask-linux-acceptance-test-XXXXXX)
trap 'rm -rf -- "$fixture_root"' EXIT
source_verifier="$repository_root/scripts/verify_linux_acceptance.sh"
verifier="$fixture_root/repository/scripts/verify_linux_acceptance.sh"
command_log="$fixture_root/commands.log"

fail() {
  printf 'Linux acceptance command test failed: %s\n' "$1" >&2
  exit 1
}

assert_before() {
  local earlier=$1 later=$2 earlier_line later_line
  earlier_line=$(grep -n -m1 -F -- "$earlier" "$command_log" | cut -d: -f1) ||
    fail "missing command: $earlier"
  later_line=$(grep -n -m1 -F -- "$later" "$command_log" | cut -d: -f1) ||
    fail "missing command: $later"
  ((earlier_line < later_line)) ||
    fail "command order is wrong: $earlier must precede $later"
}

assert_absent() {
  local unexpected=$1
  if grep -Fq -- "$unexpected" "$command_log"; then
    fail "unexpected command: $unexpected"
  fi
}

[[ -x "$source_verifier" ]] || fail 'acceptance command is missing or not executable'
install -Dm755 -- "$source_verifier" "$verifier"
mkdir -p "$fixture_root/bin"
cp -a -- "$repository_root/integration_test" "$fixture_root/repository/"

# These fakes expand their arguments and test environment only when executed.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''quality\n'\'' >>"$AXIOTASK_ACCEPTANCE_TEST_LOG"' \
  '[[ "${AXIOTASK_ACCEPTANCE_FAIL_STAGE:-}" != quality ]]' \
  >"$fixture_root/repository/scripts/quality.sh"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''deep-sync\n'\'' >>"$AXIOTASK_ACCEPTANCE_TEST_LOG"' \
  '[[ "${AXIOTASK_ACCEPTANCE_FAIL_STAGE:-}" != deep-sync ]]' \
  >"$fixture_root/repository/scripts/deep_sync.sh"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''privacy\n'\'' >>"$AXIOTASK_ACCEPTANCE_TEST_LOG"' \
  '[[ "${AXIOTASK_ACCEPTANCE_FAIL_STAGE:-}" != privacy ]]' \
  >"$fixture_root/repository/scripts/privacy_check.sh"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''linux-app:%s\n'\'' "$*" >>"$AXIOTASK_ACCEPTANCE_TEST_LOG"' \
  'if [[ "${1:-}" == build && "${2:-}" == release ]]; then' \
  '  mkdir -p "$PWD/build/linux/x64/release/bundle"' \
  '  printf '\''#!/usr/bin/env bash\nprintf "production-app\\n" >>"$AXIOTASK_ACCEPTANCE_TEST_LOG"\n'\'' >"$PWD/build/linux/x64/release/bundle/axiotask"' \
  '  chmod +x "$PWD/build/linux/x64/release/bundle/axiotask"' \
  'fi' \
  >"$fixture_root/repository/scripts/linux_app.sh"

for command_name in preflight_capability_gate probe_linux_auth \
  probe_linux_secure_storage test_google; do
  label=${command_name//_/-}
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "printf '$label:%s\\n' \"\$*\" >>\"\$AXIOTASK_ACCEPTANCE_TEST_LOG\"" \
    >"$fixture_root/repository/scripts/$command_name.sh"
done
chmod +x "$fixture_root/repository/scripts/"*.sh

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''flutter:%s\n'\'' "$*" >>"$AXIOTASK_ACCEPTANCE_TEST_LOG"' \
  'if [[ "${1:-}" == build && "${2:-}" == linux ]]; then' \
  '  mkdir -p "$PWD/build/linux/x64/debug/bundle"' \
  '  printf '\''#!/usr/bin/env bash\nprintf "synthetic-bundle\\n" >>"$AXIOTASK_ACCEPTANCE_TEST_LOG"\n'\'' >"$PWD/build/linux/x64/debug/bundle/axiotask"' \
  '  chmod +x "$PWD/build/linux/x64/debug/bundle/axiotask"' \
  'fi' \
  'if [[ "${AXIOTASK_ACCEPTANCE_FAIL_STAGE:-}" == integration && "${1:-}" == test ]]; then exit 9; fi' \
  >"$fixture_root/bin/flutter"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''timeout:%s\n'\'' "$*" >>"$AXIOTASK_ACCEPTANCE_TEST_LOG"' \
  'program=${!#}' \
  '"$program"' \
  'exit 124' \
  >"$fixture_root/bin/timeout"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''git:%s\n'\'' "$*" >>"$AXIOTASK_ACCEPTANCE_TEST_LOG"' \
  'if [[ " $* " == *'\'' status --porcelain '\''* ]]; then exit 0; fi' \
  'if [[ " $* " == *'\'' worktree add '\''* ]]; then' \
  '  target=${@: -2:1}' \
  '  mkdir -p "$target"' \
  '  exit 0' \
  'fi' \
  'if [[ " $* " == *'\'' worktree remove '\''* ]]; then' \
  '  target=${@: -1}' \
  '  rm -rf -- "$target"' \
  '  exit 0' \
  'fi' \
  'exit 0' \
  >"$fixture_root/bin/git"
chmod +x "$fixture_root/bin/"*

common_env=(
  env
  "PATH=$fixture_root/bin:$PATH"
  "AXIOTASK_ACCEPTANCE_TEST_LOG=$command_log"
  'AXIOTASK_ACCEPTANCE_SECRET_CANARY=never-print-this-secret'
)

default_output=$("${common_env[@]}" "$verifier" 2>&1)
[[ "$default_output" != *'never-print-this-secret'* ]] ||
  fail 'default output disclosed environment content'
assert_before 'quality' 'deep-sync'
assert_before 'deep-sync' 'flutter:test integration_test/'
assert_before 'flutter:test integration_test/' 'privacy'
assert_before 'privacy' 'flutter:pub get --offline'
assert_before 'flutter:pub get --offline' 'flutter:build linux --debug'
assert_before 'flutter:build linux --debug' 'timeout:'
assert_before 'timeout:' 'synthetic-bundle'
assert_before 'synthetic-bundle' 'linux-app:build debug'
assert_before 'linux-app:build debug' 'linux-app:build release'
assert_before 'linux-app:build release' 'linux-app:build-dev debug'
[[ $(grep -c '^flutter:test integration_test/.* -d linux$' "$command_log") -eq 19 ]] ||
  fail 'default mode did not run every safe Linux integration test exactly once'
assert_absent 'google_tasks_contract_probe_test.dart'
assert_absent 'google_tasks_mutation_probe_test.dart'
assert_absent 'linux_auth_probe_test.dart'
assert_absent 'linux_secure_storage_probe_test.dart'
assert_absent 'preflight-capability-gate:'
assert_absent 'probe-linux-auth:'
assert_absent 'probe-linux-secure-storage:'
assert_absent 'test-google:'
assert_absent 'production-app'

: >"$command_log"
if "${common_env[@]}" AXIOTASK_ACCEPTANCE_FAIL_STAGE=deep-sync \
  "$verifier" >/dev/null 2>&1; then
  fail 'a failed noninteractive stage did not fail the command'
fi
[[ "$(tr '\n' ' ' <"$command_log")" == *'quality deep-sync '* ]] ||
  fail 'fail-fast run omitted its prerequisite stages'
assert_absent 'flutter:'
assert_absent 'privacy'
assert_absent 'linux-app:'

: >"$command_log"
if "${common_env[@]}" AXIOTASK_ACCEPTANCE_FAIL_STAGE=integration \
  "$verifier" >/dev/null 2>&1; then
  fail 'a failed integration test did not fail the command'
fi
[[ $(grep -c '^flutter:test integration_test/' "$command_log") -eq 1 ]] ||
  fail 'integration failure did not stop the remaining integration tests'
assert_absent 'privacy'
assert_absent 'linux-app:'

: >"$command_log"
human_output=$("${common_env[@]}" "$verifier" --human 2>&1)
[[ "$human_output" == *'Human acceptance checklist'* ]] ||
  fail 'human mode did not print its review checklist'
[[ "$human_output" == *'No approval is recorded by this command'* ]] ||
  fail 'human mode claimed or implied automatic approval'
assert_before 'linux-app:build release' 'production-app'
assert_absent 'preflight-capability-gate:'
assert_absent 'probe-linux-auth:'
assert_absent 'probe-linux-secure-storage:'
assert_absent 'test-google:'

: >"$command_log"
live_output=$("${common_env[@]}" "$verifier" --human --live-probes 2>&1)
[[ "$live_output" != *'never-print-this-secret'* ]] ||
  fail 'live-mode output disclosed environment content'
assert_before 'production-app' 'probe-linux-auth:'
assert_before 'production-app' 'preflight-capability-gate:linux-auth'
assert_before 'preflight-capability-gate:linux-auth' 'probe-linux-auth:'
assert_before 'probe-linux-auth:' 'probe-linux-secure-storage:'
assert_before 'probe-linux-secure-storage:' 'test-google:'

: >"$command_log"
if "${common_env[@]}" "$verifier" --live-probes >/dev/null 2>&1; then
  fail '--live-probes was accepted without --human'
fi
[[ ! -s "$command_log" ]] || fail 'invalid options executed acceptance stages'

printf 'Linux acceptance command tests passed\n'
