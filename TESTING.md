# Testing conventions

axiotask has a strong TDD culture (VISION.md §7): **every feature or bugfix
leaves behind a test that fails without it.** This document is the standard the
quality gate holds you to. It is short on purpose — the living examples under
`test/examples/` and `integration_test/` are the templates; copy them.

## The one gate

Every push and pull request is gated on GitHub by `.github/workflows/gate.yml`
— format, both analyzers, the two source-level time bans, codegen staleness,
the full suite with coverage, both coverage ratchets, and the Android debug APK
build. That is the shared gate; nothing merges past a red one.

Locally, the same ground plus the Linux build and the integration smoke:

```bash
bash .ktask/verify.sh          # scope-aware
bash .ktask/verify.sh --full   # force every build stage (e.g. on a clean mainline)
```

Never retype its contents from memory. It runs, in order: TDD-evidence,
`dart format`, `flutter analyze --fatal-infos`, `dart analyze --fatal-infos
--fatal-warnings` (the riverpod_lint plugin), the time-source ban below `lib/`,
the wall-clock ban below `test/`, codegen staleness, `flutter test --coverage`,
both coverage ratchets, and — when product code changed — the Android APK
build, the Linux build, and the xvfb integration smoke. Non-zero exit = not
done. Any honoured `AXIOTASK_VERIFY_SKIP_*` prints `SKIPPED (env override)`, so
a run that checked less than it looks like says so.

## Tests assert what the user sees

A test states an outcome: what renders, what state a provider exposes, what the
fake server ends up holding. **"A method was called" is not coverage** and is
rejected in review. Prefer finding rendered text/widgets and reading provider
state over verifying mock interactions. Every task ships at least one non-happy
path (empty field, task with children, offline, coarse pointer, second page,
API 412/404).

## The mandatory red-check

For every test you add:

1. Name the behavior/invariant it protects and the specific failure it
   prevents. If you can't, it doesn't belong in the suite.
2. Make it **fail first**, and confirm it fails **for the expected reason** —
   paste that failure output into the task report. A test that has never been
   seen red proves nothing.
3. Make the smallest change that turns it green.

## The five layers (see `test/examples/`)

- **unit** — `example_unit_test.dart`: pure Dart, no binding. Time comes from
  `package:clock`'s ambient `clock`, pinned with `withClock`.
- **store** — `example_store_test.dart`: a Notifier/provider's observable
  STATE, driven through `createTestContainer()` (see below).
- **widget** — `example_widget_test.dart`: pump a widget, find rendered
  content, drive a gesture, assert the tree changed.
- **golden** — `example_golden_test.dart`: pixel snapshot via alchemist (see
  "Golden discipline").
- **integration** — `integration_test/app_smoke_test.dart`: the app on the real
  Linux engine (real bootstrap, file-backed DB, go_router shell), run headless
  under xvfb by the gate — launch → DB opens → list renders → CRUD round-trip →
  clean exit. Desktop integration tests launch a fresh app process per file, and
  a single `flutter test integration_test/` reliably connects only to the FIRST
  file's app (the rest die with "log reader stopped"); keep the smoke suite in
  ONE file, or have the operator switch the gate to a per-file loop.

## Shared harness (`test/support/`)

- **`createTestContainer()`** — the ONLY way to build a Riverpod
  `ProviderContainer` in tests. It disables Riverpod 3's retry backoff, which
  otherwise reschedules a throwing provider on a timer and hangs/flakes the
  suite. Auto-disposes.
- **`flutter_test_config.dart`** loads the real app fonts once per suite so
  widget/golden output shows glyphs, not boxes.
- **`property_check.dart`** — the single door to `kiri_check`. Import this, not
  the library. Its `forAll` is fixed-seed so a counterexample reproduces; no
  test uses a random seed.

## Time and timers are injected — never `DateTime.now()` / raw `Timer`

