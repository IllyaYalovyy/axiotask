# Synchronization specification

- Status: **Draft**
- Scope: foundational state, authority, persistence, and component boundaries
- Updated: 2026-08-10

## Purpose and scope

This draft defines what local and remote state mean before later sections choose
conflict outcomes, mutation ordering, retry/backoff behavior, or implementation
details. It is normative for the state and authority model only.

Normative inputs are [VISION.md](../VISION.md), the accepted
[target architecture](ARCHITECTURE.md), accepted ADRs, and the verified
[Google Tasks API contract](GOOGLE_TASKS_API_CONTRACT.md). The Rust/Tauri
synchronization documents were reviewed as read-only historical evidence of
failure modes. Their schema, push-first order, conflict-copy behavior, automatic
hierarchy repair, timing, and unverified Google assumptions are not adopted by
this draft.

This draft deliberately does **not** decide:

- conflict resolution or field/row merge behavior;
- push-versus-pull ordering or mutation dependencies;
- retry eligibility, backoff, cadence, freshness duration, or timeouts;
- recovery of an uncertain create or other uncertain remote mutation;
- cross-list move decomposition;
- import/export merge policy.

Those decisions require later specification sections and, where identified by
the API contract, controlled Google probes.

## Core terms

| Term | Meaning |
|---|---|
| Remote system of record | Google Tasks is the durable cross-device system for every supported list and task. Axiotask does not create a second permanent task universe. |
| Confirmed remote state | A validated Google resource representation that has been committed locally as the last known remote result. “Confirmed” does not mean current forever. |
| Local cache | The account-scoped SQLite representation used for responsive reads, offline continuity, confirmed remote bases, projected local state, operations, and sync evidence. It is not an alternate backend. |
| Remote base | The last confirmed Google representation against which a later local intent and remote observation can be compared. |
| Durable pending intent | An acknowledged local request that has committed to SQLite but has not yet received a transactionally recorded remote confirmation. |
| Projected state | The user-visible local task/list state after applying acknowledged local intent to the last confirmed base. It may be newer than Google and must be shown with non-green health until confirmed. |
| Fresh | A complete required sync run succeeded inside the configured freshness window, with no newer fact invalidating it. The duration remains unresolved. |
| Stale | The last confirmed remote state is older than the freshness boundary or a newer failure means currentness cannot be claimed. |
| Uncertain outcome | A remote mutation may have committed, but the client lacks durable evidence proving committed or not committed. |
| Attention | Automatic progress is intentionally blocked because safe resolution requires user action, a product decision, or new verified capability evidence. Attention is a reason/state below the four top-level health outcomes, not a fifth health color. |

“Connected” is not a single authority state. Authorization, transport
reachability, freshness, active work, and remote confirmation are independent
facts. Token presence or a connectivity signal never establishes current remote
state.

## Authority model

Google is authoritative for the last **confirmed** cross-device state of a
supported resource. SQLite is authoritative for whether Axiotask acknowledged a
local request and for all evidence needed to avoid forgetting, duplicating, or
misrepresenting that request. These authorities cover different facts:

- Google answers “what remote state has been confirmed?”
- the durable local operation answers “what did Axiotask acknowledge that is
  not yet confirmed?”
- the projected row answers “what should the UI display after that acknowledged
  local request?”
- sync evidence answers “may this display be called current?”

Remote authority does not permit a pull to erase durable pending intent. Local
intent does not make Axiotask an independent system of record and does not by
itself decide a conflict against a newer remote change. The later conflict
policy must reconcile both facts without silently discarding acknowledged work,
except where an explicitly accepted product rule applies.

### Authority by operating condition

