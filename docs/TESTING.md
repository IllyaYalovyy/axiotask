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

S30A adds `test/domain/account_backup_codec_test.dart` for exact v1 supported
field round-trip, deterministic encoding, strict version/field/value/bounds,
hierarchy/reference/order validation, and structural exclusion of credentials,
authorization, sync attempts, diagnostics, preferences, and raw rows.
S30B adds `test/domain/account_backup_import_planner_test.dart` for
same-subject authoritative-identity wins and cross-account non-matching. Codec
and bounded file tests reject hostile structure, size, malformed JSON, and
malformed UTF-8 before mutation.
S31 adds `test/domain/local_data_recovery_service_test.dart` for exact preview
confirmation/account binding and reset/rebuild ordering.

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

S22A implements those contracts in
`test/data/preferences/device_preferences_test.dart`, with relational account,
foreign-key, restart, and stream evidence in
`test/data/preferences/relational_preferences_test.dart`. The combined
repository routing test proves a failed device write neither routes relational
or query settings through device storage nor changes synchronization settings.
`integration_test/preferences_native_smoke_test.dart` uses one isolated
namespace, verifies the actual `SharedPreferencesAsync` plugin after adapter
reconstruction, and removes only its three exact synthetic keys.

S30A adds `test/data/database/account_backup_repository_test.dart` for
selected-account isolation, projected acknowledged-offline edits,
document-local identity, sidebar/sibling order, and hierarchy over real
in-memory SQLite. `test/data/backup/local_account_backup_exporter_test.dart`
uses a unique temporary directory for exact write, cancellation, failure, and
sibling cleanup without a platform picker or normal storage.
S30B extends them with freshness refusal, empty/mostly-empty restore,
existing-wins preservation, dependency rows, manifest retry, and injected local
rollback. The create-engine suite proves remote partial success stays confirmed
while a failed restored dependency leaves its child waiting.
S31 adds `test/data/database/account_partition_reset_store_test.dart`. It seeds
every account-owned table class, proves one selected partition is empty after
reset while another remains, repeats reset, injects failure before commit, and
keeps device-only preferences untouched. Coordinator tests cancel an active
request, wait for its conservative interruption state, and permit exactly one
post-commit full rebuild.

No test path is obtained from the production application-data resolver.

### 3. Google HTTP adapter contract tests

A local scripted HTTP server verifies exact request method, path, query,
headers, pagination, encoding, strict response decoding, etags, `Retry-After`,
timeouts, cancellation, and error mapping. Production-sink tests verify that
diagnostics contain neither authorization material nor task content. Separate
development-sink tests verify that task-content and decoded-payload canaries are
retained for investigation while authorization headers, tokens, PKCE values,
DPoP keys, and other credential canaries remain absent.

`test/core/diagnostics_test.dart` covers `HLT-010/011` product separation,
credential shapes (including deliberately misclassified safe fields), typed
sync/API/storage/UI events, fixed bounds, clear, schema rejection, and restart.
`test/app/composition/composition_test.dart` reopens distinct release and
development files and proves the release composition remains production-sink
only. Coordinator, ViewModel, HTTP, authorization, preferences, bootstrap, and
sync-engine regressions cover their concrete event producers.

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

S15A extends the engine/store/fake boundary with durable create claiming and
list→top-level→child execution. The focused suite asserts exact payload/call
order, stable local IDs, atomic Google-ID/base binding, independent partial
success, dependency suppression, restart after claim and acknowledgement,
newer-generation preservation, duplicate-content independence, and uncertain
create non-matching. The Linux application integration resumes an isolated
stopped database through the production coordinator and observes Pending become
Good only after remote confirmation.

S15B extends that boundary with task content PATCH and list-title publication.
The focused suite asserts complete title/notes/due/completion payloads, admitted
JSON-null clears, task-before-list call order, read-proven no-op suppression,
independent partial acknowledgement, newer-generation preservation, and
restart at claim/response/acknowledgement boundaries. Uncertain updates remain
durable and are not replayed because read-back recovery belongs to a later
slice. The Linux application integration reopens an isolated stopped database,
then observes Resume confirm both updates through the production coordinator.

S16 adds pure whole-record policy tests, engine cases for one-sided and
two-sided changes, Google timestamp ties, optional clears, completion cascades,
fail-closed timestamp evidence, 412 refetch/replan, and file-backed restart
after supersession. A two-host production-store harness proves convergence and
quiescence with independent clocks. The Linux application integration also
stops synchronization, creates competing synthetic edits, resumes through the
production coordinator, and inspects the typed aggregate Google-won result.

