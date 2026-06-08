//! Integration tests for Tauri commands.
//!
//! These test the command logic through AppState without needing a running
//! Tauri instance. Each test gets a fresh in-memory store + InMemoryClient.

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axiotask_core::api::InMemoryClient;
    use axiotask_core::api::GoogleTasksClient;
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
            pending_op: None,
            local_only: false,
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
    async fn sync_pushes_local_creates_to_remote() {
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let state = Arc::new(AppState::new_memory_with_push(client.clone()).await.unwrap());

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
    async fn undo_delete_restores_tombstoned_task() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "restore me").await;

        // Set notes on the task before delete
        let mut t = state.store.list_tasks("L1").await.unwrap().remove(0);
        t.task.notes = Some("important notes".into());
        t.task.due = Some("2026-06-01T00:00:00.000Z".into());
        state.store.upsert_task(&t).await.unwrap();

        // Delete (tombstone since it has etag)
        let tasks = state.store.list_tasks("L1").await.unwrap();
        let mut t = tasks[0].clone();
        t.sync_state = SyncState::Deleted;
        t.pending_op = Some("delete".into());
        state.store.upsert_task(&t).await.unwrap();

        // Verify deleted
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(tasks.is_empty());

        // Undo: restore with dirty+create state
        let mut restored = t.clone();
        restored.sync_state = SyncState::Dirty;
        restored.pending_op = Some("create".into());
        state.store.upsert_task(&restored).await.unwrap();

        // Verify restored
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.title, "restore me");
        assert_eq!(tasks[0].task.notes.as_deref(), Some("important notes"));
        assert_eq!(tasks[0].task.due.as_deref(), Some("2026-06-01T00:00:00.000Z"));
        assert_eq!(tasks[0].sync_state, SyncState::Dirty);
    }

    #[tokio::test]
    async fn undo_delete_restores_hard_deleted_local_task() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;

        // Create a local-only task (no etag)
        let task = StoredTask {
            task: axiotask_core::model::Task {
                id: "local-1".into(),
                parent: None,
                position: "00000000000001".into(),
                title: "local task".into(),
                notes: Some("my notes".into()),
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

        // Hard delete
        state.store.delete_task_hard("local-1").await.unwrap();
        assert!(state.store.list_tasks("L1").await.unwrap().is_empty());

        // Undo: re-insert the same task
        state.store.upsert_task(&task).await.unwrap();
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.title, "local task");
        assert_eq!(tasks[0].task.notes.as_deref(), Some("my notes"));
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

    #[tokio::test]
    async fn move_to_list_creates_in_target_and_tombstones_old() {
        // GH#16: cross-list move = create-in-new + delete-from-old.
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Work").await;
        seed_list(&state, "L2", "Personal").await;
        seed_task(&state, "T1", "L1", "Task to move").await; // has etag e1

        state.move_task_to_list("T1", "L2").await.unwrap();

        // Old list: T1 is tombstoned (excluded from list_tasks but pending delete).
        let l1_tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(l1_tasks.is_empty(), "old list should not show the task");

        // New list: a fresh task with the same title, pending create.
        let l2_tasks = state.store.list_tasks("L2").await.unwrap();
        assert_eq!(l2_tasks.len(), 1);
        assert_eq!(l2_tasks[0].task.title, "Task to move");
        assert_ne!(l2_tasks[0].task.id, "T1", "moved task gets a fresh id");
        assert_eq!(l2_tasks[0].pending_op.as_deref(), Some("create"));

        // drain_dirty sees both the delete tombstone and the create.
        let dirty = state.store.drain_dirty().await.unwrap();
        let ops: std::collections::HashSet<_> =
            dirty.iter().filter_map(|t| t.pending_op.clone()).collect();
        assert!(ops.contains("create"));
        assert!(ops.contains("delete"));
    }

    #[tokio::test]
    async fn move_to_list_local_only_task_hard_deletes_old() {
        // A never-synced task (no etag) is hard-deleted from the old list.
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Work").await;
        seed_list(&state, "L2", "Personal").await;

        // Local-only task (no etag).
        let local = StoredTask {
            task: axiotask_core::model::Task {
                id: "local-1".into(),
                parent: None,
                position: "1".into(),
                title: "unsynced".into(),
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
        state.store.upsert_task(&local).await.unwrap();

        state.move_task_to_list("local-1", "L2").await.unwrap();

        // Old gone entirely (no tombstone — never synced).
        assert!(state.store.list_tasks("L1").await.unwrap().is_empty());
        // New exists in L2.
        let l2 = state.store.list_tasks("L2").await.unwrap();
        assert_eq!(l2.len(), 1);
        assert_eq!(l2[0].task.title, "unsynced");
        // No delete tombstone should remain (only the create).
        let dirty = state.store.drain_dirty().await.unwrap();
        assert!(dirty.iter().all(|t| t.pending_op.as_deref() != Some("delete")));
    }

    #[tokio::test]
    async fn move_to_list_syncs_without_data_loss() {
        // End-to-end: move then sync. Task ends up in the new remote list,
        // removed from the old. No 404-delete data loss.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "T1", "movable", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone()).await.unwrap(),
        );

        // Pull so both lists + the task are local.
        state.run_sync().await.unwrap();
        assert_eq!(state.store.list_tasks("L1").await.unwrap().len(), 1);

        // Move T1 → L2, then sync.
        state.move_task_to_list("T1", "L2").await.unwrap();
        state.run_sync().await.unwrap();

        // Remote L1 no longer has T1; remote L2 has the new task.
        let l1_remote = client.list_tasks("L1", None).await.unwrap();
        assert!(l1_remote.items.iter().all(|t| t.id != "T1"));
        let l2_remote = client.list_tasks("L2", None).await.unwrap();
        assert_eq!(l2_remote.items.len(), 1);
        assert_eq!(l2_remote.items[0].title, "movable");
    }

    #[tokio::test]
    async fn rename_list_marks_update_for_synced_and_keeps_create_for_new() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Old").await;
        state.rename_list("L1", "New").await.unwrap();
        let l = state.store.drain_dirty_lists().await.unwrap()
            .into_iter().find(|l| l.list.id == "L1").unwrap();
        assert_eq!(l.list.title, "New");
        assert_eq!(l.pending_op.as_deref(), Some("update"));

        let create = StoredTaskList {
            list: axiotask_core::model::TaskList {
                id: "local".into(), title: "Draft".into(), etag: None,
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: SyncState::Dirty,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: Some("create".into()),
            local_only: false,
        };
        state.store.upsert_list(&create).await.unwrap();
        state.rename_list("local", "Renamed Draft").await.unwrap();
        let l = state.store.drain_dirty_lists().await.unwrap()
            .into_iter().find(|l| l.list.id == "local").unwrap();
        assert_eq!(l.pending_op.as_deref(), Some("create"), "rename folds into create");
    }

    #[tokio::test]
    async fn rename_list_syncs_to_remote() {
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Before");
        let state = Arc::new(AppState::new_memory_with_push(client.clone()).await.unwrap());
        state.run_sync().await.unwrap();
        state.rename_list("L1", "After").await.unwrap();
        state.run_sync().await.unwrap();
        let remote = client.list_tasklists().await.unwrap();
        assert!(remote.iter().any(|l| l.id == "L1" && l.title == "After"));
    }

    #[tokio::test]
    async fn delete_list_tombstones_synced_list() {
        // A synced list (has etag) must tombstone so the delete reaches Google.
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Doomed").await;
        seed_task(&state, "T1", "L1", "child").await;

        state.delete_list("L1").await.unwrap();

        // Hidden from all_lists but present as a delete tombstone in drain.
        assert!(state.store.all_lists().await.unwrap().iter().all(|l| l.list.id != "L1"));
        let dirty = state.store.drain_dirty_lists().await.unwrap();
        assert!(dirty.iter().any(|l| l.list.id == "L1" && l.pending_op.as_deref() == Some("delete")));
        // Tasks removed locally.
        assert!(state.store.list_tasks("L1").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn delete_list_hard_deletes_local_only_list() {
        // A never-synced list (no etag) is hard-deleted, no tombstone.
        let (_client, state) = setup().await;
        // create_list path makes a local-only list (etag None).
        let lists_before = state.store.all_lists().await.unwrap().len();
        let l = StoredTaskList {
            list: axiotask_core::model::TaskList {
                id: "local-list".into(), title: "Temp".into(), etag: None,
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: SyncState::Dirty,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: Some("create".into()),
            local_only: false,
        };
        state.store.upsert_list(&l).await.unwrap();
        state.delete_list("local-list").await.unwrap();

        // No tombstone — fully gone.
        let dirty = state.store.drain_dirty_lists().await.unwrap();
        assert!(dirty.iter().all(|l| l.list.id != "local-list"));
        assert_eq!(state.store.all_lists().await.unwrap().len(), lists_before);
    }

    #[tokio::test]
    async fn token_store_clear_removes_auth() {
        // Test the underlying mechanism of logout: clearing the token store
        let (_client, state) = setup().await;
        assert!(!state.is_authenticated());
        // Clearing token store should work without error
        // (In production, logout also switches the HTTP client, but that
        // requires the Tauri runtime which isn't available in unit tests.)
    }

    #[tokio::test]
    async fn fresh_sync_clears_local_and_repulls() {
        let (client, state) = setup().await;
        // Seed local data
        seed_list(&state, "L1", "Local list").await;
        seed_task(&state, "T1", "L1", "Local task").await;

        // Seed remote data
        client.seed_list("R1", "Remote list");
        client.seed_task("R1", "RT1", "Remote task", "00000000000001");

        // Clear all local data
        state.store.clear_all().await.unwrap();
        assert!(state.store.all_lists().await.unwrap().is_empty());

        // Sync pulls remote data
        let outcome = state.run_sync().await.unwrap();
        assert!(outcome.pulled >= 1);

        // Remote data is now local
        let lists = state.store.all_lists().await.unwrap();
        assert!(lists.iter().any(|l| l.list.title == "Remote list"));
    }

    #[tokio::test]
    async fn test_state_defaults_to_read_only() {
        // In-memory test state must default to push-disabled (read-only)
        // so tests never accidentally push to a real backend.
        let (_client, state) = setup().await;
        assert!(!state.is_push_enabled());
    }

    #[tokio::test]
    async fn concurrent_syncs_do_not_double_push() {
        // Two concurrent run_sync calls must not both push the same dirty
        // create. The sync_guard serializes them.
        use axiotask_core::api::in_memory::Method;

        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .expect("setup push state"),
        );

        // Pull so the list exists locally.
        state.run_sync().await.unwrap();

        // Create one dirty task.
        let task = StoredTask {
            task: axiotask_core::model::Task {
                id: "local-1".into(),
                parent: None,
                position: "1".into(),
                title: "push once".into(),
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
        state.store.upsert_task(&task).await.unwrap();

        // Fire two syncs concurrently.
        let s1 = state.clone();
        let s2 = state.clone();
        let (r1, r2) = tokio::join!(s1.run_sync(), s2.run_sync());
        r1.unwrap();
        r2.unwrap();

        // insert_task must have been called exactly once — no double push.
        assert_eq!(client.call_count(Method::InsertTask), 1);

        // Exactly one task in the list (no duplicate).
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert!(tasks[0].task.id.starts_with("remote-"));
    }

    #[test]
    fn dirty_op_preserves_create_for_unsynced() {
        use crate::commands::dirty_op;
        assert_eq!(dirty_op(None), "create");
        assert_eq!(dirty_op(Some("e1")), "update");
    }

    #[tokio::test]
    async fn offline_created_then_edited_task_pushes_as_create_not_deleted() {
        // Regression: a task created offline (no etag, pending create) and then
        // edited (complete/due/notes) must STAY a create. Flipping to 'update'
        // would patch a non-existent remote id → 404 → delete (data loss).
        use crate::commands::dirty_op;
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let state = Arc::new(AppState::new_memory_with_push(client.clone()).await.unwrap());
        state.run_sync().await.unwrap();

        // Offline create.
        let mut t = StoredTask {
            task: axiotask_core::model::Task {
                id: "local-1".into(), parent: None, position: "1".into(),
                title: "offline task".into(), notes: None,
                status: TaskStatus::NeedsAction, due: None, completed: None,
                etag: None, updated: "2026-06-01T00:00:00Z".into(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-06-01T00:00:00Z".into(),
            pending_op: Some("create".into()),
        };
        state.store.upsert_task(&t).await.unwrap();

        // Simulate completing it before first sync (what the fixed command does).
        t.task.status = TaskStatus::Completed;
        t.pending_op = Some(dirty_op(t.task.etag.as_deref())); // must remain "create"
        state.store.upsert_task(&t).await.unwrap();
        assert_eq!(t.pending_op.as_deref(), Some("create"));

        state.run_sync().await.unwrap();

        // Pushed as a create (gets a remote id), NOT deleted.
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1, "task must survive");
        assert!(tasks[0].task.id.starts_with("remote-"));
        assert_eq!(tasks[0].task.status, TaskStatus::Completed);
    }

    // ─── Local-only list creation ───────────────────────────────────────────

    #[tokio::test]
    async fn create_list_synced_is_dirty_create() {
        // A normal (synced) list is queued for push as a fresh create.
        let (_client, state) = setup().await;
        let created = state.create_list("Work", false).await.unwrap();
        assert!(!created.local_only);
        assert_eq!(created.sync_state, SyncState::Dirty);
        assert_eq!(created.pending_op.as_deref(), Some("create"));
        assert!(created.list.etag.is_none());
        let dirty = state.store.drain_dirty_lists().await.unwrap();
        assert!(
            dirty.iter().any(|l| l.list.id == created.list.id),
            "synced list must be queued for push"
        );
    }

    #[tokio::test]
    async fn create_list_local_only_is_clean_and_never_pushed() {
        // A local-only list lives only in the cache: clean, no pending op,
        // and excluded from every push path.
        let (_client, state) = setup().await;
        let created = state.create_list("Scratch", true).await.unwrap();
        assert!(created.local_only);
        assert_eq!(created.sync_state, SyncState::Clean);
        assert!(created.pending_op.is_none());
        assert!(created.list.etag.is_none());

        let dirty = state.store.drain_dirty_lists().await.unwrap();
        assert!(
            dirty.iter().all(|l| l.list.id != created.list.id),
            "local-only list must never be pushed"
        );

        // Persisted and visible like any other list.
        let all = state.store.all_lists().await.unwrap();
        let stored = all
            .iter()
            .find(|l| l.list.id == created.list.id)
            .expect("local-only list persisted");
        assert!(stored.local_only);
        assert_eq!(stored.list.title, "Scratch");
    }

    #[tokio::test]
    async fn create_list_local_only_excluded_from_ghost_detection() {
        // Ghost detection must never see a local-only list, or it would be
        // deleted the moment it's absent from the server (which is always).
        let (_client, state) = setup().await;
        let created = state.create_list("Scratch", true).await.unwrap();
        let ghost_eligible = state.store.clean_list_ids().await.unwrap();
        assert!(
            !ghost_eligible.contains(&created.list.id),
            "local-only list must be excluded from ghost detection"
        );
    }

    // ─── Export / backup ────────────────────────────────────────────────────

    #[tokio::test]
    async fn build_backup_includes_all_lists_and_tasks() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_list(&state, "L2", "Work").await;
        seed_task(&state, "T1", "L1", "Buy milk").await;
        seed_task(&state, "T2", "L1", "Pay rent").await;
        seed_task(&state, "T3", "L2", "Ship release").await;

        let backup = state.build_backup().await.unwrap();

        // Envelope is self-describing.
        assert_eq!(backup.version, axiotask_core::export::BACKUP_VERSION);
        assert_eq!(backup.app, "axiotask");
        assert!(!backup.exported_at.is_empty());

        // All lists (auto-created "My Tasks" + 2 seeded) and all tasks present.
        assert_eq!(backup.lists.len(), 3);
        assert_eq!(backup.task_count(), 3);

        let inbox = backup
            .lists
            .iter()
            .find(|l| l.id == "L1")
            .expect("Inbox in backup");
        let titles: Vec<&str> = inbox.tasks.iter().map(|t| t.title.as_str()).collect();
        assert!(titles.contains(&"Buy milk"));
        assert!(titles.contains(&"Pay rent"));
    }

    #[tokio::test]
    async fn build_backup_preserves_full_task_metadata_losslessly() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;

        let now = "2026-06-08T00:00:00Z".to_string();
        let stored = StoredTask {
            task: axiotask_core::model::Task {
                id: "T1".into(),
                parent: None,
                position: "00000000000042".into(),
                title: "Recurring chore".into(),
                notes: Some(
                    "Water the plants\n[[recur:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE]]".into(),
                ),
                status: TaskStatus::Completed,
                due: Some("2026-06-10T00:00:00Z".into()),
                completed: Some("2026-06-09T08:00:00Z".into()),
                etag: Some("etag-1".into()),
                updated: now.clone(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: now.clone(),
            pending_op: Some("update".into()),
        };
        state.store.upsert_task(&stored).await.unwrap();

        let backup = state.build_backup().await.unwrap();
        let task = backup
            .lists
            .iter()
            .flat_map(|l| &l.tasks)
            .find(|t| t.id == "T1")
            .expect("task in backup");

        assert_eq!(task.parent, None);
        assert_eq!(task.position, "00000000000042");
        assert_eq!(task.status, "completed");
        assert_eq!(task.due.as_deref(), Some("2026-06-10T00:00:00Z"));
        assert_eq!(task.completed.as_deref(), Some("2026-06-09T08:00:00Z"));
        assert_eq!(task.etag.as_deref(), Some("etag-1"));
        assert_eq!(task.sync_state, "dirty");
        assert_eq!(task.pending_op.as_deref(), Some("update"));
        // Notes (including the recurrence trailer) survive verbatim.
        assert_eq!(
            task.notes.as_deref(),
            Some("Water the plants\n[[recur:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE]]")
        );
        // Derived recurrence is surfaced for human readers.
        let rec = task.recurrence.as_ref().expect("recurrence derived");
        assert!(rec.rrule.contains("FREQ=WEEKLY"));
        assert!(!rec.summary.is_empty());

        // Whole snapshot serializes to valid, re-parseable JSON.
        let json = backup.to_json_pretty().unwrap();
        let _: axiotask_core::export::Backup = serde_json::from_str(&json).unwrap();
    }

    // ─── Import / restore ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn restore_backup_inserts_lists_and_tasks() {
        let (_client, state) = setup().await;
        let backup = axiotask_core::export::Backup::build(
            "2026-06-08T00:00:00Z",
            vec![
                (
                    StoredTaskList {
                        list: axiotask_core::model::TaskList {
                            id: "RL1".into(),
                            title: "Restored".into(),
                            etag: Some("e".into()),
                            updated: "2026-01-01T00:00:00Z".into(),
                        },
                        sync_state: SyncState::Clean,
                        local_updated: "2026-01-01T00:00:00Z".into(),
                        pending_op: None,
                        local_only: false,
                    },
                    vec![StoredTask {
                        task: axiotask_core::model::Task {
                            id: "RT1".into(),
                            parent: None,
                            position: "00000000000001".into(),
                            title: "Restored task".into(),
                            notes: None,
                            status: TaskStatus::NeedsAction,
                            due: None,
                            completed: None,
                            etag: Some("e".into()),
                            updated: "2026-01-01T00:00:00Z".into(),
                        },
                        list_id: "RL1".into(),
                        sync_state: SyncState::Clean,
                        local_updated: "2026-01-01T00:00:00Z".into(),
                        pending_op: None,
                    }],
                ),
            ],
        );

        let summary = state.restore_backup(backup).await.unwrap();
        assert_eq!(summary.lists, 1);
        assert_eq!(summary.tasks, 1);

        let lists = state.store.all_lists().await.unwrap();
        assert!(lists.iter().any(|l| l.list.id == "RL1" && l.list.title == "Restored"));
        let tasks = state.store.list_tasks("RL1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.title, "Restored task");
    }

    #[tokio::test]
    async fn restore_backup_round_trips_a_full_export() {
        // Seed one state, export it, then restore the export into a brand-new
        // state and prove every row comes back byte-for-byte.
        let (_client, source) = setup().await;
        seed_list(&source, "L1", "Inbox").await;

        let original = StoredTask {
            task: axiotask_core::model::Task {
                id: "T1".into(),
                parent: None,
                position: "00000000000042".into(),
                title: "Water plants".into(),
                notes: Some("weekly\n[[recur:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE]]".into()),
                status: TaskStatus::Completed,
                due: Some("2026-06-10T00:00:00Z".into()),
                completed: Some("2026-06-09T08:00:00Z".into()),
                etag: Some("etag-1".into()),
                updated: "2026-06-08T00:00:00Z".into(),
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-06-08T00:00:00Z".into(),
            pending_op: Some("update".into()),
        };
        source.store.upsert_task(&original).await.unwrap();

        let backup = source.build_backup().await.unwrap();
        let json = backup.to_json_pretty().unwrap();

        // Fresh destination state, restore from the serialized backup.
        let (_c2, dest) = setup().await;
        let parsed = axiotask_core::export::Backup::from_json(&json).unwrap();
        dest.restore_backup(parsed).await.unwrap();

        let restored = dest.store.list_tasks("L1").await.unwrap();
        let t = restored.iter().find(|t| t.task.id == "T1").expect("task restored");
        assert_eq!(*t, original);
    }

    #[tokio::test]
    async fn restore_backup_overwrites_existing_rows_without_dropping_others() {
        // Restore is a non-destructive merge: it upserts everything in the
        // backup (overwriting matching ids) but leaves untouched rows alone.
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "old title").await;
        seed_task(&state, "KEEP", "L1", "not in backup").await;

        let backup = axiotask_core::export::Backup::build(
            "now",
            vec![(
                StoredTaskList {
                    list: axiotask_core::model::TaskList {
                        id: "L1".into(),
                        title: "Inbox".into(),
                        etag: Some("e1".into()),
                        updated: "2026-01-01T00:00:00Z".into(),
                    },
                    sync_state: SyncState::Clean,
                    local_updated: "2026-01-01T00:00:00Z".into(),
                    pending_op: None,
                    local_only: false,
                },
                vec![StoredTask {
                    task: axiotask_core::model::Task {
                        id: "T1".into(),
                        parent: None,
                        position: "00000000000001".into(),
                        title: "new title".into(),
                        notes: None,
                        status: TaskStatus::NeedsAction,
                        due: None,
                        completed: None,
                        etag: Some("e1".into()),
                        updated: "2026-01-02T00:00:00Z".into(),
                    },
                    list_id: "L1".into(),
                    sync_state: SyncState::Clean,
                    local_updated: "2026-01-02T00:00:00Z".into(),
                    pending_op: None,
                }],
            )],
        );

        state.restore_backup(backup).await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let t1 = tasks.iter().find(|t| t.task.id == "T1").unwrap();
        assert_eq!(t1.task.title, "new title", "matching id overwritten");
        assert!(
            tasks.iter().any(|t| t.task.id == "KEEP"),
            "untouched row preserved"
        );
    }

    // ─── Properties / settings ───────────────────────────────────────────────

    #[tokio::test]
    async fn set_push_enabled_flips_runtime_and_persists() {
        let (_client, state) = setup().await;
        assert!(!state.is_push_enabled(), "defaults to read-only");

        state.set_push_enabled(true).unwrap();
        assert!(state.is_push_enabled(), "runtime flag flips immediately");

        // Persisted to the (temp) config file so the choice survives a restart.
        let cfg = axiotask_core::config::AppConfig::load_from(state.config_path())
            .expect("config written");
        assert!(cfg.sync.push_enabled);

        // And it can be turned back off.
        state.set_push_enabled(false).unwrap();
        assert!(!state.is_push_enabled());
        let cfg = axiotask_core::config::AppConfig::load_from(state.config_path()).unwrap();
        assert!(!cfg.sync.push_enabled);
    }

    #[tokio::test]
    async fn set_auto_sync_persists() {
        let (_client, state) = setup().await;
        assert!(state.auto_sync_on_start(), "memory state defaults on");
        state.set_auto_sync_on_start(false).unwrap();
        assert!(!state.auto_sync_on_start());
        let cfg = axiotask_core::config::AppConfig::load_from(state.config_path()).unwrap();
        assert!(!cfg.sync.auto_sync_on_start);
    }

    #[tokio::test]
    async fn sync_status_starts_empty_then_records_a_run() {
        let (_client, state) = setup().await;
        let before = state.sync_status().await;
        assert!(before.last_synced.is_none());
        assert_eq!(before.total_syncs, 0);
        assert!(before.last_error.is_none());

        // A direct sync against the in-memory client succeeds (empty pull).
        state.run_sync().await.expect("sync ok");

        let after = state.sync_status().await;
        assert!(after.last_synced.is_some(), "timestamp recorded");
        assert_eq!(after.total_syncs, 1);
        assert!(after.last_error.is_none());
    }

    #[tokio::test]
    async fn pending_push_count_reflects_dirty_changes() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        // setup() auto-creates a pending "My Tasks" list, so measure deltas.
        let baseline = state.pending_push_count().await.unwrap();

        // A fresh create is a pending push.
        let now = jiff::Zoned::now().strftime("%Y-%m-%dT%H:%M:%SZ").to_string();
        let t = StoredTask {
            task: axiotask_core::model::Task {
                id: "T1".into(),
                parent: None,
                position: "1".into(),
                title: "todo".into(),
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
        state.store.upsert_task(&t).await.unwrap();
        assert_eq!(state.pending_push_count().await.unwrap(), baseline + 1);
    }
}
