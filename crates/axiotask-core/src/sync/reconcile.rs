//! Pure sync decision core (RFC-009 Step 1).
//!
//! Every decision the sync engine makes is a function of *observations* —
//! the local row state and what the server answered — and nothing else.
//! Those decisions live here, as pure `(state, observation) → action`
//! functions with no IO, no async, no store, and no client. [`super::engine`]
//! is left with the three things that genuinely need the outside world:
//! **observe** (read the store, call the API), **decide** (call into this
//! module), **apply** (write the store).
//!
//! Why: a conflict-matrix row (RFC-009) is then a table entry over a pure
//! function instead of a staged engine + fake + SQLite fixture. The engine's
//! integration and property suites keep proving the wiring; these functions
//! prove the *choices*.
//!
//! This module is an extraction only — every branch below is the behavior
//! `engine.rs` already had, moved verbatim. Section markers (§B, §D, …) refer
//! to the matrix in `designs/RFC-009-sync-conflict-matrix.md`.

use std::collections::{HashMap, HashSet};
use std::hash::BuildHasher;

use crate::api::ApiError;
use crate::model::{BaseSnapshot, NewTask, Task, TaskList, TaskPatch, TaskStatus};
use crate::store::{PendingMove, StoredTask, StoredTaskList, SyncState};

// ─── Shared vocabulary ───────────────────────────────────────────────────────

/// How far along the push pipeline a task id referenced by a pending intent
/// is. Local ids are UUIDs the server has never seen; naming one in a request
/// draws a permanent 400 ("Invalid task ID", verified live).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefState {
    /// No such row locally (deleted, or never existed).
    Missing,
    /// Present locally but never pushed — it still carries a local UUID.
    Local,
    /// Present and pushed: it carries a server etag, so its id is real.
    Synced,
}

impl RefState {
    /// Classify a referenced row as the store returned it.
    pub fn of(row: Option<&StoredTask>) -> Self {
        match row {
            None => Self::Missing,
            Some(t) if t.task.etag.is_some() => Self::Synced,
            Some(_) => Self::Local,
        }
    }
}

/// How a failed row push resolves. Transient errors leave the row dirty for
/// the next run. A server rejection (400 & co.) also leaves the row dirty but
/// is counted and logged — it must not abort the run, or one poisoned row
/// would permanently starve every other push AND the pull. Only auth failures
/// abort: every subsequent call would fail the same way.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushFailure {
    /// Leave the row dirty; the next run retries it.
    Retry,
    /// Count it, log it, keep the row dirty, and continue with the next row.
    Reject,
    /// Auth is dead — abort the whole run.
    Abort,
}

/// Classify one row's push failure ([`PushFailure`]).
pub fn push_failure(e: &ApiError) -> PushFailure {
    if e.is_transient() {
        return PushFailure::Retry;
    }
    if matches!(e, ApiError::Unauthorized | ApiError::AuthExpired(_)) {
        return PushFailure::Abort;
    }
    PushFailure::Reject
}

// ─── §B/§C — content update ──────────────────────────────────────────────────

/// What a failed content-update push does to the row (§B, §C).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateFailure {
    /// `412`: the etag is stale — refetch and reconcile ([`resolve_conflict`]).
    ResolveConflict,
    /// `404`: the row is gone on the server (deleted, or cascaded away with a
    /// deleted parent). Delete wins in both directions (P4) — hard-delete
    /// locally and discard the edit.
    DeleteLocal,
    /// Anything else — generic row-push failure handling.
    Failed(PushFailure),
}

/// Decide what an update push's error means (§B). A success always adopts the
/// response **body**, not just the etag (P6).
pub fn on_update_error(e: &ApiError) -> UpdateFailure {
    match e {
        ApiError::PreconditionFailed => UpdateFailure::ResolveConflict,
        ApiError::NotFound => UpdateFailure::DeleteLocal,
        other => UpdateFailure::Failed(push_failure(other)),
    }
}

/// How a `412` resolves once the authoritative remote row is in hand.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictResolution {
    /// No real divergence — adopt the remote row wholesale (etag included).
    AdoptRemote,
    /// Real divergence — remote becomes canonical and the local edit survives
    /// as a "(conflicted copy)" task (P3). Nothing is silently discarded.
    ConflictedCopy,
}

/// Resolve a `412` conflict: identical content is just etag/normalization
/// drift to absorb; divergent content preserves both (P3).
///
/// **Status is deliberately excluded from the divergence test** (RFC-009 D1,
/// ratified): when title, notes and due all agree and only the checkbox
/// differs, remote wins outright and no copy is made. A lost checkbox click
/// costs one click to redo; a duplicate "buy milk (conflicted copy)" is
/// confusing and has to be cleaned up by hand. Status still counts everywhere
/// else — [`same_content`] is unchanged, so create-adoption stays exact.
pub fn resolve_conflict(local: &Task, remote: &Task) -> ConflictResolution {
    if same_typed_content(local, remote) {
        ConflictResolution::AdoptRemote
    } else {
        ConflictResolution::ConflictedCopy
    }
}

/// What a failed refetch during `412` resolution does (§B).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefetchFailure {
    /// `404`: the server deleted it — mirror the update-path behavior (P4).
    DeleteLocal,
    /// Transient — the row stays dirty and retries next run.
    StayDirty,
    /// Anything else aborts the run, preserving the local edit untouched.
    Abort,
}

/// Decide what a failed conflict refetch means (§B).
pub fn on_conflict_refetch_error(e: &ApiError) -> RefetchFailure {
    match e {
        ApiError::NotFound => RefetchFailure::DeleteLocal,
        e if e.is_transient() => RefetchFailure::StayDirty,
        _ => RefetchFailure::Abort,
    }
}

/// The patch an update push sends. Canonicalizes on the way out: Google 400s
/// a bare date, `""` clears a due date (both verified live), and cleared notes
/// go as `""` rather than being omitted. An unparseable stored due degrades to
/// "clear" rather than poisoning the row forever.
pub fn update_patch(row: &StoredTask) -> TaskPatch {
    TaskPatch {
        title: Some(row.task.title.clone()),
        notes: row.task.notes.clone().or(Some(String::new())),
        due: Some(
            row.task
                .due
                .as_deref()
                .and_then(crate::dates::normalize_due)
                .unwrap_or_default(),
        ),
        status: Some(row.task.status),
    }
}

/// The remote row, stored as the new canonical version of a conflicted task.
pub fn canonical_row(remote: &Task, list_id: &str) -> StoredTask {
    StoredTask {
        task: remote.clone(),
        list_id: list_id.to_string(),
        sync_state: SyncState::Clean,
        pending_op: None,
        local_updated: remote.updated.clone(),
    }
}

/// The surviving local edit, as a fresh unpushed "(conflicted copy)" create.
/// `new_id` is supplied by the caller so this stays pure.
pub fn conflicted_copy(local: &StoredTask, remote: &Task, new_id: String) -> StoredTask {
    StoredTask {
        task: Task {
            id: new_id,
            parent: local.task.parent.clone(),
            position: local.task.position.clone(),
            title: format!("{} (conflicted copy)", local.task.title),
            notes: local.task.notes.clone(),
            status: local.task.status,
            due: local.task.due.clone(),
            completed: local.task.completed.clone(),
            etag: None,
            updated: remote.updated.clone(),
            web_view_link: None,
        },
        list_id: local.list_id.clone(),
        sync_state: SyncState::Dirty,
        pending_op: Some("create".into()),
        local_updated: remote.updated.clone(),
    }
}

// ─── §D — delete ─────────────────────────────────────────────────────────────

/// What a delete push does (§D).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteAction {
    /// Hard-delete locally and clear the tombstone. A remote `404` counts as
    /// success: the row is gone either way.
    HardDeleteLocal,
    /// Generic row-push failure handling.
    Failed(PushFailure),
}

/// Decide what a delete push's answer means (§D); `None` is a success. The
/// DELETE is unconditional (no If-Match), so a concurrent remote edit is
/// discarded (P4).
pub fn plan_delete(error: Option<&ApiError>) -> DeleteAction {
    match error {
        None | Some(ApiError::NotFound) => DeleteAction::HardDeleteLocal,
        Some(e) => DeleteAction::Failed(push_failure(e)),
    }
}

// ─── §G — create ─────────────────────────────────────────────────────────────

/// Whether a dirty row is a create this pass may attempt at all — the cheap,
/// id-only half of the gate (§G).
///
/// * `attempted` — creates already tried this run. A create whose response
///   timed out after the server committed would otherwise be double-inserted
///   (orphan recovery only runs at the start of a run, not between passes).
/// * `unresolved_inflight` — a marker recovery that could NOT resolve still
///   means "this insert may already have landed"; that create waits for a run
///   with a complete remote view (H1).
/// * `held` — the one id the UI is actively holding. A create remaps a local
///   id to the server id, which would invalidate the id the UI holds, so that
///   ONE create waits. Every other create still pushes.
pub fn create_is_eligible<S: BuildHasher, T: BuildHasher>(
    pending_op: Option<&str>,
    id: &str,
    attempted: &HashSet<String, S>,
    unresolved_inflight: &HashSet<String, T>,
    held: Option<&str>,
) -> bool {
    pending_op == Some("create")
        && !attempted.contains(id)
        && !unresolved_inflight.contains(id)
        && held != Some(id)
}

/// Whether a pending update or delete may be pushed at all (§B/§D × §G).
///
/// A row whose CREATE is still unresolved in flight has no server id yet, and
/// naming its local UUID in a request is a permanent 400 ("Invalid task ID",
/// verified live). Worse, its insert MAY have committed: pushing the delete
/// now would report success against an id Google never minted while the row it
/// really created lives on, to be pulled back as a duplicate. Both mutations
/// wait for the run that resolves the marker — recovery either adopts the
/// orphan (giving the row a real id to delete) or proves the insert never
/// landed (and drops the row outright).
pub fn mutation_is_pushable<S: BuildHasher>(
    id: &str,
    unresolved_inflight: &HashSet<String, S>,
) -> bool {
    !unresolved_inflight.contains(id)
}

