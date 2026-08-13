#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
privacy_check="$repository_root/scripts/privacy_check.sh"

if [[ ! -x "$privacy_check" ]]; then
  printf 'privacy checker is missing or is not executable: %s\n' "$privacy_check" >&2
  exit 1
fi

fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT

git -C "$fixture_root" init -q
git -C "$fixture_root" config user.name 'Synthetic Fixture'
git -C "$fixture_root" config user.email 'fixture@example.invalid'

assert_accepted() {
  if ! "$privacy_check" "$fixture_root" >/dev/null; then
    printf 'privacy checker rejected a clean synthetic fixture\n' >&2
    exit 1
  fi
}

assert_rejected() {
  local expected_reason="$1"
  local output

  if output="$($privacy_check "$fixture_root" 2>&1)"; then
    printf 'privacy checker accepted forbidden fixture: %s\n' "$expected_reason" >&2
    exit 1
  fi

  if [[ "$output" != *"$expected_reason"* ]]; then
    printf 'privacy checker did not identify %s\n%s\n' "$expected_reason" "$output" >&2
    exit 1
  fi
}

printf 'synthetic task fixture\n' >"$fixture_root/fixture.txt"
git -C "$fixture_root" add fixture.txt
assert_accepted

printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----' >"$fixture_root/fixture.txt"
assert_rejected 'credential-like content'

printf '/%s/%s/private.txt\n' home fixture-user >"$fixture_root/fixture.txt"
assert_rejected 'absolute local path'

attribution_start='Co-authored-'
attribution_end='by: Automation AI <fixture@example.invalid>'
printf '%s%s\n' "$attribution_start" "$attribution_end" >"$fixture_root/fixture.txt"
assert_rejected 'AI attribution'

printf 'synthetic task fixture\n' >"$fixture_root/fixture.txt"
mkdir -p "$fixture_root/.ktask"
printf 'local orchestration state\n' >"$fixture_root/.ktask/prompt.md"
assert_rejected 'forbidden repository artifact'

printf 'privacy checker fixture tests passed\n'