| Condition | Authoritative facts | UI interpretation |
|---|---|---|
| Fresh, authorized, no unresolved work | Confirmed remote base and projected state agree; complete-run evidence establishes freshness. | Good is possible. |
| Authorized with pending or in-flight intent | The remote base remains the last confirmed Google state; durable intent and projected state represent the acknowledged local delta. | Pending; the projection is not yet claimed to exist in Google. |
| Disconnected | The cache remains the last known remote state; durable intent remains authoritative evidence of acknowledged work. Connectivity supplies no remote confirmation. | Never Good. Cached and projected data remain usable with an explicit offline reason. |
| Stale | The base remains historical evidence, not a currentness claim. Pending intent remains durable. | Failed when verification is not actively repairing it; Pending while a required verification is active. |
| Uncertain mutation | Neither a retry nor local cleanup may assume whether Google committed. Base, intent, and uncertainty evidence all remain intact. | Never Good; show uncertainty and its affected count. |
| Conclusive failed attempt | The attempt outcome is authoritative evidence that this attempt did not confirm the operation. It does not erase the acknowledged intent. | Failed unless an active recovery run makes the current outcome Pending. |
| Synchronization stopped | Cache, bases, authorization, and operations remain intact; no new Google request begins. | Inactive with reason `syncStopped`, plus any unresolved counts. |
| No usable Tasks authorization | Cache and operations remain intact; the authorization adapter is authoritative for the missing/terminal authorization fact. | Inactive with reason `noAuthorization`, plus any unresolved counts. |
| Unsupported or malformed remote data | The validated portion may be retained, but the affected scope is not confirmed complete and the unsupported resource is not mutated. | Failed with an attention reason; never Good from that run. |

A completed API request is not automatically a completed sync run. A run may
publish validated partial data, but only completion of every required phase and
page can advance the last verified-success fact. The API does not document
snapshot isolation across pages, so “complete” currently means complete
execution of the specified retrieval strategy—not an unproven globally atomic
Google snapshot.

## Identity and account isolation

### Account identity

Each account partition has an opaque stable local account key and one verified
Google subject identifier. The Google subject, not an email address or display
name, binds remote data to its partition. OAuth credentials remain outside
SQLite, but their resolved subject must match the partition before remote data
is read into or written from it.

Every list, task, remote base, operation, sync attempt, attention record, and
account-scoped preference belongs to exactly one account partition. Foreign
keys, queries, uniqueness constraints, and repository APIs must carry or derive
that account scope. Cross-account joins in user-visible task queries are
forbidden.

The initial product exposes one configured account and no account switching.
The model supports multiple isolated partitions so future multi-account support
does not require replacing task/list identity. If the authorization adapter
returns a different subject unexpectedly, synchronization stops before remote
data access; it must not silently switch or merge partitions.

### List and task identity

Every list and task receives an opaque SQLite-assigned 64-bit local key before
any Google request. Local keys are installation-local and never sent as Google
resource IDs. UI selection, navigation, parent references, operation targets,
and repository relationships use local keys.

The Google resource ID is nullable external metadata:

- `remoteId == null` is valid only for a provisional resource covered by a
  durable create intent, or transiently inside the transaction creating both;
- `remoteId != null` binds the local object to a Google resource within its
  account and resource type;
- assigning a returned Google ID never changes the local key;
- assigning/remapping a Google ID and confirming its operation is one local
  transaction;
- a durable resource with neither a remote ID nor a create intent is an
  invariant violation, not a local-only list/task.

Remote-key uniqueness is account- and resource-type-scoped as required by ADR
0002. The Google contract does not establish task-ID behavior during cross-list
moves, so the later move specification must not assume stability or replacement
until probe P7 resolves it.

## Domain, projected, and remote-base state

### Supported domain state

A task list contains stable local/account identity, optional Google identity,
its user-visible title, projected lifecycle, last confirmed remote base, and
references to unresolved operations.

A task contains stable local/account identity, its local list key, an optional
local parent key, title, notes, `needsAction`/`completed` status, an optional
date-only due value, projected lifecycle, last confirmed remote base, and
references to unresolved operations. Google output such as opaque position,
hidden/deleted flags, completion timestamp, updated timestamp, links, and
optional `webViewLink` is remote metadata, not a reason to expose unsupported
domain behavior.

Due is a calendar date. The domain does not model a Google Tasks due time or
deadline because the documented API discards and cannot return that time.
Exact wire normalization remains gated on API-contract probe P9.

