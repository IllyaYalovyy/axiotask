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
  invariants using the durations in the accepted Stage 4 specification.

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

The S06 suite is `test/data/google_tasks/decoder_test.dart` plus
`test/data/google_tasks/http_service_test.dart`. It uses completer-controlled
server responses and an injected timeout signal rather than elapsed-time sleeps.
The server sees only synthetic identifiers/content and an in-memory synthetic
authorization header; no test reads platform authorization or normal storage.

The S07 suite adds
`test/data/google_tasks/mutation_http_service_test.dart`. It exercises every
supported mutation request/response shape, strict success decoding, response
loss/truncation, conditional and structured error mapping, stale source-list
paths, and release/development diagnostic separation. The adapter performs one
request and exposes ambiguity; retry and reconciliation remain sync-engine work.

### 4. Stateful fake Google service

`FakeGoogleTasksService` implements the same narrow port as the HTTP adapter and
maintains strict in-memory list/task state. S08 supports:

- deterministic pagination and canonical test ordering without claiming that
  Google's collection pages have stable order or snapshot isolation;
- resource/collection etags and task stale-version rejection;
- one supported parent/child level, opaque sibling positions, completion
  cascades, and stable task identity across same-list and cross-list moves;
- duplicate creates, task tombstones and parent-delete cascades, and complete
  list removal with the observed repeated-delete representation;
- every ordinary service mutation plus a canonical request ledger with exact
  operation counts;
- an in-memory HTTP transport that fails closed on unsupported methods, paths,
  queries, flags, missing or invalid required headers, bodies, and hierarchy
  references.

A shared contract suite runs the same observable scenarios against the direct
fake and `HttpGoogleTasksService` over that in-memory transport. S09A adds
independently addressed barriers and splits the fake HTTP response into
controllable chunks, so a committed mutation, response headers, and partial or
complete body delivery are distinct observations. Later S09 slices own
auth/lifecycle and other fault scripting; S08 does not invent those behaviors.

The fake behavior/evidence mapping is:

| Fake behavior | API evidence boundary |
|---|---|
| Full-view task flags and documented maximum request sizes | Official `tasklists.list` / `tasks.list` contract; `API-001`, `API-002`, `REL-018` |
| Deterministic page tokens and list ordering | Test-only canonical mechanism. P3 / `API-002` explicitly prevents treating it as Google snapshot isolation or a server order guarantee. |
| Lexicographic sibling positions and parent/previous placement | Official Task resource and `tasks.insert` / `tasks.move`; `API-005` |
| Task ETag changes and stale task mutation rejection | Controlled P1; `API-003` |
| List ETag changes without conditional-write safety | Controlled P2; `API-003` |
| Repeated identical creates produce distinct IDs | Controlled P5; `API-004` |
| Stable task ID and subtree preservation across a cross-list move | Controlled P7; `API-004`, `API-005` |
| Task tombstones, parent-delete cascade, list disappearance, and repeated list delete | Controlled P4; `API-004`, `API-005` |
| Parent completion cascade and completed-parent insertion/move result | Controlled P8; `API-005` |
| UTC-midnight due values and JSON-null clearing for `notes` / `due` | Controlled P9 and S07 P12 follow-up; `API-005`, `API-009` |
| Possibly stale source-list task operations | Exact server effect remains absent. The direct fake returns conservative uncertainty without mutation; the HTTP adapter's admitted stale-path boundary remains covered separately. |
| Exact request ledger | Test-harness observation only; it makes `RUN-011`–`RUN-013` assertable and is not presented as Google behavior. |
| Commit and partial response boundaries | Test-harness transport control only. It exposes uncertainty interleavings without claiming that Google uses the fake's byte chunking. |

S09A also qualifies `FakeClock`, `FakeRandom`, `DeterministicBarriers`, and
`ObservationLedger`. UTC wall time can jump independently of monotonic time;
timers release at exact monotonic deadlines; jitter is scripted or seed-replayed;
run, page, request, server-commit, response, and transaction boundaries use
typed addresses rather than call counts; and typed observations retain exact
wall/monotonic timestamps and insertion order. These controls use no elapsed-time
sleeps and contain synthetic test data only.