S18A adds pure one-level hierarchy policy tests and real-SQLite repository
transactions for add, promote, demote, cross-scope/deleted/deep parent
rejection, parent-subtree protection, and file-backed restart. Read-engine
coverage retains child-before-parent deferral, preserves pending local structure
against remote publication, and proves unsupported depth persists a safe
application-failure code while only the sensitive development sink sees the
decoded synthetic scope. The scripted Google port fails on any mutation.
Widget and isolated Linux integration tests exercise the task-detail controls;
curated golden and actual synthetic desktop captures cover hierarchy controls
and the protected-depth error state.

S18B adds pure structure-winner tests, real-SQLite anchor/boundary and projected
ordering tests, engine coverage for canonical cross-list subtree MOVE plus an
independent content edit, and two-host competing-order convergence with a
quiescent repeat. Existing deletion and unsupported-depth suites remain the
move/delete and no-flattening regression gates. Widget and isolated Linux
integration checks drive reorder and move-to-list task-detail controls; the
ignored `hierarchy-controls` desktop PNG is inspected at 1280×720.

S19A adds a pure retry-policy suite plus engine and coordinator integration
under injected wall/monotonic time and deterministic full jitter. The focused
tests cover initial-plus-three request attempts, safe conclusively uncommitted
mutation retry, `Retry-After`, fitting an attempt inside the two-minute run
budget, durable restart reconstruction, exact five-minute exhaustion, backward
wall-clock discontinuity, unknown/permanent fail-closed classification, and
explicit Retry latch clearing. Health and Linux golden/actual screenshot checks
prove that waiting/exhaustion are Failed while only an executing retry is
Pending.

S19B adds engine/coordinator authorization-recovery suites over real in-memory
SQLite plus the qualified authorization fake. They prove one refresh and one
request replay for the accepted structured read rejection, terminal refresh and
second-rejection latching, cache/intent preservation, restart suppression,
cancel/scope/subject failure, stopped-sync precedence, and matching interactive
reauthorization followed by Pending full verification. HTTP adapter tests admit
only the observed malformed-bearer read shape; unknown 401/403 shapes and every
mutation-side auth-like response remain non-replayed and fail closed. Linux
authorization contracts retain `invalid_grant`, scope, subject, cancellation,
DPoP, and secure replacement coverage.

S20A extends the create engine/store suite with `REL-013`, `API-004`, and
`CRS-004`–`CRS-007` recovery cases. It covers commit-before-loss and
not-dispatched restart boundaries, repeated response loss, returned-ID binding,
newer edit/move/delete generations, list/parent dependencies, and two-host
duplicate ingestion. Identical content remains independent. The accepted
duplicate diagnostic exposes only resource kind/count/generation in release
history while the sensitive development composition may retain the synthetic
title; neither path uses content to resolve identity.

S20B extends the update, delete, shared-adapter, restart, and multi-host suites
with `REL-014`–`REL-017`, `REL-020`, `API-004`, `API-009`, and
`CRS-004`–`CRS-007`. Landed, not-landed, and unknown response-loss variants
prove separate whole-content, list-title, stable-placement, task-tombstone, and
exact-list-identity rules. Repeated loss and newer edit/move/delete cases prove
that the old attempt is resolved before the newer generation can publish.
Direct-list 404, live-list replay, malformed read-back, file-backed restart,
moved-task deletion, and unrelated-resource assertions prevent invented
success and collateral deletion. Release diagnostics expose only safe aggregate
resolution counts and stable failure codes; the UI contract is unchanged.

S21A adds `test/sync/restart_recovery_test.dart` across `CRS-001`–`CRS-011`
and stale-finalizer `RUN-014`. Temporary-file reopen proves committed local
intent and partial page tokens survive without an exit callback. Transaction
fault injection proves abandoned-run interruption, all in-flight attempt
transitions, delete-expiry cleanup, count recomputation, and the verification
obligation commit together or not at all. Repeating recovery preserves exact
transition timestamps, newer desired generations, reauthorization and retry
exhaustion latches, while durable run identity prevents an older finalizer from
changing success or failure facts after a newer run begins. Existing
create/update/delete recovery and acknowledgement-boundary suites remain the
operation-specific and no-half-acknowledgement regressions. This is
transaction/barrier and reopen evidence; killed mutation-process qualification
remains S21B.

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

