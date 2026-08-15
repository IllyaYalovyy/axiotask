# Functional parity execution plan

- Status: **Accepted Stage 5 plan**
- Scope: behavioral parity from the Rust/Tauri client to the new Flutter client
- Updated: 2026-08-11

This plan prevents accidental feature loss while allowing deliberate redesign.
The Rust/Tauri application on `main` is read-only behavioral evidence, not an
architecture or schema precedent. The discarded Flutter project is not evidence
and is not referenced here.

## How to use this plan

Each capability has a stable parity ID. A vertical slice may change
**Implementation** from `Not started` only when its specified behavior exists.
It may change **Verification** from `Not run` only when every required evidence
layer passes and its artifacts have been reviewed. A drop still requires a test
or architecture assertion where accidental reintroduction is plausible.

Decisions mean:

- **Retain** — the user capability remains a parity requirement.
- **Redesign** — the user need remains, but Rust behavior is intentionally
  replaced for correctness, platform fit, or accepted architecture.
- **Drop** — the behavior is intentionally unsupported.
- **Defer** — not in the first usable milestone; any architectural prerequisite
  stated in the row is still required now.

Evidence codes are `U` domain/unit, `P` persistence, `C` adapter/contract, `W`
widget/ViewModel, `I` application integration, `S` synchronization, `V` golden
plus inspected Fedora/Android screenshots, `G` opt-in real Google, and `D`
physical-device/platform proof. `—` means that layer is not applicable.

Rust evidence uses these read-only `main`-branch path prefixes: `app:` means
`crates/axiotask-app/src/`, `ui:` means `crates/axiotask-app/ui/src/`,
`ui-test:` means `crates/axiotask-app/ui/src/__tests__/`, `core:` means
`crates/axiotask-core/src/`, and `design:` means `designs/`. Tests are evidence
of intended Rust behavior only; they do not verify Flutter behavior.

## Accepted cross-capability contracts

### Backup/export and restore/import

Export is an explicit, versioned JSON snapshot of one selected account's
supported lists and tasks. It contains current projected user data, including
acknowledged offline edits, list/task relationships, ordering, completion,
notes, and due dates. It may contain the source Google subject and remote IDs
needed for identity matching. It excludes credentials, authorization material,
sync attempts, diagnostics, device preferences, and implementation-specific
database rows. The file and file picker warn that the export contains private
task data.

Import is intended primarily to recreate a backup into an empty or mostly empty
Google account:

1. The user explicitly selects the target account and file.
2. The complete document is parsed, bounded, version-checked, and validated
   before any write. Validation includes unique item keys, referential
   integrity, exactly one subtask level, supported values, and size limits.
3. Import requires a successful current full synchronization of the target
   account before planning, because existing remote records must win. Offline,
   stale, stopped, or unauthorized import does not mutate local state.
4. Existing local or Google records with matching authoritative identity are
   left unchanged. Import never overwrites or deletes them and never matches by
   title, notes, dates, or other content.
5. Every absent list/task is recreated through one validated account-scoped
   repository transaction and the normal durable desired-state pipeline. Lists
   precede tasks; parents precede children; structure and ordering are applied
   through normal synchronization operations.
6. A durable import manifest makes restart and retry idempotent within the same
   local account partition. A cross-account import or a repeat after deleting
   that manifest cannot identify prior copies by content and may create
   duplicates; the preview states this limitation.
7. Local acknowledgement is all-or-nothing. Google publication may succeed per
   operation as specified by synchronization; failures remain visible and
   retryable without rolling back confirmed remote operations.

### Delete and undo

Deleting a task does not immediately erase its local row. One SQLite transaction
hides it from normal projections, records the authoritative delete intent, and
stores a bounded undo snapshot of the task and supported descendants. The
snapshot expires 30 seconds after acknowledgement using the injected clock. The
delete is not eligible for remote dispatch during that grace period, including
during explicit refresh, so Undo can restore the original local/remote identity
without racing Google.

Undo consumes the tombstone snapshot transactionally, supersedes the unclaimed
delete intent, and restores the same task/subtree as pending desired state. If
the grace period has expired or a delete was already dispatched because of a
recovered older state, deletion of the old Google identity remains authoritative
and Undo is unavailable; the client never pretends that Google supports
undelete. List deletion and Clear completed have no undo and require explicit
confirmation.

At expiry, the UI removes Undo and a cleanup transaction strips the content
snapshot while retaining the minimal deletion identity/evidence required by
synchronization. After Google deletion is confirmed and no recovery dependency
remains, ordinary desired-state compaction removes the tombstone. Startup and
resume perform the same clock-driven cleanup, so correctness never depends on a
timer callback or an open toast.

### Bulk-operation failure semantics

A bulk command validates the entire selection first. One SQLite transaction
applies every selected local change and creates/coalesces one desired-state
record per affected resource; a local validation or transaction failure accepts
none of the command. After acknowledgement, synchronization treats those
resource operations independently. Safe independent successes remain
confirmed, failed or dependent operations remain pending/failed, and the result
surface reports exact succeeded, waiting, and failed counts. It never reports
the original selection count as success after an early failure.

