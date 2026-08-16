# Local development and repository workflow

This document defines the local workflow for the generated Linux and Android
Flutter projects. The reproducible setup, build, install, launch, and
verification commands are maintained in the repository [README](../README.md).

## Supported development targets

- Fedora Linux 43+ with GNOME while the selected Fedora release remains
  supported. Release-readiness testing must also cover the then-current stable
  Fedora release; the application must not depend on Fedora-version string
  checks when the required native libraries and services are available.
- Android through a current supported SDK/emulator and at least one physical
  Google Play Services device for authentication validation.
- Flutter stable `>=3.44.0 <3.45.0` and Dart `>=3.12.0 <3.13.0` are enforced by
  `pubspec.yaml`. S00 was validated with Flutter 3.44.8 and Dart 3.12.2.

No effort is allocated to Windows, macOS, iOS, web, distribution packaging,
hosted CI, or release automation.

## Locked scaffold toolchain and dependencies

The S00 lock was resolved on Fedora 43 with Android SDK 36.1.0, Build-Tools
36.1.0, JDK 21.0.8, clang 21.1.8, CMake 3.31.11, Ninja 1.13.1, GTK 3.24.52,
and pkg-config 2.3.0. The generated Android runner pins Android Gradle Plugin
9.0.1, Kotlin 2.3.20, and Gradle 9.1.0.

Direct package dependencies are exact: Flutter and `flutter_test` come from the
locked Flutter 3.44.8 SDK, and `flutter_lints` is 6.0.0. `pubspec.lock` records
the complete exact transitive resolution. Supported ranges permit Flutter patch
updates within 3.44.x and Dart patch updates within 3.12.x; any upgrade still
requires the dependency admission review and both native build gates.

S02 additionally locks `drift` 2.34.3, `sqlite3` 3.5.1 with bundled SQLite
3.53.4 native assets, `path_provider` 2.1.6, `drift_dev` 2.34.5, and
`build_runner` 2.15.1. The generated Drift output is committed. The normal
quality gate regenerates it and fails if any generated Dart file changes.

S22A locks `shared_preferences` 2.5.5 for disposable device presentation only.
The application adapter uses `SharedPreferencesAsync` with the composition's
injected namespace. Account/list/view query preferences remain in Drift, while
unit tests inject an in-memory device backend and never open normal preferences.
The default device presentation is system theme, standard density, and
onboarding not dismissed; malformed values are removed and safely diagnosed.

The version-1 database contains the account-scoped Google list/task cache,
separate remote bases, page-scope completeness, relational preference
foundation, durable truthful-health facts, coalesced desired state and
dependencies, and immutable outbound-attempt snapshots documented in
[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md). File-backed
connections run on a Drift background isolate and measured `foreign_keys=ON`,
`journal_mode=WAL`, `synchronous=FULL`, `busy_timeout=5000`, and
`wal_autocheckpoint=1000` on Fedora and the API 36 Android emulator. Explicit
`wal_checkpoint(TRUNCATE)` is supported and tested. In-memory tests retain
SQLite's required `journal_mode=memory` while using the other selected
settings. Existing files are checked read-only for schema version, exact schema,
integrity, and foreign-key violations before Drift can migrate or create
anything. Unknown, malformed, and corrupt files are closed and preserved.

S14A adds no dependency. Offline list create/rename uses the existing Drift
connection: projection, desired list content, causal generation, and unresolved
health count commit in one transaction. Its Linux integration test uses a
temporary database and synthetic account, and the screenshot runner uses the
existing isolated screenshot composition; neither can discover normal
credentials, storage, or Google Tasks data.

S14B also adds no dependency. Task create and whole-content title, notes,
date-only due, and completion edits use the same transaction boundary, stable
local identity, dependency rows, and unresolved health facts. Focused Linux
integration closes and reopens a temporary database immediately after an edit;
the synthetic screenshot composition covers provisional and stopped-sync task
states without loading Google or normal application storage.

S15A adds no dependency or storage namespace. After complete applicable remote
enumeration, the headless engine claims immutable create generations and sends
eligible list, top-level-task, and child-task creates in dependency order.
Canonical responses bind Google IDs and remote bases atomically without
replacing local IDs. The focused Linux application integration starts from a
stopped isolated temporary database, resumes through the real coordinator, and
confirms against the strict in-memory Google service; it opens no OAuth or
normal application storage.