S21B adds `test/sync/process_death_recovery_test.dart` as the complete
file-backed `F-STORE` qualification. Separate pure-Dart children pause at local
commit, durable run begin, mutation claim, each create-acknowledgement write,
partial-operation, page publication, finalization, and recovery-transaction
boundaries; the parent sends `SIGKILL` and independently reopens the real
SQLite file. `test/data/database/file_database_test.dart` separately covers
unavailable, malformed, schema, foreign-key integrity, and corrupt opens while
checking that main/WAL/SHM bytes remain preserved. App recovery widget tests
prove repeated Retry Open, safe diagnostics, no empty-account substitution,
and transition to recovery if a running sync can no longer revalidate storage.
The mid-run persistence test proves no second Google request or mutation begins
after that loss.

S22B adds pure effective-date and smart-view policy suites covering exact local
calendar boundaries, unfinished direct-child propagation, top-level-only
membership, exclusions, completion filtering, Focus overdue partitioning,
Missed oldest-first behavior, and stable manual/effective-date/title/reverse
ordering. Relational aggregate tests cover new/deleted lists, atomic sidebar
ordering, exclusions, reactive view preferences, and file restart. ViewModel
and widget tests prove every displayed count is the length of the same projected
rows and that typed controls update the selected view. No test reads normal
preferences, credentials, task data, or Google.

S23A adds a pure direct-child progress suite and a detail ViewModel suite. They
prove completed/total counts include only direct children, stable sibling order
is retained, navigation returns from child to parent, and create/edit/delete/
reorder actions produce the existing shared domain commands rather than
widget-owned mutations.

S23B adds `test/domain/date_workflow_policy_test.dart` for local-calendar
shortcuts, month-end clamping, clear, and edited-row-wins parent/child plans.
`test/data/database/due_cascade_repository_test.dart` proves the related
projection and desired states commit or roll back together, the exact Undo
group survives file restart, completed children participate in the literal
cascade, and Undo restores all rows or none. Detail ViewModel/widget tests prove
completion and every date route share these repository commands. Update-engine
coverage publishes Google's returned/refetched P8 child cascade in the same run
and retains the existing impossible-child-reopen and Google-won policy evidence.

S24A adds `test/domain/quick_capture_parser_test.dart` for exact terminal
grammar, invalid calendar dates, phrase position, ambiguity, and clamped month
boundaries. `test/features/tasks/quick_add_view_model_test.dart` proves preview
dismissal, target revalidation, persistence rollback, publication-after-commit,
and duplicate-submit suppression. Adaptive-shell widget tests prove the title,
Google list, and parsed or smart-view default date are visible before Enter.

S24B adds `test/domain/bulk_capture_parser_test.dart` for trimmed non-empty line
mode and blank-line-separated paragraph mode, where each paragraph's first line
is its title and remaining lines are notes. It proves the 100-task, 1024-title,
8192-note, and 1 MiB input bounds plus whole-preview rejection of malformed
control characters. `test/data/database/bulk_capture_repository_test.dart`
proves one all-or-none SQLite transaction, provisional-list and predecessor
dependencies, injected rollback, invalid targets, and file restart. ViewModel
and widget tests cover visible target/entries, mode changes, duplicate submit,
rollback, and local-versus-Google result wording. The Linux integration restarts
the database before an ordinary create run and proves one confirmed create, one
exact rejected create, and one unattempted dependent create.

S25 adds a repository suite that seeds real Drift/SQLite account partitions,
supported and protected projections, parent/child rows, Unicode text, empty and
long queries, and live cache updates. ViewModel and overlay tests cover stale
query replacement, bounded keyboard selection, failure/empty states,
accessibility context, and identical pointer/keyboard activation. The pure
application navigation suite proves one ordered route stack for drawer, stable
local-ID detail, selection, tracked dialogs, and search. Adaptive-shell and
isolated Linux integration tests exercise Navigator-driven system back and
verify that a child result opens its supported parent while protected and
cross-account rows remain absent.

S28A adds `test/domain/bulk_task_operations_test.dart` for mixed-hierarchy due
and MOVE normalization, and
`test/data/database/bulk_task_operations_repository_test.dart` for every
selection/destination/synchronizability rejection, desired-write rollback, one
desired/member row per affected resource, and file restart. Create/update sync
engine cases prove exact independent success/failure/dependency accounting.
ViewModel and adaptive-shell tests cover transient selection, duplicate-safe
dispatch, failure retention, complete confirmation, reschedule/move routes,
result copy, and platform back. The isolated Linux integration commits two
tasks together and reopens the database before asserting all exact counts.