Bulk delete follows the task undo grace as one durable undo group. Undo restores
the entire group or none of it. Clear completed is a distinct destructive
operation: it skips completed parents with unfinished children, requires
confirmation, has no undo, and follows per-task remote results after its local
transaction commits.

### Unsupported hierarchy

The product creates and represents only top-level tasks and one subtask level.
Unexpected deeper remote data is retained only as protected raw/base evidence
for diagnosis; it is not projected as a supported task, edited, moved, flattened,
or deleted. The affected scope becomes Failed with `applicationFailure`, valid
unrelated scopes may remain visible, and development diagnostics expose the full
allowed payload. No repair or placeholder task is invented.

### Refresh, recovery, and Reset Local Data

Refresh requests the complete accepted synchronization procedure and never
deletes local state first. Retry Open handles non-destructive database-open
recovery. These are distinct from **Reset Local Data**, an explicit destructive
product action.

Reset Local Data warns that cached data, pending and uncertain changes, undo
records, sync history, account-scoped preferences, and import manifests for the
selected account will be permanently discarded. After explicit confirmation it
cancels/serializes against synchronization, deletes that account partition in
one controlled transaction, and starts a full Google rebuild. Authorization and
device-only presentation preferences remain. If Google is unavailable, the
empty selected-account cache remains visibly Failed until a later successful
rebuild. The reset never claims it can recall an uncertain mutation already sent
to Google.

A separate destructive reset may exist in development tooling only against an
explicit isolated test root. Push-disabled/read-only mode remains a harness
property, not a release setting.

## Connection, synchronization, and account scope

