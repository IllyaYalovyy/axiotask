#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

printf 'Checking Dart formatting...\n'
dart format --output=none --set-exit-if-changed lib test integration_test

printf 'Checking generated Dart code...\n'
./scripts/check_generated.sh

printf 'Running static analysis...\n'
flutter analyze --fatal-infos --fatal-warnings

printf 'Running Flutter tests...\n'
flutter test

printf 'Testing interactive capability gates...\n'
./test/preflight_capability_gate_test.sh

printf 'Testing the privacy checker...\n'
./test/privacy_check_test.sh

printf 'Scanning repository privacy...\n'
./scripts/privacy_check.sh

printf 'Local quality gate passed.\n'
