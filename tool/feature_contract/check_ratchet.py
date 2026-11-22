#!/usr/bin/env python3
"""Fails when a must-have feature or user-facing control present in the last
release is gone without a recorded approval.

The feature contract tests (test/contract/) compare the application with the
COMMITTED registry and inventory. That alone cannot stop a change that deletes
a registry entry, a contract, or inventory lines together with the feature.
This ratchet compares the working tree with the last released tree instead,
which no change under review can edit:

  * every feature ID (and each of its targets) in the released
    must_have_features.json must still be registered, or be listed under
    "removed_features" in approved_removals.json with a non-empty
    "owner_approval";
  * every line of the released control inventories must still be present, or
    be listed under "removed_controls" with either "replaced_by" naming a
    line that exists now (a rename or move) or a non-empty "owner_approval"
    (a true removal).

The baseline is the newest reachable release tag (v*), or the ref named by
FEATURE_CONTRACT_BASELINE. A baseline older than the contract has nothing to
compare and passes. A repository with no release tag fails, so a shallow CI
checkout cannot turn the ratchet off silently; fetch tags or set
FEATURE_CONTRACT_BASELINE=none deliberately.

Pure reads of git objects and tracked files: no build, clock or network.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = "test/contract/must_have_features.json"
LEDGER = "test/contract/approved_removals.json"
SURFACE_DIR = "test/contract/ui_surface"


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args], cwd=ROOT, text=True, capture_output=True, check=False
    )


def baseline_refs() -> list[str]:
    """The refs to compare with; empty when comparison is switched off."""
    configured = os.environ.get("FEATURE_CONTRACT_BASELINE", "").strip()
    if configured.lower() == "none":
        return []
    if configured:
        if git("rev-parse", "--verify", "--quiet", f"{configured}^{{commit}}").returncode:
            sys.exit(f"feature contract: baseline ref {configured!r} does not exist")
        return [configured]
    # The newest release tag at or before HEAD, and the one before HEAD, so a
    # freshly tagged release commit is still compared with its predecessor.
    refs: list[str] = []
    for start in ("HEAD", "HEAD^"):
        described = git("describe", "--tags", "--abbrev=0", "--match", "v*", start)
        tag = described.stdout.strip()
        if described.returncode == 0 and tag and tag not in refs:
            refs.append(tag)
    if not refs:
        sys.exit(
            "feature contract: no release tag (v*) is reachable, so removed "
            "features cannot be detected. Fetch tags (git fetch --tags, or "
            "fetch-depth: 0 in CI), or set FEATURE_CONTRACT_BASELINE=none to "
            "skip deliberately."
        )
    return refs


def show(ref: str, path: str) -> str | None:
    result = git("show", f"{ref}:{path}")
    return result.stdout if result.returncode == 0 else None


def surface_lines(text: str) -> set[str]:
    return {
        line for line in text.splitlines() if line.strip() and not line.startswith("#")
    }


def feature_targets(registry: dict) -> dict[str, set[str]]:
    return {
        feature["id"]: set(feature.get("targets", []))
        for feature in registry.get("features", [])
    }


def compare(ref: str, ledger: dict) -> list[str] | None:
    """Problems against [ref], or None when it predates the contract."""
    released_registry = show(ref, REGISTRY)
    if released_registry is None:
        return None
    problems: list[str] = []
    approved_features = {
        (entry["id"], target)
        for entry in ledger.get("removed_features", [])
        if str(entry.get("owner_approval", "")).strip()
        for target in entry.get("targets", ["android", "linux"])
    }
    current = feature_targets(json.loads((ROOT / REGISTRY).read_text()))
    released = feature_targets(json.loads(released_registry))
    for feature_id, targets in sorted(released.items()):
        for target in sorted(targets):
            if target in current.get(feature_id, set()):
                continue
            if (feature_id, target) in approved_features:
                continue
            problems.append(
                f"must-have feature {feature_id} ({target}) was released in {ref} "
                "and is no longer registered"
            )

    listing = git("ls-tree", "--name-only", f"{ref}:{SURFACE_DIR}")
    for name in sorted(listing.stdout.split()) if listing.returncode == 0 else []:
        target = Path(name).stem
        was = surface_lines(show(ref, f"{SURFACE_DIR}/{name}") or "")
        path = ROOT / SURFACE_DIR / name
        now = surface_lines(path.read_text()) if path.exists() else set()
        approved = set()
        for entry in ledger.get("removed_controls", []):
            if entry.get("target") != target:
                continue
            replaced_by = entry.get("replaced_by")
            if (replaced_by and replaced_by in now) or str(
                entry.get("owner_approval", "")
            ).strip():
                approved.add(entry.get("control"))
        for line in sorted(was - now - approved):
            problems.append(
                f"control released in {ref} is gone from the {target} "
                f"application: {line}"
            )
    return problems


def main() -> int:
    refs = baseline_refs()
    if not refs:
        print("feature contract: ratchet skipped (FEATURE_CONTRACT_BASELINE=none)")
        return 0

    ledger = json.loads((ROOT / LEDGER).read_text())
    problems = [
        f"{LEDGER}: removed feature {entry.get('id')!r} has no owner_approval"
        for entry in ledger.get("removed_features", [])
        if not str(entry.get("owner_approval", "")).strip()
    ]
    compared = []
    for ref in refs:
        found = compare(ref, ledger)
        if found is None:
            print(f"feature contract: {ref} predates the contract; nothing to compare")
            continue
        compared.append(ref)
        problems.extend(found)

    if problems:
        print("feature contract ratchet FAILED:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print(
            "\nRestore what was removed. A rename or move is recorded in "
            f"{LEDGER} with 'replaced_by'; removing a feature or control outright "
            "needs the owner's explicit approval recorded as 'owner_approval'.",
            file=sys.stderr,
        )
        return 1
    if compared:
        print(f"feature contract: nothing released in {', '.join(compared)} was removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
