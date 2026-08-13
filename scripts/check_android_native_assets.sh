#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apk_path="${1:-$repository_root/build/app/outputs/flutter-apk/app-debug.apk}"

if [[ ! -f "$apk_path" ]]; then
  printf 'Android APK not found: %s\n' "$apk_path" >&2
  printf 'Build it first with: flutter build apk --debug\n' >&2
  exit 1
fi

archive_entries="$(unzip -Z1 "$apk_path")"
for abi in arm64-v8a armeabi-v7a x86_64; do
  expected="lib/$abi/libsqlite3.so"
  if ! grep -Fxq "$expected" <<<"$archive_entries"; then
    printf 'Missing SQLite native asset in APK: %s\n' "$expected" >&2
    exit 1
  fi
done

printf 'Android APK contains SQLite native assets for arm64-v8a, armeabi-v7a, and x86_64.\n'