Projected state is materialized so repository streams and restart behavior are
deterministic. It must always be transactionally consistent with the operation
records that explain why it differs from the remote base. Projection does not
change merely because a widget opens, closes, focuses, or has uncommitted text.

### Remote bases and ETags

A remote base is account- and local-resource-scoped. It records the validated
Google values required to identify the last agreement point, together with the
remote ID, remote ETag if supplied, remote `updated` value if supplied, and the
sync attempt that observed it. Task bases include supported content and
structure values needed by later reconciliation; list bases include the title
and relevant remote version metadata.

The following invariants apply:

1. Base content and its ETag/version metadata are one unit and change in one
   transaction.
2. A resource Google has never confirmed has no remote base.
3. Starting a local edit does not overwrite its base.
4. A pending operation identifies the base against which its intent was formed,
   even if later local commands coalesce it; exact coalescing is unresolved.
5. A validated mutation response may update the base only through the operation
   acknowledgement transaction.
6. A malformed, unsupported, partial, or ambiguously committed response cannot
   advance the base as though the operation were confirmed.
7. Collection ETags are not change cursors; the API contract documents neither
   their conditional semantics nor what changes them.
8. Resource ETag presence does not prove that PATCH, UPDATE, DELETE, or MOVE
   honors `If-Match`. Conditional policy remains blocked on probes P1/P2.

The exact base field set is finalized with conflict policy. Omitting a field
that can distinguish a real remote change from server normalization is not
allowed merely to simplify persistence.

## Durable operations and attempts

A durable operation is the local proof of an acknowledged, unconfirmed request.
It is not an HTTP request object and does not store credentials, raw URLs, raw
responses, or task text in diagnostics.

Every operation must carry enough typed information to recover after restart:

- stable local operation key and account key;
- target resource type and stable local target key;
- operation kind and normalized intent/payload;
- the relevant remote ID and base reference/ETag, when known;
- local dependency references needed to express list/parent/sibling ordering;
- lifecycle state and local causal sequence;
- safe attempt/uncertainty/failure metadata;
- creation and last-transition times from the injected clock.

Dependencies use local keys. A task create may therefore depend on a provisional
list or parent without rewriting UI identity when Google later assigns IDs.
Exact operation decomposition and ordering are deferred.

A sync attempt is separate evidence: it records one engine run or one remote
mutation attempt, its phase, start/end outcome, safe failure classification,
and association with operations. Attempt history must not be confused with
current operation state.

### Operation lifecycle states

| State | Meaning | Durable consequence |
|---|---|---|
| `pending` | Locally acknowledged and not currently claimed by a remote attempt. | Contributes to unconfirmed count and prevents Good. |
| `inFlight` | Ownership of a remote attempt was recorded before a request could produce a side effect. | Prevents another engine run from blindly issuing the same operation. |
| `uncertain` | Google may have committed, but the client cannot prove either outcome. | Intent, base, attempt evidence, and projected state remain; blind replay and silent clearing are forbidden. |
| `failed` | The latest attempt has a conclusive non-success outcome; unlike `uncertain`, evidence establishes that Google did not confirm that attempt. | Intent remains unresolved with a typed failure; retry/terminal policy is deferred. |
| `attention` | Safe automatic progress is blocked pending user action, product policy, or capability evidence. | The underlying durable fact survives restart and cannot be cleared by reopening the app. |
| `confirmed` | A Google success result and its local consequences were committed atomically. | No longer contributes to pending/uncertain counts; retention/compaction is unresolved. |

`confirmed` is remote confirmation. It is distinct from local acknowledgement,
which creates `pending`.

```text
local transaction commits
          │
          ▼
       pending ───────► inFlight ───────► confirmed
                           │
                           ├────────────► uncertain
                           └────────────► failed

pending ─────────────────────────────────► failed
failed/uncertain ──► pending | confirmed | attention
attention ─────────► pending | confirmed
```

