# Synchronization specification

- Status: **Draft**
- Scope: foundational state, authority, persistence, reconciliation, and component boundaries
- Updated: 2026-08-11

## Purpose and scope

This draft defines what local and remote state mean and the automatic
reconciliation policy. Retry timing, detailed run ordering, and implementation
remain later work.

Normative inputs are [VISION.md](../VISION.md), the accepted
[target architecture](ARCHITECTURE.md), accepted ADRs, and the verified
[Google Tasks API contract](GOOGLE_TASKS_API_CONTRACT.md). The Rust/Tauri
synchronization documents were reviewed as read-only historical evidence of
failure modes. Their schema, push-first order, conflict-copy behavior, automatic
hierarchy repair, timing, and unverified Google assumptions are not adopted by
this draft.

This draft deliberately does **not** decide:

- push-versus-pull ordering or mutation dependencies;
- retry eligibility, backoff, cadence, freshness duration, or timeouts;
- import/export merge policy.

Those decisions require later specification sections and, where identified by
the API contract, controlled Google probes.

## Core terms

| Term | Meaning |
|---|---|
| Remote system of record | Google Tasks is the durable cross-device system for every supported list and task. Axiotask does not create a second permanent task universe. |
| Confirmed remote state | A validated Google resource representation that has been committed locally as the last known remote result. “Confirmed” does not mean current forever. |
| Local cache | The account-scoped SQLite representation used for responsive reads, offline continuity, confirmed remote bases, projected local state, desired-state records, and sync evidence. It is not an alternate backend. |
| Remote base | The last confirmed Google representation against which a later local intent and remote observation can be compared. |
| Durable pending intent | An acknowledged local request that has committed to SQLite but has not yet received a transactionally recorded remote confirmation. |
| Projected state | The user-visible local task/list state after applying acknowledged local intent to the last confirmed base. It may be newer than Google and must be shown with non-green health until confirmed. |
| Fresh | A complete required sync run succeeded inside the configured freshness window, with no newer fact invalidating it. The duration remains unresolved. |
| Stale | The last confirmed remote state is older than the freshness boundary or a newer failure means currentness cannot be claimed. |
| Uncertain outcome | A remote mutation may have committed, but the client lacks durable evidence proving committed or not committed. |
| Desired remote state | The latest acknowledged local state that Axiotask intends Google to hold for one resource. Repeated local edits coalesce into this state rather than accumulating an event log. |

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
- the durable desired-state record answers “what did Axiotask acknowledge that
  is not yet confirmed?”
- the projected row answers “what should the UI display after that acknowledged
  local request?”
- sync evidence answers “may this display be called current?”

Remote authority does not permit a pull to erase durable pending intent. Local
intent does not make Axiotask an independent system of record. The automatic
policy below reconciles both facts and records every accepted whole-record,
structural, or deletion loss explicitly.

### Authority by operating condition

| Condition | Authoritative facts | UI interpretation |
|---|---|---|
| Fresh, authorized, no unresolved work | Confirmed remote base and projected state agree; complete-run evidence establishes freshness. | Good is possible. |
| Authorized with pending or in-flight intent | The remote base remains the last confirmed Google state; durable intent and projected state represent the acknowledged local delta. | Pending; the projection is not yet claimed to exist in Google. |
| Disconnected | The cache remains the last known remote state; durable intent remains authoritative evidence of acknowledged work. Connectivity supplies no remote confirmation. | Never Good. Cached and projected data remain usable with an explicit offline reason. |
| Stale | The base remains historical evidence, not a currentness claim. Pending intent remains durable. | Failed when verification is not actively repairing it; Pending while a required verification is active. |
| Uncertain mutation | Neither a retry nor local cleanup may assume whether Google committed. Base, intent, and uncertainty evidence all remain intact. | Never Good; show uncertainty and its affected count. |
| Conclusive failed attempt | The attempt outcome is authoritative evidence that this attempt did not confirm the operation. It does not erase the acknowledged intent. | Failed unless an active recovery run makes the current outcome Pending. |
| Synchronization stopped | Cache, bases, authorization, and desired state remain intact; no new Google request begins. | Inactive with reason `syncStopped`, plus any unresolved counts. |
| No usable Tasks authorization | Cache and desired state remain intact; the authorization adapter is authoritative for the missing/terminal authorization fact. | Inactive with reason `noAuthorization`, plus any unresolved counts. |
| Unsupported or malformed remote data | The validated portion may be retained, but the affected scope is not confirmed complete and the unsupported resource is not mutated. | Failed with reason `applicationFailure` and a specific diagnostic code; never Good from that run. |

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