/// Whether a create's parent is resolved enough to name in the insert (§G).
/// `None` is a top-level create — no constraint. A still-local parent id draws
/// a permanent 400 from Google ("Invalid task ID", verified live), so the
/// child waits; `finish_create` rewrites its `parent_id` once the parent lands.
pub fn parent_is_pushable(parent: Option<RefState>) -> bool {
    match parent {
        None => true,
        Some(state) => state == RefState::Synced,
    }
}

/// For a SUBTASK, the already-synced sibling to anchor the insert after.
/// Without `previous` the API inserts at the top, so a batch of subtasks would
/// land on Google in reverse creation order. `None` for a top-level create.
pub fn create_previous_anchor(row: &StoredTask, list_rows: &[StoredTask]) -> Option<String> {
    let parent = row.task.parent.as_deref()?;
    list_rows
        .iter()
        .filter(|t| {
            t.task.parent.as_deref() == Some(parent)
                && t.task.id != row.task.id
                && t.task.etag.is_some()
        })
        .max_by(|a, b| a.task.position.cmp(&b.task.position))
        .map(|t| t.task.id.clone())
}

/// The insert payload for a create. `due` is canonicalized on the way out:
/// Google 400s a bare date, and this heals any legacy/imported row that
/// stored a non-canonical form.
pub fn create_payload(row: &StoredTask, previous: Option<String>) -> NewTask {
    NewTask {
        title: row.task.title.clone(),
        notes: row.task.notes.clone(),
        due: row
            .task
            .due
            .as_deref()
            .and_then(crate::dates::normalize_due),
        status: Some(row.task.status),
        parent: row.task.parent.clone(),
        previous,
    }
}

/// What a failed create push does to the in-flight marker (§G).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CreateFailure {
    /// Transient: the insert may or may not have reached the server. KEEP the
    /// marker so the next run can adopt an orphan instead of duplicating.
    KeepInflight,
    /// The insert definitively did not land — clear the marker, then handle
    /// the failure normally.
    ClearInflight(PushFailure),
}

/// Decide what a create push's error means (§G).
pub fn on_create_error(e: &ApiError) -> CreateFailure {
    if e.is_transient() {
        CreateFailure::KeepInflight
    } else {
        CreateFailure::ClearInflight(push_failure(e))
    }
}

/// The remote task an interrupted create already committed, if any: our
/// content under an id we never recorded. Scoped strictly to the row behind
/// an in-flight marker, so it never merges unrelated tasks (duplicate titles
/// are legal — this is not content dedup).
pub fn find_orphan<'a, S: BuildHasher>(
    local: &Task,
    remote: &'a [Task],
    known_local_ids: &HashSet<String, S>,
) -> Option<&'a Task> {
    remote
        .iter()
        .find(|r| !known_local_ids.contains(&r.id) && same_content(local, r))
}

/// Like [`find_orphan`] but matches on the create's **base snapshot** — the
/// insert payload as it was actually sent — instead of the row's current
/// content (RFC-009 §G, #122). An edit made during the in-flight window mutates
/// the local row but never the base, so adoption still recognizes the committed
/// server row; without this the drifted content misses and the create is
/// retried, duplicating the task.
///
/// `has_parent` tolerates the one status coercion Google applies on insert that
/// the payload cannot predict: a subtask inserted under a completed parent is
/// stored **already completed**, and a later parent-complete cascades onto it
/// too (RFC-009 §G, probe). So for any SUBTASK create, a completed remote is
/// still our child — status is not required to match (the parent's completion
/// state can itself change between the insert and recovery, so we cannot key on
/// it). Everything the user typed always must match. For a top-level create
/// (`has_parent == false`) status stays strict, since no cascade can touch it —
/// so a crashed create never adopts an unrelated same-title row (the
/// d1-does-not-leak guarantee).
pub fn find_orphan_by_base<'a, S: BuildHasher>(
    base: &BaseSnapshot,
    has_parent: bool,
    remote: &'a [Task],
    known_local_ids: &HashSet<String, S>,
) -> Option<&'a Task> {
    remote
        .iter()
        .find(|r| !known_local_ids.contains(&r.id) && base_matches_create(base, has_parent, r))
}

/// A create's base against a committed remote row (see [`find_orphan_by_base`]).
/// Typed content (title/notes/due) must always match; status must match unless
/// the subtask completion cascade explains a completed remote.
fn base_matches_create(base: &BaseSnapshot, has_parent: bool, r: &Task) -> bool {
    let due = |d: &Option<String>| d.as_deref().and_then(crate::dates::normalize_due);
    let notes = |n: &Option<String>| n.clone().filter(|s| !s.is_empty());
    base.title == r.title
        && notes(&base.notes) == notes(&r.notes)
        && due(&base.due) == due(&r.due)
        && (base.status == r.status || (has_parent && r.status == TaskStatus::Completed))
}

// ─── §E/§F — position and parent moves ───────────────────────────────────────

/// The ids a pending move references, as the store currently sees them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MoveRefs {
    /// The task being moved.
    pub task: RefState,
    /// The target parent; `None` when the move names none (top-level).
    pub parent: Option<RefState>,
    /// The sibling the task should follow; `None` when the move names none.
    pub previous: Option<RefState>,
    /// Whether the moved task currently has subtasks of its own. Only matters
    /// for a demote: its children would land a third level down.
    pub task_has_children: bool,
    /// Whether the target parent is itself a subtask — the mirror case of the
    /// same third level.
    pub parent_is_subtask: bool,
}

/// What to do with a pending move before calling the API (§E, §F).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MoveIntent {
    /// Send it. `keep_previous` false means the ordering half was dropped and
    /// only the reparent is sent.
    Send {
        /// Whether the `previous` sibling is still expressible.
        keep_previous: bool,
    },
    /// Nothing left to express — clear the intent so it stops being re-walked
    /// (and stops inflating the pending-changes count the UI shows).
    Drop,
    /// The move would nest the task a third level deep (invariant #1). Clear
    /// the intent WITHOUT calling the API: the server would accept it (probe
    /// 3: there is no depth cap, the move returns 200), and the grandchild it
    /// would store is a row no list view can render. The pull that follows
    /// restores the remote parent on the row, so local converges too.
    Refuse,
    /// The ids aren't on the server yet — keep the intent and try next run.
    Wait,
}

/// Plan a pending move against the current local view of the ids it names
/// (§E, §F). Moves degrade, never wedge (P5).
pub fn plan_move(refs: MoveRefs) -> MoveIntent {
    // The TARGET PARENT is gone (the user deleted it after dropping this task
    // under it). Its delete cascades to the whole subtree on both sides
    // (verified live), so this task goes with it: there is nothing left to
    // express, and Google would answer 400 "Invalid task ID" for the dead
    // parent (verified live). The synced-yet check below can never pass for a
    // row that no longer exists, so the intent would otherwise survive forever.
    if refs.parent == Some(RefState::Missing) {
        return MoveIntent::Drop;
    }
    // A DEMOTE that would produce a third level (invariant #1) — either the
    // task already has subtasks, or the target parent is itself a subtask.
    // Google does NOT cap nesting depth: the move is accepted with 200 and the
    // grandchild is stored (probe 3, which falsified the earlier "the server
    // rejects it" claim). So the refusal has to happen here. A demote is only
    // ever *recorded* against a childless task, but a pull can hand that task
    // a remote-born subtask before the move is pushed.
    if refs.parent.is_some() && (refs.task_has_children || refs.parent_is_subtask) {
        return MoveIntent::Refuse;
    }
    // The SIBLING this task was dropped after is gone. One drag can carry two
    // intents — reparent and ordering — and the row already applied both
    // optimistically. "Place after B" is unexpressible now, but the reparent
    // still is, so dropping the whole intent would strand it: local would show
    // the task at its new parent while Google keeps the old one, and because
    // the row is Clean with a matching etag no later pull ever corrects the
    // drift. Keep the parent, drop only the ordering — position self-heals on
    // the next pull.
    let keep_previous = refs.previous.is_some_and(|p| p != RefState::Missing);
    // A move whose task (or target parent/previous) hasn't been pushed yet
    // still carries a local UUID — the API answers 400 "Invalid task ID"
    // (verified live), which would drop the user's reordering. Hold the
    // intent; finish_create rewrites the ids when the create lands.
    let unsynced = |r: Option<RefState>| r.is_some_and(|s| s != RefState::Synced);
    if refs.task != RefState::Synced
        || unsynced(refs.parent)
        || (keep_previous && unsynced(refs.previous))
    {
        return MoveIntent::Wait;
    }
    MoveIntent::Send { keep_previous }
}

/// The `previous` id to send for a planned move, given the stored intent.
pub fn move_previous_id(mv: &PendingMove, intent: MoveIntent) -> Option<String> {
    match intent {
        MoveIntent::Send {
            keep_previous: true,
        } => mv.previous_id.clone(),
        _ => None,
    }
}

/// How much of a successful move response is adopted (§E).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MoveAdoption {
    /// Adopt the response BODY, not just the etag — the same trap
    /// `update` documents. A move can change more than parent/position:
    /// completing a parent cascades to its subtree server-side (verified
    /// live), so a task moved OUT of a parent completed in the same batch
    /// comes back completed. The fresh etag the move returns would otherwise
    /// make every later pull skip the row and freeze that drift in place (P6).
    Body,
    /// The row carries its own pending content edit: keep it (meta only). Its
    /// update push adopts the server body on this run or the next.
    MetaOnly,
}

/// Decide how much of a move response to adopt, from the row snapshot taken
/// *before* the call (so a mid-flight re-edit stays dirty).
pub fn move_adoption(before: Option<&StoredTask>) -> MoveAdoption {
    match before {
        Some(t) if t.sync_state == SyncState::Clean => MoveAdoption::Body,
        _ => MoveAdoption::MetaOnly,
    }
}

/// What a failed move push does (§E, §F).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MoveFailure {
    /// `404` on a move that named a `previous` sibling. The status is
    /// **ambiguous**: the server answers 404 both for "Previous task id not
    /// found" (probe 2, verified live) and for a subject it no longer has.
    /// Reading it as "the task is gone" throws away a reparent the server
    /// would have accepted — the user's demote silently reverts. Resolve the
    /// ambiguity by experiment: drop the ordering half (P5's ladder) and send
    /// the reparent alone. If THAT 404s, the subject really is gone.
    DropPreviousAndRetry,
    /// `404`: the task is gone on the server — drop the stale intent.
    DropIntent,
    /// Transient — keep the intent and retry next run.
    Retry,
    /// Auth is dead — abort the run, leaving the intent pending.
    Abort,
    /// Rejected. A rejected move must not starve the rest of the queue: count
    /// it and drop the intent (positions self-heal on the next pull).
    RejectAndDrop,
}

