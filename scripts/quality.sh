#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

printf 'Checking Dart formatting...\n'
dart format --output=none --set-exit-if-changed lib test

printf 'Running static analysis...\n'
flutter analyze --fatal-infos --fatal-warnings

printf 'Running Flutter tests...\n'
flutter test

printf 'Testing the privacy checker...\n'
./test/privacy_check_test.sh

printf 'Scanning repository privacy...\n'
./scripts/privacy_check.sh

printf 'Local quality gate passed.\n'