S15B adds no dependency or namespace. After a complete applicable enumeration,
the same engine confirms read-proven no-op content, then claims eligible task
content snapshots before list titles. Task PATCH payloads always include title,
notes, due, and completion, using the admitted JSON-null clears and the current
task ETag. Each canonical response is acknowledged independently; interrupted,
ambiguous, and conclusively rejected attempts remain durable and are not
replayed by this non-retry slice. The Linux integration reopens a temporary
stopped database before Resume and uses only synthetic state plus the strict
in-memory Google service.

S16 adds no dependency or namespace. Reconciliation compares the complete
stored base, desired task-content or list-title record, and the current complete
Google observation. A one-sided change survives; a two-sided change selects the
strictly newer local timestamp or Google for a later/equal timestamp. Missing
required timestamp/base evidence fails closed without a write. A task 412
supersedes that immutable attempt, refetches the complete task scope, and
replans the same durable generation. Focused tests use synthetic isolated
stores, independently clocked hosts, and the strict in-memory Google service.

S04 locks `flutter_secure_storage` 10.3.1 and the resolved Linux implementation
3.0.2. Linux builds require Fedora's `libsecret` and `libsecret-devel` packages;
runtime access requires an active Secret Service, normally `gnome-keyring` in a
GNOME user D-Bus session. The opt-in probe command and exact isolation behavior
are maintained in the README. Normal tests fake the secure-value boundary and
never open Secret Service.

S05 locks `oauth2` 2.0.5, `http` 1.6.0, `crypto` 3.0.7, `jose` 0.3.5+2, and
`url_launcher` 6.3.2 for Linux authorization. S06 reuses `http` without a
dependency change for the page-oriented Google Tasks read adapter. Its normal
verification uses only synthetic JSON and a loopback scripted server; it never
loads OAuth configuration or reaches Google. The optional real-account read
probe remains outside this slice and may run only through the already isolated
S05 harness.

S07 reuses the same HTTP and authorization dependencies for strict mutation
operations and adds no package. Normal mutation tests use a loopback scripted
server and synthetic authorization. The explicit opt-in mutation probe alone
may use Google; it requires the already pinned dedicated subject, uses a unique
disposable prefix and separate credential namespace, and verifies both Google
resource cleanup and credential cleanup.

S13B locks `connectivity_plus` 7.3.1 for Linux NetworkManager interface-change
hints. The adapter deliberately maps an available interface to unknown or
may-have-returned rather than internet reachability. Production, development,
and synthetic Linux entry points use the same adapter, while deterministic
tests inject `ConnectivityPort` and never query the host network. Stop/Resume is
stored in the existing account-scoped SQLite preference row, so no new database,
preferences namespace, credential store, or OAuth configuration is introduced.

## Branch and commits

Development occurs on the independent orphan branch `flutter2` in the same
remote repository as the Rust reference. The older `flutter` branch is ignored.
Commit identity and message style follow the existing repository, without AI
attribution or co-author trailers.

For each coherent change:

1. write or update the behavioral test/specification;
2. implement the smallest complete slice;
3. format and analyze;
4. run focused tests, then the normal local quality gate;
5. inspect actual screenshots when UI changed;
6. inspect generated files and the complete diff;
7. scan the staged diff for privacy/security issues;
8. commit with a concise imperative subject;
9. repeat the repository privacy check and push `flutter2` directly.

Broken intermediate commits and enormous cross-subsystem commits are avoided.

## Local verification

The scaffold provides one normal entry point:

```text
./scripts/quality.sh
```

It is deterministic, fails fast with useful output, and invokes formatting,
generated-code freshness, analysis, tests, privacy-check fixtures, and the
repository privacy scan. Separate explicit commands run application
integration tests, goldens, actual screenshot capture, physical-device auth
validation, real Google API tests, and the deep sync oracle when those
capabilities exist.

No command silently selects a real Google account or normal application-data
directory.

S11 provides curated Linux health goldens and a separate native synthetic
screenshot entry point. The screenshot runner opens no database or Google
adapter and writes only beneath the ignored `screenshots/actual/` directory:

```text
flutter test test/features/tasks/adaptive_shell_golden_test.dart
./scripts/capture_linux_health_screenshots.sh
```