Product code (`lib/`) reads wall time through `clock.now()` and schedules
through injectable abstractions. `DateTime.now()` and a bare `dart:async`
`Timer(...)`/`Timer.periodic(...)` are **banned below `lib/`** and the gate
greps for them (the port of the reference repo's `timestamp_audit.rs`).
Uncontrollable time is the top flake source; this ban keeps every date/timer
test deterministic under `withClock` / `fake_async`.

**Tests may not sleep either.** `Future.delayed` and `DateTime.now()` are banned
below `test/` too, and the gate greps for them. A test that polls a wall-clock
deadline is a flake waiting for a loaded runner — it either burns the time it
sleeps or fails on a machine slower than yours. Wait on the outcome instead:
`await scheduler.runs.firstWhere(...)`, a `Completer`, or `pumpEventQueue()`;
drive scheduled time with `fakeAsync`. Bound only the FAILURE path, with
`.timeout(...)`. One file is allowlisted — `test/ui/properties_test.dart` drains
real file IO inside `tester.runAsync()`, where fake timers starve the IO.

## Golden discipline

Goldens are byte-compared on every `flutter test`. A golden that changed is a
**signal**, not a chore — investigate before you regenerate.

**Golden-regeneration rule:** goldens are regenerated
(`flutter test --update-goldens`) ONLY in a dedicated commit whose sole purpose
is a toolchain or intended design change — **never** folded into a feature or
bugfix task. If your feature legitimately changes a golden, that regeneration
is its own reviewed commit with the before/after called out; a feature task
must never silently rewrite a baseline. Goldens are generated on the reference
toolchain (this repo's pinned Flutter) so they reproduce across the fleet.

alchemist can write two variants per golden. This suite runs **one**:
`goldens/<platform>/`, the real rendering. The `ci` variant obscures every run
of text into a solid block, so it cannot show a typography or layout regression
— all it added was a second baseline to regenerate on every engine bump. It is
disabled in `flutter_test_config.dart` and `test/packaging/golden_variant_test.dart`
keeps it that way (#275).

## The suite has prerequisites, not silent skips

A few assertions drive REAL external tools rather than re-reading strings this
repository wrote itself:

- the icon suite — `python3 cairosvg` (rasters) and `python3 GdkPixbuf` (the
  loader GNOME actually uses, which needs the librsvg SVG loader module);
- the distribution suite — `appstreamcli` and `desktop-file-validate`, the only
  two checks there that ask a freedesktop validator whether the shipped
  metainfo and `.desktop` entry parse.

None of them may `markTestSkipped` when its tool is absent: that turns a
machine without the tool into a GREEN packaging run that verified nothing —
exactly how the #261 blank icon reached a release. Each suite checks its
toolchain ONCE up front and fails with an install hint, so a missing tool is
one legible failure instead of five confusing ones (#275):

```bash
# Fedora
sudo dnf install python3-cairosvg python3-gobject gdk-pixbuf2-modules \
                 appstream desktop-file-utils
# Debian/Ubuntu (what CI installs)
sudo apt-get install python3-cairosvg python3-gi gir1.2-gdkpixbuf-2.0 \
                     librsvg2-common appstream desktop-file-utils
```

The one prerequisite the gate cannot yet demand is the sync oracle
(`AXIOTASK_ORACLE_BIN`): the reference binary does not exist (#181). Rather
than skip quietly, the local gate prints `BLOCKED (#181)` and names what is
missing; the moment the binary exists it exports `AXIOTASK_ORACLE=required` and
absence becomes a failure like every other prerequisite.

## Reference-toolchain assertions

A handful of expectations are byte-for-byte artifacts of one toolchain, not of
the code: goldens (one Flutter engine) and the icon re-render check (one
cairosvg/libcairo). Elsewhere they report the other machine's version, not a
defect. The icon one carries the `reference-toolchain` tag and CI excludes it;
the local gate on the reference machine runs it, and the renderer-free
recorded-sha256 assertion guards the committed bytes everywhere. Goldens are
NOT excluded — they are expected to be identical on the runner, and a
difference is the engine-bump signal.

## Flakes are failures

A flake is a gate failure, full stop. Find the nondeterminism (real timer, wall
clock, network, uncontrolled async), fix it, re-run enough to prove it gone,
and record the root cause. Never land a task with a known flake.

The commonest shape here is **waiting a fixed amount of real time for work that
publishes no signal** — it passes on the author's machine and fails on a loaded
runner. `test/ui/properties_test.dart` waited `6 x 60ms` for the local-data
reset and went red on CI with `Expected: empty / Actual: [StoredTaskList]`: the
budget expired mid-chain and the test asserted against a store still being
emptied. Wait on the OUTCOME instead — the reset's notice is rendered only after
its future returns, so the loop leaves the moment the notice appears and the
round cap bounds only the failure path.

## Mutation testing — would the suite notice?

Coverage says a line RAN. It cannot say an assertion DEPENDED on it: a test
that pumps the widget and asserts nothing covers everything and protects
nothing. Mutation testing asks the harder question by breaking the code on
purpose — one operator, constant or statement at a time — and re-running the
tests. A mutant the suite still passes is a **survivor**: a place where the
product could be wrong and the gate would stay green.

```bash
flutter test --coverage                       # the run needs coverage/lcov.info
tool/mutation.sh lib/src/model/dates.dart     # one file (~6 min)
tool/mutation.sh --plan lib/src/sync/engine.dart   # show the scope, run nothing
tool/mutation.sh                              # the whole core — hours; detach it
python3 tool/mutation_report.py -v mutation/  # the table + every survivor
```

It is **not part of `.ktask/verify.sh`** — a full core run is over an hour
(engine.dart alone is ~1 h). Run it at review time, or when an issue asks for a
before/after on a specific file. Everything it writes lands in the gitignored
`mutation/`: one markdown report and the generated config per source file, plus
`survivors.tsv` (file, line, original, mutated).

Two properties make the numbers trustworthy, and both are asserted in
`test/tool/mutation_tool_test.dart`:

- **It never runs in the working tree.** `mutation_test` edits sources in place;
  a session that dies mid-mutant would leave a mutated file behind. The run
  happens on an rsync'd throwaway copy, and the script compares a hash of
  `lib/ test/ tool/ integration_test/` before and after — a changed tree is a
  hard failure, not a warning.
- **Each file is mutated against the tests that cover it.** The same-name
  `<name>_test.dart` first, then up to 8 test files that import it directly.
  `engine.dart`, `reconcile.dart` and `store.dart` have no same-name test — the
  whole of `test/sync` / `test/store` is their scope. A consequence worth
  knowing: behaviour covered ONLY from outside that scope (engine paths
  exercised just by `test/app/*`) shows up as a survivor. That is a real signal
  — the unit's own suite never exercised it — not a tooling artefact.

### Triaging a survivor

Every survivor gets one of three verdicts, and the verdict is decided by
reading the test file, never by the tool:

- **Equivalent mutant** — the mutated program cannot behave differently, so no
  test could ever kill it (`Object.hash` argument permutations: equal values
  still hash equal; `<=` → `<` where the operands are equal; `>= 10` → `> 10`
  guarding `substring(0, 10)`). Record it in the closing issue and move on.
- **Weak test** — the behaviour IS exercised, but nothing asserts the part the
  mutant changed (a counter incremented and never read, a branch taken and only
  its side effect checked). Add the assertion.
- **Untested behaviour** — no test reaches the line at all. Write the test.

**A survivor is closed by an ASSERTION, never by excluding the line**, never by
deleting the mutation rule, and never by raising the cap in
`tool/mutation_baseline.tsv`. That file is a ratchet, seeded from the
2026-09-02/03 pilot (949 mutants, 55 survivors → #277–#279): a file may never
grow survivors, and `tool/mutation_report.py` exits non-zero when one does.
Killed a survivor? Lower the number in the same commit.