S28B extends those suites with destructive `PAR-BULK-002` and `PAR-TASK-008`
coverage: hierarchy-root normalization, exact one-group counts, all-or-none
Undo under missing snapshot evidence, the 29.999/30.000-second restart
boundary, refresh gating, partial remote deletion, confirmation cancel, and
unrelated-list safety. Clear-completed cases retain a completed parent and its
unfinished child while deleting independent eligible completed roots without
offering Undo. The isolated Linux integration reopens one temporary database
before grouped Undo and uses only synthetic resources.

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

S29B implements this evidence in
`test/features/diagnostics/{diagnostics_view_model,diagnostics_view}_test.dart`,
`test/data/diagnostics/local_diagnostic_exporter_test.dart`, and the release/
development composition cases. The native Linux integration repeats
reachability, allowed private-context retention, credential exclusion,
copy/export, and clear using only an in-memory history and temporary export
directory. Curated release-light/development-dark goldens and the ignored
actual desktop captures verify the persistent warning and product separation.

S30A adds `test/features/backup/{account_backup_view_model,
account_backup_view}_test.dart`. They prove selected-account routing, explicit
native-picker cancellation/failure, confirmation before
the adapter opens, persistent private-data warning, and exact successful result
counts without a normal filesystem or Google account.
S30B adds validation-before-preview, freshness recheck, confirmation before the
transaction, source mismatch/duplicate warnings, exact existing/create counts,
and local-acceptance versus remote-publication copy.
S31 adds `test/features/recovery/` ViewModel/widget evidence for destructive
warning/cancel/confirm, transaction failure, and Good-only rebuilt copy versus
a visibly failed empty cache.

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

S31 adds curated 1280×720 `local-data-reset-warning-light`,
`local-data-reset-rebuilt-light`, and `local-data-reset-failed-dark` goldens.

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

S30A implements the export half in
`integration_test/account_backup_linux_test.dart`. It uses one unique temporary
SQLite file, acknowledges a provisional list/task through the production
repositories, enters the backup from the real application header, writes to an
injected temporary destination, decodes the produced v1 file, and verifies
seeded sync-run/authorization canaries are absent. It opens no OAuth,
diagnostic, preference, secure-storage, normal database, or Google boundary.
S30B adds a bounded temporary v1 document to the same application route,
previews it against a fresh synthetic partition, and atomically creates ordinary
desired state plus one manifest without opening normal or Google boundaries.
S31 adds `integration_test/local_data_recovery_linux_test.dart` over one unique
temporary production SQLite file. It enters recovery from the real header,
confirms the warning, preserves the other account, verifies synthetic Google
reconstruction, and separately proves unavailable Google leaves an empty
selected cache under Failed health.

S12B adds the Linux-only
`integration_test/read_slice_linux_test.dart` application slice. It opens a
temporary production SQLite connection, renders a warm cache before remote
verification, exercises startup/Refresh/Linux resume, observes first Good only
after full finalization, and verifies partial-page failure, malformed data, and
absent authorization without Google access. All content and identities are
synthetic; Android composition/lifecycle remains outside this slice.

S17 adds `integration_test/delete_publish_linux_test.dart`. It uses a temporary
SQLite file and stateful synthetic Google service to verify task delete → Undo
with unchanged identities, zero Google DELETE calls through 29.999 seconds,
and one tombstone-verified DELETE at 30.000 seconds. Focused store, coordinator,
engine, widget, and golden tests cover restart cleanup/claim recovery, explicit
Refresh during grace, subtree/moved-child safety, unrelated accounts/lists,
durable Undo presentation, and irreversible list-delete confirmation.

S22B adds `integration_test/smart_views_restart_linux_test.dart`. It closes and
reopens a unique temporary SQLite file, then renders the effective child date,
restored Focus preferences, restored list exclusion/order, and exact visible
count through the production task and relational-preference repositories. It
uses an in-memory device adapter, fixed synthetic identities/content, and no
Google or normal application storage.

S23A adds `integration_test/task_details_linux_test.dart`. It opens and reopens
one unique temporary SQLite file, renders parent-only collection rows and exact
direct-child progress, saves multiline Unicode notes, creates a direct child,
and verifies the notes/children/progress after restart. Sync is stopped and no
Google, credential store, normal database, or normal preferences are used.

