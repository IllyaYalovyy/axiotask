#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

flutter run -d linux --debug -t lib/main_backup_screenshot.dart

printf 'Synthetic account backup screenshots written beneath screenshots/actual/.\n'