Every list, task, remote base, desired-state record, sync attempt, and
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
resource IDs. UI selection, navigation, parent references, desired-state
targets, and repository relationships use local keys.

The Google resource ID is nullable external metadata:

- `remoteId == null` is valid only for a provisional resource covered by a
  durable create intent, or transiently inside the transaction creating both;
- `remoteId != null` binds the local object to a Google resource within its
  account and resource type;
- assigning a returned Google ID never changes the local key;
- assigning/remapping a Google ID and confirming its desired state is one local
  transaction;
- a durable resource with neither a remote ID nor a create intent is an
  invariant violation, not a local-only list/task.

Remote-key uniqueness is account- and resource-type-scoped as required by ADR
0002. Controlled probe P7 moved single tasks and a parent subtree across lists
while preserving task IDs and carrying the child. Cross-list movement therefore
uses Google's `destinationTasklist` mutation and stable identity; it is not
decomposed into clone/delete. Because replay from the original list returned 404
after a landed move, uncertain recovery must read the destination by the same ID
before retrying or interpreting source absence.

## Domain, projected, and remote-base state

### Supported domain state

A task list contains stable local/account identity, optional Google identity,
its user-visible title, projected lifecycle, last confirmed remote base, and
references to unresolved desired state.

A task contains stable local/account identity, its local list key, an optional
local parent key, title, notes, `needsAction`/`completed` status, an optional
date-only due value, projected lifecycle, last confirmed remote base, and
references to unresolved desired state. Google output such as opaque position,
hidden/deleted flags, completion timestamp, updated timestamp, links, and
optional `webViewLink` is remote metadata, not a reason to expose unsupported
domain behavior.

Due is a calendar date. The domain does not model a Google Tasks due time or
deadline because the documented API discards and cannot return that time.
Controlled probe P9 establishes the wire spelling: encode the product date as
UTC midnight and expect `00:00:00.000Z`. Arbitrary local-offset timestamps are
forbidden because Google first maps the instant to its UTC calendar date.

Projected state is materialized so repository streams and restart behavior are
deterministic. It must always be transactionally consistent with the
desired-state records that explain why it differs from the remote base.
Projection does not
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
4. A pending desired-state record identifies the base against which its intent
   was first formed. Later local commands replace its desired projection while
   retaining that base until remote confirmation or reconciliation explicitly
   rebases or supersedes it.
5. A validated mutation response may update the base only through the operation
   acknowledgement transaction.
6. A malformed, unsupported, partial, or ambiguously committed response cannot
   advance the base as though the operation were confirmed.
7. Collection ETags are not change cursors; the API contract documents neither
   their conditional semantics nor what changes them.
8. Controlled P1 evidence shows task PATCH, UPDATE, DELETE, and MOVE honor
   `If-Match`: stale returned 412 without mutation, while current/`*`/absent
   succeeded. P2 shows task-list PATCH, UPDATE, and DELETE ignore it. Task
   mutation policy may use preconditions; list conflict policy may not.

The exact base field set is finalized with conflict policy. Omitting a field
that can distinguish a real remote change from server normalization is not
allowed merely to simplify persistence.

## Durable desired state and attempts

A durable desired-state record is the local proof of an acknowledged,
unconfirmed result the user wants Google to hold. It is neither an HTTP request
object nor an append-only log of UI commands. There is at most one current
desired-state record per local resource. Repeated edits replace its desired
projection and increment its generation in the same transaction that updates
the visible projection.

Each desired-state record carries enough typed information to recover after
restart:

- stable local record key, account key, target resource type, and local target
  key;
- desired lifecycle (`present` or `deleted`) and the complete supported content
  and structural projection needed to reach that state;
- the original relevant remote base reference/ETag and remote ID, when known;
- local dependency references needed to express list/parent/sibling ordering;
- dirty content/structure/lifecycle facets, content or list-title
  `localModifiedAt`, lifecycle state, generation, and local causal sequence;
- attempt, uncertainty, and failure metadata;
- creation and last-transition times from the injected clock.

Dependencies use local keys. A task create may therefore depend on a provisional
list or parent without rewriting UI identity when Google later assigns IDs.
Edits made while synchronization is stopped use this exact path: they remain
fully available, update projected state immediately, and coalesce durably until
Resume schedules catch-up.

Claiming remote work snapshots the exact desired-state generation into a
durable attempt before issuing a request. A later local edit may advance the
current desired state without changing that attempt snapshot. This prevents an
in-flight or uncertain request from being misremembered while still avoiding an
event log. Exact decomposition into Google create/patch/move/delete calls and
dependency ordering are deferred.

A sync attempt is separate evidence: it records one engine run or remote
mutation attempt, the claimed desired-state generation, phase, start/end
outcome, typed failure classification, and association with the desired-state
record. Attempt history must not be confused with current desired state.

