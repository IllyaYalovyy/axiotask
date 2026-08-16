# Target architecture

Status: **Stage 3 and Stage 4 synchronization design accepted; deterministic
foreground coordination, Linux lifecycle/Stop/Resume control, durable offline
list/task acknowledgement, ordered Google create/update/delete/MOVE
publication, whole-record content reconciliation, and Google-authoritative
one-level structure reconciliation are implemented through S18B. General retry,
Android lifecycle control, and other later mutations remain later slices.**

This document defines the boundaries needed to scaffold Axiotask. The accepted
[Stage 4 synchronization specification](SYNC_SPEC.md) supplies the detailed
policy within these boundaries.

## Architectural goals

In priority order:

1. Users can trust the relationship between displayed state and Google Tasks.
2. Acknowledged work is durable, synchronization is recoverable, and failures
   are visible.
3. Domain and synchronization behavior can run deterministically without
   Flutter widgets, plugins, a normal database, or a Google account.
4. Desktop and Android views can diverge without duplicating product rules.
5. Public interfaces remain small and explicit so changes are locally
   understandable and reviewable.
6. Dependencies and abstractions exist only where they remove demonstrated
   risk or platform complexity.

## System shape

```text
Flutter views
    ↓ user intent / ↑ immutable view state
View models and commands
    ↓
Domain policies and repositories
    ↓                         ↘ sync triggers
Transactional local store      Sync coordinator ── Sync engine
    ↓ streams                         ↓                ↓
Drift / SQLite                 lifecycle + clock   Google Tasks port
                                                      ↓
                                             HTTP / platform auth
```

Dependency arrows point inward toward domain contracts. Widgets do not call
SQLite, HTTP, OAuth plugins, or the sync engine. The sync engine does not read
widgets, focus state, open editors, or view-model state.

## Layers and module boundaries

The codebase is organized by responsibility, with feature folders only in the
UI layer:

```text
lib/
  main.dart
  src/
    app/                 # composition root, lifecycle, adaptive shell
    core/                # clock, typed outcomes, sanitized diagnostics
    domain/
      model/             # immutable application models and opaque IDs
      policy/            # smart views, effective due date, validated actions
      repository/        # narrow interfaces consumed by UI/domain
    data/
      database/          # Drift schema, DAOs, transactions, row mapping
      google_tasks/      # strict wire DTOs and REST service
      auth/              # platform adapters and secure credential store
      connectivity/      # connectivity hints only
      preferences/       # typed relational and device preference adapters
    sync/                # coordinator, engine port, health projection
    features/
      tasks/             # views, view models, feature-local widgets
      search/
      settings/
      account/
    ui/core/             # theme and genuinely shared presentation widgets
```

Tests mirror these boundaries. Files do not grow into generic `utils`,
`helpers`, or global service-locator modules.

### UI layer

- A View is a composition of widgets and platform-adaptive layout.
- A ViewModel owns one feature's immutable `ViewState`, subscribes to repository
  streams, transforms domain data for display, and exposes user-intent methods.
- ViewModels may use Flutter `ChangeNotifier`; domain and data code may not.
- Views contain only rendering, animation, layout, and trivial routing logic.
- Async commands expose running/succeeded/failed state so duplicate taps and
  error presentation are deterministic.

`provider` is used only for construction, lifetime, and narrow subscriptions.
It is not a global state architecture. There is no service locator and no
mutable application singleton.

### Domain layer

The domain layer is justified by synchronization and task policy that must not
be reimplemented in desktop widgets, mobile widgets, or SQL:

- task/list invariants;
- top-level plus one-subtask-level rules;
- smart-view membership and effective dates;
- validated move, reorder, complete, reschedule, and bulk commands;
- typed failures with explicit authorization, connection, remote-service,
  persistence, unsupported-data, and application-failure reasons;
- synchronization ports and outcomes.

Models are immutable Dart classes or sealed types with explicit equality and
copy operations. Code generation is not used for domain models initially; the
model set is small enough that explicit code is easier to audit.

The supported remote product surface matches ordinary lists and tasks in the
standalone Google Tasks UX. The adapter leaves `showAssigned` false and does not
ingest cross-product assigned/shared tasks from Docs or Chat. The domain models
only a top-level task and one subtask level. If Google nevertheless returns an
unsupported deeper relationship, the adapter reports unsupported remote state
and does not mutate that resource; no deeper-hierarchy feature is built.

### Data layer

Repositories are the only application-facing source of task, account,
preference, and sync-health state. Services are stateless adapters for a single
external source: SQLite, Google Tasks HTTP, secure storage, connectivity, or
platform authorization.

