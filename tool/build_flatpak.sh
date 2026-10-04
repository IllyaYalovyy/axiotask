#!/usr/bin/env bash
# Package an existing Flutter release bundle; fail if its ELF dependencies
# cannot be resolved in the pinned runtime. Install org.gnome.Sdk//49 and
# org.gnome.Platform//49 from Flathub before running this script.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP_ID=io.github.illyayalovyy.axiotask
RUNTIME_VERSION=49
BUNDLE=build/linux/x64/release/bundle
if [ "${1:-}" = --bundle ] && [ $# = 2 ]; then
  BUNDLE="$2"
elif [ $# != 0 ]; then
  echo 'usage: bash tool/build_flatpak.sh [--bundle DIR]' >&2
  exit 1
fi
[ -x "$BUNDLE/axiotask" ] || { echo "release bundle missing: $BUNDLE" >&2; exit 1; }
for tool in flatpak python3 desktop-file-validate appstreamcli; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
VERSION=$(sed -nE 's/^version: ([^+ ]+).*/\1/p' pubspec.yaml)
[ -n "$VERSION" ]
WORK=$(mktemp -d "$ROOT/build/flatpak.XXXXXX")
APP="$WORK/app"
flatpak build-init "$APP" "$APP_ID" org.gnome.Sdk org.gnome.Platform "$RUNTIME_VERSION"
install -d "$APP/files/lib/axiotask" "$APP/files/bin"
cp -a "$BUNDLE/." "$APP/files/lib/axiotask/"
python3 tool/normalize_runpath.py "$APP/files/lib/axiotask"
cat > "$APP/files/bin/axiotask" <<'LAUNCHER'
#!/bin/sh
exec /app/lib/axiotask/axiotask "$@"
LAUNCHER
chmod 755 "$APP/files/bin/axiotask"
install -Dm644 "linux/packaging/$APP_ID.desktop" "$APP/files/share/applications/$APP_ID.desktop"
sed -i "s/^Icon=axiotask$/Icon=$APP_ID/" "$APP/files/share/applications/$APP_ID.desktop"
for size in 16 24 32 48 64 128 256 512; do
  install -Dm644 "linux/packaging/icons/hicolor/${size}x${size}/apps/axiotask.png" \
    "$APP/files/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done
install -Dm644 linux/packaging/icons/hicolor/scalable/apps/axiotask.svg \
  "$APP/files/share/icons/hicolor/scalable/apps/$APP_ID.svg"
install -Dm644 "linux/packaging/$APP_ID.metainfo.xml" "$APP/files/share/metainfo/$APP_ID.metainfo.xml"
desktop-file-validate "$APP/files/share/applications/$APP_ID.desktop"
appstreamcli validate --no-net "$APP/files/share/metainfo/$APP_ID.metainfo.xml"
# Check the actual runtime, rather than the SDK or host. ldd also catches
# versioned symbol errors (e.g. GLIBC), not just absent library filenames.
flatpak build --runtime "$APP" sh -c '
  set -eu
  for elf in /app/lib/axiotask/axiotask /app/lib/axiotask/lib/*.so; do
    result=$(ldd "$elf" 2>&1) || { printf "%s\n" "$result"; exit 1; }
    if printf "%s\n" "$result" | grep -q "not found"; then
      printf "%s\n" "$result"; exit 1
    fi
  done
'
flatpak build-finish "$APP" --command=axiotask --share=network --share=ipc \
  --socket=wayland --socket=fallback-x11 --device=dri
flatpak build-export "$WORK/repo" "$APP" stable
mkdir -p dist
flatpak build-bundle "$WORK/repo" "dist/axiotask-$VERSION.flatpak" "$APP_ID" stable \
  --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo
printf 'Built dist/axiotask-%s.flatpak\n' "$VERSION"