### Desired-state and attempt lifecycle states

| State | Meaning | Durable consequence |
|---|---|---|
| `pending` | Locally acknowledged and not currently claimed by a remote attempt. | Contributes to unconfirmed count and prevents Good. |
| `inFlight` | Ownership of a remote attempt was recorded before a request could produce a side effect. | Prevents another engine run from blindly issuing the same operation. |
| `uncertain` | Google may have committed, but the client cannot prove either outcome. | Intent, base, attempt evidence, and projected state remain until the operation-specific recovery policy confirms, supersedes, or explicitly retries it. |
| `failed` | The latest attempt has a conclusive non-success outcome; unlike `uncertain`, evidence establishes that Google did not confirm that attempt. | Intent remains unresolved with a typed failure; retry/terminal policy is deferred. |
| `confirmed` | A Google success result and its local consequences were committed atomically. | No longer contributes to unresolved counts. If no newer generation exists, the desired-state record may be removed/compacted in that transaction. |
| `superseded` | Reconciliation selected newer Google state or authoritative deletion instead of an acknowledged local facet. | The losing facet no longer contributes to unresolved counts. Its typed resolution remains in bounded attempt history; the desired-state record may be removed when no other facet remains. |

`confirmed` is remote confirmation. It is distinct from local acknowledgement,
which creates `pending`.

These labels are generation-scoped. The desired-state record exposes the state
of its newest generation, while an attempt retains the state and immutable
snapshot of the generation it claimed. If a user edits during an in-flight
attempt, the new generation is `pending` while the older attempt remains
`inFlight`. Confirmation of the older generation advances the remote base but
cannot clear or overwrite the newer pending generation.

```text
local transaction commits
          │
          ▼
       pending ───────► inFlight ───────► confirmed
          │                │
          └────────────────┴────────────► superseded
                           │
                           ├────────────► uncertain
                           └────────────► failed

pending ─────────────────────────────────► failed
failed/uncertain ─────────────────────────► pending | confirmed | superseded
```

The reconciliation policy below selects confirmation, supersession, or a new
pending attempt. Retry timing remains later work.
No transition may discard acknowledged intent without an explicit resolution.

## Automatic reconciliation and conflict policy

### Deliberately small model

Reconciliation uses four rules:

1. Task content is one record containing title, notes, due date, and completion
   status. It uses whole-record last-write-wins; fields are never independently
   merged.
2. List title is one record and uses the same last-write-wins rule.
3. Parent, list membership, and sibling order are structural state. If both the
   local desired structure and Google changed from the base, Google wins.
4. Deletion wins over every edit, move, reorder, completion change, and create
   dependency, regardless of timestamps.

This intentionally fits a personal task list rather than a collaborative text
system. There are no conflict copies, three-way notes merges, per-field clocks,
or routine conflict questions. More machinery is justified only by observed
failures that this policy cannot handle acceptably.

Each desired-state generation records independently whether content, structure,
or lifecycle is dirty. That is still one coalesced desired-state record, not an
operation log. It lets independent operations commute—for example, retaining a
remote move while applying newer local content—without mixing old and new text
fields. When local task content wins, the adapter writes every supported
writable content field and the verified clear representation for absent values;
it never sends a sparse changed-field patch that would accidentally retain part
of the losing remote snapshot.

### Timestamp rule

Each local content edit commits one UTC `localModifiedAt` for the complete task
content projection. A list rename does the same for its complete title record.
Google's output-only `updated` is the remote record timestamp. When both local
and Google content differ from the same remote base:

- local wins only when `localModifiedAt` is strictly later than Google
  `updated`;
- Google wins when its timestamp is later or equal;
- missing or malformed required timestamps are an application failure, not a
  guessed conflict result.

The local timestamp comes from the injected wall clock and is persisted in the
same transaction as the desired state. Device-clock error can therefore choose
the wrong winner; that is an accepted limitation of this simple policy. A
successful local write receives a new Google server timestamp, so another host
will subsequently treat that Google record as the newer remote state. This and
the Google-on-equality tie-break prevent oscillation after pending work is
resolved.

Google `updated` is not used for structure: the API does not contractually make
it a modification clock for move/reorder state. Structural conflict detection
compares the current Google parent/list/order with the stored remote base.

### Content and structure policies