| ID | Capability | Rust behavioral evidence | Decision and intentional difference | Intended Flutter behavior | Domain / UX specification | Required evidence | Implementation | Verification |
|---|---|---|---|---|---|---|---|---|
| `PAR-AUTH-001` | Connect Google account | `app:commands.rs` auth commands; `design:RFC-001-auth-oauth-pkce.md` | **Redesign** — replace Tauri flows and plaintext desktop persistence with accepted platform adapters. | Native Android authorization and Linux browser PKCE/DPoP expose one typed account state; connection alone never implies healthy sync. | [Authentication boundary](ARCHITECTURE.md#authentication-boundary), [ADR 0003](adr/0003-authentication.md) | U,C,W,I,G,D,V | S05 Linux adapter and S12B configured-account restore/read wiring complete; interactive application connection and Android remain later slices | Linux authorization suites; `test/app/composition/composition_test.dart`; `integration_test/read_slice_linux_test.dart` |
| `PAR-AUTH-002` | Sign-out/account removal | `app:commands.rs::auth_logout` | **Drop** — it is not needed to stop synchronization and lacks an accepted credential/data lifecycle. | No release sign-out, disconnect, revoke, or remove-account action. Stop Sync is the control. | [Credential lifecycle](SECURITY.md#credential-lifecycle) | U,W,I | Not applicable | Not run |
| `PAR-ACCOUNT-001` | Multiple accounts | `app:state.rs` exposes one active application state. | **Defer UI; retain schema readiness** — future multi-account support must not require a data migration. | Initial UI configures one account; every persistent row and uniqueness rule is account-scoped so later accounts remain isolated. | [Identity and account scoping](ARCHITECTURE.md#identity-and-account-scoping), [SYNC_SPEC](SYNC_SPEC.md#identity-and-account-isolation) | U,P,S,I | S10 schema/read boundary complete; UI deferred | `test/data/database/tasks_repository_test.dart` |
| `PAR-SYNC-001` | Truthful sync health | `ui:Sidebar.svelte`; `ui-test:Sync.test.js`; `ui-test:AuthRecovery.test.js` | **Redesign; highest priority** — Rust's indicator did not reliably prove remote success. | Exactly Inactive, Good, Failed, or Pending; green only after a successful required run and never while stale, unauthorized, failed, pending, or uncertain. | [Sync health vocabulary](UX.md#sync-health-vocabulary), [truthful SyncHealth](SYNC_SPEC.md#truthful-synchealth) | U,P,W,I,S,V | S13A foreground cadence and deadline runtime facts complete; retry and later write facts remain pending | Health/store/engine suites; `test/sync/coordinator/sync_coordinator_test.dart`; `test/app/foreground_read_coordinator_test.dart`; `integration_test/read_slice_linux_test.dart`; Linux widget/golden/screenshot evidence |
| `PAR-SYNC-002` | Stop/resume synchronization | Push/auto-sync settings in `ui:Properties.svelte` and `app:commands.rs` | **Redesign** — one scheduler control, not separate read-only/auto-sync product modes. | Stop prevents new Google work while preserving authorization, cache, and editable durable intent; Resume triggers catch-up. | [ADR 0004](adr/0004-sync-boundary-and-health.md) | U,P,W,I,S,V | S13B durable Linux Stop/Resume, active-read cancellation, restart preservation, stopped-work fixture, and immediate catch-up complete; mutation-dispatch uncertainty follows the outbound engine slices | `test/data/database/sync_settings_repository_test.dart`; `test/sync/coordinator/sync_coordinator_test.dart`; `test/app/foreground_read_coordinator_test.dart`; `test/features/tasks/{tasks_view_model,adaptive_shell}_test.dart`; `integration_test/read_slice_linux_test.dart`; Linux golden and actual screenshots |
| `PAR-SYNC-003` | Automatic and manual refresh | `ui:App.svelte::{doSync,refreshFromPull}`; `core:sync/engine.rs` | **Redesign** — use accepted serialized triggers and five-minute foreground cadence. | Startup, resume, connectivity-restored, local-edit debounce, cadence, pull-to-refresh, and Retry all request the same coordinator; connectivity is never health proof. | [Scheduling](SYNC_SPEC.md#serialized-runs-and-trigger-coalescing) | U,W,I,S | S13B completes production Linux connectivity hints, process-lifetime cadence, and Resume catch-up on top of S13A serialization/debounce/deadline behavior; Retry remains later | `test/app/linux_platform_adapters_test.dart`; `test/sync/coordinator/sync_coordinator_test.dart`; `test/app/foreground_read_coordinator_test.dart`; `test/features/tasks/tasks_view_model_test.dart`; `integration_test/read_slice_linux_test.dart` |
| `PAR-SYNC-004` | Offline cached reading/editing | `core:store/repo.rs`; `ui-test:OfflineFirst.test.js` | **Retain with new durability model** — offline is continuity, not a second backend. | Cached data remains usable; every acknowledged edit is durable before success and health is non-green until Google confirms it. | [Authority model](SYNC_SPEC.md#authority-by-operating-condition) | U,P,W,I,S,V | S12B cached reading, S14A/S14B durable acknowledgement, S15A/S15B outbound confirmation, and S16 deterministic content reconciliation complete for implemented create/update operations | `test/data/database/{task_lists,task_edits,sync_health_repository}_test.dart`; `test/features/tasks/{tasks_view_model,adaptive_shell}_test.dart`; `test/sync/{create,update}_sync_engine_test.dart`; `test/sync/content_reconciliation_multi_host_test.dart`; `integration_test/{read_slice_linux,offline_list_edits_linux,offline_task_edits_linux,create_publish_linux,update_publish_linux}_test.dart`; Linux actual screenshots |

## Lists, tasks, dates, and bulk work

| ID | Capability | Rust behavioral evidence | Decision and intentional difference | Intended Flutter behavior | Domain / UX specification | Required evidence | Implementation | Verification |
|---|---|---|---|---|---|---|---|---|
| `PAR-LIST-001` | Discover Google lists | `app:commands.rs::list_tasklists`; `core:sync/engine.rs` | **Retain**. | Enumerate every supported page for the configured account and publish validated lists incrementally without false completeness. | [API contract](GOOGLE_TASKS_API_CONTRACT.md), [run phases](SYNC_SPEC.md#run-phase-ordering) | U,C,P,I,S,G | S12B configured-account application read path complete | Engine/process-death/HTTP suites; `integration_test/read_slice_linux_test.dart` |
| `PAR-LIST-002` | Create, rename, delete lists | `ui-test:ListManagement.test.js`; `app:commands.rs` list commands | **Retain with accepted sync semantics** — no local-only creation and no guessed list preconditions. | Commands acknowledge durable desired state; deletion is authoritative, confirmed, and has no undo. | [Reconciliation](SYNC_SPEC.md#automatic-reconciliation-and-conflict-policy) | U,P,W,I,S,G,V | S14A durable offline acknowledgement, S15A outbound create/identity binding, S15B eligible rename publication/no-op suppression, and S16 base-aware whole-title reconciliation complete; delete remains later | `test/domain/task_list_commands_test.dart`; `test/data/database/task_lists_repository_test.dart`; `test/features/tasks/{tasks_view_model,adaptive_shell}_test.dart`; `test/sync/{create,update}_sync_engine_test.dart`; `test/sync/{reconciliation/content_policy,content_reconciliation_multi_host}_test.dart`; `integration_test/{offline_list_edits_linux,create_publish_linux,update_publish_linux}_test.dart`; Linux actual screenshots |
| `PAR-LIST-003` | Client list ordering | `ui:Sidebar.svelte`; `ui-test:ListReorder.test.js` | **Retain; storage redesign** — move from frontend storage to account-scoped SQLite. | Custom sidebar order survives restart; unknown/new lists append without corrupting saved references. | [Persistence](ARCHITECTURE.md#persistence) | U,P,W,I,V | Not started | Not run |
| `PAR-LIST-004` | Exclude lists from smart views | `ui:App.svelte::toggleExclude`; `ui-test:ListExclusion.test.js` | **Retain; storage redesign**. | Exclusion is account-scoped, relational, restart-safe, and affects smart views/counts consistently. | [Persistence](ARCHITECTURE.md#persistence) | U,P,W,I | Not started | Not run |
| `PAR-LIST-005` | Local-only lists | `main:crates/axiotask-core/schema.sql` `local_only`; `ui:Sidebar.svelte` creation path | **Drop** — contradicts Google-client product scope. | Domain/schema/repositories cannot acknowledge an unsynchronizable list. | [VISION non-goals](../VISION.md#non-goals) | U,P,W,I | Not applicable; S14A provisional lists require durable Google-targeted create intent and expose no local-only option | `test/data/database/task_lists_repository_test.dart`; `test/features/tasks/adaptive_shell_test.dart` |
| `PAR-TASK-001` | Create, edit, delete task | `app:commands.rs` task commands; `ui-test:DetailWorkflow.test.js`; `ui-test:DeleteUndo.test.js` | **Retain; redesign acknowledgement and deletion**. | Edits use atomic projected-state/desired-state transactions; delete uses the accepted durable grace tombstone. | [Mutation acknowledgement](SYNC_SPEC.md#transactional-acknowledgement-of-local-mutations), [delete contract](#delete-and-undo) | U,P,W,I,S,V | S14B durable offline acknowledgement, S15A top-level/child create and identity binding, S15B eligible complete-content publication/no-op suppression, and S16 deterministic whole-content reconciliation complete; delete remains later | `test/domain/task_commands_test.dart`; `test/data/database/task_edits_repository_test.dart`; `test/features/tasks/{tasks_view_model,adaptive_shell}_test.dart`; `test/sync/{create,update}_sync_engine_test.dart`; `test/sync/{reconciliation/content_policy,content_reconciliation_multi_host}_test.dart`; `integration_test/{offline_task_edits_linux,create_publish_linux,update_publish_linux}_test.dart`; Linux actual screenshots |
| `PAR-TASK-002` | Complete/reopen task | `app:commands.rs::toggle_complete`; `ui-test:CompleteUndo.test.js` | **Retain**. | Completion is whole-record content; returned Google cascade state is authoritative. Reopen does not imply reopening children. | [Content policy](SYNC_SPEC.md#content-and-structure-policies) | U,P,W,I,S,G,V | S14B local complete/reopen acknowledgement, S15B eligible complete-snapshot publication, and S16 whole-record/canonical cascade supersession complete | `test/domain/task_commands_test.dart`; `test/data/database/task_edits_repository_test.dart`; `test/features/tasks/{tasks_view_model,adaptive_shell}_test.dart`; `test/sync/{update_sync_engine,reconciliation/content_policy}_test.dart`; `integration_test/{offline_task_edits_linux,update_publish_linux}_test.dart`; Linux actual screenshots |
| `PAR-TASK-003` | Undo task deletion | `app:commands.rs::{DeleteToken,undo_delete}`; `ui:App.svelte` 30-second timer | **Redesign** — make the grace/tombstone durable and prevent remote dispatch during the undo window. | Thirty-second task/bulk-task Undo survives restart; list delete and Clear completed remain non-undoable. | [Delete and undo](#delete-and-undo) | U,P,W,I,S,V | Not started | Not run |
| `PAR-TASK-004` | Notes editing | `app:commands.rs::set_notes`; `ui:TaskDetail.svelte` | **Retain**. | Preserve empty/cleared, Unicode, multiline, and long supported content exactly; task text remains untrusted plain text. | [Network and API data](SECURITY.md#network-and-api-data) | U,C,P,W,I,S | S14B local validation/acknowledgement, S15B complete outbound snapshot plus live-proven JSON-null clear, and S16 no-merge whole-record reconciliation complete | `test/domain/task_commands_test.dart`; `test/data/database/task_edits_repository_test.dart`; `test/features/tasks/adaptive_shell_test.dart`; `test/sync/{update_sync_engine,reconciliation/content_policy}_test.dart`; `integration_test/{offline_task_edits_linux,update_publish_linux}_test.dart`; S07 optional-field-clear contract tests; Linux actual screenshots |
| `PAR-TASK-005` | Due-date edit/clear | `app:commands.rs::set_due`; `ui:DatePicker.svelte`; `ui-test:DueConsistency.test.js` | **Retain**. | Store a date-only domain value and encode UTC midnight; clearing uses only a contract-proven representation. | [API due contract](GOOGLE_TASKS_API_CONTRACT.md#deletion-hierarchy-dates-completion-and-recurrence) | U,C,P,W,I,S,G,V | S14B local date-only acknowledgement, S15B outbound UTC-midnight/JSON-null clear publication, and S16 whole-record set/change/clear reconciliation complete | `test/domain/task_commands_test.dart`; `test/data/database/task_edits_repository_test.dart`; `test/features/tasks/adaptive_shell_test.dart`; `test/sync/{update_sync_engine,reconciliation/content_policy}_test.dart`; `integration_test/{offline_task_edits_linux,update_publish_linux}_test.dart`; S07/P9 contract evidence; Linux actual screenshots |
| `PAR-TASK-006` | Date consistency cascade and undo | `app:commands.rs::{set_due_inner,undo_set_due_inner}` | **Retain** — the edited row wins: an earlier child pulls its dated parent earlier; a later parent moves earlier dated children later. | One durable command applies the selected date plus required related changes; one Undo reverses the whole acknowledged group. | This row; [bulk semantics](#bulk-operation-failure-semantics) | U,P,W,I,S | Not started | Not run |
| `PAR-TASK-007` | Today/tomorrow/week/month shortcuts | `app:commands.rs::set_due`; `ui-test:Reschedule.test.js` | **Retain**. | Injected local calendar/locale computes clamped date-only results; every UI path calls one domain policy. | [Testing principles](TESTING.md#principles) | U,W,I,V | Not started | Not run |
| `PAR-TASK-008` | Clear completed | `app:commands.rs::clear_completed`; `ui-test:ClearCompleted.test.js` | **Retain with explicit safety rule**. | Confirm once; skip completed parents with unfinished children; locally acknowledge the selected deletions atomically; no Undo. | [Bulk semantics](#bulk-operation-failure-semantics) | U,P,W,I,S,V | Not started | Not run |
| `PAR-CAPTURE-001` | Quick add | `ui:App.svelte::{newTask,submitQuickAdd}`; `ui-test:QuickAdd.test.js` | **Redesign for native layouts**. | One/two-interaction creation targets the visible list; smart-view creation chooses a visible honest default and never silently vanishes. | [Interaction principles](UX.md#interaction-principles) | U,W,I,V | Not started | Not run |
| `PAR-CAPTURE-002` | Natural-language date preview | `ui:App.svelte::parseQuickAddDue` | **Retain narrowly; redesign acceptance**. | Recognize only terminal ISO date, today, tomorrow, next week, and next month phrases; show the parsed date and stripped title before submission and allow dismissal. | This row; [interaction principles](UX.md#interaction-principles) | U,W,I,V | Not started | Not run |
| `PAR-CAPTURE-003` | Bulk paste/add | `ui:BulkAdd.svelte`; `ui-test:BulkAdd.test.js`; `ui-test:PasteCreate.test.js` | **Retain**. | Preview line/paragraph parsing and target list; reject invalid/over-limit input before one atomic local acknowledgement. | [Bulk semantics](#bulk-operation-failure-semantics) | U,P,W,I,S,V | Not started | Not run |
| `PAR-BULK-001` | Multi-select | `ui:App.svelte::selectedIds`; `ui-test:BulkOps.test.js` | **Retain**. | Selection is transient UI state with keyboard, pointer, touch, accessibility, and system-back behavior; it never gates sync. | [Interaction principles](UX.md#interaction-principles) | U,W,I,V | Not started | Not run |
| `PAR-BULK-002` | Bulk complete/reschedule/move/delete | Sequential command loops in `ui:App.svelte` bulk handlers | **Redesign** — atomic local command plus honest per-resource remote outcomes. | Validate all, acknowledge all-or-none locally, then show exact confirmed/pending/failed counts; bulk delete has one undo group. | [Bulk semantics](#bulk-operation-failure-semantics) | U,P,W,I,S,V | Not started | Not run |

## Structure, subtasks, views, and search

| ID | Capability | Rust behavioral evidence | Decision and intentional difference | Intended Flutter behavior | Domain / UX specification | Required evidence | Implementation | Verification |
|---|---|---|---|---|---|---|---|---|
| `PAR-STRUCT-001` | Manual top-level ordering | `app:commands.rs::reorder_task`; `ui-test:DragAndDrop.test.js` | **Retain with accepted Google-authoritative conflicts**. | Use `previous`/MOVE and canonical returned order; never synthesize opaque positions. | [Structure policy](SYNC_SPEC.md#content-and-structure-policies) | U,C,P,W,I,S,G,V | Not started | Not run |
| `PAR-STRUCT-002` | Move between lists | `app:commands.rs::move_to_list`; `ui-test:MoveToList.test.js` | **Retain; redesign sync semantics** — stable-ID move, not clone/delete. | Move the task/subtree through Google MOVE; Google wins competing structure and content remains independent. | [Structure policy](SYNC_SPEC.md#content-and-structure-policies) | U,C,P,W,I,S,G,V | Not started | Not run |
| `PAR-STRUCT-003` | One subtask level | `ui:taskTree.js`; `ui-test:TwoLevelTree.test.js` | **Retain exactly**. | Domain rejects local depth greater than one before mutation; collections show parents and details show children. | [Task hierarchy](UX.md#task-hierarchy) | U,P,W,I,S,V | S14B local validation and S15A parent-before-child create publication complete; full details collection UX remains later | `test/domain/task_commands_test.dart`; `test/data/database/task_edits_repository_test.dart`; `test/sync/create_sync_engine_test.dart` |
| `PAR-STRUCT-004` | Unsupported remote hierarchy | Recursive hierarchy behavior in `ui:taskTree.js` and `ui:App.svelte` | **Redesign** — never flatten, repair, or expose unsupported rows as ordinary tasks. | Protect evidence, fail the affected scope, and leave Google untouched. | [Unsupported hierarchy](#unsupported-hierarchy), [SYNC_SPEC](SYNC_SPEC.md#one-supported-subtask-level) | U,C,P,W,I,S,V | Not started | Not run |
| `PAR-STRUCT-005` | Add/edit/complete/date/reorder subtask | `ui:TaskDetail.svelte`; `ui-test:SubtaskReorder.test.js` | **Retain**. | All supported task commands apply to a leaf subtask; validation prevents children beneath it. | [Task hierarchy](UX.md#task-hierarchy) | U,P,W,I,S,V | S14B child create/content acknowledgement and S15A Google child create complete; remaining detail/edit/reorder UX is later | `test/data/database/task_edits_repository_test.dart`; `test/sync/create_sync_engine_test.dart` |
| `PAR-STRUCT-006` | Promote/detach and demote | `ui:App.svelte::{promoteTask,handleDemoteSelect}`; `ui-test:DemoteToSubtask.test.js` | **Retain**. | Promote to top level or choose a valid top-level parent; resulting canonical Google order is adopted. | [Structure policy](SYNC_SPEC.md#content-and-structure-policies) | U,P,W,I,S,G,V | Not started | Not run |
| `PAR-STRUCT-007` | Parent subtask progress | `ui:App.svelte::getSubtaskProgress`; `ui-test:TaskWidget.test.js` | **Retain**. | Shared domain projection reports completed/total direct children; collections do not duplicate child rows. | [Task hierarchy](UX.md#task-hierarchy) | U,W,I,V | Not started | Not run |
| `PAR-STRUCT-008` | Parent completion behavior | `ui-test:CompleteUndo.test.js`; controlled API probe P8 | **Retain with Google authority**. | Complete parent adopts Google's child cascade; reopen parent leaves children completed; impossible child reopen is visibly superseded. | [Completion policy](SYNC_SPEC.md#content-and-structure-policies), [API P8](GOOGLE_TASKS_API_CONTRACT.md#sanitized-observations) | U,C,P,W,I,S,G,V | Not started | Not run |
| `PAR-STRUCT-009` | Effective parent due date | `ui:App.svelte::dueInfo`; `ui-test:SubtaskDatePropagation.test.js` | **Retain as derived state**. | Parent effective date is the earlier of its explicit date and unfinished direct-child dates; completed children do not propagate. | [Task hierarchy](UX.md#task-hierarchy) | U,W,I,V | Not started | Not run |
| `PAR-VIEW-001` | Focus view | `ui:App.svelte::focusTasks`; `ui-test:SmartViews.test.js` | **Retain**. | Top-level open tasks due before the end of the next seven local calendar days, including overdue; overdue section first. | This row | U,P,W,I,V | Not started | Not run |
| `PAR-VIEW-002` | Upcoming view | `ui:App.svelte::upcomingTasks`; `ui-test:SmartViews.test.js` | **Retain**. | Top-level open tasks after today through fourteen local calendar days; effective dates apply. | This row | U,P,W,I,V | Not started | Not run |
| `PAR-VIEW-003` | Missed view | `ui:App.svelte::missedTasks`; `ui-test:SmartViews.test.js` | **Retain**. | Top-level open tasks with effective date before today, oldest first. | This row | U,P,W,I,V | Not started | Not run |
| `PAR-VIEW-004` | Unscheduled view | `ui:App.svelte::unscheduledTasks`; `ui-test:SmartViews.test.js` | **Retain**. | Top-level open tasks with no explicit or unfinished-child effective date. | This row | U,P,W,I,V | Not started | Not run |
| `PAR-VIEW-005` | All view and counts | `ui:App.svelte::{visibleTasks,viewCounts}`; `ui-test:SmartViewCounts.test.js` | **Retain**. | Show top-level tasks across included lists; counts exactly match visible membership and completion filtering. | This row | U,P,W,I,V | Not started | Not run |
| `PAR-VIEW-006` | Per-view sorting | `ui:SortDropdown.svelte`; `ui-test:Sort.test.js` | **Retain; storage redesign**. | Manual, effective due, title, and created order are account/view-scoped SQLite preferences; completed-bottom is explicit. | [Persistence](ARCHITECTURE.md#persistence) | U,P,W,I,V | Not started | Not run |
| `PAR-VIEW-007` | Show completed | `ui:App.svelte` `showCompleted` localStorage preference | **Retain; storage redesign**. | Account/view-scoped SQLite preference drives rows and counts consistently after restart. | [Persistence](ARCHITECTURE.md#persistence) | U,P,W,I | Not started | Not run |
| `PAR-SEARCH-001` | Search title and notes | `ui:SearchOverlay.svelte`; `ui-test:SearchOverlay.test.js` | **Retain**. | Search supported tasks only; a child match identifies and opens its parent context; keyboard and touch results agree. | [Task hierarchy](UX.md#task-hierarchy) | U,W,I,V | Not started | Not run |

## Adaptive interaction and presentation

| ID | Capability | Rust behavioral evidence | Decision and intentional difference | Intended Flutter behavior | Domain / UX specification | Required evidence | Implementation | Verification |
|---|---|---|---|---|---|---|---|---|
| `PAR-DESKTOP-001` | Keyboard navigation/shortcuts | `ui:shortcuts.js`; `ui-test:KeyboardNav.test.js` | **Retain**. | Discoverable shortcuts accelerate focus, create, edit, date, move, select, and search without conflicting with text input. | [Adaptive UX ADR](adr/0005-adaptive-ux.md) | U,W,I,V | Not started | Not run |
| `PAR-DESKTOP-002` | Context and hover actions | `ui:ContextMenu.svelte`; `ui-test:HoverActionsNoReflow.test.js` | **Redesign**. | Hover/context menu are accelerators only; every action has a visible/focusable route and no hover reflow. | [Interaction principles](UX.md#interaction-principles) | W,I,V | Not started | Not run |
| `PAR-DESKTOP-003` | Pointer drag/reorder | `ui:TaskRow.svelte`; `ui:ListView.svelte`; `ui-test:DragAndDrop.test.js` | **Retain**. | Drag provides preview and keyboard/button alternatives; failure restores canonical projection and truthful health. | [Adaptive UX ADR](adr/0005-adaptive-ux.md) | U,W,I,S,V | Not started | Not run |
| `PAR-ANDROID-001` | Navigation/drawer | `ui:Sidebar.svelte`; `ui-test:MobileDrawer.test.js` | **Redesign natively**. | Use Flutter/Material navigation selected by width; routes preserve list/detail state and expose sync status. | [Information architecture](UX.md#information-architecture) | W,I,D,V | Not started | Not run |
| `PAR-ANDROID-002` | Fast creation action | `ui:App.svelte` mobile quick-add affordance | **Retain concept; redesign widget**. | Reachable primary add action respects keyboard, insets, text scaling, and current target context. | [Interaction principles](UX.md#interaction-principles) | W,I,D,V | Not started | Not run |
| `PAR-ANDROID-003` | Swipe/long-press actions | `ui:TaskRow.svelte`; `ui-test:TouchInteractions.test.js` | **Redesign**. | Gestures may accelerate selection/actions but visible accessible controls always exist; accidental destructive gestures require Undo/confirmation policy. | [Interaction principles](UX.md#interaction-principles) | W,I,D,V | Not started | Not run |
| `PAR-ANDROID-004` | Pull to refresh | `ui:App.svelte` touch refresh functions; `ui-test:IncrementalRefresh.test.js` | **Retain natively**. | Request immediate foreground synchronization and keep the control pending until the actual run result is known. | [Sync health](UX.md#sync-health-vocabulary) | W,I,S,D,V | Not started | Not run |
| `PAR-ANDROID-005` | System back/predictive back | `ui:App.svelte` history handling; `ui-test:AndroidBackButton.test.js` | **Retain correctly in Flutter**. | Back closes the topmost selection/dialog/detail/navigation surface in a tested state order and supports predictive back. | [Adaptive UX ADR](adr/0005-adaptive-ux.md) | U,W,I,D,V | Not started | Not run |
| `PAR-ANDROID-006` | Safe areas and responsive layout | `ui:App.svelte` safe-area CSS; `ui-test:SafeAreaInsets.test.js` | **Retain correctly in Flutter**. | Insets, keyboard, text scaling, narrow/wide constraints, and touch targets are honored on real Android. | [Accessibility](UX.md#accessibility-and-visual-validation) | W,I,D,V | Not started | Not run |
| `PAR-UX-001` | Theme | `ui:theme.js`; `ui:theme.css`; `ui-test:ThemeContrast.test.js` | **Retain; storage redesign**. | System/light/dark is a device-only typed preference with system default and accessible contrast. | [Persistence](ARCHITECTURE.md#persistence) | U,W,I,V | Not started | Not run |
| `PAR-UX-002` | Onboarding | `ui:App.svelte` onboarding | **Redesign**. | Explain Connect, truthful sync status, offline continuity, quick add, and where recovery lives; dismissal is device-only. | [Trust before decoration](UX.md#trust-before-decoration) | W,I,V | Not started | Not run |

## Safety, recovery, links, development-only behavior, and non-goals

| ID | Capability | Rust behavioral evidence | Decision and intentional difference | Intended Flutter behavior | Domain / UX specification | Required evidence | Implementation | Verification |
|---|---|---|---|---|---|---|---|---|
| `PAR-DATA-001` | Backup/export | `core:export.rs`; `ui-test:Export.test.js` | **Retain; redesign format boundary** — export user state, not Rust sync/storage rows. | Versioned account snapshot includes supported projected data and explicit privacy warning. | [Backup/export contract](#backupexport-and-restoreimport) | U,P,W,I,S,V | Not started | Not run |
| `PAR-DATA-002` | Restore/import | `app:state.rs::restore_backup`; `ui-test:Import.test.js` | **Retain; redesign safety semantics**. | After successful target sync, recreate absent records; matching existing identity wins; no content matching, overwrite, or deletion. | [Backup/import contract](#backupexport-and-restoreimport) | U,C,P,W,I,S,G,V | Not started | Not run |
| `PAR-DATA-003` | Reset Local Data | `app:commands.rs::fresh_sync` clears synced rows before pull. | **Redesign as explicit destructive product recovery** — pending work is intentionally discarded too. | Reset selected account partition after warning/confirmation, preserve authorization/device preferences, then rebuild from Google with truthful health. | [Reset contract](#refresh-recovery-and-reset-local-data) | U,P,W,I,S,V | Not started | Not run |
| `PAR-LINK-001` | Manage recurrence in Google Tasks | `ui-test:OpenInGoogle.test.js`; task `webViewLink` | **Retain as workaround**. | Clearly labeled action opens a validated Google task link; unavailable/invalid link explains that recurrence cannot be managed here. | [Recurrence and links](UX.md#recurrence-and-links) | U,C,W,I,G,D,V | Not started | Not run |
| `PAR-LINK-002` | Open user-authored web links | `ui:TaskDetail.svelte::extractUrls`; `ui-test:UrlDetection.test.js` | **Retain separately**. | Parse only supported `http`/`https` URLs from plain text; require safe launcher outcome and never shell-execute. | [Network and API data](SECURITY.md#network-and-api-data) | U,C,W,I,D,V | Not started | Not run |
| `PAR-LINK-003` | Edit recurrence | No public recurrence fields in the Tasks discovery contract. | **Drop as unsupported** — never simulate it locally. | Direct users to Google's UI through `webViewLink`; recurring configuration is not cached or claimed. | [API limitations](GOOGLE_TASKS_API_CONTRACT.md#deletion-hierarchy-dates-completion-and-recurrence) | U,W,I,G,V | Not applicable | Not run |
| `PAR-RECOVERY-001` | Database-open recovery | Rust schema wipe/export behavior in `core:store/mod.rs` | **Redesign** — no automatic destructive replacement. | Preserve unreadable files, stop remote work, show Retry Open plus safe diagnostics; Reset remains a separate explicit action. | [Persistence recovery](SYNC_SPEC.md#database-failures) | U,P,W,I,V | Not started | Not run |
| `PAR-DEV-001` | Sensitive development diagnostics | `app:commands.rs::user_error`; tracing in `app:state.rs`; frontend `console.error` calls | **Redesign and retain for debug composition only**. | One-interaction searchable local diagnostics include allowed task/API/SQL context; release composition cannot construct them; credentials are always redacted. | [Development diagnostics](UX.md#development-diagnostics), [Diagnostics](SECURITY.md#diagnostics) | U,C,P,W,I,S,V | Not started | Not run |
| `PAR-DEV-002` | Push-disabled/read-only sync | `core:config.rs` `push_enabled`; `app:state.rs::set_push_enabled` | **Drop from product; defer optional harness**. | No release setting. A test harness may provide it only if isolated and it does not branch production synchronization policy. | [VISION important behavior](../VISION.md#important-product-behavior) | U,I,S | Not applicable | Not run |
| `PAR-DEV-003` | Multiple isolated instances/prefixes | `core:config.rs` `AXIOTASK_PREFIX` | **Drop from product**. | Tests inject isolated paths, namespaces, app IDs, stores, and accounts; users do not manage instance prefixes. | [Isolation rules](TESTING.md#isolation-rules) | U,P,I | Not applicable | Not run |
| `PAR-PLATFORM-001` | Android background sync | `app:state.rs::background_sync_loop` | **Drop** by product decision. | Android synchronizes only while foreground/resumed and catches up immediately on resume. | [VISION non-goals](../VISION.md#non-goals) | U,I,S,D | Not applicable | Not run |
| `PAR-PLATFORM-002` | Play-Services-free Android | `design:RFC-010-android-auth-play-services.md` local-only proposal | **Drop**. | No special local-only/authless product mode; connection reports the unsupported platform requirement. | [VISION non-goals](../VISION.md#non-goals) | W,I,D | Not applicable | Not run |
| `PAR-SCOPE-001` | Non-Google-Tasks assigned resources | `core:api/http.rs` omits `showAssigned`; no Rust product workflow | **Drop**. | Keep `showAssigned=false`; never ingest or mutate Docs/Chat-assigned resources. | [Product boundary](ARCHITECTURE.md#domain-layer) | U,C,I,G | Not applicable | Not run |
| `PAR-PRIVACY-001` | Telemetry/analytics | Absent from Rust. | **Retain absence**. | No analytics, advertising, remote crash reporting, or automatic diagnostic upload. | [Diagnostics](SECURITY.md#diagnostics) | U,C,I | Not applicable | Not run |

## Milestone dependency order

This is an ordering constraint, not an implementation backlog:

1. **Foundation:** account-scoped schema, stable identity, transactional command
   boundary, diagnostics separation, platform authorization proofs.
2. **Trustworthy read path:** list/task adapter, cache, full retrieval,
   SyncHealth, startup/resume/refresh, unsupported-data failure.
3. **Single-resource writes:** lists, task content, completion, structure,
   deletion grace/cleanup, offline restart, and reconciliation evidence.
4. **Core UX:** adaptive shells, task detail, smart views, search, quick add,
   preferences, accessibility, and visual review.
5. **Batch and safety:** multi-select, bulk commands, Clear completed,
   export/import, Reset Local Data, and recovery surfaces.
6. **Escape hatches and polish:** recurrence link, user links, onboarding,
   exhaustive device/platform and visual gates.

No row is complete because a neighboring row works. Implementation commits
must name the parity IDs they advance, and verification evidence must be linked
from this file or the eventual task/backlog entry before a status changes.

## Stage 5 gate result

All previous `Investigate` items are resolved. The only deferred product
capability is multi-account UI; its account-partition architecture is mandatory
from schema version 1. Optional read-only tooling is deferred only as isolated
test infrastructure and is not a product feature. No application implementation
has started, so every retained/redesigned row remains `Not started / Not run`.
