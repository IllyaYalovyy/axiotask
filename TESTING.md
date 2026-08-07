# Testing conventions

axiotask has a strong TDD culture (VISION.md §7): **every feature or bugfix
leaves behind a test that fails without it.** This document is the standard the
quality gate holds you to. It is short on purpose — the living examples under
`test/examples/` and `integration_test/` are the templates; copy them.

## The one gate

```bash
bash .ktask/verify.sh
```

Never retype its contents from memory. It runs, in order: TDD-evidence,
`dart format`, `flutter analyze --fatal-infos`, `dart analyze --fatal-infos
--fatal-warnings` (the riverpod_lint plugin), the time-source ban, `flutter
test --coverage`, and — when product code changed — the Android APK build, the
Linux build, and the xvfb integration smoke. Non-zero exit = not done.

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
- **integration** — `integration_test/example_integration_test.dart`: the app
  on the real Linux engine, run headless under xvfb by the gate.

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

alchemist writes two variants per golden: `goldens/<platform>/` (real platform
rendering) and `goldens/ci/` (host-independent). Commit both.

## Flakes are failures

A flake is a gate failure, full stop. Find the nondeterminism (real timer, wall
clock, network, uncontrolled async), fix it, re-run enough to prove it gone,
and record the root cause. Never land a task with a known flake.
