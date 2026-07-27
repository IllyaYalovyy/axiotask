//! Sync engine: push local changes, pull remote changes, resolve conflicts.
//!
//! Design: RFC-004; conflict matrix: RFC-009. Single entry point
//! [`SyncEngine::run`]. All conflict resolution follows "remote wins" for MVP.
//!
//! This module is the IO half of sync: it **observes** (store reads, API
//! calls), asks [`super::reconcile`] to **decide**, and **applies** the
//! decision to the store. Every branch that is a *choice* rather than a write
//! lives in `reconcile` as a pure function, so RFC-009's matrix rows are
//! testable without an engine, a fake, or a database.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tracing::{debug, info, warn};

use super::SyncError;
use super::reconcile::{
    self, ConflictResolution, CreateFailure, DeleteAction, ListDeleteAction, ListPullAction,
    ListRenameFailure, MoveAdoption, MoveFailure, MoveIntent, MoveRefs, PullRowAction, PushFailure,
    RefState, RefetchFailure, UpdateFailure,
};
use crate::api::{ApiError, GoogleTasksClient};
use crate::model::{Task, TaskList};
use crate::store::{PendingMove, Store, StoredTask, StoredTaskList, SyncState};

/// Counters and changed-data scope from a single sync run.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SyncOutcome {
    /// Tasks pulled from server (new or updated locally).
    pub pulled: u32,
    /// Tasks pushed to server.
    pub pushed: u32,
    /// Conflicts resolved (412 responses).
    pub conflicts: u32,
    /// Tasks hard-deleted locally (confirmed by server or ghost detection).
    pub deleted: u32,
    /// Rows whose push was rejected by the server (e.g. a 400). The row stays
    /// dirty and the run continues — one poisoned row must not stop the other
    /// pushes, or the pull.
    pub errors: u32,
    /// Task lists whose task rows changed locally during this run.
    pub changed_list_ids: Vec<String>,
    /// The task-list collection or list metadata changed, so callers must
    /// refresh list metadata before replacing task rows.
    pub lists_changed: bool,
}

impl SyncOutcome {
    fn mark_list_changed(&mut self, list_id: &str) {
        if !self.changed_list_ids.iter().any(|id| id == list_id) {
            self.changed_list_ids.push(list_id.to_string());
        }
    }
}

/// Configuration for a sync engine instance.
#[derive(Default)]
pub struct SyncConfig {
    /// Whether to push local changes to the server.
    pub push_enabled: bool,
    /// Hold the CREATE push of exactly this one task this run: the id of the row
    /// the UI is actively holding (the inline editor's row, or the open detail
    /// panel's task). A create remaps a local id to the server id, which would
    /// invalidate the id the UI holds — so that ONE create waits. Every OTHER
    /// create still pushes: a subtask created inside an open detail panel (#85)
    /// has its own id, and remapping it never touches the parent id the panel
    /// holds. Updates/deletes/moves reuse existing ids and always push.
    pub held_create_id: Option<String>,
}

/// The sync engine. Stateless — each [`run`](SyncEngine::run) is independent.
pub struct SyncEngine {
    client: Arc<dyn GoogleTasksClient>,
    store: Store,
    config: SyncConfig,
}

impl SyncEngine {
    /// Create a new sync engine.
    pub fn new(client: Arc<dyn GoogleTasksClient>, store: Store) -> Self {
        Self {
            client,
            store,
            config: SyncConfig::default(),
        }
    }

    /// Create with explicit configuration.
    pub fn with_push(client: Arc<dyn GoogleTasksClient>, store: Store, push_enabled: bool) -> Self {
        Self {
            client,
            store,
            config: SyncConfig {
                push_enabled,
                held_create_id: None,
            },
        }
    }

    /// Hold the CREATE push of this one task id this run (see
    /// [`SyncConfig::held_create_id`]). `None` holds nothing.
    pub fn hold_create_id(mut self, id: Option<String>) -> Self {
        self.config.held_create_id = id;
        self
    }

    /// Execute a full sync cycle: push then pull. Always writes to sync_log.
    pub async fn run(&self) -> Result<SyncOutcome, SyncError> {
        let started = std::time::Instant::now();
        let mut outcome = SyncOutcome::default();
        let result = self.execute(&mut outcome).await;
        let duration_ms = started.elapsed().as_millis() as u64;
        self.store
            .write_sync_log(
                outcome.pulled,
                outcome.pushed,
                outcome.conflicts,
                duration_ms,
                result.as_ref().err().map(ToString::to_string),
            )
            .await;
        result?;
        Ok(outcome)
    }

    async fn execute(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        if self.config.push_enabled {
            self.push_all(out).await?;
        }
        self.pull_all(out).await
    }

    // ─── Push ────────────────────────────────────────────────────────────────

    /// Push all dirty rows: creates (parents first), then remaining ops.
    async fn push_all(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        // Recover any creates interrupted by a crash before pushing new ones.
        self.recover_inflight_creates(out).await?;
        // A marker recovery could NOT resolve (its list fetch died transiently,
        // so the orphan — if any — was invisible) still means "this insert may
        // already have landed". Re-pushing it now is exactly the duplicate H1
        // exists to prevent, so the create waits for a run with a complete
        // remote view. Every other create pushes as usual.
        let unresolved_creates: HashSet<String> = self
            .store
            .inflight_creates()
            .await?
            .into_iter()
            .map(|(local_id, _)| local_id)
            .collect();

        // List CREATES first — tasks reference lists, so the list must exist
        // (with its remote id) before we push tasks into it. Held while the user
        // is editing (a list-id remap would disrupt the row the UI holds), but
        // never blocks the task creates below.
        if self.config.held_create_id.is_none() {
            self.push_list_creates(out).await?;
        }

        // Creates, in dependency order. A child insert names its parent's id in
        // the request, so a create is pushable only once its parent is resolved
        // (parentless, or the parent row carries a server etag) — pushing with
        // a still-local parent id draws a permanent 400 from Google ("Invalid
        // task ID", verified live). Each finish_create remaps children's
        // parent_id in the DB, so looping until no progress resolves arbitrary
        // nesting depth; anything left (parent itself unpushable this run)
        // stays dirty for the next run. The one create the UI is holding (the
        // row being edited) waits so its id remap can't invalidate the id the UI
        // holds; every other create — including subtasks born inside an open
        // detail panel (#85) — still pushes.
        {
            // Attempt each create at most once per run: a create whose
            // response times out after the server committed would otherwise be
            // double-inserted (in-flight orphan recovery only runs at the
            // start of a run, not between passes).
            let mut attempted: HashSet<String> = HashSet::new();
            loop {
                let mut progressed = false;
                for row in &self.store.drain_dirty().await? {
                    if !reconcile::create_is_eligible(
                        row.pending_op.as_deref(),
                        &row.task.id,
                        &attempted,
                        &unresolved_creates,
                        self.config.held_create_id.as_deref(),
                    ) {
                        continue;
                    }
                    if !reconcile::parent_is_pushable(
                        self.ref_state_of(row.task.parent.as_deref()).await?,
                    ) {
                        continue;
                    }
                    attempted.insert(row.task.id.clone());
                    self.push_create(row, out).await?;
                    progressed = true;
                }
                if !progressed {
                    break;
                }
            }
        }

        // Updates and deletes reuse existing ids — except when the row's own
        // create is still unresolved in flight, in which case there is no
        // server id to reuse yet and the mutation waits for the run that
        // resolves the marker.
        for row in &self.store.drain_dirty().await? {
            if !reconcile::mutation_is_pushable(&row.task.id, &unresolved_creates) {
                continue;
            }
            match row.pending_op.as_deref() {
                Some("update") => self.push_update(row, out).await?,
                Some("delete") => self.push_delete(row, out).await?,
                _ => {}
            }
        }

        // Then position/parent moves via the move API.
        self.push_moves(out).await?;

        // Finally, list renames and deletes (after task ops so a deleted list's
        // task tombstones are pushed first).
        self.push_list_mutations(out).await?;
        Ok(())
    }

    /// Apply the decision [`reconcile::push_failure`] made for one row's push
    /// failure: log it, count it, or propagate it (aborting the run).
    fn row_push_failure(
        e: ApiError,
        out: &mut SyncOutcome,
        id: &str,
        op: &str,
    ) -> Result<(), SyncError> {
        Self::apply_push_failure(reconcile::push_failure(&e), e, out, id, op)
    }

    /// Apply an already-classified push failure (used where the decision came
    /// from an op-specific reconciler that had already inspected the error).
    fn apply_push_failure(
        failure: PushFailure,
        e: ApiError,
        out: &mut SyncOutcome,
        id: &str,
        op: &str,
    ) -> Result<(), SyncError> {
        match failure {
            PushFailure::Retry => {
                warn!(id, err = %e, "transient error on {op}, will retry");
                Ok(())
            }
            PushFailure::Abort => Err(e.into()),
            PushFailure::Reject => {
                warn!(id, err = %e, "server rejected {op}; row stays dirty, continuing");
                out.errors += 1;
                Ok(())
            }
        }
    }

    /// Push locally-created lists so their tasks can reference real ids.
    /// Adopts an existing remote list with the same title instead of creating
    /// a duplicate (covers the default "My Tasks" and same-named lists).
    async fn push_list_creates(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let creates: Vec<_> = self
            .store
            .drain_dirty_lists()
            .await?
            .into_iter()
            .filter(|l| l.pending_op.as_deref() == Some("create"))
            .collect();
        if creates.is_empty() {
            return Ok(());
        }
        // Snapshot remote lists once for adoption matching.
        let remote = match self.client.list_tasklists().await {
            Ok(v) => v,
            Err(e) if e.is_transient() => {
                warn!(err = %e, "transient listing lists, retry");
                return Ok(());
            }
            Err(e) => return Err(e.into()),
        };
        let mut local_ids: HashSet<String> = self
            .store
            .all_lists()
            .await?
            .into_iter()
            .map(|l| l.list.id)
            .collect();

        for l in creates {
            // Adopt a remote list with the same title we don't already track.
            if let Some(existing) = reconcile::adoptable_list(&l.list.title, &remote, &local_ids) {
                // Record the adoption so a SECOND same-title local create in
                // this batch doesn't remap onto the same remote id (a primary
                // key collision that aborts the run); it inserts a new remote
                // list instead.
                local_ids.insert(existing.id.clone());
                self.store
                    .remap_list_id(
                        &l.list.id,
                        &existing.id,
                        existing.etag.as_deref(),
                        &existing.updated,
                    )
                    .await?;
                out.lists_changed = true;
                debug!(local_id = %l.list.id, remote_id = %existing.id, "adopted existing list by title");
                continue;
            }
            match self.client.insert_tasklist(&l.list.title).await {
                Ok(remote_list) => {
                    self.store
                        .remap_list_id(
                            &l.list.id,
                            &remote_list.id,
                            remote_list.etag.as_deref(),
                            &remote_list.updated,
                        )
                        .await?;
                    out.pushed += 1;
                    out.lists_changed = true;
                    debug!(local_id = %l.list.id, remote_id = %remote_list.id, "pushed list create");
                }
                Err(e) => Self::row_push_failure(e, out, &l.list.id, "list create")?,
            }
        }
        Ok(())
    }

