#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: %s <android-auth|linux-auth>\n' "${0##*/}" >&2
}

fail() {
  printf 'Capability gate failed: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is unavailable"
}

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
  fail 'run this command from the Axiotask Git worktree'

config_path=${AXIOTASK_STAGE7_GATE_CONFIG:-"$repository_root/.ktask/gates/stage7.env"}
declare -A private_config=()

load_private_config() {
  [[ -f "$config_path" ]] ||
    fail "private configuration is missing; create .ktask/gates/stage7.env"

  git -C "$repository_root" check-ignore -q -- "$config_path" ||
    fail 'private configuration is not ignored by Git'

  local mode
  mode=$(stat -c '%a' -- "$config_path")
  [[ "$mode" == '600' ]] ||
    fail 'private configuration permissions must be 600'

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || fail 'private configuration contains an invalid line'
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      AXIOTASK_AUTH_PROBE_ACCOUNT_SUBJECT | \
        AXIOTASK_ANDROID_AUTH_CLIENT_ID | \
        AXIOTASK_LINUX_AUTH_CLIENT_ID | \
        AXIOTASK_LINUX_AUTH_CLIENT_SECRET)
        [[ ! -v "private_config[$key]" ]] ||
          fail "private configuration repeats '$key'"
        private_config["$key"]=$value
        ;;
      *) fail "private configuration contains unsupported key '$key'" ;;
    esac
  done <"$config_path"
}

require_value() {
  [[ -n "${private_config[$1]:-}" ]] ||
    fail "private configuration is missing '$1'"
}

require_google_client_id() {
  require_value "$1"
  [[ "${private_config[$1]}" == *.apps.googleusercontent.com ]] ||
    fail "private configuration has an invalid '$1'"
}

check_android_auth() {
  require_command adb
  require_command flutter
  load_private_config
  require_value AXIOTASK_AUTH_PROBE_ACCOUNT_SUBJECT
  require_google_client_id AXIOTASK_ANDROID_AUTH_CLIENT_ID

  local -a physical_devices=()
  local serial state details
  while read -r serial state details; do
    [[ -n "${serial:-}" ]] || continue
    [[ "$state" == 'device' ]] || continue
    [[ "$serial" == emulator-* || "$details" == *'model:sdk_gphone'* ]] && continue
    physical_devices+=("$serial")
  done < <(adb devices -l | tail -n +2)

  [[ ${#physical_devices[@]} -eq 1 ]] ||
    fail 'exactly one unlocked and authorized physical Android device is required'

  local play_services_path
  play_services_path=$(adb -s "${physical_devices[0]}" \
    shell pm path com.google.android.gms 2>/dev/null) ||
    fail 'the physical device does not expose Google Play Services'
  [[ "$play_services_path" == package:* ]] ||
    fail 'the physical device does not expose Google Play Services'

  flutter devices --machine | grep -Fq "${physical_devices[0]}" ||
    fail 'Flutter does not recognize the authorized physical Android device'

  printf 'Capability gate passed: Android authorization prerequisites are available.\n'
}

check_linux_auth() {
  require_command gdbus
  require_command pkg-config
  require_command secret-tool
  require_command xdg-open
  pkg-config --exists libsecret-1 ||
    fail 'libsecret-devel is required; install it outside ktask before continuing'
  load_private_config
  require_value AXIOTASK_AUTH_PROBE_ACCOUNT_SUBJECT
  require_google_client_id AXIOTASK_LINUX_AUTH_CLIENT_ID
  require_value AXIOTASK_LINUX_AUTH_CLIENT_SECRET

  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] ||
    fail 'a user D-Bus session is required'
  gdbus call --session \
    --dest org.freedesktop.secrets \
    --object-path /org/freedesktop/secrets \
    --method org.freedesktop.DBus.Peer.Ping \
    >/dev/null 2>&1 || fail 'GNOME Secret Service is unavailable in this session'

  printf 'Capability gate passed: Linux authorization prerequisites are available.\n'
}

[[ $# -eq 1 ]] || {
  usage
  exit 2
}

case "$1" in
  android-auth) check_android_auth ;;
  linux-auth) check_linux_auth ;;
  *)
    usage
    exit 2
    ;;
esac