S23B extends that integration with complete/reopen, a fixed-local-date shortcut,
multi-row due propagation, restart-visible grouped Undo, and exact restoration
of all prior dates in the same isolated file-backed composition.

S24A adds `integration_test/quick_capture_linux_test.dart`. It enters one
synthetic parsed capture through the production widget/ViewModel/repository
path, closes and reopens the unique temporary SQLite file, then resumes the
production coordinator and proves one ordinary list create plus one ordinary
task create bind Google identities without losing the stripped title or due
date.

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

S22B adds curated fixed-time light/dark desktop goldens at 1280×800 and
matching actual `smart-views-light` / `smart-views-dark` application scenarios
at 1280×720. Both show overdue-first Focus membership, an effective date
inherited from one unfinished direct child, matching badge/row count, per-view
controls, and only synthetic content.

S23A adds curated long-content light/dark task-detail goldens at 1280×800 and
matching actual `task-details-light` / `task-details-dark` application scenarios
at 1280×720. They show plain multiline notes, parent-only collection rows,
completed/total direct-child progress, and visible subtask management routes.

S23B updates those curated detail goldens for the completion/date controls and
adds actual `task-workflows-light` / `task-workflows-dark` scenarios at 1280×720.
The reviewed captures show an explicit and inherited effective date, one
completed child, non-green pending health, and restart-durable grouped Undo
using only fixed synthetic content.

S24A adds curated `quick_capture_light` / `quick_capture_dark` goldens at
1280×800 and matching actual `quick-capture-light` / `quick-capture-dark`
application scenarios at 1280×720. The reviewed captures show the focused
single-line keyboard field, stripped title, visible Google list target, exact
date chip with dismissal affordance, and non-green pending synchronization.

S24B adds actual `bulk-capture-preview-{light,dark}` and
`bulk-capture-result-{light,dark}` captures at 1280×720. They show the bounded
three-entry preview, visible Google target, mode choice, non-green sync health,
and the truthful post-transaction message that Google confirmation is pending.
All content and identities are fixed synthetic values.

S25 adds curated `search_results_{light,dark}` and
`navigation_back_{light,dark}` goldens plus actual
`search-results-{light,dark}` captures at 1280×720. The reviewed actual images
show a focused title/notes query, non-green sync evidence, the matched subtask,
its parent context and Google-list label, and the close/back affordance. The
fixtures contain only fixed synthetic identities and task content.

S26A adds `desktop_interactions_1024_light` and
`desktop_interactions_1280_dark` curated goldens plus matching isolated Linux
application captures. The 1024 and 1280 logical-pixel states show all three
panes, truthful non-green sync health, visible task/detail routes, and the
reserved task-row action region. Widget tests additionally inspect hover
geometry before/after pointer entry, secondary-click menus, semantics, F1 and
header discoverability, text-editor suppression, arrow/Enter focus transitions,
and 1.8x text at 1024/1280/1440. The Linux integration exercises the same
keyboard route over a temporary SQLite database with synthetic data.

S26B adds pure drop-anchor and bounded-autoscroll adapter tests, pointer widget
tests for preview/drop/cancel/invalid targets/cross-list movement, unchanged row
geometry, command-failure canonical restore, and focusable detail alternatives.
`desktop_drag_reorder_linux_test.dart` drives the same gestures through a unique
temporary SQLite database. Curated `drag_preview_light` and
`drag_failure_dark` goldens plus matching actual Fedora captures show an
in-progress placement preview and a truthful failed state with canonical row
order restored. All identities and content are synthetic.

S28A adds curated `bulk_selection_light`, `bulk_result_dark`, and
`bulk_confirmation_light` desktop goldens at 1280×800 plus matching ignored
`bulk-operation-{selection-light,result-dark,confirmation-light}` Fedora
captures at 1280×720. The reviewed images show two selected rows, visible
non-destructive commands, explicit all-or-none local confirmation, exact
confirmed/pending/failed Google-resource counts, and truthful non-green sync
health using only fixed synthetic data.

S28B adds curated `bulk_delete_undo_light` and
`clear_completed_confirmation_dark` goldens plus matching ignored
`bulk-delete-undo-light.png` and `clear-completed-confirmation-dark.png` Fedora
captures at 1280×720. The reviewed group image shows one selected-count banner
and one “Undo all” action; the Clear image states that the action has no Undo
and that the unsafe completed parent is retained. Both use fixed synthetic
content only.

