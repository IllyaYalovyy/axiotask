#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/repository/scripts" "$fixture/repository/lib" "$fixture/bin"
cp "$repository_root/scripts/run_linux_capture.sh" "$fixture/repository/scripts/"
touch "$fixture/repository/lib/main_fixture_screenshot.dart"
case "$(uname -m)" in
  x86_64 | amd64) architecture=x64 ;;
  aarch64 | arm64) architecture=arm64 ;;
  *) exit 2 ;;
esac
mkdir -p "$fixture/repository/build/linux/$architecture/debug/bundle"
cat > "$fixture/bin/flutter" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_BUILD_LOG"
exit "${CAPTURE_BUILD_EXIT:-0}"
SH
cat > "$fixture/repository/build/linux/$architecture/debug/bundle/axiotask" <<'SH'
#!/usr/bin/env bash
echo captured > "$CAPTURE_RUN_LOG"
exit "${CAPTURE_RUN_EXIT:-0}"
SH
chmod +x "$fixture/bin/flutter" "$fixture/repository/build/linux/$architecture/debug/bundle/axiotask"
export PATH="$fixture/bin:$PATH"
export CAPTURE_BUILD_LOG="$fixture/build.log" CAPTURE_RUN_LOG="$fixture/run.log"
runner="$fixture/repository/scripts/run_linux_capture.sh"

# A capture that exits immediately must finish without a Flutter VM handshake.
timeout 5 bash "$runner" lib/main_fixture_screenshot.dart '--dart-define=CAPTURE=value with spaces'
test "$(cat "$CAPTURE_RUN_LOG")" = captured
printf '%s\n' build linux --debug -t lib/main_fixture_screenshot.dart '--dart-define=CAPTURE=value with spaces' > "$fixture/expected.log"
cmp "$CAPTURE_BUILD_LOG" "$fixture/expected.log"

rm "$CAPTURE_RUN_LOG"
status=0
CAPTURE_BUILD_EXIT=7 bash "$runner" lib/main_fixture_screenshot.dart || status=$?
test "$status" = 7
test ! -e "$CAPTURE_RUN_LOG"

status=0
CAPTURE_RUN_EXIT=9 bash "$runner" lib/main_fixture_screenshot.dart || status=$?
test "$status" = 9

rm "$CAPTURE_BUILD_LOG"
status=0
bash "$runner" lib/main.dart 2>/dev/null || status=$?
test "$status" = 2
test ! -e "$CAPTURE_BUILD_LOG"
echo 'Linux capture runner tests passed'
