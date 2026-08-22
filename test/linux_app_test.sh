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
}

[[ -x "$source_wrapper" ]] || fail 'wrapper is missing or not executable'
install -Dm755 -- "$source_wrapper" "$wrapper"
git -C "$fixture_root/repository" init -q
mkdir -p "$fixture_root/bin" "$fixture_root/user"
flutter_log="$fixture_root/flutter-arguments.log"
case "$(uname -m)" in
  x86_64 | amd64) bundle_root="$fixture_root/repository/build/linux/x64" ;;
  aarch64 | arm64) bundle_root="$fixture_root/repository/build/linux/arm64" ;;
  *) fail 'unsupported test architecture' ;;
esac

# The fake records argument boundaries and creates a minimal bundle for install.
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
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "${1:-}" == passwd ]] || exit 1' \
  'printf '\''fixture:x:%s:%s::%s:/bin/bash\n'\'' "${2:-1000}" "${2:-1000}" "$AXIOTASK_FAKE_USER_HOME"' \
  >"$fixture_root/bin/getent"
chmod +x "$fixture_root/bin/flutter" "$fixture_root/bin/getent"

common_env=(
  env
  "PATH=$fixture_root/bin:$PATH"
  "AXIOTASK_FAKE_FLUTTER_LOG=$flutter_log"
  "AXIOTASK_FAKE_BUNDLE_ROOT=$bundle_root"
  "AXIOTASK_FAKE_USER_HOME=$fixture_root/user"
)

assert_fails_with 'Usage:' "$wrapper"
assert_fails_with 'Usage:' "${common_env[@]}" "$wrapper" run extra

"${common_env[@]}" "$wrapper" run >/dev/null
grep -Fxq -- 'run' "$flutter_log" || fail 'run did not invoke Flutter'
grep -Fxq -- '-d' "$flutter_log" || fail 'run omitted the Linux device'
grep -Fxq -- 'linux' "$flutter_log" || fail 'run omitted the Linux target'
grep -Fxq -- 'lib/main.dart' "$flutter_log" ||
  fail 'run omitted the production entry point'

: >"$flutter_log"
"${common_env[@]}" "$wrapper" dev >/dev/null
grep -Fxq -- 'lib/main_development.dart' "$flutter_log" ||
  fail 'dev omitted the isolated development entry point'

: >"$flutter_log"
"${common_env[@]}" "$wrapper" build release >/dev/null
grep -Fxq -- 'build' "$flutter_log" || fail 'build did not invoke Flutter'
grep -Fxq -- '--release' "$flutter_log" || fail 'release mode was not forwarded'
grep -Fxq -- 'lib/main.dart' "$flutter_log" ||
  fail 'build omitted the production entry point'

: >"$flutter_log"
"${common_env[@]}" "$wrapper" build-dev debug >/dev/null
grep -Fxq -- '--debug' "$flutter_log" || fail 'dev build mode was not forwarded'
grep -Fxq -- 'lib/main_development.dart' "$flutter_log" ||
  fail 'dev build omitted the development entry point'

if rg -q -- '--dart-define-from-file=|\.ktask/' "$flutter_log"; then
  fail 'application command depends on task-runner configuration'
fi

: >"$flutter_log"
install_target="$fixture_root/user/.local/opt/axiotask"
"${common_env[@]}" "$wrapper" install debug "$install_target" >/dev/null
[[ -x "$install_target/axiotask" ]] ||
  fail 'local bundle executable was not installed'
[[ -f "$install_target/.axiotask-local-install" ]] ||
  fail 'local install safety marker is missing'

"${common_env[@]}" "$wrapper" remove "$install_target" >/dev/null
[[ ! -e "$install_target" ]] || fail 'marked local install was not removed'

unmarked_target="$fixture_root/user/.local/opt/unmarked"
mkdir -p "$unmarked_target"
assert_fails_with 'not an Axiotask local install' \
  "${common_env[@]}" "$wrapper" remove "$unmarked_target"
assert_fails_with 'refusing a system install target' \
  "${common_env[@]}" "$wrapper" install release /usr/local/axiotask

: >"$flutter_log"
"${common_env[@]}" "$wrapper" synthetic wrapper-test-instance >/dev/null
grep -Fxq -- 'lib/main_test.dart' "$flutter_log" ||
  fail 'synthetic run omitted the isolated entry point'
grep -Fxq -- '--dart-define=AXIOTASK_TEST_INSTANCE=wrapper-test-instance' \
  "$flutter_log" || fail 'synthetic run omitted its isolated instance'
assert_fails_with 'invalid synthetic instance' \
  "${common_env[@]}" "$wrapper" synthetic '../production'

printf 'Linux app wrapper tests passed\n'
