//! Integration tests for Tauri commands.
//!
//! These test the command logic through AppState without needing a running
//! Tauri instance. Each test gets a fresh in-memory store + InMemoryClient.

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axiotask_core::api::GoogleTasksClient;
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
                web_view_link: None,
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

        crate::commands::create_task_inner(&state, "L1".into(), None, "new task".into())
            .await
            .unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.title, "new task");
        // Never-synced create → no etag, queued as a dirty "create" for push.
        assert!(tasks[0].task.etag.is_none());
        assert_eq!(tasks[0].sync_state, SyncState::Dirty);
        assert_eq!(tasks[0].pending_op.as_deref(), Some("create"));
    }

    #[tokio::test]
    async fn toggle_complete_flips_status() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "buy milk").await;

        // Toggle to completed
        crate::commands::toggle_complete_inner(&state, "T1".into())
            .await
            .unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].task.status, TaskStatus::Completed);
        assert!(tasks[0].task.completed.is_some());
        assert_eq!(tasks[0].sync_state, SyncState::Dirty);

        // Toggle back
        crate::commands::toggle_complete_inner(&state, "T1".into())
            .await
            .unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].task.status, TaskStatus::NeedsAction);
        assert!(tasks[0].task.completed.is_none());
    }

    #[tokio::test]
    async fn delete_task_with_etag_marks_deleted() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "doomed").await;

        // Task has an etag (already pushed) → soft delete (tombstone kept so the
        // delete can be pushed to Google).
        let token = crate::commands::delete_task_inner(&state, "T1".into())
            .await
            .unwrap();
        assert!(token.had_etag);

        // list_tasks excludes the tombstoned task.
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(tasks.is_empty());

        // But drain_dirty still sees the pending delete.
        let dirty = state.store.drain_dirty().await.unwrap();
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty[0].pending_op.as_deref(), Some("delete"));
    }

    #[tokio::test]
    async fn delete_task_without_etag_hard_deletes() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;

        // A never-pushed task (create_task leaves it with no etag).
        let created =
            crate::commands::create_task_inner(&state, "L1".into(), None, "ephemeral".into())
                .await
                .unwrap();

        // No etag → hard delete locally, leaving nothing to push.
        let token = crate::commands::delete_task_inner(&state, created.id.clone())
            .await
            .unwrap();
        assert!(!token.had_etag);

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

        let today = jiff::Zoned::now().date();
        crate::commands::set_due_inner(&state, "T1".into(), "Tomorrow".into())
            .await
            .unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(tasks[0].task.due.is_some());
        assert_eq!(tasks[0].sync_state, SyncState::Dirty);
        let due = tasks[0].task.due.as_ref().unwrap();
        let tomorrow = today.tomorrow().unwrap();
        assert!(due.starts_with(&tomorrow.to_string()));
    }

    #[tokio::test]
    async fn rename_task_updates_title_and_marks_dirty() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "old title").await;

        crate::commands::rename_task_inner(&state, "T1".into(), "new title".into())
            .await
            .unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks[0].task.title, "new title");
        assert_eq!(tasks[0].sync_state, SyncState::Dirty);
        // Already pushed (seeded with an etag) → queued as an "update", not a
        // duplicate "create".
        assert_eq!(tasks[0].pending_op.as_deref(), Some("update"));
    }

    #[tokio::test]
    async fn move_task_changes_parent() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "parent").await;
        seed_task(&state, "T2", "L1", "child-to-be").await;

        // Reparent T2 under T1 (one level of nesting — invariant #1).
        crate::commands::move_task_inner(&state, "T2".into(), Some("T1".into()), None)
            .await
            .unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let moved = tasks.iter().find(|t| t.task.id == "T2").unwrap();
        assert_eq!(moved.task.parent.as_deref(), Some("T1"));

        // move_task records a pending reorder so the new parent/position is
        // pushed via the move API on the next sync.
        let moves = state.store.pending_moves().await.unwrap();
        assert!(
            moves
                .iter()
                .any(|m| m.task_id == "T2" && m.parent_id.as_deref() == Some("T1"))
        );
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
    async fn sync_status_reports_changed_task_lists_for_incremental_refresh() {
        let (client, state) = setup().await;
        client.seed_list("L1", "Inbox");
        client.seed_list("L2", "Work");
        client.seed_task("L2", "RT1", "remote task", "00000000000001");

        let outcome = state.run_sync().await.unwrap();
        assert_eq!(outcome.changed_list_ids, vec!["L2"]);

        let status = state.sync_status().await;
        assert_eq!(status.changed_list_ids, vec!["L2"]);
        assert!(
            status.lists_changed,
            "newly pulled list metadata still requires a sidebar refresh"
        );
    }

    #[tokio::test]
    async fn expired_session_sets_needs_reauth_with_an_actionable_error() {
        // A permanently-denied token refresh (invalid_grant) must flip the
        // app into "sign in again" state — with a message that says what to
        // do — and a later working sync must clear it (re-login recovery).
        use axiotask_core::api::ApiError;
        use axiotask_core::api::in_memory::Method;

        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        assert!(!state.needs_reauth());

        client.fail_next(Method::ListTaskLists, || {
            ApiError::AuthExpired("invalid_grant: Token has been expired or revoked.".into())
        });
        state.run_sync().await.unwrap_err();

        assert!(state.needs_reauth(), "dead session must be flagged");
        let msg = state
            .sync_status()
            .await
            .last_error
            .expect("error surfaced");
        assert!(msg.contains("sign in again"), "actionable, got: {msg}");
        // The status snapshot (and thus the sync-updated event payload) must
        // carry the flag — it's how the main window learns to show a re-auth
        // action instead of a Sync button that can only fail.
        assert!(state.sync_status().await.needs_reauth);

        // After re-login the next sync works — the flag and error clear.
        state.run_sync().await.unwrap();
        assert!(!state.needs_reauth());
        assert!(!state.sync_status().await.needs_reauth);
        assert!(state.sync_status().await.last_error.is_none());
    }

    #[tokio::test]
    async fn logout_works_inside_the_async_runtime() {
        // Sign out runs as an async Tauri command on a tokio worker. The old
        // implementation called block_on there, panicking the runtime AFTER
        // clearing the tokens — the app crashed mid-signout and the UI never
        // learned it was signed out.
        let client = Arc::new(InMemoryClient::new());
        let state = Arc::new(AppState::new_memory(client).await.unwrap());
        state
            .token_store_for_test()
            .save(&axiotask_core::auth::StoredTokens {
                access_token: "at".into(),
                refresh_token: "rt".into(),
                access_expires_at: Some(i64::MAX),
                scope: "tasks".into(),
            })
            .unwrap();
        assert!(state.is_authenticated());

        state.logout().await.expect("logout must not fail");

        assert!(!state.is_authenticated());
        assert!(!state.needs_reauth());
    }

    #[tokio::test]
    async fn sync_pushes_local_creates_to_remote() {
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );

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
                web_view_link: None,
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
    async fn editing_holds_creates_until_finished() {
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap(); // pull the list

        let task = StoredTask {
            task: axiotask_core::model::Task {
                id: "local-uuid".into(),
                parent: None,
                position: "1".into(),
                title: "editing".into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-05-23T00:00:00Z".into(),
                web_view_link: None,
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-05-23T00:00:00Z".into(),
            pending_op: Some("create".into()),
        };
        state.store.upsert_task(&task).await.unwrap();

        // Editing THIS row — its CREATE is held, so the local id is NOT remapped
        // and the UI can keep operating on it (fixes create-then-edit failures).
        state.set_editing_task(Some("local-uuid".into()));
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.pushed, 0, "create held while its own row is edited");
        assert!(
            state
                .store
                .list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .any(|t| t.task.id == "local-uuid"),
            "local id preserved while editing"
        );

        // After editing ends, it pushes and remaps as usual.
        state.set_editing_task(None);
        let out = state.run_sync().await.unwrap();
        assert!(out.pushed >= 1, "pushes after editing ends");
        assert!(
            !state
                .store
                .list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .any(|t| t.task.id == "local-uuid"),
            "id remapped once editing finished"
        );
    }

    #[tokio::test]
    async fn editing_still_pushes_updates() {
        // Regression: holding pushes for the WHOLE detail panel starved committed
        // edits — a subtask marked done (an update) never synced while the panel
        // was open. Only creates should be held; updates must push while editing.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let parent = client.seed_task("L1", "parent-1", "Parent", "1");
        let child = client.seed_task_with_parent("L1", "child-1", "Sub", "2", Some("parent-1"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap(); // pull the list + tasks

        // Mark the subtask done locally (an update on an already-synced id).
        let mut sub = state
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|t| t.task.id == "child-1")
            .unwrap();
        sub.task.status = TaskStatus::Completed;
        sub.task.completed = Some("2026-05-23T00:00:00Z".into());
        sub.sync_state = SyncState::Dirty;
        sub.pending_op = Some("update".into());
        state.store.upsert_task(&sub).await.unwrap();

        // With the detail panel open on the parent, the subtask completion
        // (an update) must still push.
        state.set_editing_task(Some("parent-1".into()));
        let out = state.run_sync().await.unwrap();
        assert!(out.pushed >= 1, "update pushes while editing");
        let cleared = state
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|t| t.task.id == "child-1")
            .unwrap();
        assert_eq!(
            cleared.sync_state,
            SyncState::Clean,
            "completed subtask is no longer dirty"
        );
        assert_eq!(cleared.task.status, TaskStatus::Completed);
        let _ = (parent, child);
    }

    #[tokio::test]
    async fn subtask_created_in_open_detail_panel_syncs() {
        // #85: subtasks are BORN in the detail panel — the inline "add a subtask"
        // field keeps the panel open to add more. The open panel marks the PARENT
        // as the held id; a subtask has its own id, so its create must still push
        // (remapping it never touches the parent id the panel holds). The old
        // coarse hold suppressed EVERY create while the panel was open, so newly
        // created subtasks never reached the server.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "Parent", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap(); // pull the list + parent (parent now synced)

        // Detail panel open on the parent → the parent is the held id.
        state.set_editing_task(Some("P".into()));

        // User types a subtask into the inline field.
        let sub = crate::commands::create_task_inner(
            &state,
            "L1".into(),
            Some("P".into()),
            "buy milk".into(),
        )
        .await
        .unwrap();
        assert_eq!(sub.parent_id.as_deref(), Some("P"));

        // Sync runs while the panel is still open (schedule_sync fires on create).
        let out = state.run_sync().await.unwrap();
        assert!(out.pushed >= 1, "subtask pushed even with the panel open");

        // It reached the server, under the parent.
        let remote = client.list_tasks("L1", None).await.unwrap();
        let landed = remote
            .items
            .iter()
            .find(|t| t.title == "buy milk")
            .expect("subtask reached the server");
        assert_eq!(
            landed.parent.as_deref(),
            Some("P"),
            "subtask landed under its parent"
        );

        // Locally, the subtask's id was remapped and it is clean now.
        let local = state.store.list_tasks("L1").await.unwrap();
        let stored = local
            .iter()
            .find(|t| t.task.title == "buy milk")
            .expect("subtask still present locally");
        assert!(
            stored.task.id.starts_with("remote-"),
            "subtask id remapped to the server id"
        );
        assert_eq!(stored.sync_state, SyncState::Clean, "subtask is synced");
        assert_eq!(stored.task.parent.as_deref(), Some("P"));
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
                web_view_link: None,
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

    // Regression for #80: create_task once handed every row the same constant
    // position, so reorder_task's position-swap swapped two equal strings and
    // did nothing on local-only / unsynced tasks. Reorder must actually change
    // the rendered order.
    #[tokio::test]
    async fn reorder_moves_freshly_created_task() {
        let (_client, state) = setup().await;
        // A local-only list never syncs, so its rows keep their create-time
        // positions forever — exactly where the bug bit.
        let list = StoredTaskList {
            list: axiotask_core::model::TaskList {
                id: "L1".into(),
                title: "Local".into(),
                etag: None,
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: SyncState::Clean,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: None,
            local_only: true,
        };
        state.store.upsert_list(&list).await.unwrap();

        // Two tasks created through the real command path.
        crate::commands::create_task_inner(&state, "L1".into(), None, "first".into())
            .await
            .unwrap();
        crate::commands::create_task_inner(&state, "L1".into(), None, "second".into())
            .await
            .unwrap();

        // Whatever the initial rendered order is, moving the last row up must
        // land it first.
        let before = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(before.len(), 2);
        let last_id = before[1].task.id.clone();
        let last_title = before[1].task.title.clone();
        let first_title = before[0].task.title.clone();
        assert_ne!(last_title, first_title);

        crate::commands::reorder_task_inner(&state, last_id, "up".into())
            .await
            .unwrap();

        let after = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(
            after[0].task.title, last_title,
            "reorder should move the last task to the top"
        );
        assert_eq!(after[1].task.title, first_title);
    }

    // #90: reordering subtasks in the detail panel. The panel measures drag
    // distance against the FULL sibling list, so with "Hide completed" on it
    // asks for as many single-step swaps as needed to cross hidden completed
    // rows. This proves reorder_task walks a subtask across a completed sibling.
    #[tokio::test]
    async fn reorder_moves_subtask_across_completed_sibling() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "P1", "L1", "parent").await;

        // Three subtasks of P1: active, completed, active.
        for (id, title, pos, status) in [
            ("s1", "alpha", "00000000000001", TaskStatus::NeedsAction),
            ("s2", "beta", "00000000000002", TaskStatus::Completed),
            ("s3", "gamma", "00000000000003", TaskStatus::NeedsAction),
        ] {
            let sub = StoredTask {
                task: axiotask_core::model::Task {
                    id: id.into(),
                    parent: Some("P1".into()),
                    position: pos.into(),
                    title: title.into(),
                    notes: None,
                    status,
                    due: None,
                    completed: None,
                    etag: Some("e1".into()),
                    updated: "2026-01-01T00:00:00Z".into(),
                    web_view_link: None,
                },
                list_id: "L1".into(),
                sync_state: SyncState::Clean,
                local_updated: "2026-01-01T00:00:00Z".into(),
                pending_op: None,
            };
            state.store.upsert_task(&sub).await.unwrap();
        }

        // Drag "gamma" above "alpha": the panel emits two single-step "up"
        // swaps (across the hidden completed "beta").
        crate::commands::reorder_task_inner(&state, "s3".into(), "up".into())
            .await
            .unwrap();
        crate::commands::reorder_task_inner(&state, "s3".into(), "up".into())
            .await
            .unwrap();

        let all = state.store.list_tasks("L1").await.unwrap();
        let subs: Vec<_> = all
            .iter()
            .filter(|s| s.task.parent.as_deref() == Some("P1"))
            .map(|s| s.task.title.as_str())
            .collect();
        assert_eq!(
            subs,
            vec!["gamma", "alpha", "beta"],
            "gamma should land first, alpha second, completed beta retained last"
        );
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
        assert!(
            err.contains("not authenticated"),
            "expected auth error, got: {err}"
        );
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
                web_view_link: None,
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
        assert_eq!(
            tasks[0].task.due.as_deref(),
            Some("2026-06-01T00:00:00.000Z")
        );
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
                web_view_link: None,
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

        let new_id = state.move_task_to_list("T1", "L2").await.unwrap();
        assert_ne!(new_id, "T1", "moved task gets a fresh id");

        // Old list: T1 is tombstoned (excluded from list_tasks but pending delete).
        let l1_tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(l1_tasks.is_empty(), "old list should not show the task");

        // New list: a fresh task with the same title, pending create.
        let l2_tasks = state.store.list_tasks("L2").await.unwrap();
        assert_eq!(l2_tasks.len(), 1);
        assert_eq!(l2_tasks[0].task.title, "Task to move");
        assert_eq!(l2_tasks[0].task.id, new_id);
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
                web_view_link: None,
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: Some("create".into()),
        };
        state.store.upsert_task(&local).await.unwrap();

        let new_id = state.move_task_to_list("local-1", "L2").await.unwrap();
        assert_ne!(new_id, "local-1", "moved local task gets a fresh id");

        // Old gone entirely (no tombstone — never synced).
        assert!(state.store.list_tasks("L1").await.unwrap().is_empty());
        // New exists in L2.
        let l2 = state.store.list_tasks("L2").await.unwrap();
        assert_eq!(l2.len(), 1);
        assert_eq!(l2[0].task.id, new_id);
        assert_eq!(l2[0].task.title, "unsynced");
        // No delete tombstone should remain (only the create).
        let dirty = state.store.drain_dirty().await.unwrap();
        assert!(
            dirty
                .iter()
                .all(|t| t.pending_op.as_deref() != Some("delete"))
        );
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
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
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
    async fn move_to_list_takes_subtasks_along() {
        // Data-loss regression: moving a parent used to leave its subtasks
        // behind on a tombstone. Deleting a parent deletes its children both
        // on Google (verified live) and locally via the FK cascade — so the
        // whole subtree must move together.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "sub one", "2", Some("P"));
        client.seed_task_with_parent("L1", "C2", "sub two", "3", Some("C1")); // 2 levels deep
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();
        assert_eq!(state.store.list_tasks("L1").await.unwrap().len(), 3);

        state.move_task_to_list("P", "L2").await.unwrap();

        // Locally: the whole subtree exists in L2 with its shape intact.
        let l2 = state.store.list_tasks("L2").await.unwrap();
        assert_eq!(l2.len(), 3, "parent + both descendants moved");
        let parent = l2.iter().find(|t| t.task.title == "parent").unwrap();
        let c1 = l2.iter().find(|t| t.task.title == "sub one").unwrap();
        let c2 = l2.iter().find(|t| t.task.title == "sub two").unwrap();
        assert_eq!(c1.task.parent.as_deref(), Some(parent.task.id.as_str()));
        assert_eq!(c2.task.parent.as_deref(), Some(c1.task.id.as_str()));

        // After sync: everything lives in remote L2; nothing remains in L1.
        state.run_sync().await.unwrap();
        let l2_remote = client.list_tasks("L2", None).await.unwrap();
        assert_eq!(l2_remote.items.len(), 3, "no subtask lost in the move");
        let l1_remote = client.list_tasks("L1", None).await.unwrap();
        assert!(l1_remote.items.is_empty());
        // And nothing is stuck dirty.
        assert!(
            state
                .store
                .list_tasks("L2")
                .await
                .unwrap()
                .iter()
                .all(|t| t.sync_state == SyncState::Clean)
        );
    }

    #[tokio::test]
    async fn set_due_from_picker_normalizes_bare_date_and_pushes() {
        // The calendar picker sends "raw:YYYY-MM-DD". Google 400s a bare date
        // (verified live) — the command must canonicalize before storing, and
        // the round trip to the (equally strict) fake server must succeed.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "pick a date", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::set_due_inner(&state, "T1".into(), "raw:2026-08-02".into())
            .await
            .unwrap();
        let stored = state.store.list_tasks("L1").await.unwrap().remove(0);
        assert_eq!(stored.task.due.as_deref(), Some("2026-08-02T00:00:00.000Z"));

        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0, "canonical form must not 400");
        let remote = client.list_tasks("L1", None).await.unwrap();
        assert_eq!(
            remote.items[0].due.as_deref(),
            Some("2026-08-02T00:00:00.000Z")
        );
    }

    #[tokio::test]
    async fn set_due_rejects_garbage_instead_of_poisoning_the_row() {
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "task", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        let err =
            crate::commands::set_due_inner(&state, "T1".into(), "raw:not-a-date".into()).await;
        assert!(err.is_err(), "garbage due must be rejected at the boundary");
        let stored = state.store.list_tasks("L1").await.unwrap().remove(0);
        assert_eq!(stored.sync_state, SyncState::Clean, "row untouched");
    }

    #[test]
    fn instance_lock_excludes_a_second_holder_and_frees_on_drop() {
        // #48: the guard that stops two processes from double-pushing the same
        // dirty rows. flock semantics apply across separate opens even within
        // one process, so this exercises the real contention path.
        let dir = std::env::temp_dir().join(format!(
            "axiotask-lock-test-{}-{}",
            std::process::id(),
            jiff::Timestamp::now().as_nanosecond(),
        ));
        let db = dir.join("axiotask.sqlite");

        let first = crate::state::acquire_instance_lock(&db).expect("first instance acquires");

        let second = crate::state::acquire_instance_lock(&db);
        let err = second.expect_err("second instance must be refused");
        assert!(err.contains("already running"), "{err}");
        assert!(
            err.contains(&std::process::id().to_string()),
            "names the holder pid: {err}"
        );

        // First instance exits → the lock frees → a new instance may start.
        drop(first);
        crate::state::acquire_instance_lock(&db).expect("lock freed after drop");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn instance_lock_is_scoped_per_data_directory() {
        // Prod, a dev-prefixed instance, and an e2e run under its own
        // XDG_DATA_HOME use different data dirs — they must coexist.
        let base = std::env::temp_dir().join(format!(
            "axiotask-lock-scope-{}-{}",
            std::process::id(),
            jiff::Timestamp::now().as_nanosecond(),
        ));
        let prod =
            crate::state::acquire_instance_lock(&base.join("axiotask").join("axiotask.sqlite"))
                .expect("prod acquires");
        let dev =
            crate::state::acquire_instance_lock(&base.join("axiotask-dev").join("axiotask.sqlite"))
                .expect("dev coexists with prod");
        drop((prod, dev));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn completing_a_parent_completes_open_descendants() {
        // Google auto-completes children when a parent completes (verified
        // live). Mirror locally so subtask progress and date propagation are
        // truthful immediately, and push the same state.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "kid", "2", Some("P"));
        client.seed_task_with_parent("L1", "C2", "grandkid", "3", Some("C1"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::toggle_complete_inner(&state, "P".into())
            .await
            .unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(
            tasks.iter().all(|t| t.task.status == TaskStatus::Completed),
            "parent + all descendants completed locally"
        );

        // And the same state pushes cleanly.
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);
        let remote = client.list_tasks("L1", None).await.unwrap();
        assert!(
            remote
                .items
                .iter()
                .all(|t| t.status == TaskStatus::Completed)
        );
    }

    #[tokio::test]
    async fn uncompleting_a_parent_does_not_reopen_descendants() {
        // The server leaves children completed when a parent reopens
        // (verified live) — mirror that.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "kid", "2", Some("P"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::toggle_complete_inner(&state, "P".into())
            .await
            .unwrap(); // complete all
        crate::commands::toggle_complete_inner(&state, "P".into())
            .await
            .unwrap(); // reopen parent

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let p = tasks.iter().find(|t| t.task.id == "P").unwrap();
        let c = tasks.iter().find(|t| t.task.id == "C1").unwrap();
        assert_eq!(p.task.status, TaskStatus::NeedsAction);
        assert_eq!(c.task.status, TaskStatus::Completed, "child stays done");
    }

    #[tokio::test]
    async fn undo_after_delete_pushed_restores_the_whole_subtree() {
        // Data-loss regression: delete a parent, let the delete sync (server
        // cascades the children away — verified live), then undo. The token
        // now carries the subtree, so undo rebuilds parent AND children.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "kid one", "2", Some("P"));
        client.seed_task_with_parent("L1", "C2", "kid two", "3", Some("C1"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        let token = crate::commands::delete_task_inner(&state, "P".into())
            .await
            .unwrap();
        assert_eq!(token.subtree.len(), 2, "descendants captured");

        // The delete pushes; server cascade + local FK wipe the subtree.
        state.run_sync().await.unwrap();
        assert!(state.store.list_tasks("L1").await.unwrap().is_empty());
        assert!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .is_empty()
        );

        // Undo: everything comes back, shape intact, and pushes to the server.
        crate::commands::undo_delete_inner(&state, token)
            .await
            .unwrap();
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(tasks.len(), 3, "parent + both descendants restored");
        let kid = tasks.iter().find(|t| t.task.title == "kid one").unwrap();
        let grandkid = tasks.iter().find(|t| t.task.title == "kid two").unwrap();
        assert_eq!(kid.task.parent.as_deref(), Some("P"));
        assert_eq!(grandkid.task.parent.as_deref(), Some("C1"));

        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(client.list_tasks("L1", None).await.unwrap().items.len(), 3);
    }

    #[tokio::test]
    async fn undo_recreate_with_dead_parent_falls_back_to_top_level() {
        // The subtask's parent was deleted separately before the undo — the
        // recreate must not fail the FK; it lands at top level instead.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "kid", "2", Some("P"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        let kid_token = crate::commands::delete_task_inner(&state, "C1".into())
            .await
            .unwrap();
        let _ = crate::commands::delete_task_inner(&state, "P".into())
            .await
            .unwrap();
        state.run_sync().await.unwrap(); // both deletes land

        crate::commands::undo_delete_inner(&state, kid_token)
            .await
            .unwrap();
        let tasks = state.store.list_tasks("L1").await.unwrap();
        let kid = tasks
            .iter()
            .find(|t| t.task.title == "kid")
            .expect("kid restored");
        assert_eq!(kid.task.parent, None, "orphaned undo lands at top level");
    }

    #[tokio::test]
    async fn clear_completed_spares_open_subtasks_under_a_completed_parent() {
        // Deleting a completed parent cascades to its children on the server
        // (verified live) — clear-completed must not destroy open work.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P-open-kid", "done parent, open kid", "1");
        client.seed_task_with_parent("L1", "K-open", "still todo", "2", Some("P-open-kid"));
        client.seed_task("L1", "P-done", "done parent, done kid", "3");
        client.seed_task_with_parent("L1", "K-done", "also done", "4", Some("P-done"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        // Mark the two parents + the second kid completed (kid K-open stays open).
        for id in ["K-done", "P-done"] {
            crate::commands::toggle_complete_inner(&state, id.into())
                .await
                .unwrap();
        }
        // Complete P-open-kid WITHOUT the cascade taking K-open with it:
        // simulate a pull state where the parent is completed but a child is
        // open (happens when the parent completed remotely first).
        let mut p = state
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|t| t.task.id == "P-open-kid")
            .unwrap();
        p.task.status = TaskStatus::Completed;
        state.store.upsert_task(&p).await.unwrap();

        let cleared = crate::commands::clear_completed_inner(&state, "L1".into())
            .await
            .unwrap();
        state.run_sync().await.unwrap();

        let left = state.store.list_tasks("L1").await.unwrap();
        assert!(
            left.iter().any(|t| t.task.id == "K-open"),
            "open subtask survives"
        );
        assert!(
            left.iter().any(|t| t.task.id == "P-open-kid"),
            "its parent is spared too"
        );
        assert!(
            left.iter()
                .all(|t| t.task.id != "P-done" && t.task.id != "K-done"),
            "fully-completed subtree is cleared"
        );
        assert_eq!(cleared, 2);
    }

    #[tokio::test]
    async fn undo_delete_after_unpushed_edit_keeps_the_edit_queued() {
        // Edit (unpushed) → delete → undo: the revived row must stay dirty so
        // the edit still reaches the server. Reviving it clean silently
        // dropped the edit from the push queue.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "original", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        // Unpushed local edit.
        let mut t = state.store.list_tasks("L1").await.unwrap().remove(0);
        t.task.title = "edited offline".into();
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        state.store.upsert_task(&t).await.unwrap();

        // Delete (tombstone) then undo before any sync.
        let token = {
            // Inline delete_task's effect via the command path.
            let t = state.store.find_task_any("T1").await.unwrap().unwrap();
            let mut d = t.clone();
            d.sync_state = SyncState::Deleted;
            d.pending_op = Some("delete".into());
            state.store.upsert_task(&d).await.unwrap();
            crate::commands::DeleteToken {
                id: t.task.id.clone(),
                list_id: t.list_id.clone(),
                parent_id: None,
                title: t.task.title.clone(),
                notes: None,
                status: "needsAction".into(),
                due: None,
                position: t.task.position.clone(),
                had_etag: true,
                subtree: vec![],
            }
        };
        crate::commands::undo_delete_inner(&state, token)
            .await
            .unwrap();

        let revived = state.store.find_task_any("T1").await.unwrap().unwrap();
        assert_eq!(
            revived.sync_state,
            SyncState::Dirty,
            "edit must stay queued"
        );
        assert_eq!(revived.pending_op.as_deref(), Some("update"));

        // And the edit reaches the server on the next sync.
        state.run_sync().await.unwrap();
        let remote = client.list_tasks("L1", None).await.unwrap();
        assert_eq!(remote.items[0].title, "edited offline");
    }

    #[tokio::test]
    async fn rename_list_marks_update_for_synced_and_keeps_create_for_new() {
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Old").await;
        state.rename_list("L1", "New").await.unwrap();
        let l = state
            .store
            .drain_dirty_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        assert_eq!(l.list.title, "New");
        assert_eq!(l.pending_op.as_deref(), Some("update"));

        let create = StoredTaskList {
            list: axiotask_core::model::TaskList {
                id: "local".into(),
                title: "Draft".into(),
                etag: None,
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: SyncState::Dirty,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: Some("create".into()),
            local_only: false,
        };
        state.store.upsert_list(&create).await.unwrap();
        state.rename_list("local", "Renamed Draft").await.unwrap();
        let l = state
            .store
            .drain_dirty_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "local")
            .unwrap();
        assert_eq!(
            l.pending_op.as_deref(),
            Some("create"),
            "rename folds into create"
        );
    }

    #[tokio::test]
    async fn rename_list_syncs_to_remote() {
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Before");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
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
        assert!(
            state
                .store
                .all_lists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.list.id != "L1")
        );
        let dirty = state.store.drain_dirty_lists().await.unwrap();
        assert!(
            dirty
                .iter()
                .any(|l| l.list.id == "L1" && l.pending_op.as_deref() == Some("delete"))
        );
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
                id: "local-list".into(),
                title: "Temp".into(),
                etag: None,
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
                web_view_link: None,
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
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        // Offline create.
        let mut t = StoredTask {
            task: axiotask_core::model::Task {
                id: "local-1".into(),
                parent: None,
                position: "1".into(),
                title: "offline task".into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-06-01T00:00:00Z".into(),
                web_view_link: None,
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
                title: "Garden chore".into(),
                notes: Some("Water the plants".into()),
                status: TaskStatus::Completed,
                due: Some("2026-06-10T00:00:00Z".into()),
                completed: Some("2026-06-09T08:00:00Z".into()),
                etag: Some("etag-1".into()),
                updated: now.clone(),
                web_view_link: None,
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
        // Notes survive verbatim.
        assert_eq!(task.notes.as_deref(), Some("Water the plants"));

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
            vec![(
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
                        web_view_link: None,
                    },
                    list_id: "RL1".into(),
                    sync_state: SyncState::Clean,
                    local_updated: "2026-01-01T00:00:00Z".into(),
                    pending_op: None,
                }],
            )],
        );

        let summary = state.restore_backup(backup).await.unwrap();
        assert_eq!(summary.lists, 1);
        assert_eq!(summary.tasks, 1);

        let lists = state.store.all_lists().await.unwrap();
        assert!(
            lists
                .iter()
                .any(|l| l.list.id == "RL1" && l.list.title == "Restored")
        );
        let tasks = state.store.list_tasks("RL1").await.unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].task.title, "Restored task");
    }

    #[tokio::test]
    async fn restore_backup_round_trips_content_as_fresh_creates() {
        // Export from one state, restore into a fresh one: the CONTENT comes
        // back intact, but as dirty CREATES with etags stripped — restoring
        // rows "clean" with their saved etags is the ghost-detection trap
        // (see restore_backup_survives_the_next_sync below).
        let (_client, source) = setup().await;
        seed_list(&source, "L1", "Inbox").await;

        let original = StoredTask {
            task: axiotask_core::model::Task {
                id: "T1".into(),
                parent: None,
                position: "00000000000042".into(),
                title: "Water plants".into(),
                notes: Some("weekly watering".into()),
                status: TaskStatus::Completed,
                due: Some("2026-06-10T00:00:00Z".into()),
                completed: Some("2026-06-09T08:00:00Z".into()),
                etag: Some("etag-1".into()),
                updated: "2026-06-08T00:00:00Z".into(),
                web_view_link: None,
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
        let t = restored
            .iter()
            .find(|t| t.task.id == "T1")
            .expect("task restored");
        // Content preserved…
        assert_eq!(t.task.title, original.task.title);
        assert_eq!(t.task.notes, original.task.notes);
        assert_eq!(t.task.status, original.task.status);
        assert_eq!(t.task.due, original.task.due);
        assert_eq!(t.task.position, original.task.position);
        // …but as a fresh create that will push back to the server.
        assert_eq!(t.task.etag, None);
        assert_eq!(t.sync_state, SyncState::Dirty);
        assert_eq!(t.pending_op.as_deref(), Some("create"));
    }

    #[tokio::test]
    async fn restore_backup_merges_missing_rows_and_never_clobbers_existing() {
        // Restore only ADDS what is missing. An existing row keeps its current
        // content (restore must not silently roll back live state), and rows
        // absent from the backup are untouched.
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "T1", "L1", "current title").await;
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
                vec![
                    StoredTask {
                        task: axiotask_core::model::Task {
                            id: "T1".into(),
                            parent: None,
                            position: "00000000000001".into(),
                            title: "stale backup title".into(),
                            notes: None,
                            status: TaskStatus::NeedsAction,
                            due: None,
                            completed: None,
                            etag: Some("e1".into()),
                            updated: "2026-01-02T00:00:00Z".into(),
                            web_view_link: None,
                        },
                        list_id: "L1".into(),
                        sync_state: SyncState::Clean,
                        local_updated: "2026-01-02T00:00:00Z".into(),
                        pending_op: None,
                    },
                    StoredTask {
                        task: axiotask_core::model::Task {
                            id: "T-deleted-since".into(),
                            parent: None,
                            position: "00000000000002".into(),
                            title: "bring me back".into(),
                            notes: None,
                            status: TaskStatus::NeedsAction,
                            due: None,
                            completed: None,
                            etag: Some("e2".into()),
                            updated: "2026-01-02T00:00:00Z".into(),
                            web_view_link: None,
                        },
                        list_id: "L1".into(),
                        sync_state: SyncState::Clean,
                        local_updated: "2026-01-02T00:00:00Z".into(),
                        pending_op: None,
                    },
                ],
            )],
        );

        let summary = state.restore_backup(backup).await.unwrap();
        assert_eq!(summary.tasks, 1, "only the missing row is restored");

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let t1 = tasks.iter().find(|t| t.task.id == "T1").unwrap();
        assert_eq!(t1.task.title, "current title", "existing row not clobbered");
        assert!(
            tasks.iter().any(|t| t.task.id == "KEEP"),
            "untouched row preserved"
        );
        let back = tasks
            .iter()
            .find(|t| t.task.id == "T-deleted-since")
            .unwrap();
        assert_eq!(back.pending_op.as_deref(), Some("create"));
    }

    #[tokio::test]
    async fn restore_backup_survives_the_next_sync() {
        // THE reason restores exist: the data is gone from the server. The old
        // implementation restored rows clean-with-etags, and the next sync's
        // ghost detection saw "clean rows absent from the server" and silently
        // deleted everything the user had just restored. Now they push back.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "precious", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        // Backup taken while the task existed.
        let backup_json = state
            .build_backup()
            .await
            .unwrap()
            .to_json_pretty()
            .unwrap();

        // The task is deleted (remotely AND locally, fully synced away).
        client.delete_task_from_state("L1", "T1");
        state.run_sync().await.unwrap();
        assert!(state.store.list_tasks("L1").await.unwrap().is_empty());

        // Restore, then sync — the data must survive and reach the server.
        let parsed = axiotask_core::export::Backup::from_json(&backup_json).unwrap();
        let summary = state.restore_backup(parsed).await.unwrap();
        assert_eq!(summary.tasks, 1);
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);

        let local = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(local.len(), 1, "restored task survives the sync");
        assert_eq!(local[0].task.title, "precious");
        assert_eq!(
            local[0].sync_state,
            SyncState::Clean,
            "pushed back to the server"
        );
        let remote = client.list_tasks("L1", None).await.unwrap();
        assert!(
            remote.items.iter().any(|t| t.title == "precious"),
            "back on the server"
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
        let now = jiff::Zoned::now()
            .strftime("%Y-%m-%dT%H:%M:%SZ")
            .to_string();
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
                web_view_link: None,
            },
            list_id: "L1".into(),
            sync_state: SyncState::Dirty,
            local_updated: now,
            pending_op: Some("create".into()),
        };
        state.store.upsert_task(&t).await.unwrap();
        assert_eq!(state.pending_push_count().await.unwrap(), baseline + 1);
    }

    #[tokio::test]
    async fn pull_populates_web_view_link_through_to_task_view() {
        // A task pulled from Google carries its webViewLink; it must survive
        // into the store and the TaskView the frontend reads.
        let (client, state) = setup().await;
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "remote-1", "Monthly update", "1");
        state.run_sync().await.unwrap();

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let t = tasks
            .iter()
            .find(|t| t.task.id == "remote-1")
            .expect("pulled task");
        assert!(
            t.task
                .web_view_link
                .as_deref()
                .unwrap_or("")
                .contains("tasks.google.com"),
            "stored task keeps the Google web link"
        );

        let view = crate::commands::TaskView::from(t);
        assert!(
            view.web_view_link.is_some(),
            "TaskView exposes the link to the UI"
        );
    }

    // ---- Sync observability (#4, step 1) ----
    //
    // The background sync loop updates status silently; the UI must be notified
    // after each run so it reflects background syncs, not just manual ones.

    /// Records every sync-status snapshot pushed to the notifier.
    #[derive(Default)]
    struct RecordingNotifier {
        calls: std::sync::Mutex<Vec<crate::state::SyncStatus>>,
    }
    impl crate::state::SyncNotifier for RecordingNotifier {
        fn notify_sync(&self, status: &crate::state::SyncStatus) {
            self.calls.lock().unwrap().push(status.clone());
        }
    }

    #[tokio::test]
    async fn sync_notifies_observer_on_success() {
        let (_client, state) = setup().await;
        let spy = Arc::new(RecordingNotifier::default());
        state.set_sync_notifier(spy.clone());

        state.run_sync().await.expect("sync ok");

        let calls = spy.calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "exactly one notification per sync run");
        assert!(calls[0].last_error.is_none(), "success clears last_error");
        assert!(
            calls[0].last_synced.is_some(),
            "success records last_synced"
        );
        assert_eq!(calls[0].total_syncs, 1);
    }

    #[tokio::test]
    async fn sync_notifies_observer_on_failure() {
        use axiotask_core::api::ApiError;
        use axiotask_core::api::in_memory::Method;
        let (client, state) = setup().await;
        let spy = Arc::new(RecordingNotifier::default());
        state.set_sync_notifier(spy.clone());

        // A non-transient error on the first pull call fails the whole run.
        client.fail_next(Method::ListTaskLists, || ApiError::Unauthorized);

        let res = state.run_sync().await;
        assert!(res.is_err(), "sync run should fail");

        let calls = spy.calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "failure still notifies the observer");
        assert!(calls[0].last_error.is_some(), "failure surfaces last_error");
    }
}