`PreferencesRepository` is one typed application boundary with two storage
adapters. Account-scoped or relational preferences use Drift; small disposable
device-presentation preferences use `SharedPreferencesAsync`. ViewModels do not
know which adapter owns a setting.

The important ports are intentionally small:

```dart
abstract interface class TasksRepository {
  Stream<TasksSnapshot> watchTasks(TasksQuery query);
  Stream<int> watchPendingMutationCount();
  Future<Outcome<TaskId>> createTask(CreateTask command);
  Future<Outcome<void>> apply(TaskCommand command);
}

abstract interface class GoogleTasksService {
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  });
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId list, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  });
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  );
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  );
  // Rename/delete/create/move operations use the same typed boundary.
}

abstract interface class SyncRunner {
  Future<SyncRunReport> run(SyncRunRequest request);
}
```

Exact operations, metadata, phase ordering, and conflict results are defined by
the accepted [Stage 4 specification](SYNC_SPEC.md). The UI observes repositories
and `SyncHealth`; it never interprets raw HTTP or database errors.

The S06 HTTP implementation deliberately exposes one validated page per call;
the synchronization engine owns traversal and scope completeness so pages can
be published incrementally. The request boundary uses exact explicit listing
flags, a 30-second cancellable attempt, no redirects or retries, and bounded
JSON collection decoding. Known fields are type-checked; future unknown optional
fields are deliberately ignored. Live resources require the fields needed for a
remote base, while a positive `deleted=true` task is represented separately and
may retain only the fields actually present. Assigned resources and malformed
rows fail the containing scope.

The S07 mutation boundary uses explicit operation values for task-list
create/rename/delete and task create/complete-snapshot patch/delete/move. It
validates exact paths, bodies, placement queries, task `If-Match`, response
status/content type/body shape, and the same response-size bound as reads. It
does not retry. A valid canonical response is `Committed`; a conclusive
rejection is `Rejected`; transport loss, malformed/unexpected success, 5xx,
unknown responses, and any possibly stale source-list path are `Uncertain` so
later synchronization policy must resolve them. JSON `null` for task `notes`
and `due` is admitted by the isolated S07 probe; no unproved optional clear
spelling is available through the operation DTO.

## Identity and account scoping

Every task and list receives a stable local primary key before any remote
request. The nullable Google resource ID is a separate external key, unique
within its Google account and resource type.
Widgets, parents, selections, desired-state records, and navigation use the
local key. A successful create fills the remote key without replacing
application identity.

The initial local key is a SQLite-assigned 64-bit integer wrapped in an opaque
Dart value type. UUIDs add no correctness benefit because keys never need to be
generated independently by multiple stores. If Stage 4 discovers such a need,
that premise must be revisited explicitly.

The schema supports multiple isolated Google accounts from its first version:
every remote object, snapshot, desired-state record, sync attempt, and
account-specific preference is owned by a stable Google account subject. The
initial product permits one configured account and exposes no switching UI.
Future multi-account support can activate multiple existing account partitions
without a data-model migration. No query or uniqueness constraint may merge or
display data across accounts.

## Persistence

Drift over SQLite is the durable store for all non-secret application state:

- account-scoped task lists and tasks;
- remote snapshots/versions needed for reconciliation;
- coalesced desired remote state, pending attempts, and uncertain outcomes;
- synchronization attempts and last verified success;
- account-scoped/relational view settings, list exclusions, and local ordering;
- restart-safe recovery checkpoints and schema metadata.

OAuth tokens never enter SQLite.

Small device-local presentation settings that do not require relational
integrity—initially theme, visual density, and onboarding dismissal—use
`SharedPreferencesAsync` behind `PreferencesRepository`. They are explicitly
non-critical: failure may recover to a documented default and report a
sanitized diagnostic. Desired state, sync metadata, account identity,
list references, and any setting that changes task queries never use this
store.

Writes that acknowledge a user mutation atomically update the visible local
row and its coalesced durable desired-state record in one transaction. If that
transaction fails, the UI reports failure and does not pretend the change was
accepted.

The production database runs through one Drift connection hosted away from the
UI isolate. SQLite foreign keys are enabled. WAL, busy handling, checkpointing,
and synchronous durability settings will be selected and failure-tested during
the persistence implementation; correctness takes precedence over an
unmeasured write-speed optimization.

Tests inject in-memory or temporary-file database connections and an in-memory
device-preference adapter. Production path/plugin lookup is confined to the
composition root, so tests cannot accidentally open normal application storage.

