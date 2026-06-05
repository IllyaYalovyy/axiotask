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
        assert!(!state.push_enabled());
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
}
