#!/usr/bin/env bash
set -euo pipefail

scan_root="${1:-$(git rev-parse --show-toplevel)}"

if ! repository_root="$(git -C "$scan_root" rev-parse --show-toplevel 2>/dev/null)"; then
  printf 'privacy check failed: target is not a Git repository\n' >&2
  exit 1
fi

if [[ "$(cd "$scan_root" && pwd -P)" != "$(cd "$repository_root" && pwd -P)" ]]; then
  printf 'privacy check failed: target must be the repository root\n' >&2
  exit 1
fi

mapfile -d '' candidate_files < <(
  git -C "$repository_root" ls-files --cached --others --exclude-standard -z
)

for relative_path in "${candidate_files[@]}"; do
  case "$relative_path" in
    .ktask|.ktask/*|.claude|.claude/*|.codex|.codex/*|AGENTS.md|CLAUDE.md|CODEX.md|\
    test-results/*|screenshots/actual/*|integration_test/output/*|*.log|*.sqlite|*.sqlite3|*.db|\
    credentials*.json|tokens*.json|android/app/google-services.json|android/key.properties|\
    android/local.properties|*.jks|*.keystore)
      printf 'privacy check failed: forbidden repository artifact\n' >&2
      exit 1
      ;;
  esac
done

existing_files=()
for relative_path in "${candidate_files[@]}"; do
  if [[ -f "$repository_root/$relative_path" ]]; then
    existing_files+=("$repository_root/$relative_path")
  fi
done

scan_for() {
  local reason="$1"
  local pattern="$2"

  if ((${#existing_files[@]} == 0)); then
    return
  fi

  if rg --quiet --no-messages --pcre2 -- "$pattern" "${existing_files[@]}"; then
    printf 'privacy check failed: %s\n' "$reason" >&2
    exit 1
  fi
}

private_marker='PRIVATE'
credential_pattern="-----BEGIN (?:RSA |EC |OPENSSH )?${private_marker} KEY-----"
credential_pattern+='|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]{20,}'
credential_pattern+='|GOCSPX-[0-9A-Za-z_-]{20,}|Bearer[[:space:]]+[0-9A-Za-z._~+/-]{16,}'
scan_for 'credential-like content' "$credential_pattern"

scan_for 'absolute local path' '/(?:home|Users)/[A-Za-z0-9._-]+/'

attribution_prefix='Co-authored-'
attribution_pattern="${attribution_prefix}by:.*(?:AI|ChatGPT|Claude|Codex|Copilot)"
scan_for 'AI attribution' "$attribution_pattern"

printf 'privacy check passed (%d files scanned)\n' "${#existing_files[@]}"
