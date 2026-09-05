#!/usr/bin/env bash
# Mutation testing for the axiotask core — "do the tests notice when the code
# is wrong?" (#280).
#
# Coverage says a line RAN. Mutation testing says an assertion DEPENDED on it:
# the tool rewrites one operator/constant/statement at a time and re-runs the
# tests. A mutant the suite still passes is a SURVIVOR — a place where the code
# could be wrong and nothing would go red. The 2026-09-02/03 pilot ran this by
# hand over model/sync/store (949 mutants, 55 survivors) and produced #277-#279;
# this script is that run, committed, so a survivor count is reproducible and
# the follow-up issues can show a before/after.
#
# Usage:
#   tool/mutation.sh                          # the whole core (hours — detach it)
#   tool/mutation.sh lib/src/model/dates.dart # one file (~6 min)
#   tool/mutation.sh --plan lib/src/sync/engine.dart   # show the scope, run nothing
#   tool/mutation.sh --dry lib/src/store/store.dart    # count mutants, run no tests
#
# Options:
#   -o, --output DIR    where reports land (default: mutation/, gitignored)
#   -w, --work DIR      throwaway copy location (default under XDG_CACHE_HOME)
#   -t, --timeout SEC   per-mutant test timeout (default 300)
#   -n, --plan          print the derived test scope per file and exit
#   -d, --dry           mutation_test dry run: count mutants, run no tests
#       --no-ratchet    skip the baseline check (still writes the report)
#   -h, --help          this text
#
# It is NOT part of `.ktask/verify.sh`: a full core run is over an hour. Run it
# at review time, or when an issue asks for a before/after. See TESTING.md,
# "Mutation testing".
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

MUTATION_TEST_VERSION=1.8.0
OUT=mutation
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/axiotask-mutation/tree"
TIMEOUT=300
MODE=run
RATCHET=1
BASELINE=tool/mutation_baseline.tsv

# The core: hand-written logic where a surviving mutant means a missing
# assertion. Generated code (*.g.dart) and the model barrel carry no behaviour.
default_targets() {
  local f
  for f in lib/src/model/*.dart lib/src/sync/*.dart \
           lib/src/store/store.dart lib/src/store/backup.dart; do
    case "$f" in
      *.g.dart | lib/src/model/model.dart) continue ;;
    esac
    printf '%s\n' "$f"
  done
}

die() { printf 'mutation.sh: %s\n' "$1" >&2; exit 2; }

targets=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o | --output) OUT=${2:?--output needs a directory}; shift 2 ;;
    -w | --work) WORK=${2:?--work needs a directory}; shift 2 ;;
    -t | --timeout) TIMEOUT=${2:?--timeout needs seconds}; shift 2 ;;
    -n | --plan) MODE=plan; shift ;;
    -d | --dry) MODE=dry; shift ;;
    --no-ratchet) RATCHET=0; shift ;;
    -h | --help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*) die "unknown option $1 (try --help)" ;;
    *) targets+=("$1"); shift ;;
  esac
done
# A dry run reports every mutant as undetected (it runs no tests), so checking
# that against the ratchet would be theatre.
[ "$MODE" = dry ] && RATCHET=0
if [ ${#targets[@]} -eq 0 ]; then
  mapfile -t targets < <(default_targets)
fi
for src in "${targets[@]}"; do
  [ -f "$src" ] || die "not a file: $src"
  case "$src" in lib/*) ;; *) die "not a lib/ source file: $src" ;; esac
done

# ── Test scope for one source file ─────────────────────────────────────────
# The point of a per-file scope is speed: running the whole suite per mutant
# would make a single file an overnight job. The scope must still contain every
# test that could kill a mutant in that file, or a survivor is an artefact of
# the scope rather than a gap in the suite.
#
#   engine.dart / reconcile.dart / store.dart have no same-name test — their
#   behaviour is spread over a whole directory of them, so the directory IS the
#   scope. (Consequence, seen in the pilot: engine behaviour covered only by
#   test/app/* shows up as a survivor here. That is a real scoping signal —
#   the sync engine's own suite never exercised it — not noise.)
#
# Everything else: the same-name test first, then every test file that imports
# the source directly, capped at 8 so one widely-imported file cannot drag the
# whole suite into every mutant run.
scope_for() {
  local src=$1 base rel same f n=0
  local -a files=()
  case "$src" in
    lib/src/sync/engine.dart | lib/src/sync/reconcile.dart) printf 'test/sync\n'; return 0 ;;
    lib/src/store/store.dart) printf 'test/store\n'; return 0 ;;
  esac
  base=$(basename "$src" .dart)
  rel="package:axiotask/${src#lib/}"
  same=$(find test -type f -name "${base}_test.dart" | sort | head -1)
  [ -n "$same" ] && files+=("$same")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$same" ] && continue
    [ $n -ge 8 ] && break
    n=$((n + 1))
    files+=("$f")
  done < <(grep -rlF "$rel" test --include='*_test.dart' 2>/dev/null | sort)
  printf '%s\n' "${files[*]}"
}

# Everything the mutation run may not disturb. mutation_test edits files IN
# PLACE and restores them afterwards; a crash mid-mutant leaves a mutated
# source behind. That is exactly why the run happens on a copy — and why this
# hash is compared again at the end (acceptance criterion of #280).
tree_fingerprint() {
  find lib test tool integration_test -type f -print0 2>/dev/null \
    | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

if [ "$MODE" = plan ]; then
  for src in "${targets[@]}"; do
    scope=$(scope_for "$src")
    [ -n "$scope" ] || die "no test scope for $src — no ${src##*/} same-name test and no test file imports it; add one before mutating it"
    printf '%s: flutter test %s\n' "$src" "$scope"
  done
  exit 0