/// Decide what a move push's error means (§E, §F). `sent_previous` says
/// whether the call that failed named a `previous` sibling — the only thing
/// that makes a 404 ambiguous ([`MoveFailure::DropPreviousAndRetry`]).
pub fn on_move_error(e: &ApiError, sent_previous: bool) -> MoveFailure {
    match e {
        ApiError::NotFound if sent_previous => MoveFailure::DropPreviousAndRetry,
        ApiError::NotFound => MoveFailure::DropIntent,
        e => match push_failure(e) {
            PushFailure::Retry => MoveFailure::Retry,
            PushFailure::Abort => MoveFailure::Abort,
            PushFailure::Reject => MoveFailure::RejectAndDrop,
        },
    }
}

// ─── §I — list operations ────────────────────────────────────────────────────

/// A remote list a local list-create should adopt instead of inserting a
/// duplicate — same title, and not already tracked locally (§I). Covers the
/// default "My Tasks" bootstrap and any create that already landed.
pub fn adoptable_list<'a, S: BuildHasher>(
    title: &str,
    remote: &'a [TaskList],
    tracked_local_ids: &HashSet<String, S>,
) -> Option<&'a TaskList> {
    remote
        .iter()
        .find(|r| r.title == title && !tracked_local_ids.contains(&r.id))
}

/// What a failed list rename does (§I).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListRenameFailure {
    /// `404`: the list is gone on the server — hard-delete it locally (P4).
    DeleteLocal,
    /// Generic row-push failure handling.
    Failed(PushFailure),
}

/// Decide what a list rename's error means (§I).
pub fn on_list_rename_error(e: &ApiError) -> ListRenameFailure {
    match e {
        ApiError::NotFound => ListRenameFailure::DeleteLocal,
        e => ListRenameFailure::Failed(push_failure(e)),
    }
}

/// What a list delete push does (§I).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListDeleteAction {
    /// Hard-delete locally; a remote `404` counts as success.
    DeleteLocal,
    /// Transient — keep the tombstone and retry next run.
    Retry,
    /// Auth is dead — abort the run, leaving the tombstone.
    Abort,
    /// Permanently refused — Google will not delete an account's default
    /// list, for example. A tombstone that can never push would error on every
    /// run forever; revive the list instead (its tasks re-pull) and tell the
    /// user via the error count.
    Revive,
}

/// Decide what a list delete's answer means (§I); `None` is a success.
pub fn plan_list_delete(error: Option<&ApiError>) -> ListDeleteAction {
    match error {
        None | Some(ApiError::NotFound) => ListDeleteAction::DeleteLocal,
        Some(e) => match push_failure(e) {
            PushFailure::Retry => ListDeleteAction::Retry,
            PushFailure::Abort => ListDeleteAction::Abort,
            PushFailure::Reject => ListDeleteAction::Revive,
        },
    }
}

// ─── §G3 — a remotely-deleted list holding unpushed rows (D2) ────────────────

/// The title Google gives an account's default list, and the title the app's
/// own offline bootstrap uses (`state.rs::ensure_default_list`). Preferring it
/// makes the re-home target the list the user thinks of as home whenever one
/// exists.
const DEFAULT_LIST_TITLE: &str = "My Tasks";

/// Where the unpushed rows of a remotely-deleted list go (§G3, D2 —
/// ratified).
///
/// A row the server has never seen must not die with a list the server
/// deleted (P2), so it re-homes to the **default list**: the surviving list
/// titled "My Tasks" if there is one, otherwise the alphabetically first, tied
/// by id so the choice is deterministic. Candidates exclude the dying list
/// itself, lists the user has tombstoned (they would take the rows down again)
/// and local-only lists (they never push, so a re-homed create would never
/// sync). `None` means there is nowhere to put them — the caller keeps the
/// list alive instead (see `engine::pull_all`).
pub fn rehome_target<'a>(
    lists: &'a [StoredTaskList],
    dying_list_id: &str,
) -> Option<&'a StoredTaskList> {
    lists
        .iter()
        .filter(|l| {
            l.list.id != dying_list_id && !l.local_only && l.sync_state != SyncState::Deleted
        })
        .min_by_key(|l| {
            (
                l.list.title != DEFAULT_LIST_TITLE,
                l.list.title.clone(),
                l.list.id.clone(),
            )
        })
}

// ─── §A — pull ───────────────────────────────────────────────────────────────

/// An in-flight create the pull must not front-run: its base snapshot (the
/// payload as sent) plus the remote parent id it was inserted under. Matching on
/// the base — not the row's live content — means an edit made during the
/// in-flight window (#122) still recognizes the committed orphan, and the parent
/// id lets the match tolerate the completed-parent cascade (RFC-009 §G).
pub struct InflightBase {
    /// The create's base snapshot (payload as sent).
    pub base: BaseSnapshot,
    /// The parent id the row currently names (remote id once the parent has
    /// been adopted), used to detect the completed-parent cascade.
    pub parent: Option<String>,
}

/// The rows of one remote list that are candidates for upsert, in FK-safe
/// order (§A). Dirty rows keep their local intent (push handles them), and a
/// remote row matching an in-flight create by its BASE snapshot is left for
/// `recover_inflight_creates` to adopt via id remap — pulling it as a new clean
/// row would duplicate it (or collide on the primary key). Matching on the base
/// (not the live row) makes this robust to an edit during the in-flight window
/// (#122) and to the completed-parent status cascade (RFC-009 §G), exactly like
/// recovery's [`find_orphan_by_base`].
pub fn pull_batch<S: BuildHasher>(
    remote: Vec<Task>,
    dirty_ids: &HashSet<String, S>,
    inflight: &[InflightBase],
) -> Vec<Task> {
    let filtered: Vec<Task> = remote
        .into_iter()
        .filter(|t| !dirty_ids.contains(&t.id))
        .filter(|t| {
            !inflight
                .iter()
                .any(|f| base_matches_create(&f.base, f.parent.is_some(), t))
        })
        .collect();
    order_parents_first(filtered)
}

/// Everything [`plan_pull_row`] needs to judge one pulled row.
pub struct PullRowContext<'a> {
    /// Local `task_id → etag` for the list being pulled.
    pub local_etags: &'a HashMap<String, Option<String>>,
    /// Ids of the batch currently being upserted.
    pub batch_ids: &'a HashSet<String>,
    /// Ids already present locally in this list.
    pub known_local: &'a HashSet<String>,
}

/// What a pulled remote row does to the local store (§A).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullRowAction {
    /// Local already carries this etag — nothing to do.
    Skip,
    /// Upsert as a clean row.
    Upsert,
    /// Upsert, but detached from its parent and with the etag dropped. A
    /// parent that is neither in this batch nor already local (its row was
    /// skipped as dirty/in-flight, or it moved mid-pagination) would fail the
    /// FK and abort the whole pull. Dropping the etag keeps the row from being
    /// etag-skipped next pull, so it re-links once the parent appears.
    UpsertDetached,
}

/// Decide what to do with one pulled row (§A).
pub fn plan_pull_row(task: &Task, ctx: &PullRowContext<'_>) -> PullRowAction {
    if is_up_to_date(&task.id, task.etag.as_deref(), ctx.local_etags) {
        return PullRowAction::Skip;
    }
    match &task.parent {
        Some(p) if !ctx.batch_ids.contains(p) && !ctx.known_local.contains(p) => {
            PullRowAction::UpsertDetached
        }
        _ => PullRowAction::Upsert,
    }
}

/// Ids of the local rows that sit a third level deep — a grandchild, i.e. a
/// row whose parent is a **clean** subtask (RFC-009 §F/§G, D7 **ratified**).
///
/// Google does not cap nesting depth (probe 3: a `move` that deepens the tree
/// returns 200), so invariant #1 (subtasks are strictly one level) is ours to
/// enforce client-side. Two vectors reach the server-side third level and no
/// push-side guard can close either — the demote is unseen until the pull:
///   * §F residual — a remote-born subtask arrives *after* our demote already
///     landed, so the server holds `P > T > C` we never asked for; and
///   * §G — our own queued subtask create races a remote demote of its parent,
///     so the create lands (or is still queued) under a row the server has
///     since made a subtask.
///
/// The pull is the one place with the full server picture, so D7 promotes each
/// grandchild to top-level and, for a synced row, pushes the corrective move
/// (see [`super::engine::SyncEngine::repair_third_level`]).
///
/// Detects over the LOCAL store after the pull's upsert, not the fetched batch:
/// a paged pull can land a middle row's demotion (`T` gains parent `P`) while
/// the grandchild `C` sits on a page a transient error dropped — so `C` never
/// appears in this batch, yet it is a third level the moment `T`'s demotion is
/// stored. The local store is the only place that sees the whole chain.
///
/// The **clean-middle guard** is what makes local detection safe: the PARENT
/// (`T`) must be `Clean`. A clean parent link is server-confirmed, so a row that
/// looks nested purely because of an un-pushed optimistic demote of the middle
/// (a refused move that stayed put while `T` was dirty) is never mistaken for a
/// real third level and never triggers a bogus repair. The grandchild `C`
/// itself may be in any state — clean, a pending edit, or a still-queued create
/// under a just-demoted parent (§G) — because that only changes HOW it is
/// promoted, not WHETHER it is a third level. A create can only sit under `T`
/// because `T` was top-level when it was made, and a synced row can never be
/// optimistically re-parented under a subtask (the demote gate refuses it), so
/// `C`'s link to a clean `T` is always real.
///
/// Structural only — no IO. Promoting exactly these ids to top-level heals any
/// tree to at most one level: a great-grandchild `D` under a promoted `C`
/// becomes a legal one-level subtask once `C` is top-level.
pub fn third_level_ids(rows: &[StoredTask]) -> Vec<String> {
    let by_id: HashMap<&str, &StoredTask> = rows.iter().map(|r| (r.task.id.as_str(), r)).collect();
    rows.iter()
        .filter(|r| {
            r.task
                .parent
                .as_deref()
                .and_then(|p| by_id.get(p))
                .is_some_and(|parent| {
                    parent.sync_state == SyncState::Clean && parent.task.parent.is_some()
                })
        })
        .map(|r| r.task.id.clone())
        .collect()
}

