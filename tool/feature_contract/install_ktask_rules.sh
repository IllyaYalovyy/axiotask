#!/usr/bin/env bash
# Installs the feature-contract rules into this project's ktask `code`
# category, so every executing, reviewing, validating and repairing agent is
# told that registered features and inventoried controls may not be lost.
#
# The rules live in tool/feature_contract/ktask/ and are added to the `code`
# templates in effect. Rerunning replaces an earlier installation with the
# current files. Only tasks defined afterwards use the change.
#
# Usage: tool/feature_contract/install_ktask_rules.sh [actor-name]
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"
actor="${1:-}"
rules_directory="tool/feature_contract/ktask"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$rules_directory" "$work" <<'PYTHON'
import json
import subprocess
import sys
from pathlib import Path

rules_directory, work = Path(sys.argv[1]), Path(sys.argv[2])
shown = subprocess.run(
    ["ktask", "--json", "category", "show", "code"],
    text=True, capture_output=True, check=True,
)
templates = json.loads(shown.stdout)["data"]["category"]["templates"]
rules = (rules_directory / "rules.md").read_text().strip()
review = (rules_directory / "review_rules.md").read_text().strip()
markers = ("Feature contract (this project", "Feature contract review (")
for role in ("execution", "review", "validation", "remediation"):
    # Start from the effective template without any earlier installation of
    # these rules, so user-scope customisation is kept and reruns are stable.
    lines = [
        line for line in templates[role].rstrip("\n").split("\n")
        if not line.startswith(markers)
    ]
    additions = [rules] + ([review] if role in ("review", "validation") else [])
    # Rules go before the trailing Task/Goal/Criteria/Context block.
    index = next(
        (i for i, line in enumerate(lines) if line.startswith("Task: {{title}}")),
        len(lines),
    )
    merged = lines[:index] + additions + lines[index:]
    (work / f"{role}.txt").write_text("\n".join(merged) + "\n")
PYTHON

arguments=(category save code --scope project --checks
  --description 'Source code: project checks gate it; registered features and controls may not be lost.'
  --execution "@$work/execution.txt"
  --review "@$work/review.txt"
  --validation "@$work/validation.txt"
  --remediation "@$work/remediation.txt")
if [ -n "$actor" ]; then
  arguments+=(--actor-kind ai --actor "$actor")
fi
ktask "${arguments[@]}" >/dev/null
ktask category show code | head -3
