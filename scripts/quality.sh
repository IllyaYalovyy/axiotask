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

printf 'Checking that no released feature or control was removed...\n'
python3 tool/feature_contract/check_ratchet.py

printf 'Running Flutter tests (including the must-have feature contract)...\n'
bash scripts/verified_flutter_test.sh

printf 'Testing Flutter run completion verification...\n'
bash test/flutter_test_report_test.sh

printf 'Testing the feature contract ratchet...\n'
bash test/feature_contract_ratchet_test.sh

printf 'Testing interactive capability gates...\n'
./test/preflight_capability_gate_test.sh

printf 'Testing first-class Linux profile commands...\n'
./test/linux_app_test.sh

printf 'Testing Linux screenshot process completion...\n'
bash test/linux_capture_runner_test.sh

printf 'Testing the privacy checker...\n'
./test/privacy_check_test.sh

printf 'Testing Android release qualification...\n'
bash test/android_qualification_test.sh

printf 'Scanning repository privacy...\n'
./scripts/privacy_check.sh

printf 'Local quality gate passed.\n'