There is no migration from prior implementations. The first intentional schema
is versioned, verified on open, and receives migration tests before a released
format changes. During early development an explicit destructive reset may be
available, but startup never silently destroys an unreadable or inconsistent
database.

## Import and export boundary

Import and export are required safety features, not an alternate local backend.
Exports are explicit, versioned, account-aware files that contain no OAuth
credentials or DPoP keys and warn that task data is sensitive. Import parses and
validates the complete file before making changes, presents a summary, and
converts accepted changes into the same durable desired-state records used by
normal edits. It cannot write around account isolation, synchronization state,
or the synchronization engine. The accepted
[functional parity contract](FUNCTIONAL_PARITY.md#backupexport-and-restoreimport)
defines the format boundary, existing-record-wins behavior, identity limits,
durable import manifest, and local/remote failure semantics.

## Authentication boundary

Authentication and Google API authorization are distinct concepts and are
represented separately.

```text
No Tasks authorization
Connecting
Connected + authorized for Tasks
Connected but authorization refresh pending
Authorization rejected or expired
Authorization request failed
```

Android uses Flutter's maintained `google_sign_in` plugin and its authorization
client for the Google Tasks scope. The current plugin uses Android Credential
Manager for sign-in, exposes explicit scope authorization, and owns its platform
authorization state. Axiotask does not receive or persist an Android refresh
token. This choice must pass an early physical-device proof: interactive
connect, lightweight restore, authorized `tasklists.list`, expiration/refresh
behavior, cancellation, process restart, and stopping/resuming synchronization.
Failure of that proof stops dependent work; it does not justify a private
half-implementation of Google's SDK.

Linux uses the external system browser, Authorization Code flow with PKCE,
random state, and a loopback redirect on an ephemeral port. It also requests a
DPoP-bound refresh token: a per-installation P-256 key signs a fresh proof for
each token exchange/refresh, including Google's returned nonce. Google currently
keeps resource access tokens as bearer tokens, so DPoP protects refresh-token
replay rather than changing Tasks API calls. The key and refresh token are kept
together in secure storage.

The `oauth2` package handles grant/credential mechanics behind a DPoP-aware HTTP
client; a maintained JOSE implementation creates standards-compliant ES256
proofs. The application owns browser launch, callback validation, nonce/key
lifecycle, safe cancellation, typed errors, and credential persistence. This
composition must pass Google endpoint integration tests before adoption.
Embedded web views and custom URI workarounds are not used.

On Linux, the refresh token and DPoP private key are stored through
`flutter_secure_storage` backed by GNOME Secret Service through libsecret.
Android authorization remains owned by `google_sign_in`. Access tokens remain
in memory unless a platform API manages them. A secure-store failure cannot fall
back to a plaintext file.

Stopping synchronization is not sign-out or authorization revocation. It
persists an account-scoped `syncEnabled = false`, prevents new runs, requests
cancellation of an active run at the next safe boundary, and leaves
authorization, cached tasks, and pending desired state untouched. Task editing
remains fully available and continues to update/coalesce durable desired state
while synchronization is stopped. Resuming sets the flag and schedules an
immediate catch-up run. The application does not initially provide account
removal, sign-out, or authorization-revocation workflows.

Required OAuth configuration is validated before connection starts. Missing or
malformed configuration disables connection with an actionable setup result;
there are no silent defaults.

## Error model

Expected failures cross subsystem boundaries as a sealed `Failure` value, not
an arbitrary exception string. Each failure carries:

- stable diagnostic code;
- safe category (`network`, `authorization`, `rateLimit`, `remote`,
  `persistence`, `configuration`, `unsupportedRemoteState`, or `internal`);
- typed operation context;
- transient/permanent/unknown retry classification;
- a concrete user-facing impact and optional action when one actually exists;
- a production-safe diagnostic summary;
- development-only sensitive context when the debug composition enables it.

Programmer defects still throw and fail tests. Low-level exceptions are mapped
once at their adapter boundary. Release UI messages explain impact and action
rather than dumping stack traces, SQL, HTTP bodies, or filesystem paths. Debug
builds additionally expose the detailed local event log described under
Observability; this deliberate development behavior is never enabled by a
runtime switch in a release build.

Persistence and authorization failures are never silently converted to
defaults. Corrupt non-critical preferences may be quarantined and reset to a
documented default; sync-critical records may not.

## Synchronization boundary and scheduling

`SyncCoordinator` is a session-level component that receives typed triggers:

- application startup after local state is readable;
- foreground resume;
- connectivity may-have-returned;
- durable local mutation committed;
- explicit user retry/refresh;
- foreground cadence while the application remains active.

When synchronization is enabled, it coalesces bursts, permits only one engine
run, and remembers triggers that arrive during a run. A local mutation gets a
five-second trailing debounce capped at ten seconds from the burst's first
mutation. A task deletion is durably Undoable for 30 seconds and is ineligible
for remote dispatch until that boundary; unrelated work is not delayed.
Foreground cadence is five minutes; resume and explicit retry are immediate.
Android has no periodic background worker. Exact phase, timeout, and retry
behavior is normative in `SYNC_SPEC.md` and tested with injected time and
randomness.

The cadence is not silently stretched for large accounts. Because Google offers
no verified lossless change cursor, every scheduled verification traverses the
required pages. If documented quota, account size, latency, or the run deadline
prevents completion, health becomes Failed and no partial run is presented as
successful. Request-cost and maximum-page fixtures make that accepted scale
consequence visible before implementation.

Connectivity state is only a hint to schedule work. A Wi-Fi or cellular signal
does not prove internet or Google availability. Only an authenticated Google
request and a completed sync run can establish remote health.

`SyncEngine` receives the local store, Google Tasks port, authorization source,
clock, and run request. It returns a typed report. It has no dependency on
Flutter, view models, current selection, editing focus, or navigation.

## Truthful sync health

`SyncHealth` is a first-class projection, not a decorative boolean. It combines:

- whether synchronization is enabled;
- account/authorization state;
- current run phase;
- last attempt and last verified successful completion;
- latest failure since that success;
- durable pending and uncertain operation counts;
- foreground/connectivity hint;
- the latest explicit failure reason.

Those facts produce exactly four top-level outcomes:

1. **Inactive** — synchronization is stopped or usable Tasks authorization is
   absent. The reason is mandatory: `syncStopped` or `noAuthorization`.
2. **Failed** — the latest required completed attempt failed or timed out, or a
   previously good result exceeded its freshness deadline and verification is
   not actively running. The reason distinguishes `noConnection`,
   `remoteFailure`, `applicationFailure`, and `stale`; any pending count remains
   visible.
3. **Pending** — authorization is usable and a nonfailed run/verification is
   active or immediately queued, a retry request is executing, or durable work
   awaits an eligible immediate run. Waiting for retry backoff remains Failed.
4. **Good** — synchronization is enabled, authorization is usable, the latest
   forced or scheduled required run succeeded less than five minutes ago, and
   there is no newer failure, active/queued work, pending desired state, or
   uncertain outcome.

Evaluation uses that order except that an actively running retry is Pending
rather than Failed. Connectivity is evidence for scheduling only and never
produces Good. Startup and every foreground resume require verification, so
cached data starts Pending. A monotonic run deadline prevents a hung request
from remaining Pending forever; timeout becomes Failed. The persisted
last-success wall time and a monotonic in-session five-minute freshness deadline
ensure an old success cannot remain Good. `SYNC_SPEC.md` fixes a 30-second
request timeout and two-minute run deadline without weakening these rules.

The authorization adapter is the only authority for `noAuthorization`. It emits
that reason when credentials are absent, the Tasks scope is absent, or Google
terminally rejects refresh/authorization. A network error or timeout is Failed,
not No authorization. Token presence, connectivity, and a successful lightweight
sign-in never produce Good; only completion of the full required sync run does.
Pending work comes from durable database counts and coordinator state, never
transient widget state.

A sync may publish remote pages incrementally. Before a failure is detected,
health remains Pending while required phases/pages are incomplete. Detection of
any failure changes health to Failed immediately, even if independent safe work
continues. The last verified-success timestamp does not advance. Incremental
publication must remain transactionally valid and restart-safe, but the UI is
allowed to show the partial newer data with the non-green status.

Good means that the available Google synchronization procedure completed
successfully; it does not claim an atomic server snapshot that the API does not
provide. Presentation says “Synced” with the exact completion time rather than
the absolute claim “Up to date.”

Health is stored/projected below the UI so desktop and Android cannot disagree
about its meaning. The accepted Stage 4 specification defines exact state
transitions and stale timing.

## Startup and lifecycle

1. Initialize privacy-safe diagnostics and validate local paths.
2. Open and validate SQLite without destructive fallback.
3. Render cached account-scoped data with health Pending or Inactive.
4. Initialize the platform authorization adapter and secure storage.
5. Start repository subscriptions and the serialized sync coordinator.
6. If authorized, request a foreground verification run.

Partial initialization failures produce a usable recovery surface where safe.
For example, auth configuration failure can show cached data as Inactive with
reason `noAuthorization`, whereas database failure cannot show an invented empty
task list.

`AppLifecycleListener` provides resume/hide/exit signals. Exit may request a
bounded flush, but correctness never depends on receiving an exit callback;
every acknowledged mutation is already durable.

The Linux adapter keeps coordinator eligibility tied to the running process,
not window focus, visibility, or minimization. View-focus facts remain
observable for presentation tests only. A best-effort exit notification cancels
an active read through the transport and prevents new requests, while hard exit
uses the same durable restart model without requiring that notification.
`connectivity_plus` is mapped only to `provenNoRoute` and
`mayHaveReturned` hints: an available interface never establishes reachability
or healthy synchronization.

## Navigation and adaptive presentation

The initial navigation surface is small enough for Flutter's `Navigator` APIs;
`go_router` is not justified until deep links or route complexity demonstrate
a need. Desktop and Android share route concepts and ViewModels but own separate
shell/layout widgets selected by capabilities and width, not platform-name
checks alone.

Detailed interaction requirements live in [UX.md](UX.md).

## Testing architecture

All boundary interfaces have deterministic fakes. A stateful strict
`FakeGoogleTasksService` models pagination, etags, remote mutation, partial
success, lost responses, authorization expiry, rate limiting, malformed data,
and injected interleavings. The same behavior contract is exercised against the
HTTP adapter and, where safe, the opt-in real API harness.

Clocks, trigger scheduling, connectivity, lifecycle, authorization, secure
storage, external URL opening, and database connections are injected. Tests do
not patch global platform channels unless they are specifically adapter tests.

See [TESTING.md](TESTING.md) for the verification layers and isolation rules.

## Observability and privacy

Synchronization emits structured events with stable codes, run/operation IDs,
phase, duration, counts, and typed failure reasons. Logging has two deliberately
different products:

- **Release product:** a bounded local diagnostic history contains only
  production-safe summaries. It excludes task content, account details, raw
  request/response bodies, SQL values, raw remote IDs, and full URLs. The user
  can inspect, copy, export, and clear this safe history from Diagnostics.
- **Development product:** a debug-only sensitive sink records the information
  needed to reconstruct failures. It does not sample or suppress errors or
  boundary/state transitions: it includes task titles/notes, decoded Google
  request and response data, redacted authorization state/errors, remote IDs,
  desired-state/attempt/coordinator transitions, database operations/values,
  repository/UI commands, stack traces, and timing. A visibly marked in-app
  Diagnostics surface provides live viewing, search, copy/export, and clear
  without requiring a terminal or filesystem access.

Credential scrubbing is unconditional. Neither product may log access or
refresh tokens, authorization headers or codes, client secrets, PKCE verifiers,
DPoP private keys, secure-store values, or unredacted OAuth callback URLs. The
development sink is compiled/composed only into debug development builds; a
release build has no runtime flag capable of enabling it. Both histories are
bounded and local, exports are explicit, and there is no telemetry, remote
logging, crash upload, or automatic diagnostics upload.

## Composition and build modes

The production composition root is the only place that constructs concrete
plugins and storage paths. Test and screenshot entry points construct the same
application with temporary stores, synthetic accounts, fake time, and fake
Google services.

Test/demo composition and sensitive development diagnostics are enabled by
separate Dart entry points used only in debug/test builds, not by a runtime
secret flag in production. Release verification proves that the sensitive sink
and its detailed renderers are unreachable from the production composition.

## Sources informing this design

- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)
- [Flutter architecture guide](https://docs.flutter.dev/app-architecture/guide)
- [Flutter application lifecycle API](https://api.flutter.dev/flutter/widgets/AppLifecycleListener-class.html)
- [Google OAuth for installed applications](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google OAuth security practices](https://developers.google.com/identity/protocols/oauth2/resources/best-practices)
- [OAuth DPoP (RFC 9449)](https://datatracker.ietf.org/doc/rfc9449/)
- [Google Tasks v1 task resource](https://developers.google.com/tasks/reference/rest/v1/tasks)
- [Google Tasks v1 list method](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list)
- [Google Tasks product help](https://support.google.com/tasks/answer/7675772)
- [Google Tasks recurrence help](https://support.google.com/tasks/answer/12132599)
- [Drift](https://pub.dev/packages/drift)
- [Flutter secure storage](https://pub.dev/packages/flutter_secure_storage)
- [Connectivity Plus warning and API](https://pub.dev/packages/connectivity_plus)
