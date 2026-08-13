#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'Linux secure-storage probe failed: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is unavailable"
}

[[ "${AXIOTASK_RUN_LINUX_SECURE_STORAGE_PROBE:-}" == '1' ]] ||
  fail 'set AXIOTASK_RUN_LINUX_SECURE_STORAGE_PROBE=1 to opt in'
[[ "$(uname -s)" == 'Linux' ]] || fail 'this probe supports Linux only'
[[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] ||
  fail 'run from a GNOME desktop session'
[[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] ||
  fail 'a user D-Bus session is required'

require_command flutter
require_command gdbus
require_command pkg-config
pkg-config --exists libsecret-1 ||
  fail 'libsecret-devel is required to build the Linux plugin'
gdbus call --session \
  --dest org.freedesktop.secrets \
  --object-path /org/freedesktop/secrets \
  --method org.freedesktop.DBus.Peer.Ping \
  >/dev/null 2>&1 || fail 'GNOME Secret Service is unavailable in this session'

flutter test integration_test/linux_secure_storage_probe_test.dart -d linux
printf 'Linux secure-storage probe passed; its dedicated namespace was removed.\n'