S13B extends the native Linux read-slice command above with hidden/unfocused
process-lifetime cadence, file-backed Stop restart, preserved cache/auth/work
facts, and Resume catch-up. Screenshot capture includes the active Stop control
and stopped Resume state using ignored synthetic output.

S18A extends the same ignored screenshot runner with `hierarchy-controls` and
`hierarchy-unsupported-error`. Both contain synthetic content; the latter shows
the last valid one-level projection under a safe application-failure code and
never renders the protected decoded diagnostic payload.

S18B extends `hierarchy-controls` with manual sibling ordering and cross-list
movement controls. The isolated Linux integration drives promote, reorder, and
move-to-list commands across a file-backed restart; the actual synthetic PNG is
reviewed from ignored `screenshots/actual/` output.

S19A adds `health-retry-waiting`, `health-retry-executing`, and
`health-retry-exhausted` to the same isolated runner. Waiting shows the exact
synthetic UTC boundary and Retry action under Failed; execution alone is
Pending; exhaustion remains Failed with an immediate Retry action. Focused
retry verification is available under `test/sync/retry/` and uses no real
account, credential, network, or normal application storage.

S19B validates the existing `health-no-authorization` scenario as the durable
reauthorization layout: cached synthetic tasks and unresolved counts remain
visible, health is Inactive, and Reauthorize is prominent at 1280×720. The
ignored actual capture uses no OAuth configuration, credentials, Google access,
or normal application storage.

S20A adds no dependency, namespace, OAuth configuration, or live-account step.
At the beginning of a run, interrupted unbound creates become uncertain and the
latest unresolved attempt from the original create generation is eligible for
one replay after complete applicable enumeration. A response received durably
binds its returned ID; earlier possibly committed objects remain independent.
Focused recovery, restart, dependency, and multi-host checks use only temporary
SQLite stores and the strict synthetic Google service.

S20B likewise adds no dependency, namespace, OAuth configuration, or
live-account step. Complete enumeration supplies operation-specific evidence
for response-lost task content, list title, and stable-ID move attempts before a
newer generation can publish. Task deletes retain current-list tombstone proof.
List deletes use a targeted identity GET: direct 404 confirms, a live identity
permits one newly claimed replay and another read-back, and every failure or
unknown result remains uncertain. Focused engine/store/restart/multi-host,
adapter-contract, and fake-application checks remain isolated and synthetic.

S21A adds no dependency, OAuth configuration, live-account step, platform
storage namespace, or visual surface. Schema-v1 `sync_runs` rows make the run
lifecycle durable alongside the existing page checkpoints. At each engine
entry, one SQLite transaction interrupts abandoned runs, changes every claimed
mutation to its conservative uncertain state, expires eligible delete snapshots,
recomputes counts, and retains retry/reauthorization latches and newer desired
generations. A failed recovery transaction rolls back completely; retrying it is
idempotent. Focused recovery and reopen checks use only temporary or in-memory
SQLite with synthetic subjects and no Google, credential, normal-storage, or
exit-callback dependency.

S21B adds no dependency, OAuth configuration, account access, or storage
namespace. Its child-process suite signals named durable boundaries, is killed
with `SIGKILL`, and is reopened by the parent against a unique temporary SQLite
file. Failed database validation reads a temporary copy of the complete
main/WAL/SHM set so SQLite cannot rewrite production shared-memory metadata.
The originals are never deleted, moved, quarantined, or replaced. The isolated
Linux recovery capture writes only the ignored synthetic
`screenshots/actual/database-recovery.png` file.

S22B adds no dependency, schema version, OAuth configuration, account access,
or storage namespace. Cached supported tasks and S22A relational preferences
feed pure effective-date, membership, and stable-sort policy. The Linux restart
test reopens one temporary SQLite file and the light/dark screenshot scenarios
use fixed 2026-08-15 local-calendar data through synthetic repositories only.
Actual smart-view captures are written as the ignored
`screenshots/actual/smart-views-{light,dark}.png` files.

S23A adds no dependency, schema version, OAuth configuration, account access,
or storage namespace. `integration_test/task_details_linux_test.dart` uses one
unique temporary SQLite file and synthetic identities/content to verify notes,
direct-child progress, create, and restart. Curated long-content detail goldens
and ignored `task-details-{light,dark}.png` captures exercise the 1280-pixel
Fedora layout without reading normal storage, preferences, credentials, or
Google.

