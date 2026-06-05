//! Sync engine: push local changes, pull remote changes, resolve conflicts.
//!
//! Design: RFC-004. Single entry point [`SyncEngine::run`].
//! All conflict resolution follows "remote wins" for MVP.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tracing::{debug, info, warn};

use super::SyncError;
use crate::api::{ApiError, GoogleTasksClient};
use crate::model::{NewTask, TaskList, TaskPatch};
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
        let mut outcome = SyncOutcome::default();
        let result = self.execute(&mut outcome).await;
        self.store.write_sync_log(outcome.pulled, outcome.pushed, outcome.conflicts, result.as_ref().err().map(ToString::to_string)).await;
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
        // First pass: push parent creates (no parent_id).
        // remap_id updates child references in DB.
        let dirty = self.store.drain_dirty().await?;
        let parent_creates: Vec<_> = dirty.iter()
            .filter(|r| r.pending_op.as_deref() == Some("create") && r.task.parent.is_none())
            .collect();

        for row in parent_creates {
            self.push_create(row, out).await?;
        }

        // Second pass: re-read DB for fresh parent_ids after remaps.
        for row in &self.store.drain_dirty().await? {
            match row.pending_op.as_deref() {
                Some("create") => self.push_create(row, out).await?,
                Some("update") => self.push_update(row, out).await?,
                Some("delete") => self.push_delete(row, out).await?,
                _ => {}
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
        match self.client.insert_task(&row.list_id, payload).await {
            Ok(remote) => {
                self.store.remap_id(&row.task.id, &remote.id).await?;
                self.store.mark_task_clean(&remote.id, remote.etag.as_deref(), &remote.updated).await?;
                out.pushed += 1;
                debug!(local_id = %row.task.id, remote_id = %remote.id, "pushed create");
                Ok(())
            }
            Err(e) if e.is_transient() => { warn!(err = %e, "transient error on create, will retry"); Ok(()) }
            Err(e) => Err(e.into()),
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
                // Remote wins: mark clean so pull overwrites.
                info!(id = %row.task.id, "412 conflict — remote wins");
                out.conflicts += 1;
                self.store.mark_task_clean(&row.task.id, row.task.etag.as_deref(), &row.task.updated).await?;
                Ok(())
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

        // Compute skip-set after push so remapped IDs are current.
        let dirty_ids = self.store.dirty_ids().await?;

        for list in &lists {
            self.pull_list(list, &dirty_ids, out).await?;
        }
        Ok(())
    }

    /// Pull a single list's tasks, upsert changes, detect ghost rows.
    async fn pull_list(
        &self,
        list: &TaskList,
        dirty_ids: &HashSet<String>,
        out: &mut SyncOutcome,
    ) -> Result<(), SyncError> {
        let (remote_tasks, complete) = self.fetch_all_tasks(&list.id).await?;

        let remote_ids: HashSet<String> = remote_tasks.iter().map(|t| t.id.clone()).collect();

        // Filter: skip dirty rows, collect tasks to upsert.
        let mut to_upsert: Vec<_> = remote_tasks.into_iter()
            .filter(|t| !dirty_ids.contains(&t.id))
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
            self.store.upsert_task(&stored).await?;
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
            self.store.delete_task_hard(ghost_id).await?;
            out.deleted += 1;
        }
        Ok(())
    }

    async fn upsert_list(&self, list: &TaskList) -> Result<(), SyncError> {
        let stored = StoredTaskList {
            list: list.clone(),
            sync_state: SyncState::Clean,
            local_updated: list.updated.clone(),
        };
        self.store.upsert_list(&stored).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::InMemoryClient;
    use crate::model::TaskStatus;
    use crate::store::open_memory;
    use sqlx::Row as _;

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
    async fn push_update_412_conflict_remote_wins() {
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

        // After pull, remote version wins
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].sync_state, SyncState::Clean);
        assert_eq!(tasks[0].task.title, "server-version");
    }

    #[tokio::test]
    async fn push_update_412_no_loop_on_next_sync() {
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

        eng.run().await.unwrap(); // resolves conflict
        let out2 = eng.run().await.unwrap(); // must be noop
        assert_eq!(out2.conflicts, 0);
        assert_eq!(out2.pushed, 0);
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

        client.fail_next(crate::api::in_memory::Method::InsertTask, || ApiError::Network("timeout".into()));
        client.fail_next(crate::api::in_memory::Method::InsertTask, || ApiError::Network("timeout".into()));

        let out = eng.run().await.unwrap();
        assert_eq!(out.pushed, 0);
        assert_eq!(eng.store.drain_dirty().await.unwrap().len(), 1);
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
}
