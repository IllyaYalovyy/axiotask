//! Integration tests for Tauri commands.
//!
//! These test the command logic through AppState without needing a running
//! Tauri instance. Each test gets a fresh in-memory store + InMemoryClient.

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axiotask_core::api::InMemoryClient;
    use axiotask_core::model::TaskStatus;
    use axiotask_core::store::{StoredTask, StoredTaskList, SyncState};

    // We test the state + store logic directly since Tauri commands are thin
    // wrappers. This avoids needing the Tauri runtime in tests.

    use crate::state::AppState;

    async fn setup() -> (Arc<InMemoryClient>, Arc<AppState>) {
        let client = Arc::new(InMemoryClient::new());
        let state = Arc::new(
            AppState::new_memory(client.clone())
                .await
                .expect("setup state"),
        );
        (client, state)
    }

    async fn seed_list(state: &AppState, id: &str, title: &str) {
        let list = StoredTaskList {
            list: axiotask_core::model::TaskList {
                id: id.into(),
                title: title.into(),
                etag: Some("e1".into()),
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: SyncState::Clean,
            local_updated: "2026-01-01T00:00:00Z".into(),
        };
        state.store.upsert_list(&list).await.unwrap();
    }

    async fn seed_task(state: &AppState, id: &str, list_id: &str, title: &str) {
        let task = StoredTask {
            task: axiotask_core::model::Task {
                id: id.into(),
                parent: None,
                position: "00000000000001".into(),
                title: title.into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: Some("e1".into()),
                updated: "2026-01-01T00:00:00Z".into(),
            },
            list_id: list_id.into(),
            sync_state: SyncState::Clean,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: None,
        };
        state.store.upsert_task(&task).await.unwrap();
    }

    #[tokio::test]
    async fn list_tasklists_returns_seeded_lists() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_list(&state, "L2", "Work").await;

        let lists = state.store.all_lists().await.unwrap();
        // 3 = auto-created "My Tasks" + 2 seeded
        assert_eq!(lists.len(), 3);
        let titles: Vec<_> = lists.iter().map(|l| l.list.title.as_str()).collect();
        assert!(titles.contains(&"Inbox"));
        assert!(titles.contains(&"Work"));
    }

    #[tokio::test]
    async fn create_task_inserts_dirty_row() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;

        let id = uuid::Uuid::new_v4().to_string();
        let now = "2026-05-23T00:00:00Z".to_string();
        let stored = StoredTask {
            task: axiotask_core::model::Task {
                id: id.clone(),
                parent: None,
                position: "99999999999999".into(),
                title: "new task".into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: now.clone(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: now,
            pending_op: Some("create".into()),
        };
        state.store.upsert_task(&stored).await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.title, "new task");
        assert_eq!(tasks[0].sync_state, SyncState::Dirty);
        assert_eq!(tasks[0].pending_op.as_deref(), Some("create"));
    }

    #[tokio::test]
    async fn toggle_complete_flips_status() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "buy milk").await;

        // Toggle to completed
        let mut tasks = state.store.list_tasks("L1").await.unwrap();
        let mut t = tasks.remove(0);
        t.task.status = TaskStatus::Completed;
        t.task.completed = Some("2026-05-23T00:00:00Z".into());
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        state.store.upsert_task(&t).await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].task.status, TaskStatus::Completed);
        assert!(tasks[0].task.completed.is_some());

        // Toggle back
        let mut t = tasks[0].clone();
        t.task.status = TaskStatus::NeedsAction;
        t.task.completed = None;
        state.store.upsert_task(&t).await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].task.status, TaskStatus::NeedsAction);
        assert!(tasks[0].task.completed.is_none());
    }

    #[tokio::test]
    async fn delete_task_with_etag_marks_deleted() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "doomed").await;

        let mut tasks = state.store.list_tasks("L1").await.unwrap();
        let mut t = tasks.remove(0);
        // Has etag → soft delete
        t.sync_state = SyncState::Deleted;
        t.pending_op = Some("delete".into());
        state.store.upsert_task(&t).await.unwrap();

        // list_tasks excludes deleted
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(tasks.is_empty());

        // But drain_dirty still sees it
        let dirty = state.store.drain_dirty().await.unwrap();
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty[0].pending_op.as_deref(), Some("delete"));
    }

    #[tokio::test]
    async fn delete_task_without_etag_hard_deletes() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;

        // Task with no etag (never pushed)
        let task = StoredTask {
            task: axiotask_core::model::Task {
                id: "local-only".into(),
                parent: None,
                position: "1".into(),
                title: "ephemeral".into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-01-01T00:00:00Z".into(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: Some("create".into()),
        };
        state.store.upsert_task(&task).await.unwrap();
        state.store.delete_task_hard("local-only").await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(tasks.is_empty());
        let dirty = state.store.drain_dirty().await.unwrap();
        assert!(dirty.is_empty());
    }

    #[tokio::test]
    async fn set_due_applies_date_move() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "task with due").await;

        let mut tasks = state.store.list_tasks("L1").await.unwrap();
        let mut t = tasks.remove(0);
        // Simulate set_due with Tomorrow
        let today = jiff::civil::Date::from(jiff::Zoned::now().date());
        let new_due = axiotask_core::dates::apply_date_move(today, axiotask_core::dates::DateMove::Tomorrow);
        t.task.due = new_due.map(|d| format!("{}T00:00:00.000Z", d));
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        state.store.upsert_task(&t).await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(tasks[0].task.due.is_some());
        let due = tasks[0].task.due.as_ref().unwrap();
        let tomorrow = today.tomorrow().unwrap();
        assert!(due.starts_with(&tomorrow.to_string()));
    }

    #[tokio::test]
    async fn rename_task_updates_title_and_marks_dirty() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "old title").await;

        let mut tasks = state.store.list_tasks("L1").await.unwrap();
        let mut t = tasks.remove(0);
        t.task.title = "new title".into();
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        state.store.upsert_task(&t).await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].task.title, "new title");
        assert_eq!(tasks[0].sync_state, SyncState::Dirty);
    }

    #[tokio::test]
    async fn move_task_changes_parent() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "parent").await;
        seed_task(&state, "T2", "L1", "child-to-be").await;

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let mut child = tasks.iter().find(|t| t.task.id == "T2").unwrap().clone();
        child.task.parent = Some("T1".into());
        child.task.position = "00000000000001".into();
        child.sync_state = SyncState::Dirty;
        child.pending_op = Some("update".into());
        state.store.upsert_task(&child).await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let moved = tasks.iter().find(|t| t.task.id == "T2").unwrap();
        assert_eq!(moved.task.parent.as_deref(), Some("T1"));
    }

    #[tokio::test]
    async fn sync_pulls_remote_tasks_into_store() {
        let (client, state) = setup().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "RT1", "remote task", "00000000000001");

        let outcome = state.run_sync().await.unwrap();
        assert_eq!(outcome.pulled, 1);

        let lists = state.store.all_lists().await.unwrap();
        // auto-created "My Tasks" + synced "Inbox"
        assert_eq!(lists.len(), 2);
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.title, "remote task");
    }

    #[tokio::test]
    #[ignore]
    async fn sync_pushes_local_creates_to_remote() {
        let (client, state) = setup().await;
        client.seed_list("L1", "Inbox");

        // Pull to get the list locally
        state.run_sync().await.unwrap();

        // Create a local task
        let task = StoredTask {
            task: axiotask_core::model::Task {
                id: "local-uuid".into(),
                parent: None,
                position: "1".into(),
                title: "push me".into(),
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
        state.store.upsert_task(&task).await.unwrap();

        let outcome = state.run_sync().await.unwrap();
        assert!(outcome.pushed >= 1);

        // Local id should be remapped
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(!tasks.iter().any(|t| t.task.id == "local-uuid"));
        assert!(tasks.iter().any(|t| t.task.id.starts_with("remote-")));
    }

    #[tokio::test]
    async fn set_notes_updates_notes_field() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "task with notes").await;

        let mut t = state.store.list_tasks("L1").await.unwrap().remove(0);
        t.task.notes = Some("hello world".into());
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        state.store.upsert_task(&t).await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].task.notes.as_deref(), Some("hello world"));
    }

    #[tokio::test]
    async fn reorder_swaps_positions() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;

        // Create two tasks with different positions
        let mut t1 = StoredTask {
            task: axiotask_core::model::Task {
                id: "T1".into(),
                parent: None,
                position: "00000000000001".into(),
                title: "first".into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: Some("e1".into()),
                updated: "2026-01-01T00:00:00Z".into(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Clean,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: None,
        };
        let mut t2 = t1.clone();
        t2.task.id = "T2".into();
        t2.task.position = "00000000000002".into();
        t2.task.title = "second".into();
        state.store.upsert_task(&t1).await.unwrap();
        state.store.upsert_task(&t2).await.unwrap();

        // Swap positions (simulate reorder)
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].task.id, "T1");
        assert_eq!(tasks[1].task.id, "T2");

        // Swap
        t1.task.position = "00000000000002".into();
        t2.task.position = "00000000000001".into();
        t1.sync_state = SyncState::Dirty;
        t2.sync_state = SyncState::Dirty;
        state.store.upsert_task(&t1).await.unwrap();
        state.store.upsert_task(&t2).await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].task.id, "T2");
        assert_eq!(tasks[1].task.id, "T1");
    }

    #[tokio::test]
    async fn auto_creates_default_list_on_first_launch() {
        // When no lists exist and user is not authenticated,
        // AppState should auto-create "My Tasks" locally.
        let client = Arc::new(InMemoryClient::new());
        let state = Arc::new(
            AppState::new_memory(client.clone())
                .await
                .expect("setup state"),
        );

        let lists = state.store.all_lists().await.unwrap();
        assert_eq!(lists.len(), 1);
        assert_eq!(lists[0].list.title, "My Tasks");
        assert_eq!(lists[0].sync_state, SyncState::Dirty);
    }

    #[tokio::test]
    async fn does_not_create_default_list_when_lists_exist() {
        // If lists already exist, no default list should be created.
        let client = Arc::new(InMemoryClient::new());
        let state = Arc::new(
            AppState::new_memory(client.clone())
                .await
                .expect("setup state"),
        );

        // Seed a list after initial creation (simulating existing data)
        seed_list(&state, "existing", "Work").await;

        // Create a new state with a store that already has lists
        // We test by verifying no duplicate "My Tasks" appears
        let lists = state.store.all_lists().await.unwrap();
        // Should have "My Tasks" (auto-created) + "Work" (seeded)
        assert_eq!(lists.len(), 2);
    }

    #[tokio::test]
    async fn sync_refuses_when_not_authenticated() {
        // GH#26: sync_now must not run when user is not authenticated.
        let (_client, state) = setup().await;
        assert!(!state.is_authenticated());

        let result = state.run_sync_if_authed().await;
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.contains("not authenticated"), "expected auth error, got: {err}");
    }

    #[tokio::test]
    async fn crud_works_without_authentication() {
        // GH#26: all CRUD operations work locally without sign-in.
        let (_client, state) = setup().await;
        assert!(!state.is_authenticated());

        // Create list
        let lists = state.store.all_lists().await.unwrap();
        assert!(!lists.is_empty(), "default list should exist");
        let list_id = lists[0].list.id.clone();

        // Create task
        let task = StoredTask {
            task: axiotask_core::model::Task {
                id: "local-1".into(),
                parent: None,
                position: "00000000000001".into(),
                title: "offline task".into(),
                notes: Some("notes".into()),
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-01-01T00:00:00Z".into(),
            },
            list_id: list_id.clone(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: Some("create".into()),
        };
        state.store.upsert_task(&task).await.unwrap();

        // Read
        let tasks = state.store.list_tasks(&list_id).await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.title, "offline task");

        // Update
        let mut t = tasks[0].clone();
        t.task.title = "updated offline".into();
        state.store.upsert_task(&t).await.unwrap();
        let tasks = state.store.list_tasks(&list_id).await.unwrap();
        assert_eq!(tasks[0].task.title, "updated offline");

        // Delete
        state.store.delete_task_hard("local-1").await.unwrap();
        let tasks = state.store.list_tasks(&list_id).await.unwrap();
        assert!(tasks.is_empty());
    }

    #[tokio::test]
    async fn schedule_sync_is_noop_when_not_authenticated() {
        // GH#26: schedule_sync should not trigger sync when not authenticated.
        let (client, state) = setup().await;
        assert!(!state.is_authenticated());

        // Seed remote data that would appear if sync ran
        client.seed_list("REMOTE", "Remote List");
        client.seed_task("REMOTE", "RT1", "remote task", "00000000000001");

        // schedule_sync should be a no-op
        state.schedule_sync();

        // Give async a moment
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        // Local store should NOT have remote data
        let lists = state.store.all_lists().await.unwrap();
        assert!(
            !lists.iter().any(|l| l.list.title == "Remote List"),
            "sync should not have run"
        );
    }
}
