#!/usr/bin/env bash
# Capture programs write their images and exit. Do not attach Flutter's VM
# service: a fast successful exit can race that handshake or leave it waiting.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
entry_point=${1:-}
[[ "$entry_point" == lib/main*_screenshot.dart && -f "$entry_point" ]] || {
  echo 'Usage: run_linux_capture.sh lib/main*_screenshot.dart [build options]' >&2
  exit 2
}
shift
case "$(uname -m)" in
  x86_64 | amd64) architecture=x64 ;;
  aarch64 | arm64) architecture=arm64 ;;
  *) echo 'Unsupported Linux architecture' >&2; exit 2 ;;
esac

flutter build linux --debug -t "$entry_point" "$@"
exec "$repository_root/build/linux/$architecture/debug/bundle/axiotask"
