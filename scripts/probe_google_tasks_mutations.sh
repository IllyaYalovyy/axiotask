#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'Google Tasks mutation probe failed: %s\n' "$1" >&2
  exit 1
}

[[ "${AXIOTASK_RUN_GOOGLE_TASKS_MUTATION_PROBE:-}" == '1' ]] ||
  fail 'set AXIOTASK_RUN_GOOGLE_TASKS_MUTATION_PROBE=1 to opt in'
[[ "$(uname -s)" == 'Linux' ]] || fail 'this probe supports Linux only'

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
  fail 'run this command from the Axiotask worktree'
gate_config=${AXIOTASK_STAGE7_GATE_CONFIG:-"$repository_root/.ktask/gates/stage7.env"}
subject_file="$repository_root/.ktask/gates/linux-auth-subject"
probe_config=$(mktemp /tmp/axiotask-google-mutation-probe-XXXXXX.json)
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
[[ -f "$subject_file" && -s "$subject_file" ]] ||
  fail 'the dedicated account subject must already be pinned'
[[ "$(stat -c '%a' -- "$subject_file")" == '600' ]] ||
  fail 'the pinned-subject file permissions must be 600'
git -C "$repository_root" check-ignore -q -- "$subject_file" ||
  fail 'the pinned-subject file is not ignored'

printf '{\n' >"$probe_config"
printf '  "AXIOTASK_LINUX_AUTH_CLIENT_ID": "%s",\n' "$client_id" >>"$probe_config"
printf '  "AXIOTASK_LINUX_AUTH_CLIENT_SECRET": "%s",\n' "$client_secret" >>"$probe_config"
printf '  "AXIOTASK_LINUX_AUTH_SUBJECT_FILE": "%s",\n' "$subject_file" >>"$probe_config"
printf '  "AXIOTASK_GOOGLE_TASKS_MUTATION_PROBE_INSTANCE": "automated-s07"\n' >>"$probe_config"
printf '}\n' >>"$probe_config"

cd "$repository_root"
flutter test integration_test/google_tasks_mutation_probe_test.dart -d linux \
  --dart-define-from-file="$probe_config"

[[ "$(stat -c '%a' -- "$subject_file")" == '600' ]] ||
  fail 'the pinned-subject file permissions changed'
printf 'Google Tasks mutation probe passed with cleanup and pinned-subject isolation.\n'
