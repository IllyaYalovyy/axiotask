//! Sync engine: push local changes, pull remote changes, resolve conflicts.
//!
//! Design: RFC-004. Single entry point [`SyncEngine::run`].
//! All conflict resolution follows "remote wins" for MVP.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tracing::{debug, info, warn};

use super::SyncError;
use crate::api::{ApiError, GoogleTasksClient};
use crate::model::{NewTask, Task, TaskList, TaskPatch};
use crate::store::{Store, StoredTask, StoredTaskList, SyncState};

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
        self.recover_inflight_creates().await?;

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
                    if row.pending_op.as_deref() != Some("create")
                        || attempted.contains(&row.task.id)
                        || self.config.held_create_id.as_deref() == Some(row.task.id.as_str())
                    {
                        continue;
                    }
                    let parent_resolved = match &row.task.parent {
                        None => true,
                        Some(pid) => self
                            .store
                            .find_task_any(pid)
                            .await?
                            .is_some_and(|p| p.task.etag.is_some()),
                    };
                    if !parent_resolved {
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

        // Updates and deletes (always pushed — they reuse existing ids).
        for row in &self.store.drain_dirty().await? {
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

    /// Classify a push failure for one row. Transient errors leave the row
    /// dirty for the next run. A server rejection (400 & co.) also leaves the
    /// row dirty but is counted and logged — it must not abort the run, or one
    /// poisoned row would permanently starve every other push AND the pull.
    /// Only auth failures propagate: every subsequent call would fail the same
    /// way, so aborting is correct.
    fn row_push_failure(
        e: ApiError,
        out: &mut SyncOutcome,
        id: &str,
        op: &str,
    ) -> Result<(), SyncError> {
        if e.is_transient() {
            warn!(id, err = %e, "transient error on {op}, will retry");
            return Ok(());
        }
        if matches!(e, ApiError::Unauthorized | ApiError::AuthExpired(_)) {
            return Err(e.into());
        }
        warn!(id, err = %e, "server rejected {op}; row stays dirty, continuing");
        out.errors += 1;
        Ok(())
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
            if let Some(existing) = remote
                .iter()
                .find(|r| r.title == l.list.title && !local_ids.contains(&r.id))
            {
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
                    Err(ApiError::NotFound) => {
                        self.store.delete_list_hard(&l.list.id).await?;
                        out.lists_changed = true;
                    }
                    Err(e) => Self::row_push_failure(e, out, &l.list.id, "list rename")?,
                },
                Some("delete") => match self.client.delete_tasklist(&l.list.id).await {
                    Ok(()) | Err(ApiError::NotFound) => {
                        self.store.delete_list_hard(&l.list.id).await?;
                        out.deleted += 1;
                        out.lists_changed = true;
                    }
                    Err(e) if e.is_transient() => {
                        warn!(err = %e, "transient on list delete, retry");
                    }
                    Err(e @ (ApiError::Unauthorized | ApiError::AuthExpired(_))) => {
                        return Err(e.into());
                    }
                    Err(e) => {
                        // Permanently refused — Google will not delete an
                        // account's default list, for example. A tombstone that
                        // can never push would error on every run forever;
                        // revive the list instead (its tasks re-pull) and tell
                        // the user via the error count.
                        warn!(id = %l.list.id, err = %e, "list delete refused by server; restoring list");
                        out.errors += 1;
                        let mut revived = l.clone();
                        revived.sync_state = SyncState::Clean;
                        revived.pending_op = None;
                        self.store.upsert_list(&revived).await?;
                        out.lists_changed = true;
                    }
                },
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
    async fn recover_inflight_creates(&self) -> Result<(), SyncError> {
        let inflight = self.store.inflight_creates().await?;
        for (local_id, list_id) in inflight {
            let local = self
                .store
                .list_tasks(&list_id)
                .await?
                .into_iter()
                .find(|t| t.task.id == local_id);
            let Some(local) = local else {
                // Local task gone (e.g. user deleted it) — drop the marker.
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
            let orphan = remote
                .iter()
                .find(|r| !local_id_set.contains(&r.id) && same_content(&local.task, r));

            match orphan {
                Some(o) => {
                    info!(local_id = %local_id, remote_id = %o.id, "adopting orphaned create after crash");
                    self.store
                        .finish_create(
                            &local_id,
                            &o.id,
                            o.etag.as_deref(),
                            &o.updated,
                            &local.local_updated,
                            Some(&o.position),
                        )
                        .await?;
                }
                None => {
                    // Insert never reached the server — let normal push retry.
                    self.store.clear_inflight_create(&local_id).await?;
                }
            }
        }
        Ok(())
    }

    /// Whether an id referenced by a pending move is safe to send: `None`
    /// (no constraint) or a task that exists locally with a server etag.
    async fn task_is_synced(&self, id: Option<&str>) -> Result<bool, SyncError> {
        match id {
            None => Ok(true),
            Some(i) => Ok(self
                .store
                .find_task_any(i)
                .await?
                .is_some_and(|t| t.task.etag.is_some())),
        }
    }

    /// Push pending position/parent moves via the Tasks move endpoint.
    async fn push_moves(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        for mv in self.store.pending_moves().await? {
            // A move whose task (or target parent/previous) hasn't been pushed
            // yet still carries a local UUID — the API answers 400 "Invalid
            // task ID" (verified live), which would drop the user's reordering.
            // Hold the intent; finish_create rewrites the ids when the create
            // lands, and the move pushes on that run or the next.
            if !self.task_is_synced(Some(&mv.task_id)).await?
                || !self.task_is_synced(mv.parent_id.as_deref()).await?
                || !self.task_is_synced(mv.previous_id.as_deref()).await?
            {
                debug!(id = %mv.task_id, "move waits for its ids to be synced");
                continue;
            }
            match self
                .client
                .move_task(
                    &mv.list_id,
                    &mv.task_id,
                    mv.parent_id.as_deref(),
                    mv.previous_id.as_deref(),
                )
                .await
            {
                Ok(remote) => {
                    // Meta only: the move endpoint hands back a fresh etag, but
                    // the row may carry an unrelated pending content edit whose
                    // dirty flag must survive the move completing.
                    self.store
                        .refresh_task_meta(&remote.id, remote.etag.as_deref(), &remote.updated)
                        .await?;
                    self.store.clear_move(&mv.task_id).await?;
                    out.pushed += 1;
                    debug!(id = %mv.task_id, "pushed move");
                }
                // Task gone on server — drop the stale move intent.
                Err(ApiError::NotFound) => {
                    self.store.clear_move(&mv.task_id).await?;
                    debug!(id = %mv.task_id, "move target gone, dropping move");
                }
                Err(e) if e.is_transient() => {
                    warn!(err = %e, "transient error on move, will retry");
                }
                Err(e) => {
                    // A rejected move must not starve the rest of the queue;
                    // drop the intent (positions self-heal on the next pull).
                    Self::row_push_failure(e, out, &mv.task_id, "move")?;
                    self.store.clear_move(&mv.task_id).await?;
                }
            }
        }
        Ok(())
    }

    async fn push_create(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        // For a SUBTASK, anchor the insert after its last already-synced
        // sibling: without `previous` the API inserts at the top, so a batch
        // of subtasks lands on Google in reverse creation order.
        let previous = match &row.task.parent {
            None => None,
            Some(pid) => self
                .store
                .list_tasks(&row.list_id)
                .await?
                .into_iter()
                .filter(|t| {
                    t.task.parent.as_deref() == Some(pid)
                        && t.task.id != row.task.id
                        && t.task.etag.is_some()
                })
                .max_by(|a, b| a.task.position.cmp(&b.task.position))
                .map(|t| t.task.id),
        };
        let payload = NewTask {
            title: row.task.title.clone(),
            notes: row.task.notes.clone(),
            // Canonicalize on the way out: Google 400s a bare date, and heals
            // any legacy/imported row that stored a non-canonical form.
            due: row
                .task
                .due
                .as_deref()
                .and_then(crate::dates::normalize_due),
            status: Some(row.task.status),
            parent: row.task.parent.clone(),
            previous,
        };
        // Durably mark in-flight BEFORE the non-idempotent insert.
        self.store
            .record_inflight_create(&row.task.id, &row.list_id)
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
            Err(e) if e.is_transient() => {
                // Insert may or may not have reached the server. The in-flight
                // marker lets the next run adopt an orphan instead of dup'ing.
                warn!(err = %e, "transient error on create, will retry");
                Ok(())
            }
            Err(e) => {
                self.store.clear_inflight_create(&row.task.id).await?;
                Self::row_push_failure(e, out, &row.task.id, "create")
            }
        }
    }

    async fn push_update(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let patch = TaskPatch {
            title: Some(row.task.title.clone()),
            notes: row.task.notes.clone().or(Some(String::new())),
            // Canonical form, or "" to clear — both verified against the live
            // API ("" clears; a bare date 400s). An unparseable stored due
            // degrades to clear rather than poisoning the row forever.
            due: Some(
                row.task
                    .due
                    .as_deref()
                    .and_then(crate::dates::normalize_due)
                    .unwrap_or_default(),
            ),
            status: Some(row.task.status),
        };
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
            Err(ApiError::PreconditionFailed) => self.resolve_conflict(row, out).await,
            Err(ApiError::NotFound) => {
                debug!(id = %row.task.id, "task gone from server, deleting locally");
                self.store.delete_task_hard(&row.task.id).await?;
                out.mark_list_changed(&row.list_id);
                Ok(())
            }
            Err(e) => Self::row_push_failure(e, out, &row.task.id, "update"),
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
            // Server deleted it; mirror the push_update NotFound behavior.
            Err(ApiError::NotFound) => {
                self.store.delete_task_hard(&local.task.id).await?;
                return Ok(());
            }
            Err(e) if e.is_transient() => return Ok(()), // stays dirty, retry
            Err(e) => return Err(e.into()),
        };

        // Adopt the remote wholesale if the content is already identical (no
        // real divergence — just normalization/etag drift to absorb).
        if same_content(&local.task, &remote) {
            self.store
                .apply_pushed_task(&remote, &local.local_updated)
                .await?;
            out.mark_list_changed(&local.list_id);
            return Ok(());
        }

        // Real conflict: remote becomes canonical, local edit survives as a copy.
        info!(id = %local.task.id, "412 conflict — preserving local edit as conflicted copy");
        out.conflicts += 1;

        let canonical = StoredTask {
            task: remote.clone(),
            list_id: local.list_id.clone(),
            sync_state: SyncState::Clean,
            pending_op: None,
            local_updated: remote.updated.clone(),
        };
        self.store.upsert_task(&canonical).await?;

        let copy = StoredTask {
            task: Task {
                id: uuid::Uuid::new_v4().to_string(),
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
        };
        self.store.upsert_task(&copy).await?;
        out.mark_list_changed(&local.list_id);
        Ok(())
    }

    async fn push_delete(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        match self.client.delete_task(&row.list_id, &row.task.id).await {
            Ok(()) | Err(ApiError::NotFound) => {
                self.store.delete_task_hard(&row.task.id).await?;
                out.deleted += 1;
                out.mark_list_changed(&row.list_id);
                debug!(id = %row.task.id, "pushed delete");
                Ok(())
            }
            Err(e) => Self::row_push_failure(e, out, &row.task.id, "delete"),
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
        for ghost in self
            .store
            .clean_list_ids()
            .await?
            .difference(&remote_list_ids)
        {
            debug!(id = %ghost, "removing ghost list");
            self.store.delete_list_hard_if_clean(ghost).await?;
            out.deleted += 1;
            out.lists_changed = true;
        }

        // Compute skip-set after push so remapped IDs are current.
        let dirty_ids = self.store.dirty_ids().await?;

        // In-flight creates: a remote task matching one of these by content is
        // the (possibly committed) result of an interrupted create. Don't pull
        // it as a new clean row — leave it for recover_inflight_creates to
        // adopt via id remap next run (avoids a duplicate / PK collision).
        let mut inflight_by_list: HashMap<String, Vec<Task>> = HashMap::new();
        for (local_id, list_id) in self.store.inflight_creates().await? {
            if let Some(t) = self.store.find_task_any(&local_id).await? {
                inflight_by_list.entry(list_id).or_default().push(t.task);
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
        inflight: &[Task],
        out: &mut SyncOutcome,
    ) -> Result<(), SyncError> {
        let (remote_tasks, complete) = self.fetch_all_tasks(&list.id).await?;

        let remote_ids: HashSet<String> = remote_tasks.iter().map(|t| t.id.clone()).collect();

        // Filter: skip dirty rows and orphans of in-flight creates.
        let to_upsert: Vec<_> = remote_tasks
            .into_iter()
            .filter(|t| !dirty_ids.contains(&t.id))
            .filter(|t| !inflight.iter().any(|f| same_content(f, t)))
            .collect();

        // Parents before children for FK safety — TOPOLOGICALLY, not by a
        // has-parent flag: the API allows nesting deeper than one level
        // (verified live), so among tasks that all have parents, a child can
        // otherwise land before its own parent and fail the FK.
        let to_upsert = order_parents_first(to_upsert);

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

        for mut task in to_upsert {
            if Self::is_up_to_date(&task.id, task.etag.as_deref(), &local_etags) {
                continue;
            }
            // A parent that is neither in this batch nor already local (its
            // row was skipped as dirty/in-flight, or it moved mid-pagination)
            // would fail the FK and abort the whole pull. Detach instead, and
            // drop the etag so the row is NOT etag-skipped next pull — it gets
            // re-processed and re-linked once the parent is present.
            if let Some(p) = &task.parent
                && !batch_ids.contains(p)
                && !known_local.contains(p)
            {
                warn!(id = %task.id, parent = %p, "pulled task's parent unknown; detaching until it appears");
                task.parent = None;
                task.etag = None;
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

        // Ghost detection: remove clean local rows absent from server.
        if complete {
            self.remove_ghosts(&list.id, &remote_ids, out).await?;
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

    /// Check if a remote task is already up-to-date locally.
    fn is_up_to_date(
        id: &str,
        remote_etag: Option<&str>,
        local_etags: &HashMap<String, Option<String>>,
    ) -> bool {
        match (local_etags.get(id), remote_etag) {
            (Some(Some(local)), Some(remote)) => local == remote,
            _ => false,
        }
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
            self.store.delete_task_hard_if_clean(ghost_id).await?;
            out.deleted += 1;
            out.mark_list_changed(list_id);
        }
        Ok(())
    }

    /// Reconcile one remote list into the local store.
    async fn upsert_list(&self, list: &TaskList) -> Result<bool, SyncError> {
        let locals = self.store.all_lists().await?;

        // Locally dirty list with the same id → preserve local intent (push will handle it).
        if locals
            .iter()
            .any(|l| l.list.id == list.id && l.sync_state != SyncState::Clean)
        {
            return Ok(false);
        }

        // Adopt a local-only create (no etag) with the same title — covers the
        // offline "My Tasks" bootstrap and any create that already landed.
        if let Some(orphan) = locals.iter().find(|l| {
            l.pending_op.as_deref() == Some("create")
                && l.list.etag.is_none()
                && l.list.title == list.title
        }) {
            self.store
                .remap_list_id(
                    &orphan.list.id,
                    &list.id,
                    list.etag.as_deref(),
                    &list.updated,
                )
                .await?;
            return Ok(true);
        }

        let changed = !locals.iter().any(|l| {
            l.list.id == list.id
                && l.list.title == list.title
                && l.list.etag == list.etag
                && l.list.updated == list.updated
                && !l.local_only
                && l.sync_state == SyncState::Clean
        });

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

/// Whether two tasks have identical user-visible content (the patchable
/// fields). Used to tell a real conflict from an identical concurrent edit,
/// and to adopt an orphaned create after a crash.
///
/// Comparison is normalization-tolerant, because Google canonicalizes what we
/// send: `due` always comes back as `YYYY-MM-DDT00:00:00.000Z` (a local
/// `...T00:00:00Z` is the same date), and cleared notes come back absent
/// (`None` ≡ `Some("")`). A raw string comparison here manufactures phantom
/// conflicts — the local edit gets duplicated as a "(conflicted copy)" even
/// though nothing diverged.
fn same_content(a: &Task, b: &Task) -> bool {
    let due = |t: &Task| t.due.as_deref().and_then(crate::dates::normalize_due);
    let notes = |t: &Task| t.notes.clone().filter(|n| !n.is_empty());
    a.title == b.title && notes(a) == notes(b) && due(a) == due(b) && a.status == b.status
}

/// Order a batch so every task appears after its parent (Kahn-style BFS from
/// the roots). A task whose parent is not in the batch counts as a root — the
/// parent already exists locally. Any leftover (a parent cycle, which the API
/// cannot produce but corrupt data could) is appended last rather than dropped.
fn order_parents_first(tasks: Vec<Task>) -> Vec<Task> {
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
    use crate::api::InMemoryClient;
    use crate::model::TaskStatus;
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
            .record_inflight_create("local-1", "L1")
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
            .record_inflight_create("local-1", "L1")
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
                .any(|t| t.task.title == "server-version" && t.sync_state == SyncState::Clean)
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

    #[tokio::test]
    async fn conflicted_copy_pushes_then_converges() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "server", "1");
        eng.run().await.unwrap();

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
    async fn push_update_412_then_server_gone_deletes_local() {
        // 412 then the task is deleted on the server before we fetch it.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "doomed", "1");
        eng.run().await.unwrap();

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "edit".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = Some("stale".into());
        eng.store.upsert_task(&local).await.unwrap();

        // patch → 412, then get_task → NotFound (server deleted it).
        client.delete_task_from_state("L1", "T1");

        eng.run().await.unwrap();
        // Local row dropped to mirror server.
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
                .any(|t| t.task.title == "server-version" && t.sync_state == SyncState::Clean)
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
    async fn push_update_not_found_deletes_local() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        let remote = client.seed_task("L1", "T1", "exists", "1");
        eng.run().await.unwrap();

        client.delete_task_from_state("L1", "T1");

        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "edited".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = remote.etag;
        eng.store.upsert_task(&local).await.unwrap();

        eng.run().await.unwrap();
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
            .record_inflight_create("local-1", "L1")
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
            .record_inflight_create("local-p", "L1")
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
}