Transitions on the final two lines are placeholders for later recovery,
conflict, and retry policy; they are possibilities, not selected behavior.
No transition may discard acknowledged intent without an explicit resolution.

An `inFlight` operation left by process loss becomes `uncertain` on startup
unless durable transport evidence proves the request could not have left the
device. Merely failing to receive a response is not such proof. If Google
returns success but the local acknowledgement transaction fails, the prior
durable `inFlight` evidence likewise makes the outcome uncertain.

## Transactional acknowledgement of local mutations

A repository command acknowledges a local mutation only after one SQLite
transaction commits all required local consequences:

1. validate account, resource, and one-level hierarchy invariants;
2. read the current projection and relevant remote base;
3. write the new projected list/task state;
4. create or update the durable operation and its dependencies;
5. make the operation visible to pending-count and health queries;
6. commit.

Only after commit may the command return success and repository streams publish
the projected state. If the transaction fails, the command returns a typed
persistence failure and must not report success or publish a projection that
lacks durable intent.

The post-commit sync trigger is a scheduling optimization, not the durability
mechanism. If the process dies after commit but before notifying the coordinator,
the pending record remains discoverable at startup, resume, and the next
foreground scheduling opportunity. Correctness therefore never depends on an
exit callback or an in-memory event.

Remote acknowledgement also uses one transaction: validate the response,
update remote ID/base/ETag and projected state as allowed by later policy,
transition the operation to `confirmed`, and record attempt consequences. A
crash cannot leave a remote ID rebound while the operation still appears safe
to issue as a new create.

## Structural synchronization phases

This phase model defines responsibilities, not push/pull ordering:

| Phase | Required structural result |
|---|---|
| Eligibility | Resolve account partition, durable `syncEnabled`, Tasks authorization state, startup recovery, and whether a run is permitted. No network health is inferred. |
| Begin attempt | Create a durable run identity/start record and claim eligible work without overlapping another run for the configured account. |
| Remote exchange | Acquire validated authorization for requests, enumerate required remote pages, and/or execute selected durable operations. Exact ordering and batching are unresolved. |
| Validate and stage | Strictly decode resource fields, associate account/identity, defer parent resolution until enough of the required view is available, and track page/scope completeness. |
| Transactional publish/acknowledge | Commit internally valid remote batches and operation outcomes without overwriting concurrent local intent. No transaction spans network IO. |
| Finalize | Produce a typed run report. Advance last verified success only if every required phase/page completed and no unsupported, malformed, uncertain, or failed requirement invalidates the run. |

Validated pages may be published incrementally. Until finalization succeeds,
health remains non-green and the prior last-success timestamp remains unchanged.
Destructive “missing remotely” conclusions require a complete applicable remote
view and must not run after pagination, validation, or unsupported-data failure.
The API contract leaves concurrent-pagination consistency unresolved, so the
exact completeness algorithm is blocked on probe P3.

On startup, a durable run with no final outcome is marked interrupted. Its
claimed `inFlight` operations are treated under the uncertainty rule above.
Startup does not pretend the abandoned process is still synchronizing.

## SyncCoordinator and SyncEngine boundary

| SyncCoordinator owns | SyncEngine owns |
|---|---|
| Observing startup, foreground resume, connectivity hints, committed-mutation notifications, explicit refresh/retry, and foreground cadence. | Executing one account-scoped run against the local sync store, authorization port, Google Tasks port, and clock. |
| Reading `syncEnabled`, coalescing triggers, and allowing at most one active run for the configured account. | Recovering/claiming operation states and performing the structural phases above. |
| Remembering that another run is required when a trigger arrives during a run. | Strict wire validation, completeness evidence, transactional publication/acknowledgement, and typed run reports. |
| Requesting cancellation at engine-declared safe boundaries and enforcing an outer run deadline. | Honoring cancellation only at safe boundaries; never abandoning an open local transaction. |
| Projecting runtime scheduling facts used by SyncHealth. | Reporting facts; it does not choose UI wording, schedule itself, or mutate coordinator state. |

