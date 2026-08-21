#!/usr/bin/env bash

set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
fixture_root=$(mktemp -d /tmp/axiotask-linux-app-test-XXXXXX)
trap 'rm -rf -- "$fixture_root"' EXIT
source_wrapper="$repository_root/scripts/linux_app.sh"
wrapper="$fixture_root/repository/scripts/linux_app.sh"

fail() {
  printf 'Linux app wrapper test failed: %s\n' "$1" >&2
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
  [[ "$output" != *'client-id-output-canary'* ]] ||
    fail 'failure output disclosed the client ID'
  [[ "$output" != *'client-secret-output-canary'* ]] ||
    fail 'failure output disclosed the client secret'
}

write_config() {
  local path=$1
  shift
  printf '%s\n' "$@" >"$path"
  chmod 600 "$path"
}

[[ -x "$source_wrapper" ]] || fail 'wrapper is missing or not executable'
install -Dm755 -- "$source_wrapper" "$wrapper"
git -C "$fixture_root/repository" init -q
printf '.ktask/\n' >"$fixture_root/repository/.gitignore"
mkdir -p "$fixture_root/bin"
flutter_log="$fixture_root/flutter-arguments.log"
bundle_root="$fixture_root/repository/build/linux/x64"
case "$(uname -m)" in
  x86_64 | amd64) bundle_root="$fixture_root/repository/build/linux/x64" ;;
  aarch64 | arm64) bundle_root="$fixture_root/repository/build/linux/arm64" ;;
esac

# The fake records argument boundaries but never reads the private config.
# The generated fake expands its environment and arguments when it runs.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf '\''CALL\n'\'' >>"$AXIOTASK_FAKE_FLUTTER_LOG"' \
  'printf '\''%s\n'\'' "$@" >>"$AXIOTASK_FAKE_FLUTTER_LOG"' \
  'if [[ "${1:-}" == build && "${2:-}" == linux ]]; then' \
  '  mode=release' \
  '  [[ " $* " == *'\'' --debug '\''* ]] && mode=debug' \
  '  mkdir -p "$AXIOTASK_FAKE_BUNDLE_ROOT/$mode/bundle/data"' \
  '  printf '\''#!/usr/bin/env bash\nexit 0\n'\'' >"$AXIOTASK_FAKE_BUNDLE_ROOT/$mode/bundle/axiotask"' \
  '  chmod +x "$AXIOTASK_FAKE_BUNDLE_ROOT/$mode/bundle/axiotask"' \
  '  printf '\''synthetic bundle asset\n'\'' >"$AXIOTASK_FAKE_BUNDLE_ROOT/$mode/bundle/data/fixture.txt"' \
  'fi' \
  >"$fixture_root/bin/flutter"
# The generated fake expands its environment and arguments when it runs.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "${1:-}" == passwd ]] || exit 1' \
  'printf '\''fixture:x:%s:%s::%s:/bin/bash\n'\'' "${2:-1000}" "${2:-1000}" "$AXIOTASK_FAKE_USER_HOME"' \
  >"$fixture_root/bin/getent"
chmod +x "$fixture_root/bin/flutter"
chmod +x "$fixture_root/bin/getent"
mkdir -p "$fixture_root/user"

common_env=(
  env
  "PATH=$fixture_root/bin:$PATH"
  "AXIOTASK_FAKE_FLUTTER_LOG=$flutter_log"
  "AXIOTASK_FAKE_BUNDLE_ROOT=$bundle_root"
  "AXIOTASK_FAKE_USER_HOME=$fixture_root/user"
)

assert_fails_with 'Usage:' "$wrapper"
assert_fails_with 'private configuration is missing' \
  "${common_env[@]}" "$wrapper" run
assert_fails_with 'private configuration is missing' \
  "${common_env[@]}" "$wrapper" run --config "$fixture_root/missing.env"
