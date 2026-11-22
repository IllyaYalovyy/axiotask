#!/usr/bin/env bash
# Proves the feature-contract ratchet fails for exactly the changes it exists
# to stop: a released must-have feature or user-facing control that is gone
# without a recorded approval. Runs against a throwaway repository.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$work"
git init --quiet
git config user.email ratchet@example.invalid
git config user.name ratchet
git config commit.gpgsign false
git config tag.gpgsign false
mkdir -p tool/feature_contract test/contract/ui_surface
cp "$repository_root/tool/feature_contract/check_ratchet.py" tool/feature_contract/

registry() {
  printf '{"schema":1,"features":[%s]}\n' "$1" > test/contract/must_have_features.json
}
ledger() {
  printf '{"schema":1,"removed_features":[%s],"removed_controls":[%s]}\n' "$1" "$2" \
    > test/contract/approved_removals.json
}
feature() { printf '{"id":"%s","title":"t","targets":[%s]}' "$1" "$2"; }

check() { python3 tool/feature_contract/check_ratchet.py >"$work/out" 2>&1; }
expect_pass() {
  check || { echo "FAIL: expected pass: $1"; cat "$work/out"; exit 1; }
}
expect_fail() {
  if check; then echo "FAIL: expected failure: $1"; cat "$work/out"; exit 1; fi
  grep -q -- "$2" "$work/out" || {
    echo "FAIL: $1: output does not mention '$2'"; cat "$work/out"; exit 1;
  }
}

# No release tag at all must not silently disable the ratchet.
registry "$(feature MH-A '"android","linux"')"
ledger '' ''
printf 'home | button: Keep\nhome | button: Old name\n' > test/contract/ui_surface/android.txt
git add -A && git commit --quiet -m baseline
expect_fail 'no release tag' 'no release tag'
FEATURE_CONTRACT_BASELINE=none expect_pass 'explicit opt-out'

# A baseline older than the contract has nothing to compare.
git rm --quiet -r --cached test/contract && git commit --quiet -m 'pre-contract'
git tag v0.9.0
git add -A && git commit --quiet -m 'contract introduced'
expect_pass 'baseline predates the contract'

git tag v1.0.0
expect_pass 'unchanged since the release'

# Adding a feature or a control is always allowed.
registry "$(feature MH-A '"android","linux"'),$(feature MH-B '"android"')"
printf 'home | button: Keep\nhome | button: Old name\nhome | button: New\n' \
  > test/contract/ui_surface/android.txt
expect_pass 'additions'

# Removing a released feature fails...
registry "$(feature MH-B '"android"')"
expect_fail 'feature removed' 'MH-A (android)'
# ...as does dropping one of its platforms...
registry "$(feature MH-A '"linux"'),$(feature MH-B '"android"')"
expect_fail 'target removed' 'MH-A (android)'
# ...and an approval without the owner's reference does not count.
ledger '{"id":"MH-A","targets":["android"],"owner_approval":""}' ''
expect_fail 'empty approval' 'no owner_approval'
ledger '{"id":"MH-A","targets":["android"],"owner_approval":"ktask task 99"}' ''
expect_pass 'owner-approved feature removal'

# Removing a released control fails...
registry "$(feature MH-A '"android","linux"')"
ledger '' ''
printf 'home | button: Keep\nhome | button: Renamed\n' > test/contract/ui_surface/android.txt
expect_fail 'control removed' 'home | button: Old name'
# ...a rename must point at a control that really exists now...
ledger '' '{"target":"android","control":"home | button: Old name","replaced_by":"home | button: Missing"}'
expect_fail 'rename to a missing control' 'home | button: Old name'
ledger '' '{"target":"android","control":"home | button: Old name","replaced_by":"home | button: Renamed"}'
expect_pass 'recorded rename'
# ...and an outright removal needs the owner.
printf 'home | button: Keep\n' > test/contract/ui_surface/android.txt
expect_fail 'replacement removed too' 'home | button: Old name'
ledger '' '{"target":"android","control":"home | button: Old name","owner_approval":"ktask task 100"}'
expect_pass 'owner-approved control removal'

# Deleting the whole inventory is a removal of every control in it.
ledger '' ''
rm test/contract/ui_surface/android.txt
expect_fail 'inventory deleted' 'home | button: Keep'

echo 'Feature contract ratchet tests passed.'
