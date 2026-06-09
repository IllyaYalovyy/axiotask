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

/// Counters from a single sync run.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SyncOutcome {
    /// Tasks pulled from server (new or updated locally).
    pub pulled: u32,
    /// Tasks pushed to server.
    pub pushed: u32,
    /// Conflicts resolved (412 responses).
    pub conflicts: u32,
    /// Tasks hard-deleted locally (confirmed by server or ghost detection).
    pub deleted: u32,
}

/// Configuration for a sync engine instance.
#[derive(Default)]
pub struct SyncConfig {
    /// Whether to push local changes to the server.
    pub push_enabled: bool,
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
        Self { client, store, config: SyncConfig::default() }
    }

    /// Create with explicit configuration.
    pub fn with_push(client: Arc<dyn GoogleTasksClient>, store: Store, push_enabled: bool) -> Self {
        Self { client, store, config: SyncConfig { push_enabled } }
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
        // (with its remote id) before we push tasks into it.
        self.push_list_creates(out).await?;

        // First pass: push parentless creates. finish_create remaps child
        // references in DB so the second pass sees real parent ids.
        let dirty = self.store.drain_dirty().await?;
        let parent_creates: Vec<_> = dirty.iter()
            .filter(|r| r.pending_op.as_deref() == Some("create") && r.task.parent.is_none())
            .collect();

        for row in parent_creates {
            self.push_create(row, out).await?;
        }

        // Second pass: re-read DB for fresh parent_ids after remaps. Only
        // CHILD creates are pushed here — parentless creates were attempted
        // exactly once in pass 1. Re-attempting them here would double-insert
        // a create whose response timed out after the server committed it
        // (the in-flight recovery that dedups such orphans only runs at the
        // start of a run, not between passes).
        for row in &self.store.drain_dirty().await? {
            match row.pending_op.as_deref() {
                Some("create") if row.task.parent.is_some() => self.push_create(row, out).await?,
                Some("create") => {} // parentless: already attempted in pass 1
                Some("update") => self.push_update(row, out).await?,
                Some("delete") => self.push_delete(row, out).await?,
                _ => {}
            }
        }

        // Third pass: push position/parent moves via the move API.
        self.push_moves(out).await?;

        // Finally, list renames and deletes (after task ops so a deleted list's
        // task tombstones are pushed first).
        self.push_list_mutations(out).await?;
        Ok(())
    }

    /// Push locally-created lists so their tasks can reference real ids.
    /// Adopts an existing remote list with the same title instead of creating
    /// a duplicate (covers the default "My Tasks" and same-named lists).
    async fn push_list_creates(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let creates: Vec<_> = self.store.drain_dirty_lists().await?
            .into_iter()
            .filter(|l| l.pending_op.as_deref() == Some("create"))
            .collect();
        if creates.is_empty() {
            return Ok(());
        }
        // Snapshot remote lists once for adoption matching.
        let remote = match self.client.list_tasklists().await {
            Ok(v) => v,
            Err(e) if e.is_transient() => { warn!(err = %e, "transient listing lists, retry"); return Ok(()); }
            Err(e) => return Err(e.into()),
        };
        let local_ids: HashSet<String> = self.store.all_lists().await?
            .into_iter().map(|l| l.list.id).collect();

        for l in creates {
            // Adopt a remote list with the same title we don't already track.
            if let Some(existing) = remote.iter()
                .find(|r| r.title == l.list.title && !local_ids.contains(&r.id))
            {
                self.store
                    .remap_list_id(&l.list.id, &existing.id, existing.etag.as_deref(), &existing.updated)
                    .await?;
                debug!(local_id = %l.list.id, remote_id = %existing.id, "adopted existing list by title");
                continue;
            }
            match self.client.insert_tasklist(&l.list.title).await {
                Ok(remote_list) => {
                    self.store
                        .remap_list_id(&l.list.id, &remote_list.id, remote_list.etag.as_deref(), &remote_list.updated)
                        .await?;
                    out.pushed += 1;
                    debug!(local_id = %l.list.id, remote_id = %remote_list.id, "pushed list create");
                }
                Err(e) if e.is_transient() => warn!(err = %e, "transient on list create, retry"),
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }

    /// Push list renames (update) and deletions.
    async fn push_list_mutations(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        for l in self.store.drain_dirty_lists().await? {
            match l.pending_op.as_deref() {
                Some("update") => match self.client.patch_tasklist(&l.list.id, &l.list.title).await {
                    Ok(remote) => {
                        self.store.mark_list_clean(&remote.id, remote.etag.as_deref(), &remote.updated).await?;
                        out.pushed += 1;
                    }
                    Err(ApiError::NotFound) => { self.store.delete_list_hard(&l.list.id).await?; }
                    Err(e) if e.is_transient() => warn!(err = %e, "transient on list rename, retry"),
                    Err(e) => return Err(e.into()),
                },
                Some("delete") => match self.client.delete_tasklist(&l.list.id).await {
                    Ok(()) | Err(ApiError::NotFound) => {
                        self.store.delete_list_hard(&l.list.id).await?;
                        out.deleted += 1;
                    }
                    Err(e) if e.is_transient() => warn!(err = %e, "transient on list delete, retry"),
                    Err(e) => return Err(e.into()),
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
            let local = self.store.list_tasks(&list_id).await?
                .into_iter().find(|t| t.task.id == local_id);
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
            let local_id_set: HashSet<String> = self.store.list_tasks(&list_id).await?
                .into_iter().map(|t| t.task.id).collect();

            // Orphan: a remote task with our content whose id we never recorded.
            let orphan = remote.iter()
                .find(|r| !local_id_set.contains(&r.id) && same_content(&local.task, r));

            match orphan {
                Some(o) => {
                    info!(local_id = %local_id, remote_id = %o.id, "adopting orphaned create after crash");
                    self.store.finish_create(&local_id, &o.id, o.etag.as_deref(), &o.updated).await?;
                }
                None => {
                    // Insert never reached the server — let normal push retry.
                    self.store.clear_inflight_create(&local_id).await?;
                }
            }
        }
        Ok(())
    }

    /// Push pending position/parent moves via the Tasks move endpoint.
    async fn push_moves(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        for mv in self.store.pending_moves().await? {
            match self.client.move_task(
                &mv.list_id,
                &mv.task_id,
                mv.parent_id.as_deref(),
                mv.previous_id.as_deref(),
            ).await {
                Ok(remote) => {
                    self.store.mark_task_clean(&remote.id, remote.etag.as_deref(), &remote.updated).await?;
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
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }

    async fn push_create(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let payload = NewTask {
            title: row.task.title.clone(),
            notes: row.task.notes.clone(),
            due: row.task.due.clone(),
            status: Some(row.task.status),
            parent: row.task.parent.clone(),
            previous: None,
        };
        // Durably mark in-flight BEFORE the non-idempotent insert.
        self.store.record_inflight_create(&row.task.id, &row.list_id).await?;
        match self.client.insert_task(&row.list_id, payload).await {
            Ok(remote) => {
                // Atomic: remap local→remote id AND mark clean in one txn so a
                // crash can't leave a remapped row still flagged 'create'.
                self.store
                    .finish_create(&row.task.id, &remote.id, remote.etag.as_deref(), &remote.updated)
                    .await?;
                out.pushed += 1;
                debug!(local_id = %row.task.id, remote_id = %remote.id, "pushed create");
                Ok(())
            }
            Err(e) if e.is_transient() => {
                // Insert may or may not have reached the server. The in-flight
                // marker lets the next run adopt an orphan instead of dup'ing.
                warn!(err = %e, "transient error on create, will retry");
                Ok(())
            }
            Err(e) => { self.store.clear_inflight_create(&row.task.id).await?; Err(e.into()) }
        }
    }

    async fn push_update(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let patch = TaskPatch {
            title: Some(row.task.title.clone()),
            notes: row.task.notes.clone().or(Some(String::new())),
            due: row.task.due.clone().or(Some(String::new())),
            status: Some(row.task.status),
        };
        match self.client.patch_task(&row.list_id, &row.task.id, patch, row.task.etag.as_deref()).await {
            Ok(remote) => {
                self.store.mark_task_clean(&remote.id, remote.etag.as_deref(), &remote.updated).await?;
                out.pushed += 1;
                debug!(id = %row.task.id, "pushed update");
                Ok(())
            }
            Err(ApiError::PreconditionFailed) => {
                self.resolve_conflict(row, out).await
            }
            Err(ApiError::NotFound) => {
                debug!(id = %row.task.id, "task gone from server, deleting locally");
                self.store.delete_task_hard(&row.task.id).await?;
                Ok(())
            }
            Err(e) if e.is_transient() => { warn!(err = %e, "transient error on update, will retry"); Ok(()) }
            Err(e) => Err(e.into()),
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
    async fn resolve_conflict(&self, local: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
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

        // Adopt remote etag if the content is already identical (no real divergence).
        if same_content(&local.task, &remote) {
            self.store
                .mark_task_clean(&remote.id, remote.etag.as_deref(), &remote.updated)
                .await?;
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
        Ok(())
    }

    async fn push_delete(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        match self.client.delete_task(&row.list_id, &row.task.id).await {
            Ok(()) | Err(ApiError::NotFound) => {
                self.store.delete_task_hard(&row.task.id).await?;
                out.deleted += 1;
                debug!(id = %row.task.id, "pushed delete");
                Ok(())
            }
            Err(e) if e.is_transient() => { warn!(err = %e, "transient error on delete, will retry"); Ok(()) }
            Err(e) => Err(e.into()),
        }
    }

    // ─── Pull ────────────────────────────────────────────────────────────────

    /// Pull all lists and their tasks from the server.
    async fn pull_all(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let lists = match self.client.list_tasklists().await {
            Ok(v) => v,
            Err(e) if e.is_transient() => { warn!(err = %e, "transient error listing tasklists"); return Ok(()); }
            Err(e) => return Err(e.into()),
        };

        for list in &lists {
            self.upsert_list(list).await?;
        }

        // List ghost detection: a clean local list absent from the server was
        // deleted remotely — remove it (FK cascade drops its tasks).
        let remote_list_ids: HashSet<String> = lists.iter().map(|l| l.id.clone()).collect();
        for ghost in self.store.clean_list_ids().await?.difference(&remote_list_ids) {
            debug!(id = %ghost, "removing ghost list");
            self.store.delete_list_hard_if_clean(ghost).await?;
            out.deleted += 1;
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
        let mut to_upsert: Vec<_> = remote_tasks.into_iter()
            .filter(|t| !dirty_ids.contains(&t.id))
            .filter(|t| !inflight.iter().any(|f| same_content(f, t)))
            .collect();

        // Parents before children for FK safety.
        to_upsert.sort_by_key(|t| t.parent.is_some());

        // Idempotency: skip rows where local etag already matches.
        let local_etags = self.build_etag_map(&list.id).await;

        for task in to_upsert {
            if Self::is_up_to_date(&task.id, task.etag.as_deref(), &local_etags) {
                continue;
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
        self.store.list_tasks(list_id).await.unwrap_or_default()
            .into_iter()
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
        }
        Ok(())
    }

    /// Reconcile one remote list into the local store.
    async fn upsert_list(&self, list: &TaskList) -> Result<(), SyncError> {
        let locals = self.store.all_lists().await?;

        // Locally dirty list with the same id → preserve local intent (push will handle it).
        if locals.iter().any(|l| l.list.id == list.id && l.sync_state != SyncState::Clean) {
            return Ok(());
        }

        // Adopt a local-only create (no etag) with the same title — covers the
        // offline "My Tasks" bootstrap and any create that already landed.
        if let Some(orphan) = locals.iter().find(|l| {
            l.pending_op.as_deref() == Some("create")
                && l.list.etag.is_none()
                && l.list.title == list.title
        }) {
            self.store
                .remap_list_id(&orphan.list.id, &list.id, list.etag.as_deref(), &list.updated)
                .await?;
            return Ok(());
        }

        let stored = StoredTaskList {
            list: list.clone(),
            sync_state: SyncState::Clean,
            local_updated: list.updated.clone(),
            pending_op: None,
            local_only: false,
        };
        // Race-safe: won't clobber a list a live rename just dirtied.
        self.store.upsert_remote_list(&stored).await?;
        Ok(())
    }
}

/// Whether two tasks have identical user-visible content (the patchable
/// fields). Used to tell a real conflict from an identical concurrent edit.
fn same_content(a: &Task, b: &Task) -> bool {
    a.title == b.title && a.notes == b.notes && a.due == b.due && a.status == b.status
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
            sync_state: if op == "delete" { SyncState::Deleted } else { SyncState::Dirty },
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
        eng.store.upsert_task(&dirty_task("local-1", "L1", "create")).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0);
        assert_eq!(client.call_count(crate::api::in_memory::Method::InsertTask), 0);
    }

    #[tokio::test]
    async fn push_create_remaps_id() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();
        eng.store.upsert_task(&dirty_task("local-1", "L1", "create")).await.unwrap();

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
        eng.store.record_inflight_create("local-1", "L1").await.unwrap();

        let _out = eng.run().await.unwrap();

        // No re-insert: InsertTask not called this run.
        assert_eq!(client.call_count(crate::api::in_memory::Method::InsertTask), 0);
        // Exactly one task remains, adopted to the orphan's id.
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        let milk: Vec<_> = tasks.iter().filter(|t| t.task.title == "buy milk").collect();
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
        eng.store.record_inflight_create("local-1", "L1").await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 1, "normal insert happened");
        assert_eq!(client.call_count(crate::api::in_memory::Method::InsertTask), 1);
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
        eng.store.upsert_task(&dirty_task("local-1", "L1", "create")).await.unwrap();
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
        assert_eq!(client.list_tasks("L1", None).await.unwrap().items.iter()
            .filter(|t| t.title == "buy milk").count(), 1);

        // Run 2: recovery adopts the orphan instead of inserting again.
        eng.run().await.unwrap();
        assert_eq!(client.call_count(Method::InsertTask), 1, "no second insert");
        let milk: Vec<_> = eng.store.list_tasks("L1").await.unwrap()
            .into_iter().filter(|t| t.task.title == "buy milk").collect();
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
        assert!(tasks.iter().any(|t| t.task.title == "server-version" && t.sync_state == SyncState::Clean));
        assert!(tasks.iter().any(|t| t.task.title == "local-edit (conflicted copy)"));
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
        assert!(tasks.iter().any(|t| t.task.title == "conflict (conflicted copy)"));
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
        assert!(eng.store.list_tasks("L1").await.unwrap().iter().all(|t| t.task.id != "T1"));
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
        eng.store.upsert_task(&dirty_task("local-1", "L1", "create")).await.unwrap();

        // A single transient. A parentless create must be attempted EXACTLY
        // once per run (no pass-2 re-attempt that could double-insert).
        client.fail_next(crate::api::in_memory::Method::InsertTask, || ApiError::Network("timeout".into()));

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0);
        assert_eq!(client.call_count(crate::api::in_memory::Method::InsertTask), 1,
            "parentless create attempted exactly once per run");
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

        client.fail_next(crate::api::in_memory::Method::DeleteTask, || ApiError::Server { status: 503 });
        client.fail_next(crate::api::in_memory::Method::DeleteTask, || ApiError::Server { status: 503 });

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 0);
        assert_eq!(eng.store.drain_dirty().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn push_to_unknown_list_is_fatal() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        eng.store.upsert_list(&StoredTaskList {
            list: TaskList { id: "ghost-list".into(), title: "Local".into(), etag: None, updated: "2026-01-01T00:00:00Z".into() },
            sync_state: SyncState::Dirty,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: None,
            local_only: false,
        }).await.unwrap();
        eng.store.upsert_task(&dirty_task("local-1", "ghost-list", "create")).await.unwrap();

        assert!(eng.run().await.is_err());
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
        assert_eq!(eng.store.list_tasks("L1").await.unwrap()[0].task.title, "work");
        assert_eq!(eng.store.list_tasks("L2").await.unwrap()[0].task.title, "personal");
    }

    #[tokio::test]
    async fn pull_parents_before_children() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P1", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "child", "2", Some("P1"));

        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 2);
        let child = eng.store.list_tasks("L1").await.unwrap().into_iter().find(|t| t.task.id == "C1").unwrap();
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
        let mut t1 = eng.store.list_tasks("L1").await.unwrap().into_iter().find(|t| t.task.id == "T1").unwrap();
        t1.task.title = "local edit".into();
        t1.sync_state = SyncState::Dirty;
        t1.pending_op = Some("update".into());
        eng.store.upsert_task(&t1).await.unwrap();

        let out = eng.run().await.unwrap();
        // Neither T1 (dirty, skipped) nor T2 (etag unchanged) should count
        assert_eq!(out.pulled, 0);
        // Local edit preserved
        let t1 = eng.store.list_tasks("L1").await.unwrap().into_iter().find(|t| t.task.id == "T1").unwrap();
        assert_eq!(t1.task.title, "local edit");
    }

    #[tokio::test]
    async fn pull_updates_when_remote_etag_differs() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "v1", "1");
        eng.run().await.unwrap();

        // Remote edit (changes etag)
        client.patch_task("L1", "T1", TaskPatch { title: Some("v2".into()), ..Default::default() }, None).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 1);
        assert_eq!(eng.store.list_tasks("L1").await.unwrap()[0].task.title, "v2");
    }

    #[tokio::test]
    async fn pull_handles_pagination() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        for i in 0..10 {
            client.seed_task("L1", &format!("T{i}"), &format!("task {i}"), &format!("{i:014}"));
        }
        let out = eng.run().await.unwrap();
        assert_eq!(out.pulled, 10);
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
        eng.store.upsert_task(&dirty_task("local-only", "L1", "create")).await.unwrap();

        eng.run().await.unwrap();
        assert!(eng.store.list_tasks("L1").await.unwrap().iter().any(|t| t.task.id == "local-only"));
    }

    #[tokio::test]
    async fn ghost_detection_skipped_on_transient() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task1", "1");
        client.seed_task("L1", "T2", "task2", "2");
        eng.run().await.unwrap();

        client.fail_next(crate::api::in_memory::Method::ListTasks, || ApiError::Server { status: 503 });

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
        client.fail_next(crate::api::in_memory::Method::ListTaskLists, || ApiError::Server { status: 503 });

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

        let row: (i64, i64, i64) = sqlx::query_as("SELECT pulled, pushed, conflicts FROM sync_log ORDER BY id DESC LIMIT 1")
            .fetch_one(eng.store.pool())
            .await.unwrap();
        assert_eq!(row.0, 1);
    }

    #[tokio::test]
    async fn sync_log_written_on_error() {
        let (client, eng) = engine().await;
        client.fail_next(crate::api::in_memory::Method::ListTaskLists, || ApiError::Other("fatal".into()));
        let _ = eng.run().await;

        let row: (Option<String>,) = sqlx::query_as("SELECT error FROM sync_log ORDER BY id DESC LIMIT 1")
            .fetch_one(eng.store.pool())
            .await.unwrap();
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
        eng.store.record_move("T1", "L1", None, Some("T2")).await.unwrap();

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

        eng.store.record_move("T1", "L1", None, Some("X")).await.unwrap();
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
        eng.store.record_move("ghost", "L1", None, None).await.unwrap();

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

        eng.store.record_move("T1", "L1", None, Some("T2")).await.unwrap();
        client.fail_next(Method::MoveTask, || ApiError::Server { status: 503 });

        eng.run().await.unwrap();
        // Move intent preserved for retry.
        assert_eq!(eng.store.pending_moves().await.unwrap().len(), 1);
    }

    // ─── List sync ───────────────────────────────────────────────────────────

    fn dirty_list(id: &str, title: &str, op: &str) -> StoredTaskList {
        StoredTaskList {
            list: TaskList { id: id.into(), title: title.into(), etag: if op == "create" { None } else { Some("e1".into()) }, updated: "2026-01-01T00:00:00Z".into() },
            sync_state: if op == "delete" { SyncState::Deleted } else { SyncState::Dirty },
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: Some(op.into()),
            local_only: false,
        }
    }

    #[tokio::test]
    async fn push_list_create_remaps_and_tasks_follow() {
        let (_client, eng) = engine_with_push().await;
        // Local list create + a task in it.
        eng.store.upsert_list(&dirty_list("local-list", "Work", "create")).await.unwrap();
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

        let mut l = eng.store.all_lists().await.unwrap().into_iter().find(|l| l.list.id == "L1").unwrap();
        l.list.title = "New Name".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();

        let out = eng.run().await.unwrap();
        assert!(out.pushed >= 1);
        let page = client.list_tasklists().await.unwrap();
        assert!(page.iter().any(|l| l.id == "L1" && l.title == "New Name"));
        let l = eng.store.all_lists().await.unwrap().into_iter().find(|l| l.list.id == "L1").unwrap();
        assert_eq!(l.sync_state, SyncState::Clean);
    }

    #[tokio::test]
    async fn push_list_delete() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Doomed");
        eng.run().await.unwrap();

        let mut l = eng.store.all_lists().await.unwrap().into_iter().find(|l| l.list.id == "L1").unwrap();
        l.sync_state = SyncState::Deleted;
        l.pending_op = Some("delete".into());
        eng.store.upsert_list(&l).await.unwrap();

        let out = eng.run().await.unwrap();
        assert_eq!(out.deleted, 1);
        // Gone from server and local.
        assert!(client.list_tasklists().await.unwrap().iter().all(|l| l.id != "L1"));
        assert!(eng.store.all_lists().await.unwrap().iter().all(|l| l.list.id != "L1"));
    }

    #[tokio::test]
    async fn pull_adopts_local_create_by_title() {
        // Offline default "My Tasks" (local create) must adopt Google's
        // existing "My Tasks" on pull instead of duplicating.
        let (client, eng) = engine_with_push().await;
        eng.store.upsert_list(&dirty_list("local-uuid", "My Tasks", "create")).await.unwrap();
        client.seed_list("remote-mytasks", "My Tasks");

        eng.run().await.unwrap();

        let lists = eng.store.all_lists().await.unwrap();
        let mt: Vec<_> = lists.iter().filter(|l| l.list.title == "My Tasks").collect();
        assert_eq!(mt.len(), 1, "no duplicate My Tasks");
        assert_eq!(mt[0].list.id, "remote-mytasks");
        assert_eq!(mt[0].sync_state, SyncState::Clean);
    }

    #[tokio::test]
    async fn pull_preserves_locally_renamed_list() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Server Title");
        eng.run().await.unwrap();

        let mut l = eng.store.all_lists().await.unwrap().into_iter().find(|l| l.list.id == "L1").unwrap();
        l.list.title = "Local Rename".into();
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        eng.store.upsert_list(&l).await.unwrap();

        eng.run().await.unwrap(); // pull must not clobber the local rename (push disabled)
        let l = eng.store.all_lists().await.unwrap().into_iter().find(|l| l.list.id == "L1").unwrap();
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