S30A adds actual `account-backup-warning-light.png` and
`account-backup-result-dark.png` Fedora captures at 1280×720. The warning view
identifies the current selected Google account, exact v1 JSON contents and
exclusions, and the persistent private-data warning before the file action. The
result view retains that warning and reports only the synthetic filename plus
exact list/task counts. Both use fixed in-memory synthetic data.
S30B adds `account-restore-preview-light.png` and
`account-restore-result-dark.png`, showing existing-wins counts, the
cross-account/manifest duplicate limitation, and that locally accepted records
still require Google publication. Both use fixed in-memory synthetic data.
S31 adds `local-data-reset-warning-light.png`,
`local-data-reset-rebuilt-light.png`, and `local-data-reset-failed-dark.png` at
1280×720. The inspected warning names every discarded class and the
already-sent limitation; result captures distinguish verified Good rebuild
from an empty, non-green failed cache. All content is fixed and synthetic.

S32B adds `onboarding_light.png` and `onboarding_dark.png` curated desktop
goldens at 1280×800 plus matching ignored synthetic Linux captures. ViewModel
and widget coverage proves default/dismissal/write-failure behavior, truthful
connection and health copy, semantics, keyboard/touch finish activation,
narrow/wide layouts, two-times text scale, and reduced-motion stability.
Shared visual-token tests verify light/dark foreground contrast and standard/
compact density presentation.

Significant UI changes are incomplete until actual screenshots have been
inspected on both relevant form factors. Screenshots containing a real account
or task data are forbidden.

### 11. Real Google API integration tests

Real API tests are a separately invoked, explicit opt-in suite. They require a
dedicated test account and ignored local configuration. Missing configuration
fails closed; the commands never search release application credentials or the
Rust token file.
The pinned-subject Google mutation probe includes S30B's empty-list smoke: one
fresh in-memory partition restores a synthetic list/task, publishes it through
the production engine, verifies returned identities and live read-back, then
deletes the exact prefixed list and isolated credential bundle.

Every run uses a unique, recognizable test prefix and a dedicated disposable
list. Cleanup runs in `finally`, records leftovers without exposing content,
and a separate cleanup command removes stale test resources by the safe prefix.

S34A supplies the full opt-in contract command,
`AXIOTASK_RUN_GOOGLE_CONTRACT=1 ./scripts/test_google.sh`. It takes only the
Linux OAuth client configuration and pinned-subject file from ignored private
sources. Access tokens, refresh tokens, and DPoP keys remain inside the shipped
development secure-storage boundary. The command first restores the existing
development authorization and otherwise runs the shipped interactive browser
flow. It then exercises the shipped `HttpGoogleTasksService`; there is no
second token-refresh or Tasks HTTP implementation in test code. The account
guard compares the subject on every Tasks operation. Missing/mismatched
subjects make zero Tasks calls. Prefix-scoped cleanup runs before and after the
probe, and the safe prefix is printed before the first mutation. The separate
cleanup command requires one exact
`axiotask-contract-probe-<UTC>-<random>` prefix and confirms zero remaining
matching lists. S34A validates `webViewLink` presence/shape on a disposable
ordinary task, but makes no claim about ordinary or recurring link navigation.
That confirmation is owned by the final Linux HUMAN approval gate. Adversarial
platform-authentication and intentional rate-limit generation remain their own
gates, so this suite makes no synthetic claim for them.

The suite validates only high-value assumptions that a fake cannot prove:

- pagination and wire shapes through the production adapter (with forced
  multi-page traversal qualified against the deterministic fake);
- etag behavior and conditional updates;
- create/update/delete/move semantics;
- lost-response recovery probes where safely reproducible;
- `webViewLink` availability;
- the existing Linux authorization boundary's successful restore or interactive
  connection to the pinned account.

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
authorization and final device gates.

S33 provides the deep synchronization suite:

```text
./scripts/deep_sync.sh
```

It runs the qualified fake/model/replay support checks, then repeats four fixed
generated sequences (`331`, `902`, `1907`, and `8161`) through production
repository and engine ports backed by two isolated temporary SQLite files. The
model checks the twelve `SYNC_SPEC.md` reliability invariants after every
transition, drives edits, creates, deletes, moves, triggers, authorization
refresh, and reopen recovery, enumerates both host orders, verifies no-write
quiescence, exercises bounded no-progress detection, and runs the real
subprocess crash matrix. The normal two-pass command has no network dependency
and reports its duration. `AXIOTASK_REPLAY_SEED=<integer>` reduces the generated
corpus to the printed failing seed for exact replay.

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
