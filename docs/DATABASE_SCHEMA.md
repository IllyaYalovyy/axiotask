# Database schema version 1

Schema version 1 is the first intentional Axiotask SQLite format. It contains
the account-scoped Google cache foundation; there is no migration from an older
Axiotask implementation or from the earlier development-only `accounts` proof.
An existing file must match the exact version-1 schema digest, pass SQLite
integrity checking, and have no foreign-key violations before Drift opens it.
Unknown, modified, or corrupt files are preserved and rejected rather than
replaced with an empty cache.

## Tables

| Table | Responsibility |
|---|---|
| `accounts` | Stable local account key and unique verified Google subject. No email address or credential is stored. |
| `task_lists` | Materialized list projection with a stable local key, account key, separate nullable Google ID, title, and supported/deleted/unsupported projection boundary. |
| `tasks` | Materialized task projection with stable local/account/list/parent keys, separate nullable Google ID, supported content, date-only due epoch day, opaque Google position, and projection boundary. |
| `task_list_remote_bases` | Last confirmed list content, Google identity/version metadata, and the publication that observed it. |
| `task_remote_bases` | Last confirmed supported task content, structure, lifecycle, links, Google identity/version metadata, and the publication that observed it. |
| `scope_completeness` | Account list-enumeration or per-list task-enumeration page-chain state, including the opaque next-page token while incomplete. |
| `account_preferences` | Relational account settings: sync-enabled control, optional account-owned default list reference, and the next account-scoped causal sequence for durable desired state. |
| `sync_facts` | Account-scoped last verified success, newest failure, unresolved-work counts, reauthorization/retry/scope/follow-up facts used by the truthful health projection. Runtime authorization, connectivity, and active phase remain injected observations rather than durable guesses. |
| `desired_states` | One coalesced account/resource intent with stable local target, present/deleted lifecycle, optional bound Google ID, original confirmed whole-content base snapshot, full desired list/task fields, dirty facets, exact delete `not_before`, generation, causal sequence, and current lifecycle. S14A writes list content; S14B writes complete task content; S16 compares the preserved base during reconciliation; S17 records authoritative delete intent. |
| `desired_state_dependencies` | Typed account-scoped ordering edges between desired resources, with composite foreign keys preventing cross-account dependencies. Provisional task creates record their list and optional parent references; list edits need no edge. |
| `desired_state_attempts` | Immutable claimed generation/payload snapshots with present/deleted lifecycle, request identity, optional delete eligibility boundary, and durable lifecycle/failure, uncertainty, confirmation, or supersession evidence. A 412 may supersede one attempt and create a fresh attempt for the same desired generation after refetch/replan. |
| `task_delete_tombstones` | One account/root-task durable Undo and deletion record, tied to the exact desired generation with its 30-second `not_before` boundary and snapshot-availability bit. |
| `task_delete_snapshots` | Account-scoped bounded task/subtree snapshots preserving stable local/remote identity and supported content until Undo expiry; cleanup strips content while retaining minimal deletion/scope evidence. |
| `task_due_change_groups` | The one currently available account-scoped grouped due Undo, with edited task, exact snapshot count, propagation direction, and durable acknowledgement time. |
| `task_due_change_snapshots` | Account/task-owned prior date-only values for every row in the accepted due cascade; deleting a group cascades only to its snapshots. |
| `bulk_operations` | The latest durable non-destructive bulk result per account: operation kind, selected/affected counts, exact confirmed/pending/failed counts, and acknowledgement time. |
| `bulk_operation_members` | One account/task member per affected Google resource, pinned to the exact desired generation whose attempt lifecycle determines that member's durable result. |
| `task_list_preferences` | Account/list-owned sidebar order and smart-view exclusion storage. |
| `view_preferences` | Account/view-owned sort and completion-filter storage. |

The preference tables are exposed through the S22A typed application
repository. List order/exclusion and per-view sort/completion filtering remain
account-scoped in these tables; theme, density, and onboarding dismissal are
device-only and never enter SQLite.

S22B consumes the relational rows reactively through the same typed repository.
Unknown/new supported lists use defaults and append after explicitly ordered
lists; deleted/unsupported lists leave the ordinary projection. Smart-view
exclusion, per-view completion filtering, and sorting are then applied by one
pure domain projection, so sidebar counts are the length of the same rows the
collection renders rather than a separate SQL approximation.

## Invariants

- Every cache, remote-base, completeness, and relational-preference row carries
  or derives an `account_id`. Composite foreign keys prevent a task, parent,
  remote base, or preference from attaching to another account or list.
- Missing list preferences default to no explicit sidebar order and inclusion
  in smart views. Missing view preferences default to manual sorting with
  completed tasks hidden. Both projections are reactive and require an explicit
  account plus list/view key; no unscoped preference read exists.
- Repository reads require an `AccountId`; every list/task predicate and join is
  constrained by that account. There is no unscoped task read API.