The coordinator does not interpret task conflicts, mutate task/base/operation
rows, infer success from connectivity, or call widgets. The engine does not
read lifecycle APIs, navigation, selected task, focus, editor buffers, or
ViewModels. Repository transactions are the only path from user intent into
durable sync work.

Retry scheduling is intentionally absent from this boundary draft. Later policy
must place it without allowing two retry layers or weakening serialized runs.

## UI-observable state

The UI may observe only typed, account-scoped repository projections:

- projected supported task lists and tasks keyed by stable local identity;
- whether a displayed value has unresolved local intent, when needed for a
  specific interaction, without exposing wire mechanics on every row;
- aggregate pending, in-flight, uncertain, failed, and attention counts;
- `SyncHealth`, current safe phase/activity, last attempt, and exact last
  verified-success time;
- sanitized failure category, impact, whether user action is required, and an
  allowed recovery action;
- a typed unsupported-remote-state notice.

The UI does not observe OAuth tokens, ETags, raw HTTP status/body/message, page
tokens, SQL errors/values, operation payload internals, or raw remote IDs. It
does not decide that a task is confirmed based on a successful button command;
the command confirms only the local transaction.

Uncommitted editor text remains ViewModel/UI state and is not synchronizable.
Closing an editor cannot be a precondition for sync. A Save/apply action becomes
synchronizable only through the repository transaction defined above.

## Truthful SyncHealth

`SyncHealth` is a projection of facts below the UI, evaluated per configured
account. Its inputs are:

- durable `syncEnabled`;
- authorization adapter state, including Tasks scope and terminal rejection;
- foreground/resume verification obligation and connectivity hint;
- coordinator active/queued state and current engine phase;
- durable last attempt and last verified-success time;
- freshness boundary and monotonic active-run deadline;
- newest failure after the last verified success;
- counts of `pending`, `inFlight`, `uncertain`, `failed`, and `attention` work;
- whether user action is required.

It produces exactly the accepted four top-level outcomes:

| Outcome | Exact foundational rule |
|---|---|
| **Inactive** | `syncEnabled=false`, or the authorization adapter says usable Tasks authorization is absent/terminally rejected. Reason is mandatory: `syncStopped` or `noAuthorization`. Unresolved counts remain visible. |
| **Failed** | The latest required completed attempt failed/timed out; attention is unresolved; a conclusive failed operation is not actively being repaired; or freshness expired without active verification. Last success and unresolved counts remain visible. |
| **Pending** | Authorization is usable and required verification, an active/queued run, or durable unconfirmed work exists, provided no higher-priority non-active failure makes the outcome Failed. Active recovery after failure is Pending. |
| **Good** | Sync is enabled; authorization is usable; a complete required run succeeded inside the freshness window; connectivity is not known unavailable; and there is no newer failure, required verification, active/queued work, or pending/in-flight/uncertain/failed/attention operation. |

Evaluation order is Inactive, Failed, Pending, Good, with the accepted exception
that an active recovery run is Pending rather than Failed. A known disconnected
hint invalidates Good and creates a verification obligation, but does not prove
an API failure. If freshness expires before active verification, the result is
Failed; while verification is active it is Pending.

Additional invariants:

- startup and every foreground resume require verification, so cached data
  starts Pending or Inactive, never Good;
- token presence, sign-in restoration, and connectivity cannot produce Good;
- only the authorization adapter can produce `noAuthorization`; network errors
  remain Failed;
- a hung run becomes Failed at its monotonic deadline;
- partial publication does not advance last verified success;
- `confirmed` history does not count as unresolved work;
- process restart re-derives runtime phase from durable attempts/operations and
  cannot clear durable failure/attention evidence merely by resetting memory.

## One supported subtask level

The domain permits either:

- a top-level task with no parent; or
- a subtask whose parent is a top-level task in the same account and list.

Local commands reject a parent that is itself a subtask, a cross-account parent,
a cross-list parent, or a deleted/unsupported parent before acknowledgement.
Parent relationships use stable local keys; Google parent IDs are adapter
metadata.