/// Whether a remote task is already up to date locally.
pub fn is_up_to_date<S: BuildHasher>(
    id: &str,
    remote_etag: Option<&str>,
    local_etags: &HashMap<String, Option<String>, S>,
) -> bool {
    match (local_etags.get(id), remote_etag) {
        (Some(Some(local)), Some(remote)) => local == remote,
        _ => false,
    }
}

/// What a pulled remote list does to the local store (§A, §I).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ListPullAction {
    /// A locally dirty list with the same id — preserve local intent (push
    /// will handle it).
    KeepLocal,
    /// Adopt a local-only create (no etag) with the same title by remapping
    /// its id — covers the offline "My Tasks" bootstrap and any create that
    /// already landed.
    AdoptLocalCreate {
        /// The local id to remap onto the remote list.
        local_id: String,
    },
    /// Upsert the remote list. `changed` reports whether anything the UI shows
    /// actually differs from what is stored.
    Upsert {
        /// Whether this upsert changes locally-visible list metadata.
        changed: bool,
    },
}

/// Decide how one remote list reconciles into the local store (§A, §I).
pub fn plan_list_pull(remote: &TaskList, locals: &[StoredTaskList]) -> ListPullAction {
    if locals
        .iter()
        .any(|l| l.list.id == remote.id && l.sync_state != SyncState::Clean)
    {
        return ListPullAction::KeepLocal;
    }

    if let Some(orphan) = locals.iter().find(|l| {
        l.pending_op.as_deref() == Some("create")
            && l.list.etag.is_none()
            && l.list.title == remote.title
    }) {
        return ListPullAction::AdoptLocalCreate {
            local_id: orphan.list.id.clone(),
        };
    }

    let changed = !locals.iter().any(|l| {
        l.list.id == remote.id
            && l.list.title == remote.title
            && l.list.etag == remote.etag
            && l.list.updated == remote.updated
            && !l.local_only
            && l.sync_state == SyncState::Clean
    });
    ListPullAction::Upsert { changed }
}

// ─── Content comparison and ordering ─────────────────────────────────────────

/// Whether two tasks have identical user-visible content (the patchable
/// fields). Used to tell a real conflict from an identical concurrent edit,
/// and to adopt an orphaned create after a crash. Covers exactly title, notes,
/// due, status — never position, parent, or etag (P3), so a remote *move*
/// never manufactures a conflicted copy.
///
/// Comparison is normalization-tolerant, because Google canonicalizes what we
/// send: `due` always comes back as `YYYY-MM-DDT00:00:00.000Z` (a local
/// `...T00:00:00Z` is the same date), and cleared notes come back absent
/// (`None` ≡ `Some("")`). A raw string comparison here manufactures phantom
/// conflicts — the local edit gets duplicated as a "(conflicted copy)" even
/// though nothing diverged.
pub fn same_content(a: &Task, b: &Task) -> bool {
    same_typed_content(a, b) && a.status == b.status
}

/// On a `412`, whether the server left the TYPED content (title/notes/due)
/// unchanged relative to our base snapshot (RFC-009 §B × moved-while-edited,
/// #118). True means the etag bumped for a reason that did not touch what the
/// user typed — a bare reorder, or a status cascade — so the server never
/// diverged from us on content. The caller then keeps the local typed edit and
/// re-pushes it (adopting the remote STATUS, which D1 resolves remote-wins); no
/// conflicted copy. Status is deliberately EXCLUDED here: the completed-parent
/// cascade coerces status on both sides, so comparing it would read that shared
/// coercion as a remote divergence. Whole-row resolution still holds (NG1) —
/// this is base-version conflict *detection*, not a field-level content merge.
pub fn only_local_diverged(remote: &Task, base: &BaseSnapshot) -> bool {
    let due = |d: &Option<String>| d.as_deref().and_then(crate::dates::normalize_due);
    let notes = |n: &Option<String>| n.clone().filter(|s| !s.is_empty());
    base.title == remote.title
        && notes(&base.notes) == notes(&remote.notes)
        && due(&base.due) == due(&remote.due)
}

/// Whether two tasks agree on everything the user *typed* — title, notes, due
/// — ignoring the checkbox. This is the divergence test for conflict
/// resolution (RFC-009 D1): a status-only difference is not worth a duplicate
/// task. Same normalization tolerance as [`same_content`].
pub fn same_typed_content(a: &Task, b: &Task) -> bool {
    let due = |t: &Task| t.due.as_deref().and_then(crate::dates::normalize_due);
    let notes = |t: &Task| t.notes.clone().filter(|n| !n.is_empty());
    a.title == b.title && notes(a) == notes(b) && due(a) == due(b)
}