| State | Preconditions | Decision and retry | Durable transition | User-visible result and convergence | Data-loss analysis | Required tests |
|---|---|---|---|---|---|---|
| Task title | Task exists on both sides; title participates in the complete content snapshot. | If only one snapshot changed from base, use it. If both changed, apply the timestamp rule to the whole snapshot. A local winner is written with the latest ETag; 412 refetches and reevaluates. | Winning Google snapshot becomes base/projection. Losing content facet becomes `superseded`; a successful local write becomes `confirmed`. | The whole winning task appears. Google-winning stale edits are aggregated in sync details; there is no per-task question. All hosts converge after observing the winning Google version. | Every field from the older content snapshot, including title, is intentionally discarded. No unrelated task changes. | Local-only change; remote-only change; local-newer, remote-newer, equal timestamp; 412 then each outcome; restart before resolution. |
| Notes | Same as title; notes are not a merge document. | Same whole-content timestamp rule. Never concatenate, diff3-merge, or create a conflict copy. | Same as title. | Notes come entirely from the winning task snapshot. | Older notes are intentionally discarded, avoiding corrupted or duplicated prose. | Disjoint and overlapping edits must both choose one whole snapshot; empty/null notes; long notes. |
| Due date | Same as title; due is the normalized date-only value. | Same whole-content timestamp rule, encoded as verified UTC midnight when local wins. | Same as title. | One complete task snapshot wins; no mixed title/date record is created. | The older due value is intentionally discarded. | Set/change/clear on both sides; UTC-boundary encoding; timestamp ties. |
| Completion status | Same as title, plus current parent state is known. | Same whole-content rule, except Google completion cascades are authoritative. A child that Google keeps completed beneath a completed parent is accepted even when local content is newer; Axiotask never reopens the parent implicitly. | Adopt returned/refetched cascade state and mark an impossible child-reopen facet `superseded`. | Parent/child status matches Google; sync details explain an automatically rejected child reopen without prompting. | The impossible local reopen is lost by explicit policy; no other content or sibling is changed. | Parent completion cascade, parent reopen, child reopen beneath completed parent, restart, and newer competing content. |
| Parent relationship | Local structure is dirty and the current Google parent is compared with the base. | If Google structure changed, discard the local reparent and use Google. Otherwise issue MOVE with current ETag; 412 refetches and reevaluates. | Google parent becomes base/projection; conflicting local structure becomes `superseded`, otherwise successful MOVE is `confirmed`. | Google parent is shown after a conflict. Once one host moves successfully, other pending conflicting hosts discard their moves and converge. | Only the losing relationship is discarded. Content remains governed independently. | Local-only/remote-only/concurrent reparent; content concurrent with move; 412; completed-parent result; one-level validation. |
| List membership | Local cross-list move is dirty and current Google membership is compared with the base. | Google wins a membership conflict. With no remote structural change, use `destinationTasklist` and current ETag. On uncertain response, look for the same Google task ID in the destination before retrying. | Adopt Google membership or confirm the successful stable-ID move; clear only the losing structure facet. | Task appears once in Google's selected list. Competing clients cannot move it back on every sync. | Losing local membership is discarded; task content and stable local identity remain. | Concurrent cross-list moves; move versus content edit; uncertain landed move; source 404/destination hit; subtree movement. |
| Manual ordering | Local sibling placement is dirty; compare target parent/list and relevant sibling order with the base. | Any Google change to that structural scope wins. Otherwise MOVE using the current valid `previous` anchor and ETag. A missing/deleted anchor triggers refetch and reevaluation, not a fabricated order. | Adopt Google order and supersede local reorder, or confirm returned canonical position. | Google order becomes stable across hosts; opaque positions are never synthesized. | Only the losing local placement is discarded. No sibling is deleted or rewritten. | First/middle/last; concurrent reorder; insertion/deletion/move of anchor; equal-looking positions; restart. |
| List title | List exists on both sides and current/base/local titles and timestamps are available. | Whole-title last-write-wins. Google list endpoints ignore `If-Match`; a local winner is patched once and the response/read-back is adopted. A later Google rename wins on its later server timestamp. | Winning list becomes base/projection; local facet is `confirmed` or `superseded`. | One title is shown everywhere after subsequent sync; no rename conflict prompt. | Older title is intentionally discarded. Tasks in the list are untouched. | Local/remote/concurrent rename; equal timestamp; rename racing PATCH; lost response/read-back; deletion during rename. |

An aggregate production-safe resolution entry such as “3 stale offline changes
were replaced by newer Google changes” makes acknowledged loss visible without
creating one dialog or conflict object per task. Debug diagnostics include the
affected task IDs and complete development-only state under the existing
privacy rules.

### Operation crossings