No normal domain object represents a third level. This is a product constraint,
not an assumption that the Google API enforces it.

### Unexpected remote structure or data

Remote page order is not a hierarchy contract. A child seen before its parent
is deferred until the required remote scope supplies enough data to validate the
relationship; it is not immediately orphaned, flattened, or deleted.

If a complete applicable view contains a deeper hierarchy, invalid identity,
unknown required enum, malformed resource, assigned task despite the explicit
filter, or another unsupported relationship:

1. the adapter/engine records a typed account-scoped unsupported observation;
2. the unsupported resource is not moved, patched, deleted, promoted, or
   rewritten;
3. no local proxy, local-only list, or destructive flattened copy is created;
4. the last valid cached projection for previously known supported resources is
   retained;
5. destructive absence processing is disabled for the affected incomplete
   scope;
6. the run cannot become Good or advance last verified success;
7. the UI receives only a sanitized attention notice and safe recovery action.

Whether a brand-new unsupported resource receives a read-only placeholder or
only a global attention notice is unresolved. Either presentation must avoid
claiming edit support and must not hide the unhealthy sync state.

## Crash and persistence invariants

1. No transaction spans network IO.
2. Local acknowledgement always implies durable projected state plus durable
   intent; neither may exist alone after commit.
3. Remote confirmation always updates identity/base/operation consequences in
   one transaction.
4. Process loss cannot convert `inFlight` to `pending` without evidence that no
   side effect could have reached Google.
5. Partial or malformed remote data cannot justify destructive absence
   processing or last-success advancement.
6. Concurrent repository edits cannot be overwritten by an engine write based
   on an older read. The final local transaction must re-check the current
   operation/projection version.
7. A database open/write failure is visible and preserves recoverable data; no
   empty-cache or preference-store fallback is allowed.
8. Every unresolved record remains account-scoped and discoverable after
   restart.
9. Diagnostics contain stable codes and aggregate metadata, never task content,
   account email, credentials, raw bodies, SQL values, or full request URLs.

## Explicit non-goals

- Local-only lists or tasks that permanently bypass Google Tasks.
- Treating offline continuity as a second backend.
- Cross-product assigned/shared tasks from Docs or Chat.
- More than one supported subtask level.
- Destructive flattening or automatic repair of unsupported remote hierarchy.
- Periodic Android background synchronization; Android catches up in foreground
  and on resume.
- Webhooks or real-time server push not exposed by the public API.
- Recurrence configuration through the public API.
- UI/editor state influencing synchronization eligibility.
- Account switching in the initial product.
- Conflict-copy behavior inherited from Rust.
- A generic HTTP retry interceptor or retry policy in this draft.

## Unresolved foundational questions

These questions must be resolved in later Stage 4 work; this Draft does not
silently answer them:

1. **Mutation representation:** should repeated local commands coalesce into one
   desired-state operation per resource, remain an ordered operation log, or use
   a narrowly defined hybrid? This determines the first synchronization schema.
2. **Stopped-sync editing:** while synchronization is explicitly stopped, may
   users continue mutating cached Google data and accumulate pending intent, or
   should task mutation become read-only until Resume?
3. **Confirmed-operation retention:** how much confirmed operation/attempt
   history is retained for crash evidence and diagnostics before compaction?
4. **Unsupported-data presentation:** should a new unsupported remote resource
   appear as a read-only placeholder, or only as a global attention item?
5. **Automatic recovery boundary:** which conclusive failures become pending
   again automatically and which become attention? This belongs with retry and
   failure policy.
6. **Conflict authority:** how remote base, current remote observation, and
   durable local intent resolve for every mutation crossing—including the
   already established delete principle—belongs to the conflict-policy draft.
7. **Completeness evidence:** probe P3 must establish what pagination can prove;
   until then the specification cannot claim an atomic remote snapshot.
8. **Uncertain mutation recovery:** probes P1/P2/P5–P8 must establish conditional
   and identity behavior before create/move/delete uncertainty can be resolved
   safely.
