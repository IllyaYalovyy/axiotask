# Testing strategy

Testing is a design constraint, not a cleanup phase. Every behavior change starts
with the smallest test that can fail for the right reason, and completion
requires the relevant broader checks to remain green.

## Principles

- Assert observable behavior, state transitions, invariants, and failure impact.
- Prefer stateful fakes over interaction-only mocks.
- Inject clocks, randomness, storage, lifecycle, connectivity, and services.
- Never use arbitrary sleeps to make a race test pass.
- Include a meaningful failure or edge path with each feature.
- Do not inspect source strings as a proxy for compiling or executing behavior.
- Do not duplicate production algorithms inside test expectations.
- A test must fail when the protected behavior is deliberately broken.
- Coverage is diagnostic information, not an acceptance target.

## Verification layers

### 1. Pure unit tests

Fast Dart tests cover immutable domain models and policies:

- smart-view membership and effective due dates;
- validation and one-subtask-level rules;
- rejection of deeper local hierarchy without remote mutation;
- typed error mapping and recovery classification;
- operation coalescing and scheduler state with a fake clock;
- four-outcome sync state transitions, precedence, timeouts, and freshness
  invariants after Stage 4 defines their durations.

These tests use no Flutter binding, files, plugins, or network.

### 2. Persistence tests

Each DAO and multi-row operation is tested against real SQLite through Drift,
using an in-memory connection when filesystem behavior is irrelevant and a
unique temporary directory when WAL, restart, locks, or durability matter.

Tests cover:

- constraints and account isolation;
- visible mutation plus desired-state-record atomicity;
- rollback on injected failure;
- reactive query emission;
- schema validation and every supported migration;
- restart with pending desired state and uncertain attempts;
- corrupt/missing database behavior without silent replacement;
- relational/account preference integrity separately from sync-critical state.

The device-preference adapter has a separate contract suite covering typed
defaults, malformed values, write failures, and recovery. Unit/widget tests use
an in-memory implementation and never open the platform preference store.

No test path is obtained from the production application-data resolver.

### 3. Google HTTP adapter contract tests

A local scripted HTTP server verifies exact request method, path, query,
headers, pagination, encoding, strict response decoding, etags, `Retry-After`,
timeouts, cancellation, and error mapping. Production-sink tests verify that
diagnostics contain neither authorization material nor task content. Separate
development-sink tests verify that task-content and decoded-payload canaries are
retained for investigation while authorization headers, tokens, PKCE values,
DPoP keys, and other credential canaries remain absent.

These are protocol tests, not synchronization tests.

### 4. Stateful fake Google service

`FakeGoogleTasksService` implements the same narrow port as the HTTP adapter and
maintains real list/task state. It supports:

- pagination and stable ordering;
- etags and stale-version failures;
- soft-deleted representations where the real API uses them;
- per-operation transient and permanent failures;
- authentication expiration and reauthorization;
- rate limiting and retry hints;
- malformed or partial responses;
- commit-then-fail/lost-response outcomes;
- remote changes injected between awaited operations;
- deterministic cancellation and process-restart snapshots;
- call recording for API-efficiency assertions.

A shared contract suite prevents convenient fake behavior from drifting away
from the verified Google adapter behavior.

### 5. Synchronization subsystem tests

After Stage 4, the sync engine is run without Flutter against real temporary
SQLite plus the stateful fake. Tests cover the full synchronization matrix,
including deterministic operation-sequence/property testing and restart at
explicit failure points.

The matrix includes successful and failed incremental remote-page publication:
each published transaction remains valid and visible, partial completion never
advances last verified success, and restart continues from an explicitly
supported checkpoint or safely re-fetches without duplicating state.

Concurrency is controlled with barriers/completers exposed by fakes, never
wall-clock sleeps. Fixed seeds are printed on failure and are replayable.

### 6. ViewModel tests

ViewModels are tested with fake repositories and immutable snapshots. Tests
verify loading/content/empty/failure states, command progress, duplicate-action
prevention, selection, navigation intent, and exact sync-health presentation
inputs without rendering widgets.

### 7. Widget tests

Widget tests render views with injected ViewModels and verify semantics,
keyboard/touch actions, focus, scrolling, adaptive breakpoints, accessibility
labels, text scaling, and important error/recovery surfaces.

