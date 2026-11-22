#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

bash scripts/run_linux_capture.sh lib/main_onboarding_screenshot.dart

printf 'Synthetic onboarding screenshots written beneath screenshots/actual/.\n'