fi

# ── Prerequisites ──────────────────────────────────────────────────────────
command -v dart >/dev/null || die "dart is not on PATH"
[ -s coverage/lcov.info ] \
  || die "coverage/lcov.info is missing — run 'flutter test --coverage' first (the run uses it to skip mutants no test even executes)"
if ! dart pub global list 2>/dev/null | grep -qx "mutation_test $MUTATION_TEST_VERSION"; then
  printf '── installing mutation_test %s\n' "$MUTATION_TEST_VERSION"
  dart pub global activate mutation_test "$MUTATION_TEST_VERSION" \
    || die "could not activate mutation_test $MUTATION_TEST_VERSION"
fi

before=$(tree_fingerprint)
mkdir -p "$OUT" || die "cannot create $OUT"

# ── The throwaway copy ─────────────────────────────────────────────────────
# NEVER the working tree: a mutated source plus a session that dies is a silent
# corruption of the repository. .dart_tool comes along (minus the multi-GB
# device-build caches) so the first `flutter test` in the copy is already warm.
WORKTMP="${WORK%/}.tmp"
mkdir -p "$WORK" "$WORKTMP" || die "cannot create $WORK"
printf '── syncing a throwaway copy to %s\n' "$WORK"
rsync -a --delete \
  --exclude='.git' --exclude='build/' --exclude='mutation/' \
  --exclude='.dart_tool/flutter_build/' --exclude='.dart_tool/hooks_runner/' \
  ./ "$WORK/" || die "rsync failed"

status=0
reports=()
for src in "${targets[@]}"; do
  name=$(basename "$src" .dart)
  scope=$(scope_for "$src")
  if [ -z "$scope" ]; then
    printf '!! %s: no test scope (no same-name test, no importer) — SKIPPED\n' "$src"
    status=1
    continue
  fi
  cfg="$OUT/$name.xml"
  cat > "$cfg" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<mutations version="1.2">
  <files>
    <file>$src</file>
  </files>
  <commands>
    <command group="test" expected-return="0" working-directory="." timeout="$TIMEOUT">flutter test $scope</command>
  </commands>
</mutations>
XML
  cp "$cfg" "$WORK/mutation-config.xml"
  printf '── %s\n   scope: flutter test %s\n' "$src" "$scope"
  raw="$WORK/mutation-out"
  rm -rf "$raw"
  dry=()
  [ "$MODE" = dry ] && dry=(--dry)
  (
    cd "$WORK" || exit 2
    TMPDIR="$WORKTMP" dart pub global run mutation_test:mutation_test \
      "${dry[@]}" -c coverage/lcov.info --exclude-strings -f md \
      -o mutation-out mutation-config.xml
  # mutation_test's own exit code is its quality gate (an arbitrary undetected
  # percentage). The verdict here is the per-file ratchet below, so the code is
  # deliberately not propagated; the log keeps the full output either way.
  ) 2>&1 | tr '\r' '\n' | tee "$OUT/$name.log" | grep -vE '^(File|\s*$)'
  if [ -f "$raw/mutation-test-report.md" ]; then
    cp "$raw/mutation-test-report.md" "$OUT/$name.md"
    reports+=("$OUT/$name.md")
  else
    printf '!! %s: mutation_test produced no report (see %s)\n' "$src" "$OUT/$name.log"
    status=1
  fi
done

# ── The working tree must be byte-identical to how the run found it ────────
after=$(tree_fingerprint)
if [ "$before" != "$after" ]; then
  printf '\n!! THE WORKING TREE CHANGED DURING THE RUN (%s -> %s).\n' "$before" "$after"
  printf '   A mutation run must only ever touch its copy. Inspect: git status\n'
  exit 3
fi
printf '\n── working tree unchanged (%s)\n' "${before:0:12}"

[ ${#reports[@]} -gt 0 ] || exit "$status"

ratchet=(--baseline "$BASELINE")
[ "$RATCHET" = 1 ] || ratchet=()
python3 tool/mutation_report.py "${ratchet[@]}" \
  --tsv "$OUT/survivors.tsv" "${reports[@]}" || status=1
exit "$status"
