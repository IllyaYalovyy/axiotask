#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'Linux authorization probe failed: %s\n' "$1" >&2
  exit 1
}

[[ "${AXIOTASK_RUN_LINUX_AUTH_PROBE:-}" == '1' ]] ||
  fail 'set AXIOTASK_RUN_LINUX_AUTH_PROBE=1 to opt in'
[[ "$(uname -s)" == 'Linux' ]] || fail 'this probe supports Linux only'

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
  fail 'run this command from the Axiotask worktree'
gate_config=${AXIOTASK_STAGE7_GATE_CONFIG:-"$repository_root/.ktask/gates/stage7.env"}
subject_file="$repository_root/.ktask/gates/linux-auth-subject"
probe_config=$(mktemp /tmp/axiotask-linux-auth-probe-XXXXXX.json)
trap 'rm -f -- "$probe_config"' EXIT
chmod 600 "$probe_config"

"$repository_root/scripts/preflight_capability_gate.sh" linux-auth
[[ -f "$gate_config" ]] || fail 'private OAuth configuration is missing'
git -C "$repository_root" check-ignore -q -- "$gate_config" ||
  fail 'private OAuth configuration is not ignored'

client_id=
client_secret=
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    AXIOTASK_LINUX_AUTH_CLIENT_ID=*) client_id=${line#*=} ;;
    AXIOTASK_LINUX_AUTH_CLIENT_SECRET=*) client_secret=${line#*=} ;;
  esac
done <"$gate_config"
[[ -n "$client_id" && -n "$client_secret" ]] ||
  fail 'Linux OAuth configuration is incomplete'
[[ "$client_id" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail 'Linux OAuth client ID contains unsupported characters'
[[ "$client_secret" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail 'Linux OAuth client secret contains unsupported characters'
[[ "$subject_file" =~ ^[A-Za-z0-9_./-]+$ ]] ||
  fail 'the private subject path contains unsupported characters'

mkdir -p "${subject_file%/*}"
if [[ ! -e "$subject_file" ]]; then
  install -m 600 /dev/null "$subject_file"
fi
[[ "$(stat -c '%a' -- "$subject_file")" == '600' ]] ||
  fail 'the pinned-subject file permissions must be 600'
git -C "$repository_root" check-ignore -q -- "$subject_file" ||
  fail 'the pinned-subject file is not ignored'

printf '{\n' >"$probe_config"
printf '  "AXIOTASK_LINUX_AUTH_CLIENT_ID": "%s",\n' "$client_id" >>"$probe_config"
printf '  "AXIOTASK_LINUX_AUTH_CLIENT_SECRET": "%s",\n' "$client_secret" >>"$probe_config"
printf '  "AXIOTASK_LINUX_AUTH_SUBJECT_FILE": "%s",\n' "$subject_file" >>"$probe_config"
printf '  "AXIOTASK_LINUX_AUTH_PROBE_INSTANCE": "automated-s05"\n' >>"$probe_config"
printf '}\n' >>"$probe_config"

cd "$repository_root"
flutter test integration_test/linux_auth_probe_test.dart -d linux \
  --dart-define-from-file="$probe_config"

[[ "$(stat -c '%a' -- "$subject_file")" == '600' ]] ||
  fail 'the pinned-subject file permissions changed'
[[ -s "$subject_file" ]] || fail 'the authenticated subject was not pinned'
printf 'Linux authorization probe passed with isolated credentials and pinned subject.\n'