S09B qualifies stateful `FakeAuthorization`, `FakeLifecycle`, and
`FakeConnectivity` through the production authorization, lifecycle, and
connectivity ports. Authorization scripts cover restore, refresh, expiry,
terminal rejection, cancellation, subject mismatch, and request rejection after
dispatch. Lifecycle facts separate foreground eligibility, Linux window focus,
best-effort exit requests, and termination without an exit callback.
Connectivity emits only unknown, proven-no-route, or may-have-returned hints and
coalesces repeats; it has no reachability or synchronization-health authority.

S09C qualifies `MultiHostHarness`, `ReferenceModel`, and `ReplaySeed`. A
multi-host case creates two or three independent production `AppDatabase`
instances with installation-local IDs and clocks while every host receives the
same `GoogleTasksService` through the production port. The remaining host
collaborators also retain the production clock, randomness, authorization,
lifecycle, and connectivity interfaces. Host-order permutations are explicit
and deterministic.

The reference runner applies commands to a system under test, observes its
public facts, and checks independently supplied invariants after every
transition; it never computes a reconciliation result. It supports asynchronous
store snapshots and bounded quiescence. Its fixed generator algorithm, failure
seed hint, exact replay, and deterministic one-minimal shrinking qualify the
`MOD-005` harness. Self-tests replay production-store snapshots, fake Google
state and call ledgers, and a synthetic visible sequence exactly, and prove the
oracle rejects both an illegal transition and a deliberately account-leaking
consumer mutation. Production sync decisions and full `F-STORE` crash evidence
remain owned by later slices.

### 5. Synchronization subsystem tests

The S12A read-only sync engine runs without widgets against real SQLite plus the
stateful fake or a scripted read port. Its focused suite covers ordered phases,
cold and warm multi-page walks, exact page/list request scaling, terminal empty
pages, child-before-parent deferral, unsupported depth, malformed/page failures,
no-op second runs, account eligibility, and durable success/failure facts.
Later slices extend the same boundary with reconciliation and outbound work.

The S13A coordinator suite drives the qualified monotonic fake clock and typed
authorization, lifecycle, and connectivity ports. It proves exact local-edit
debounce/cap, foreground cadence, outer run deadline, one active plus one merged
follow-up, cadence arriving during another run, repeated hints, stale-finalizer
rejection, and quiescence without wall-clock sleeps. The production composition
uses the same scheduler boundary; platform connectivity and Stop/Resume wiring
remain in their owning lifecycle slice.

S13B adds the production Linux lifecycle and connectivity adapters, durable
account-scoped `syncEnabled`, active-read cancellation, and Stop/Resume through
the ViewModel. Coordinator tests cover focus/minimize independence, idle and
active Stop, best-effort exit plus missing-exit-callback behavior, stopped local
work notification, and immediate Resume catch-up. The Linux application
integration reopens a real temporary SQLite file while stopped and proves cache,
authorization state, unresolved counts, and later catch-up remain intact. The
outbound-mutation uncertainty half of `RUN-007`/`REL-006` remains gated on the
later mutation engine rather than being simulated by the read-only S13B engine.

S14A repository tests inject deterministic transaction boundaries around list
projection and desired-state writes. They cover atomic commit/rollback,
rename coalescing with the original base, stable provisional identity, restart,
account rejection, attempt claiming and stale-generation completion, atomic
create acknowledgement, and resolved-attempt compaction. ViewModel/widget tests
prove duplicate-tap suppression, no local-only choice, and no success or sync
notification before persistence succeeds. The Linux integration reopens an
isolated temporary database while synchronization is stopped and edits the
same durable provisional list after restart without Google access.

S14B applies the same boundary suite to task create and whole-content edits.
Repository tests cover rollback, coalescing, read-base advancement without
projection loss, task attempt lifecycle/acknowledgement/compaction, stable
provisional identity, account and one-level hierarchy rejection, and exact
empty/Unicode/multiline/date/completion values. ViewModel/widget tests cover
durable progress, duplicate taps, inert editor text, invalid dates, one-save
content acknowledgement, and completion. The Linux integration reopens a
temporary stopped-sync database and renders the acknowledged task without any
Google or normal-storage access.

