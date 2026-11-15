#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Run inside a disposable CI desktop session; never use a developer's keyring.
[[ "${CI:-}" == true ]] || { printf 'This runner requires CI=true.\n' >&2; exit 2; }
[[ -n "${DISPLAY:-}" && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || {
  printf 'Run under xvfb-run and dbus-run-session.\n' >&2
  exit 2
}
mkdir -p test-results/linux
export XDG_RUNTIME_DIR
XDG_RUNTIME_DIR=$(mktemp -d)
chmod 700 "$XDG_RUNTIME_DIR"
trap 'rm -rf -- "$XDG_RUNTIME_DIR"' EXIT
export XDG_DATA_HOME="$XDG_RUNTIME_DIR/data"
export XDG_CONFIG_HOME="$XDG_RUNTIME_DIR/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
# A throwaway, empty-password keyring contains synthetic probe credentials only.
printf '\n' | gnome-keyring-daemon --unlock --components=secrets
export XDG_CURRENT_DESKTOP=GNOME
export LIBGL_ALWAYS_SOFTWARE=1

failed=0
for test_file in integration_test/*_test.dart; do
  case "$test_file" in
    integration_test/linux_auth_probe_test.dart|\
    integration_test/google_tasks_contract_probe_test.dart|\
    integration_test/google_tasks_mutation_probe_test.dart)
      printf 'Live Google test excluded: %s\n' "$test_file"
      continue
      ;;
  esac
  name=$(basename "$test_file" .dart)
  if ! timeout 15m flutter test --no-pub "$test_file" -d linux \
      --reporter expanded 2>&1 | tee "test-results/linux/$name.log"; then
    failed=1
  fi
done
exit "$failed"
