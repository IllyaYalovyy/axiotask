# Synchronization specification

- Status: **Accepted**
- Scope: state, authority, reconciliation, reliability, recovery, and component boundaries
- Updated: 2026-08-11

## Purpose and scope

This specification defines what local and remote state mean, automatic reconciliation,
and the complete reliability/recovery model. Implementation remains later work.

Normative inputs are [VISION.md](../VISION.md), the accepted
[target architecture](ARCHITECTURE.md), accepted ADRs, and the verified
[Google Tasks API contract](GOOGLE_TASKS_API_CONTRACT.md). The Rust/Tauri
synchronization documents were reviewed as read-only historical evidence of
failure modes. Their schema, push-first order, conflict-copy behavior, automatic
hierarchy repair, timing, and unverified Google assumptions are not adopted by
this specification.

Every invariant and required transition maps to stable evidence IDs in the
accepted [synchronization test matrix](SYNC_TEST_MATRIX.md).

Import/export is outside the synchronization run itself. Its accepted planning,
identity, and safety contract is defined by the
[functional parity plan](FUNCTIONAL_PARITY.md#backupexport-and-restoreimport);
accepted imports enter this specification only through the normal transactional
desired-state boundary. Capability facts identified by the API contract remain
mandatory implementation gates rather than open sync policy.

## Core terms

| Term | Meaning |
|---|---|
| Remote system of record | Google Tasks is the durable cross-device system for every supported list and task. Axiotask does not create a second permanent task universe. |
| Confirmed remote state | A validated Google resource representation that has been committed locally as the last known remote result. “Confirmed” does not mean current forever. |
| Local cache | The account-scoped SQLite representation used for responsive reads, offline continuity, confirmed remote bases, projected local state, desired-state records, and sync evidence. It is not an alternate backend. |
| Remote base | The last confirmed Google representation against which a later local intent and remote observation can be compared. |
| Durable pending intent | An acknowledged local request that has committed to SQLite but has not yet received a transactionally recorded remote confirmation. |
| Projected state | The user-visible local task/list state after applying acknowledged local intent to the last confirmed base. It may be newer than Google and must be shown with non-green health until confirmed. |
| Fresh | A complete required sync run succeeded less than five minutes ago, with no newer fact invalidating it. |
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

This limitation does not change the health rule. A forced or scheduled run that
completes every required phase successfully produces Good; a detected failure
produces Failed immediately; queued or executing work produces Pending. Good
therefore means “the last required synchronization completed successfully,”
with its exact completion time. It is not a claim that Google supplied an atomic
snapshot that its API does not expose, and the UI must say “Synced” rather than
the absolute claim “Up to date.”

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

Task bases store every supported content field, parent/list membership,
canonical position, lifecycle flags, remote ID, ETag, and Google `updated` value.
List bases store title, lifecycle, remote ID, ETag, and Google `updated`. Omitting
a value that can distinguish a real remote change from server normalization is
not allowed merely to simplify persistence.

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

A task-delete generation may additionally carry a clock-derived `notBefore`
equal to its durable Undo expiry. This is not a retry or a second operation
state: the generation remains `pending`, prevents Good, and is simply ineligible
for Google dispatch until its accepted grace ends. Its bounded Undo snapshot and
cleanup contract are defined by the
[functional parity plan](FUNCTIONAL_PARITY.md#delete-and-undo).

Dependencies use local keys. A task create may therefore depend on a provisional
list or parent without rewriting UI identity when Google later assigns IDs.
Edits made while synchronization is stopped use this exact path: they remain
fully available, update projected state immediately, and coalesce durably until
Resume schedules catch-up.

Claiming remote work snapshots the exact desired-state generation into a
durable attempt before issuing a request. A later local edit may advance the
current desired state without changing that attempt snapshot. This prevents an
in-flight or uncertain request from being misremembered while still avoiding an
event log. HTTP payload construction remains adapter work; operation and
dependency order is normative below.

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
| `failed` | The latest attempt has a conclusive non-success outcome; unlike `uncertain`, evidence establishes that Google did not confirm that attempt. | Intent remains unresolved with a typed failure and follows the retry/permanent policy below. |
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

The reconciliation and reliability policies below select confirmation,
supersession, or a new pending attempt.
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

Conflict decisions operate on the Google state actually observed before a
mutation. Google does not provide an atomic account snapshot, and task-list
mutations ignore `If-Match`. A remote list rename or sibling-order change can
therefore race after enumeration. The resulting Google response and required
read-back are authoritative for that race window. The client does not add
repeated reads that consume quota without closing the race, and it never claims
that an unobservable concurrent change was detected. This accepted API
limitation can change a title or relative placement, but it cannot delete or
rewrite another task.

### Content and structure policies

| State | Preconditions | Decision and retry | Durable transition | User-visible result and convergence | Data-loss analysis | Required tests |
|---|---|---|---|---|---|---|
| Task title | Task exists on both sides; title participates in the complete content snapshot. | If only one snapshot changed from base, use it. If both changed, apply the timestamp rule to the whole snapshot. A local winner is written with the latest ETag; 412 refetches and reevaluates. | Winning Google snapshot becomes base/projection. Losing content facet becomes `superseded`; a successful local write becomes `confirmed`. | The whole winning task appears. Google-winning stale edits are aggregated in sync details; there is no per-task question. All hosts converge after observing the winning Google version. | Every field from the older content snapshot, including title, is intentionally discarded. No unrelated task changes. | Local-only change; remote-only change; local-newer, remote-newer, equal timestamp; 412 then each outcome; restart before resolution. |
| Notes | Same as title; notes are not a merge document. | Same whole-content timestamp rule. Never concatenate, diff3-merge, or create a conflict copy. | Same as title. | Notes come entirely from the winning task snapshot. | Older notes are intentionally discarded, avoiding corrupted or duplicated prose. | Disjoint and overlapping edits must both choose one whole snapshot; empty/null notes; long notes. |
| Due date | Same as title; due is the normalized date-only value. | Same whole-content timestamp rule, encoded as verified UTC midnight when local wins. | Same as title. | One complete task snapshot wins; no mixed title/date record is created. | The older due value is intentionally discarded. | Set/change/clear on both sides; UTC-boundary encoding; timestamp ties. |
| Completion status | Same as title, plus current parent state is known. | Same whole-content rule, except Google completion cascades are authoritative. A child that Google keeps completed beneath a completed parent is accepted even when local content is newer; Axiotask never reopens the parent implicitly. | Adopt returned/refetched cascade state and mark an impossible child-reopen facet `superseded`. | Parent/child status matches Google; sync details explain an automatically rejected child reopen without prompting. | The impossible local reopen is lost by explicit policy; no other content or sibling is changed. | Parent completion cascade, parent reopen, child reopen beneath completed parent, restart, and newer competing content. |
| Parent relationship | Local structure is dirty and the current Google parent is compared with the base. | If Google structure changed, discard the local reparent and use Google. Otherwise issue MOVE with current ETag; 412 refetches and reevaluates. | Google parent becomes base/projection; conflicting local structure becomes `superseded`, otherwise successful MOVE is `confirmed`. | Google parent is shown after a conflict. Once one host moves successfully, other pending conflicting hosts discard their moves and converge. | Only the losing relationship is discarded. Content remains governed independently. | Local-only/remote-only/concurrent reparent; content concurrent with move; 412; completed-parent result; one-level validation. |
| List membership | Local cross-list move is dirty and current Google membership is compared with the base. | Google wins a membership conflict. With no remote structural change, use `destinationTasklist` and current ETag. On uncertain response, look for the same Google task ID in the destination before retrying. | Adopt Google membership or confirm the successful stable-ID move; clear only the losing structure facet. | Task appears once in Google's selected list. Competing clients cannot move it back on every sync. | Losing local membership is discarded; task content and stable local identity remain. | Concurrent cross-list moves; move versus content edit; uncertain landed move; source 404/destination hit; subtree movement. |
| Manual ordering | Local sibling placement is dirty; compare target parent/list and relevant sibling order with the base. | Any Google change observed in that structural scope wins. Otherwise MOVE using the current valid `previous` anchor and ETag. A missing/deleted anchor triggers refetch and reevaluation, not a fabricated order. A sibling race after the observation adopts the canonical server result. | Adopt Google order and supersede local reorder, or confirm returned canonical position. | Google order becomes stable across hosts; opaque positions are never synthesized. | Only the losing local placement is discarded. An unobserved race may affect relative placement, but no sibling is deleted or rewritten. | First/middle/last; concurrent reorder; insertion/deletion/move of anchor before and after enumeration; equal-looking positions; restart. |
| List title | List exists on both sides and current/base/local titles and timestamps are available. | Whole-title last-write-wins for versions observed before mutation. Google list endpoints ignore `If-Match`; a local winner is patched once and the response/read-back is adopted. A rename racing after the last read is resolved by Google's resulting server state, even if that overwrites the unseen title. | Resulting list becomes base/projection; local facet is `confirmed` or `superseded`. | One server-confirmed title is shown everywhere after subsequent sync; no rename conflict prompt. | The older observed title is intentionally discarded. In the uncloseable read/write race, either concurrent title may be overwritten; tasks are untouched. | Local/remote/concurrent rename; equal timestamp; remote rename before read, between read and PATCH, and after PATCH; lost response/read-back; deletion during rename. |

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
| Task/list create | An insert may have committed, its response was not durably acknowledged, and no Google ID is mapped. | Never match by content. Return the claimed create generation to `pending` and retry the insert when retry scheduling permits. Resolve that create even when a newer generation edits, moves, or deletes the provisional object; bind the local ID to the ID from the first response durably received, then apply the newest desired generation to that ID. | Preserve every uncertain attempt and every newer generation. Successful acknowledgement maps one Google ID and confirms only the claimed create generation; the newest desired generation remains pending. Any earlier committed object is later ingested with a separate local ID. | The newest desired state reaches one bound object. A possible earlier duplicate may later appear and remains, including after the bound object was deleted. | No task is guessed away or conflated. A visible duplicate or unexpected surviving object is the accepted cost and is diagnosed; content matching is forbidden. | Lost response before/after server commit; crash before acknowledgement; repeated uncertain retries; newer edit/delete/move while create is uncertain; identical intentional remote create; task and list variants. |
| Task content/list title | A known Google ID exists and a write may have committed. | Read back. Confirm an exact landed desired snapshot; otherwise reevaluate whole-record timestamps and retry only while local still wins. | Read-back and resolution atomically update base/projection and move the generation to `confirmed`, `superseded`, or `pending`. | The normal whole-record winner appears; no duplicate or conflict prompt. | Only the older complete record is lost under the normal timestamp rule. | Landed/not-landed response loss, newer remote write before read-back, equal timestamp, list rename, restart. |
| Task delete | A known Google task ID exists and DELETE may have committed. | Read back by stable ID. A tombstone confirms. An old-list 404 triggers current-list resolution; delete a live moved task with its current ETag. Absence without positive deletion evidence remains uncertain. A success response from a possibly stale source-list path is not enough to confirm deletion without positive read-back evidence. | Confirm verified deletion, or retain uncertainty/current-ID evidence until the authoritative delete can run. | The task eventually disappears once positively deleted; no moved survivor is mistaken for success. | Remote edits/moves are intentionally lost to deletion; unrelated IDs are untouched. | Tombstone, live task, cross-list move before/during DELETE, old-list 404/success, deleted list, repeated uncertainty, restart. |
| Task-list delete | A known Google task-list ID exists and DELETE may have committed. Lists cannot move and expose no tombstone. | Read back the list. Direct 404 for the previously confirmed account/list identity confirms deletion. If it still exists, retry DELETE when scheduling permits and read back again. A malformed/inconclusive response remains uncertain. | Confirm the list deletion and supersede its still-dependent work atomically, or retain the uncertain delete and all scoped evidence. | A confirmed deleted list and its still-dependent contents disappear; a live list remains visibly pending deletion until confirmed. | Delete remains authoritative. Tasks already positively observed under surviving lists remain; unrelated lists/accounts are untouched. | Landed/not-landed response loss, repeated 204, live read-back, direct 404, malformed read-back, dependent work, moved survivor, acknowledgement failure, and restart. |
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

For task deletion, that same transaction hides the supported task/subtree,
records the delete generation and its `notBefore`, and stores the bounded Undo
snapshot. Undo before expiry transactionally supersedes that unclaimed delete
and restores the same identities. Expiry strips restorable content and makes the
delete eligible; startup and resume perform the same injected-clock cleanup.
List deletion and Clear completed do not use this grace.

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

## Reliability and deterministic scheduling

### Injected time and randomness

All scheduling decisions depend on injected `Clock`, monotonic timer, and
randomness ports. Persisted timestamps use UTC wall time for restart recovery
and user display. In-process debounce, request, run, cadence, and backoff
deadlines use monotonic time so wall-clock changes cannot extend or shorten a
running timer. Tests supply both clocks and a deterministic jitter sequence.

After restart, persisted UTC deadlines are reconstructed conservatively. A wall
clock that moved backward cannot restore Good or extend the five-minute
automatic-retry budget; an implausible clock discontinuity creates Pending
verification and a diagnostic. Only a newly completed run establishes current
freshness.

### API evidence boundary

This reliability model relies only on the verified API contract: no lossless
change cursor or atomic pagination; task but not task-list `If-Match` behavior;
duplicate-producing repeated creates; operation-specific replay observations;
stable task IDs across probed moves; and one structured 403 `quotaExceeded`
without `Retry-After`. Google does not publish a complete Tasks-specific
transient-error or retry-header matrix. Status classification, timeouts,
backoff, and exhaustion below are conservative client policy, not claims of an
undocumented Google guarantee. Unknown cases remain explicit failures.

The API documents up to 100,000 tasks and a 50,000-query courtesy limit per
day. A five-minute complete-scan cadence cannot guarantee successful operation
at the documented maximum scale. The approved product policy keeps the
five-minute cadence: every run records its request cost, quota/deadline failure
is immediately Failed, partial data never becomes Good, and the application
does not silently truncate or weaken verification. This is an explicit scale
consequence, not an API guarantee or an adaptive hidden cadence.

### Run phase ordering

One account-scoped run executes these phases in order:

| Phase | Required result and failure boundary |
|---|---|
| 1. Recover | Resolve interrupted runs and attempts from durable state before new network work. `inFlight` mutations become operation-specific `uncertain`; unfinished read-only requests are safe to discard. |
| 2. Check eligibility | Open/validate the account partition, read `syncEnabled`, lifecycle eligibility, retry-exhaustion latch, and authorization state. Ineligible runs issue no Google request. |
| 3. Authorize | Obtain a usable Tasks access token, refreshing once when required. Authorization does not establish sync health. |
| 4. Begin run | Commit a unique run ID, trigger set, start time, and two-minute monotonic deadline. This durable record is created before claiming work. |
| 5. Enumerate Google | List every task-list page, then every required task page for each list with `showCompleted=true`, `showHidden=true`, `showDeleted=true`, and `showAssigned=false`. Validate and publish safe pages transactionally while retaining per-scope completeness evidence. |
| 6. Reconcile and plan | Against each complete scope, compare the confirmed base, current Google state, and newest local desired generation. Apply deletion first, then structure, then whole content. Incomplete scopes produce no outbound mutation. |
| 7. Execute operations | Claim one eligible generation durably, then execute dependency order: authoritative list/task deletes whose `notBefore` has passed; list creates; top-level task creates; child creates; moves/reorders; complete content writes and list renames. A deleted dependency suppresses all dependent work. Each operation is acknowledged independently before the next dependent operation. |
| 8. Verify uncertain/conditional outcomes | Perform the operation-specific read-backs in the reconciliation section. A 412 refetches and replans the affected task, bounded by the run deadline and request-attempt budget. |
| 9. Finalize | Commit the typed run outcome, per-scope completeness, unresolved counts, retry episode state, and—only on complete success—the last verified-success time. |

Remote enumeration comes before mutation so stale offline intent is never pushed
without first observing the available current Google state. There is no second
account-wide pull merely to make a run look stronger than the non-atomic API can
prove. Valid mutation responses and targeted read-backs establish operation
results; a queued follow-up run handles triggers that arrived during execution.

### Partial publication and operation success

Validated pages may be published incrementally, but a scope is complete only
after its entire page-token chain terminates successfully. Until every required
scope and phase succeeds, health is non-green and last verified success does not
advance.

- Failure of task-list pagination makes the account view incomplete and blocks
  all outbound mutations for that run.
- Failure within one task list blocks absence processing and outbound mutations
  for that list, including tasks believed to have moved into or out of it.
  Independently complete lists may publish and execute operations, but the run
  still finishes Failed.
- A malformed resource fails its containing scope; valid previously published
  rows remain. No unsupported row is silently skipped to claim completeness.
- Each successful mutation is acknowledged immediately in its own local
  transaction. A later operation failure never rolls it back or causes it to be
  replayed.
- A failed dependency leaves its dependents `pending` and unattempted. Other
  dependency-independent operations may continue while enough run time remains.
- Listing absence alone never deletes. P3 proved concurrent insertion can be
  omitted from an otherwise successful page-token walk.

### Serialized runs and trigger coalescing

`SyncCoordinator` permits at most one engine run for the configured account.
Triggers are typed facts, not separate jobs:

| Trigger | Scheduling rule |
|---|---|
| Startup | After SQLite and authorization adapters initialize, request immediate verification unless sync is stopped, reauthorization is required, or automatic retry is exhausted. Cached data starts Pending/Inactive, never Good. |
| Foreground resume | Request immediate verification under the same eligibility rules. Multiple lifecycle notifications coalesce. |
| Connectivity may have returned | Request immediate verification only on a transition from unavailable/unknown-failed to potentially available. It never marks Google reachable or healthy. |
| Explicit Refresh/Retry or Resume Sync | Start immediately when no run is active. Retry/Resume clears the retry-exhaustion latch and begins a new five-minute retry episode, but cannot bypass an unexpired server `Retry-After` or missing authorization. |
| Successful reauthorization | Clear `reauthorizationRequired` only after the adapter validates usable Tasks authorization, then request immediate verification. |
| Local mutation | The mutation is already durable. Schedule at five seconds after the newest mutation, capped at ten seconds after the first mutation in the burst. A task-delete generation remains visibly Pending but cannot be claimed before its durable 30-second Undo expiry; the coordinator schedules that eligibility boundary without delaying unrelated eligible work. |
| Foreground cadence | Request verification five minutes after the preceding run finishes while the platform is eligible. If that deadline arrives during another run, coalesce one follow-up. A more urgent queued trigger wins. |

A trigger arriving during a run sets one in-memory `followUpRequired` fact and
merges its reason into the run report; it never starts an overlapping run. Local
work is already durable, and process restart independently requires verification,
so correctness does not require persisting transient trigger notifications.
After finalization, the coordinator rereads durable desired state. It starts one
immediate follow-up if eligible and work or a verification obligation still
exists. Ten mutations during a run therefore cause at most one follow-up run.

Linux remains cadence-eligible while the application process is running,
including when its window is unfocused or minimized. Android is eligible only
while resumed in the foreground. Android schedules no periodic/background
worker; pause cancels at a safe boundary, stops timers/network initiation, and
resume requests catch-up. Correctness does not depend on focus, an editor, or a
lifecycle/exit callback.

### Quiescence and API efficiency

When no run is active and no eligible trigger, retry, pending generation, or
verification obligation exists, the coordinator performs no work and holds no
polling loop beyond the single foreground cadence timer. A completed no-op run
does not write task/list resources, create attempts, or schedule an immediate
follow-up.

The API exposes no verified lossless change cursor, so each five-minute cadence
verification must consume all required task-list and task pages. Within that
constraint the engine:

- coalesces edits and triggers;
- never polls faster than the cadence without a concrete trigger/retry;
- uses one enumeration result for reconciliation and avoids redundant GETs;
- performs targeted reads only for conditional, uncertain, or moved resources;
- emits no PATCH/MOVE/DELETE when desired and Google state already agree;
- never uses `updatedMin`, collection ETags, or one listing absence as a fake
  complete-change feed;
- records request/page/operation counts so development tests can detect an N+1
  regression without imposing an invented server quota threshold.

The coordinator does not silently stretch the approved five-minute cadence to
avoid quota. If account size, latency, retry delay, or quota prevents a complete
run inside the two-minute deadline, the run fails visibly and retains its
partial-scope evidence. A later implementation may change cadence or supported
scale only through a new reviewed product decision.

## Timeouts, cancellation, and retry

### Deadlines and cancellation

Each HTTP attempt has a 30-second timeout. Each complete run has a two-minute
monotonic deadline including authorization, enumeration, request retries,
backoff waits, local transactions, and finalization. Before starting any request
or backoff, the engine checks that its worst-case boundary fits the remaining
run budget; otherwise it finalizes Failed without beginning that work.

At the run deadline, sync stop, Android pause, or application shutdown request,
the coordinator prevents new requests and asks the engine to cancel. The engine
finishes or rolls back its current SQLite transaction, then stops at the next
safe boundary. Cancellation of a read is harmless. Cancellation/timeout after a
mutation may have left the device makes that attempt `uncertain`; it is never
reported as not committed. No transaction is left open to wait for the network.

Exit may request this bounded cancellation but is not a flush protocol. A kill,
crash, lost battery, or missing exit callback has the same recovery semantics as
process death.

### Failure classification

| Class | Examples | Automatic handling | User-visible outcome |
|---|---|---|---|
| Retryable transport | DNS/connect/TLS failure, connection reset, timeout, or a platform-proven lack of route | Read-only requests retry. A possibly transmitted mutation first follows uncertain-outcome recovery. | Failed immediately (`noConnection` for proven route/transport failure); Pending only while an actual retry request/run is active. |
| Retryable remote | HTTP 429, 5xx, and the observed structured 403 `quotaExceeded` case | Backoff using the policy below. A mutation whose non-commit is not conclusive becomes uncertain before replay. Other 403 reasons are not assumed retryable. | Failed `remoteFailure` during waits; exact safe reason and retry count shown. |
| Conditional conflict | Task HTTP 412 | Not a service retry. Refetch, reconcile, and replan while within the bounded request/run budget. | Pending during active reconciliation; automatic supersession/confirmation follows conflict policy. |
| Authorization refreshable | Expired access token when the adapter can refresh | Refresh once, then repeat the request through the normal attempt budget. | Pending while refresh/request is active; never Good merely because refresh succeeded. |
| Reauthorization required | Missing Tasks scope, terminal refresh rejection such as `invalid_grant`, revoked authorization, or adapter-declared unusable credentials | Persist `reauthorizationRequired`; cancel new Google work; do not back off or repeatedly refresh. | Inactive `noAuthorization`, presented prominently with Reauthorize. Cached data and pending intent remain. |
| Permanent request | Validated 4xx such as malformed writable data, unsupported operation, or stable permission denial that is neither auth nor quota | Do not automatically retry the same request. Preserve typed failure and intent unless reconciliation supersedes it. | Failed `applicationFailure` or `remoteFailure` with concrete impact and Retry only where a changed condition could help. |
| Application/data | Malformed success body, unsupported remote hierarchy, violated invariant, decoder defect | Stop the affected scope; never improvise or retry in a tight loop. | Failed `applicationFailure`; debug diagnostics retain full allowed context. |
| Persistence | Transaction failure, unavailable/corrupt SQLite | Stop all remote work because outcomes cannot be acknowledged safely. | Failed `applicationFailure`, or a database recovery surface when state cannot be read. |

Google Tasks does not document a complete transient-status or `Retry-After`
matrix. The contract records one controlled 403 `quotaExceeded` response without
`Retry-After`; classification depends on structured reason, not every 403 or
human-readable message. Unknown responses fail closed as non-automatic until
evidence or an adapter update classifies them.

### Token refresh and reauthorization

The authorization adapter supplies usable headers for each request and may
refresh an expired or near-expiry access token once per request attempt. A Tasks
authorization rejection invalidates the access-token view and permits one
adapter refresh followed by one policy-controlled request attempt only when the
adapter classifies the rejection as conclusive. A second rejection, missing
Tasks scope, terminal refresh error, or adapter-declared revoked/unusable grant
commits account-scoped `reauthorizationRequired` immediately.

An auth response whose side-effect semantics the adapter cannot classify does
not authorize blind mutation replay; the operation becomes uncertain and uses
its normal recovery rule. This is deliberate because the contract has current
Tasks evidence for malformed bearer only, not every expired/revoked/wrong-scope
case.

`reauthorizationRequired` survives restart and suppresses refresh loops,
cadence, and remote mutation. It does not delete credentials, cached data, or
pending intent. The UI immediately presents prominent `noAuthorization` with a
Reauthorize action. Cancellation/dismissal leaves the state unchanged. Only a
completed interactive authorization flow whose verified subject matches the
account and whose Tasks scope is usable clears it; the ensuing sync is Pending
until complete and cannot become green from login alone.

### Backoff and exhaustion

There is one explicit retry policy with two non-overlapping scopes. `SyncEngine`
applies the bounded per-request retries inside a run; `SyncCoordinator` applies
between-run backoff/exhaustion. Both use the same injected timing/jitter policy
and persisted retry episode. The HTTP adapter reports typed outcomes and never
hides retries.

Within one active run, a retryable safe request—read-only, conclusively
uncommitted, or resolved through uncertain-outcome recovery—receives at most
three retries after its initial attempt. Nominal exponential delays are 1, 2,
and 4 seconds. Injected full jitter chooses deterministically in tests from zero
through the nominal delay. A valid server `Retry-After` later than the jittered
delay wins.
If that delay cannot fit before the two-minute run deadline, the run ends Failed
instead of sleeping past its deadline.

After a failed run, automatic recovery uses nominal delays of 1, 2, 4, 8, 16,
32, then at most 60 seconds, each with full jitter and any longer valid
`Retry-After`. The retry episode begins at the first retryable failure and ends
five minutes later. Waiting is **Failed**, not Pending. Only an executing retry
is Pending. Successful complete synchronization clears the episode.

While the platform proves there is no route, the episode clock and backoff
schedule continue but no doomed HTTP request is issued. A connectivity
may-have-returned transition starts an immediate eligible attempt within the
same episode; it does not reset the five-minute budget or imply success.

When the five-minute budget expires, persist `automaticRetryExhausted` and stop
all automatic cadence, resume, connectivity, and local-edit retries for that
failure episode. The UI remains Failed with the concrete reason and a Retry
button. Retry, or Resume Sync when stopped, explicitly starts a new episode. A
valid future server `Retry-After` remains an earliest-request boundary even
after the button is pressed; the UI explains when retry becomes available
rather than violating it.

Reauthorization-required and application/persistence failures do not consume
this retry budget because they are not automatically retried.

### Idempotency and uncertain outcomes

Retry safety is decided by operation, never by HTTP method alone:

| Operation | Verified behavior | Reliability rule |
|---|---|---|
| Enumeration/GET | Read-only request has no intended mutation. | Retry within the request budget; discarded partial bodies/pages establish no completeness. |
| Create | P5 produced a distinct task/list for an identical repeated insert; Google exposes no idempotency key or client-selected ID. | Never content-deduplicate. An uncertain create retries under the accepted policy and may produce a diagnosed duplicate. |
| Task content/list rename | P6 repeated writes successfully and changed version metadata again. | Read back known ID first. Confirm, supersede, or retry from current state; never assume repetition was a no-op. |
| Task delete | P6/P4 observed repeated delete success in the tested cases; DELETE through a stale source-list path after a concurrent move remains unprobed. | Read back/resolve the task ID first after uncertainty, then repeat only to enforce authoritative deletion. Never confirm from old-list absence or an unverified stale-path response. |
| Task-list delete | P4 observed direct 404 after a landed list deletion and repeated DELETE success in the tested window. | Read back the non-movable list identity. Confirm on direct 404; otherwise retry and verify under the accepted task-list uncertainty rule. |
| Move/reorder | P6 observed repeated same-list move as a no-op; P7 observed source 404 after a landed cross-list move. | Resolve current placement by stable ID before retry. Never interpret source 404 alone as deletion or failed move. |

The durable attempt—not request text—is the unit of uncertainty. A timeout,
connection loss, cancellation, malformed success response, process death after
dispatch, or acknowledgement-transaction failure can all produce `uncertain`.
Create, content/title, delete, and move then follow the separate recovery rows
under **Uncertain mutations**; no generic retry layer can bypass them.

## SyncCoordinator and SyncEngine boundary

| SyncCoordinator owns | SyncEngine owns |
|---|---|
| Receiving typed triggers, applying lifecycle eligibility, debounce/cadence, retry backoff/exhaustion, and injected timers/jitter. | Executing one account-scoped run against the local sync store, authorization port, Google Tasks port, and clocks. |
| Allowing at most one run, coalescing triggers, retaining `followUpRequired`, enforcing the outer run deadline, and requesting cancellation. | Recovering/claiming generations, performing ordered phases, classifying adapter outcomes, honoring cancellation at safe boundaries, and returning a typed report. |
| Projecting active/queued/waiting/exhausted runtime facts used by SyncHealth. | Strict wire validation, scope completeness, operation-specific uncertainty recovery, and transactional publish/acknowledgement. |

The coordinator never interprets task conflicts or mutates task/base/desired
rows. The engine never reads lifecycle APIs, navigation, selection, focus,
editor buffers, or ViewModels and never schedules itself. Repository
transactions are the only path from user intent into durable sync work.

### Stale responses and superseded work

Every request carries its run ID, operation-attempt ID, local resource key, and
claimed desired generation in local memory; the durable attempt stores the same
association. A response may commit only after a transaction rechecks that
identity against current durable state.

- A response for an older desired generation may update the confirmed remote
  base when it proves what Google accepted, but it cannot overwrite a newer
  projection or clear the newer generation.
- A response received after timeout/cancellation is handled as evidence for its
  recorded uncertain attempt, never as success for the current run.
- A page from a superseded/cancelled run may publish only if the durable run is
  still allowed to publish and its scope generation has not been replaced.
  Otherwise it is discarded and diagnosed.
- A run that completes while `followUpRequired` or a newer desired generation
  exists may advance last verified success only if its own required enumeration
  and claimed operations completed. Health remains Pending and the follow-up
  starts immediately; the older run can never clear the obligation or produce
  Good.
- Finalization compares the durable run ID and state. A late finalizer cannot
  overwrite a newer failure, retry episode, authorization state, or last-success
  record.

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
- persisted `reauthorizationRequired`, retry episode, server-not-before, and
  `automaticRetryExhausted` facts;
- the latest explicit failure reason and safe diagnostic code.

It produces exactly the accepted four top-level outcomes:

| Outcome | Exact foundational rule |
|---|---|
| **Inactive** | `syncEnabled=false`, or usable Tasks authorization is absent/terminally rejected. Reason is mandatory: `syncStopped` or `noAuthorization`. Reauthorization-required is persistent and prominent; unresolved counts remain visible. |
| **Failed** | A failure has been detected and no retry request is executing; automatic backoff/exhaustion is waiting; a permanent/application/persistence failure exists; the two-minute run timed out; known connectivity proves no route; or last success is at least five minutes old without active verification. Reason is mandatory: `noConnection`, `remoteFailure`, `applicationFailure`, or `stale`. |
| **Pending** | Authorization is usable and a nonfailed verification/run is active or immediately queued; a retry request is actually executing; local work is inside its 5–10 second debounce or task-delete Undo grace; or durable pending/in-flight/uncertain work awaits an eligible immediate run. A future backoff timer alone is not Pending. |
| **Good** | Sync is enabled; authorization is usable; the latest forced or scheduled required run completed successfully less than five minutes ago; connectivity is not known unavailable; and there is no newer failure, required verification, active/queued work, follow-up, retry episode, or pending/in-flight/uncertain/failed desired state. |

Evaluation order is Inactive, Failed, Pending, Good, with one narrow exception:
an executing retry request is Pending. Merely having an active run does not hide
a failure detected elsewhere in that run. A known disconnected hint invalidates
Good immediately and schedules verification when connectivity may return; a
positive hint never proves Google reachable. At exactly five minutes after last
verified success, health becomes Failed `stale` unless verification is actively
executing, in which case it is Pending.

### Exact transition events

| Event | Result |
|---|---|
| Database opens, sync enabled, authorization not yet validated | Pending `checkingAuthorization`; no cached state is called current. |
| Startup/resume trigger with usable authorization | Pending `verifying` until the run finalizes. |
| Local mutation commits | Pending immediately; its debounce deadline is visible as queued local work. |
| Task deletion commits during Undo grace | Pending immediately; Undo remains available until the durable expiry and no refresh may dispatch that delete early. |
| Complete successful run, no unresolved/follow-up work | Good; persist last verified success from the injected wall clock and start a five-minute monotonic freshness deadline. |
| Complete successful run with newer pending/follow-up work | Pending; last-success may advance, but the follow-up obligation forbids green. |
| Transport/remote/application/persistence failure is detected | Failed immediately, even before automatic backoff is exhausted. Preserve last-success time and unresolved counts. |
| Automatic retry request begins | Pending `retrying`; if it fails, return immediately to Failed during the next wait. |
| Five-minute retry episode exhausts | Failed with Retry; automatic triggers remain latched off for that episode. |
| Tasks authorization becomes terminally unusable | Inactive `noAuthorization` immediately with Reauthorize; no retry timer. |
| Reauthorization succeeds | Pending `verifying`; only a complete sync may produce Good. |
| Connectivity becomes known unavailable | Failed `noConnection`; potentially restored connectivity queues verification but does not change health to Good. |
| Last-success age reaches five minutes | Failed `stale`, or Pending only if verification/retry is executing. |
| User stops synchronization | Inactive `syncStopped`; cache, authorization, and unresolved intent remain. |
| User resumes synchronization after `syncStopped` | This explicit button clears retry exhaustion and starts a new episode with immediate verification when authorization is usable; reauthorization-required still presents Reauthorize instead of issuing a request. |

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
- Google service/rate-limit failures use `remoteFailure`; only an executing
  retry request moves them temporarily to Pending;
- a hung run becomes Failed at its monotonic deadline;
- partial publication does not advance last verified success;
- `confirmed` and `superseded` history do not count as unresolved work;
- process restart re-derives runtime phase from durable attempts/desired state
  and cannot clear durable failure evidence merely by resetting memory.

Green is forbidden when any of these holds: sync stopped; authorization unknown,
refreshing, absent, or rejected; startup/resume verification outstanding;
connectivity known unavailable; a run/retry is queued or active; last success is
at least five minutes old or absent; any failure is newer than success; any
required scope was partial; any follow-up is required; automatic retry is
waiting/exhausted; or any pending, in-flight, uncertain, or failed desired state
exists.

Every non-Good state shows the exact last-success wall time and human-readable
age, or “Never” when none exists. Failed stale presentation says how old the
verified data is; it never replaces that fact with a generic connection icon.
Good shows “Synced” and that same exact completion time. It does not use the
absolute label “Up to date,” because successful traversal is the available
evidence and Google does not provide atomic pagination.

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
Its S29A file retains the newest 500 typed records.

The debug development product additionally composes a bounded sensitive sink.
It does not sample or suppress failures or sync boundary/state transitions. It
records task titles/notes, decoded API request and response context, redacted
authorization state/errors, remote IDs, desired-state/attempt/coordinator
transitions, database operations/values, repository/UI commands, stack traces,
timing, and unsupported resources. Its searchable live view is one interaction
from sync details and is permanently marked as containing private test-account
data. Export is explicit; files/exports are local and ignored by Git.
Its separate S29A file retains the newest 1000 typed records.

Both products scrub credentials before event construction. Access/refresh
tokens, authorization headers/codes, client secrets, PKCE verifiers, DPoP
private keys, secure-store values, and unredacted OAuth callback URLs are never
logged. There is no automatic upload or telemetry, and release composition has
no runtime path to the sensitive sink.

Sync phase starts, coordinator fact changes, typed failures, uncertain-operation
resolutions, and aggregate automatic-resolution counts enter the same injected
sink. The release aggregate contains counts only; development may additionally
retain the private run/resource evidence supplied by the producer.

## Process death, restart, and persistence recovery

### Durable-boundary recovery matrix

| Last durable boundary before process death | Restart interpretation and recovery | Preserved invariant |
|---|---|---|
| Before local mutation transaction commits | The command was never acknowledged; no projection or intent exists. | UI success never precedes durable intent. |
| After local commit, before coordinator notification/debounce | Discover `pending` from SQLite and schedule according to startup eligibility. | Lost callbacks cannot lose work. |
| After durable run begin, before an operation claim | Mark the run interrupted; no mutation is inferred. Start normal recovery/verification. | An abandoned runtime flag cannot remain Pending forever. |
| After generation is claimed `inFlight`, before/while request dispatch | Conservatively mark a mutation `uncertain` unless durable transport evidence proves it could not leave the device. Apply operation-specific recovery. | No possibly committed mutation is blindly treated as unsent. |
| After Google response, before acknowledgement transaction | The prior `inFlight` attempt is uncertain; read back/recover. A create may retry and duplicate by accepted policy. | Remote success is never invented or forgotten as safe-to-create. |
| During acknowledgement transaction | SQLite atomicity yields either the old `inFlight` state or the complete new base/identity/resolution. Recover the former as uncertain. | Remote ID/base/projection/intent cannot be half-acknowledged. |
| After acknowledgement, before next dependent operation | Confirmed/superseded state is retained; resume only unresolved dependents. | Partial success is not replayed or rolled back. |
| During page publication | The page transaction is wholly present or absent. Scope completeness remains false until terminal page evidence commits. | Partial pages cannot justify absence deletion or Good. |
| After all work, before finalization commits | Mark run interrupted; do not advance last success. Confirmed per-operation results remain. | Last success means durable complete finalization only. |
| After finalization commits | Reconstruct health/cadence from the committed outcome and age; startup still requires new verification. | Restart cannot turn cached success directly green. |

Startup recovery runs before new remote work in one serialized engine. It marks
abandoned runs interrupted, resolves every `inFlight` mutation to `uncertain`,
preserves newer desired generations, restores retry/reauthorization/exhaustion
latches, and derives one verification obligation. Recovery itself is
transactional and idempotent so a second crash repeats it safely.

### Database failures

A local command transaction failure rolls back projection and desired state,
returns a typed persistence failure, and never publishes UI success. The user
may retry the command only after storage is usable.

If a remote response is received but its acknowledgement transaction fails, the
engine starts no further Google operation. If SQLite still accepts a separate
failure transaction, the attempt becomes `uncertain`; otherwise its already
durable `inFlight` state produces the same result on restart. The response is
not replayed from memory as proof after process loss.

If SQLite becomes unavailable during a run, the engine cancels network work at
the next safe boundary and health becomes Failed `applicationFailure` while
readable cached state remains. If the database cannot be read at all, the normal
task UI is replaced by a recovery surface: Retry Open and access to safe
diagnostics. It does not show an empty task list, start sync, or accept edits.

Malformed/corrupt database files, including their WAL/SHM companions, are closed
and preserved in place. They are never automatically moved, overwritten,
deleted, or replaced with an empty production database. Automatic recovery is
limited to SQLite-supported non-destructive open/recovery steps whose result
passes schema and integrity validation. Any quarantine, destructive reset,
import, or replacement requires a separate explicit user action and is outside
this synchronization run.

### Reliability invariants and failure proof

1. **Durable acknowledgement:** every acknowledged mutation already has one
   transactionally consistent projection and desired-state generation. Local
   transaction failure returns no success.
2. **No network transaction:** no SQLite transaction spans network IO. Timeout,
   cancellation, or process death therefore cannot strand a database lock.
3. **Atomic remote acknowledgement:** remote identity, base, projection,
   generation result, and attempt outcome commit together. Failure before commit
   remains recoverably uncertain.
4. **Serialized authority:** only one account run executes; triggers coalesce and
   cannot create competing writers. A final transaction rechecks run and desired
   generation before publishing.
5. **No blind mutation replay:** uncertain outcomes use operation-specific
   recovery. The sole deliberate exception is uncertain create, whose possible
   duplicate is accepted and never content-deduplicated.
6. **No destructive absence:** only positive deletion evidence applies delete;
   incomplete/failed scopes disable absence processing. Unrelated tasks,
   children, lists, and accounts remain outside the transaction target.
7. **Partial success durability:** each successful operation is acknowledged;
   later failure preserves it and leaves only unresolved/dependent work.
8. **Truthful health:** only complete durable finalization can advance last
   success; every failure is visible immediately and every listed green-forbidden
   fact remains non-green.
9. **Bounded activity:** request/run deadlines, bounded request retries,
   five-minute automatic-retry exhaustion, and safe cancellation prevent
   indefinite Pending or request storms.
10. **Restart equivalence:** missing exit callbacks and process death at every
    durable boundary reduce to persisted `pending`, `inFlight`/`uncertain`,
    confirmed/superseded, partial-scope, or finalized state—never an unrecorded
    success.
11. **Account isolation:** every query, operation, attempt, retry latch, and
    publication is account-scoped; recovery cannot attach data to a different
    authorization subject.
12. **Privacy-preserving evidence:** production diagnostics contain only safe
    structured facts. Development diagnostics retain allowed sensitive task/API
    evidence, but neither sink contains credential material.

### Required reliability tests

| Area | Minimum deterministic evidence |
|---|---|
| Debounce/coalescing | Mutations at 0/4/8 seconds run at 10 seconds; an isolated mutation runs at 5; triggers during a run produce exactly one follow-up; no overlapping engine call occurs. |
| Cadence/lifecycle | Linux requests a run five minutes after completion while minimized; Android runs only while resumed; pause cancels safely; startup/resume/connectivity transitions behave exactly as specified. |
| Deadlines | Boundaries immediately before/at/after 30 seconds and two minutes; no new request that cannot fit; mutation cancellation becomes uncertain. |
| Backoff | Inject minimum/maximum jitter for 1/2/4 request delays and 1/2/4/8/16/32/60 run delays; longer `Retry-After` wins; waiting is Failed; execution is Pending; five-minute exhaustion survives restart and requires Retry. |
| Authorization | One successful refresh; terminal refresh; second rejection; missing scope; cancelled and successful reauthorization; account-subject mismatch; no auth transition produces Good. |
| Partial retrieval | Failure on every task-list/task page, malformed row, and one failed list among successful lists; valid pages persist, affected writes/absence handling stop, and last success does not advance. |
| Partial operations | Success followed by independent/dependent failure for every operation class; acknowledged success is not replayed and dependents remain pending. |
| Uncertainty/idempotency | Every create/content/title/task-delete/list-delete/move uncertainty case from the reconciliation matrix, including a newer desired generation during uncertain create, accepted duplication, and cross-list source 404. |
| Stale/superseded responses | Late response after timeout/cancel, old desired generation, cancelled run page, late finalizer, and a newer local edit during acknowledgement. |
| Persistence/process death | Interrupt every durable-boundary matrix row in a killable subprocess using a real temporary SQLite database; fail before/after every transaction commit; repeat startup recovery twice; unavailable/corrupt DB never becomes an empty cache. |
| SyncHealth/freshness | Every exact transition event and every green-forbidden predicate at one millisecond before/at/after five minutes, with exact last-success age and “Never.” |
| Efficiency/quiescence | No-op run issues listing requests but no writes/attempts/follow-up; no trigger produces no work; request counts scale with pages/lists rather than rows plus targeted recovery reads; documented maximum-page and quota-cost fixtures fail visibly rather than truncating or becoming Good. |

Model tests assert all invariants after each transition rather than checking
source strings. Integration tests use fake clocks/randomness and strict Google,
authorization, connectivity, lifecycle, and storage ports; real-API tests remain
limited to capability evidence that a fake cannot establish.

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
- A generic or hidden HTTP retry interceptor.

## Accepted implementation capability gates

Stage 4 has no unresolved synchronization-policy question. The following are
explicit evidence gates for the affected adapters or later UX slices; they do
not authorize an implementation to guess or silently fall back:

1. Complete safe platform-auth evidence for expired, revoked, and wrong-scope
   cases. The current probe establishes only malformed bearer as 401.
2. The S07 P12 follow-up admits JSON `null` for the supported optional `notes`
   and `due` fields. Any future writable optional field needs equivalent
   evidence. The stale-source DELETE follow-up admits only the conservative
   adapter boundary because its retained resolution omitted the exact HTTP
   status and destination live/tombstone bit. Delete/move recovery therefore
   still never confirms deletion from an old-list absence or stale-path
   response; exact fake semantics require a retained sanitized result.
3. Probe `webViewLink` presence/navigation with an ordinary and recurring task
   created in the current Google UI before implementing the recurrence escape
   hatch.