    /// Push list renames (update) and deletions.
    async fn push_list_mutations(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        for l in self.store.drain_dirty_lists().await? {
            match l.pending_op.as_deref() {
                Some("update") => match self.client.patch_tasklist(&l.list.id, &l.list.title).await
                {
                    Ok(remote) => {
                        self.store
                            .mark_list_clean(&remote.id, remote.etag.as_deref(), &remote.updated)
                            .await?;
                        out.pushed += 1;
                        out.lists_changed = true;
                    }
                    Err(e) => match reconcile::on_list_rename_error(&e) {
                        ListRenameFailure::DeleteLocal => {
                            // The list is gone on the server, so it goes here
                            // too (P4) — but the rows it holds that the server
                            // has NEVER SEEN must not die with it (P2/D2).
                            // This is the pull's ghost-list discovery arriving
                            // through a different call, so it re-homes them
                            // the same way.
                            let survivors: Vec<StoredTaskList> = self
                                .store
                                .all_lists()
                                .await?
                                .into_iter()
                                .filter(|s| s.list.id != l.list.id)
                                .collect();
                            if self
                                .rehome_before_dropping(&l.list.id, &survivors, out)
                                .await?
                            {
                                self.store.delete_list_hard(&l.list.id).await?;
                            } else {
                                // Nowhere to put them: keep the list as an
                                // unpushed create so it is re-created on the
                                // server and the rows land in it.
                                let mut revived = l.clone();
                                revived.list.etag = None;
                                revived.sync_state = SyncState::Dirty;
                                revived.pending_op = Some("create".into());
                                self.store.upsert_list(&revived).await?;
                            }
                            out.lists_changed = true;
                        }
                        ListRenameFailure::Failed(f) => {
                            Self::apply_push_failure(f, e, out, &l.list.id, "list rename")?;
                        }
                    },
                },
                Some("delete") => {
                    let result = self.client.delete_tasklist(&l.list.id).await;
                    match reconcile::plan_list_delete(result.as_ref().err()) {
                        ListDeleteAction::DeleteLocal => {
                            self.store.delete_list_hard(&l.list.id).await?;
                            out.deleted += 1;
                            out.lists_changed = true;
                        }
                        ListDeleteAction::Retry => {
                            if let Err(e) = &result {
                                warn!(err = %e, "transient on list delete, retry");
                            }
                        }
                        ListDeleteAction::Abort => return Err(result.unwrap_err().into()),
                        ListDeleteAction::Revive => {
                            // Permanently refused — Google will not delete an
                            // account's default list, for example. Revive the
                            // list (its tasks re-pull) and tell the user via
                            // the error count.
                            if let Err(e) = &result {
                                warn!(id = %l.list.id, err = %e, "list delete refused by server; restoring list");
                            }
                            out.errors += 1;
                            let mut revived = l.clone();
                            revived.sync_state = SyncState::Clean;
                            revived.pending_op = None;
                            self.store.upsert_list(&revived).await?;
                            out.lists_changed = true;
                        }
                    }
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// Recover creates interrupted by a crash between the server insert and the
    /// local commit. For each in-flight marker, look for an orphaned remote
    /// task (our content, an id we never recorded) and adopt it instead of
    /// re-inserting — eliminating the duplicate. Scoped strictly to in-flight
    /// creates, so it never merges unrelated tasks.
    async fn recover_inflight_creates(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let inflight = self.store.inflight_creates().await?;
        for (local_id, list_id) in inflight {
            // Adopting an orphan remaps the local id to the server id — the
            // same invalidation the create push defers for the row the UI is
            // holding. Leave that one marker open until the hold clears; the
            // create is held too, so nothing can duplicate meanwhile.
            if self.config.held_create_id.as_deref() == Some(local_id.as_str()) {
                continue;
            }
            // `find_task_any` on purpose: a row the user deleted (or moved to
            // another list) while its insert was in flight is a TOMBSTONE, and
            // that tombstone is the only thing that still knows what the
            // committed insert looks like. It has to be recovered too, or the
            // orphan survives on the server and the next pull resurrects it.
            let local = self.store.find_task_any(&local_id).await?;
            let Some(local) = local else {
                // Local row really is gone (hard-deleted) — nothing to adopt.
                self.store.clear_inflight_create(&local_id).await?;
                continue;
            };

            let (remote, complete) = self.fetch_all_tasks(&list_id).await?;
            if !complete {
                continue; // incomplete view; retry recovery next run
            }
            // Ids we already track locally — a remote task NOT in this set is
            // a candidate orphan we created on the server but never linked.
            let local_id_set: HashSet<String> = self
                .store
                .list_tasks(&list_id)
                .await?
                .into_iter()
                .map(|t| t.task.id)
                .collect();

            // Orphan: a remote task with our content whose id we never recorded.
            // Match on the base snapshot — the insert payload as sent — so an
            // edit made during the in-flight window still adopts the committed
            // row instead of retrying the create and duplicating it (#122). A
            // row with no base (legacy marker) falls back to current content.
            let base = self.store.base_snapshot(&local_id).await?;
            // A SUBTASK create's committed row may have been stored completed by
            // the insert-under-completed-parent cascade, or completed later when
            // the parent was — so tolerate a completed orphan for any row that
            // has a parent (RFC-009 §G). A top-level create keeps status strict.
            let has_parent = local.task.parent.is_some();
            let orphan = match &base {
                Some(base) => {
                    reconcile::find_orphan_by_base(base, has_parent, &remote, &local_id_set)
                }
                None => reconcile::find_orphan(&local.task, &remote, &local_id_set),
            };

            match orphan {
                Some(o) => {
                    info!(local_id = %local_id, remote_id = %o.id, "adopting orphaned create after crash");
                    // Pass the DRAIN-time local_updated (base_local_updated), not
                    // the row's current one: an edit during the window advanced
                    // the row's local_updated, so finish_create's guard misses
                    // and keeps the edit as a pending update against the new
                    // server id (#122). No edit → they match → the row goes
                    // clean, exactly as the non-crash path.
                    let drained = self
                        .store
                        .inflight_base_local_updated(&local_id)
                        .await?
                        .unwrap_or_else(|| local.local_updated.clone());
                    self.store
                        .finish_create(
                            &local_id,
                            &o.id,
                            o.etag.as_deref(),
                            &o.updated,
                            &drained,
                            Some(&o.position),
                        )
                        .await?;
                }
                None if local.sync_state == SyncState::Deleted => {
                    // The insert never landed AND the user has since deleted
                    // the row. There is nothing to delete on the server and
                    // nothing to keep locally: a tombstone carrying a local
                    // UUID could never be pushed (Google 400s an id it never
                    // minted), so drop it outright.
                    self.store.clear_inflight_create(&local_id).await?;
                    self.store.delete_task_hard(&local_id).await?;
                    out.mark_list_changed(&list_id);
                }
                None => {
                    // Insert never reached the server — let normal push retry.
                    self.store.clear_inflight_create(&local_id).await?;
                }
            }
        }
        Ok(())
    }

    /// How far along the push pipeline a referenced task id is. `None` (the
    /// intent names no such id) is no constraint at all.
    async fn ref_state_of(&self, id: Option<&str>) -> Result<Option<RefState>, SyncError> {
        match id {
            None => Ok(None),
            Some(i) => Ok(Some(RefState::of(
                self.store.find_task_any(i).await?.as_ref(),
            ))),
        }
    }

    /// Undo the optimistic half of a move that will never reach the server.
    ///
    /// The UI applies parent/position immediately, so a move the push refuses
    /// or drops leaves the local row claiming a placement the server does not
    /// have — and the row's etag still MATCHES the server's, so the pull would
    /// skip it and freeze that lie in place (P6). Dropping the etag makes the
    /// pull in this same run re-adopt the row from the server, restoring the
    /// real parent and position. Same mechanism the pull's detach uses.
    ///
    /// Only for CLEAN rows: a dirty row's own content push governs its etag,
    /// and clearing it there would turn a guarded `If-Match` patch into an
    /// unconditional one. Its response body carries the true parent anyway.
    async fn revert_local_move(&self, before: Option<&StoredTask>) -> Result<(), SyncError> {
        if let Some(row) = before.filter(|r| r.sync_state == SyncState::Clean) {
            let mut reverted = row.clone();
            reverted.task.etag = None;
            self.store.upsert_task(&reverted).await?;
        }
        Ok(())
    }

    /// Everything [`reconcile::plan_move`] needs to know about the local view
    /// of one pending move: how far along the push pipeline each id it names
    /// is, plus the two facts that decide whether the move would nest a third
    /// level (invariant #1). Google accepts a third level with a 200 (probe 3),
    /// so that check can only happen here.
    async fn move_refs(
        &self,
        mv: &PendingMove,
        before: Option<&StoredTask>,
    ) -> Result<MoveRefs, SyncError> {
        let parent_row = match mv.parent_id.as_deref() {
            None => None,
            Some(p) => self.store.find_task_any(p).await?,
        };
        let task_has_children = match mv.parent_id {
            // Only a demote can deepen the tree; a promote or a plain reorder
            // never does, so skip the list read for those.
            None => false,
            Some(_) => self
                .store
                .list_tasks(&mv.list_id)
                .await?
                .iter()
                .any(|r| r.task.parent.as_deref() == Some(mv.task_id.as_str())),
        };
        Ok(MoveRefs {
            task: RefState::of(before),
            parent: mv
                .parent_id
                .as_ref()
                .map(|_| RefState::of(parent_row.as_ref())),
            previous: self.ref_state_of(mv.previous_id.as_deref()).await?,
            task_has_children,
            parent_is_subtask: parent_row.as_ref().is_some_and(|p| p.task.parent.is_some()),
        })
    }

    /// Adopt a landed move's response. The snapshot taken *before* the call is
    /// what decides how much of it is adopted: a clean row takes the whole body
    /// (a move can complete the task server-side — P6), a dirty one only the
    /// meta, so its pending edit survives.
    async fn apply_move_response(
        &self,
        before: Option<&StoredTask>,
        remote: &Task,
    ) -> Result<(), SyncError> {
        match (reconcile::move_adoption(before), before) {
            (MoveAdoption::Body, Some(t)) => {
                self.store
                    .apply_pushed_task(remote, &t.local_updated)
                    .await?;
            }
            _ => {
                self.store
                    .refresh_task_meta(&remote.id, remote.etag.as_deref(), &remote.updated)
                    .await?;
            }
        }
        Ok(())
    }

    /// Push pending position/parent moves via the Tasks move endpoint.
    async fn push_moves(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        for mv in self.store.pending_moves().await? {
            let before = self.store.find_task_any(&mv.task_id).await?;
            let intent = reconcile::plan_move(self.move_refs(&mv, before.as_ref()).await?);
            match intent {
                MoveIntent::Drop => {
                    debug!(id = %mv.task_id, "move target parent is gone, dropping move");
                    self.store.clear_move(&mv.task_id).await?;
                    continue;
                }
                MoveIntent::Refuse => {
                    debug!(id = %mv.task_id, "move would nest a third level, refusing it");
                    self.store.clear_move(&mv.task_id).await?;
                    self.revert_local_move(before.as_ref()).await?;
                    continue;
                }
                MoveIntent::Wait => {
                    debug!(id = %mv.task_id, "move waits for its ids to be synced");
                    continue;
                }
                MoveIntent::Send { keep_previous } => {
                    if mv.previous_id.is_some() && !keep_previous {
                        debug!(id = %mv.task_id, "move's previous sibling is gone, keeping the reparent only");
                    }
                }
            }
            let mut previous_id = reconcile::move_previous_id(&mv, intent);
            // The degradation ladder (P5): at most two calls — the move as
            // asked, then, if the ambiguous 404 came back, the reparent alone.
            // `previous_id` is `None` on the second pass, so the loop cannot
            // run a third time.
            loop {
                match self
                    .client
                    .move_task(
                        &mv.list_id,
                        &mv.task_id,
                        mv.parent_id.as_deref(),
                        previous_id.as_deref(),
                    )
                    .await
                {
                    Ok(remote) => {
                        // Drop the intent first so the server's parent/position can
                        // land (apply_pushed_task refuses to touch them while a move
                        // is still pending).
                        self.store.clear_move(&mv.task_id).await?;
                        self.apply_move_response(before.as_ref(), &remote).await?;
                        out.pushed += 1;
                        debug!(id = %mv.task_id, "pushed move");
                    }
                    Err(e) => match reconcile::on_move_error(&e, previous_id.is_some()) {
                        // Ambiguous 404 (§E): it means "previous task id not
                        // found" as often as "the subject is gone". Retry
                        // without the ordering half rather than assume — a
                        // dropped intent here silently reverts the reparent
                        // the user already sees applied.
                        MoveFailure::DropPreviousAndRetry => {
                            debug!(id = %mv.task_id, "move 404 with a previous sibling, retrying as a reparent only");
                            previous_id = None;
                            continue;
                        }
                        // Task gone on server — drop the stale move intent.
                        MoveFailure::DropIntent => {
                            self.store.clear_move(&mv.task_id).await?;
                            self.revert_local_move(before.as_ref()).await?;
                            debug!(id = %mv.task_id, "move target gone, dropping move");
                        }
                        MoveFailure::Retry => {
                            warn!(err = %e, "transient error on move, will retry");
                        }
                        MoveFailure::Abort => return Err(e.into()),
                        MoveFailure::RejectAndDrop => {
                            Self::apply_push_failure(
                                PushFailure::Reject,
                                e,
                                out,
                                &mv.task_id,
                                "move",
                            )?;
                            self.store.clear_move(&mv.task_id).await?;
                            self.revert_local_move(before.as_ref()).await?;
                        }
                    },
                }
                break;
            }
        }
        Ok(())
    }

    async fn push_create(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        // A subtask insert is anchored after its last already-synced sibling
        // (see `reconcile::create_previous_anchor`); a top-level create needs
        // no list read at all.
        let previous = match row.task.parent {
            None => None,
            Some(_) => {
                reconcile::create_previous_anchor(row, &self.store.list_tasks(&row.list_id).await?)
            }
        };
        let payload = reconcile::create_payload(row, previous);
        // Durably mark in-flight BEFORE the non-idempotent insert. The drained
        // `local_updated` is the base snapshot's drain marker (#124): a
        // mid-flight re-edit changes the row's local_updated, so recovery can
        // tell it apart and keep the edit as a pending update.
        self.store
            .record_inflight_create(&row.task.id, &row.list_id, &row.local_updated)
            .await?;
        match self.client.insert_task(&row.list_id, payload).await {
            Ok(remote) => {
                // Atomic: remap local→remote id AND mark clean in one txn so a
                // crash can't leave a remapped row still flagged 'create'. The
                // local_updated snapshot keeps a mid-flight re-edit dirty (as
                // an update against the new remote id) instead of wiping it.
                // The server-assigned position is adopted (an etag match makes
                // pull skip the row, so it would never arrive otherwise).
                self.store
                    .finish_create(
                        &row.task.id,
                        &remote.id,
                        remote.etag.as_deref(),
                        &remote.updated,
                        &row.local_updated,
                        Some(&remote.position),
                    )
                    .await?;
                out.pushed += 1;
                out.mark_list_changed(&row.list_id);
                debug!(local_id = %row.task.id, remote_id = %remote.id, "pushed create");
                Ok(())
            }
            Err(e) => match reconcile::on_create_error(&e) {
                CreateFailure::KeepInflight => {
                    // Insert may or may not have reached the server. The
                    // in-flight marker lets the next run adopt an orphan
                    // instead of duplicating.
                    warn!(err = %e, "transient error on create, will retry");
                    Ok(())
                }
                CreateFailure::ClearInflight(f) => {
                    self.store.clear_inflight_create(&row.task.id).await?;
                    Self::apply_push_failure(f, e, out, &row.task.id, "create")
                }
            },
        }
    }

    async fn push_update(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let patch = reconcile::update_patch(row);
        match self
            .client
            .patch_task(&row.list_id, &row.task.id, patch, row.task.etag.as_deref())
            .await
        {
            Ok(remote) => {
                // Adopt the response body, not just the etag: the server can
                // normalize or silently coerce fields (verified live: it
                // ignores re-opening a subtask of a completed parent while
                // returning 200), and the matching etag would otherwise block
                // pull from ever correcting the drift.
                self.store
                    .apply_pushed_task(&remote, &row.local_updated)
                    .await?;
                out.pushed += 1;
                out.mark_list_changed(&row.list_id);
                debug!(id = %row.task.id, "pushed update");
                Ok(())
            }
            Err(e) => match reconcile::on_update_error(&e) {
                UpdateFailure::ResolveConflict => self.resolve_conflict(row, out).await,
                UpdateFailure::DeleteLocal => {
                    debug!(id = %row.task.id, "task gone from server, deleting locally");
                    // Delete-wins (P4): the FK cascade takes this row and its
                    // WHOLE subtree, unpushed subtasks included — a subtask
                    // shares its parent's fate (RFC-009 D3 REJECTED; no
                    // auto-promotion).
                    self.store.delete_task_hard(&row.task.id).await?;
                    out.mark_list_changed(&row.list_id);
                    Ok(())
                }
                UpdateFailure::Failed(f) => {
                    Self::apply_push_failure(f, e, out, &row.task.id, "update")
                }
            },
        }
    }

    /// Resolve a `412` stale-etag conflict without losing the user's edit.
    ///
    /// Fetches the authoritative remote version, then:
    ///  * if remote content already equals the local edit → no real conflict,
    ///    just adopt the remote etag (mark clean);
    ///  * otherwise → preserve BOTH: the remote becomes the canonical task,
    ///    and the local edit is kept as a new "(conflicted copy)" task to be
    ///    pushed on the next run. Nothing is silently discarded.
    async fn resolve_conflict(
        &self,
        local: &StoredTask,
        out: &mut SyncOutcome,
    ) -> Result<(), SyncError> {
        let remote = match self.client.get_task(&local.list_id, &local.task.id).await {
            Ok(t) => t,
            Err(e) => {
                return match reconcile::on_conflict_refetch_error(&e) {
                    // Server deleted it; mirror the push_update behavior — the
                    // FK cascade takes the whole subtree, unpushed subtasks
                    // included (RFC-009 D3 REJECTED; no auto-promotion).
                    RefetchFailure::DeleteLocal => {
                        self.store.delete_task_hard(&local.task.id).await?;
                        Ok(())
                    }
                    RefetchFailure::StayDirty => Ok(()), // stays dirty, retry
                    RefetchFailure::Abort => Err(e.into()),
                };
            }
        };

        // #118: if the server left the TYPED content (title/notes/due) unchanged
        // relative to our base snapshot, it never diverged from us on content —
        // the etag bumped for a bare reorder or a status cascade. If we ALSO hold
        // a pending typed edit the server has not got, our edit wins: keep it,
        // adopt the remote STATUS (a status change we did not make is the
        // remote's — D1) and the fresh etag, and re-push next run. No conflicted
        // copy, no reverted edit. When our typed content already matches the
        // remote, this is skipped and the normal path adopts the row (resolving
        // any status difference remote-wins per D1). A row with no base falls
        // through to whole-row resolution.
        if let Some(base) = self.store.base_snapshot(&local.task.id).await?
            && reconcile::only_local_diverged(&remote, &base)
            && !reconcile::same_typed_content(&local.task, &remote)
        {
            let mut merged = local.clone();
            merged.task.status = remote.status;
            merged.task.completed = remote.completed.clone();
            merged.task.etag = remote.etag.clone();
            merged.task.updated = remote.updated.clone();
            self.store.upsert_task(&merged).await?;
            out.mark_list_changed(&local.list_id);
            return Ok(());
        }

        match reconcile::resolve_conflict(&local.task, &remote) {
            // No real divergence — just normalization/etag drift to absorb.
            ConflictResolution::AdoptRemote => {
                self.store
                    .apply_pushed_task(&remote, &local.local_updated)
                    .await?;
            }
            // Remote becomes canonical, the local edit survives as a copy.
            ConflictResolution::ConflictedCopy => {
                info!(id = %local.task.id, "412 conflict — preserving local edit as conflicted copy");
                out.conflicts += 1;
                self.store
                    .upsert_task(&reconcile::canonical_row(&remote, &local.list_id))
                    .await?;
                let copy =
                    reconcile::conflicted_copy(local, &remote, uuid::Uuid::new_v4().to_string());
                self.store.upsert_task(&copy).await?;
            }
        }
        out.mark_list_changed(&local.list_id);
        Ok(())
    }

    async fn push_delete(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let result = self.client.delete_task(&row.list_id, &row.task.id).await;
        match reconcile::plan_delete(result.as_ref().err()) {
            DeleteAction::HardDeleteLocal => {
                self.store.delete_task_hard(&row.task.id).await?;
                out.deleted += 1;
                out.mark_list_changed(&row.list_id);
                debug!(id = %row.task.id, "pushed delete");
                Ok(())
            }
            DeleteAction::Failed(f) => {
                Self::apply_push_failure(f, result.unwrap_err(), out, &row.task.id, "delete")
            }
        }
    }

    /// A list the server no longer has is about to disappear locally (P4).
    /// Move the rows it holds that the server has NEVER SEEN into a surviving
    /// list first (P2/D2, ratified): a remote event must not destroy the
    /// user's unpushed work.
    ///
    /// Returns `true` when the list may now be dropped, `false` when there is
    /// nowhere to put the rows and the caller must keep the list alive
    /// instead. `survivors` are the lists eligible to take the rows in — the
    /// caller decides which those are, because two lists deleted in the same
    /// pull must not hand the rows to each other.
    async fn rehome_before_dropping(
        &self,
        ghost: &str,
        survivors: &[StoredTaskList],
        out: &mut SyncOutcome,
    ) -> Result<bool, SyncError> {
        match reconcile::rehome_target(survivors, ghost) {
            Some(target) => {
                let moved = self
                    .store
                    .rehome_unpushed_tasks(ghost, &target.list.id)
                    .await?;
                if moved > 0 {
                    info!(from = %ghost, to = %target.list.id, moved, "list deleted remotely; re-homing unpushed rows");
                    out.mark_list_changed(&target.list.id);
                }
                Ok(true)
            }
            None => Ok(!self.store.has_unpushed_tasks(ghost).await?),
        }
    }

    // ─── Pull ────────────────────────────────────────────────────────────────

    /// Pull all lists and their tasks from the server.
    async fn pull_all(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let lists = match self.client.list_tasklists().await {
            Ok(v) => v,
            Err(e) if e.is_transient() => {
                warn!(err = %e, "transient error listing tasklists");
                return Ok(());
            }
            Err(e) => return Err(e.into()),
        };

        for list in &lists {
            if self.upsert_list(list).await? {
                out.lists_changed = true;
            }
        }

        // List ghost detection: a clean local list absent from the server was
        // deleted remotely — remove it (FK cascade drops its tasks).
        let remote_list_ids: HashSet<String> = lists.iter().map(|l| l.id.clone()).collect();
        let ghost_lists: Vec<String> = self
            .store
            .clean_list_ids()
            .await?
            .difference(&remote_list_ids)
            .cloned()
            .collect();
        // Only a list that survives THIS pull can take in re-homed rows —
        // otherwise two lists deleted together would just hand the rows to
        // each other and both cascades would still fire.
        let local_lists = self.store.all_lists().await?;
        let survivors: Vec<StoredTaskList> = local_lists
            .iter()
            .filter(|l| !ghost_lists.contains(&l.list.id))
            .cloned()
            .collect();
        for ghost in &ghost_lists {
            // D2/P2: the rows the server never saw must not die with the list.
            if !self.rehome_before_dropping(ghost, &survivors, out).await? {
                // Nowhere to put them: keep the list instead, as an unpushed
                // list create. It is re-created on the server next push (or
                // adopted by title) and the rows land in it — P2 holds even
                // when the account has no other list left.
                if let Some(mut revived) = local_lists.iter().find(|l| &l.list.id == ghost).cloned()
                {
                    revived.list.etag = None;
                    revived.sync_state = SyncState::Dirty;
                    revived.pending_op = Some("create".into());
                    self.store.upsert_list(&revived).await?;
                }
                info!(id = %ghost, "list deleted remotely but still holds unpushed rows and there is nowhere to re-home them; keeping it as a local create");
                out.lists_changed = true;
                continue;
            }
            debug!(id = %ghost, "removing ghost list");
            self.store.delete_list_hard_if_clean(ghost).await?;
            out.deleted += 1;
            out.lists_changed = true;
        }

        // Compute skip-set after push so remapped IDs are current.
        let dirty_ids = self.store.dirty_ids().await?;

        // In-flight creates: a remote task matching one of these by its BASE
        // snapshot is the (possibly committed) result of an interrupted create.
        // Don't pull it as a new clean row — leave it for recover_inflight_creates
        // to adopt via id remap next run (avoids a duplicate / PK collision).
        // Matching on the base (not the live row) survives an edit made during
        // the window (#122) and the completed-parent cascade (RFC-009 §G).
        let mut inflight_by_list: HashMap<String, Vec<reconcile::InflightBase>> = HashMap::new();
        for (local_id, list_id) in self.store.inflight_creates().await? {
            if let Some(t) = self.store.find_task_any(&local_id).await? {
                let base = self
                    .store
                    .base_snapshot(&local_id)
                    .await?
                    .unwrap_or_else(|| crate::model::BaseSnapshot::of(&t.task));
                inflight_by_list
                    .entry(list_id)
                    .or_default()
                    .push(reconcile::InflightBase {
                        base,
                        parent: t.task.parent.clone(),
                    });
            }
        }
        let empty = Vec::new();

        for list in &lists {
            let inflight = inflight_by_list.get(&list.id).unwrap_or(&empty);
            self.pull_list(list, &dirty_ids, inflight, out).await?;
        }
        Ok(())
    }

    /// Pull a single list's tasks, upsert changes, detect ghost rows.
    async fn pull_list(
        &self,
        list: &TaskList,
        dirty_ids: &HashSet<String>,
        inflight: &[reconcile::InflightBase],
        out: &mut SyncOutcome,
    ) -> Result<(), SyncError> {
        let (remote_tasks, complete) = self.fetch_all_tasks(&list.id).await?;

        let remote_ids: HashSet<String> = remote_tasks.iter().map(|t| t.id.clone()).collect();

        // Skip dirty rows and orphans of in-flight creates, then order parents
        // before children for FK safety.
        let to_upsert = reconcile::pull_batch(remote_tasks, dirty_ids, inflight);

        // Idempotency: skip rows where local etag already matches.
        let local_etags = self.build_etag_map(&list.id).await;
        let known_local: HashSet<String> = self
            .store
            .list_tasks(&list.id)
            .await?
            .into_iter()
            .map(|t| t.task.id)
            .collect();
        let batch_ids: HashSet<String> = to_upsert.iter().map(|t| t.id.clone()).collect();

        let ctx = reconcile::PullRowContext {
            local_etags: &local_etags,
            batch_ids: &batch_ids,
            known_local: &known_local,
        };
        for mut task in to_upsert {
            match reconcile::plan_pull_row(&task, &ctx) {
                PullRowAction::Skip => continue,
                PullRowAction::UpsertDetached => {
                    warn!(id = %task.id, parent = task.parent.as_deref().unwrap_or_default(), "pulled task's parent unknown; detaching until it appears");
                    task.parent = None;
                    task.etag = None;
                }
                PullRowAction::Upsert => {}
            }
            let stored = StoredTask {
                list_id: list.id.clone(),
                local_updated: task.updated.clone(),
                sync_state: SyncState::Clean,
                pending_op: None,
                task,
            };
            // Race-safe: won't clobber a row a live UI edit just dirtied.
            self.store.upsert_remote_task(&stored).await?;
            out.pulled += 1;
            out.mark_list_changed(&list.id);
        }

        // D7: flatten any server-side third level this list holds. Detected
        // over the LOCAL store after upsert (not the fetched batch), so a paged
        // pull that landed a middle row's demotion without re-fetching the
        // grandchild still repairs it; the all-clean guard in `third_level_ids`
        // keeps an un-pushed optimistic demote from triggering a bogus repair.
        if self.config.push_enabled {
            let local = self.store.list_tasks(&list.id).await?;
            let third_level = reconcile::third_level_ids(&local);
            self.repair_third_level(&list.id, &third_level, out).await?;
        }

        // Ghost detection: remove clean local rows absent from server.
        if complete {
            self.remove_ghosts(&list.id, &remote_ids, out).await?;
        }
        Ok(())
    }

    /// Flatten any server-side third level in this list (RFC-009 §F/§G, D7
    /// **ratified**). Google does not cap nesting depth (probe 3), so two
    /// vectors no push-side guard can close — the demote is unseen until the
    /// pull — leave a grandchild `C` under `P > T`: a remote-born subtask that
    /// arrived after our demote already landed (§F residual), and our own
    /// queued subtask create that raced a remote demote of its parent (§G).
    ///
    /// Each grandchild is promoted to top-level in its list AND the corrective
    /// move is pushed, so the server converges too: a local-only promotion
    /// would be overwritten by the very next pull (the server still holds the
    /// nesting) and re-trigger every run — never a fixpoint (P7). The repair is
    /// counted as a conflict: it can only arise from a concurrent change, and
    /// it must be visible, never silent. Promoting `C` discards neither task —
    /// `C` keeps its content, the user's demote of `T` survives.
    ///
    /// Idempotent under racing repairs: moving an already-top-level row to
    /// top-level is a no-op the server accepts (no depth cap), so another
    /// device's promotion landing first cannot corrupt anything — and once a
    /// grandchild is promoted it is no longer detected, so a quiescent re-run
    /// is a no-op (P7). Gated on push: a read-only sync makes no server writes,
    /// so it leaves the rare cross-device third level until push is enabled.
    async fn repair_third_level(
        &self,
        list_id: &str,
        third_level: &[String],
        out: &mut SyncOutcome,
    ) -> Result<(), SyncError> {
        for id in third_level {
            let Some(before) = self.store.find_task_any(id).await? else {
                continue; // vanished between detection and repair
            };
            if before.task.etag.is_some() {
                // A synced grandchild really sits on the server under a subtask
                // (§F residual, or a §G create that already landed). Push the
                // corrective move so the server converges too — a local-only
                // promotion would be overwritten by the next pull and re-fire
                // every run (P7).
                match self.client.move_task(list_id, id, None, None).await {
                    Ok(remote) => {
                        self.apply_move_response(Some(&before), &remote).await?;
                        // A clean row adopts the move body (parent → None). A
                        // row carrying a pending edit only meta-adopts, so make
                        // it top-level locally too, keeping its edit — otherwise
                        // the local third level would linger until the edit
                        // pushed.
                        self.promote_local_if_nested(id).await?;
                        out.conflicts += 1;
                        out.mark_list_changed(list_id);
                        debug!(id = %id, "D7: promoted a synced third level to top-level");
                    }
                    Err(e) => {
                        // The corrective move did not land. Either way the LOCAL
                        // third level must NOT linger — invariant #1 is absolute,
                        // even mid-flight (the soak checks it right after a
                        // partial pull). Promote locally now and DROP the etag so
                        // the next pull re-examines the row instead of
                        // etag-skipping it:
                        //   * transient (rate-limited / 5xx) — the server still
                        //     nests the row, so the re-pull re-nests it, D7
                        //     re-detects and retries the move until the server
                        //     converges too (P7); and
                        //   * permanent (the grandchild is gone on the server —
                        //     its parent's delete cascaded it) — the row is absent
                        //     from the next complete pull, so ghost removal drops
                        //     the stale local row.
                        // Counting it keeps the resolution visible, never silent.
                        self.promote_and_detach(id).await?;
                        out.conflicts += 1;
                        out.mark_list_changed(list_id);
                        if e.is_transient() {
                            warn!(id = %id, err = %e, "D7: transient error moving third level; promoted locally, will re-push");
                        } else {
                            warn!(id = %id, err = %e, "D7: server rejected the third-level move; promoted locally, next pull reconciles the stale row");
                        }
                    }
                }
            } else {
                // An un-pushed subtask create whose parent was demoted out from
                // under it (§G, before the create pushes). It has no server id
                // to move — promote it locally so it pushes as a TOP-LEVEL
                // create next, keeping the local tree at one level immediately.
                self.promote_local_if_nested(id).await?;
                out.conflicts += 1;
                out.mark_list_changed(list_id);
                debug!(id = %id, "D7: promoted a queued third-level create to top-level");
            }
        }
        Ok(())
    }

    /// Set a still-nested local row to top-level, preserving everything else
    /// (its pending edit or create intent, etag, content). Used by the D7
    /// repair so a grandchild whose server move only meta-adopted, or a
    /// still-queued create, does not leave a third level in the local view.
    async fn promote_local_if_nested(&self, id: &str) -> Result<(), SyncError> {
        if let Some(mut row) = self.store.find_task_any(id).await?
            && row.task.parent.is_some()
        {
            row.task.parent = None;
            self.store.upsert_task(&row).await?;
        }
        Ok(())
    }

    /// Promote a nested local row to top-level, dropping its etag only for a
    /// CLEAN row. Used by the D7 repair when the corrective server move did NOT
    /// land: the local third level must go flat immediately (invariant #1). For
    /// a clean row, clearing the etag guarantees the next pull re-examines it
    /// rather than etag-skipping it — so a transient failure re-nests +
    /// re-detects until the server converges (P7), and a permanent one (the
    /// grandchild is gone on the server) is ghost-removed on the next complete
    /// pull. Same shape as the pull's unknown-parent detach (a cleared etag
    /// never freezes a lie, P6).
    ///
    /// A DIRTY grandchild keeps its etag (same guard as [`revert_local_move`]):
    /// its own content push governs the etag, and clearing it would turn that
    /// retry's guarded `If-Match` patch into an unconditional one — silently
    /// clobbering a concurrent remote edit. Its own push re-examines the row and
    /// adopts the response body anyway, so it needs no etag drop here.
    async fn promote_and_detach(&self, id: &str) -> Result<(), SyncError> {
        if let Some(mut row) = self.store.find_task_any(id).await?
            && row.task.parent.is_some()
        {
            row.task.parent = None;
            if row.sync_state == SyncState::Clean {
                row.task.etag = None;
            }
            self.store.upsert_task(&row).await?;
        }
        Ok(())
    }

    /// Fetch all pages of tasks for a list. Returns `(tasks, complete)`.
    /// `complete` is false if a transient error interrupted pagination.
    async fn fetch_all_tasks(
        &self,
        list_id: &str,
    ) -> Result<(Vec<crate::model::Task>, bool), SyncError> {
        let mut all = Vec::new();
        let mut page_token: Option<String> = None;
        loop {
            let page = match self.client.list_tasks(list_id, page_token.as_deref()).await {
                Ok(p) => p,
                Err(e) if e.is_transient() => {
                    warn!(list_id, err = %e, "transient error fetching tasks, skipping rest");
                    return Ok((all, false));
                }
                Err(e) => return Err(e.into()),
            };
            all.extend(page.items);
            match page.next_page_token {
                Some(token) => page_token = Some(token),
                None => break,
            }
        }
        Ok((all, true))
    }

    /// Build a map of task_id → etag for idempotency checks.
    async fn build_etag_map(&self, list_id: &str) -> HashMap<String, Option<String>> {
        self.store
            .list_tasks(list_id)
            .await
            .unwrap_or_default()
            .into_iter()
            // Only treat a row as a skip candidate once its webViewLink is
            // stored. Rows saved before that column existed (web_view_link
            // NULL) are therefore re-pulled once, backfilling the link without
            // needing a full fresh sync.
            .filter(|t| t.task.web_view_link.is_some())
            .map(|t| (t.task.id, t.task.etag))
            .collect()
    }

    /// Remove local clean rows that no longer exist on the server.
    async fn remove_ghosts(
        &self,
        list_id: &str,
        remote_ids: &HashSet<String>,
        out: &mut SyncOutcome,
    ) -> Result<(), SyncError> {
        let local_clean = self.store.clean_task_ids_for_list(list_id).await?;
        for ghost_id in local_clean.difference(remote_ids) {
            debug!(id = %ghost_id, list_id, "removing ghost row");
            // Clean-guarded: a live edit that re-dirtied the row cancels the
            // ghost delete (the edit will push as a create/update next run).
            // The FK cascade takes the whole subtree, unpushed subtasks
            // included — a subtask shares its parent's fate (RFC-009 D3
            // REJECTED; no auto-promotion).
            if self.store.remove_ghost_task(ghost_id).await? {
                out.deleted += 1;
                out.mark_list_changed(list_id);
            }
        }
        Ok(())
    }

    /// Reconcile one remote list into the local store.
    async fn upsert_list(&self, list: &TaskList) -> Result<bool, SyncError> {
        let locals = self.store.all_lists().await?;
        match reconcile::plan_list_pull(list, &locals) {
            ListPullAction::KeepLocal => Ok(false),
            ListPullAction::AdoptLocalCreate { local_id } => {
                self.store
                    .remap_list_id(&local_id, &list.id, list.etag.as_deref(), &list.updated)
                    .await?;
                Ok(true)
            }
            ListPullAction::Upsert { changed } => {
                let stored = StoredTaskList {
                    list: list.clone(),
                    sync_state: SyncState::Clean,
                    local_updated: list.updated.clone(),
                    pending_op: None,
                    local_only: false,
                };
                // Race-safe: won't clobber a list a live rename just dirtied.
                self.store.upsert_remote_list(&stored).await?;
                Ok(changed)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::InMemoryClient;
    use crate::model::{TaskPatch, TaskStatus};
    use crate::store::open_memory;

    async fn engine() -> (Arc<InMemoryClient>, SyncEngine) {
        let client = Arc::new(InMemoryClient::new());
        let pool = open_memory().await.unwrap();
        let store = Store::new(pool);
        let eng = SyncEngine::new(client.clone(), store);
        (client, eng)
    }

    async fn engine_with_push() -> (Arc<InMemoryClient>, SyncEngine) {
        let client = Arc::new(InMemoryClient::new());
        let pool = open_memory().await.unwrap();
        let store = Store::new(pool);
        let eng = SyncEngine::with_push(client.clone(), store, true);
        (client, eng)
    }

    fn dirty_task(id: &str, list_id: &str, op: &str) -> StoredTask {
        StoredTask {
            task: crate::model::Task {
                id: id.into(),
                parent: None,
                position: "1".into(),
                title: format!("task {id}"),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-06-01T00:00:00Z".into(),
                web_view_link: None,
            },
            list_id: list_id.into(),
            sync_state: if op == "delete" {
                SyncState::Deleted
            } else {
                SyncState::Dirty
            },
            local_updated: "2026-06-01T00:00:00Z".into(),
            pending_op: Some(op.into()),
        }
    }

    // ─── Push tests ──────────────────────────────────────────────────────────

    #[tokio::test]
    async fn push_disabled_does_not_push() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();
        eng.store
            .upsert_task(&dirty_task("local-1", "L1", "create"))
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0);
        assert_eq!(
            client.call_count(crate::api::in_memory::Method::InsertTask),
            0
        );
    }

    #[tokio::test]
    async fn push_create_remaps_id() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();
        eng.store
            .upsert_task(&dirty_task("local-1", "L1", "create"))
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 1);
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert!(tasks.iter().any(|t| t.task.id.starts_with("remote-")));
        assert!(!tasks.iter().any(|t| t.task.id == "local-1"));
    }

    #[tokio::test]
    async fn crash_during_create_adopts_orphan_no_duplicate() {
        // Simulate: insert reached the server (orphan exists) but the app
        // crashed before finish_create — leaving a dirty 'create' + an
        // in-flight marker. Recovery must adopt the orphan, not re-insert.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        // Local dirty create.
        let mut local = dirty_task("local-1", "L1", "create");
        local.task.title = "buy milk".into();
        eng.store.upsert_task(&local).await.unwrap();
        // Server already has the task from the interrupted attempt.
        client.seed_task("L1", "remote-orphan", "buy milk", "1");
        // In-flight marker persisted before the (crashed) finish.
        eng.store
            .record_inflight_create("local-1", "L1", "2026-06-01T00:00:00Z")
            .await
            .unwrap();

        let _out = eng.run().await.unwrap();

        // No re-insert: InsertTask not called this run.
        assert_eq!(
            client.call_count(crate::api::in_memory::Method::InsertTask),
            0
        );
        // Exactly one task remains, adopted to the orphan's id.
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        let milk: Vec<_> = tasks
            .iter()
            .filter(|t| t.task.title == "buy milk")
            .collect();
        assert_eq!(milk.len(), 1, "no duplicate");
        assert_eq!(milk[0].task.id, "remote-orphan");
        assert_eq!(milk[0].sync_state, SyncState::Clean);
        // Marker cleared.
        assert!(eng.store.inflight_creates().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn crash_before_insert_reached_server_reinserts() {
        // In-flight marker exists but the server never got the task (insert
        // didn't land). Recovery clears the marker; normal push inserts.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let mut local = dirty_task("local-1", "L1", "create");
        local.task.title = "orphan-free".into();
        eng.store.upsert_task(&local).await.unwrap();
        eng.store
            .record_inflight_create("local-1", "L1", "2026-06-01T00:00:00Z")
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 1, "normal insert happened");
        assert_eq!(
            client.call_count(crate::api::in_memory::Method::InsertTask),
            1
        );
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert!(tasks[0].task.id.starts_with("remote-"));
        assert!(eng.store.inflight_creates().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn clean_create_clears_inflight_marker() {
        // The happy path: a normal create leaves no in-flight marker behind.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();
        eng.store
            .upsert_task(&dirty_task("local-1", "L1", "create"))
            .await
            .unwrap();
        eng.run().await.unwrap();
        assert!(eng.store.inflight_creates().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn create_commit_then_response_timeout_does_not_duplicate() {
        // The exact at-least-once hazard: server commits the insert but the
        // response times out. The create must NOT be re-attempted in the same
        // run (which would duplicate), and the next run adopts the orphan.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let mut t = dirty_task("local-1", "L1", "create");
        t.task.title = "buy milk".into();
        eng.store.upsert_task(&t).await.unwrap();

        // Run 1: insert commits server-side, then errors (timeout).
        client.commit_then_fail_next_insert();
        eng.run().await.unwrap();
        // Exactly one insert attempted this run (no pass-2 re-insert).
        assert_eq!(client.call_count(Method::InsertTask), 1);
        // Server has exactly one "buy milk".
        assert_eq!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .iter()
                .filter(|t| t.title == "buy milk")
                .count(),
            1
        );

        // Run 2: recovery adopts the orphan instead of inserting again.
        eng.run().await.unwrap();
        assert_eq!(client.call_count(Method::InsertTask), 1, "no second insert");
        let milk: Vec<_> = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .filter(|t| t.task.title == "buy milk")
            .collect();
        assert_eq!(milk.len(), 1, "no duplicate after recovery");
        assert!(milk[0].task.id.starts_with("remote-"));
        assert!(eng.store.inflight_creates().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn inflight_create_waits_when_recovery_view_is_incomplete() {
        // Found by the #104 property tests. The insert committed but the
        // response was lost, so an in-flight marker is open. On the NEXT run
        // the recovery fetch fails transiently — the orphan can't be seen, so
        // it can't be adopted yet. Pushing the create anyway inserts the same
        // task a second time. An unresolved marker must hold its create back
        // until a complete remote view lets recovery decide.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let mut t = dirty_task("local-1", "L1", "create");
        t.task.title = "buy milk".into();
        eng.store.upsert_task(&t).await.unwrap();

        // Run 1: server commits, response lost → marker stays open.
        client.commit_then_fail_next_insert();
        eng.run().await.unwrap();
        assert_eq!(client.call_count(Method::InsertTask), 1);
        assert_eq!(eng.store.inflight_creates().await.unwrap().len(), 1);

        // Run 2: recovery's task fetch dies transiently before it can spot the
        // orphan. The create must wait, not re-insert.
        client.fail_next(Method::ListTasks, || ApiError::Server { status: 503 });
        eng.run().await.unwrap();
        assert_eq!(
            client.call_count(Method::InsertTask),
            1,
            "create re-pushed while its in-flight marker was still unresolved"
        );
        assert_eq!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .iter()
                .filter(|t| t.title == "buy milk")
                .count(),
            1,
            "duplicate on the server"
        );

        // Run 3: a complete view lets recovery adopt the orphan — one task.
        eng.run().await.unwrap();
        assert_eq!(client.call_count(Method::InsertTask), 1);
        let milk: Vec<_> = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .filter(|t| t.task.title == "buy milk")
            .collect();
        assert_eq!(milk.len(), 1, "no duplicate after recovery");
        assert!(milk[0].task.id.starts_with("remote-"));
        assert!(eng.store.inflight_creates().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn move_response_body_is_adopted_so_a_server_cascade_cannot_stick() {
        // Found by the #104 property tests. In one batch the user drags a
        // subtask out to the top level AND completes its old parent. Updates
        // push before moves, so Google applies the completion cascade while the
        // task is still a child — it comes back completed. The move endpoint
        // returns that truth together with a fresh etag; keeping only the etag
        // freezes the drift forever, because every later pull etag-skips the
        // row. Local would show it open while Google has it done.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C", "child", "2", Some("P"));
        eng.run().await.unwrap();

        // Drag C out to the top level (local row updated + move intent).
        let mut c = eng.store.find_task_any("C").await.unwrap().unwrap();
        c.task.parent = None;
        eng.store.upsert_task(&c).await.unwrap();
        eng.store.record_move("C", "L1", None, None).await.unwrap();
        // ...and complete P, which pushes as an update before the move.
        let mut p = eng.store.find_task_any("P").await.unwrap().unwrap();
        p.task.status = TaskStatus::Completed;
        p.task.completed = Some("2026-06-02T00:00:00Z".into());
        p.sync_state = SyncState::Dirty;
        p.pending_op = Some("update".into());
        p.local_updated = "2026-06-02T00:00:00Z".into();
        eng.store.upsert_task(&p).await.unwrap();

        eng.run().await.unwrap();

        let server_c = client.get_task("L1", "C").await.unwrap();
        assert_eq!(
            server_c.status,
            TaskStatus::Completed,
            "precondition: the server cascade completed the child"
        );
        let local_c = eng.store.find_task_any("C").await.unwrap().unwrap();
        assert_eq!(
            local_c.task.status,
            TaskStatus::Completed,
            "local kept the stale status the move response corrected"
        );
        assert_eq!(local_c.task.parent, None, "the move still applied");

        // And it stays converged: a further sync changes nothing.
        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 0);
        assert_eq!(
            eng.store
                .find_task_any("C")
                .await
                .unwrap()
                .unwrap()
                .task
                .status,
            TaskStatus::Completed
        );
    }

    #[tokio::test]
    async fn move_whose_anchor_was_deleted_does_not_retry_forever() {
        // Found while writing the #104 property tests. The user reorders A to
        // sit after B — a pure reorder, no reparent — then deletes B before the
        // move pushes. B's row is gone, so the "is it synced yet?" guard says
        // no, forever: the intent (and the pending-changes count the UI shows)
        // would never clear, and every future sync would re-walk it. The
        // ordering is unexpressible without its anchor, so it is dropped and
        // the move pushes without it; position self-heals on the next pull.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "A", "a", "1");
        client.seed_task("L1", "B", "b", "2");
        eng.run().await.unwrap();

        eng.store
            .record_move("A", "L1", None, Some("B"))
            .await
            .unwrap();
        let mut b = eng.store.find_task_any("B").await.unwrap().unwrap();
        b.sync_state = SyncState::Deleted;
        b.pending_op = Some("delete".into());
        eng.store.upsert_task(&b).await.unwrap();

        eng.run().await.unwrap();
        assert!(
            eng.store.pending_moves().await.unwrap().is_empty(),
            "stale move intent survived its anchor"
        );
        assert_eq!(
            eng.store.pending_push_count().await.unwrap(),
            0,
            "pending-changes count never drains"
        );
        // A itself is untouched and still synced.
        let a = eng.store.find_task_any("A").await.unwrap().unwrap();
        assert_eq!(a.sync_state, SyncState::Clean);
    }

    #[tokio::test]
    async fn move_whose_previous_vanished_still_pushes_the_reparent() {
        // Found by the #104 property soak (3000 cases), shrunk from
        // [.., CreateSub, Sync, CreateTop, MoveAfter(..), Delete(..)].
        //
        // The user drags subtask C OUT of parent P to the top level, dropping
        // it after sibling B — one gesture carrying TWO intents: reparent
        // (P → top level) and ordering (after B). The row applies both
        // optimistically. Then B is deleted before the move pushes.
        //
        // "Place after B" is now unexpressible (Google answers 400 for an
        // unknown previous, verified live), but the REPARENT still is. Dropping
        // the whole intent strands it: local shows C at the top level, Google
        // still has it under P, and because the row is Clean with a matching
        // etag no later pull ever corrects the drift. Keep the parent, drop
        // only the ordering.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C", "child", "2", Some("P"));
        client.seed_task("L1", "B", "sibling", "3");
        eng.run().await.unwrap();

        // Drag C out to the top level, after B.
        let mut c = eng.store.find_task_any("C").await.unwrap().unwrap();
        c.task.parent = None;
        eng.store.upsert_task(&c).await.unwrap();
        eng.store
            .record_move("C", "L1", None, Some("B"))
            .await
            .unwrap();
        // ...then delete the sibling it was dropped after.
        let mut b = eng.store.find_task_any("B").await.unwrap().unwrap();
        b.sync_state = SyncState::Deleted;
        b.pending_op = Some("delete".into());
        eng.store.upsert_task(&b).await.unwrap();

        eng.run().await.unwrap();

        assert_eq!(
            client.get_task("L1", "C").await.unwrap().parent,
            None,
            "the reparent was silently dropped — Google still has C under P \
             while the local row shows it at the top level"
        );
        assert_eq!(
            eng.store
                .find_task_any("C")
                .await
                .unwrap()
                .unwrap()
                .task
                .parent,
            None,
            "local lost the reparent"
        );
        assert!(
            eng.store.pending_moves().await.unwrap().is_empty(),
            "stale move intent survived its anchor"
        );
        assert_eq!(eng.store.pending_push_count().await.unwrap(), 0);

        // And it stays converged: a further sync changes nothing.
        eng.run().await.unwrap();
        assert_eq!(client.get_task("L1", "C").await.unwrap().parent, None);
        assert_eq!(
            eng.store
                .find_task_any("C")
                .await
                .unwrap()
                .unwrap()
                .task
                .parent,
            None
        );
    }

    #[tokio::test]
    async fn move_whose_target_parent_vanished_is_dropped() {
        // The other half of the anchor rule. Here the TARGET PARENT is what
        // went away: the user drops C under P, then deletes P. The delete
        // cascades to the whole subtree on both sides (verified live), so C
        // goes with it — there is no reparent left to preserve and nothing to
        // express. Drop the intent rather than 400 against a dead parent.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task("L1", "C", "c", "2");
        eng.run().await.unwrap();

        let mut c = eng.store.find_task_any("C").await.unwrap().unwrap();
        c.task.parent = Some("P".into());
        eng.store.upsert_task(&c).await.unwrap();
        eng.store
            .record_move("C", "L1", Some("P"), None)
            .await
            .unwrap();
        let mut p = eng.store.find_task_any("P").await.unwrap().unwrap();
        p.sync_state = SyncState::Deleted;
        p.pending_op = Some("delete".into());
        eng.store.upsert_task(&p).await.unwrap();

        eng.run().await.unwrap();
        assert!(
            eng.store.pending_moves().await.unwrap().is_empty(),
            "move intent survived its dead target parent"
        );
        assert_eq!(eng.store.pending_push_count().await.unwrap(), 0);
    }

    #[tokio::test]
    async fn inflight_recovery_leaves_the_held_create_id_alone() {
        // Found by the #104 property tests. The row the UI is holding had its
        // create crash mid-flight, so an orphan is sitting on the server.
        // Adopting it remaps the local id to the server id — precisely the
        // invalidation `held_create_id` exists to prevent. Recovery must wait
        // for the hold to clear, exactly like the create push does.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let mut t = dirty_task("local-1", "L1", "create");
        t.task.title = "buy milk".into();
        eng.store.upsert_task(&t).await.unwrap();
        client.commit_then_fail_next_insert();
        eng.run().await.unwrap();
        assert_eq!(eng.store.inflight_creates().await.unwrap().len(), 1);

        // The user opens the panel on that row, then a sync runs.
        let held = SyncEngine::with_push(client.clone(), eng.store.clone(), true)
            .hold_create_id(Some("local-1".into()));
        held.run().await.unwrap();
        assert!(
            eng.store
                .list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .any(|t| t.task.id == "local-1"),
            "the id the panel holds was remapped mid-edit"
        );
        assert_eq!(client.call_count(Method::InsertTask), 1, "no re-insert");
        assert_eq!(
            eng.store.inflight_creates().await.unwrap().len(),
            1,
            "the marker stays open until the hold clears"
        );

        // Panel closed: recovery adopts the orphan, still without duplicating.
        eng.run().await.unwrap();
        assert_eq!(client.call_count(Method::InsertTask), 1);
        let milk: Vec<_> = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .filter(|t| t.task.title == "buy milk")
            .collect();
        assert_eq!(milk.len(), 1);
        assert!(milk[0].task.id.starts_with("remote-"));
        assert!(eng.store.inflight_creates().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn create_push_interleaved_with_reedit_keeps_edit_as_update_no_dup() {
        // The create is in flight — the engine holds its DRAINED snapshot
        // across the insert await — while the user re-edits the same row. The
        // insert lands under a fresh remote id; finish_create must remap the id
        // AND keep the row dirty as an UPDATE (not clean, not a second create),
        // so the newer edit pushes against the remote id. If push_create passed
        // a fresh read instead of the snapshot, finish_create would mark the row
        // clean and the re-edit would be silently lost; if it re-ran as a
        // create, the server would gain a duplicate. Neither may happen.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        // The dirty create as the push drains it (old content, old timestamp).
        let mut snapshot = dirty_task("local-1", "L1", "create");
        snapshot.task.title = "buy milk".into();
        snapshot.local_updated = "2026-06-01T00:00:00Z".into();
        eng.store.upsert_task(&snapshot).await.unwrap();

        // Concurrent re-edit commits to the store: newer content and timestamp,
        // still a dirty create under the local id (its id is not yet remapped).
        let mut reedited = snapshot.clone();
        reedited.task.title = "buy oat milk".into();
        reedited.local_updated = "2026-06-01T00:05:00Z".into();
        eng.store.upsert_task(&reedited).await.unwrap();

        // Push the ORIGINAL snapshot, exactly as the engine holds it across the
        // insert await while the re-edit lands underneath.
        let mut out = SyncOutcome::default();
        eng.push_create(&snapshot, &mut out).await.unwrap();
        assert_eq!(out.pushed, 1);

        // No duplicate: exactly one insert, one task on the server.
        assert_eq!(client.call_count(Method::InsertTask), 1);
        assert_eq!(
            client.list_tasks("L1", None).await.unwrap().items.len(),
            1,
            "one task on the server, not a duplicate"
        );

        // The local row: remapped to the remote id, still dirty but flipped to
        // an UPDATE, carrying the re-edited content — the edit survives.
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        let row = &tasks[0];
        assert!(row.task.id.starts_with("remote-"), "id remapped to remote");
        assert_eq!(
            row.sync_state,
            SyncState::Dirty,
            "the mid-flight edit stays queued"
        );
        assert_eq!(
            row.pending_op.as_deref(),
            Some("update"),
            "flipped create→update; re-running as a create would duplicate"
        );
        assert_eq!(
            row.task.title, "buy oat milk",
            "the re-edited content is preserved, not lost"
        );
        assert!(row.task.etag.is_some(), "adopted the server etag");
        assert!(
            eng.store.inflight_creates().await.unwrap().is_empty(),
            "in-flight marker cleared by the remap"
        );
    }

    #[tokio::test]
    async fn push_create_parent_before_child() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let parent = dirty_task("local-parent", "L1", "create");
        let mut child = dirty_task("local-child", "L1", "create");
        child.task.parent = Some("local-parent".into());

        eng.store.upsert_task(&parent).await.unwrap();
        eng.store.upsert_task(&child).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 2);
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 2);
        assert!(tasks.iter().all(|t| t.task.id.starts_with("remote-")));
    }

    #[tokio::test]
    async fn push_update_clears_dirty() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        let remote = client.seed_task("L1", "T1", "old", "1");
        eng.run().await.unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "new".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = remote.etag;
        eng.store.upsert_task(&local).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 1);
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].sync_state, SyncState::Clean);
        assert_eq!(tasks[0].task.title, "new");
    }

    #[tokio::test]
    async fn push_update_412_real_conflict_preserves_both() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "server-version", "1");
        eng.run().await.unwrap();

        // Another device edits the CONTENT to a third value — a genuine
        // divergence from what we last synced (our base snapshot), which is what
        // forks a conflicted copy (P3). A bare reorder that left the content
        // equal to the base would not (#118, covered separately).
        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    title: Some("their-version".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "local-edit".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = Some("stale".into());
        eng.store.upsert_task(&local).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 1);

        // Both survive: canonical remote version + a conflicted copy of the edit.
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 2, "remote + conflicted copy");
        assert!(
            tasks
                .iter()
                .any(|t| t.task.title == "their-version" && t.sync_state == SyncState::Clean)
        );
        assert!(
            tasks
                .iter()
                .any(|t| t.task.title == "local-edit (conflicted copy)")
        );
        // Nothing lost.
    }

    #[tokio::test]
    async fn push_update_412_identical_edit_no_copy() {
        // If the server already has the same content we tried to write, there's
        // no real conflict — adopt the remote etag, create no copy.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "same-title", "1");
        eng.run().await.unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        // Same content as server, but a stale etag triggers 412.
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = Some("stale".into());
        eng.store.upsert_task(&local).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 0, "identical content is not a conflict");
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1, "no conflicted copy created");
        assert_eq!(tasks[0].sync_state, SyncState::Clean);
    }

    // ─── RFC-009 §B/§C matrix: edit and complete crossings ───────────────────
    //
    // One test per row of `designs/RFC-009-sync-conflict-matrix.md` §B (local
    // content edit × remote) and §C (local complete / un-complete × remote).
    // Each asserts the STATE both sides end in, never that a call happened.

    /// A dirty content edit on an existing row, as the UI writes it: mutate
    /// through `edit`, mark dirty/update, optionally stale the etag so the
    /// push draws a 412.
    async fn stage_edit(
        eng: &SyncEngine,
        id: &str,
        stale: bool,
        edit: impl FnOnce(&mut StoredTask),
    ) {
        let mut row = eng.store.find_task_any(id).await.unwrap().unwrap();
        edit(&mut row);
        row.sync_state = SyncState::Dirty;
        row.pending_op = Some("update".into());
        row.local_updated = "2026-06-02T00:00:00Z".into();
        if stale {
            row.task.etag = Some("stale".into());
        }
        eng.store.upsert_task(&row).await.unwrap();
    }

    fn completed(row: &mut StoredTask) {
        row.task.status = TaskStatus::Completed;
        row.task.completed = Some("2026-06-02T00:00:00Z".into());
    }

    #[tokio::test]
    async fn edit_vs_remote_move_no_false_conflicted_copy() {
        // §B × moved/reordered/reparented. A move DOES bump the task's etag
        // (probe 1, #106), so an unrelated push 412s. What keeps that from
        // manufacturing a duplicate is the content comparison: it covers
        // title/notes/due/status and never position or parent (P3). Here the
        // same rename landed from another device, which then reordered the
        // task — content matches, only the position moved.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "old", "1");
        client.seed_task("L1", "T2", "anchor", "2");
        eng.run().await.unwrap();

        // The other device renames T1 and then drags it after T2.
        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    title: Some("renamed".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        client
            .move_task("L1", "T1", None, Some("T2"))
            .await
            .unwrap();
        let remote = client.get_task("L1", "T1").await.unwrap();

        // Locally the user typed the same rename; our etag predates both.
        stage_edit(&eng, "T1", true, |r| r.task.title = "renamed".into()).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 0, "a remote MOVE is not a content conflict");

        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 2, "no conflicted copy fabricated");
        assert!(
            !tasks
                .iter()
                .any(|t| t.task.title.ends_with("(conflicted copy)"))
        );
        let t1 = tasks.iter().find(|t| t.task.id == "T1").unwrap();
        assert_eq!(t1.sync_state, SyncState::Clean);
        assert_eq!(t1.task.title, "renamed");
        // The position the move produced arrives with the resolution (P6): the
        // etag we adopt must never outrun the content we hold.
        assert_eq!(t1.task.position, remote.position, "remote order adopted");
        assert_eq!(t1.task.etag, remote.etag);
    }

    #[tokio::test]
    async fn edit_vs_remote_delete_discards_edit_and_row_disappears() {
        // §B × deleted (P4: delete wins, no conflicted copy). The row is gone
        // locally and the edit is lost by the end of the run.
        //
        // This runs the REAL Google path: the fake now soft-deletes (#114), so
        // our pending edit's PATCH lands 200-but-ignored (never a 404) while the
        // row stays deleted and absent from `list_tasks`, and ghost detection on
        // the pull is what removes it — exactly what the live service does.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "exists", "1");
        eng.run().await.unwrap();

        client.delete_task_from_state("L1", "T1");
        stage_edit(&eng, "T1", false, |r| r.task.title = "edited".into()).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "a remote delete is not a sync error");
        assert_eq!(out.conflicts, 0, "delete/edit never forks a copy");
        assert!(
            eng.store.list_tasks("L1").await.unwrap().is_empty(),
            "row gone locally, edit discarded"
        );
    }

    #[tokio::test]
    async fn edit_vs_remote_parent_cascade_delete_discards_edit() {
        // §B × parent-deleted: another client deleted the PARENT, whose delete
        // cascades to the subtask we were editing (verified live). Same
        // outcome as a direct delete — the edit dies with the row (P4), and
        // nothing is left stranded behind a dead parent.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C", "child", "2", Some("P"));
        eng.run().await.unwrap();

        // The other client deletes the parent; the server cascades the child.
        client.delete_task("L1", "P").await.unwrap();
        stage_edit(&eng, "C", false, |r| r.task.title = "my edit".into()).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(out.conflicts, 0);
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert!(tasks.is_empty(), "parent and child both gone: {tasks:?}");
    }

    #[tokio::test]
    async fn complete_vs_remote_edit_produces_conflicted_copy() {
        // §C × remote edited the same row: title AND status diverge, so P3
        // applies unchanged — remote is canonical, the local state survives as
        // a copy. This is the guard that D1 stayed narrow.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "buy milk", "1");
        eng.run().await.unwrap();

        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    title: Some("buy oat milk".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        stage_edit(&eng, "T1", true, completed).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 1);

        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 2, "remote canonical + conflicted copy");
        let canonical = tasks.iter().find(|t| t.task.id == "T1").unwrap();
        assert_eq!(canonical.task.title, "buy oat milk");
        assert_eq!(canonical.task.status, TaskStatus::NeedsAction);
        assert_eq!(canonical.sync_state, SyncState::Clean);
        let copy = tasks
            .iter()
            .find(|t| t.task.title == "buy milk (conflicted copy)")
            .expect("local completion preserved as a copy");
        assert_eq!(copy.task.status, TaskStatus::Completed);
    }

    #[tokio::test]
    async fn status_only_divergence_remote_wins_no_copy() {
        // §C, D1 (ratified in RFC-009): title/notes/due all agree and only the
        // checkbox differs — remote wins outright, no conflicted copy. Here
        // another device completed the task while the user toggled it locally
        // and ended up back at open; our push 412s on the stale etag.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "buy milk", "1");
        eng.run().await.unwrap();

        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        let remote = client.get_task("L1", "T1").await.unwrap();
        stage_edit(&eng, "T1", true, |r| {
            r.task.status = TaskStatus::NeedsAction;
            r.task.completed = None;
        })
        .await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 0, "a status-only difference is not a fork");

        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1, "no conflicted copy created");
        assert_eq!(tasks[0].task.title, "buy milk", "no renamed duplicate");
        assert_eq!(tasks[0].task.status, TaskStatus::Completed, "remote wins");
        assert_eq!(tasks[0].sync_state, SyncState::Clean);
        assert_eq!(
            tasks[0].task.etag, remote.etag,
            "etag/content coherent (P6)"
        );

        // And it stays converged — no dirty row to re-push, no drift to freeze.
        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.pushed, 0);
        assert_eq!(out2.conflicts, 0);
    }

    #[tokio::test]
    async fn complete_vs_remote_delete_row_gone() {
        // §C × remote deleted: the completion is lost with the row (P4). Runs
        // the real path — the fake soft-deletes (#114), so the complete's PATCH
        // is 200-but-ignored and ghost detection on the pull removes the row.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "buy milk", "1");
        eng.run().await.unwrap();

        client.delete_task_from_state("L1", "T1");
        stage_edit(&eng, "T1", false, completed).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(out.conflicts, 0);
        assert!(eng.store.list_tasks("L1").await.unwrap().is_empty());
    }

    // ─── RFC-009 §D matrix: local delete × remote ────────────────────────────
    //
    // One test per row of §D. Every row has the same expected outcome — the
    // delete lands and whatever the remote concurrently did to that row is
    // discarded (P4, ratified) — because `delete_task` sends no `If-Match`
    // (probe 7: Google WOULD honor one; we choose not to send it). The tests
    // assert the end state on BOTH sides, never that a call happened, and
    // never a conflicted copy: delete/edit races do not fork.
    //
    // The mirror direction (local edit × remote delete) is §B, tested above by
    // `edit_vs_remote_delete_discards_edit_and_row_disappears`.

    /// A tombstone as `delete_task_inner` writes it: the row stays in the
    /// store, marked deleted with a pending `delete`, until the push confirms.
    async fn tombstone(eng: &SyncEngine, id: &str) {
        let mut row = eng.store.find_task_any(id).await.unwrap().unwrap();
        row.sync_state = SyncState::Deleted;
        row.pending_op = Some("delete".into());
        row.local_updated = "2026-06-02T00:00:00Z".into();
        eng.store.upsert_task(&row).await.unwrap();
    }

    /// Whether the row is gone from the server as the pull sees it — the remote
    /// half of every §D assertion. Google soft-deletes, so a deleted row still
    /// answers 200 on a by-id `get` (flagged `deleted:true`); "gone" as sync
    /// means absent from `list_tasks`, which is exactly what ghost detection
    /// reads.
    async fn remote_gone(client: &InMemoryClient, list: &str, id: &str) -> bool {
        !client
            .list_tasks(list, None)
            .await
            .unwrap()
            .items
            .iter()
            .any(|t| t.id == id)
    }

    #[tokio::test]
    async fn delete_vs_remote_edit_delete_wins() {
        // §D × edited. Another device renamed the task (bumping its etag)
        // after our last pull. The unconditional DELETE lands anyway and the
        // remote edit dies with the row. Not a conflict, not an error.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "doomed", "1");
        eng.run().await.unwrap();

        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    title: Some("renamed elsewhere".into()),
                    notes: Some("and annotated".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        tombstone(&eng, "T1").await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 1);
        assert_eq!(out.errors, 0, "a stale etag cannot block a delete");
        assert_eq!(out.conflicts, 0, "delete/edit never forks a copy");
        assert!(
            eng.store.list_tasks("L1").await.unwrap().is_empty(),
            "local row hard-deleted"
        );
        assert!(
            remote_gone(&client, "L1", "T1").await,
            "the remote edit was discarded with the row"
        );

        // P7: the next run has nothing left to do, and no revival on pull.
        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.deleted, 0);
        assert_eq!(out2.errors, 0);
        assert!(eng.store.list_tasks("L1").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn delete_vs_remote_status_change_delete_wins() {
        // §D × completed / un-completed, both directions of the checkbox in
        // one run. A status change bumps the etag exactly like a content edit
        // — and is discarded exactly the same way. D1 (status-only divergence
        // → remote wins, no copy) is about the 412 CONFLICT path; it must not
        // leak here and resurrect a task the user deleted.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "will be completed remotely", "1");
        client.seed_task("L1", "T2", "will be reopened remotely", "2");
        client
            .patch_task(
                "L1",
                "T2",
                TaskPatch {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        eng.run().await.unwrap();

        // Remote completes one and re-opens the other after our snapshot.
        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        client
            .patch_task(
                "L1",
                "T2",
                TaskPatch {
                    status: Some(TaskStatus::NeedsAction),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        tombstone(&eng, "T1").await;
        tombstone(&eng, "T2").await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 2);
        assert_eq!(out.errors, 0);
        assert_eq!(out.conflicts, 0);
        assert!(eng.store.list_tasks("L1").await.unwrap().is_empty());
        assert!(remote_gone(&client, "L1", "T1").await, "completed row gone");
        assert!(remote_gone(&client, "L1", "T2").await, "reopened row gone");
    }

    #[tokio::test]
    async fn delete_vs_remote_move_and_reparent_delete_wins() {
        // §D × moved / reparented. The DELETE names the task by id, so where
        // the server moved it is irrelevant — including under a new parent,
        // which is the case that could plausibly have "protected" it. The
        // parent it was dragged under survives untouched.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "keeper", "1");
        client.seed_task("L1", "T1", "doomed", "2");
        client.seed_task("L1", "T2", "reordered", "3");
        eng.run().await.unwrap();

        // Another device demotes T1 under P and reorders T2 to the front.
        client.move_task("L1", "T1", Some("P"), None).await.unwrap();
        client.move_task("L1", "T2", None, None).await.unwrap();
        tombstone(&eng, "T1").await;
        tombstone(&eng, "T2").await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 2);
        assert_eq!(out.errors, 0);

        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1, "only the keeper is left: {tasks:?}");
        assert_eq!(tasks[0].task.id, "P");
        assert_eq!(tasks[0].task.title, "keeper", "the parent is untouched");
        assert_eq!(tasks[0].sync_state, SyncState::Clean);
        assert!(
            remote_gone(&client, "L1", "T1").await,
            "reparented row gone"
        );
        assert!(remote_gone(&client, "L1", "T2").await, "reordered row gone");
        assert!(client.get_task("L1", "P").await.is_ok(), "keeper survives");
    }

    #[tokio::test]
    async fn delete_parent_takes_a_remote_born_subtask_with_it() {
        // §D × new remote subtask under the deleted parent. The child was born
        // on another device and we have never seen it, so our local cascade
        // cannot reach it — but Google's DELETE cascade does (verified live,
        // #106). The consequence of P4 + that cascade is that the remote-born
        // child dies too, and never surfaces locally as an orphan.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        eng.run().await.unwrap();

        // Another device adds a subtask we never pulled; the user deletes P.
        client.seed_task_with_parent("L1", "C-remote", "their kid", "2", Some("P"));
        tombstone(&eng, "P").await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 1);
        assert_eq!(out.errors, 0);
        assert!(
            eng.store.list_tasks("L1").await.unwrap().is_empty(),
            "the child never lands locally, not even as an orphan"
        );
        assert!(remote_gone(&client, "L1", "P").await);
        assert!(
            remote_gone(&client, "L1", "C-remote").await,
            "the server cascade took the remote-born child"
        );
    }

    #[tokio::test]
    async fn delete_subtask_vs_remote_edit_leaves_the_parent_intact() {
        // §D last row: "remove subtask" is a delete of the CHILD. Whatever the
        // remote did to that child (here: renamed it) is discarded, and the
        // parent must come out untouched and clean — deleting a subtask must
        // never cascade upward or dirty the parent.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "kid", "2", Some("P"));
        client.seed_task_with_parent("L1", "C2", "sibling", "3", Some("P"));
        eng.run().await.unwrap();
        let parent_etag = eng
            .store
            .find_task_any("P")
            .await
            .unwrap()
            .unwrap()
            .task
            .etag;

        client
            .patch_task(
                "L1",
                "C1",
                TaskPatch {
                    title: Some("renamed elsewhere".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        tombstone(&eng, "C1").await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 1);
        assert_eq!(out.errors, 0);
        assert_eq!(out.conflicts, 0);

        let tasks = eng.store.list_tasks("L1").await.unwrap();
        let ids: Vec<_> = tasks.iter().map(|t| t.task.id.as_str()).collect();
        assert_eq!(ids, vec!["P", "C2"], "only the removed subtask is gone");
        let parent = tasks.iter().find(|t| t.task.id == "P").unwrap();
        assert_eq!(parent.task.title, "parent");
        assert_eq!(parent.sync_state, SyncState::Clean, "parent not dirtied");
        assert_eq!(parent.task.etag, parent_etag, "parent untouched (P6)");
        let sibling = tasks.iter().find(|t| t.task.id == "C2").unwrap();
        assert_eq!(sibling.task.parent.as_deref(), Some("P"), "still a subtask");
        assert!(remote_gone(&client, "L1", "C1").await);
        assert!(
            client.get_task("L1", "C2").await.is_ok(),
            "sibling survives"
        );
    }

    #[tokio::test]
    async fn delete_parent_with_an_unpushed_child_converges() {
        // §D non-happy path: the user adds a subtask and deletes its parent
        // before either reaches the server. Creates push before deletes, so
        // the child is inserted and then removed by the parent's cascade —
        // the point is only that both sides converge, with nothing left dirty
        // and no child stranded under a dead parent id (which would draw a
        // permanent 400 on every later run).
        //
        // P2 is not in play: it protects unpushed rows from REMOTE events, not
        // from the user's own delete, which cascades by design (invariant #3).
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        eng.run().await.unwrap();

        let mut child = dirty_task("local-kid", "L1", "create");
        child.task.parent = Some("P".into());
        eng.store.upsert_task(&child).await.unwrap();
        tombstone(&eng, "P").await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert!(
            eng.store.list_tasks("L1").await.unwrap().is_empty(),
            "the whole subtree is gone locally"
        );
        assert!(remote_gone(&client, "L1", "P").await);
        assert!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .is_empty(),
            "no clone of the child left behind on the server"
        );

        // Nothing left pending, and the next run is a clean no-op.
        assert!(eng.store.drain_dirty().await.unwrap().is_empty());
        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.errors, 0);
        assert_eq!(out2.pushed, 0);
        assert!(eng.store.list_tasks("L1").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn conflicted_copy_pushes_then_converges() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "server", "1");
        eng.run().await.unwrap();

        // A genuine remote content edit (not a bare reorder) so the push forks
        // a conflicted copy — the base snapshot no longer matches the remote.
        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    title: Some("their-edit".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "conflict".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = Some("stale".into());
        eng.store.upsert_task(&local).await.unwrap();

        eng.run().await.unwrap(); // resolves: canonical + conflicted copy (dirty create)
        let out2 = eng.run().await.unwrap(); // pushes the conflicted copy
        assert!(out2.pushed >= 1);
        let out3 = eng.run().await.unwrap(); // now fully converged
        assert_eq!(out3.conflicts, 0);
        assert_eq!(out3.pushed, 0);

        // The conflicted copy is now a real remote task.
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert!(tasks.iter().all(|t| t.sync_state == SyncState::Clean));
        assert!(
            tasks
                .iter()
                .any(|t| t.task.title == "conflict (conflicted copy)")
        );
    }

    #[tokio::test]
    async fn push_update_into_a_remotely_deleted_list_deletes_local() {
        // The one way a task PATCH still 404s now that the fake soft-deletes
        // tasks: the row's whole LIST was deleted out from under it. That is a
        // real, permanent NotFound, and `on_update_error` hard-deletes the local
        // row (delete wins, P4) — the genuine integration exercise of the
        // patch → 404 → DeleteLocal branch. (A soft-deleted *task* answers 200,
        // not 404, and converges through ghost detection instead — see
        // `edit_vs_remote_delete_...`.)
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "doomed", "1");
        eng.run().await.unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "edit".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        eng.store.upsert_task(&local).await.unwrap();

        // The list vanishes server-side: a PATCH into it is a 404.
        client.delete_list_from_state("L1");

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "a remote delete is not a sync error");
        assert_eq!(out.conflicts, 0, "delete/edit never forks a copy");
        // Local row dropped to mirror the server.
        assert!(
            eng.store
                .list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .all(|t| t.task.id != "T1")
        );
    }

    #[tokio::test]
    async fn push_update_412_transient_get_task_stays_dirty_then_resolves() {
        // A 412 sends us to fetch the authoritative remote copy, but that GET
        // fails transiently (5xx / network). We must NOT lose the local edit,
        // NOT fabricate a conflicted copy, and NOT count a conflict — the row
        // stays dirty so the *next* run retries and resolves it.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "server-version", "1");
        eng.run().await.unwrap();

        // Another device diverges the content (not a bare reorder), so once the
        // fetch succeeds this resolves to a genuine conflicted copy.
        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    title: Some("their-version".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "local-edit".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = Some("stale".into()); // patch → 412
        eng.store.upsert_task(&local).await.unwrap();

        // The 412 conflict-fetch GET fails transiently.
        client.fail_next(Method::GetTask, || ApiError::Server { status: 503 });

        let out = eng.run().await.unwrap();
        assert_eq!(
            out.conflicts, 0,
            "a failed fetch is not a resolved conflict"
        );

        // The local edit is intact: exactly one row, still dirty/update, no copy.
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1, "no conflicted copy fabricated");
        assert_eq!(tasks[0].task.title, "local-edit", "local edit preserved");
        assert_eq!(tasks[0].sync_state, SyncState::Dirty, "row stays dirty");
        assert_eq!(tasks[0].pending_op.as_deref(), Some("update"));
        assert!(
            !tasks
                .iter()
                .any(|t| t.task.title.ends_with("(conflicted copy)")),
            "no (conflicted copy) created while the fetch was still failing"
        );

        // Next run: the GET succeeds, so the 412 finally resolves into the
        // canonical remote + a conflicted copy of the preserved edit.
        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.conflicts, 1, "retry resolves the deferred conflict");
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 2, "remote + conflicted copy after retry");
        assert!(
            tasks
                .iter()
                .any(|t| t.task.title == "their-version" && t.sync_state == SyncState::Clean)
        );
        assert!(
            tasks
                .iter()
                .any(|t| t.task.title == "local-edit (conflicted copy)")
        );
    }

    #[tokio::test]
    async fn push_update_412_non_transient_get_task_aborts_preserving_edit() {
        // A 412 whose conflict-fetch GET fails with a NON-transient error
        // (not NotFound, not transient) aborts the run — the caller can't
        // safely decide the conflict without the remote copy. The local edit
        // must survive untouched: no clean, no copy, no lost data.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "server-version", "1");
        eng.run().await.unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "local-edit".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = Some("stale".into()); // patch → 412
        eng.store.upsert_task(&local).await.unwrap();

        // The 412 conflict-fetch GET fails with a hard, non-transient error.
        client.fail_next(Method::GetTask, || ApiError::Other("boom".into()));

        let err = eng.run().await.expect_err("non-transient fetch aborts run");
        assert!(matches!(err, SyncError::Api(ApiError::Other(_))));

        // Nothing was lost or forked: the edit is still dirty and pushable.
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1, "no conflicted copy fabricated");
        assert_eq!(tasks[0].task.title, "local-edit", "local edit preserved");
        assert_eq!(tasks[0].sync_state, SyncState::Dirty, "row stays dirty");
        assert_eq!(tasks[0].pending_op.as_deref(), Some("update"));
        assert!(
            !tasks
                .iter()
                .any(|t| t.task.title.ends_with("(conflicted copy)")),
            "aborted fetch must not fork a conflicted copy"
        );
    }

    #[tokio::test]
    async fn push_update_of_a_soft_deleted_task_converges_via_ghost() {
        // §B×deleted through the REAL Google path: the row was soft-deleted
        // remotely, so our pending edit's PATCH lands 200-but-ignored (never a
        // 404), the response body is adopted, and the pull's ghost detection —
        // the row being absent from list_tasks — is what removes it. No error,
        // no conflicted copy, edit discarded (P4).
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        let remote = client.seed_task("L1", "T1", "exists", "1");
        eng.run().await.unwrap();

        client.delete_task_from_state("L1", "T1");

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "edited".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = remote.etag; // current etag → the PATCH is 200-ignored
        eng.store.upsert_task(&local).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(out.conflicts, 0, "delete/edit never forks a copy");
        assert!(eng.store.list_tasks("L1").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn push_delete_removes_local() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "doomed", "1");
        eng.run().await.unwrap();

        let mut row = eng.store.list_tasks("L1").await.unwrap().remove(0);
        row.sync_state = SyncState::Deleted;
        row.pending_op = Some("delete".into());
        eng.store.upsert_task(&row).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 1);
        assert!(eng.store.list_tasks("L1").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn push_create_transient_leaves_dirty() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();
        eng.store
            .upsert_task(&dirty_task("local-1", "L1", "create"))
            .await
            .unwrap();

        // A single transient. A parentless create must be attempted EXACTLY
        // once per run (no pass-2 re-attempt that could double-insert).
        client.fail_next(crate::api::in_memory::Method::InsertTask, || {
            ApiError::Network("timeout".into())
        });

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0);
        assert_eq!(
            client.call_count(crate::api::in_memory::Method::InsertTask),
            1,
            "parentless create attempted exactly once per run"
        );
        // Still dirty + in-flight marker for next-run recovery.
        assert_eq!(eng.store.drain_dirty().await.unwrap().len(), 1);
        assert_eq!(eng.store.inflight_creates().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn push_delete_transient_leaves_tombstone() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "doomed", "1");
        eng.run().await.unwrap();

        let mut row = eng.store.list_tasks("L1").await.unwrap().remove(0);
        row.sync_state = SyncState::Deleted;
        row.pending_op = Some("delete".into());
        eng.store.upsert_task(&row).await.unwrap();

        client.fail_next(crate::api::in_memory::Method::DeleteTask, || {
            ApiError::Server { status: 503 }
        });
        client.fail_next(crate::api::in_memory::Method::DeleteTask, || {
            ApiError::Server { status: 503 }
        });

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 0);
        assert_eq!(eng.store.drain_dirty().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn push_delete_not_found_hard_deletes_local_without_error() {
        // Server no longer has the row (someone else deleted it, or it never
        // reached the server). A delete that 404s is a SUCCESS, not a failure:
        // the local tombstone is hard-deleted and counted as deleted, and the
        // run reports zero errors — the desired end state was already reached.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "already gone on server", "1");
        eng.run().await.unwrap();

        let mut row = eng.store.list_tasks("L1").await.unwrap().remove(0);
        row.sync_state = SyncState::Deleted;
        row.pending_op = Some("delete".into());
        eng.store.upsert_task(&row).await.unwrap();

        // Row is already gone on the server (deleted by another client), so the
        // delete naturally 404s — and a subsequent pull won't resurrect it.
        client.delete_task_from_state("L1", "T1");

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 1, "404-on-delete counts as a completed delete");
        assert_eq!(out.errors, 0, "a 404 delete is not an error");
        assert!(
            eng.store.list_tasks("L1").await.unwrap().is_empty(),
            "local row is hard-deleted, not left as a dangling tombstone"
        );
    }

    #[tokio::test]
    async fn unauthorized_aborts_the_run_leaving_rows_dirty() {
        // A 401 (missing/expired/revoked access token) fails every call the
        // same way this run. Like AuthExpired it must abort on first sight
        // instead of grinding row-by-row and mis-counting each pending change
        // as a server rejection. Nothing is lost: rows stay dirty and push
        // after the token is refreshed.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let mut first = dirty_task("local-a", "L1", "create");
        first.local_updated = "2026-06-01T00:00:00Z".into();
        eng.store.upsert_task(&first).await.unwrap();
        let mut second = dirty_task("local-b", "L1", "create");
        second.local_updated = "2026-06-01T00:00:01Z".into();
        eng.store.upsert_task(&second).await.unwrap();
        client.fail_next(crate::api::in_memory::Method::InsertTask, || {
            ApiError::Unauthorized
        });

        let err = eng.run().await.unwrap_err();
        assert!(
            matches!(err, SyncError::Api(ApiError::Unauthorized)),
            "got {err:?}"
        );
        assert_eq!(
            client.call_count(crate::api::in_memory::Method::InsertTask),
            1,
            "aborted after the first failing call, not once per row"
        );
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 2);
        assert!(
            tasks.iter().all(|t| t.sync_state == SyncState::Dirty),
            "both rows stay dirty for retry after re-auth"
        );
    }

    #[tokio::test]
    async fn push_to_unknown_list_is_counted_not_fatal() {
        // A row that the server permanently rejects must not abort the run —
        // it stays dirty (and keeps being reported) while everything else
        // continues to sync. The old behavior (fatal) meant one poisoned row
        // silently killed every future push AND pull.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        eng.store
            .upsert_list(&StoredTaskList {
                list: TaskList {
                    id: "ghost-list".into(),
                    title: "Local".into(),
                    etag: None,
                    updated: "2026-01-01T00:00:00Z".into(),
                },
                sync_state: SyncState::Dirty,
                local_updated: "2026-01-01T00:00:00Z".into(),
                pending_op: None,
                local_only: false,
            })
            .await
            .unwrap();
        eng.store
            .upsert_task(&dirty_task("local-1", "ghost-list", "create"))
            .await
            .unwrap();
        // A healthy create elsewhere must still push in the same run.
        eng.store
            .upsert_task(&dirty_task("local-2", "L1", "create"))
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 1, "rejected row is counted");
        assert!(out.pushed >= 1, "healthy row still pushed");
        assert!(
            eng.store
                .drain_dirty()
                .await
                .unwrap()
                .iter()
                .any(|t| t.task.id == "local-1"),
            "rejected row stays dirty for retry/visibility"
        );
        assert!(
            eng.store
                .list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .all(|t| t.sync_state == SyncState::Clean),
            "healthy row is clean"
        );
    }

    #[tokio::test]
    async fn push_multiple_edits_coalesce() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        let remote = client.seed_task("L1", "T1", "original", "1");
        eng.run().await.unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "final-edit".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = remote.etag;
        eng.store.upsert_task(&local).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 1);
        let page = client.list_tasks("L1", None).await.unwrap();
        assert_eq!(page.items[0].title, "final-edit");
    }

    // ─── Real-API semantics (verified live) ─────────────────────────────────

    #[tokio::test]
    async fn bare_due_date_is_normalized_on_push_not_rejected() {
        // The calendar picker used to store a bare "YYYY-MM-DD"; Google 400s
        // that form. The push path must canonicalize so a legacy/imported row
        // heals instead of poisoning sync.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let mut create = dirty_task("local-1", "L1", "create");
        create.task.due = Some("2026-08-02".into());
        eng.store.upsert_task(&create).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "bare date must not draw a 400");
        assert_eq!(out.pushed, 1);
        let page = client.list_tasks("L1", None).await.unwrap();
        assert_eq!(
            page.items[0].due.as_deref(),
            Some("2026-08-02T00:00:00.000Z")
        );
    }

    #[tokio::test]
    async fn bare_due_date_on_update_is_normalized_too() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        let remote = client.seed_task("L1", "T1", "task", "1");
        eng.run().await.unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.due = Some("2026-08-05".into()); // legacy bare form
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = remote.etag;
        eng.store.upsert_task(&local).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(out.pushed, 1);
        let page = client.list_tasks("L1", None).await.unwrap();
        assert_eq!(
            page.items[0].due.as_deref(),
            Some("2026-08-05T00:00:00.000Z")
        );
    }

    #[tokio::test]
    async fn clearing_due_date_pushes_successfully() {
        // Basic case: task has a due date on the server, user clears it.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        let mut remote = client.seed_task("L1", "T1", "dated", "1");
        remote.due = Some("2026-08-01T00:00:00.000Z".into());
        eng.run().await.unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.due = None; // cleared
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        eng.store.upsert_task(&local).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(out.pushed, 1);
        let page = client.list_tasks("L1", None).await.unwrap();
        assert_eq!(page.items[0].due, None, "due cleared on the server");
        assert!(eng.store.list_tasks("L1").await.unwrap()[0].sync_state == SyncState::Clean);
    }

    #[tokio::test]
    async fn conflict_412_with_only_due_format_difference_is_not_a_conflict() {
        // Local stores "…T00:00:00Z", the server echoes "…T00:00:00.000Z".
        // Same date. A raw string comparison manufactured a phantom
        // "(conflicted copy)" out of nothing.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "same", "1");
        eng.run().await.unwrap();

        // Server task gains a due date + fresh etag (etag now stale locally).
        let patched = client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    due: Some("2026-08-01T00:00:00.000Z".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        // Local made the "same" edit, in the short form, against the old etag.
        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.due = Some("2026-08-01T00:00:00Z".into());
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        eng.store.upsert_task(&local).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 0, "identical content must not fork a copy");
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].sync_state, SyncState::Clean);
        assert_eq!(tasks[0].task.etag, patched.etag);
    }

    #[tokio::test]
    async fn crash_adoption_matches_across_due_normalization() {
        // Orphan adoption after a crash compares content; the server-side
        // orphan carries the canonical due form while the local row has the
        // short form. They must still match, or the create re-inserts a dup.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let mut local = dirty_task("local-1", "L1", "create");
        local.task.title = "buy milk".into();
        local.task.due = Some("2026-08-01T00:00:00Z".into());
        eng.store.upsert_task(&local).await.unwrap();
        let mut orphan = client.seed_task("L1", "remote-orphan", "buy milk", "1");
        orphan.due = Some("2026-08-01T00:00:00.000Z".into());
        {
            // Write the normalized due into the fake's state.
            client
                .patch_task(
                    "L1",
                    "remote-orphan",
                    TaskPatch {
                        due: Some("2026-08-01T00:00:00.000Z".into()),
                        ..Default::default()
                    },
                    None,
                )
                .await
                .unwrap();
        }
        eng.store
            .record_inflight_create("local-1", "L1", "2026-06-01T00:00:00Z")
            .await
            .unwrap();

        eng.run().await.unwrap();

        assert_eq!(
            client.call_count(crate::api::in_memory::Method::InsertTask),
            0,
            "adopted, not re-inserted"
        );
        let milk: Vec<_> = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .filter(|t| t.task.title == "buy milk")
            .collect();
        assert_eq!(milk.len(), 1, "no duplicate");
        assert_eq!(milk[0].task.id, "remote-orphan");
    }

    #[tokio::test]
    async fn poisoned_row_does_not_starve_other_pushes_or_pull() {
        // One row the server permanently rejects: everything else must still
        // push, and the pull must still run. (Previously any non-transient
        // rejection aborted the run before pull — one poisoned row froze the
        // entire pipeline forever.)
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        // Drain order is by local_updated: the poisoned row goes first.
        let mut poison = dirty_task("local-poison", "L1", "create");
        poison.local_updated = "2026-06-01T00:00:00Z".into();
        eng.store.upsert_task(&poison).await.unwrap();
        let mut ok = dirty_task("local-ok", "L1", "create");
        ok.local_updated = "2026-06-01T00:00:01Z".into();
        eng.store.upsert_task(&ok).await.unwrap();
        client.seed_task("L1", "R1", "from server", "9");
        // The server permanently rejects the first insert (a 400).
        client.fail_next(crate::api::in_memory::Method::InsertTask, || {
            ApiError::Other("400: Request contains an invalid argument.".into())
        });

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 1, "poisoned row counted");
        assert!(out.pushed >= 1, "healthy row still pushed");
        assert!(out.pulled >= 1, "pull still ran");
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert!(tasks.iter().any(|t| t.task.title == "from server"));
        assert!(
            tasks
                .iter()
                .any(|t| t.task.id == "local-poison" && t.sync_state == SyncState::Dirty),
            "poisoned row stays dirty (visible + retried), not lost"
        );
    }

    #[tokio::test]
    async fn auth_expired_aborts_the_run_instead_of_grinding_through_rows() {
        // A dead refresh token (invalid_grant) fails every call identically.
        // Unlike a poisoned row, this must abort on first sight: grinding on
        // would hammer the token endpoint once per row and mis-count every
        // pending change as a server rejection.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let mut first = dirty_task("local-a", "L1", "create");
        first.local_updated = "2026-06-01T00:00:00Z".into();
        eng.store.upsert_task(&first).await.unwrap();
        let mut second = dirty_task("local-b", "L1", "create");
        second.local_updated = "2026-06-01T00:00:01Z".into();
        eng.store.upsert_task(&second).await.unwrap();
        client.fail_next(crate::api::in_memory::Method::InsertTask, || {
            ApiError::AuthExpired("invalid_grant: Token has been expired or revoked.".into())
        });

        let err = eng.run().await.unwrap_err();
        assert!(
            matches!(err, SyncError::Api(ApiError::AuthExpired(_))),
            "got {err:?}"
        );
        assert_eq!(
            client.call_count(crate::api::in_memory::Method::InsertTask),
            1,
            "aborted after the first failing call"
        );
        // Nothing is lost: both rows stay dirty and push after re-login.
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert!(tasks.iter().all(|t| t.sync_state == SyncState::Dirty));
    }

    #[tokio::test]
    async fn child_create_waits_for_unresolved_parent() {
        // The parent's own create failed transiently this run — the child must
        // NOT be pushed with a still-local parent id (permanent 400 on the
        // real API); it stays dirty and succeeds on the next run.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        eng.store
            .upsert_task(&dirty_task("local-p", "L1", "create"))
            .await
            .unwrap();
        let mut child = dirty_task("local-c", "L1", "create");
        child.task.parent = Some("local-p".into());
        eng.store.upsert_task(&child).await.unwrap();

        client.fail_next(crate::api::in_memory::Method::InsertTask, || {
            ApiError::Server { status: 503 }
        });
        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "no permanent 400 — the child waited");

        // Next run: parent inserts, then the child (remapped parent id).
        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 2);
        assert!(tasks.iter().all(|t| t.sync_state == SyncState::Clean));
        let child = tasks
            .iter()
            .find(|t| t.task.title == "task local-c")
            .unwrap();
        assert!(
            child.task.parent.as_deref().unwrap().starts_with("remote-"),
            "parent id remapped"
        );
    }

    #[tokio::test]
    async fn three_level_creates_resolve_in_one_run() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        eng.store
            .upsert_task(&dirty_task("l-root", "L1", "create"))
            .await
            .unwrap();
        let mut mid = dirty_task("l-mid", "L1", "create");
        mid.task.parent = Some("l-root".into());
        eng.store.upsert_task(&mid).await.unwrap();
        let mut leaf = dirty_task("l-leaf", "L1", "create");
        leaf.task.parent = Some("l-mid".into());
        eng.store.upsert_task(&leaf).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(out.pushed, 3, "whole chain lands in one run");
        assert!(
            eng.store
                .list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .all(|t| t.sync_state == SyncState::Clean)
        );
    }

    #[tokio::test]
    async fn pull_multilevel_nesting_is_fk_safe() {
        // The API allows >1 level of nesting; the pull batch can arrive in any
        // order. Children inserting before their own parent breaks the FK.
        // Seed in the hostile order — grandchild first, root last (the seed_*
        // helpers are fixtures, so a forward reference is fine).
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task_with_parent("L1", "leaf", "leaf", "1", Some("mid"));
        client.seed_task_with_parent("L1", "mid", "mid", "2", Some("root"));
        client.seed_task("L1", "root", "root", "3");

        let out = eng.run().await.unwrap();
        assert_eq!(
            out.pulled, 3,
            "all three levels pulled despite hostile order"
        );
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(
            tasks
                .iter()
                .find(|t| t.task.id == "leaf")
                .unwrap()
                .task
                .parent
                .as_deref(),
            Some("mid")
        );
        assert_eq!(
            tasks
                .iter()
                .find(|t| t.task.id == "mid")
                .unwrap()
                .task
                .parent
                .as_deref(),
            Some("root")
        );
    }

    #[tokio::test]
    async fn move_push_preserves_pending_content_edit() {
        // A pending content edit and a pending position move on the same task:
        // the move completing must not wipe the edit's dirty flag.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "one", "1");
        client.seed_task("L1", "T2", "two", "2");
        eng.run().await.unwrap();

        let mut local = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|t| t.task.id == "T1")
            .unwrap();
        local.task.title = "edited".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        // Simulate the update push being held this run (editing) while the
        // move still goes out.
        eng.store.upsert_task(&local).await.unwrap();
        eng.store
            .record_move("T1", "L1", None, Some("T2"))
            .await
            .unwrap();

        // Force the update push to fail transiently so only the move lands.
        client.fail_next(crate::api::in_memory::Method::PatchTask, || {
            ApiError::Server { status: 503 }
        });
        eng.run().await.unwrap();

        let row = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|t| t.task.title == "edited")
            .unwrap();
        assert_eq!(
            row.sync_state,
            SyncState::Dirty,
            "content edit still queued"
        );
        assert!(
            eng.store.pending_moves().await.unwrap().is_empty(),
            "move cleared"
        );

        // Next run pushes the edit.
        eng.run().await.unwrap();
        let page = client.list_tasks("L1", None).await.unwrap();
        assert!(page.items.iter().any(|t| t.title == "edited"));
    }

    #[tokio::test]
    async fn created_task_adopts_server_assigned_position() {
        // The insert response carries the server-assigned position. Discarding
        // it left the local placeholder ("000…0") in place FOREVER — the
        // adopted etag makes every subsequent pull skip the row.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        let mut create = dirty_task("local-1", "L1", "create");
        create.task.position = "00000000000000000000".into();
        eng.store.upsert_task(&create).await.unwrap();
        eng.run().await.unwrap();

        let local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        let remote = client.list_tasks("L1", None).await.unwrap().items.remove(0);
        assert_eq!(
            local.task.position, remote.position,
            "local mirrors the server's position"
        );
        assert_ne!(local.task.position, "00000000000000000000");
    }

    #[tokio::test]
    async fn server_coercion_in_patch_response_is_adopted() {
        // The server can normalize/coerce what we send (verified live: it even
        // ignores some status changes while returning 200). The response body
        // is the truth; discarding it leaves local/remote permanently diverged
        // because the matching etag blocks pull from ever correcting it.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task", "1");
        eng.run().await.unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        // A due with a time-of-day: the (live-verified) server stores date-only.
        local.task.due = Some("2026-08-01T17:30:00.000Z".into());
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        eng.store.upsert_task(&local).await.unwrap();

        eng.run().await.unwrap();
        let after = eng.store.list_tasks("L1").await.unwrap().remove(0);
        assert_eq!(
            after.task.due.as_deref(),
            Some("2026-08-01T00:00:00.000Z"),
            "local adopts the server's canonical value, not what we sent"
        );
        assert_eq!(after.sync_state, SyncState::Clean);
    }

    #[tokio::test]
    async fn move_for_unsynced_task_waits_for_its_create() {
        // A reorder recorded while the task's create is held (editing) must
        // NOT be pushed with the local UUID — the live API rejects that with a
        // permanent 400, and the old code then dropped the user's move.
        let (client, eng0) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T-prev", "anchor", "1");
        eng0.run().await.unwrap();

        eng0.store
            .upsert_task(&dirty_task("local-1", "L1", "create"))
            .await
            .unwrap();
        eng0.store
            .record_move("local-1", "L1", None, Some("T-prev"))
            .await
            .unwrap();

        // Run 1: this task's create is held (user editing it). The move must
        // wait, not error.
        let eng_hold = SyncEngine::with_push(client.clone(), eng0.store.clone(), true)
            .hold_create_id(Some("local-1".into()));
        let out = eng_hold.run().await.unwrap();
        assert_eq!(
            out.errors, 0,
            "move with a local UUID must not be sent (400)"
        );
        assert_eq!(
            eng0.store.pending_moves().await.unwrap().len(),
            1,
            "intent retained"
        );

        // Run 2: create lands, finish_create remaps the move's ids, move pushes.
        let out = eng0.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert!(
            eng0.store.pending_moves().await.unwrap().is_empty(),
            "move pushed"
        );
        let remote = client.list_tasks("L1", None).await.unwrap();
        let moved = remote
            .items
            .iter()
            .find(|t| t.title == "task local-1")
            .unwrap();
        let anchor = remote.items.iter().find(|t| t.title == "anchor").unwrap();
        assert!(
            moved.position > anchor.position,
            "reorder reached the server: task sorts after its anchor ({} > {})",
            moved.position,
            anchor.position
        );
    }

    #[tokio::test]
    async fn subtask_creates_land_in_creation_order() {
        // Without `previous`, the API inserts each subtask FIRST — a batch
        // lands on Google in reverse creation order.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        eng.run().await.unwrap();

        for (i, id) in ["local-a", "local-b", "local-c"].iter().enumerate() {
            let mut c = dirty_task(id, "L1", "create");
            c.task.parent = Some("P".into());
            c.task.title = format!("sub {i}");
            c.local_updated = format!("2026-06-01T00:00:0{i}Z");
            eng.store.upsert_task(&c).await.unwrap();
            // Push one at a time — like a user adding subtasks across syncs.
            eng.run().await.unwrap();
        }

        let mut remote: Vec<_> = client
            .list_tasks("L1", None)
            .await
            .unwrap()
            .items
            .into_iter()
            .filter(|t| t.parent.as_deref() == Some("P"))
            .collect();
        remote.sort_by(|a, b| a.position.cmp(&b.position));
        let titles: Vec<_> = remote.iter().map(|t| t.title.as_str()).collect();
        assert_eq!(
            titles,
            vec!["sub 0", "sub 1", "sub 2"],
            "creation order preserved on the server"
        );
    }

    #[tokio::test]
    async fn two_same_title_local_list_creates_do_not_collide() {
        // Both used to adopt the SAME remote list → primary-key collision on
        // the second remap → the whole run aborted with a store error.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L-remote", "Work");

        for id in ["local-l1", "local-l2"] {
            eng.store
                .upsert_list(&StoredTaskList {
                    list: TaskList {
                        id: id.into(),
                        title: "Work".into(),
                        etag: None,
                        updated: "2026-01-01T00:00:00Z".into(),
                    },
                    sync_state: SyncState::Dirty,
                    local_updated: "2026-01-01T00:00:00Z".into(),
                    pending_op: Some("create".into()),
                    local_only: false,
                })
                .await
                .unwrap();
        }

        let out = eng.run().await;
        assert!(out.is_ok(), "no PK collision: {out:?}");
        // One adopted the remote list, the other created a second remote list.
        let remote = client.list_tasklists().await.unwrap();
        assert_eq!(remote.iter().filter(|l| l.title == "Work").count(), 2);
    }

    #[tokio::test]
    async fn refused_list_delete_revives_the_list_instead_of_nagging_forever() {
        // Google refuses to delete an account's default list (permanent 400).
        // A tombstone that can never push would surface an error on every run
        // forever; the list is revived instead and its tasks re-pull.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_task("L1", "T1", "still here", "1");
        eng.run().await.unwrap();

        // Tombstone the list locally (as delete_list does for synced lists).
        let mut l = eng.store.all_lists().await.unwrap().remove(0);
        l.sync_state = SyncState::Deleted;
        l.pending_op = Some("delete".into());
        eng.store.upsert_list(&l).await.unwrap();
        // Server permanently refuses.
        client.fail_next(crate::api::in_memory::Method::DeleteTaskList, || {
            ApiError::Other("400: Cannot delete the default task list".into())
        });

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 1, "refusal surfaced once");
        let lists = eng.store.all_lists().await.unwrap();
        assert_eq!(lists.len(), 1, "list revived");
        assert_eq!(lists[0].sync_state, SyncState::Clean);

        // Next run: no tombstone left, no repeat error.
        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "no permanent nag");
        assert!(
            eng.store
                .list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .any(|t| t.task.title == "still here")
        );
    }

    #[tokio::test]
    async fn pull_detaches_task_whose_parent_is_unknown_instead_of_failing() {
        // The reachable FK hazard: a create crashed mid-push (orphan exists on
        // the server, local row still carries the local UUID + an in-flight
        // marker), and a CHILD of that orphan exists remotely. Pull filters
        // the orphan out of the batch (in-flight dedup), so the child
        // references a parent that is in neither the batch nor the store. In
        // READ-ONLY mode crash recovery never runs (it lives in the push
        // phase), so without the guard every pull FK-fails — forever.
        let (client, eng) = engine().await; // push DISABLED
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        // Crashed create: local row under a local UUID + in-flight marker…
        let mut local = dirty_task("local-p", "L1", "create");
        local.task.title = "buy milk".into();
        eng.store.upsert_task(&local).await.unwrap();
        eng.store
            .record_inflight_create("local-p", "L1", "2026-06-01T00:00:00Z")
            .await
            .unwrap();
        // …its committed orphan on the server, plus a child under the orphan.
        client.seed_task("L1", "remote-orphan", "buy milk", "1");
        client.seed_task_with_parent("L1", "C", "child of orphan", "2", Some("remote-orphan"));

        let out = eng.run().await;
        assert!(out.is_ok(), "pull must survive the unknown parent: {out:?}");
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        let child = tasks
            .iter()
            .find(|t| t.task.id == "C")
            .expect("child pulled, not lost");
        assert_eq!(
            child.task.parent, None,
            "detached until the parent id resolves"
        );

        // Once recovery runs (push re-enabled), the orphan is adopted and the
        // next pull re-links the child (its etag was dropped, so it re-pulls).
        let eng_push = SyncEngine::with_push(client.clone(), eng.store.clone(), true);
        eng_push.run().await.unwrap();
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        let child = tasks.iter().find(|t| t.task.id == "C").unwrap();
        assert_eq!(
            child.task.parent.as_deref(),
            Some("remote-orphan"),
            "re-linked"
        );
    }

    // ─── Pull tests ──────────────────────────────────────────────────────────

    #[tokio::test]
    async fn pull_seeds_store() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "first", "1");
        client.seed_task("L1", "T2", "second", "2");

        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 2);
        assert_eq!(eng.store.list_tasks("L1").await.unwrap().len(), 2);
    }

    #[tokio::test]
    async fn pull_backfills_missing_web_view_link_without_etag_change() {
        // A task stored before web_view_link existed (NULL) must be re-pulled
        // and backfilled on the next sync, even though its etag is unchanged.
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task", "1");
        eng.run().await.unwrap();

        // Simulate the pre-migration state: clear the stored link, keep etag.
        let mut row = eng.store.find_task_any("T1").await.unwrap().unwrap();
        assert!(
            row.task.web_view_link.is_some(),
            "first pull stored the link"
        );
        let etag_before = row.task.etag.clone();
        row.task.web_view_link = None;
        eng.store.upsert_task(&row).await.unwrap();

        // A normal sync (no server change) must re-populate the link.
        eng.run().await.unwrap();
        let healed = eng.store.find_task_any("T1").await.unwrap().unwrap();
        assert!(
            healed.task.web_view_link.is_some(),
            "link backfilled on next pull"
        );
        assert_eq!(healed.task.etag, etag_before, "etag unchanged");
    }

    #[tokio::test]
    async fn pull_upserts_lists() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_list("L2", "Work");

        eng.run().await.unwrap();
        let lists = eng.store.all_lists().await.unwrap();
        assert_eq!(lists.len(), 2);
    }

    #[tokio::test]
    async fn pull_multiple_lists() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "T1", "work", "1");
        client.seed_task("L2", "T2", "personal", "1");

        eng.run().await.unwrap();
        assert_eq!(
            eng.store.list_tasks("L1").await.unwrap()[0].task.title,
            "work"
        );
        assert_eq!(
            eng.store.list_tasks("L2").await.unwrap()[0].task.title,
            "personal"
        );
    }

    #[tokio::test]
    async fn pull_parents_before_children() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P1", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "child", "2", Some("P1"));

        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 2);
        let child = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|t| t.task.id == "C1")
            .unwrap();
        assert_eq!(child.task.parent.as_deref(), Some("P1"));
    }

    #[tokio::test]
    async fn pull_skips_dirty_rows() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "remote", "1");
        client.seed_task("L1", "T2", "clean", "2");
        eng.run().await.unwrap();

        // Locally edit T1
        let mut t1 = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|t| t.task.id == "T1")
            .unwrap();
        t1.task.title = "local edit".into();
        t1.sync_state = SyncState::Dirty;
        t1.pending_op = Some("update".into());
        eng.store.upsert_task(&t1).await.unwrap();

        let out = eng.run().await.unwrap();
        // Neither T1 (dirty, skipped) nor T2 (etag unchanged) should count
        assert_eq!(out.pulled, 0);
        // Local edit preserved
        let t1 = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|t| t.task.id == "T1")
            .unwrap();
        assert_eq!(t1.task.title, "local edit");
    }

    #[tokio::test]
    async fn pull_updates_when_remote_etag_differs() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "v1", "1");
        eng.run().await.unwrap();

        // Remote edit (changes etag)
        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    title: Some("v2".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 1);
        assert_eq!(
            eng.store.list_tasks("L1").await.unwrap()[0].task.title,
            "v2"
        );
    }

    #[tokio::test]
    async fn pull_handles_pagination() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        for i in 0..10 {
            client.seed_task(
                "L1",
                &format!("T{i}"),
                &format!("task {i}"),
                &format!("{i:014}"),
            );
        }
        // Force real multi-page fetching: 10 tasks at 3 per page = 4 pages.
        client.set_page_size(3);
        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 10);
        assert!(
            client.call_count(crate::api::in_memory::Method::ListTasks) >= 4,
            "must iterate every page, not just the first"
        );
        assert_eq!(eng.store.list_tasks("L1").await.unwrap().len(), 10);
    }

    #[tokio::test]
    async fn pull_incomplete_pagination_never_ghosts_real_rows() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        for i in 0..6 {
            client.seed_task(
                "L1",
                &format!("T{i}"),
                &format!("task {i}"),
                &format!("{i:014}"),
            );
        }
        // 6 tasks at 2 per page = 3 pages. First full sync stores every row.
        client.set_page_size(2);
        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 6);
        assert_eq!(eng.store.list_tasks("L1").await.unwrap().len(), 6);

        // Second sync: page 0 returns real rows, but page 1 drops mid-scroll.
        // The view is now incomplete, so the tasks that live on the un-fetched
        // pages must NOT be mistaken for server-side deletions (ghosts).
        client.fail_list_tasks_page(1, || ApiError::Server { status: 503 });
        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 0, "incomplete page fetch must not ghost rows");
        assert_eq!(
            eng.store.list_tasks("L1").await.unwrap().len(),
            6,
            "every synced row must survive an interrupted paginated pull"
        );
    }

    // ─── Ghost detection ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn ghost_rows_deleted() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "stays", "1");
        client.seed_task("L1", "T2", "vanishes", "2");
        eng.run().await.unwrap();

        client.delete_task_from_state("L1", "T2");

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 1);
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.id, "T1");
    }

    #[tokio::test]
    async fn ghost_detection_preserves_dirty_rows() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "remote", "1");
        eng.run().await.unwrap();

        // Local-only task (not on server)
        eng.store
            .upsert_task(&dirty_task("local-only", "L1", "create"))
            .await
            .unwrap();

        eng.run().await.unwrap();
        assert!(
            eng.store
                .list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .any(|t| t.task.id == "local-only")
        );
    }

    #[tokio::test]
    async fn ghost_detection_skipped_on_transient() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task1", "1");
        client.seed_task("L1", "T2", "task2", "2");
        eng.run().await.unwrap();

        client.fail_next(crate::api::in_memory::Method::ListTasks, || {
            ApiError::Server { status: 503 }
        });

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 0);
        assert_eq!(eng.store.list_tasks("L1").await.unwrap().len(), 2);
    }

    #[tokio::test]
    async fn ghost_detection_per_list() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "T1", "work", "1");
        client.seed_task("L2", "T2", "personal", "1");
        eng.run().await.unwrap();

        client.delete_task_from_state("L1", "T1");

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 1);
        assert!(eng.store.list_tasks("L1").await.unwrap().is_empty());
        assert_eq!(eng.store.list_tasks("L2").await.unwrap().len(), 1);
    }

    // ─── Idempotency & transient handling ────────────────────────────────────

    #[tokio::test]
    async fn second_sync_is_noop() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task", "1");

        eng.run().await.unwrap();
        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.pulled, 0);
        assert_eq!(out2.pushed, 0);
        assert_eq!(out2.deleted, 0);
    }

    #[tokio::test]
    async fn transient_list_tasklists_error_not_fatal() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.fail_next(crate::api::in_memory::Method::ListTaskLists, || {
            ApiError::Server { status: 503 }
        });

        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 0);
    }

    // ─── Sync log ────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn sync_log_written_on_success() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task", "1");
        eng.run().await.unwrap();

        let row: (i64, i64, i64) = sqlx::query_as(
            "SELECT pulled, pushed, conflicts FROM sync_log ORDER BY id DESC LIMIT 1",
        )
        .fetch_one(eng.store.pool())
        .await
        .unwrap();
        assert_eq!(row.0, 1);
    }

    #[tokio::test]
    async fn sync_log_written_on_error() {
        let (client, eng) = engine().await;
        client.fail_next(crate::api::in_memory::Method::ListTaskLists, || {
            ApiError::Other("fatal".into())
        });
        let _ = eng.run().await;

        let row: (Option<String>,) =
            sqlx::query_as("SELECT error FROM sync_log ORDER BY id DESC LIMIT 1")
                .fetch_one(eng.store.pool())
                .await
                .unwrap();
        assert!(row.0.unwrap().contains("fatal"));
    }

    // ─── Move (reorder / reparent) ───────────────────────────────────────────

    #[tokio::test]
    async fn push_move_calls_move_api_and_clears() {
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "first", "1");
        client.seed_task("L1", "T2", "second", "2");
        eng.run().await.unwrap();

        // Record a move: T1 should follow T2.
        eng.store
            .record_move("T1", "L1", None, Some("T2"))
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert!(out.pushed >= 1);
        assert_eq!(client.call_count(Method::MoveTask), 1);
        // Pending move cleared after successful push.
        assert!(eng.store.pending_moves().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn push_move_disabled_when_push_off() {
        use crate::api::in_memory::Method;
        let (client, eng) = engine().await; // push disabled
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task", "1");
        eng.run().await.unwrap();

        eng.store
            .record_move("T1", "L1", None, Some("X"))
            .await
            .unwrap();
        eng.run().await.unwrap();

        assert_eq!(client.call_count(Method::MoveTask), 0);
        // Move intent preserved for when push is enabled.
        assert_eq!(eng.store.pending_moves().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn push_move_not_found_drops_intent() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap(); // list now exists locally

        // A clean task that exists locally but the server doesn't know.
        let mut local = dirty_task("ghost", "L1", "update");
        local.sync_state = SyncState::Clean;
        local.pending_op = None;
        local.task.etag = Some("e1".into());
        eng.store.upsert_task(&local).await.unwrap();
        eng.store
            .record_move("ghost", "L1", None, None)
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0);
        // Stale move dropped, not retried forever.
        assert!(eng.store.pending_moves().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn push_move_transient_retries() {
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task", "1");
        client.seed_task("L1", "T2", "other", "2");
        eng.run().await.unwrap();

        eng.store
            .record_move("T1", "L1", None, Some("T2"))
            .await
            .unwrap();
        client.fail_next(Method::MoveTask, || ApiError::Server { status: 503 });

        eng.run().await.unwrap();
        // Move intent preserved for retry.
        assert_eq!(eng.store.pending_moves().await.unwrap().len(), 1);
    }

    // ─── RFC-009 §E/§F matrix: local reorder / demote / promote × remote ─────
    //
    // One test per row of §E (position moves) and §F (parent moves). Moves are
    // last-writer-wins by construction — the move endpoint takes no etag — so
    // every row's expected outcome is P5: **degrade, never wedge**. No row may
    // end with a retry that never stops, a deleted task, an aborted run, or a
    // local view that has silently drifted from the server.
    //
    // The tests assert the end state on BOTH sides (local store AND fake) and,
    // where ordering is the point, that the two agree row for row.

    /// Apply a move the way `move_task` (the command) does: the local row
    /// takes the new parent/position immediately AND a pending move is
    /// recorded for the push. Tests that skip the optimistic half would never
    /// see the drift a dropped intent leaves behind.
    async fn local_move(eng: &SyncEngine, id: &str, parent: Option<&str>, previous: Option<&str>) {
        let mut row = eng.store.find_task_any(id).await.unwrap().unwrap();
        row.task.parent = parent.map(String::from);
        row.task.position = match previous {
            Some(p) => format!("after-{p}"),
            None => "00000000000001".into(),
        };
        row.local_updated = "2026-06-02T00:00:00Z".into();
        eng.store.upsert_task(&row).await.unwrap();
        eng.store
            .record_move(id, &row.list_id, parent, previous)
            .await
            .unwrap();
    }

    /// Top-level task ids in the order the server would render them.
    async fn remote_order(client: &InMemoryClient, list: &str) -> Vec<String> {
        client
            .list_tasks(list, None)
            .await
            .unwrap()
            .items
            .iter()
            .filter(|t| t.parent.is_none())
            .map(|t| t.id.clone())
            .collect()
    }

    /// Top-level task ids in the order the list view renders them (invariant
    /// #1: only top-level rows are ever rendered as list rows).
    async fn local_order(eng: &SyncEngine, list: &str) -> Vec<String> {
        eng.store
            .list_tasks(list)
            .await
            .unwrap()
            .iter()
            .filter(|t| t.task.parent.is_none())
            .map(|t| t.task.id.clone())
            .collect()
    }

    /// The parent of a task as the server currently holds it.
    async fn remote_parent(client: &InMemoryClient, list: &str, id: &str) -> Option<String> {
        client.get_task(list, id).await.unwrap().parent
    }

    /// Invariant #1, asserted over the whole store: no row may have a
    /// grandparent. Google stores a third level happily (probe 3) — this is
    /// the check that proves we never asked it to.
    async fn assert_at_most_one_level(eng: &SyncEngine, list: &str) {
        let rows = eng.store.list_tasks(list).await.unwrap();
        for r in &rows {
            if let Some(p) = r.task.parent.as_deref() {
                let parent = rows.iter().find(|x| x.task.id == p);
                assert!(
                    parent.is_none_or(|x| x.task.parent.is_none()),
                    "{} is nested a third level under {p}",
                    r.task.id
                );
            }
        }
    }

    #[tokio::test]
    async fn reorder_vs_remote_reorder_last_writer_wins_and_converges() {
        // §E × remote reordered the same list. The move endpoint carries no
        // etag, so there is nothing to 412 on: whoever writes last wins the
        // position, and the pull leaves both sides showing the same order.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "A", "a", "00000000000001");
        client.seed_task("L1", "B", "b", "00000000000002");
        client.seed_task("L1", "C", "c", "00000000000003");
        eng.run().await.unwrap();

        // Another device drags C to the top of the list.
        client.move_task("L1", "C", None, None).await.unwrap();
        // We drag A to sit right after B. Ours is written last.
        local_move(&eng, "A", None, Some("B")).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "a concurrent reorder is not an error");
        assert_eq!(
            client.call_count(Method::MoveTask),
            2,
            "the other device's drag, then ours — one call each, no retry"
        );
        assert_eq!(
            remote_order(&client, "L1").await,
            vec!["C", "B", "A"],
            "both reorders landed: theirs first, ours after it"
        );
        assert_eq!(
            local_order(&eng, "L1").await,
            remote_order(&client, "L1").await,
            "the list view shows exactly what the server holds"
        );

        // P7: quiescent remote → the next run is a no-op.
        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.pushed, 0);
        assert_eq!(client.call_count(Method::MoveTask), 2);
        assert!(eng.store.pending_moves().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn reorder_vs_remote_content_edit_keeps_both() {
        // §E × remote edited the same row's content. A move is orthogonal to
        // content: the rename arrives (via the move response body, adopted
        // because the row is clean — P6) and our ordering still lands. No
        // conflict, no copy.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "A", "a", "00000000000001");
        client.seed_task("L1", "B", "b", "00000000000002");
        eng.run().await.unwrap();

        client
            .patch_task(
                "L1",
                "A",
                TaskPatch {
                    title: Some("renamed elsewhere".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        local_move(&eng, "A", None, Some("B")).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 0, "a move cannot fork a conflicted copy");
        assert_eq!(out.errors, 0);

        let rows = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(rows.len(), 2, "no conflicted copy was created");
        let a = rows.iter().find(|t| t.task.id == "A").unwrap();
        assert_eq!(
            a.task.title, "renamed elsewhere",
            "the remote content is canonical"
        );
        assert_eq!(a.sync_state, SyncState::Clean);
        assert_eq!(
            local_order(&eng, "L1").await,
            vec!["B", "A"],
            "and our reorder still landed"
        );
        assert_eq!(remote_order(&client, "L1").await, vec!["B", "A"]);
    }

    #[tokio::test]
    async fn move_whose_previous_died_remotely_keeps_the_reparent() {
        // §E gap — the ambiguous 404. The user dropped T under P, after P's
        // existing subtask B; another device deleted B in the meantime. B is
        // still in OUR store, so the local guard passes and the move goes out
        // naming a `previous` the server no longer has → 404 "Previous task id
        // not found" (probe 2, verified live).
        //
        // Reading that 404 as "the subject is gone" throws the whole intent
        // away: the server keeps T top-level, the local row keeps the parent
        // the user already sees, and the etags still match — so the pull
        // reverts the demote (or, worse, never notices). Degrade instead: drop
        // the ordering half and send the reparent alone (P5's ladder).
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task_with_parent("L1", "B", "sibling", "00000000000002", Some("P"));
        client.seed_task("L1", "T", "dragged under P after B", "00000000000003");
        eng.run().await.unwrap();

        client.delete_task("L1", "B").await.unwrap();
        local_move(&eng, "T", Some("P"), Some("B")).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "a vanished sibling is not a run error");
        assert_eq!(
            client.call_count(Method::MoveTask),
            2,
            "the move as asked, then the reparent alone — and no third try"
        );
        assert_eq!(
            remote_parent(&client, "L1", "T").await.as_deref(),
            Some("P"),
            "the reparent the user asked for reached the server"
        );
        let t = eng.store.find_task_any("T").await.unwrap().unwrap();
        assert_eq!(
            t.task.parent.as_deref(),
            Some("P"),
            "and the local view still agrees with it"
        );
        assert!(
            eng.store.find_task_any("B").await.unwrap().is_none(),
            "the deleted sibling is gone locally too"
        );
        assert!(eng.store.pending_moves().await.unwrap().is_empty());

        // P7 + no wedge: nothing left to push.
        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.pushed, 0);
        assert_eq!(out2.errors, 0);
        assert_eq!(client.call_count(Method::MoveTask), 2);
    }

    #[tokio::test]
    async fn move_404_without_a_previous_drops_the_intent_and_the_run_goes_on() {
        // §E — the other half of the ambiguity. With no `previous` in the
        // request there is nothing left to degrade to, so a 404 can only mean
        // the subject is gone: drop the intent, do NOT retry, and let the rest
        // of the queue through.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T", "vanishing", "00000000000001");
        client.seed_task("L1", "A", "a", "00000000000002");
        client.seed_task("L1", "B", "b", "00000000000003");
        eng.run().await.unwrap();

        client.fail_next_for_id(Method::MoveTask, "T", || ApiError::NotFound);
        local_move(&eng, "T", None, None).await;
        local_move(&eng, "A", None, Some("B")).await;

        let out = eng.run().await.unwrap();
        assert_eq!(
            client.call_count(Method::MoveTask),
            2,
            "one call for the 404'd move (no pointless retry) and one for the other"
        );
        assert_eq!(out.errors, 0, "a 404 move is not counted as a failure");
        assert!(
            eng.store.pending_moves().await.unwrap().is_empty(),
            "neither intent is left to grind forever"
        );
        assert_eq!(
            remote_order(&client, "L1").await,
            vec!["T", "B", "A"],
            "the second move still landed — one bad row cannot starve the queue"
        );
    }

    #[tokio::test]
    async fn reorder_vs_remote_delete_of_the_moved_task_drops_the_intent() {
        // §E × task deleted remotely. The fake models the live asymmetry: an
        // unknown SUBJECT id is a permanent 400 "Invalid task ID" (probe 2),
        // not a 404. It is counted and dropped, never retried, and the pull
        // removes the row the user can no longer act on.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "A", "a", "00000000000001");
        client.seed_task("L1", "B", "b", "00000000000002");
        eng.run().await.unwrap();

        client.delete_task("L1", "A").await.unwrap();
        local_move(&eng, "A", None, Some("B")).await;

        eng.run().await.unwrap();
        assert!(
            eng.store.pending_moves().await.unwrap().is_empty(),
            "the intent is dropped, not retried forever"
        );
        assert_eq!(
            local_order(&eng, "L1").await,
            vec!["B"],
            "the deleted row is gone from the list view"
        );

        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.errors, 0, "and the failure does not repeat");
    }

    #[tokio::test]
    async fn demote_under_a_parent_deleted_remotely_converges_in_both_orders() {
        // §F × P deleted remotely. Two legal serializations; the invariant is
        // convergence, not which one won.
        //
        // (a) The server processed the delete first, so our move names a dead
        // parent id. The exact status for that is NOT probed (an insert naming
        // an unresolved parent is a permanent 400 "Invalid task ID"; a move
        // naming an unknown subject is the same 400, an unknown previous a
        // 404), so the test injects BOTH permanent statuses and demands the
        // same outcome from each: the intent is dropped, the run continues,
        // and the task survives top-level on both sides.
        use crate::api::in_memory::Method;
        for reject in [
            || ApiError::Other("400: Invalid task ID".into()),
            || ApiError::NotFound,
        ] {
            let (client, eng) = engine_with_push().await;
            client.seed_list("L1", "Inbox");
            client.seed_task("L1", "P", "parent", "00000000000001");
            client.seed_task("L1", "T", "dragged under P", "00000000000002");
            eng.run().await.unwrap();

            // P dies remotely; we have not pulled that yet, so the local guard
            // still sees a live parent and the move goes out.
            client.delete_task("L1", "P").await.unwrap();
            local_move(&eng, "T", Some("P"), None).await;
            client.fail_next_for_id(Method::MoveTask, "T", reject);

            eng.run().await.unwrap();
            assert!(
                eng.store.pending_moves().await.unwrap().is_empty(),
                "no wedge: the intent is dropped either way"
            );
            assert_eq!(
                local_order(&eng, "L1").await,
                vec!["T"],
                "the task survives, top-level, and P is gone from the view"
            );
            assert_eq!(remote_parent(&client, "L1", "T").await, None);
            assert_at_most_one_level(&eng, "L1").await;

            let out2 = eng.run().await.unwrap();
            assert_eq!(out2.errors, 0);
            assert_eq!(out2.pushed, 0);
        }

        // (b) The move landed first, and P's delete cascaded T away on the
        // server afterwards. Ghost detection converges the local view.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "dragged under P", "00000000000002");
        eng.run().await.unwrap();

        local_move(&eng, "T", Some("P"), None).await;
        eng.run().await.unwrap();
        assert_eq!(
            remote_parent(&client, "L1", "T").await.as_deref(),
            Some("P")
        );

        client.delete_task("L1", "P").await.unwrap();
        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert!(
            eng.store.list_tasks("L1").await.unwrap().is_empty(),
            "the cascade took the demoted task; local mirrors it"
        );
    }

    #[tokio::test]
    async fn demote_under_a_remotely_completed_parent_arrives_completed() {
        // §F × P completed remotely. Google accepts the move (200) and its
        // cascade completes the moved-in task — the move RESPONSE already says
        // so (probe 4). Response-body adoption (P6) converges it: the user
        // sees their open task become done rather than the row freezing with a
        // fresh etag and stale content.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "still open", "00000000000002");
        eng.run().await.unwrap();

        client
            .patch_task(
                "L1",
                "P",
                TaskPatch {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        local_move(&eng, "T", Some("P"), None).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        let t = eng.store.find_task_any("T").await.unwrap().unwrap();
        assert_eq!(t.task.parent.as_deref(), Some("P"), "the demote landed");
        assert_eq!(
            t.task.status,
            TaskStatus::Completed,
            "the server's cascade completed it and we adopted the body"
        );
        assert_eq!(t.sync_state, SyncState::Clean);
        assert_eq!(
            t.task.etag,
            client.get_task("L1", "T").await.unwrap().etag,
            "etag and content stay coherent (P6) — no frozen row"
        );

        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.pushed, 0, "converged in one run");
    }

    #[tokio::test]
    async fn demote_of_a_task_that_gained_a_remote_subtask_is_refused() {
        // §F gap — the third level. The demote was recorded while T was
        // childless; a pull then handed T a remote-born subtask. Pushing the
        // move now would nest C three deep, and Google would ACCEPT it (probe
        // 3: no depth cap, 200) — the server cannot save us here, so the move
        // must be refused client-side. Invariant #1 is ours to keep.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "about to be demoted", "00000000000002");
        eng.run().await.unwrap();

        // Another device adds a subtask under T; we pull it.
        client.seed_task_with_parent("L1", "C", "remote-born child", "00000000000003", Some("T"));
        eng.run().await.unwrap();
        assert_eq!(
            eng.store
                .find_task_any("C")
                .await
                .unwrap()
                .unwrap()
                .task
                .parent
                .as_deref(),
            Some("T")
        );

        local_move(&eng, "T", Some("P"), None).await;
        let out = eng.run().await.unwrap();

        assert_eq!(
            client.call_count(Method::MoveTask),
            0,
            "the move is never sent: the server would say yes"
        );
        assert_eq!(out.errors, 0, "refusing is not an error");
        assert!(eng.store.pending_moves().await.unwrap().is_empty());
        assert_eq!(
            remote_parent(&client, "L1", "T").await,
            None,
            "T is still top-level on the server"
        );
        // And the local row was reverted to the server's truth — otherwise the
        // matching etag would freeze the third level into the local view.
        assert_eq!(
            local_order(&eng, "L1").await,
            vec!["P", "T"],
            "T renders as a top-level row again"
        );
        assert_at_most_one_level(&eng, "L1").await;
        assert_eq!(
            eng.store
                .find_task_any("C")
                .await
                .unwrap()
                .unwrap()
                .task
                .parent
                .as_deref(),
            Some("T"),
            "and its subtask is still its subtask"
        );

        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.pushed, 0);
        assert_eq!(client.call_count(Method::MoveTask), 0);
        assert_at_most_one_level(&eng, "L1").await;
    }

    #[tokio::test]
    async fn a_refused_move_leaves_a_pending_content_edit_alone() {
        // The refusal reverts the optimistic placement by dropping the row's
        // etag — but only for a CLEAN row. A row that also carries a pending
        // edit owns its etag: clearing it would downgrade the guarded
        // `If-Match` patch to an unconditional one. The edit must land, and the
        // row must still converge to the server's parent afterwards.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "about to be demoted", "00000000000002");
        eng.run().await.unwrap();
        client.seed_task_with_parent("L1", "C", "remote-born child", "00000000000003", Some("T"));
        eng.run().await.unwrap();

        local_move(&eng, "T", Some("P"), None).await;
        let mut t = eng.store.find_task_any("T").await.unwrap().unwrap();
        t.task.title = "renamed locally".into();
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        eng.store.upsert_task(&t).await.unwrap();

        // The edit's push drops on the network, so the row is STILL dirty when
        // the move is refused — the case the clean-only filter exists for.
        client.fail_next(Method::PatchTask, || ApiError::Server { status: 503 });
        eng.run().await.unwrap();
        assert_eq!(
            client.call_count(Method::MoveTask),
            0,
            "the move is refused"
        );
        let t = eng.store.find_task_any("T").await.unwrap().unwrap();
        assert_eq!(t.sync_state, SyncState::Dirty, "the edit is still pending");
        assert!(t.task.etag.is_some(), "and it kept its etag guard");

        // Another device edits the same row. The retried patch must still be
        // guarded by If-Match, or that edit is silently overwritten.
        client
            .patch_task(
                "L1",
                "T",
                TaskPatch {
                    title: Some("renamed remotely".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 1, "412 → the remote edit was not clobbered");
        let rows = eng.store.list_tasks("L1").await.unwrap();
        let t = rows.iter().find(|r| r.task.id == "T").unwrap();
        assert_eq!(t.task.title, "renamed remotely", "remote is canonical (P3)");
        assert_eq!(t.task.parent, None, "and T is top-level again");
        assert!(
            rows.iter()
                .any(|r| r.task.title.contains("(conflicted copy)")),
            "the local edit survives as a copy"
        );
        assert_at_most_one_level(&eng, "L1").await;
    }

    #[tokio::test]
    async fn demote_under_a_task_that_became_a_subtask_remotely_is_refused() {
        // §F gap, mirror case: the target parent P was itself demoted under Q
        // by another device. Same third level, same refusal.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "Q", "grandparent-to-be", "00000000000001");
        client.seed_task("L1", "P", "target parent", "00000000000002");
        client.seed_task("L1", "T", "dragged under P", "00000000000003");
        eng.run().await.unwrap();

        client.move_task("L1", "P", Some("Q"), None).await.unwrap();
        eng.run().await.unwrap(); // pull: P is now a subtask of Q locally too
        let calls_before = client.call_count(Method::MoveTask); // the remote drag

        local_move(&eng, "T", Some("P"), None).await;
        eng.run().await.unwrap();

        assert_eq!(
            client.call_count(Method::MoveTask),
            calls_before,
            "the move is never sent"
        );
        assert!(eng.store.pending_moves().await.unwrap().is_empty());
        assert_eq!(remote_parent(&client, "L1", "T").await, None);
        assert_at_most_one_level(&eng, "L1").await;
        assert!(
            local_order(&eng, "L1").await.contains(&"T".to_string()),
            "T is back to being a top-level row, not a hidden grandchild"
        );
    }

    #[tokio::test]
    async fn d7_repairs_a_remote_born_third_level_after_our_demote_landed() {
        // §F residual (D7 ratified). No push-side guard can catch this: our
        // demote of T under P LANDS while T is childless, so the server holds
        // P > T. Only THEN does another device add C under T — the server now
        // has a third level (P > T > C) we never asked for. The pull is the
        // one place with the full picture, so D7 promotes C to top-level AND
        // pushes the corrective move so the server converges too, counting it
        // as a conflict.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "to be demoted", "00000000000002");
        eng.run().await.unwrap();

        // Our demote lands: T becomes a subtask of P on the server.
        local_move(&eng, "T", Some("P"), None).await;
        eng.run().await.unwrap();
        assert_eq!(
            remote_parent(&client, "L1", "T").await,
            Some("P".into()),
            "our demote landed — T is a subtask of P server-side"
        );

        // Another device now hangs C under the (already-demoted) T.
        client.seed_task_with_parent("L1", "C", "remote grandchild", "00000000000003", Some("T"));
        let moves_before = client.call_count(Method::MoveTask);

        let out = eng.run().await.unwrap();

        assert_eq!(
            out.conflicts, 1,
            "the third level is resolved as a conflict"
        );
        assert_eq!(out.errors, 0, "repairing is not an error");
        assert_eq!(
            client.call_count(Method::MoveTask),
            moves_before + 1,
            "exactly one corrective move — C promoted to top-level"
        );
        // Local: C is a top-level row, T is still P's subtask.
        let c = eng.store.find_task_any("C").await.unwrap().unwrap();
        assert_eq!(c.task.parent, None, "C is promoted to top-level locally");
        assert_eq!(c.sync_state, SyncState::Clean);
        assert_eq!(
            eng.store
                .find_task_any("T")
                .await
                .unwrap()
                .unwrap()
                .task
                .parent
                .as_deref(),
            Some("P"),
            "the user's demote of T survives — nothing is discarded"
        );
        assert!(
            local_order(&eng, "L1").await.contains(&"C".to_string()),
            "C now renders as a top-level list row"
        );
        assert_at_most_one_level(&eng, "L1").await;
        // Server converged too — C is top-level there, coherent etag (P6).
        assert_eq!(
            remote_parent(&client, "L1", "C").await,
            None,
            "the corrective move reached the server"
        );
        assert_eq!(
            c.task.etag,
            client.get_task("L1", "C").await.unwrap().etag,
            "etag stays coherent with content (P6) — no frozen row"
        );

        // P7: a second run against the quiescent server is a no-op — the
        // repair does not re-fire every pull.
        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.conflicts, 0, "no repair re-fires once converged");
        assert_eq!(out2.pushed, 0);
        assert_eq!(
            client.call_count(Method::MoveTask),
            moves_before + 1,
            "no further corrective move"
        );
        assert_at_most_one_level(&eng, "L1").await;
    }

    #[tokio::test]
    async fn d7_repairs_our_queued_subtask_create_under_a_remotely_demoted_parent() {
        // §G (D7 ratified). The most practical third-level vector: an offline
        // device has a queued subtask create under T; meanwhile another device
        // demotes T under P. Push runs before pull, so the queued insert cannot
        // know its parent is now a subtask — the server accepts it (no depth
        // cap, probed) and WE create the third level. The following pull's D7
        // repair catches it within one round-trip.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "target parent", "00000000000002");
        eng.run().await.unwrap();

        // Another device demotes T under P on the server. Locally T is still a
        // top-level row (the demote is unseen until the pull).
        client.move_task("L1", "T", Some("P"), None).await.unwrap();

        // Our still-queued subtask create under T — legal locally, since T is
        // top-level in our view.
        let mut c = dirty_task("local-c", "L1", "create");
        c.task.parent = Some("T".into());
        c.task.title = "queued grandchild".into();
        eng.store.upsert_task(&c).await.unwrap();

        let out = eng.run().await.unwrap();
        // The insert landed under T (server P > T > C), then the pull promoted C.
        assert_eq!(out.conflicts, 1, "the third level we created is repaired");
        assert_eq!(out.errors, 0);

        // C's local id was remapped by the insert; find it by its unique title.
        let rows = eng.store.list_tasks("L1").await.unwrap();
        let c = rows
            .iter()
            .find(|r| r.task.title == "queued grandchild")
            .expect("the created subtask is present");
        assert_eq!(c.task.parent, None, "our queued subtask ends up top-level");
        assert_eq!(c.sync_state, SyncState::Clean);
        assert_at_most_one_level(&eng, "L1").await;
        assert_eq!(
            remote_parent(&client, "L1", &c.task.id).await,
            None,
            "the server converged to the promotion too"
        );

        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.conflicts, 0, "converged in one round-trip");
        assert_eq!(out2.pushed, 0);
        assert_at_most_one_level(&eng, "L1").await;
    }

    #[tokio::test]
    async fn d7_promotes_a_still_unpushed_subtask_create_locally() {
        // §G before the create pushes: the subtask create is HELD (the UI has
        // its editor open), so it stays queued while the pull lands its parent's
        // remote demote. There is no server id to move — D7 must promote the
        // create LOCALLY so the tree is one level immediately, and it then
        // pushes as a top-level create.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "target parent", "00000000000002");
        eng.run().await.unwrap();
        client.move_task("L1", "T", Some("P"), None).await.unwrap();

        // A queued subtask create under T, held so its create push is deferred.
        let mut c = dirty_task("held-c", "L1", "create");
        c.task.parent = Some("T".into());
        c.task.title = "held grandchild".into();
        eng.store.upsert_task(&c).await.unwrap();

        let held = SyncEngine::with_push(client.clone(), eng.store.clone(), true)
            .hold_create_id(Some("held-c".into()));
        let moves_before = client.call_count(Method::MoveTask);
        let out = held.run().await.unwrap();

        // No server move — the create has no id yet — but the local tree is
        // already flat: the held create is now top-level.
        assert_eq!(
            client.call_count(Method::MoveTask),
            moves_before,
            "no corrective move: an un-pushed create has no server id to move"
        );
        assert_eq!(out.conflicts, 1, "promoting the queued third level counts");
        let c = eng.store.find_task_any("held-c").await.unwrap().unwrap();
        assert_eq!(c.task.parent, None, "the held create is promoted locally");
        assert_eq!(c.sync_state, SyncState::Dirty, "still a queued create");
        assert_eq!(c.pending_op.as_deref(), Some("create"));
        assert_at_most_one_level(&eng, "L1").await;

        // Release the hold: the create pushes as a TOP-LEVEL task and converges.
        eng.run().await.unwrap();
        let rows = eng.store.list_tasks("L1").await.unwrap();
        let c = rows
            .iter()
            .find(|r| r.task.title == "held grandchild")
            .expect("the created task is present");
        assert_eq!(c.task.parent, None, "it landed top-level on the server too");
        assert_eq!(c.sync_state, SyncState::Clean);
        assert_eq!(remote_parent(&client, "L1", &c.task.id).await, None);
        assert_at_most_one_level(&eng, "L1").await;
    }

    #[tokio::test]
    async fn d7_third_level_repair_defers_to_a_racing_promotion_pulled_first() {
        // Idempotency, path 1 (D7): another device sees the same third level
        // and promotes C first. Its promotion changed C's etag, so our pull
        // ADOPTS the top-level C before D7 even inspects the row — D7 then finds
        // no grandchild and issues no redundant move. At-most-one-level holds
        // and the run converges, with no double promotion.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "subtask", "00000000000002");
        eng.run().await.unwrap();
        local_move(&eng, "T", Some("P"), None).await;
        eng.run().await.unwrap();
        client.seed_task_with_parent("L1", "C", "grandchild", "00000000000003", Some("T"));

        // The other device wins the race: it promotes C on the server before
        // our pull runs.
        client.move_task("L1", "C", None, None).await.unwrap();
        let moves_before = client.call_count(Method::MoveTask);

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "a racing repair is not an error");
        assert_eq!(
            client.call_count(Method::MoveTask),
            moves_before,
            "no redundant corrective move — the pull already adopted the promotion"
        );
        let c = eng.store.find_task_any("C").await.unwrap().unwrap();
        assert_eq!(c.task.parent, None, "C is top-level, exactly once");
        assert_at_most_one_level(&eng, "L1").await;
        assert_eq!(remote_parent(&client, "L1", "C").await, None);
        assert_eq!(
            c.task.etag,
            client.get_task("L1", "C").await.unwrap().etag,
            "etag/content stay coherent even through the racing promotion (P6)"
        );

        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.conflicts, 0, "quiescent afterwards");
        assert_eq!(out2.pushed, 0);
        assert_at_most_one_level(&eng, "L1").await;
    }

    #[tokio::test]
    async fn d7_corrective_move_on_an_already_top_level_row_is_an_accepted_no_op() {
        // Idempotency, path 2 (D7): the guarantee the repair leans on when two
        // devices race. If another device promoted C first, our corrective
        // move(parent=None) lands on an already top-level C — Google accepts it
        // (no depth cap; a move issues a fresh etag but changes no placement),
        // so a second repair can never corrupt the row or wedge. This pins the
        // exact API contract D7 depends on.
        let client = InMemoryClient::new();
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "C", "already top-level", "00000000000001");

        let first = client.move_task("L1", "C", None, None).await.unwrap();
        assert_eq!(first.parent, None, "C stays top-level");
        // A racing repair promotes it AGAIN — still fine, still top-level.
        let second = client.move_task("L1", "C", None, None).await.unwrap();
        assert_eq!(second.parent, None, "a redundant promotion is a no-op");
        assert_eq!(
            client.get_task("L1", "C").await.unwrap().parent,
            None,
            "the server never nests C from a repeated promote"
        );
    }

    #[tokio::test]
    async fn d7_transient_move_failure_still_flattens_locally_then_converges() {
        // D7 failure path (found by the §F/§G soak): the corrective move is
        // rate-limited. The LOCAL third level must NOT linger — invariant #1 is
        // absolute even mid-flight — so the grandchild is promoted locally now
        // and its etag dropped; the server, still nesting it, is caught by the
        // next pull's re-detect + retry (P7), never stranded.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "to be demoted", "00000000000002");
        eng.run().await.unwrap();
        local_move(&eng, "T", Some("P"), None).await;
        eng.run().await.unwrap();
        client.seed_task_with_parent("L1", "C", "grandchild", "00000000000003", Some("T"));

        // The corrective move is rate-limited (transient) this run.
        client.fail_next_for_id(Method::MoveTask, "C", || ApiError::RateLimited {
            retry_after: None,
        });
        let out = eng.run().await.unwrap();

        // Local: flat immediately, even though the server move did not land.
        assert_eq!(out.conflicts, 1, "resolving the third level counts");
        let c = eng.store.find_task_any("C").await.unwrap().unwrap();
        assert_eq!(c.task.parent, None, "C is promoted to top-level locally");
        assert_eq!(
            c.task.etag, None,
            "etag dropped so the next pull re-examines it"
        );
        assert_at_most_one_level(&eng, "L1").await;
        // Server still nests C — the move was refused this run.
        assert_eq!(
            remote_parent(&client, "L1", "C").await,
            Some("T".into()),
            "the server is still nested; it must be caught next run (P7)"
        );

        // Next run: the fault is gone, so the re-pull re-detects and the retry
        // lands — server and local converge, at one level.
        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.conflicts, 1, "the retry resolves it on the server too");
        assert_eq!(
            remote_parent(&client, "L1", "C").await,
            None,
            "server converged"
        );
        let c = eng.store.find_task_any("C").await.unwrap().unwrap();
        assert_eq!(c.task.parent, None);
        assert_at_most_one_level(&eng, "L1").await;

        // And it is a fixpoint afterwards.
        let out3 = eng.run().await.unwrap();
        assert_eq!(out3.conflicts, 0, "no repair re-fires once converged");
        assert_at_most_one_level(&eng, "L1").await;
    }

    #[tokio::test]
    async fn d7_permanent_move_failure_flattens_locally_on_a_partial_pull() {
        // The exact soak failure. A grandchild `C` was pulled in nested under a
        // clean subtask `T`, then DELETED on the server (its own delete, or a
        // cascade), so the corrective move is rejected permanently (400 — the
        // id is unknown on the server). On a PARTIAL pull ghost removal is
        // skipped, so without the fix the stale nested row lingers — a third
        // level in the store right after the pull. D7 must promote it locally
        // regardless; the next COMPLETE pull ghost-removes the vanished row.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "to be demoted", "00000000000002");
        eng.run().await.unwrap();
        local_move(&eng, "T", Some("P"), None).await;
        eng.run().await.unwrap();

        // A clean local grandchild under T that the server does NOT hold — the
        // residual after a demote landed and the grandchild was then deleted
        // remotely. Its move will be a permanent 400 (unknown id).
        let mut c = dirty_task("C", "L1", "create");
        c.task.parent = Some("T".into());
        c.task.title = "vanished grandchild".into();
        c.task.etag = Some("e-c".into());
        c.sync_state = SyncState::Clean;
        c.pending_op = None;
        eng.store.upsert_task(&c).await.unwrap();

        // Partial pull: page the list and fail the last page so ghost removal
        // (which would otherwise mask the fix) is skipped this run.
        client.set_page_size(1);
        client.fail_list_tasks_page(1, || ApiError::Server { status: 503 });
        let out = eng.run().await.unwrap();

        assert_eq!(out.conflicts, 1, "the third level is resolved locally");
        let c = eng.store.find_task_any("C").await.unwrap().unwrap();
        assert_eq!(
            c.task.parent, None,
            "C is flat locally despite the rejection"
        );
        assert_at_most_one_level(&eng, "L1").await;

        // Heal: a complete pull ghost-removes the vanished row and converges.
        client.clear_faults();
        client.set_page_size(100);
        eng.run().await.unwrap();
        assert!(
            eng.store.find_task_any("C").await.unwrap().is_none(),
            "the vanished grandchild is ghost-removed on the next complete pull"
        );
        assert_at_most_one_level(&eng, "L1").await;
    }

    #[tokio::test]
    async fn d7_dirty_grandchild_keeps_its_etag_so_the_retry_push_stays_guarded() {
        // D7 failure path × a DIRTY grandchild (RFC-009 §F/§G, invariant P6).
        // When the corrective move is refused, the LOCAL third level must still
        // flatten immediately (invariant #1) — but a grandchild carrying a
        // pending edit KEEPS its etag, because its own content push governs the
        // etag. Dropping it (as a clean row does) would turn the retry patch's
        // guarded `If-Match` into an unconditional overwrite, silently
        // clobbering a concurrent remote edit — the same guard
        // `revert_local_move` applies.
        use crate::api::in_memory::Method;
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task("L1", "T", "to be demoted", "00000000000002");
        eng.run().await.unwrap();
        local_move(&eng, "T", Some("P"), None).await;
        eng.run().await.unwrap();
        // T is now a clean subtask of P, both locally and on the server.

        // A synced grandchild C under T (§F residual) that ALSO carries a
        // pending local edit: dirty, but holding the server etag it synced at.
        let seeded =
            client.seed_task_with_parent("L1", "C", "grandchild", "00000000000003", Some("T"));
        let c_etag = seeded.etag.clone().unwrap();
        let mut c = dirty_task("C", "L1", "update");
        c.task.parent = Some("T".into());
        c.task.title = "my local edit".into();
        c.task.etag = Some(c_etag.clone());
        c.task.web_view_link = Some("https://tasks.google.com/task/C".into());
        eng.store.upsert_task(&c).await.unwrap();

        // This run both the content push AND the corrective move are refused
        // (rate-limited). C stays dirty; D7 must flatten it locally now.
        client.fail_next_for_id(Method::PatchTask, "C", || ApiError::RateLimited {
            retry_after: None,
        });
        client.fail_next_for_id(Method::MoveTask, "C", || ApiError::RateLimited {
            retry_after: None,
        });
        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 1, "resolving the third level counts");

        let c = eng.store.find_task_any("C").await.unwrap().unwrap();
        assert_eq!(
            c.task.parent, None,
            "C is flattened to top-level locally (invariant #1)"
        );
        assert_eq!(
            c.sync_state,
            SyncState::Dirty,
            "the pending edit survives the repair"
        );
        assert_eq!(
            c.task.etag.as_deref(),
            Some(c_etag.as_str()),
            "a dirty grandchild keeps its etag so its retry push stays If-Match-guarded"
        );
        assert_at_most_one_level(&eng, "L1").await;

        // The behavioral consequence: a concurrent remote edit bumps C's server
        // etag. Because the retained etag makes the retry push If-Match-guarded,
        // that push 412s and BOTH edits survive — the remote is not clobbered.
        client
            .patch_task(
                "L1",
                "C",
                TaskPatch {
                    title: Some("their remote edit".into()),
                    ..Default::default()
                },
                Some(&c_etag),
            )
            .await
            .unwrap();

        let out2 = eng.run().await.unwrap();
        assert!(
            out2.conflicts >= 1,
            "the guarded retry hits a 412 and resolves it, never a silent clobber"
        );
        let rows = eng.store.list_tasks("L1").await.unwrap();
        assert!(
            rows.iter().any(|t| t.task.title == "their remote edit"),
            "the concurrent remote edit survives as the canonical row (no lost update)"
        );
        assert!(
            rows.iter()
                .any(|t| t.task.title == "my local edit (conflicted copy)"),
            "the local edit is preserved as a conflicted copy, nothing discarded"
        );
        assert_at_most_one_level(&eng, "L1").await;
    }

    #[tokio::test]
    async fn promote_vs_remote_delete_drops_the_intent_and_the_row_disappears() {
        // §F — promote/detach × the row deleted remotely. Delete wins (P4):
        // the intent is dropped and ghost detection removes the row. The
        // parent it was detaching from is untouched.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "00000000000001");
        client.seed_task_with_parent("L1", "S", "subtask", "00000000000002", Some("P"));
        eng.run().await.unwrap();

        client.delete_task("L1", "S").await.unwrap();
        local_move(&eng, "S", None, None).await;

        eng.run().await.unwrap();
        assert!(eng.store.pending_moves().await.unwrap().is_empty());
        assert!(
            eng.store.find_task_any("S").await.unwrap().is_none(),
            "the promoted row is gone, not resurrected top-level"
        );
        let p = eng.store.find_task_any("P").await.unwrap().unwrap();
        assert_eq!(p.sync_state, SyncState::Clean, "the parent is untouched");

        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.errors, 0);
    }

    #[tokio::test]
    async fn promote_vs_remote_reparent_last_writer_wins() {
        // §F — promote × the remote reparented the same row elsewhere. No etag
        // on the move endpoint, so the last write wins and the pull converges
        // both sides on it. Ours is written last: the task ends up top-level.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "old parent", "00000000000001");
        client.seed_task("L1", "Q", "other parent", "00000000000002");
        client.seed_task_with_parent("L1", "S", "subtask", "00000000000003", Some("P"));
        eng.run().await.unwrap();

        client.move_task("L1", "S", Some("Q"), None).await.unwrap();
        local_move(&eng, "S", None, None).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(
            remote_parent(&client, "L1", "S").await,
            None,
            "our promote was written last"
        );
        assert_eq!(
            local_order(&eng, "L1").await,
            vec!["S", "P", "Q"],
            "and the row renders as a top-level task"
        );
        assert_at_most_one_level(&eng, "L1").await;

        let out2 = eng.run().await.unwrap();
        assert_eq!(out2.pushed, 0, "converged");
    }

    #[tokio::test]
    async fn a_content_edit_and_a_move_on_the_same_row_both_land_in_one_run() {
        // §F last row: push order is updates-then-moves, so the final state is
        // the new content at the new position. The move response must NOT
        // clobber the pending edit (meta-only adoption for a dirty row).
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "A", "a", "00000000000001");
        client.seed_task("L1", "B", "b", "00000000000002");
        eng.run().await.unwrap();

        let mut a = eng.store.find_task_any("A").await.unwrap().unwrap();
        a.task.title = "renamed by me".into();
        a.sync_state = SyncState::Dirty;
        a.pending_op = Some("update".into());
        a.local_updated = "2026-06-02T00:00:00Z".into();
        eng.store.upsert_task(&a).await.unwrap();
        local_move(&eng, "A", None, Some("B")).await;

        let out = eng.run().await.unwrap();
        assert_eq!(out.conflicts, 0);
        assert_eq!(out.errors, 0);
        let a = eng.store.find_task_any("A").await.unwrap().unwrap();
        assert_eq!(a.task.title, "renamed by me");
        assert_eq!(a.sync_state, SyncState::Clean, "nothing left pending");
        assert_eq!(
            client.get_task("L1", "A").await.unwrap().title,
            "renamed by me"
        );
        assert_eq!(remote_order(&client, "L1").await, vec!["B", "A"]);
        assert_eq!(local_order(&eng, "L1").await, vec!["B", "A"]);
        assert_eq!(
            a.task.etag,
            client.get_task("L1", "A").await.unwrap().etag,
            "etag/content coherence (P6) survives update-then-move"
        );
    }

    // ─── List sync ───────────────────────────────────────────────────────────

    fn dirty_list(id: &str, title: &str, op: &str) -> StoredTaskList {
        StoredTaskList {
            list: TaskList {
                id: id.into(),
                title: title.into(),
                etag: if op == "create" {
                    None
                } else {
                    Some("e1".into())
                },
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: if op == "delete" {
                SyncState::Deleted
            } else {
                SyncState::Dirty
            },
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: Some(op.into()),
            local_only: false,
        }
    }

    #[tokio::test]
    async fn push_list_create_remaps_and_tasks_follow() {
        let (_client, eng) = engine_with_push().await;
        // Local list create + a task in it.
        eng.store
            .upsert_list(&dirty_list("local-list", "Work", "create"))
            .await
            .unwrap();
        let mut t = dirty_task("local-task", "local-list", "create");
        t.task.title = "do work".into();
        eng.store.upsert_task(&t).await.unwrap();

        let out = eng.run().await.unwrap();
        assert!(out.pushed >= 2);
        // List remapped to a remote id; task points at it.
        let lists = eng.store.all_lists().await.unwrap();
        let work = lists.iter().find(|l| l.list.title == "Work").unwrap();
        assert!(work.list.id.starts_with("remote-list-"));
        assert_eq!(work.sync_state, SyncState::Clean);
        let tasks = eng.store.list_tasks(&work.list.id).await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert!(tasks[0].task.id.starts_with("remote-"));
    }

    #[tokio::test]
    async fn held_edit_holds_list_create_then_pushes_on_release() {
        // A held edit (the UI is actively holding a row's id) freezes ALL list
        // creates for that run: a list-id remap would invalidate the id the UI
        // holds. The pending list create must WAIT — not push, not remap, not
        // get ghosted by the pull — and then push on the next unheld run.
        let (client, eng0) = engine_with_push().await;
        eng0.store
            .upsert_list(&dirty_list("local-list", "Work", "create"))
            .await
            .unwrap();

        // Run 1: an edit is held. The list create must be deferred.
        let eng_hold = SyncEngine::with_push(client.clone(), eng0.store.clone(), true)
            .hold_create_id(Some("held-task".into()));
        let out = eng_hold.run().await.unwrap();
        assert_eq!(out.pushed, 0, "nothing pushed while the edit is held");
        let lists = eng0.store.all_lists().await.unwrap();
        let work = lists
            .iter()
            .find(|l| l.list.title == "Work")
            .expect("pending list survives the held run, not ghosted");
        assert_eq!(
            work.list.id, "local-list",
            "id not remapped while the edit is held"
        );
        assert_eq!(work.sync_state, SyncState::Dirty, "create still queued");
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.title != "Work"),
            "server has no such list yet"
        );

        // Run 2: the edit is released. The deferred create now pushes and remaps.
        let out = eng0.run().await.unwrap();
        assert_eq!(out.pushed, 1, "the deferred list create pushes on release");
        let lists = eng0.store.all_lists().await.unwrap();
        let work = lists.iter().find(|l| l.list.title == "Work").unwrap();
        assert!(
            work.list.id.starts_with("remote-list-"),
            "remapped to a remote id on release"
        );
        assert_eq!(work.sync_state, SyncState::Clean);
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .any(|l| l.title == "Work"),
            "list now exists on the server"
        );
    }

    #[tokio::test]
    async fn push_list_rename() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Old Name");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.list.title = "New Name".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();

        let out = eng.run().await.unwrap();
        assert!(out.pushed >= 1);
        let page = client.list_tasklists().await.unwrap();
        assert!(page.iter().any(|l| l.id == "L1" && l.title == "New Name"));
        let l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        assert_eq!(l.sync_state, SyncState::Clean);
    }

    #[tokio::test]
    async fn push_list_delete() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Doomed");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.sync_state = SyncState::Deleted;
        l.pending_op = Some("delete".into());
        eng.store.upsert_list(&l).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 1);
        // Gone from server and local.
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.id != "L1")
        );
        assert!(
            eng.store
                .all_lists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.list.id != "L1")
        );
    }

    #[tokio::test]
    async fn push_list_rename_not_found_hard_deletes_local() {
        // Renaming a list the server no longer has (deleted elsewhere) 404s.
        // The rename is meaningless against a gone list, so the local row is
        // hard-deleted to converge with the server — not left dirty to 404
        // forever. No error is surfaced.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Old Name");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.list.title = "New Name".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();

        // The list is gone on the server (deleted by another client), so the
        // rename naturally 404s — and a pull won't resurrect it.
        client.delete_list_from_state("L1");

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "a 404 rename is not a server rejection");
        assert!(
            eng.store
                .all_lists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.list.id != "L1"),
            "the gone list is hard-deleted locally, not left dirty forever"
        );
    }

    #[tokio::test]
    async fn push_list_rename_not_found_rehomes_the_rows_the_server_never_saw() {
        // §I × P2. The 404 says the list is gone on the server, so it goes
        // locally too (P4) — but an unpushed create in it is work the server
        // has NEVER SEEN, and a remote event must not destroy that. It re-homes
        // to the default list, exactly as the pull's ghost path does (D2).
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Work");
        client.seed_list("L2", "My Tasks");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.list.title = "Work stuff".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();
        eng.store
            .upsert_task(&dirty_task("local-1", "L1", "create"))
            .await
            .unwrap();

        client.delete_list_from_state("L1");
        eng.run().await.unwrap();

        assert!(
            eng.store
                .all_lists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.list.id != "L1"),
            "the gone list is still dropped locally (P4)"
        );
        assert_eq!(
            eng.store
                .list_tasks("L2")
                .await
                .unwrap()
                .into_iter()
                .map(|t| t.task.title)
                .collect::<Vec<_>>(),
            vec!["task local-1"],
            "and the unpushed row survived in the default list (P2/D2)"
        );
    }

    #[tokio::test]
    async fn push_list_rename_not_found_keeps_the_list_when_there_is_nowhere_to_rehome() {
        // The same 404 with no surviving list to take the rows: dropping the
        // list would destroy them, so it is kept as an unpushed list create and
        // re-created on the server instead (P2 holds even with one list left).
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Work");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.list.title = "Work stuff".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();
        eng.store
            .upsert_task(&dirty_task("local-1", "L1", "create"))
            .await
            .unwrap();

        client.delete_list_from_state("L1");
        eng.run().await.unwrap();
        eng.run().await.unwrap();

        let lists = eng.store.all_lists().await.unwrap();
        let kept = lists
            .iter()
            .find(|l| l.list.title == "Work stuff")
            .expect("the list was kept rather than taking the row down with it");
        assert_eq!(
            eng.store
                .list_tasks(&kept.list.id)
                .await
                .unwrap()
                .into_iter()
                .map(|t| t.task.title)
                .collect::<Vec<_>>(),
            vec!["task local-1"]
        );
        assert_eq!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .into_iter()
                .map(|l| l.title)
                .collect::<Vec<_>>(),
            vec!["Work stuff"],
            "and it was re-created on the server so the row can push"
        );
    }

    #[tokio::test]
    async fn push_list_rename_transient_stays_dirty_then_converges() {
        // A transient (503) on a list rename must leave the row dirty and the
        // server untouched — no error surfaced — then succeed on the next run.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Old Name");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.list.title = "New Name".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();

        client.fail_next(crate::api::in_memory::Method::PatchTaskList, || {
            ApiError::Server { status: 503 }
        });

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "transient is not counted as an error");
        let l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        assert_eq!(l.sync_state, SyncState::Dirty, "stays dirty for retry");
        assert_eq!(l.list.title, "New Name", "local rename intent preserved");
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .any(|r| r.id == "L1" && r.title == "Old Name"),
            "server unchanged while the retry is pending"
        );

        // Next run (no fault): the rename lands and the row goes clean.
        let out = eng.run().await.unwrap();
        assert!(out.pushed >= 1);
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .any(|r| r.id == "L1" && r.title == "New Name")
        );
        let l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        assert_eq!(l.sync_state, SyncState::Clean);
    }

    #[tokio::test]
    async fn push_list_delete_transient_leaves_tombstone() {
        // A transient on a list delete must NOT hard-delete locally (that would
        // strand the list on the server) — it stays a tombstone and retries.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Doomed");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.sync_state = SyncState::Deleted;
        l.pending_op = Some("delete".into());
        eng.store.upsert_list(&l).await.unwrap();

        client.fail_next(crate::api::in_memory::Method::DeleteTaskList, || {
            ApiError::Server { status: 503 }
        });

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 0, "nothing deleted on a transient");
        assert_eq!(out.errors, 0, "transient is not counted as an error");
        // Deleted tombstones are excluded from all_lists; they live in the
        // dirty-list queue awaiting push.
        let pending = eng.store.drain_dirty_lists().await.unwrap();
        assert!(
            pending
                .iter()
                .any(|l| l.list.id == "L1" && l.sync_state == SyncState::Deleted),
            "tombstone survives for the next run's retry"
        );
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .any(|r| r.id == "L1"),
            "server list untouched while delete retries"
        );
    }

    #[tokio::test]
    async fn push_list_delete_auth_abort_leaves_tombstone() {
        // A 401 on a list delete aborts the run (every call would fail the same
        // way) instead of being swallowed. The tombstone survives so the delete
        // pushes after re-auth, and the server list is untouched.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Doomed");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.sync_state = SyncState::Deleted;
        l.pending_op = Some("delete".into());
        eng.store.upsert_list(&l).await.unwrap();

        client.fail_next(crate::api::in_memory::Method::DeleteTaskList, || {
            ApiError::Unauthorized
        });

        let err = eng.run().await.unwrap_err();
        assert!(
            matches!(err, SyncError::Api(ApiError::Unauthorized)),
            "auth failure aborts the run; got {err:?}"
        );
        let pending = eng.store.drain_dirty_lists().await.unwrap();
        assert!(
            pending
                .iter()
                .any(|l| l.list.id == "L1" && l.sync_state == SyncState::Deleted),
            "tombstone survives for retry after re-auth"
        );
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .any(|r| r.id == "L1"),
            "server list untouched by the aborted delete"
        );
    }

    #[tokio::test]
    async fn pull_adopts_local_create_by_title() {
        // Offline default "My Tasks" (local create) must adopt Google's
        // existing "My Tasks" on pull instead of duplicating.
        let (client, eng) = engine_with_push().await;
        eng.store
            .upsert_list(&dirty_list("local-uuid", "My Tasks", "create"))
            .await
            .unwrap();
        client.seed_list("remote-mytasks", "My Tasks");

        eng.run().await.unwrap();

        let lists = eng.store.all_lists().await.unwrap();
        let mt: Vec<_> = lists
            .iter()
            .filter(|l| l.list.title == "My Tasks")
            .collect();
        assert_eq!(mt.len(), 1, "no duplicate My Tasks");
        assert_eq!(mt[0].list.id, "remote-mytasks");
        assert_eq!(mt[0].sync_state, SyncState::Clean);
    }

    #[tokio::test]
    async fn pull_preserves_locally_renamed_list() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Server Title");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.list.title = "Local Rename".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();

        eng.run().await.unwrap(); // pull must not clobber the local rename (push disabled)
        let l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        assert_eq!(l.list.title, "Local Rename");
        assert_eq!(l.sync_state, SyncState::Dirty);
    }

    #[tokio::test]
    async fn pull_removes_ghost_list_and_its_tasks() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Keep");
        client.seed_list("L2", "Vanish");
        client.seed_task("L2", "T2", "doomed", "1");
        eng.run().await.unwrap();
        assert_eq!(eng.store.all_lists().await.unwrap().len(), 2);

        // L2 deleted on the server.
        client.delete_tasklist("L2").await.unwrap();

        let out = eng.run().await.unwrap();
        assert!(out.deleted >= 1);
        let lists = eng.store.all_lists().await.unwrap();
        assert_eq!(lists.len(), 1);
        assert_eq!(lists[0].list.id, "L1");
        // Cascade removed the ghost list's tasks.
        assert!(eng.store.list_tasks("L2").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn ghost_detection_spares_local_only_list() {
        // A local-only list is absent from the server by design. Ghost
        // detection must never remove it, even though no remote list matches.
        let (client, eng) = engine().await;
        client.seed_list("L1", "Synced");
        eng.run().await.unwrap();

        eng.store
            .upsert_list(&StoredTaskList {
                list: TaskList {
                    id: "local-1".into(),
                    title: "Scratch".into(),
                    etag: None,
                    updated: "2026-01-01T00:00:00Z".into(),
                },
                sync_state: SyncState::Clean,
                local_updated: "2026-01-01T00:00:00Z".into(),
                pending_op: None,
                local_only: true,
            })
            .await
            .unwrap();
        eng.store
            .upsert_task(&StoredTask {
                task: crate::model::Task {
                    id: "local-task".into(),
                    parent: None,
                    position: "1".into(),
                    title: "scratch task".into(),
                    notes: None,
                    status: TaskStatus::NeedsAction,
                    due: None,
                    completed: None,
                    etag: None,
                    updated: "2026-01-01T00:00:00Z".into(),
                    web_view_link: None,
                },
                list_id: "local-1".into(),
                sync_state: SyncState::Clean,
                local_updated: "2026-01-01T00:00:00Z".into(),
                pending_op: None,
            })
            .await
            .unwrap();

        eng.run().await.unwrap();

        let lists = eng.store.all_lists().await.unwrap();
        assert!(
            lists.iter().any(|l| l.list.id == "local-1"),
            "local-only list survives ghost detection"
        );
        assert_eq!(
            eng.store.list_tasks("local-1").await.unwrap().len(),
            1,
            "its tasks survive too"
        );
    }

    #[tokio::test]
    async fn push_skips_local_only_list_and_its_tasks() {
        // With push enabled, neither a local-only list nor its tasks may be
        // sent to the server.
        let (client, eng) = engine_with_push().await;
        eng.store
            .upsert_list(&StoredTaskList {
                list: TaskList {
                    id: "local-1".into(),
                    title: "Scratch".into(),
                    etag: None,
                    updated: "2026-01-01T00:00:00Z".into(),
                },
                sync_state: SyncState::Clean,
                local_updated: "2026-01-01T00:00:00Z".into(),
                pending_op: None,
                local_only: true,
            })
            .await
            .unwrap();
        eng.store
            .upsert_task(&dirty_task("local-task", "local-1", "create"))
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0, "nothing from a local-only list is pushed");
        // The list never appears on the server.
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.title != "Scratch")
        );
        // The task stays local and dirty (still awaiting nothing — it's local-only).
        let tasks = eng.store.list_tasks("local-1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.id, "local-task");
    }

    // ─── §G — local `create` × remote (RFC-009), P2 ──────────────────────────

    /// Where the row lives now, as the user would see it: `(list_id, parent)`.
    async fn placement(eng: &SyncEngine, id: &str) -> Option<(String, Option<String>)> {
        eng.store
            .find_task_any(id)
            .await
            .unwrap()
            .map(|r| (r.list_id, r.task.parent))
    }

    #[tokio::test]
    async fn create_in_remotely_deleted_list_rehomes_to_default_list_still_dirty() {
        // §G3 / D2. The user adds a task to "Work" offline; another device
        // deletes "Work" before the create ever reaches the server. The list
        // goes, but the row the server never saw must NOT go with it (P2): it
        // re-homes to the default list, still queued, and lands next run.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Work");
        eng.run().await.unwrap();

        let mut row = dirty_task("local-1", "L2", "create");
        row.task.title = "buy milk".into();
        eng.store.upsert_task(&row).await.unwrap();
        client.delete_tasklist("L2").await.unwrap();

        eng.run().await.unwrap();

        assert!(
            eng.store
                .all_lists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.list.id != "L2"),
            "the remotely-deleted list is gone locally"
        );
        assert_eq!(
            placement(&eng, "local-1").await,
            Some(("L1".into(), None)),
            "the unpushed create re-homed to the default list instead of dying"
        );
        let row = eng.store.find_task_any("local-1").await.unwrap().unwrap();
        assert_eq!(row.sync_state, SyncState::Dirty);
        assert_eq!(row.pending_op.as_deref(), Some("create"), "still queued");
        assert_eq!(row.task.title, "buy milk", "content untouched");

        // Still syncs: the next run pushes it into its new home.
        let out = eng.run().await.unwrap();
        assert!(out.pushed >= 1);
        assert!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .iter()
                .any(|t| t.title == "buy milk"),
            "the re-homed create lands on the server"
        );
        // And converges: the third run is a no-op (P7).
        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0);
        assert_eq!(out.errors, 0);
    }

    #[tokio::test]
    async fn rehome_keeps_an_unpushed_subtree_together_but_the_orphan_dies_with_its_parent() {
        // D2's non-happy path: the dying list holds a whole unpushed subtree
        // AND an unpushed subtask of a SYNCED parent. The subtree re-homes
        // intact (parent + child, still one level); the orphan — whose parent
        // dies with the list, since the server knows it (P1) — dies WITH its
        // parent in the list cascade rather than being promoted (D3 rejected:
        // the parent bond outranks P2).
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Work");
        client.seed_task("L2", "SYNCED", "server parent", "1");
        eng.run().await.unwrap();

        // Unpushed parent + its unpushed child. Held so neither is pushed
        // before the list dies (this is the "created while offline" shape).
        let mut parent = dirty_task("local-parent", "L2", "create");
        parent.task.title = "trip".into();
        eng.store.upsert_task(&parent).await.unwrap();
        let mut child = dirty_task("local-child", "L2", "create");
        child.task.title = "pack".into();
        child.task.parent = Some("local-parent".into());
        eng.store.upsert_task(&child).await.unwrap();
        // An unpushed subtask of the SYNCED parent.
        let mut orphan = dirty_task("local-orphan", "L2", "create");
        orphan.task.title = "call hotel".into();
        orphan.task.parent = Some("SYNCED".into());
        eng.store.upsert_task(&orphan).await.unwrap();

        client.delete_tasklist("L2").await.unwrap();
        eng.run().await.unwrap();

        assert_eq!(
            placement(&eng, "local-parent").await,
            Some(("L1".into(), None))
        );
        assert_eq!(
            placement(&eng, "local-child").await,
            Some(("L1".into(), Some("local-parent".into()))),
            "the unpushed subtree re-homes intact"
        );
        assert!(
            eng.store
                .find_task_any("local-orphan")
                .await
                .unwrap()
                .is_none(),
            "a subtask whose synced parent died dies with it — never promoted (D3 rejected)"
        );
        assert!(
            eng.store.find_task_any("SYNCED").await.unwrap().is_none(),
            "the row the server knew dies with its list (P1)"
        );

        // Only the subtree survives, still one level deep (invariant #1), and
        // it converges — the orphan's death leaves no wedge behind.
        eng.run().await.unwrap();
        let rows = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(
            rows.len(),
            2,
            "the orphan is gone; only the subtree remains"
        );
        assert!(rows.iter().all(|r| r.sync_state == SyncState::Clean));
        assert!(
            rows.iter().all(|r| r.task.title != "call hotel"),
            "the orphaned subtask never comes back as a row"
        );
        let parent_id = rows
            .iter()
            .find(|r| r.task.title == "trip")
            .unwrap()
            .task
            .id
            .clone();
        assert_eq!(
            rows.iter()
                .find(|r| r.task.title == "pack")
                .unwrap()
                .task
                .parent
                .as_deref(),
            Some(parent_id.as_str()),
            "the child follows its re-homed parent's remapped id"
        );
    }

    #[tokio::test]
    async fn rehome_with_nowhere_to_go_keeps_the_list_as_an_unpushed_create() {
        // D2's boundary: the ONLY list is deleted remotely while it still holds
        // an unpushed create. There is nowhere to re-home to, so the list is
        // kept as a local list create instead of being dropped — P2 holds even
        // then, and the next run re-creates the list and pushes the row.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Work");
        eng.run().await.unwrap();

        let mut row = dirty_task("local-1", "L1", "create");
        row.task.title = "nowhere to go".into();
        eng.store.upsert_task(&row).await.unwrap();
        client.delete_tasklist("L1").await.unwrap();

        eng.run().await.unwrap();
        let l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.title == "Work")
            .expect("the list is kept, not dropped");
        assert_eq!(l.sync_state, SyncState::Dirty);
        assert_eq!(l.pending_op.as_deref(), Some("create"));
        assert_eq!(
            placement(&eng, "local-1").await.map(|p| p.1),
            Some(None),
            "the unpushed row is still there"
        );

        // Next run: the list is re-created on the server and the row lands.
        eng.run().await.unwrap();
        let lists = client.list_tasklists().await.unwrap();
        let work = lists
            .iter()
            .find(|l| l.title == "Work")
            .expect("list re-created on the server");
        assert!(
            client
                .list_tasks(&work.id, None)
                .await
                .unwrap()
                .items
                .iter()
                .any(|t| t.title == "nowhere to go")
        );
        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0, "converged (P7)");
        assert_eq!(out.errors, 0);
    }

    #[tokio::test]
    async fn edited_parent_deleted_remotely_takes_its_unpushed_subtask_with_it() {
        // The delete-wins cascade reached through the update path: we push an
        // edit to a parent the server already deleted (404 → delete-wins, P4),
        // and its FK cascade takes the unpushed subtask with it. D3 rejected:
        // the child dies with the parent — never promoted (the parent bond
        // outranks P2, exactly like the user's own delete, invariant #3).
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_task("L1", "P", "parent", "1");
        eng.run().await.unwrap();

        stage_edit(&eng, "P", false, |r| r.task.title = "renamed here".into()).await;
        let mut child = dirty_task("local-kid", "L1", "create");
        child.task.title = "kept".into();
        child.task.parent = Some("P".into());
        eng.store.upsert_task(&child).await.unwrap();
        client.delete_task_from_state("L1", "P");

        eng.run().await.unwrap();

        assert!(
            eng.store.find_task_any("P").await.unwrap().is_none(),
            "delete wins over our edit (P4)"
        );
        assert!(
            eng.store
                .find_task_any("local-kid")
                .await
                .unwrap()
                .is_none(),
            "the unpushed subtask dies with its parent — never promoted (D3 rejected)"
        );
        // No wedge: nothing lingers to push, and the child never reaches the
        // server as a stray top-level row.
        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0, "converged (P7)");
        assert_eq!(out.errors, 0);
        assert!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .iter()
                .all(|t| t.title != "kept"),
            "the dead child never lands on the server"
        );
    }

    #[tokio::test]
    async fn synced_row_in_remotely_deleted_list_dies_with_the_list() {
        // D2's boundary (P1/P4): a row the server HAS seen dies with its list
        // even with a local edit pending. P2 only shields work the server has
        // never seen — it is not a general "never delete a dirty row" rule.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Work");
        client.seed_task("L2", "T2", "server row", "1");
        eng.run().await.unwrap();

        stage_edit(&eng, "T2", false, |r| r.task.title = "edited here".into()).await;
        client.delete_tasklist("L2").await.unwrap();

        eng.run().await.unwrap();

        assert!(
            eng.store.find_task_any("T2").await.unwrap().is_none(),
            "the synced row dies with its list, edit discarded"
        );
        assert!(
            eng.store.list_tasks("L1").await.unwrap().is_empty(),
            "and it is NOT re-homed into the default list"
        );
    }

    #[tokio::test]
    async fn subtask_create_parent_deleted_remotely_dies_with_its_parent() {
        // §G / D3 (REJECTED by user). The user adds a subtask; another device
        // deletes its parent before the create lands. The parent's local
        // removal FK-cascades the unpushed child away — the child shares its
        // parent's fate, exactly like the user's own delete (invariant #3).
        // No auto-promotion: the child never becomes a stray top-level row,
        // and the dead-parent insert never survives to wedge the queue.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_task("L1", "P", "parent", "1");
        eng.run().await.unwrap();

        let mut child = dirty_task("local-kid", "L1", "create");
        child.task.title = "orphaned subtask".into();
        child.task.parent = Some("P".into());
        eng.store.upsert_task(&child).await.unwrap();

        client.delete_task_from_state("L1", "P");
        eng.run().await.unwrap();

        assert!(
            eng.store.find_task_any("P").await.unwrap().is_none(),
            "the remotely-deleted parent is gone locally"
        );
        assert!(
            eng.store
                .find_task_any("local-kid")
                .await
                .unwrap()
                .is_none(),
            "the unpushed child dies with its parent — never promoted (D3 rejected)"
        );

        // No wedge and nothing lands: the queue is empty and the server never
        // sees the dead child.
        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0, "converged (P7)");
        assert_eq!(out.errors, 0);
        let remote = client.list_tasks("L1", None).await.unwrap().items;
        assert!(
            remote.iter().all(|t| t.title != "orphaned subtask"),
            "the dead child never reaches the server"
        );
    }

    #[tokio::test]
    async fn subtask_create_parent_completed_remotely_converges_no_wedge() {
        // §G × parent completed remotely. Probe 5: the insert is ACCEPTED and
        // the child is created already completed — the cascade is Google's, not
        // ours. The row must converge to `completed` locally in the same run
        // (P6: an adopted etag with stale content would freeze the row out of
        // every future pull), and must not wedge or error.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_task("L1", "P", "parent", "1");
        eng.run().await.unwrap();

        client
            .patch_task(
                "L1",
                "P",
                TaskPatch {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        let mut child = dirty_task("local-kid", "L1", "create");
        child.task.title = "late subtask".into();
        child.task.parent = Some("P".into());
        eng.store.upsert_task(&child).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "the insert is accepted, not rejected");
        let row = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|r| r.task.title == "late subtask")
            .expect("the subtask exists locally");
        assert_eq!(row.task.parent.as_deref(), Some("P"), "still a subtask");
        assert_eq!(
            row.task.status,
            TaskStatus::Completed,
            "Google's cascade completed it; local mirrors the server (P6)"
        );
        assert_eq!(row.sync_state, SyncState::Clean);

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0, "converged (P7)");
        assert_eq!(out.errors, 0);
    }

    #[tokio::test]
    async fn create_racing_identical_remote_create_both_live_no_content_dedup() {
        // §G. In-flight adoption is scoped to rows behind an in-flight marker.
        // A local create that merely LOOKS like a remote task (same title, no
        // marker) must not be swallowed by it — duplicate titles are legal.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        eng.run().await.unwrap();

        // Someone else creates "buy milk" remotely; we create our own.
        client.seed_task("L1", "remote-theirs", "buy milk", "1");
        let mut mine = dirty_task("local-mine", "L1", "create");
        mine.task.title = "buy milk".into();
        eng.store.upsert_task(&mine).await.unwrap();

        eng.run().await.unwrap();

        let titles: Vec<_> = eng
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .map(|r| r.task.title)
            .collect();
        assert_eq!(
            titles.iter().filter(|t| *t == "buy milk").count(),
            2,
            "both tasks live — adoption is not content dedup"
        );
        assert_eq!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .iter()
                .filter(|t| t.title == "buy milk")
                .count(),
            2,
            "and both exist on the server"
        );
    }

    #[tokio::test]
    async fn held_create_survives_remote_list_delete_and_pushes_after_release() {
        // §G × held create. The row the UI is holding is not pushed this run —
        // and a remote list delete in the same window must not destroy it
        // either (P2). It re-homes, waits for the hold to clear, then pushes.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Work");
        eng.run().await.unwrap();

        let mut held = dirty_task("local-held", "L2", "create");
        held.task.title = "held row".into();
        eng.store.upsert_task(&held).await.unwrap();
        client.delete_tasklist("L2").await.unwrap();

        let eng_hold = SyncEngine::with_push(client.clone(), eng.store.clone(), true)
            .hold_create_id(Some("local-held".into()));
        let out = eng_hold.run().await.unwrap();
        assert_eq!(out.pushed, 0, "the held create does not push");
        assert_eq!(
            placement(&eng, "local-held").await,
            Some(("L1".into(), None)),
            "but it survives the list delete, re-homed"
        );
        assert_eq!(
            eng.store
                .find_task_any("local-held")
                .await
                .unwrap()
                .unwrap()
                .task
                .id,
            "local-held",
            "id not remapped while held — the UI still holds it"
        );

        // Released: it pushes.
        let out = eng.run().await.unwrap();
        assert!(out.pushed >= 1);
        assert!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .iter()
                .any(|t| t.title == "held row")
        );
    }

    #[tokio::test]
    async fn crash_between_rehome_and_push_converges_no_duplicate() {
        // P8 over the new path: the row re-homes, its insert commits on the
        // server, and the response is lost. The in-flight marker must survive
        // the re-home (its own list_id pointed at the list that just died), so
        // the next run adopts the orphan instead of inserting a second copy.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Work");
        eng.run().await.unwrap();

        let mut row = dirty_task("local-1", "L2", "create");
        row.task.title = "survive me".into();
        eng.store.upsert_task(&row).await.unwrap();
        client.delete_tasklist("L2").await.unwrap();

        // Run 1: insert into the dead list fails; the pull re-homes the row.
        eng.run().await.unwrap();
        assert_eq!(
            placement(&eng, "local-1").await,
            Some(("L1".into(), None)),
            "re-homed"
        );

        // Run 2: the insert commits but the response is lost (crash window).
        client.commit_then_fail_next_insert();
        eng.run().await.unwrap();

        // Run 3: recovery adopts the orphan — exactly one copy on each side.
        eng.run().await.unwrap();
        assert_eq!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .iter()
                .filter(|t| t.title == "survive me")
                .count(),
            1,
            "no duplicate on the server"
        );
        let local = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(local.len(), 1);
        assert_eq!(local[0].sync_state, SyncState::Clean);
        assert!(local[0].task.etag.is_some(), "adopted the server's row");
    }

    // ─── RFC-009 §I matrix: local list ops × remote ──────────────────────────
    //
    // One test per row of §I. Lists have no conflict machinery at all: probe 8
    // (#106) established that `patch_tasklist` IGNORES `If-Match` — a stale
    // etag still returns 200 — so a rename can never 412 and there is nothing
    // to fork a "(conflicted copy)" from. D6 (remote wins, no copy) is what
    // that server design forces, and these tests pin the convergence it has to
    // produce in both serializations.

    /// Every list title the local store would show in the sidebar. Tombstoned
    /// lists are excluded by `all_lists`, exactly as the UI sees them.
    async fn sidebar(eng: &SyncEngine) -> Vec<String> {
        let mut titles: Vec<String> = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .map(|l| l.list.title)
            .collect();
        titles.sort();
        titles
    }

    /// Mark a synced list deleted the way `AppState::delete_list` does: local
    /// task rows go immediately, the list becomes a tombstone to push.
    async fn tombstone_list(eng: &SyncEngine, id: &str) {
        for t in eng.store.list_tasks(id).await.unwrap() {
            eng.store.delete_task_hard(&t.task.id).await.unwrap();
        }
        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == id)
            .expect("list to tombstone");
        l.sync_state = SyncState::Deleted;
        l.pending_op = Some("delete".into());
        eng.store.upsert_list(&l).await.unwrap();
    }

    #[tokio::test]
    async fn a_list_rename_race_lands_last_writer_wins_with_no_conflicted_copy() {
        // §I × remote rename, D6 (RATIFIED). Two devices rename the same list
        // in the same window. The tasklists endpoint has no precondition, so
        // our PATCH lands over theirs (last writer wins) — and, crucially, the
        // outcome is ONE list, not a forked copy: the sidebar never grows a
        // second entry out of a rename race, and the run converges (P7).
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Work");
        client.seed_task("L1", "T1", "ship it", "1");
        eng.run().await.unwrap();

        // Local rename, still unpushed.
        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.list.title = "Job".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();
        // The other device renames it too, bumping the list's etag.
        client.patch_tasklist("L1", "Career").await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "no 412 is possible on a tasklist");
        assert_eq!(out.conflicts, 0, "and no conflicted copy is ever forked");

        assert_eq!(
            sidebar(&eng).await,
            vec!["Job"],
            "one list, carrying the last write"
        );
        let remote = client.list_tasklists().await.unwrap();
        assert_eq!(remote.len(), 1, "no duplicate list on the server either");
        assert_eq!(remote[0].title, "Job");
        // The list's tasks are untouched by the rename race.
        assert_eq!(
            eng.store
                .list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .map(|t| t.task.title.clone())
                .collect::<Vec<_>>(),
            vec!["ship it"]
        );

        let out = eng.run().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P7)");
    }

    #[tokio::test]
    async fn a_remote_rename_after_ours_landed_wins_on_the_next_pull() {
        // §I × remote rename, the other serialization — the remote write is
        // the last one. D6: remote wins, silently. The local title is replaced
        // with no copy, no error and no "your rename was overwritten" state to
        // clean up, and the row stays clean so nothing re-pushes the old title.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Work");
        eng.run().await.unwrap();

        let mut l = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        l.list.title = "Job".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();
        eng.run().await.unwrap();
        assert_eq!(sidebar(&eng).await, vec!["Job"], "our rename landed");

        // Only now does the other device rename it.
        client.patch_tasklist("L1", "Career").await.unwrap();
        let out = eng.run().await.unwrap();

        assert_eq!(sidebar(&eng).await, vec!["Career"], "remote wins (D6)");
        assert_eq!(out.conflicts, 0);
        assert_eq!(out.errors, 0);
        assert!(out.lists_changed, "the sidebar is told to refresh");
        let stored = eng
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        assert_eq!(stored.sync_state, SyncState::Clean, "nothing left to push");

        let out = eng.run().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P7)");
    }

    #[tokio::test]
    async fn a_locally_deleted_list_takes_remotely_added_tasks_with_it() {
        // §I × remote added tasks to the list meanwhile. Google's list delete
        // cascades server-side (P4), so a task another device dropped into the
        // list in our delete window dies with it. Accepted: the user asked for
        // the list to go. What must NOT happen is a local orphan — a row in a
        // list that no longer exists, invisible in every view and undeletable.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Doomed");
        client.seed_task("L2", "T1", "old row", "1");
        eng.run().await.unwrap();

        tombstone_list(&eng, "L2").await;
        // Another device adds a task to the list we are deleting.
        client.seed_task("L2", "T2", "added elsewhere", "2");

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(sidebar(&eng).await, vec!["My Tasks"], "the list is gone");
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.id != "L2"),
            "and gone on the server"
        );
        assert!(
            client
                .list_tasks("L2", None)
                .await
                .unwrap()
                .items
                .is_empty(),
            "the server cascaded its tasks, including the one added late"
        );
        assert!(
            eng.store.find_task_any("T2").await.unwrap().is_none(),
            "the remote-born row never lands as a local orphan"
        );
        assert!(eng.store.find_task_any("T1").await.unwrap().is_none());

        let out = eng.run().await.unwrap();
        assert_eq!((out.pushed, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    #[tokio::test]
    async fn a_pending_list_delete_hides_the_list_while_the_push_retries() {
        // §I × remote added tasks, non-happy path: the delete push hits a
        // transient, so the tombstone survives a whole run in which the pull
        // still sees the list AND the task added to it remotely. Neither may
        // come back: `all_lists` (what the sidebar and every smart view iterate
        // over) must not show the list, so nothing it holds is reachable.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Doomed");
        eng.run().await.unwrap();

        tombstone_list(&eng, "L2").await;
        client.seed_task("L2", "T2", "added elsewhere", "1");
        client.fail_next(crate::api::in_memory::Method::DeleteTaskList, || {
            ApiError::Server { status: 503 }
        });

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "a transient is not an error");
        assert_eq!(
            sidebar(&eng).await,
            vec!["My Tasks"],
            "the deleted list stays hidden while its delete retries"
        );
        // Every task the UI can reach = the tasks of the lists it renders.
        let mut visible: Vec<String> = Vec::new();
        for l in eng.store.all_lists().await.unwrap() {
            for t in eng.store.list_tasks(&l.list.id).await.unwrap() {
                visible.push(t.task.title);
            }
        }
        assert!(
            visible.is_empty(),
            "nothing from the dying list is reachable: {visible:?}"
        );

        // Next run: the retry lands and both sides converge.
        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.id != "L2"),
            "the delete finally lands"
        );
        assert!(eng.store.find_task_any("T2").await.unwrap().is_none());
        let out = eng.run().await.unwrap();
        assert_eq!((out.pushed, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    #[tokio::test]
    async fn a_list_delete_that_already_happened_remotely_is_a_success() {
        // §I × already deleted remotely. The 404 is the outcome we wanted, so
        // it clears the tombstone instead of counting an error or nagging on
        // every future run.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Doomed");
        eng.run().await.unwrap();

        tombstone_list(&eng, "L2").await;
        client.delete_list_from_state("L2");

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0, "a 404 on a delete is success, not failure");
        assert_eq!(sidebar(&eng).await, vec!["My Tasks"]);
        assert!(
            eng.store
                .drain_dirty_lists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.list.id != "L2"),
            "no tombstone left to retry forever"
        );
        let out = eng.run().await.unwrap();
        assert_eq!((out.pushed, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    #[tokio::test]
    async fn a_local_list_create_adopts_a_same_title_list_created_remotely() {
        // §I × remote created a list with the same title (the two-device
        // "Groceries" race, and the offline "My Tasks" bootstrap). The create
        // adopts the remote list instead of inserting a duplicate — and the
        // tasks queued in the local list follow it onto the adopted id, which
        // is the part a plain id remap could silently drop.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L-remote", "Groceries");
        eng.store
            .upsert_list(&dirty_list("local-list", "Groceries", "create"))
            .await
            .unwrap();
        let mut t = dirty_task("local-task", "local-list", "create");
        t.task.title = "milk".into();
        eng.store.upsert_task(&t).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(sidebar(&eng).await, vec!["Groceries"], "exactly one list");
        assert_eq!(
            client.list_tasklists().await.unwrap().len(),
            1,
            "no duplicate list was created on the server"
        );
        assert_eq!(
            eng.store
                .list_tasks("L-remote")
                .await
                .unwrap()
                .iter()
                .map(|t| t.task.title.clone())
                .collect::<Vec<_>>(),
            vec!["milk"],
            "the queued task followed the list onto the adopted id"
        );
        assert!(
            client
                .list_tasks("L-remote", None)
                .await
                .unwrap()
                .items
                .iter()
                .any(|t| t.title == "milk"),
            "and it pushed into the adopted list, not a dead local id"
        );
        let out = eng.run().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P7)");
    }

    // ─── RFC-009 §A: completed / auto-hidden rows survive the pull ───────────

    #[tokio::test]
    async fn a_task_completed_remotely_is_pulled_not_ghost_deleted() {
        // §A × completed (and, live, auto-hidden by Google some time later).
        // The pull asks for `showCompleted=true&showHidden=true`
        // (`list_tasks_asks_for_completed_and_hidden_tasks` pins the wire), so
        // such a row stays in the remote view and ghost detection leaves it
        // alone. If it ever dropped out, the local row would be DELETED —
        // silently eating the user's completed history rather than showing it
        // ticked.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Work");
        client.seed_task("L1", "T1", "file taxes", "1");
        eng.run().await.unwrap();

        // Another device ticks it off.
        client
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 0, "a completed row is not a ghost");
        let rows = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(rows.len(), 1, "the row is still there");
        assert_eq!(rows[0].task.title, "file taxes");
        assert_eq!(
            rows[0].task.status,
            TaskStatus::Completed,
            "and it shows as done"
        );
        assert_eq!(rows[0].sync_state, SyncState::Clean);

        let out = eng.run().await.unwrap();
        assert_eq!((out.pulled, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    #[tokio::test]
    async fn a_completed_subtask_survives_the_pull_still_attached() {
        // §A × completed, non-happy variant: the hidden row is a SUBTASK of an
        // open parent. Ghost-deleting it would empty the detail panel of a task
        // the user completed, and detaching it would promote a subtask into a
        // list row (invariant #1). It must stay exactly where it was, done.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Work");
        client.seed_task("L1", "P", "trip", "1");
        client.seed_task_with_parent("L1", "C", "pack", "2", Some("P"));
        eng.run().await.unwrap();

        client
            .patch_task(
                "L1",
                "C",
                TaskPatch {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 0);
        let rows = eng.store.list_tasks("L1").await.unwrap();
        let child = rows
            .iter()
            .find(|r| r.task.id == "C")
            .expect("the completed subtask survives the pull");
        assert_eq!(child.task.status, TaskStatus::Completed);
        assert_eq!(
            child.task.parent.as_deref(),
            Some("P"),
            "still a subtask — never promoted to a list row (invariant #1)"
        );
        assert_eq!(
            rows.iter().find(|r| r.task.id == "P").unwrap().task.status,
            TaskStatus::NeedsAction,
            "completing a child does not touch the parent"
        );
    }
}
