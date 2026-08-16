#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

flutter run -d linux --debug -t lib/main_local_data_recovery_screenshot.dart

printf 'Synthetic local data recovery screenshots written beneath screenshots/actual/.\n'