The matrix includes successful and failed incremental remote-page publication:
each published transaction remains valid and visible, partial completion never
advances last verified success, and restart continues from an explicitly
supported checkpoint or safely re-fetches without duplicating state.

Concurrency is controlled with barriers/completers exposed by fakes, never
wall-clock sleeps. Fixed seeds are printed on failure and are replayable.

`test/sync/read_sync_process_death_test.dart` launches a pure-Dart child against
an isolated temporary production SQLite file, waits for an explicit committed
page signal, kills the process, and reopens the file independently. It proves a
committed page survives while completeness and last success remain false. The
production application-support path resolver stays in its Flutter composition
adapter so the headless child cannot discover normal application storage.

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

S12B adds the Linux-only
`integration_test/read_slice_linux_test.dart` application slice. It opens a
temporary production SQLite connection, renders a warm cache before remote
verification, exercises startup/Refresh/Linux resume, observes first Good only
after full finalization, and verifies partial-page failure, malformed data, and
absent authorization without Google access. All content and identities are
synthetic; Android composition/lifecycle remains outside this slice.

The Linux secure-storage contract suite injects a fake key/value boundary for
absent, locked, unavailable, denied, malformed, ambiguous-write, failed-delete,
namespace, and credential-redaction behavior. The explicit GNOME probe uses the
real plugin and Secret Service with fixed synthetic values under one dedicated
namespace. It verifies initial write/read, complete replacement/read, deletion,
and cleanup, and it never calls global deletion or searches normal credentials.

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

The interactive authorization slices have fail-closed prerequisite checks:

```text
./scripts/preflight_capability_gate.sh android-auth
./scripts/preflight_capability_gate.sh linux-auth
```

The Android check requires exactly one authorized physical device with Google
Play Services plus ignored dedicated-account configuration. The Linux check
requires installed `libsecret-devel` metadata, a live user D-Bus session, GNOME
Secret Service, a system-browser launcher, and ignored dedicated-account
configuration. A passing preflight only allows the implementation task to
start; it is not evidence that authorization, refresh, DPoP, persistence, or a
Google Tasks call works.

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

`scripts/quality.sh` is the single normal gate. It currently runs formatting
verification, Drift generated-code freshness, strict static analysis, all
normal Flutter tests, behavioral privacy-check fixtures, and the repository
privacy scan. The S02 native database integration probe remains explicit so it
can name a real runner:

```text
flutter test integration_test/database_native_probe_test.dart -d linux
flutter test integration_test/database_native_probe_test.dart -d <android-device-id>
```

S02 acceptance requires the Android command on an emulator plus a debug APK
build followed by `./scripts/check_android_native_assets.sh`. The probe resolves
a distinct application-support filename, uses only a fixed synthetic account
subject, exercises transaction/stream/checkpoint/close/reopen behavior, emits
only SQLite version, schema, counts, and pragma facts, then removes only that
exact probe database and its WAL/SHM companions. The APK check proves SQLite is
packaged for ARM64, ARMv7, and x86_64 without pretending packaging proves
runtime behavior. Physical-device execution remains mandatory for Android
authorization and final device gates. Scope-specific scripts will add golden,
screenshot, real API, and deep synchronization suites.

Run the isolated Linux secure-storage capability proof only from an unlocked
GNOME user session:

```text
AXIOTASK_RUN_LINUX_SECURE_STORAGE_PROBE=1 \
  ./scripts/probe_linux_secure_storage.sh
```

The script fails closed when its explicit opt-in, `libsecret-devel`, user D-Bus,
GNOME desktop, or Secret Service prerequisite is absent.

Run the isolated Google Tasks P7/P12 mutation proof only after the S05 subject
has been pinned for the dedicated test account:

```text
AXIOTASK_RUN_GOOGLE_TASKS_MUTATION_PROBE=1 \
  ./scripts/probe_google_tasks_mutations.sh
```

It sets and clears only synthetic optional fields, tests DELETE through a stale
source-list path after a stable-ID cross-list move, deletes its uniquely
prefixed scratch lists, confirms zero prefix matches, and deletes/verifies only
its separate probe credential bundle.

There is deliberately no hosted CI. The same local gate is run before every
commit, followed by staged-diff review; the repository privacy check is repeated
before every push.
