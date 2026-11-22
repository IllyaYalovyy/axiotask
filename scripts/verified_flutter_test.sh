#!/usr/bin/env bash
# Flutter can exit zero after SIGINT despite unfinished tests. Require its
# independent JSON report to confirm that every started test finished.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p test-results/verified-tests
report=$(mktemp test-results/verified-tests/flutter.XXXXXX.jsonl)
flutter test --file-reporter "json:$report" "$@"
python3 scripts/check_flutter_test_report.py "$report"