[[ ! -e "$flutter_log" ]] || fail 'missing config invoked Flutter'

invalid_config="$fixture_root/invalid.env"
write_config "$invalid_config" \
  'AXIOTASK_LINUX_AUTH_CLIENT_ID=client-id-output-canary.apps.googleusercontent.com' \
  'this is not an env assignment' \
  'AXIOTASK_LINUX_AUTH_CLIENT_SECRET=client-secret-output-canary'
assert_fails_with 'invalid line' \
  "${common_env[@]}" "$wrapper" build debug --config "$invalid_config"
[[ ! -e "$flutter_log" ]] || fail 'malformed config invoked Flutter'

duplicate_config="$fixture_root/duplicate.env"
write_config "$duplicate_config" \
  'AXIOTASK_LINUX_AUTH_CLIENT_ID=client-id-output-canary.apps.googleusercontent.com' \
  'AXIOTASK_LINUX_AUTH_CLIENT_SECRET=client-secret-output-canary' \
  'AXIOTASK_LINUX_AUTH_CLIENT_SECRET=second-secret-output-canary'
assert_fails_with 'repeats a key' \
  "${common_env[@]}" "$wrapper" build release --config "$duplicate_config"
[[ ! -e "$flutter_log" ]] || fail 'duplicate config invoked Flutter'

missing_secret_config="$fixture_root/missing-secret.env"
write_config "$missing_secret_config" \
  'AXIOTASK_LINUX_AUTH_CLIENT_ID=client-id-output-canary.apps.googleusercontent.com'
assert_fails_with "missing 'AXIOTASK_LINUX_AUTH_CLIENT_SECRET'" \
  "${common_env[@]}" "$wrapper" run --config "$missing_secret_config"
[[ ! -e "$flutter_log" ]] || fail 'incomplete config invoked Flutter'

bad_client_config="$fixture_root/bad-client.env"
write_config "$bad_client_config" \
  'AXIOTASK_LINUX_AUTH_CLIENT_ID=client-id-output-canary' \
  'AXIOTASK_LINUX_AUTH_CLIENT_SECRET=client-secret-output-canary'
assert_fails_with "invalid 'AXIOTASK_LINUX_AUTH_CLIENT_ID'" \
  "${common_env[@]}" "$wrapper" build release --config "$bad_client_config"
[[ ! -e "$flutter_log" ]] || fail 'invalid client config invoked Flutter'

insecure_config="$fixture_root/insecure.env"
write_config "$insecure_config" \
  'AXIOTASK_LINUX_AUTH_CLIENT_ID=client-id-output-canary.apps.googleusercontent.com' \
  'AXIOTASK_LINUX_AUTH_CLIENT_SECRET=client-secret-output-canary'
chmod 644 "$insecure_config"
assert_fails_with 'permissions must be 600' \
  "${common_env[@]}" "$wrapper" build release --config "$insecure_config"
[[ ! -e "$flutter_log" ]] || fail 'insecure config invoked Flutter'

unignored_config="$fixture_root/repository/private.env"
write_config "$unignored_config" \
  'AXIOTASK_LINUX_AUTH_CLIENT_ID=client-id-output-canary.apps.googleusercontent.com' \
  'AXIOTASK_LINUX_AUTH_CLIENT_SECRET=client-secret-output-canary'
assert_fails_with 'inside the repository must be ignored' \
  "${common_env[@]}" "$wrapper" build release --config "$unignored_config"
[[ ! -e "$flutter_log" ]] || fail 'unignored config invoked Flutter'

config="$fixture_root/repository/.ktask/gates/stage7.env"
mkdir -p "${config%/*}"
write_config "$config" \
  '# Synthetic wrapper-test configuration.' \
  'AXIOTASK_LINUX_AUTH_CLIENT_ID=client-id-output-canary.apps.googleusercontent.com' \
  'AXIOTASK_LINUX_AUTH_CLIENT_SECRET=client-secret-output-canary' \
  'AXIOTASK_DEVELOPMENT_ACCOUNT_SUBJECT=synthetic-dedicated-subject'

