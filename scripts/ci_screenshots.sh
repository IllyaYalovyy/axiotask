#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-results/screenshots
failed=0
for capture in scripts/capture_linux_*_screenshots.sh; do
  name=$(basename "$capture" .sh)
  if ! timeout 60m bash "$capture" 2>&1 | tee "test-results/screenshots/$name.log"; then
    failed=1
  fi
done
exit "$failed"
