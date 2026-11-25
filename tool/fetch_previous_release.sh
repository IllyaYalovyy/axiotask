#!/usr/bin/env bash
# Download the newest published release's RPM and unpack it, so the candidate
# build can be started on top of what users have installed today.
#
# Usage: tool/fetch_previous_release.sh <directory>
# Prints the bundle directory (the one holding the `axiotask` executable).
set -euo pipefail

target=${1:?usage: tool/fetch_previous_release.sh <directory>}
for tool in gh rpm2cpio cpio; do
  command -v "$tool" >/dev/null ||
    { echo "error: $tool is required" >&2; exit 1; }
done

mkdir -p "$target/download" "$target/root"
gh release download --pattern '*.x86_64.rpm' --dir "$target/download" --clobber
rpm=$(find "$target/download" -name '*.x86_64.rpm' | sort | tail -1)
[ -n "$rpm" ] || { echo 'error: the newest release has no RPM' >&2; exit 1; }
(cd "$target/root" && rpm2cpio "$rpm" | cpio -idm --quiet)
bundle="$target/root/usr/lib/axiotask"
[ -x "$bundle/axiotask" ] ||
  { echo "error: $rpm holds no /usr/lib/axiotask/axiotask" >&2; exit 1; }
printf '%s\n' "$bundle"
