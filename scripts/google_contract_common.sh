#!/usr/bin/env bash

# Shared, source-only setup for the explicit Linux Google contract commands.
# It passes OAuth client configuration and the pinned-subject file to the
# shipped authorization adapter. Refresh/access tokens remain in the app's
# development secure-storage namespace and never enter a file or process arg.

google_contract_write_defines() {
  local repository_root=$1
  local output_path=$2
  local cleanup_prefix=${3:-}
  local gate_config=${AXIOTASK_STAGE7_GATE_CONFIG:-"$repository_root/.ktask/gates/stage7.env"}
  local subject_file="$repository_root/.ktask/gates/linux-auth-subject"

  [[ -f "$gate_config" ]] ||
    google_contract_fail 'private OAuth configuration is missing'
  git -C "$repository_root" check-ignore -q -- "$gate_config" ||
    google_contract_fail 'private OAuth configuration is not ignored'
  [[ "$(stat -c '%a' -- "$gate_config")" == '600' ]] ||
    google_contract_fail 'private OAuth configuration permissions must be 600'
  [[ -f "$subject_file" && -s "$subject_file" ]] ||
    google_contract_fail 'the dedicated account subject is not pinned'
  git -C "$repository_root" check-ignore -q -- "$subject_file" ||
    google_contract_fail 'the pinned subject is not ignored'
  [[ "$(stat -c '%a' -- "$subject_file")" == '600' ]] ||
    google_contract_fail 'the pinned-subject file permissions must be 600'

  local client_id=
  local client_secret=
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      AXIOTASK_LINUX_AUTH_CLIENT_ID=*) client_id=${line#*=} ;;
      AXIOTASK_LINUX_AUTH_CLIENT_SECRET=*) client_secret=${line#*=} ;;
    esac
  done <"$gate_config"
  [[ "$client_id" =~ ^[A-Za-z0-9._-]+\.apps\.googleusercontent\.com$ ]] ||
    google_contract_fail 'Linux OAuth client ID is invalid'
  [[ "$client_secret" =~ ^[A-Za-z0-9._-]+$ ]] ||
    google_contract_fail 'Linux OAuth client secret contains unsupported characters'
  [[ "$subject_file" =~ ^[A-Za-z0-9_./-]+$ ]] ||
    google_contract_fail 'the private subject path contains unsupported characters'

  {
    printf '{\n'
    printf '  "AXIOTASK_LINUX_AUTH_CLIENT_ID": "%s",\n' "$client_id"
    printf '  "AXIOTASK_LINUX_AUTH_CLIENT_SECRET": "%s",\n' "$client_secret"
    printf '  "AXIOTASK_LINUX_AUTH_SUBJECT_FILE": "%s",\n' "$subject_file"
    printf '  "AXIOTASK_GOOGLE_CONTRACT_INTERACTIVE": true'
    if [[ -n "$cleanup_prefix" ]]; then
      printf ',\n  "AXIOTASK_GOOGLE_CONTRACT_CLEANUP_PREFIX": "%s"' "$cleanup_prefix"
    fi
    printf '\n}\n'
  } >"$output_path"
}