/// Order a batch so every task appears after its parent (Kahn-style BFS from
/// the roots). A task whose parent is not in the batch counts as a root — the
/// parent already exists locally. Any leftover (a parent cycle, which the API
/// cannot produce but corrupt data could) is appended last rather than dropped.
///
/// Topological, not a has-parent flag: the API allows nesting deeper than one
/// level (verified live), so among tasks that all have parents, a child can
/// otherwise land before its own parent and fail the FK.
pub fn order_parents_first(tasks: Vec<Task>) -> Vec<Task> {
    let in_batch: HashSet<String> = tasks.iter().map(|t| t.id.clone()).collect();
    let mut remaining: Vec<Option<Task>> = tasks.into_iter().map(Some).collect();
    let mut placed: HashSet<String> = HashSet::new();
    let mut out = Vec::with_capacity(remaining.len());
    loop {
        let mut progressed = false;
        for slot in &mut remaining {
            let ready = slot.as_ref().is_some_and(|t| match &t.parent {
                None => true,
                Some(p) => !in_batch.contains(p) || placed.contains(p),
            });
            if ready {
                let t = slot.take().unwrap();
                placed.insert(t.id.clone());
                out.push(t);
                progressed = true;
            }
        }
        if !progressed {
            break;
        }
    }
    out.extend(remaining.into_iter().flatten());
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::TaskStatus;

    fn task(id: &str) -> Task {
        Task {
            id: id.into(),
            parent: None,
            position: "00000000000000000000".into(),
            title: format!("task {id}"),
            notes: None,
            status: TaskStatus::NeedsAction,
            due: None,
            completed: None,
            etag: Some(format!("etag-{id}")),
            updated: "2026-01-01T00:00:00.000Z".into(),
            web_view_link: Some(format!("https://tasks.google.com/{id}")),
        }
    }

    fn stored(t: Task) -> StoredTask {
        StoredTask {
            list_id: "L".into(),
            local_updated: t.updated.clone(),
            sync_state: SyncState::Clean,
            pending_op: None,
            task: t,
        }
    }

    fn ids(v: &[&str]) -> HashSet<String> {
        v.iter().map(ToString::to_string).collect()
    }

    fn list(id: &str, title: &str) -> TaskList {
        TaskList {
            id: id.into(),
            title: title.into(),
            etag: Some(format!("letag-{id}")),
            updated: "2026-01-01T00:00:00.000Z".into(),
        }
    }

    fn stored_list(l: TaskList) -> StoredTaskList {
        StoredTaskList {
            local_updated: l.updated.clone(),
            list: l,
            sync_state: SyncState::Clean,
            pending_op: None,
            local_only: false,
        }
    }

    // ─── failure classification ──────────────────────────────────────────

    #[test]
    fn push_failure_classification() {
        assert_eq!(
            push_failure(&ApiError::Server { status: 503 }),
            PushFailure::Retry
        );
        assert_eq!(
            push_failure(&ApiError::RateLimited { retry_after: None }),
            PushFailure::Retry
        );
        assert_eq!(
            push_failure(&ApiError::Network("reset".into())),
            PushFailure::Retry
        );
        assert_eq!(push_failure(&ApiError::Unauthorized), PushFailure::Abort);
        assert_eq!(
            push_failure(&ApiError::AuthExpired("invalid_grant".into())),
            PushFailure::Abort
        );
        // A poisoned row is counted and skipped, never fatal.
        assert_eq!(
            push_failure(&ApiError::Other("400 bad request".into())),
            PushFailure::Reject
        );
    }

    // ─── §B/§C update ────────────────────────────────────────────────────

    #[test]
    fn update_412_resolves_a_conflict() {
        assert_eq!(
            on_update_error(&ApiError::PreconditionFailed),
            UpdateFailure::ResolveConflict
        );
    }

    #[test]
    fn update_404_hard_deletes_local_delete_wins() {
        // Whatever produces a 404 on the PATCH, delete wins (P4). Note what
        // this row is NOT: Google's deletes are SOFT (probed, #106; modeled in
        // the fake since #114) — a PATCH to a remotely-deleted TASK answers
        // **200** with a body echoing our edit while the row stays deleted, so
        // §B × deleted converges through ghost detection on the pull, not this
        // branch. A task PATCH only 404s when its whole LIST was deleted; that
        // is the crossing this branch actually handles.
        assert_eq!(
            on_update_error(&ApiError::NotFound),
            UpdateFailure::DeleteLocal
        );
    }

    #[test]
    fn update_other_errors_defer_to_push_failure() {
        assert_eq!(
            on_update_error(&ApiError::Server { status: 500 }),
            UpdateFailure::Failed(PushFailure::Retry)
        );
        assert_eq!(
            on_update_error(&ApiError::Unauthorized),
            UpdateFailure::Failed(PushFailure::Abort)
        );
        assert_eq!(
            on_update_error(&ApiError::Other("bad due".into())),
            UpdateFailure::Failed(PushFailure::Reject)
        );
    }

    #[test]
    fn conflict_with_identical_content_adopts_remote_no_copy() {
        let local = task("t1");
        let mut remote = task("t1");
        remote.etag = Some("newer".into());
        assert_eq!(
            resolve_conflict(&local, &remote),
            ConflictResolution::AdoptRemote
        );
    }

    #[test]
    fn conflict_ignores_due_normalization_and_empty_notes() {
        let mut local = task("t1");
        local.due = Some("2026-03-04T00:00:00Z".into());
        local.notes = Some(String::new());
        let mut remote = task("t1");
        remote.due = Some("2026-03-04T00:00:00.000Z".into());
        remote.notes = None;
        assert_eq!(
            resolve_conflict(&local, &remote),
            ConflictResolution::AdoptRemote
        );
    }

    #[test]
    fn conflict_ignores_position_and_parent_so_a_remote_move_makes_no_copy() {
        // §B × moved/reordered/reparented: content is untouched, so a bumped
        // etag must NOT manufacture a conflicted copy (P3).
        let local = task("t1");
        let mut remote = task("t1");
        remote.parent = Some("p9".into());
        remote.position = "99999999999999999999".into();
        remote.etag = Some("moved".into());
        assert_eq!(
            resolve_conflict(&local, &remote),
            ConflictResolution::AdoptRemote
        );
    }

    #[test]
    fn conflict_with_divergent_title_preserves_both() {
        let mut local = task("t1");
        local.title = "mine".into();
        let mut remote = task("t1");
        remote.title = "theirs".into();
        assert_eq!(
            resolve_conflict(&local, &remote),
            ConflictResolution::ConflictedCopy
        );
    }

    #[test]
    fn status_only_divergence_resolves_remote_wins_no_copy() {
        // §C, D1 (ratified): title/notes/due all match and only the checkbox
        // differs — remote wins outright. A lost checkbox click is cheap; a
        // duplicate task is expensive and confusing.
        let local = task("t1");
        let mut remote = task("t1");
        remote.status = TaskStatus::Completed;
        assert_eq!(
            resolve_conflict(&local, &remote),
            ConflictResolution::AdoptRemote
        );
        // Both directions: local complete × remote un-complete resolves the
        // same way.
        let mut local_done = task("t1");
        local_done.status = TaskStatus::Completed;
        assert_eq!(
            resolve_conflict(&local_done, &task("t1")),
            ConflictResolution::AdoptRemote
        );
    }

    #[test]
    fn status_divergence_alongside_content_divergence_still_preserves_both() {
        // §C: D1 is narrow. The moment anything the user typed also diverges,
        // P3 applies and the local edit survives as a copy.
        let mut local = task("t1");
        local.title = "mine".into();
        local.status = TaskStatus::Completed;
        let mut remote = task("t1");
        remote.title = "theirs".into();
        assert_eq!(
            resolve_conflict(&local, &remote),
            ConflictResolution::ConflictedCopy
        );

        // Same for notes and due, each with a status divergence riding along.
        let mut notes_local = task("t1");
        notes_local.notes = Some("mine".into());
        notes_local.status = TaskStatus::Completed;
        assert_eq!(
            resolve_conflict(&notes_local, &task("t1")),
            ConflictResolution::ConflictedCopy
        );
        let mut due_local = task("t1");
        due_local.due = Some("2026-03-04T00:00:00.000Z".into());
        due_local.status = TaskStatus::Completed;
        assert_eq!(
            resolve_conflict(&due_local, &task("t1")),
            ConflictResolution::ConflictedCopy
        );
    }

    #[test]
    fn d1_does_not_leak_into_orphan_adoption() {
        // D1 relaxes CONFLICT resolution only. `same_content` still counts
        // status, so a crashed create never adopts a remote row that merely
        // looks similar — adoption must stay exact.
        let local = task("local-uuid");
        let mut committed = task("server-id");
        committed.title = local.title.clone();
        committed.status = TaskStatus::Completed;
        assert!(find_orphan(&local, &[committed], &HashSet::new()).is_none());
        assert!(!same_content(&local, &{
            let mut t = task("x");
            t.title = local.title.clone();
            t.status = TaskStatus::Completed;
            t
        }));
    }

    // ─── §B/§G base snapshot (#124) ──────────────────────────────────────────

    #[test]
    fn only_local_diverged_true_for_a_bare_remote_reorder() {
        // #118: the remote moved position/parent and bumped the etag but left
        // the TYPED content equal to our base — only WE changed. Structural
        // fields are not part of the comparison, so they never break the match.
        // Normalization tolerance matches `same_content` (due canonicalization,
        // empty notes ≡ None).
        let base = BaseSnapshot {
            title: "t".into(),
            notes: Some(String::new()),
            due: Some("2026-03-04T00:00:00Z".into()),
            status: TaskStatus::NeedsAction,
        };
        let mut reordered = task("t1");
        reordered.title = "t".into();
        reordered.notes = None;
        reordered.due = Some("2026-03-04T00:00:00.000Z".into());
        reordered.parent = Some("p9".into());
        reordered.position = "99999999999999999999".into();
        reordered.etag = Some("bumped".into());
        assert!(only_local_diverged(&reordered, &base));

        // Status is EXCLUDED: a completed-parent cascade can flip the server's
        // status without it being a content divergence (both sides cascade).
        let mut cascaded = reordered.clone();
        cascaded.status = TaskStatus::Completed;
        assert!(
            only_local_diverged(&cascaded, &base),
            "a status-only server change is not a typed-content divergence"
        );

        // A genuine remote TYPED edit is a real divergence — not "only local".
        let mut theirs = reordered.clone();
        theirs.title = "theirs".into();
        assert!(!only_local_diverged(&theirs, &base));
    }

    #[test]
    fn find_orphan_by_base_adopts_despite_a_mid_flight_edit() {
        // #122: the row was edited during the in-flight window, so its CURRENT
        // content no longer matches the committed server row and `find_orphan`
        // misses — but the base (the payload as sent) still adopts it.
        let base = BaseSnapshot {
            title: "buy milk".into(),
            notes: None,
            due: None,
            status: TaskStatus::NeedsAction,
        };
        let mut committed = task("server-id");
        committed.title = "buy milk".into();

        let mut drifted = task("local-uuid");
        drifted.title = "buy oat milk".into();
        assert!(
            find_orphan(&drifted, std::slice::from_ref(&committed), &HashSet::new()).is_none(),
            "current content misses the orphan"
        );
        assert_eq!(
            find_orphan_by_base(
                &base,
                false,
                std::slice::from_ref(&committed),
                &HashSet::new()
            )
            .map(|t| t.id.as_str()),
            Some("server-id"),
            "the base still adopts it"
        );
        // A row we already track locally is never re-adopted.
        assert!(find_orphan_by_base(&base, false, &[committed], &ids(&["server-id"])).is_none());
    }

    #[test]
    fn find_orphan_by_base_tolerates_the_completed_parent_cascade() {
        // RFC-009 §G: a subtask inserted under a completed parent is stored
        // already completed, so the payload (needsAction) and the committed row
        // (completed) disagree only on status. With a completed parent that is
        // our cascaded child — adopt it — otherwise a crashed subtask create
        // duplicates. Top-level, status stays strict (d1-does-not-leak).
        let base = BaseSnapshot {
            title: "sub".into(),
            notes: None,
            due: None,
            status: TaskStatus::NeedsAction, // what we sent
        };
        let mut committed = task("server-sub");
        committed.title = "sub".into();
        committed.status = TaskStatus::Completed; // what the server stored
        // Parent completed → the coercion is explained → adopt.
        assert_eq!(
            find_orphan_by_base(
                &base,
                true,
                std::slice::from_ref(&committed),
                &HashSet::new()
            )
            .map(|t| t.id.as_str()),
            Some("server-sub"),
        );
        // Parent NOT completed → a completed same-title row is unrelated → miss.
        assert!(
            find_orphan_by_base(&base, false, &[committed], &HashSet::new()).is_none(),
            "status stays strict without a completed-parent explanation"
        );
    }

    #[test]
    fn conflict_refetch_failures() {
        assert_eq!(
            on_conflict_refetch_error(&ApiError::NotFound),
            RefetchFailure::DeleteLocal
        );
        assert_eq!(
            on_conflict_refetch_error(&ApiError::Server { status: 503 }),
            RefetchFailure::StayDirty
        );
        // Non-transient, non-404 aborts the run and preserves the local edit.
        assert_eq!(
            on_conflict_refetch_error(&ApiError::Other("bad json".into())),
            RefetchFailure::Abort
        );
        assert_eq!(
            on_conflict_refetch_error(&ApiError::Unauthorized),
            RefetchFailure::Abort
        );
    }

    #[test]
    fn update_patch_canonicalizes_due_and_clears_notes() {
        let mut row = stored(task("t1"));
        row.task.due = Some("2026-03-04".into()); // bare date: Google 400s it
        row.task.notes = None;
        let patch = update_patch(&row);
        assert_eq!(patch.due.as_deref(), Some("2026-03-04T00:00:00.000Z"));
        // Cleared notes go as "" so the server actually clears them.
        assert_eq!(patch.notes.as_deref(), Some(""));
        assert_eq!(patch.status, Some(TaskStatus::NeedsAction));
    }

    #[test]
    fn update_patch_degrades_an_unparseable_due_to_clear() {
        let mut row = stored(task("t1"));
        row.task.due = Some("not a date".into());
        assert_eq!(update_patch(&row).due.as_deref(), Some(""));
    }

    #[test]
    fn conflicted_copy_is_an_unpushed_create_that_keeps_the_local_edit() {
        let mut local = stored(task("t1"));
        local.task.title = "mine".into();
        local.task.due = Some("2026-03-04T00:00:00Z".into());
        local.task.parent = Some("p1".into());
        let mut remote = task("t1");
        remote.title = "theirs".into();

        let copy = conflicted_copy(&local, &remote, "new-uuid".into());
        assert_eq!(copy.task.id, "new-uuid");
        assert_eq!(copy.task.title, "mine (conflicted copy)");
        assert_eq!(copy.task.due.as_deref(), Some("2026-03-04T00:00:00Z"));
        assert_eq!(copy.task.parent.as_deref(), Some("p1"));
        // Unpushed: no etag, dirty, pending create — P2 says nothing may
        // destroy it before the server has seen it.
        assert!(copy.task.etag.is_none());
        assert_eq!(copy.sync_state, SyncState::Dirty);
        assert_eq!(copy.pending_op.as_deref(), Some("create"));

        let canonical = canonical_row(&remote, &local.list_id);
        assert_eq!(canonical.task.title, "theirs");
        assert_eq!(canonical.sync_state, SyncState::Clean);
        assert!(canonical.pending_op.is_none());
    }

    // ─── §D delete ───────────────────────────────────────────────────────

    #[test]
    fn delete_succeeds_and_404_counts_as_success() {
        assert_eq!(plan_delete(None), DeleteAction::HardDeleteLocal);
        assert_eq!(
            plan_delete(Some(&ApiError::NotFound)),
            DeleteAction::HardDeleteLocal
        );
    }

    #[test]
    fn delete_wins_in_both_directions() {
        // P4, pinned at the layer where the choice lives. `plan_delete` takes
        // NOTHING but the error: no etag, no remote row, no local content. A
        // pending delete therefore cannot be talked out of landing by anything
        // the server concurrently did to the row — that missing parameter IS
        // the "unconditional" in P4, and adding one would fail to compile here
        // rather than silently changing the matrix.
        //
        // Probe 7 (#106) established this is a CHOICE, not a constraint:
        // Google's DELETE does honor `If-Match` (stale → 412, task survives).
        // `http.rs::delete_task` sends none on purpose — pinned separately by
        // `delete_task_sends_no_if_match` in `api::http`.
        assert_eq!(plan_delete(None), DeleteAction::HardDeleteLocal);

        // The other direction of P4: a local content edit that discovers the
        // row already gone remotely also resolves delete-wins — the edit is
        // discarded and the local row dies, on the push and on the refetch
        // that follows a 412. Neither path forks a conflicted copy.
        assert_eq!(
            on_update_error(&ApiError::NotFound),
            UpdateFailure::DeleteLocal
        );
        assert_eq!(
            on_conflict_refetch_error(&ApiError::NotFound),
            RefetchFailure::DeleteLocal
        );
    }

    #[test]
    fn delete_failures_defer_to_push_failure() {
        assert_eq!(
            plan_delete(Some(&ApiError::Network("down".into()))),
            DeleteAction::Failed(PushFailure::Retry)
        );
        assert_eq!(
            plan_delete(Some(&ApiError::AuthExpired("gone".into()))),
            DeleteAction::Failed(PushFailure::Abort)
        );
        assert_eq!(
            plan_delete(Some(&ApiError::Other("403".into()))),
            DeleteAction::Failed(PushFailure::Reject)
        );
    }

    // ─── §G create ───────────────────────────────────────────────────────

    #[test]
    fn create_eligibility_gate() {
        let none = HashSet::new();
        assert!(create_is_eligible(Some("create"), "a", &none, &none, None));
        // Not a create.
        assert!(!create_is_eligible(Some("update"), "a", &none, &none, None));
        assert!(!create_is_eligible(None, "a", &none, &none, None));
        // Already attempted this run — never twice (duplicate insert).
        assert!(!create_is_eligible(
            Some("create"),
            "a",
            &ids(&["a"]),
            &none,
            None
        ));
        // Unresolved in-flight marker — waits for a complete remote view.
        assert!(!create_is_eligible(
            Some("create"),
            "a",
            &none,
            &ids(&["a"]),
            None
        ));
        // The one id the UI holds waits; every other create still pushes.
        assert!(!create_is_eligible(
            Some("create"),
            "a",
            &none,
            &none,
            Some("a")
        ));
        assert!(create_is_eligible(
            Some("create"),
            "b",
            &none,
            &none,
            Some("a")
        ));
    }

    #[test]
    fn a_mutation_waits_while_its_own_create_is_unresolved_in_flight() {
        // The row has no server id yet AND its insert may already have
        // committed: pushing an update or a delete against its local UUID
        // would 400, and a delete that "succeeded" would leave the committed
        // row behind to be pulled back as a duplicate (#113/#120).
        let none: HashSet<String> = HashSet::new();
        assert!(mutation_is_pushable("a", &none));
        assert!(!mutation_is_pushable("a", &ids(&["a"])));
        assert!(
            mutation_is_pushable("b", &ids(&["a"])),
            "only the row behind the marker waits; everything else pushes"
        );
    }

    #[test]
    fn subtask_create_waits_for_an_unpushed_parent() {
        assert!(parent_is_pushable(None));
        assert!(parent_is_pushable(Some(RefState::Synced)));
        assert!(!parent_is_pushable(Some(RefState::Local)));
        assert!(!parent_is_pushable(Some(RefState::Missing)));
    }

    #[test]
    fn ref_state_reads_etag_presence() {
        assert_eq!(RefState::of(None), RefState::Missing);
        assert_eq!(RefState::of(Some(&stored(task("a")))), RefState::Synced);
        let mut unsynced = stored(task("a"));
        unsynced.task.etag = None;
        assert_eq!(RefState::of(Some(&unsynced)), RefState::Local);
    }

    #[test]
    fn subtask_create_anchors_after_its_last_synced_sibling() {
        let mut child = stored(task("new"));
        child.task.parent = Some("p".into());
        child.task.etag = None;

        let mut sib_a = stored(task("a"));
        sib_a.task.parent = Some("p".into());
        sib_a.task.position = "00000000000000000001".into();
        let mut sib_b = stored(task("b"));
        sib_b.task.parent = Some("p".into());
        sib_b.task.position = "00000000000000000002".into();
        // Unsynced sibling: naming its local UUID would draw a 400.
        let mut sib_c = stored(task("c"));
        sib_c.task.parent = Some("p".into());
        sib_c.task.position = "00000000000000000009".into();
        sib_c.task.etag = None;
        // Another parent's child must never be used as the anchor.
        let mut other = stored(task("z"));
        other.task.parent = Some("q".into());
        other.task.position = "00000000000000000099".into();

        let rows = vec![child.clone(), sib_a, sib_b, sib_c, other];
        assert_eq!(create_previous_anchor(&child, &rows).as_deref(), Some("b"));

        // A top-level create has no anchor at all.
        let top = stored(task("top"));
        assert_eq!(create_previous_anchor(&top, &rows), None);
    }

    #[test]
    fn create_payload_canonicalizes_due_and_carries_the_anchor() {
        let mut row = stored(task("t1"));
        row.task.due = Some("2026-03-04".into());
        row.task.parent = Some("p".into());
        let payload = create_payload(&row, Some("b".into()));
        assert_eq!(payload.due.as_deref(), Some("2026-03-04T00:00:00.000Z"));
        assert_eq!(payload.parent.as_deref(), Some("p"));
        assert_eq!(payload.previous.as_deref(), Some("b"));
        assert_eq!(payload.status, Some(TaskStatus::NeedsAction));
    }

    #[test]
    fn transient_create_failure_keeps_the_inflight_marker() {
        // The insert may already have landed — keeping the marker is what
        // lets the next run adopt the orphan instead of duplicating it.
        assert_eq!(
            on_create_error(&ApiError::Server { status: 502 }),
            CreateFailure::KeepInflight
        );
        assert_eq!(
            on_create_error(&ApiError::Other("400".into())),
            CreateFailure::ClearInflight(PushFailure::Reject)
        );
        assert_eq!(
            on_create_error(&ApiError::Unauthorized),
            CreateFailure::ClearInflight(PushFailure::Abort)
        );
    }

    #[test]
    fn orphan_adoption_is_scoped_to_content_and_unknown_ids() {
        let local = task("local-uuid");
        let mut committed = task("server-id");
        committed.title = local.title.clone();

        // Our content under an id we never recorded → adopt it.
        assert_eq!(
            find_orphan(&local, &[committed.clone()], &ids(&["local-uuid"])).map(|t| t.id.as_str()),
            Some("server-id")
        );
        // Already tracked locally → not an orphan.
        assert!(find_orphan(&local, &[committed.clone()], &ids(&["server-id"])).is_none());
        // Different content → never merged (duplicate titles are legal, this
        // is not content dedup).
        let mut unrelated = task("other");
        unrelated.title = "something else".into();
        assert!(find_orphan(&local, &[unrelated], &HashSet::new()).is_none());
    }

    // ─── §E/§F moves ─────────────────────────────────────────────────────

    fn refs(task: RefState, parent: Option<RefState>, previous: Option<RefState>) -> MoveRefs {
        MoveRefs {
            task,
            parent,
            previous,
            task_has_children: false,
            parent_is_subtask: false,
        }
    }

    #[test]
    fn move_with_all_ids_synced_is_sent_whole() {
        assert_eq!(
            plan_move(refs(
                RefState::Synced,
                Some(RefState::Synced),
                Some(RefState::Synced)
            )),
            MoveIntent::Send {
                keep_previous: true
            }
        );
        // A bare reorder to the top of a list names neither ref.
        assert_eq!(
            plan_move(refs(RefState::Synced, None, None)),
            MoveIntent::Send {
                keep_previous: false
            }
        );
    }

    #[test]
    fn move_whose_target_parent_vanished_is_dropped() {
        assert_eq!(
            plan_move(refs(
                RefState::Synced,
                Some(RefState::Missing),
                Some(RefState::Synced)
            )),
            MoveIntent::Drop
        );
    }

    #[test]
    fn move_whose_previous_vanished_degrades_to_the_reparent() {
        // P5: degrade, never wedge — the reparent is still expressible.
        assert_eq!(
            plan_move(refs(
                RefState::Synced,
                Some(RefState::Synced),
                Some(RefState::Missing)
            )),
            MoveIntent::Send {
                keep_previous: false
            }
        );
    }

    #[test]
    fn move_waits_while_any_named_id_is_still_local() {
        assert_eq!(
            plan_move(refs(RefState::Local, None, None)),
            MoveIntent::Wait
        );
        assert_eq!(
            plan_move(refs(RefState::Missing, None, None)),
            MoveIntent::Wait
        );
        assert_eq!(
            plan_move(refs(RefState::Synced, Some(RefState::Local), None)),
            MoveIntent::Wait
        );
        assert_eq!(
            plan_move(refs(RefState::Synced, None, Some(RefState::Local))),
            MoveIntent::Wait
        );
    }

    #[test]
    fn a_vanished_previous_does_not_rescue_an_unsynced_parent() {
        // Degradation drops the ordering, but the reparent still names a
        // local-only id — that must still wait, not be sent as a 400.
        assert_eq!(
            plan_move(refs(
                RefState::Synced,
                Some(RefState::Local),
                Some(RefState::Missing)
            )),
            MoveIntent::Wait
        );
    }

    #[test]
    fn move_previous_id_follows_the_plan() {
        let mv = PendingMove {
            task_id: "t".into(),
            list_id: "L".into(),
            parent_id: Some("p".into()),
            previous_id: Some("b".into()),
        };
        assert_eq!(
            move_previous_id(
                &mv,
                MoveIntent::Send {
                    keep_previous: true
                }
            )
            .as_deref(),
            Some("b")
        );
        assert_eq!(
            move_previous_id(
                &mv,
                MoveIntent::Send {
                    keep_previous: false
                }
            ),
            None
        );
    }

    #[test]
    fn move_adopts_the_body_only_for_a_clean_row() {
        let clean = stored(task("t"));
        assert_eq!(move_adoption(Some(&clean)), MoveAdoption::Body);
        let mut dirty = stored(task("t"));
        dirty.sync_state = SyncState::Dirty;
        dirty.pending_op = Some("update".into());
        // A pending content edit must survive the move response.
        assert_eq!(move_adoption(Some(&dirty)), MoveAdoption::MetaOnly);
        assert_eq!(move_adoption(None), MoveAdoption::MetaOnly);
    }

    #[test]
    fn move_failures() {
        // No `previous` was sent, so a 404 can only mean the subject is gone.
        assert_eq!(
            on_move_error(&ApiError::NotFound, false),
            MoveFailure::DropIntent
        );
        assert_eq!(
            on_move_error(&ApiError::Server { status: 500 }, false),
            MoveFailure::Retry
        );
        assert_eq!(
            on_move_error(&ApiError::Unauthorized, false),
            MoveFailure::Abort
        );
        // A rejected move drops its intent so it can't retry forever (P5).
        assert_eq!(
            on_move_error(&ApiError::Other("400 invalid".into()), false),
            MoveFailure::RejectAndDrop
        );
    }

    #[test]
    fn a_move_404_is_ambiguous_only_while_a_previous_was_sent() {
        // §E gap: the move endpoint answers 404 for BOTH "previous task id not
        // found" (probe 2, verified live) and a subject the server no longer
        // has. Reading either as "the task is gone" would throw away a reparent
        // the server would have accepted. The ladder resolves the ambiguity by
        // experiment instead of by guessing: drop the ordering half, retry.
        assert_eq!(
            on_move_error(&ApiError::NotFound, true),
            MoveFailure::DropPreviousAndRetry
        );
        // The retry names no `previous`, so its 404 is unambiguous.
        assert_eq!(
            on_move_error(&ApiError::NotFound, false),
            MoveFailure::DropIntent
        );
        // Only 404 is ambiguous — every other status means the same either way,
        // so nothing else may enter the ladder (a retried 400 would be a second
        // pointless call, a retried 503 would double-count the outage).
        for sent_previous in [true, false] {
            assert_eq!(
                on_move_error(
                    &ApiError::Other("400: Invalid task ID".into()),
                    sent_previous
                ),
                MoveFailure::RejectAndDrop
            );
            assert_eq!(
                on_move_error(&ApiError::Server { status: 503 }, sent_previous),
                MoveFailure::Retry
            );
            assert_eq!(
                on_move_error(&ApiError::Unauthorized, sent_previous),
                MoveFailure::Abort
            );
        }
    }

    #[test]
    fn a_demote_that_would_create_a_third_level_is_refused() {
        // §F gap: Google ACCEPTS a move that nests a task three deep (probe 3,
        // 200 — there is no depth cap), so invariant #1 is ours to enforce.
        // The moved task already has subtasks of its own — a remote pull can
        // hand it one after the demote was recorded.
        let mut with_children = refs(RefState::Synced, Some(RefState::Synced), None);
        with_children.task_has_children = true;
        assert_eq!(plan_move(with_children), MoveIntent::Refuse);

        // The mirror: the target parent is itself a subtask.
        let mut under_a_subtask = refs(RefState::Synced, Some(RefState::Synced), None);
        under_a_subtask.parent_is_subtask = true;
        assert_eq!(plan_move(under_a_subtask), MoveIntent::Refuse);
    }

    #[test]
    fn a_promote_or_reorder_of_a_parent_task_is_still_allowed() {
        // The refusal is about DEPTH, not about having children: detaching a
        // task with subtasks (parent cleared) leaves the tree one level deep,
        // and so does reordering it among its siblings.
        let mut promote = refs(RefState::Synced, None, Some(RefState::Synced));
        promote.task_has_children = true;
        assert_eq!(
            plan_move(promote),
            MoveIntent::Send {
                keep_previous: true
            }
        );
        // And a childless demote under a top-level parent is the normal path.
        assert_eq!(
            plan_move(refs(RefState::Synced, Some(RefState::Synced), None)),
            MoveIntent::Send {
                keep_previous: false
            }
        );
    }

    // ─── §I list ops ─────────────────────────────────────────────────────

    #[test]
    fn list_create_adopts_a_same_title_remote_list_once() {
        let remote = vec![list("r1", "My Tasks"), list("r2", "Work")];
        assert_eq!(
            adoptable_list("My Tasks", &remote, &HashSet::new()).map(|l| l.id.as_str()),
            Some("r1")
        );
        // Already tracked → insert a new remote list instead of colliding.
        assert!(adoptable_list("My Tasks", &remote, &ids(&["r1"])).is_none());
        assert!(adoptable_list("Errands", &remote, &HashSet::new()).is_none());
    }

    #[test]
    fn list_rename_failures() {
        assert_eq!(
            on_list_rename_error(&ApiError::NotFound),
            ListRenameFailure::DeleteLocal
        );
        assert_eq!(
            on_list_rename_error(&ApiError::Network("x".into())),
            ListRenameFailure::Failed(PushFailure::Retry)
        );
        assert_eq!(
            on_list_rename_error(&ApiError::Unauthorized),
            ListRenameFailure::Failed(PushFailure::Abort)
        );
    }

    #[test]
    fn list_delete_outcomes() {
        assert_eq!(plan_list_delete(None), ListDeleteAction::DeleteLocal);
        assert_eq!(
            plan_list_delete(Some(&ApiError::NotFound)),
            ListDeleteAction::DeleteLocal
        );
        assert_eq!(
            plan_list_delete(Some(&ApiError::Server { status: 503 })),
            ListDeleteAction::Retry
        );
        assert_eq!(
            plan_list_delete(Some(&ApiError::Unauthorized)),
            ListDeleteAction::Abort
        );
        // Refused (e.g. the account's default list) — revive rather than nag
        // forever with a tombstone that can never push.
        assert_eq!(
            plan_list_delete(Some(&ApiError::Other("403 forbidden".into()))),
            ListDeleteAction::Revive
        );
    }

    // ─── §A pull ─────────────────────────────────────────────────────────

    #[test]
    fn pull_batch_skips_dirty_rows_and_inflight_orphans() {
        let mut committed = task("server-id");
        committed.title = "task local-uuid".into(); // same content as the base
        let inflight = InflightBase {
            base: BaseSnapshot {
                title: "task local-uuid".into(),
                notes: None,
                due: None,
                status: TaskStatus::NeedsAction,
            },
            parent: None,
        };
        let batch = pull_batch(
            vec![task("a"), task("b"), committed],
            &ids(&["a"]),
            &[inflight],
        );
        let got: Vec<&str> = batch.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(got, vec!["b"]);
    }

    #[test]
    fn pull_batch_skips_an_inflight_orphan_edited_during_the_window() {
        // #122 at the pull layer: the local row drifted ("edited"), but the base
        // still matches the committed orphan, so the pull leaves it for recovery
        // instead of front-running it as a duplicate.
        let mut committed = task("server-id");
        committed.title = "buy milk".into(); // the payload as sent
        let inflight = InflightBase {
            base: BaseSnapshot {
                title: "buy milk".into(),
                notes: None,
                due: None,
                status: TaskStatus::NeedsAction,
            },
            parent: None,
        };
        let batch = pull_batch(vec![committed], &HashSet::new(), &[inflight]);
        assert!(batch.is_empty(), "the committed orphan is not pulled");
    }

    #[test]
    fn pull_batch_skips_a_completed_subtask_orphan_under_a_completed_parent() {
        // RFC-009 §G at the pull layer: the committed child was stored completed
        // by the cascade, but the parent-completed tolerance still recognizes it.
        let mut parent = task("remote-parent");
        parent.status = TaskStatus::Completed;
        let mut child = task("remote-child");
        child.title = "sub".into();
        child.parent = Some("remote-parent".into());
        child.status = TaskStatus::Completed;
        let inflight = InflightBase {
            base: BaseSnapshot {
                title: "sub".into(),
                notes: None,
                due: None,
                status: TaskStatus::NeedsAction, // payload was open
            },
            parent: Some("remote-parent".into()),
        };
        let batch = pull_batch(vec![parent, child], &HashSet::new(), &[inflight]);
        let got: Vec<&str> = batch.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(got, vec!["remote-parent"], "only the parent is pulled");
    }

    #[test]
    fn pull_batch_orders_parents_before_children_at_any_depth() {
        let mut child = task("c");
        child.parent = Some("b".into());
        let mut mid = task("b");
        mid.parent = Some("a".into());
        let batch = pull_batch(vec![child, mid, task("a")], &HashSet::new(), &[]);
        let got: Vec<&str> = batch.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(got, vec!["a", "b", "c"]);
    }

    #[test]
    fn order_parents_first_appends_a_cycle_instead_of_dropping_it() {
        let mut a = task("a");
        a.parent = Some("b".into());
        let mut b = task("b");
        b.parent = Some("a".into());
        let out = order_parents_first(vec![a, b]);
        assert_eq!(out.len(), 2, "a cycle must not silently drop rows");
    }

    #[test]
    fn pull_row_skips_only_on_a_matching_etag() {
        let batch_ids = ids(&["t1"]);
        let known = HashSet::new();
        let mut etags = HashMap::new();
        etags.insert("t1".to_string(), Some("etag-t1".to_string()));
        let ctx = PullRowContext {
            local_etags: &etags,
            batch_ids: &batch_ids,
            known_local: &known,
        };
        assert_eq!(plan_pull_row(&task("t1"), &ctx), PullRowAction::Skip);

        let mut changed = task("t1");
        changed.etag = Some("newer".into());
        assert_eq!(plan_pull_row(&changed, &ctx), PullRowAction::Upsert);

        // A row whose local etag is NULL (e.g. the web_view_link backfill) is
        // never skipped.
        let mut null_etags = HashMap::new();
        null_etags.insert("t1".to_string(), None);
        let ctx2 = PullRowContext {
            local_etags: &null_etags,
            batch_ids: &batch_ids,
            known_local: &known,
        };
        assert_eq!(plan_pull_row(&task("t1"), &ctx2), PullRowAction::Upsert);
    }

    #[test]
    fn pull_row_detaches_a_child_whose_parent_is_nowhere_yet() {
        let mut child = task("c");
        child.parent = Some("p".into());
        let etags = HashMap::new();

        // Parent neither in the batch nor already local → detach so the FK
        // holds; the dropped etag re-links it next pull.
        let batch_ids = ids(&["c"]);
        let known = HashSet::new();
        assert_eq!(
            plan_pull_row(
                &child,
                &PullRowContext {
                    local_etags: &etags,
                    batch_ids: &batch_ids,
                    known_local: &known,
                }
            ),
            PullRowAction::UpsertDetached
        );

        // Parent in the same batch → plain upsert.
        let batch_with_parent = ids(&["c", "p"]);
        assert_eq!(
            plan_pull_row(
                &child,
                &PullRowContext {
                    local_etags: &etags,
                    batch_ids: &batch_with_parent,
                    known_local: &known,
                }
            ),
            PullRowAction::Upsert
        );

        // Parent already local (its row was skipped as dirty) → plain upsert.
        let known_parent = ids(&["p"]);
        assert_eq!(
            plan_pull_row(
                &child,
                &PullRowContext {
                    local_etags: &etags,
                    batch_ids: &batch_ids,
                    known_local: &known_parent,
                }
            ),
            PullRowAction::Upsert
        );
    }

    #[test]
    fn list_pull_preserves_a_locally_renamed_list() {
        let mut local = stored_list(list("r1", "renamed here"));
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        assert_eq!(
            plan_list_pull(&list("r1", "server title"), &[local]),
            ListPullAction::KeepLocal
        );
    }

    #[test]
    fn list_pull_adopts_an_unpushed_local_create_by_title() {
        let mut orphan = stored_list(list("local-uuid", "Work"));
        orphan.list.etag = None;
        orphan.pending_op = Some("create".into());
        assert_eq!(
            plan_list_pull(&list("r2", "Work"), &[orphan]),
            ListPullAction::AdoptLocalCreate {
                local_id: "local-uuid".into()
            }
        );
    }

    #[test]
    fn list_pull_adopts_a_remote_rename_even_when_the_etag_is_unchanged() {
        // §I / D6: a list rename resolves REMOTE-WINS, and it must not be
        // possible for a stale etag to freeze the local title out of the pull
        // (the P6 failure mode, at list level). Tasks are skipped on a matching
        // etag; lists deliberately are NOT — the title itself is compared, so a
        // server-side rename always lands even if the etag and `updated` are
        // byte-identical to what we hold.
        let stored = stored_list(list("r1", "Work"));
        let mut renamed = list("r1", "Career");
        renamed.etag = stored.list.etag.clone();
        renamed.updated = stored.list.updated.clone();
        assert_eq!(
            plan_list_pull(&renamed, std::slice::from_ref(&stored)),
            ListPullAction::Upsert { changed: true },
            "the remote title wins; no conflicted copy exists for lists"
        );
    }

    // ─── §G3 / D2 — the re-home target ───────────────────────────────────

    #[test]
    fn rehome_target_prefers_the_default_list() {
        let lists = [
            stored_list(list("r1", "Work")),
            stored_list(list("r2", "My Tasks")),
            stored_list(list("r3", "Dying")),
        ];
        assert_eq!(
            rehome_target(&lists, "r3").map(|l| l.list.id.as_str()),
            Some("r2")
        );
    }

    #[test]
    fn rehome_target_falls_back_to_the_first_list_deterministically() {
        // No "My Tasks": alphabetical by title, ties broken by id, so the
        // answer never depends on store iteration order.
        let lists = [
            stored_list(list("r2", "Work")),
            stored_list(list("r1", "Work")),
            stored_list(list("r3", "Admin")),
        ];
        assert_eq!(
            rehome_target(&lists, "zz").map(|l| l.list.id.as_str()),
            Some("r3")
        );
        let ties = [
            stored_list(list("r2", "Work")),
            stored_list(list("r1", "Work")),
        ];
        assert_eq!(
            rehome_target(&ties, "zz").map(|l| l.list.id.as_str()),
            Some("r1")
        );
    }

    #[test]
    fn rehome_target_skips_lists_that_cannot_keep_the_work() {
        // A local-only list never pushes (the re-homed create would never
        // sync) and a tombstoned list is about to take its rows down again.
        let mut local_only = stored_list(list("r1", "My Tasks"));
        local_only.local_only = true;
        let mut doomed = stored_list(list("r2", "Archive"));
        doomed.sync_state = SyncState::Deleted;
        doomed.pending_op = Some("delete".into());
        let good = stored_list(list("r3", "Work"));

        let lists = [local_only.clone(), doomed.clone(), good];
        assert_eq!(
            rehome_target(&lists, "dying").map(|l| l.list.id.as_str()),
            Some("r3")
        );
        // Nothing usable at all — the caller must keep the dying list.
        assert!(rehome_target(&[local_only, doomed], "dying").is_none());
        assert!(rehome_target(&[], "dying").is_none());
    }

    #[test]
    fn rehome_target_never_returns_the_dying_list() {
        let lists = [stored_list(list("r1", "My Tasks"))];
        assert!(rehome_target(&lists, "r1").is_none());
    }

    #[test]
    fn list_pull_reports_whether_anything_changed() {
        let stored = stored_list(list("r1", "Work"));
        assert_eq!(
            plan_list_pull(&list("r1", "Work"), std::slice::from_ref(&stored)),
            ListPullAction::Upsert { changed: false }
        );
        assert_eq!(
            plan_list_pull(
                &list("r1", "Renamed remotely"),
                std::slice::from_ref(&stored)
            ),
            ListPullAction::Upsert { changed: true }
        );
        assert_eq!(
            plan_list_pull(&list("r1", "Work"), &[]),
            ListPullAction::Upsert { changed: true }
        );
        // A local-only list shadowing the same id still counts as a change.
        let mut local_only = stored.clone();
        local_only.local_only = true;
        assert_eq!(
            plan_list_pull(&list("r1", "Work"), &[local_only]),
            ListPullAction::Upsert { changed: true }
        );
    }

    // ─── content comparison ──────────────────────────────────────────────

    #[test]
    fn same_content_covers_exactly_title_notes_due_status() {
        let a = task("x");
        let mut b = task("y"); // different id and etag
        b.title = a.title.clone();
        assert!(same_content(&a, &b));

        let mut notes = b.clone();
        notes.notes = Some("hi".into());
        assert!(!same_content(&a, &notes));

        let mut due = b.clone();
        due.due = Some("2026-03-04T00:00:00.000Z".into());
        assert!(!same_content(&a, &due));

        let mut status = b.clone();
        status.status = TaskStatus::Completed;
        assert!(!same_content(&a, &status));
    }

    /// A clean local row with a parent, for the depth-detection tests below.
    fn child(id: &str, parent: Option<&str>) -> StoredTask {
        let mut t = task(id);
        t.parent = parent.map(ToString::to_string);
        stored(t)
    }

    #[test]
    fn third_level_ids_flags_only_the_grandchild() {
        // P (top) > T (subtask) > C (grandchild). Only C sits a third level
        // deep — T is a legal one-level subtask, P is top-level.
        let rows = vec![
            child("P", None),
            child("T", Some("P")),
            child("C", Some("T")),
        ];
        assert_eq!(third_level_ids(&rows), vec!["C".to_string()]);
    }

    #[test]
    fn third_level_ids_is_empty_for_a_legal_one_level_tree() {
        // A parent with two direct subtasks is invariant #1's happy shape;
        // nothing to repair.
        let rows = vec![
            child("P", None),
            child("A", Some("P")),
            child("B", Some("P")),
        ];
        assert!(third_level_ids(&rows).is_empty());
    }

    #[test]
    fn third_level_ids_ignores_a_row_whose_parent_is_absent() {
        // A detached child (parent not present) is not a grandchild — its
        // parent chain stops at the missing row, so depth cannot exceed one.
        let rows = vec![child("C", Some("gone"))];
        assert!(third_level_ids(&rows).is_empty());
    }

    #[test]
    fn third_level_ids_skips_an_optimistic_demote_of_the_middle_row() {
        // The false-positive guard: T looks like a subtask (parent = P) purely
        // because of an un-pushed / refused-but-not-reverted optimistic demote,
        // so its row is still DIRTY. Its parent link is not server-confirmed,
        // so C must NOT be treated as a real third level — repairing it would
        // rewrite a server that is actually one level.
        let mut t = child("T", Some("P"));
        t.sync_state = SyncState::Dirty;
        let rows = vec![child("P", None), t, child("C", Some("T"))];
        assert!(third_level_ids(&rows).is_empty());
    }

    #[test]
    fn third_level_ids_flags_a_still_queued_subtask_create_under_a_clean_subtask() {
        // §G before the create pushes: C is a queued subtask create (no etag)
        // whose parent T is a clean, server-confirmed subtask. It IS a third
        // level — the leaf's state only changes HOW it is promoted (locally,
        // since it has no server id yet), not that it must be flagged.
        let mut c = child("C", Some("T"));
        c.sync_state = SyncState::Dirty;
        c.pending_op = Some("create".into());
        c.task.etag = None;
        let rows = vec![child("P", None), child("T", Some("P")), c];
        assert_eq!(third_level_ids(&rows), vec!["C".to_string()]);
    }

    #[test]
    fn third_level_ids_flags_every_clean_row_below_the_first_level() {
        // A pathological four-deep chain P > T > C > D, all clean. Both C and D
        // have a parent that is itself a subtask, so both are flagged; promoting
        // them to top-level flattens the chain to at most one level.
        let rows = vec![
            child("P", None),
            child("T", Some("P")),
            child("C", Some("T")),
            child("D", Some("C")),
        ];
        let mut got = third_level_ids(&rows);
        got.sort();
        assert_eq!(got, vec!["C".to_string(), "D".to_string()]);
    }
}