| Crossing | Preconditions | Decision and retry | Durable transition | User-visible result and convergence | Data-loss analysis | Required tests |
|---|---|---|---|---|---|---|
| Create versus create | Separate successful creates have different Google IDs, even when content is identical. | Treat them as independent tasks/lists. Never deduplicate by content. | Each remote ID maps to its own stable local ID and base. | Both objects remain visible and converge normally. | None; intentional duplicates are preserved. | Identical and different concurrent creates from two clients; parent/list dependencies. |
| Edit versus edit | Both complete task-content snapshots changed from one base. | Apply whole-record timestamp rule; local winner uses current ETag and reevaluates after 412. | Winner becomes base/projection; loser is recorded as `superseded`. | One whole task record remains; no mixed notes/title/date/status. | Entire older content snapshot is intentionally lost and reported in the aggregate resolution summary. | Every content field, overlapping notes, clock equality/skew, repeated 412, process restart. |
| Local edit versus remote delete | Local content is pending and Google positively reports a task tombstone, or its list is authoritatively deleted. A task 404 by itself is not deletion evidence because cross-list moves preserve IDs. | Delete wins. Do not PATCH, clone, or preserve the edit elsewhere. | Mark task deleted; clear content/structure intents as `superseded` with resolution `deleteWon`; update base/tombstone evidence atomically. | Task disappears and pending count falls; aggregate sync details report deletion resolution. | Pending edit is intentionally lost. Only the identified task/list scope is affected. | Direct tombstone, parent cascade, deleted list, edit during in-flight delete, task moved from old list, restart. |
| Local delete versus remote edit | Local lifecycle is deleted while Google changed content or structure. | Delete wins. Resolve the task's current list by stable Google ID, then DELETE with its current ETag; 412 repeats resolution. A tombstone confirms deletion; an old-list 404 does not. | Delete attempt becomes `confirmed`; remote edits and every local non-delete facet become superseded. | Task disappears on all hosts. | Remote edit is intentionally lost by the hard-delete rule. | Remote content/move/reorder before delete; repeated delete; old-list 404 with live destination task; 412; uncertain delete read-back. |
| Move versus edit | One side changed structure and the other content, with no competing change to the same facet. | Operations commute: retain Google structure and reconcile content by its rule, or retain Google content and apply uncontested local structure. | Publish both facet results in one valid projection; independently confirm/supersede dirty facets. | User sees the winning complete content in the selected Google structure. | No loss when facets are independent. If both also changed content/structure, each facet's normal rule applies. | Both directions, all content fields, cross-list move, 412 between operations, restart. |
| Move versus delete | Any task/list/ancestor deletion competes with a move. | Delete wins; do not retry the move or recreate at its destination. | Move facet becomes `superseded` with resolution `deleteWon`; verified deletion is published atomically. | Deleted task does not reappear. | Move is intentionally lost. A task positively found alive under the same Google ID outside a deleted list is not treated as that list's deleted descendant. | Local/remote delete, parent cascade, list deletion, uncertain cross-list move already landed. |
| Concurrent moves | Local structure differs from base and current Google structure also differs. | Google structure wins regardless of local timestamps. No local replay. | Adopt Google parent/list/order and mark local structure `superseded`. | The next completed sync is stable; clients do not move the task back and forth. | Losing local placement is intentionally discarded; content remains independent. | Same-list reorder, reparent, cross-list move, three sequential hosts, restart with pending move. |
| Local operation against remotely deleted list | Positive list deletion/404 is established; local descendants or intents still reference it. | List deletion wins. Cancel creates, edits, moves, and reorders still dependent on that list; never recreate the list automatically. | In one account/list-scoped transaction mark the list removed, supersede its dependent intents, and remove its projected contents. Preserve remote-ID evidence needed to recognize a task already moved to another surviving list. | The list and tasks still belonging to it disappear; unrelated lists remain intact. | All pending work inside the deleted list is intentionally lost. A task positively observed in another list under the same Google ID survives. | Offline task/list creation, pending edits, parent/child rows, concurrent landed move-out, unrelated-list invariants, pagination failure, restart. |
| Remote changes while local work is pending | A current Google record and stored base are available before issuing the pending generation. | Reconcile lifecycle first, then structure, then complete content. Orthogonal facets commute; same-facet conflicts use the rules above. | Update base and projection together; clear only resolved facets and retain newer local generations. | Partial validated changes may appear while health remains Pending/Failed; final state follows Google plus any uncontested/newer local content. | Loss occurs only through explicit whole-record, structural-Google, or deletion rules. | Remote mutation in every engine phase; newer local generation during publish; partial-page failure; restart. |
| Changes from multiple devices | Each installation has its own local IDs and pending timestamps; Google IDs/base state connect confirmed records. | Every host applies the same rules. A successful content write gets a newer Google timestamp; a successful structure change becomes the Google structure that conflicting hosts retain. | Each host confirms or supersedes its local facets, then stores the same Google base. | Hosts converge after their pending work and complete enumerations finish; no conflict questions or ping-pong moves. | Earlier whole content and losing offline structure can be discarded as specified; independent creates remain. | Two- and three-host model tests with varied sync order, offline duration, crashes, and repeated full sync. |

