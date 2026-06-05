//! Sync engine state machine. Single `run()` entry point: push dirty rows,
//! then pull remote changes, applying the conflict rules from RFC-004.

use std::sync::Arc;

use super::SyncError;
use crate::api::{ApiError, GoogleTasksClient};
use crate::model::{NewTask, TaskList, TaskPatch};
use crate::store::{Store, StoredTask, StoredTaskList, SyncState};

/// Numeric counters from a single sync run.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SyncOutcome {
    /// Number of tasks pulled from the server (created or updated locally).
    pub pulled: u32,
    /// Number of tasks pushed up to the server.
    pub pushed: u32,
    /// Number of conflicts resolved.
    pub conflicts: u32,
    /// Number of tasks hard-deleted locally after the server confirmed.
    pub deleted: u32,
}

/// The sync engine. One run per call to [`SyncEngine::run`].
pub struct SyncEngine {
    pub(crate) client: Arc<dyn GoogleTasksClient>,
    pub(crate) store: Store,
    pub(crate) push_enabled: bool,
}

impl SyncEngine {
    /// Construct.
    pub fn new(client: Arc<dyn GoogleTasksClient>, store: Store) -> Self {
        Self {
            client,
            store,
            push_enabled: false,
        }
    }

    /// Construct with explicit push setting.
    pub fn with_push(client: Arc<dyn GoogleTasksClient>, store: Store, push_enabled: bool) -> Self {
        Self {
            client,
            store,
            push_enabled,
        }
    }

    /// Run a single full sync: push then pull.
    pub async fn run(&self) -> Result<SyncOutcome, SyncError> {
        let mut out = SyncOutcome::default();
        let result = self.run_inner(&mut out).await;
        // Always write sync_log regardless of success/failure
        self.write_sync_log(&out, result.as_ref().err()).await;
        result?;
        Ok(out)
    }

    async fn run_inner(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        self.push(out).await?;
        self.pull(out).await?;
        Ok(())
    }

    async fn write_sync_log(&self, out: &SyncOutcome, err: Option<&SyncError>) {
        let now = jiff::Zoned::now().strftime("%Y-%m-%dT%H:%M:%SZ").to_string();
        let error_msg = err.map(|e| e.to_string());
        let _ = sqlx::query(
            "INSERT INTO sync_log (ran_at, pulled, pushed, conflicts, error) VALUES (?, ?, ?, ?, ?)"
        )
        .bind(&now)
        .bind(i64::from(out.pulled))
        .bind(i64::from(out.pushed))
        .bind(i64::from(out.conflicts))
        .bind(&error_msg)
        .execute(self.store.pool())
        .await;
    }

    /// Push dirty rows. Handles id remap (local UUID → remote id) on success.
    async fn push(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        if !self.push_enabled {
            return Ok(());
        }
        let dirty = self.store.drain_dirty().await?;
        for row in &dirty {
            match row.pending_op.as_deref() {
                Some("create") => self.push_create(row, out).await?,
                Some("update") => self.push_update(row, out).await?,
                Some("delete") => self.push_delete(row, out).await?,
                _ => {} // unknown op, skip
            }
        }
        Ok(())
    }