Debug-only widget tests cover the live, searchable sensitive Diagnostics view,
its persistent privacy warning, copy/export/clear actions, and one-interaction
access from sync details. Release-composition tests prove that this sensitive
view and sink cannot be constructed or enabled by runtime state; the release
Diagnostics view exposes only production-safe summaries.

Desktop and phone constraints are explicit fixtures. Widget tests never use the
normal database or platform auth.

### 8. Golden tests

Flutter's built-in golden support protects a small curated set of stable visual
contracts. Goldens use bundled fonts, fixed locale/time/theme/pixel ratio, and
synthetic data. They cover representative desktop and Android sizes, light/dark
themes, long content, empty state, offline/stale state, sync failure, and
reauthorization required.

Goldens complement behavior assertions; they do not replace them. A changed
golden is reviewed visually before acceptance and is never bulk-regenerated as
a way to clear failures.

### 9. Application integration tests

Flutter `integration_test` runs the real application composition with an
isolated database and stateful fake. Core workflows run on Fedora and Android:

- cold start and cached-state verification;
- create/edit/complete/reschedule/reorder/move/delete;
- search, smart views, subtasks, bulk actions, and undo where supported;
- offline editing, reconnect, and truthful sync status;
- auth-expired presentation using the fake auth adapter;
- stop/resume sync without credential, cache, or queued-operation loss;
- export/import validation, account isolation, and eventual Google convergence;
- lifecycle pause/resume and Android predictive back;
- restart with pending desired state.

Plugin-specific tests run separately where a real platform implementation is
required.

### 10. Actual screenshot review

A dedicated test entry point builds the real app with synthetic repositories,
fixed time, and deterministic scenarios. Local scripts launch it at named
desktop and Android dimensions, capture actual application screenshots, and
store them under ignored output directories. The developer or agent inspects
those images in addition to golden diffs.

Significant UI changes are incomplete until actual screenshots have been
inspected on both relevant form factors. Screenshots containing a real account
or task data are forbidden.

### 11. Real Google API integration tests

Real API tests are a separately invoked, explicit opt-in suite. They require a
dedicated test account and ignored local configuration. If configuration is
absent, the command exits as skipped/not configured; it never searches normal
application credentials.

Every run uses a unique, recognizable test prefix and a dedicated disposable
list. Cleanup runs in `finally`, records leftovers without exposing content,
and a separate cleanup command removes stale test resources by the safe prefix.

The suite validates only high-value assumptions that a fake cannot prove:

- pagination and wire shapes;
- etag behavior and conditional updates;
- create/update/delete/move semantics;
- lost-response recovery probes where safely reproducible;
- `webViewLink` availability;
- Linux PKCE/DPoP exchange, returned nonce handling, bound refresh, and rejection
  of a missing/wrong DPoP key;
- authorization expiration/error classification where practical.

It is never part of the normal fast quality command.

### 12. Physical Android authentication gate

Before Android-dependent feature work, a small real-device test must prove the
official Flutter Google sign-in path can authenticate, authorize the Tasks
scope, call `tasklists.list`, restore after process restart, refresh or request
reauthorization correctly, handle cancellation, and stop/resume synchronization
without deleting authorization or the cache. Emulator-only or source-level
evidence is insufficient.

## Isolation rules

- Test application IDs/namespaces differ from production where platform storage
  is involved.
- Secure-storage adapter tests use a dedicated namespace and delete only that
  namespace.
- Unit/widget/integration tests receive database connections directly; they do
  not call production path discovery.
- Real API credentials are not shared with the normal app and are never loaded
  implicitly.
- Fixtures use synthetic names, email addresses, URLs, and task content.
- Tests fail closed when isolation configuration is ambiguous.

## Local quality commands

Once the Flutter scaffold exists, `scripts/quality.sh` will be the single normal
gate and will run formatting verification, static analysis, unit/persistence/
adapter/ViewModel/widget tests, generated-code freshness, and repository privacy
checks. Scope-specific scripts will add integration, golden, screenshot, real
API, and deep synchronization suites.

There is deliberately no hosted CI. The same local gate is run before every
commit, followed by staged-diff review; the repository privacy check is repeated
before every push.