- Local list/task IDs are SQLite-assigned 64-bit identities. Google IDs are
  separate external values, unique by account and resource type. Binding a
  Google ID does not replace the local ID.
- Google IDs are nullable because a durable create needs a provisional local
  identity. A supported list or task without a Google ID enters a repository
  snapshot only while the same account/local key has unresolved present desired
  state. An orphan provisional row stays hidden and cannot behave as a
  local-only resource.
- A task parent must be in the same account and list. Cache writes reject a
  parent that is already a child, so the supported projection has only a top
  level and one subtask level.
- Remote bases are separate from materialized projections. Updating projected
  content or structure cannot silently overwrite the historical agreement
  point; a task base may retain its confirmed source list while its projected
  row targets another account-owned list.
- Live task bases require title, status, and position; tombstone bases may
  retain only fields Google supplied. Date-only due values are integer UTC
  epoch days, and task-link JSON and absolute URIs are strictly decoded.
- Unsupported, deleted, and orphan provisional projection rows are preserved
  but excluded from ordinary snapshots. A read never flattens, repairs, deletes,
  or exposes unsupported data as supported tasks.
- Page-chain completeness is account-scoped and keyed uniquely even for the
  account-wide list scope. It becomes complete only when its next-page token is
  absent. Aggregate cache completeness requires the list scope and every
  selected supported list scope from the same publication walk to be complete.
- `CacheCompleteness.complete` means only that a recorded page walk terminated.
  Every `CachedTasksSnapshot` is explicitly `unverifiedCache`; it supplies no
  last-success, authorization, connectivity, pending-work, or freshness fact
  and therefore can never establish healthy synchronization.
- `sync_facts.last_successful_sync_at` is written only for a completed required
  synchronization. Failure reason/time/diagnostic/action are one nullable unit;
  unresolved counts are non-negative. Missing rows mean no success, failure, or
  unresolved work, never implicit freshness. `account_preferences.sync_enabled`
  is joined into the same account-scoped projection.
- List create and rename acknowledge success only after one SQLite transaction
  commits the materialized projection, coalesced `desired_states` row, causal
  sequence, and recomputed unresolved count. A failure at any boundary rolls
  the entire edit back, so UI success cannot precede durability.
- Repeated list renames preserve the first confirmed base snapshot and stable
  local identity while incrementing the desired generation and replacing only
  the requested title. Remote read publication may advance the confirmed base,
  but cannot overwrite a pending projected title.
- Task create/title/notes/due/completion commands commit projection, complete
  desired content, causal generation, dependency rows, and unresolved counts in
  one transaction. Empty, cleared, Unicode, multiline, and date-only values are
  preserved; repeated edits retain the original confirmed base and local key.
- A due action first computes the complete edited-row-wins plan. One transaction
  updates every affected projection and coalesced whole-content desired state,
  then replaces the account's prior available due Undo with a group whose exact
  snapshot count covers the edited row and every propagated row. A group is
  offered only when a related row changed. Undo validates the entire group and
  restores every prior date plus desired state atomically; a missing or partial
  group changes nothing. Group/snapshots survive restart and never assign a date
  to an undated related row or propagate a clear.
- Non-destructive bulk complete, reschedule, and move validate the entire
  selection, affected due cascade, destination, and synchronizability before
  one transaction changes any projection. The transaction writes at most one
  desired row and one bulk member per affected resource. Selecting a parent and
  its child for a cross-list move records only the independent parent Google
  MOVE while preserving the subtree. The latest result survives restart:
  matching confirmed generations count as confirmed; unresolved
  pending/in-flight/uncertain generations count as pending; conclusive failure,
  supersession, or local replacement before dispatch counts as failed. These
  counts always sum to the affected-resource count and never rewrite confirmed
  remote successes.
- Promote, demote, reorder, and cross-list move commands validate the complete
  direct subtree and `previous` anchor before one transaction changes the
  projection and coalesced structure facet. Desired rows and immutable attempts
  retain list, parent, previous, opaque position, and sibling-order base
  evidence. Pending structure survives reads and restart, publishes by stable
  ID through Google MOVE, then adopts Google's canonical returned position. A
  task with children cannot be demoted, and a child, missing/deleted anchor, or
  cross-account/list relationship is rejected before any row changes.
- A supported provisional task is projected only while an unresolved present
  task intent exists. Its non-Google `local-pending` position is local ordering
  scaffolding until a later create acknowledgement stores Google's canonical
  position; it is never interpreted or sent as a Google position.
- Claiming an outbound generation records its immutable request snapshot before
  network work. Legal lifecycle transitions are explicit, and completing an
  older attempt cannot clear a newer coalesced generation. Atomic create
  acknowledgement binds the Google ID and canonical base/projection while
  resolving only the matching generation.