### Uncertain mutations

Uncertain recovery is operation-specific:

| Mutation | Preconditions | Decision and retry | Durable transition | User-visible result and convergence | Data-loss analysis | Required tests |
|---|---|---|---|---|---|---|
| Task/list create | An insert may have committed, its response was not durably acknowledged, and no Google ID is mapped. | Never match by content. Return the generation to `pending` and retry the insert when retry scheduling permits. Bind the local ID to the ID from the first response durably received. | Preserve every uncertain attempt. Successful acknowledgement maps one Google ID and confirms the desired generation; any earlier committed object is later ingested with a separate local ID. | The intended object confirms; a possible duplicate may later appear and remains. Hosts converge on both real Google IDs. | No task is guessed away or conflated. A duplicate is the accepted cost and is diagnosed. | Lost response before/after server commit; crash before acknowledgement; repeated uncertain retries; identical intentional remote create; task and list variants. |
| Task content/list title | A known Google ID exists and a write may have committed. | Read back. Confirm an exact landed desired snapshot; otherwise reevaluate whole-record timestamps and retry only while local still wins. | Read-back and resolution atomically update base/projection and move the generation to `confirmed`, `superseded`, or `pending`. | The normal whole-record winner appears; no duplicate or conflict prompt. | Only the older complete record is lost under the normal timestamp rule. | Landed/not-landed response loss, newer remote write before read-back, equal timestamp, list rename, restart. |
| Delete | A known Google ID exists and DELETE may have committed. | Read back by stable ID. A tombstone confirms. An old-list 404 triggers current-list resolution; delete a live moved task with its current ETag. Absence without positive deletion evidence remains uncertain. | Confirm verified deletion, or retain uncertainty/current-ID evidence until the authoritative delete can run. | The task eventually disappears once positively deleted; no moved survivor is mistaken for success. | Remote edits/moves are intentionally lost to deletion; unrelated IDs are untouched. | Tombstone, live task, cross-list move, old-list 404, deleted list, repeated uncertainty, restart. |
| Move/reorder | A known Google ID exists and MOVE may have committed. | Resolve current membership by stable ID, including a possible third list. Confirm if landed; otherwise Google wins changed structure, or retry only when base structure still holds. | Update canonical structure/base and mark the facet `confirmed`, `superseded`, or `pending` atomically. | One Google placement remains and competing clients stop replaying stale moves. | Only the losing local placement is discarded. | Landed same/cross-list move, source 404, third-list move, changed anchor, no-op retry, restart. |

The create rule deliberately prefers a rare visible duplicate over content
matching that could conflate two intentional tasks or silently lose an
acknowledged create. None of these normal reconciliation cases requires a
manual-conflict state. Transport, authorization, malformed-data, or persistence
failures remain visible through ordinary `SyncHealth` and diagnostics.

### Deletion evidence and scope safety

Deletion is product-terminal, but it is applied only from positive evidence:

- a task tombstone, a confirmed local DELETE, or a verified Google parent
  cascade establishes task deletion; a missing row in one listing and a 404 in
  an old source list do not;
- a successful local list DELETE or direct 404 for a previously confirmed list
  establishes list deletion because lists cannot move;
- deleting a parent sends one parent DELETE. Known children are resolved from
  their Google results/tombstones, not deleted independently from a stale local
  parent relationship; a child already moved away therefore survives;
- deleting a list supersedes work scoped to that list. Remote-ID evidence is
  retained so a task positively discovered in a surviving list is recognized
  as a moved survivor rather than deleted or duplicated;
- every publish/delete transaction is constrained by account key and explicit
  local/remote IDs. It never applies a broad absence-based delete to a page,
  account, sibling set, or unrelated list.

Required invariant tests seed unrelated siblings, children, lists, accounts,
pending creates, and a concurrently moved child around every deletion. They
assert that only positively deleted resources and still-dependent provisional
resources disappear. Pagination failure must disable absence processing.

Confirmed and superseded desired-state records are not an audit log. After the
resolution transaction no longer needs a record for current correctness, it may
remove or compact it. Bounded attempt summaries remain available for health and
diagnostics; their exact time/size budget is an implementation configuration to
be tested, not a product-policy question.

An `inFlight` attempt left by process loss becomes `uncertain` on startup
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
4. create or update the durable desired-state record and its dependencies;
5. make the desired state visible to unresolved-count and health queries;
6. commit.