S23B changes the exact version-1 schema contract by adding account-scoped due
Undo groups/snapshots, but adds no dependency, OAuth configuration, account
access, or storage namespace. Pure policy and real-SQLite tests use injected
local dates, synthetic tasks, and temporary files to prove clamping, cascade
rollback, and restart Undo. The isolated Linux detail integration exercises
completion, date propagation, restart, and grouped Undo without starting sync.
Ignored `task-workflows-{light,dark}.png` captures use fixed 2026-08-15 data and
were reviewed at the Linux runner's 1280×720 size; they read no normal storage,
preferences, credentials, OAuth configuration, or Google account.

## Development versus release diagnostics

S01 provides a clearly named debug development entry point that composes the
sensitive local diagnostic sink. The full in-app viewer remains a later UI
slice. The sink records
all application failures and the boundary/state-transition evidence needed to
reproduce them, including test-account task content and detailed API/database
context, without sampling or suppressing errors. When the later viewer slice is
implemented, it is one interaction from sync details and supports live search,
copy, explicit export, and clear. Its rotating log files and exports remain
inside ignored development storage.

The normal release entry point constructs only the production-safe sink and has
no runtime diagnostic-mode flag. Behavioral composition tests prove the
separation. Credential and authorization material is redacted before either
logging path in every build.

`lib/main.dart`, `lib/main_development.dart`, and `lib/main_test.dart` are the
production-safe, sensitive-development, and synthetic-test roots respectively.
Their injected database filename, preferences namespace, secure-storage
namespace, OAuth configuration identity, diagnostics namespace, authorization,
clock, and randomness are distinct. On first authorization, development Google
access obtains the stable account subject from the authenticated identity and
pins it in ignored private development storage before any Google Tasks request.
Later absence or mismatch fails closed; a subject is never guessed or required
before authorization.
The reproducible launch, isolation, and current cleanup commands are maintained
in the repository README.

## `ktask`

`ktask` state is local orchestration, not product source. `.ktask/` remains
ignored. Useful local mechanisms are:

- small ordered tasks with a hard stop on failed verification;
- retry with the previous failure/report context;
- a concise cross-cutting invariant checklist;
- normal fast verification separated from an expensive sync oracle;
- attempt logs and handoff summaries;
- timeouts and explicit external-test opt-in.

Machine-specific executor paths, prompts, transcripts, and agent state must not
be committed. Human-useful decisions discovered during a task are moved into
the product documentation or ADRs.

Interactive capability proofs are preceded by HUMAN queue gates. A gate may be
acknowledged only after its checked preflight command succeeds; missing hardware,
credentials, or desktop services therefore pause orchestration instead of
consuming a failed implementation attempt. The preflight reads only
`.ktask/gates/stage7.env` (or the explicitly named equivalent), requires the
file to be ignored and mode `600`, and never prints configured values. It proves
prerequisite availability, not the behavior that the following slice must test.

Implementation is deliberately Linux-desktop-first. Shared behavior and the
complete Fedora product are implemented, verified, and manually accepted before
Android authorization, lifecycle, UI, device, or release work resumes. Android
remains a supported target; it is sequenced later so unfinished mobile capability
cannot block or dilute desktop completion.

## Documentation map

- `VISION.md`: stable product intent and non-goals.
- `docs/ARCHITECTURE.md`: component boundaries and data flow.
- `docs/adr/`: meaningful decisions and rejected alternatives.
- `docs/SYNC_SPEC.md`: Stage 4 synchronization state machine and guarantees.
- `docs/SYNC_TEST_MATRIX.md`: Stage 4 behavioral evidence plan.
- `docs/FUNCTIONAL_PARITY.md`: Rust behavior disposition and verification.
- `docs/EXECUTION_PLAN.md`: ordered Stage 6 implementation slices and gates.
- `docs/TESTING.md`: local test layers and isolation.
- `docs/UX.md`: adaptive interaction and visual review principles.
- `docs/SECURITY.md`: threat model and privacy controls.
- `docs/DEPENDENCIES.md`: admitted/rejected dependencies and rationale.
- `docs/DATABASE_SCHEMA.md`: exact version-1 tables and persistence invariants.
- `README.md`: supported build/run/test instructions once executable code exists.

Documentation is updated in the same coherent commit as the behavior it governs.