- Task deletion atomically hides the supported root and descendants, stores one
  tombstone plus bounded snapshots, and records a deleted desired generation
  whose `not_before` is exactly 30 seconds after acknowledgement. Before that
  boundary Undo restores the same local and Google identities and supersedes
  the unclaimed deletion. At and after the boundary cleanup removes Undo
  content and only then permits a claim. A claimed delete recovered after
  process death becomes uncertain, never implicitly successful.
- Task DELETE acknowledgement requires a positive Google tombstone for the
  stable task ID. A moved child is removed from a parent snapshot before the
  parent cascade is applied, preserving the same identity in its observed
  surviving list. List deletion has no snapshot/Undo and hides only its
  account-scoped list after explicit UI confirmation.
- S15A selects only pending unbound create generations after complete applicable
  enumeration. It claims lists before top-level tasks before children; resolved
  dependency Google IDs are read from account-scoped cache rows. A conclusive
  rejection stores a failed code, while an interrupted or ambiguous create
  stores an uncertain code and is not selected again by this non-retry slice.
- S20A startup/run recovery preserves every uncertain unbound-create attempt and
  selects only the latest unresolved attempt in that original generation for one
  recovery replay per run. Recovery never compares content. A canonical response
  atomically binds its returned Google ID while older uncertain attempts remain
  evidence; a newer edit, move, or delete generation remains pending against the
  new base. List and parent dependencies still resolve before task recovery.
- S20B blocks a newer content or structure generation while an older attempt is
  in flight or uncertain. After complete enumeration, exact whole-content or
  stable-placement evidence resolves the older attempt and rebases only its
  facet; the newer generation remains pending when it still differs. A
  non-matching observation supersedes the old attempt and the existing
  reconciliation policy decides the current generation. Task-delete recovery
  retains the stable-ID/current-list tombstone rule. An uncertain list delete is
  confirmed only by a direct exact-identity 404; a live identity transactionally
  supersedes that attempt before one new delete claim, whose success is read
  back again. Read failure or ambiguity leaves uncertainty durable and health
  non-green.
- S21A stores each run ID, sorted trigger set, start time, terminal state/time,
  and safe failure code in account-scoped `sync_runs`. Beginning a run
  interrupts any older unfinished row before establishing its first incomplete
  page checkpoint. Startup recovery transactionally interrupts abandoned rows,
  maps all `in_flight` attempts to operation-specific `uncertain` evidence,
  preserves a newer desired generation, performs eligible delete cleanup,
  recomputes unresolved counts, and records a verification obligation without
  clearing retry, exhaustion, or reauthorization latches. A repeated recovery
  changes nothing. Success/failure finalization requires the same run to remain
  active, so an older finalizer cannot alter last success, current failure, or
  checkpoint authority after a newer run begins.
- S21B validates an existing database against a private temporary copy of its
  main file and any WAL/SHM companions before opening the originals.
  Validation/open/read failure leaves every original in place and prevents
  account projection, editing, transport construction, and synchronization.
  Retry Open repeats validation against the same originals. Killed-process
  tests qualify local commit, claim, acknowledgement, partial page/operation,
  finalization, and recovery-transaction boundaries against real file-backed
  SQLite rather than exception-only simulation.
- S15B confirms an eligible pending content generation without a mutation only
  when the complete current scope proves Google already holds the exact desired
  title or task snapshot. Otherwise, unchanged confirmed bases allow immutable
  task-content attempts before list-title attempts. Task attempts snapshot every
  supported content field and use the current ETag; canonical acknowledgements
  advance the base atomically and cannot clear a newer desired generation.
  Rejected or ambiguous updates remain failed/uncertain.
- S16 compares each pending or uncertain content generation with its complete
  original task-content/list-title base and the complete current publication.
  One-sided changes are retained; two-sided changes use strictly-newer local
  time with Google winning later/equal timestamps. Missing base or timestamp
  evidence fails closed. Google winners atomically replace the complete
  projection/base and become superseded; local winners rebase before dispatch.
  Task 412 handling supersedes the immutable attempt, refetches the task scope,
  and replans the same generation without weakening ETag protection.
- S13B Stop/Resume updates only `account_preferences.sync_enabled` in one
  account-scoped transaction. It does not delete or rewrite cache rows, remote
  bases, health evidence, unresolved counts, account identity, or credentials.
- An S12A read run uses its opaque publication ID as the durable page-walk
  identity. Begin marks the required scope incomplete, every page transaction
  replaces only that scope's token/completeness evidence, and finalization
  advances `sync_facts.last_successful_sync_at` only after the list scope and
  every list selected by that publication have terminal task scopes. An
  interrupted or failed publication remains incomplete and retains the prior
  success time and previously valid cache rows.
- SQLite foreign keys remain enabled and multi-row writes use explicit
  transactions. Failed transactions may re-emit an unchanged Drift snapshot,
  but cannot expose or retain partially written state.

OAuth tokens, DPoP keys, authorization headers, release diagnostics, and
device-only preferences are not part of these cache/health/desired-state
tables.