Only after commit may the command return success and repository streams publish
the projected state. If the transaction fails, the command returns a typed
persistence failure and must not report success or publish a projection that
lacks durable intent.

The post-commit sync trigger is a scheduling optimization, not the durability
mechanism. If the process dies after commit but before notifying the coordinator,
the pending desired-state record remains discoverable at startup, resume, and
the next
foreground scheduling opportunity. Correctness therefore never depends on an
exit callback or an in-memory event.

Remote acknowledgement also uses one transaction: validate the response,
update remote ID/base/ETag and projected state as allowed by this policy,
confirm or supersede the attempted generation, remove/compact the desired-state
record when no newer generation exists, and record attempt consequences. A
crash cannot leave a remote ID rebound while the desired state still appears
safe to issue as a new create.

## Structural synchronization phases

This phase model defines responsibilities, not push/pull ordering:

| Phase | Required structural result |
|---|---|
| Eligibility | Resolve account partition, durable `syncEnabled`, Tasks authorization state, startup recovery, and whether a run is permitted. No network health is inferred. |
| Begin attempt | Create a durable run identity/start record and claim eligible work without overlapping another run for the configured account. |
| Remote exchange | Acquire validated authorization for requests, enumerate required remote pages, and/or execute selected desired-state generations. Exact ordering and batching are unresolved. |
| Validate and stage | Strictly decode resource fields, associate account/identity, defer parent resolution until enough of the required view is available, and track page/scope completeness. |
| Transactional publish/acknowledge | Commit internally valid remote batches and attempt outcomes without overwriting concurrent local intent. No transaction spans network IO. |
| Finalize | Produce a typed run report. Advance last verified success only if every required phase/page completed and no unsupported, malformed, uncertain, or failed requirement invalidates the run. |

Validated pages may be published incrementally. Until finalization succeeds,
health remains non-green and the prior last-success timestamp remains unchanged.
Every required listing follows page tokens until termination for every required
scope. That establishes completion of the documented listing procedure, not an
atomic snapshot: Google does not document snapshot isolation across pages.
Therefore listing absence alone is never sufficient to delete a previously
known local resource. It creates a verification candidate under the deletion
evidence rules above. Pagination, validation, or unsupported-data failure
also disables all absence processing for the affected scope. P3 directly
confirmed the risk: a task inserted after page 1 was omitted from the continued
walk even though every page-token request succeeded, then appeared in a clean
enumeration.

On startup, a durable run with no final outcome is marked interrupted. Its
claimed `inFlight` attempts are treated under the uncertainty rule above.
Startup does not pretend the abandoned process is still synchronizing.

## SyncCoordinator and SyncEngine boundary

| SyncCoordinator owns | SyncEngine owns |
|---|---|
| Observing startup, foreground resume, connectivity hints, committed-mutation notifications, explicit refresh/retry, and foreground cadence. | Executing one account-scoped run against the local sync store, authorization port, Google Tasks port, and clock. |
| Reading `syncEnabled`, coalescing triggers, and allowing at most one active run for the configured account. | Recovering/claiming desired-state generations and attempts and performing the structural phases above. |
| Remembering that another run is required when a trigger arrives during a run. | Strict wire validation, completeness evidence, transactional publication/acknowledgement, and typed run reports. |
| Requesting cancellation at engine-declared safe boundaries and enforcing an outer run deadline. | Honoring cancellation only at safe boundaries; never abandoning an open local transaction. |
| Projecting runtime scheduling facts used by SyncHealth. | Reporting facts; it does not choose UI wording, schedule itself, or mutate coordinator state. |

The coordinator does not interpret task conflicts or mutate task, base,
desired-state, or attempt rows; it does not infer success from connectivity or
call widgets. The engine does not
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
- aggregate pending, in-flight, uncertain, and failed counts;
- `SyncHealth`, current safe phase/activity, last attempt, and exact last
  verified-success time;
- explicit failure reason, safe impact, and an allowed action when one actually
  exists;
- a typed unsupported-remote-state diagnostic code.

The release UI does not observe OAuth tokens, ETags, raw HTTP bodies/messages,
page tokens, SQL errors/values, desired-state payload internals, or raw remote
IDs. It does not decide that a task is confirmed based on a successful button
command; the command confirms only the local transaction. The debug-only
Diagnostics UI is a separate development surface described below; it may show
sensitive task/API/storage context but never credential material.

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
- counts of `pending`, `inFlight`, `uncertain`, and `failed` work;
- the latest explicit failure reason and safe diagnostic code.

It produces exactly the accepted four top-level outcomes:

| Outcome | Exact foundational rule |
|---|---|
| **Inactive** | `syncEnabled=false`, or the authorization adapter says usable Tasks authorization is absent/terminally rejected. Reason is mandatory: `syncStopped` or `noAuthorization`. Unresolved counts remain visible. |
| **Failed** | The latest required completed attempt failed/timed out; a conclusive failed desired state is not actively being repaired; unsupported/application state prevents safe progress; or freshness expired without active verification. Reason is mandatory: `noConnection`, `remoteFailure`, `applicationFailure`, or `stale`. Last success and unresolved counts remain visible. |
| **Pending** | Authorization is usable and required verification, an active/queued run, or durable unconfirmed work exists, provided no higher-priority non-active failure makes the outcome Failed. Active recovery after failure is Pending. |
| **Good** | Sync is enabled; authorization is usable; a complete required run succeeded inside the freshness window; connectivity is not known unavailable; and there is no newer failure, required verification, active/queued work, or pending/in-flight/uncertain/failed desired state. |

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
- `noConnection` requires transport failure or a platform state that proves no
  route; a positive connectivity hint never proves Google is reachable;
- malformed responses, unsupported remote state, broken invariants, and local
  persistence failures use `applicationFailure` with a specific diagnostic code;
- Google service/rate-limit failures use `remoteFailure`; retry policy may move
  them to Pending only when recovery is actually queued or active;
- a hung run becomes Failed at its monotonic deadline;
- partial publication does not advance last verified success;
- `confirmed` history does not count as unresolved work;
- process restart re-derives runtime phase from durable attempts/desired state
  and cannot clear durable failure evidence merely by resetting memory.

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
7. SyncHealth becomes Failed with reason `applicationFailure` and a specific
   unsupported-data diagnostic code;
8. a brand-new unsupported resource is not projected as a fake or read-only
   task; the release product shows the global safe failure summary, while the
   development Diagnostics view records the complete decoded offending
   resource and task content needed to investigate it.

This is an application capability failure, not a generic request for manual
intervention. Retrying or a later compatible application version may recover it;
the current run must not improvise a lossy representation.

## Production and development diagnostics

The release product persists a bounded, account-scoped stream of safe event
codes, phases, timing, counts, failure reasons, and sanitized causes. It is easy
to inspect, copy, export, and clear in the application, but never contains task
content, account details, raw remote IDs, raw bodies, SQL values, or full URLs.

The debug development product additionally composes a bounded sensitive sink.
It does not sample or suppress failures or sync boundary/state transitions. It
records task titles/notes, decoded API request and response context, redacted
authorization state/errors, remote IDs, desired-state/attempt/coordinator
transitions, database operations/values, repository/UI commands, stack traces,
timing, and unsupported resources. Its searchable live view is one interaction
from sync details and is permanently marked as containing private test-account
data. Export is explicit; files/exports are local and ignored by Git.

Both products scrub credentials before event construction. Access/refresh
tokens, authorization headers/codes, client secrets, PKCE verifiers, DPoP
private keys, secure-store values, and unredacted OAuth callback URLs are never
logged. There is no automatic upload or telemetry, and release composition has
no runtime path to the sensitive sink.

## Crash and persistence invariants

1. No transaction spans network IO.
2. Local acknowledgement always implies durable projected state plus durable
   intent; neither may exist alone after commit.
3. Remote confirmation always updates identity/base/desired-state consequences in
   one transaction.
4. Process loss cannot convert `inFlight` to `pending` without evidence that no
   side effect could have reached Google.
5. Partial or malformed remote data cannot justify destructive absence
   processing or last-success advancement.
6. Concurrent repository edits cannot be overwritten by an engine write based
   on an older read. The final local transaction must re-check the current
   desired-state/projection version.
7. A database open/write failure is visible and preserves recoverable data; no
   empty-cache or preference-store fallback is allowed.
8. Every unresolved record remains account-scoped and discoverable after
   restart.
9. Production diagnostics contain only safe structured evidence. Development
   diagnostics contain the sensitive application/task evidence defined above,
   but neither diagnostic path ever contains credential material.

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
- A generic HTTP retry interceptor or retry-timing policy in this draft.

## Remaining Stage 4 work and evidence

No current item below requires a product answer from the user. They are concrete
specification or capability-research actions:

1. Define retry/backoff/cadence/freshness/timeout policy. A failure always remains
   visible with its concrete reason; it becomes Pending only when a recovery run
   is actually queued or active.
2. Choose structural phase ordering and dependency scheduling consistent with
   this conflict policy, including bounded reevaluation after repeated 412s.
3. Complete safe platform-auth evidence for expired, revoked, and wrong-scope
   cases. The current probe establishes only malformed bearer as 401.
4. Probe `webViewLink` presence/navigation with an ordinary and recurring task
   created in the current Google UI before implementing the recurrence escape
   hatch.
