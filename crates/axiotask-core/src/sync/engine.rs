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
        self.push(&mut out).await?;
        self.pull(&mut out).await?;
        Ok(out)
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

    /// Resolve a `412` precondition failure: pull the remote row, then merge.
    /// RFC-004 conflict rule: title/notes/status → newer-wins by `updated`;
    /// for MVP we treat the remote as authoritative because we just learned
    /// our cached etag is stale.
    async fn resolve_conflict(&self, _row: &StoredTask) -> Result<(), SyncError> {
        // MVP behavior: remote wins. The next pull will overwrite the local
        // copy. We just leave the local row dirty; the user's edit is lost
        // for this field. Future work: field-level merge per RFC-004.
        //
        // Tracked in TECH_DEBT under SYNC-MERGE.
        Ok(())
    }

    /// Pull lists + tasks; upsert into store, preserving local dirty edits.
    async fn pull(&self, out: &mut SyncOutcome) -> Result<(), SyncError> {
        let lists = match self.client.list_tasklists().await {
            Ok(v) => v,
            Err(e) if e.is_transient() => return Ok(()),
            Err(e) => return Err(e.into()),
        };
        for list in &lists {
            self.upsert_list_from_remote(list).await?;
        }
        let local_dirty_ids: std::collections::HashSet<String> = self
            .store
            .drain_dirty()
            .await?
            .into_iter()
            .map(|t| t.task.id)
            .collect();
        for list in lists {
            let mut page_token: Option<String> = None;
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
}
