#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

before_manifest="$(mktemp)"
after_manifest="$(mktemp)"
trap 'rm -f "$before_manifest" "$after_manifest"' EXIT

generated_manifest() {
  while IFS= read -r -d '' generated_file; do
    relative_path="${generated_file#./}"
    checksum="$(sha256sum "$relative_path" | cut -d ' ' -f 1)"
    printf '%s  %s\n' "$checksum" "$relative_path"
  done < <(find ./lib -type f -name '*.g.dart' -print0 | sort -z)
}

generated_manifest >"$before_manifest"
dart run build_runner build
generated_manifest >"$after_manifest"

if ! cmp --silent "$before_manifest" "$after_manifest"; then
  printf 'generated-code check failed: regeneration changed generated Dart files\n' >&2
  diff --unified "$before_manifest" "$after_manifest" || true
  exit 1
fi

if [[ ! -s "$after_manifest" ]]; then
  printf 'generated-code check failed: no generated Dart files found\n' >&2
  exit 1
fi

printf 'generated-code check passed\n'