run_output=$("${common_env[@]}" "$wrapper" run 2>&1)
[[ "$run_output" != *'client-id-output-canary'* ]] || fail 'run disclosed client ID'
[[ "$run_output" != *'client-secret-output-canary'* ]] || fail 'run disclosed client secret'
grep -Fxq -- 'run' "$flutter_log" || fail 'run did not invoke flutter run'
grep -Fxq -- '-d' "$flutter_log" || fail 'run omitted the Linux device option'
grep -Fxq -- 'linux' "$flutter_log" || fail 'run omitted the Linux target'
grep -Fxq -- 'lib/main.dart' "$flutter_log" || fail 'run omitted production entry point'
grep -Fxq -- "--dart-define-from-file=$config" "$flutter_log" ||
  fail 'run did not pass the private config file'

: >"$flutter_log"
build_output=$(
  "${common_env[@]}" "$wrapper" build release --config "$config" 2>&1
)
[[ "$build_output" != *'client-id-output-canary'* ]] || fail 'build disclosed client ID'
[[ "$build_output" != *'client-secret-output-canary'* ]] ||
  fail 'build disclosed client secret'
grep -Fxq -- 'build' "$flutter_log" || fail 'build did not invoke Flutter'
grep -Fxq -- '--release' "$flutter_log" || fail 'release mode was not forwarded'
grep -Fxq -- 'lib/main.dart' "$flutter_log" || fail 'build omitted production entry point'

: >"$flutter_log"
install_target="$fixture_root/user/.local/opt/axiotask"
install_output=$(
  "${common_env[@]}" "$wrapper" install debug "$install_target" \
    --config "$config" 2>&1
)
[[ "$install_output" != *'client-id-output-canary'* ]] ||
  fail 'install disclosed client ID'
[[ "$install_output" != *'client-secret-output-canary'* ]] ||
  fail 'install disclosed client secret'
[[ -x "$install_target/axiotask" ]] || fail 'local bundle executable was not installed'
[[ -f "$install_target/.axiotask-local-install" ]] ||
  fail 'local install safety marker is missing'
grep -Fxq -- '--debug' "$flutter_log" || fail 'install did not build requested mode'

"${common_env[@]}" "$wrapper" remove "$install_target" >/dev/null
[[ ! -e "$install_target" ]] || fail 'marked local install was not removed'

unmarked_target="$fixture_root/user/.local/opt/unmarked"
mkdir -p "$unmarked_target"
assert_fails_with 'not an Axiotask local install' \
  "${common_env[@]}" "$wrapper" remove "$unmarked_target"
assert_fails_with 'refusing a system install target' \
  "${common_env[@]}" "$wrapper" install release /usr/local/axiotask \
  --config "$config"

: >"$flutter_log"
synthetic_output=$(
  "${common_env[@]}" "$wrapper" synthetic wrapper-test-instance 2>&1
)
[[ "$synthetic_output" != *'client-id-output-canary'* ]] ||
  fail 'synthetic run disclosed client ID'
[[ "$synthetic_output" != *'client-secret-output-canary'* ]] ||
  fail 'synthetic run disclosed client secret'
grep -Fxq -- 'lib/main_test.dart' "$flutter_log" ||
  fail 'synthetic run omitted the isolated entry point'
grep -Fxq -- '--dart-define=AXIOTASK_TEST_INSTANCE=wrapper-test-instance' \
  "$flutter_log" || fail 'synthetic run omitted its isolated instance'
if rg -q -- '--dart-define-from-file=' "$flutter_log"; then
  fail 'synthetic run received private configuration'
fi
assert_fails_with 'invalid synthetic instance' \
  "${common_env[@]}" "$wrapper" synthetic '../production'

printf 'Linux app wrapper tests passed\n'
