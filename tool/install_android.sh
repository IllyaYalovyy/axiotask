#!/usr/bin/env bash
# Installs a published axiotask release on the phone connected over USB.
#
#   tool/install_android.sh            the newest release
#   tool/install_android.sh v1.6.0     that release
#
# The APK is downloaded from GitHub Releases, checked against the release's
# SHA256SUMS and installed over the existing application, which keeps its
# data. Nothing is uninstalled: if Android refuses the update, the script
# stops and says why.
set -euo pipefail

repository="IllyaYalovyy/axiotask"
package="com.axiotask.app"
tag="${1:-}"

for program in adb gh sha256sum; do
  command -v "$program" >/dev/null || { echo "$program is not installed" >&2; exit 1; }
done

mapfile -t phones < <(adb devices | awk '$2 == "device" && $1 !~ /^emulator-/ { print $1 }')
if [ "${#phones[@]}" -ne 1 ]; then
  echo "Expected exactly one phone connected with USB debugging allowed, found ${#phones[@]}." >&2
  adb devices >&2
  exit 1
fi
phone="${phones[0]}"

if [ -z "$tag" ]; then
  tag="$(gh release view --repo "$repository" --json tagName --jq .tagName)"
fi

folder="$(mktemp -d)"
trap 'rm -rf "$folder"' EXIT
gh release download "$tag" --repo "$repository" --dir "$folder" \
  --pattern '*.apk' --pattern 'SHA256SUMS'
apk="$(ls "$folder"/*.apk)"
(cd "$folder" && sha256sum --check --ignore-missing --quiet SHA256SUMS)

installed() {
  adb -s "$phone" shell dumpsys package "$package" |
    sed -n 's/.*versionName=//p' | head -1
}

before="$(installed)"
echo "Phone $phone has ${before:-no axiotask}; installing $tag."
adb -s "$phone" install -r "$apk"
echo "Installed: $(installed)"
