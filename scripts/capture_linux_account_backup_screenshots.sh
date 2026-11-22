#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

bash scripts/run_linux_capture.sh lib/main_backup_screenshot.dart

printf 'Synthetic account backup screenshots written beneath screenshots/actual/.\n'