    async fn push_create(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let new = NewTask {
            title: row.task.title.clone(),
            notes: row.task.notes.clone(),
            due: row.task.due.clone(),
            status: Some(row.task.status),
            parent: row.task.parent.clone(),
            previous: None,
        };
        match self.client.insert_task(&row.list_id, new).await {
            Ok(remote) => {
                self.store.remap_id(&row.task.id, &remote.id).await?;
                self.store
                    .mark_task_clean(&remote.id, remote.etag.as_deref(), &remote.updated)
                    .await?;
                out.pushed += 1;
                Ok(())
            }
            Err(e) if e.is_transient() => Ok(()), // try again later
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
        match self
            .client
            .patch_task(&row.list_id, &row.task.id, patch, row.task.etag.as_deref())
            .await
        {
            Ok(remote) => {
                self.store
                    .mark_task_clean(&remote.id, remote.etag.as_deref(), &remote.updated)
                    .await?;
                out.pushed += 1;
                Ok(())
            }
            Err(ApiError::PreconditionFailed) => {
                out.conflicts += 1;
                self.resolve_conflict(row).await
            }
            Err(ApiError::NotFound) => {
                // Server says it's gone — drop the local row.
                self.store.delete_task_hard(&row.task.id).await?;
                Ok(())
            }
            Err(e) if e.is_transient() => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    async fn push_delete(&self, row: &StoredTask, out: &mut SyncOutcome) -> Result<(), SyncError> {
        match self.client.delete_task(&row.list_id, &row.task.id).await {
            Ok(()) | Err(ApiError::NotFound) => {
                self.store.delete_task_hard(&row.task.id).await?;
                out.deleted += 1;
                Ok(())
            }
            Err(e) if e.is_transient() => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// Resolve a `412` precondition failure: mark local row clean so the
    /// subsequent pull overwrites it with the remote version (remote wins).
    async fn resolve_conflict(&self, row: &StoredTask) -> Result<(), SyncError> {
        self.store
            .mark_task_clean(&row.task.id, row.task.etag.as_deref(), &row.task.updated)
            .await?;
        Ok(())
    }

    /// Pull lists + tasks; upsert into store, preserving local dirty edits.
    /// Detects server-side deletions (ghost rows).
    async fn pull(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let lists = match self.client.list_tasklists().await {
            Ok(v) => v,
            Err(e) if e.is_transient() => return Ok(()),
            Err(e) => return Err(e.into()),
        };
        for list in &lists {
            self.upsert_list_from_remote(list).await?;
        }
        // Compute skip-set AFTER push (Step 5c) so remapped IDs are current
        let local_dirty_ids = self.store.dirty_ids().await?;

        for list in &lists {
            let mut page_token: Option<String> = None;
            let mut remote_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
            let mut all_tasks = Vec::new();
            loop {
                let page = match self
                    .client
                    .list_tasks(&list.id, page_token.as_deref())
                    .await
                {
                    Ok(p) => p,
                    Err(e) if e.is_transient() => break,
                    Err(e) => return Err(e.into()),
                };
                for task in page.items {
                    remote_ids.insert(task.id.clone());
                    if local_dirty_ids.contains(&task.id) {
                        continue;
                    }
                    all_tasks.push((list.id.clone(), task));
                }
                if page.next_page_token.is_none() {
                    break;
                }
                page_token = page.next_page_token;
            }
            // Insert parents before children to satisfy FK constraints
            all_tasks.sort_by_key(|(_, t)| t.parent.is_some());
            for (list_id, task) in all_tasks {
                let stored = StoredTask {
                    list_id,
                    local_updated: task.updated.clone(),
                    sync_state: SyncState::Clean,
                    pending_op: None,
                    task,
                };
                self.store.upsert_task(&stored).await?;
                out.pulled += 1;
            }

            // Step 5b: Detect ghost rows — clean local rows not in remote response
            let local_clean_ids = self.store.clean_task_ids_for_list(&list.id).await?;
            for ghost_id in local_clean_ids.difference(&remote_ids) {
                self.store.delete_task_hard(ghost_id).await?;
                out.deleted += 1;
            }
        }
        Ok(())
    }

    async fn upsert_list_from_remote(&self, list: &TaskList) -> Result<(), SyncError> {
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

    #[tokio::test]
    async fn push_disabled_does_not_push_dirty_rows() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");

        // Pull so store knows about L1
        eng.run().await.unwrap();

        // Create a dirty task locally
        let local = StoredTask {
            task: crate::model::Task {
                id: "local-uuid-1".into(),
                parent: None,
                position: "1".into(),
                title: "unpushed".into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-05-23T00:00:00Z".into(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-05-23T00:00:00Z".into(),
            pending_op: Some("create".into()),
        };
        eng.store.upsert_task(&local).await.unwrap();

        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.pushed, 0);
        assert_eq!(client.call_count(crate::api::in_memory::Method::InsertTask), 0);
    }

    #[tokio::test]
    async fn pull_seeds_local_store_from_remote() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "first", "00000000000001");
        client.seed_task("L1", "T2", "second", "00000000000002");

        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.pulled, 2);

        let lists = eng.store.all_lists().await.unwrap();
        assert_eq!(lists.len(), 1);
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 2);
    }

    #[tokio::test]
    async fn push_create_remaps_local_id_to_remote() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");

        // Pull once so the local store knows about L1.
        eng.run().await.unwrap();

        // Now create a task locally with a local UUID.
        let local = StoredTask {
            task: crate::model::Task {
                id: "local-uuid-1".into(),
                parent: None,
                position: "1".into(),
                title: "do laundry".into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-05-23T00:00:00Z".into(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-05-23T00:00:00Z".into(),
            pending_op: Some("create".into()),
        };
        eng.store.upsert_task(&local).await.unwrap();

        let outcome = eng.run().await.unwrap();
        assert!(outcome.pushed >= 1);

        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert!(
            tasks.iter().any(|t| t.task.id.starts_with("remote-")),
            "task should have remote id after push, got: {:?}",
            tasks.iter().map(|t| t.task.id.clone()).collect::<Vec<_>>()
        );
        assert!(
            !tasks.iter().any(|t| t.task.id == "local-uuid-1"),
            "local id must be remapped away"
        );
    }

    #[tokio::test]
    async fn push_update_clears_dirty_flag() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        let remote = client.seed_task("L1", "T1", "old", "1");
        // Pull
        eng.run().await.unwrap();

        // Locally edit
        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "new".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.local_updated = "2026-05-23T00:00:00Z".into();
        // Keep the same etag = `remote.etag` so the server accepts the patch.
        local.task.etag = remote.etag.clone();
        eng.store.upsert_task(&local).await.unwrap();

        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.pushed, 1);
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].sync_state, SyncState::Clean);
        assert_eq!(tasks[0].pending_op, None);
        assert_eq!(tasks[0].task.title, "new");
    }

    #[tokio::test]
    async fn push_delete_removes_local_row() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "doomed", "1");
        eng.run().await.unwrap();

        let mut row = eng.store.list_tasks("L1").await.unwrap().remove(0);
        row.sync_state = SyncState::Deleted;
        row.pending_op = Some("delete".into());
        eng.store.upsert_task(&row).await.unwrap();

        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.deleted, 1);
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert!(tasks.is_empty());
    }

    #[tokio::test]
    async fn push_update_handles_412_conflict() {
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "original", "1");
        // Pull
        eng.run().await.unwrap();

        // Locally edit with a stale etag
        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "my edit".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = Some("stale-etag".into());
        eng.store.upsert_task(&local).await.unwrap();

        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.conflicts, 1);
        assert_eq!(outcome.pushed, 0); // conflict, not pushed
    }

    #[tokio::test]
    async fn transient_api_error_is_not_fatal() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.fail_next(crate::api::in_memory::Method::ListTaskLists, || {
            ApiError::Server { status: 503 }
        });
        // Pull tolerates the transient and succeeds (zero pulled).
        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.pulled, 0);
    }

    #[tokio::test]
    async fn pull_multiple_lists_stores_tasks_in_correct_list() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "T1", "work task", "00000000000001");
        client.seed_task("L2", "T2", "personal task", "00000000000001");

        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.pulled, 2);

        let work_tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(work_tasks.len(), 1);
        assert_eq!(work_tasks[0].task.title, "work task");
        assert_eq!(work_tasks[0].list_id, "L1");

        let personal_tasks = eng.store.list_tasks("L2").await.unwrap();
        assert_eq!(personal_tasks.len(), 1);
        assert_eq!(personal_tasks[0].task.title, "personal task");
        assert_eq!(personal_tasks[0].list_id, "L2");
    }

    #[tokio::test]
    async fn pull_inserts_parents_before_children_fk_safe() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        // Seed parent and child — child references parent
        client.seed_task("L1", "P1", "parent", "00000000000001");
        client.seed_task_with_parent("L1", "C1", "child", "00000000000002", Some("P1"));

        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.pulled, 2);

        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 2);
        let child = tasks.iter().find(|t| t.task.id == "C1").unwrap();
        assert_eq!(child.task.parent.as_deref(), Some("P1"));
    }

    #[tokio::test]
    async fn pull_skips_locally_dirty_rows() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "remote version", "00000000000001");
        client.seed_task("L1", "T2", "clean remote", "00000000000002");

        // First pull to get everything
        eng.run().await.unwrap();

        // Now locally modify T1
        let mut tasks = eng.store.list_tasks("L1").await.unwrap();
        let mut t1 = tasks.iter_mut().find(|t| t.task.id == "T1").unwrap().clone();
        t1.task.title = "local edit".into();
        t1.sync_state = SyncState::Dirty;
        t1.pending_op = Some("update".into());
        eng.store.upsert_task(&t1).await.unwrap();

        // Pull again — should skip T1 (dirty) but still pull T2
        let outcome = eng.run().await.unwrap();
        // T2 is re-pulled (idempotent upsert), T1 is skipped
        assert_eq!(outcome.pulled, 1);

        // Verify local edit is preserved
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        let t1 = tasks.iter().find(|t| t.task.id == "T1").unwrap();
        assert_eq!(t1.task.title, "local edit");
        assert_eq!(t1.sync_state, SyncState::Dirty);
    }

    #[tokio::test]
    async fn pull_handles_pagination() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        // Seed multiple tasks to verify all are pulled (single page in InMemoryClient)
        for i in 0..10 {
            client.seed_task("L1", &format!("T{i}"), &format!("task {i}"), &format!("{i:014}"));
        }

        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.pulled, 10);

        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 10);
    }

    #[tokio::test]
    async fn pull_upserts_lists_from_remote() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_list("L2", "Work");

        eng.run().await.unwrap();

        let lists = eng.store.all_lists().await.unwrap();
        assert_eq!(lists.len(), 2);
        let titles: Vec<_> = lists.iter().map(|l| l.list.title.as_str()).collect();
        assert!(titles.contains(&"Inbox"));
        assert!(titles.contains(&"Work"));
    }

    // === Step 5a: Conflict loop fix ===

    #[tokio::test]
    async fn conflict_412_marks_local_clean_so_pull_overwrites() {
        // When push gets 412, the local row must be marked clean so the
        // subsequent pull can overwrite it. Otherwise it loops forever.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        let remote = client.seed_task("L1", "T1", "remote version", "1");
        // Pull to seed local
        eng.run().await.unwrap();

        // Locally edit with a stale etag (simulating concurrent remote edit)
        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "my local edit".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = Some("stale-etag".into());
        eng.store.upsert_task(&local).await.unwrap();

        // Run sync — push will get 412, should mark clean
        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.conflicts, 1);

        // After sync, local row should be clean (pull overwrote it)
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].sync_state, SyncState::Clean);
        assert_eq!(tasks[0].pending_op, None);
        // Remote version wins
        assert_eq!(tasks[0].task.title, "remote version");
    }

    #[tokio::test]
    async fn conflict_412_does_not_loop_on_second_sync() {
        // After resolving a 412 conflict, the next sync must be a no-op
        // (no push attempt, no conflict).
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "server", "1");
        eng.run().await.unwrap();

        // Create conflict
        let mut local = eng.store.list_tasks("L1").await.unwrap().remove(0);
        local.task.title = "conflict".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        local.task.etag = Some("stale".into());
        eng.store.upsert_task(&local).await.unwrap();

        // First sync resolves conflict
        eng.run().await.unwrap();

        // Second sync should be a complete no-op
        let outcome2 = eng.run().await.unwrap();
        assert_eq!(outcome2.conflicts, 0);
        assert_eq!(outcome2.pushed, 0);
    }

    // === Step 5b: Ghost row detection ===

    #[tokio::test]
    async fn pull_deletes_local_clean_rows_missing_from_remote() {
        // If a task exists locally as clean but the server no longer returns it,
        // the local row is a ghost and must be removed.
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "will-stay", "1");
        client.seed_task("L1", "T2", "will-vanish", "2");

        // Initial pull — both tasks land locally
        eng.run().await.unwrap();
        assert_eq!(eng.store.list_tasks("L1").await.unwrap().len(), 2);

        // Server-side deletion: remove T2 from the mock (simulates deletion on another device)
        client.delete_task_from_state("L1", "T2");

        // Pull again — T2 should be gone locally
        let outcome = eng.run().await.unwrap();
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.id, "T1");
        assert!(outcome.deleted >= 1);
    }

    #[tokio::test]
    async fn pull_does_not_delete_locally_dirty_rows_missing_from_remote() {
        // Dirty rows (not yet pushed) must NOT be deleted even if the server
        // doesn't know about them.
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "remote", "1");
        eng.run().await.unwrap();

        // Create a local-only task (dirty, pending create)
        let local = StoredTask {
            task: crate::model::Task {
                id: "local-only".into(),
                parent: None,
                position: "99".into(),
                title: "not on server yet".into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-06-01T00:00:00Z".into(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-06-01T00:00:00Z".into(),
            pending_op: Some("create".into()),
        };
        eng.store.upsert_task(&local).await.unwrap();

        // Pull — local-only task must survive
        eng.run().await.unwrap();
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert!(tasks.iter().any(|t| t.task.id == "local-only"));
    }

    // === Step 5c: Stale skip-set ===

    #[tokio::test]
    async fn skip_set_computed_after_push_not_before() {
        // After push remaps an ID, the skip-set for pull must use the NEW id.
        // If computed before push, the remapped task gets re-pulled and clobbered.
        let (client, eng) = engine_with_push().await;
        client.seed_list("L1", "Inbox");
        eng.run().await.unwrap();

        // Create a local task
        let local = StoredTask {
            task: crate::model::Task {
                id: "local-uuid".into(),
                parent: None,
                position: "1".into(),
                title: "locally created".into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-06-01T00:00:00Z".into(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-06-01T00:00:00Z".into(),
            pending_op: Some("create".into()),
        };
        eng.store.upsert_task(&local).await.unwrap();

        // Run sync — push creates remote, remap happens, then pull runs
        let outcome = eng.run().await.unwrap();
        assert_eq!(outcome.pushed, 1);

        // The task should exist exactly once (not duplicated by pull)
        let tasks = eng.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        // And it should be clean (not re-pulled as a separate row)
        assert_eq!(tasks[0].sync_state, SyncState::Clean);
    }

    // === Step 7: sync_log ===

    #[tokio::test]
    async fn sync_log_records_outcome() {
        let (client, eng) = engine().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task", "1");

        eng.run().await.unwrap();

        // Check sync_log table has a row
        let row: (i64, i64, i64, i64) = sqlx::query_as(
            "SELECT pulled, pushed, conflicts, COALESCE(error IS NULL, 1) FROM sync_log ORDER BY id DESC LIMIT 1"
        )
        .fetch_one(eng.store.pool())
        .await
        .unwrap();
        assert_eq!(row.0, 1); // pulled
        assert_eq!(row.1, 0); // pushed
        assert_eq!(row.2, 0); // conflicts
    }

    #[tokio::test]
    async fn sync_log_records_error_on_failure() {
        let (client, eng) = engine().await;
        // Fatal error (non-transient)
        client.fail_next(crate::api::in_memory::Method::ListTaskLists, || {
            ApiError::Other("fatal test error".into())
        });

        let result = eng.run().await;
        assert!(result.is_err());

        // sync_log should still have a row with the error
        let row: (Option<String>,) = sqlx::query_as(
            "SELECT error FROM sync_log ORDER BY id DESC LIMIT 1"
        )
        .fetch_one(eng.store.pool())
        .await
        .unwrap();
        assert!(row.0.is_some());
        assert!(row.0.unwrap().contains("fatal test error"));
    }
}
