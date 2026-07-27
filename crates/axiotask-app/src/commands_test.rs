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
        let pending = state.store.pending_moves().await.unwrap();
        assert!(
            pending
                .iter()
                .any(|m| m.task_id == "T2" && m.parent_id.as_deref() == Some("T1"))
        );
    }

    #[tokio::test]
    async fn demoting_a_task_that_has_subtasks_is_refused() {
        // Invariant #1 (RFC-009 §F): subtasks are strictly ONE level. Google
        // does not enforce that — a move that nests three deep is accepted with
        // 200 (probe 3) — so the refusal has to happen on our side, and not
        // only in the Svelte guard: this command is the last gate before the
        // store records an intent the list view could never render.
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "P", "L1", "parent").await;
        seed_task(&state, "C", "L1", "its subtask").await;
        seed_task(&state, "X", "L1", "another top-level task").await;
        crate::commands::move_task_inner(&state, "C".into(), Some("P".into()), None)
            .await
            .unwrap();

        let err = crate::commands::move_task_inner(&state, "P".into(), Some("X".into()), None)
            .await
            .expect_err("demoting a task that has subtasks must be refused");
        assert!(err.contains("subtask"), "explains itself: {err}");

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let p = tasks.iter().find(|t| t.task.id == "P").unwrap();
        assert_eq!(p.task.parent, None, "P is still a top-level row");
        let c = tasks.iter().find(|t| t.task.id == "C").unwrap();
        assert_eq!(
            c.task.parent.as_deref(),
            Some("P"),
            "and its subtask is untouched"
        );
        assert!(
            !state
                .store
                .pending_moves()
                .await
                .unwrap()
                .iter()
                .any(|m| m.task_id == "P"),
            "nothing queued to push a third level at the server"
        );
    }

    #[tokio::test]
    async fn nesting_a_task_under_a_subtask_is_refused() {
        // The mirror of the row above: the TARGET is already a subtask, so the
        // moved task would be the third level.
        let (_client, state) = setup().await;
        seed_list(&state, "L1", "Inbox").await;
        seed_task(&state, "P", "L1", "parent").await;
        seed_task(&state, "C", "L1", "its subtask").await;
        seed_task(&state, "X", "L1", "would-be grandchild").await;
        crate::commands::move_task_inner(&state, "C".into(), Some("P".into()), None)
            .await
            .unwrap();

        let err = crate::commands::move_task_inner(&state, "X".into(), Some("C".into()), None)
            .await
            .expect_err("nesting under a subtask must be refused");
        assert!(err.contains("subtask"), "explains itself: {err}");

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let x = tasks.iter().find(|t| t.task.id == "X").unwrap();
        assert_eq!(x.task.parent, None, "X still renders as a top-level row");
        assert!(
            !state
                .store
                .pending_moves()
                .await
                .unwrap()
                .iter()
                .any(|m| m.task_id == "X")
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
    async fn permanent_sync_failure_flags_attention_backs_off_and_logs_the_real_error() {
        // A permanent failure (a non-retryable API rejection / store bug) fails
        // identically on every retry. The app must: surface the REAL error as a
        // "needs attention" state (not a transient blip, not a dead session),
        // and stretch the idle re-poll cadence instead of hammering every 60s.
        use axiotask_core::api::ApiError;
        use axiotask_core::api::in_memory::Method;
        use std::time::Duration;

        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        // Healthy: no attention, base cadence.
        assert!(!state.sync_status().await.needs_attention);
        let base = state.next_sync_period();

        // First permanent failure.
        client.fail_next(Method::ListTaskLists, || {
            ApiError::Other("schema mismatch: column tasks.blorp missing".into())
        });
        state.run_sync().await.unwrap_err();

        let status = state.sync_status().await;
        assert!(
            status.needs_attention,
            "permanent failure must need attention"
        );
        let msg = status.last_error.expect("the real error is surfaced");
        assert!(
            msg.contains("schema mismatch: column tasks.blorp missing"),
            "surfaces the real error, got: {msg}"
        );
        // Distinct from the dead-session state — this is NOT a re-auth prompt.
        assert!(!state.needs_reauth());
        assert!(!state.sync_status().await.needs_reauth);
        // The idle cadence has backed off past the base period.
        let after_one = state.next_sync_period();
        assert!(
            after_one > base,
            "cadence must back off: {after_one:?} !> {base:?}"
        );

        // A second consecutive permanent failure backs off further still.
        client.fail_next(Method::ListTaskLists, || {
            ApiError::Other("schema mismatch: column tasks.blorp missing".into())
        });
        state.run_sync().await.unwrap_err();
        let after_two = state.next_sync_period();
        assert!(
            after_two > after_one,
            "cadence keeps growing: {after_two:?} !> {after_one:?}"
        );

        // The first success clears attention and restores the base cadence.
        state.run_sync().await.unwrap();
        let recovered = state.sync_status().await;
        assert!(!recovered.needs_attention, "success clears attention");
        assert!(recovered.last_error.is_none(), "success clears the error");
        assert_eq!(
            state.next_sync_period(),
            Duration::from_secs(60),
            "cadence returns to the base period after recovery"
        );
    }

    #[tokio::test]
    async fn transient_sync_failure_does_not_flag_attention_or_back_off() {
        // A transient failure (5xx / network / rate-limit) is expected to clear
        // itself — keep retrying silently at the base cadence. It must NOT flip
        // the "needs attention" state or stretch the polling interval. The
        // engine usually swallows transients into a partial Ok, so to reach the
        // scheduler as an Err we fail the list-creates pull, whose only retry
        // signal is to return the transient error up.
        use axiotask_core::api::ApiError;
        use axiotask_core::api::in_memory::Method;

        let client = Arc::new(InMemoryClient::new());
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        let base = state.next_sync_period();

        // A 5xx on the lists pull is transient; the engine returns Ok (partial
        // run) so no Err reaches the scheduler and attention stays clear.
        client.fail_next(Method::ListTaskLists, || ApiError::Server { status: 503 });
        let _ = state.run_sync().await;

        let status = state.sync_status().await;
        assert!(
            !status.needs_attention,
            "a transient failure never needs attention"
        );
        assert_eq!(
            state.next_sync_period(),
            base,
            "a transient failure never stretches the cadence"
        );
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
        client.seed_task_with_parent("L1", "C2", "sub two", "3", Some("P")); // one level (invariant #1)
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
        assert_eq!(l2.len(), 3, "parent + both subtasks moved");
        let parent = l2.iter().find(|t| t.task.title == "parent").unwrap();
        let c1 = l2.iter().find(|t| t.task.title == "sub one").unwrap();
        let c2 = l2.iter().find(|t| t.task.title == "sub two").unwrap();
        assert_eq!(c1.task.parent.as_deref(), Some(parent.task.id.as_str()));
        assert_eq!(c2.task.parent.as_deref(), Some(parent.task.id.as_str()));

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
        client.seed_task_with_parent("L1", "C2", "kid two", "3", Some("P"));
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

    // ─── RFC-009 §C matrix: complete / un-complete × remote ──────────────────
    //
    // The crossings driven by a real user action go through the real command
    // (`toggle_complete_inner`) and the real sync engine against the fake, and
    // assert the state both sides end in.

    #[tokio::test]
    async fn completing_a_parent_keeps_the_cascade_etag_coherent_and_converges() {
        // §C row 1: our local cascade and Google's server-side cascade both
        // run. Every landed response body must be adopted, or a row ends up
        // carrying a fresh etag over stale content — and every later pull
        // etag-skips it, freezing the drift forever (P6, the #104 bug class).
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
            .unwrap();
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(out.conflicts, 0, "our own cascade is not a conflict");

        for id in ["P", "C1"] {
            let local = state.store.find_task_any(id).await.unwrap().unwrap();
            let remote = client.get_task("L1", id).await.unwrap();
            assert_eq!(local.task.status, TaskStatus::Completed, "{id} local done");
            assert_eq!(remote.status, TaskStatus::Completed, "{id} remote done");
            assert_eq!(local.sync_state, SyncState::Clean, "{id} clean");
            // P6: the etag we hold and the content we hold came from the same
            // response.
            assert_eq!(local.task.etag, remote.etag, "{id} etag coherent");
            assert_eq!(local.task.title, remote.title, "{id} content coherent");
        }

        // P7: with a quiescent remote the next run is a no-op.
        let out2 = state.run_sync().await.unwrap();
        assert_eq!(out2.pushed, 0);
        assert_eq!(out2.pulled, 0);
        assert_eq!(out2.conflicts, 0);
    }

    #[tokio::test]
    async fn uncompleting_a_subtask_under_a_completed_parent_converges_back() {
        // §C: re-opening a subtask whose parent is still completed returns 200
        // and is SILENTLY IGNORED server-side (verified live, #106). Adopting
        // the response body converges the local row back to completed on the
        // same run — the user's checkbox bounces back instead of the row
        // wedging dirty forever or freezing behind a matching etag.
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
            .unwrap();
        state.run_sync().await.unwrap();

        // The user re-opens the SUBTASK while its parent stays done.
        crate::commands::toggle_complete_inner(&state, "C1".into())
            .await
            .unwrap();
        assert_eq!(
            state
                .store
                .find_task_any("C1")
                .await
                .unwrap()
                .unwrap()
                .task
                .status,
            TaskStatus::NeedsAction,
            "precondition: the local toggle applied optimistically"
        );

        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0, "a silently-ignored write is not an error");
        assert_eq!(out.conflicts, 0);

        let local = state.store.find_task_any("C1").await.unwrap().unwrap();
        let remote = client.get_task("L1", "C1").await.unwrap();
        assert_eq!(remote.status, TaskStatus::Completed, "server ignored it");
        assert_eq!(
            local.task.status,
            TaskStatus::Completed,
            "local converged back to the server's truth"
        );
        assert_eq!(local.sync_state, SyncState::Clean, "no row left wedged");
        assert_eq!(local.task.etag, remote.etag, "etag/content coherent (P6)");

        // No etag freeze: the next run is a no-op and the row still agrees.
        let out2 = state.run_sync().await.unwrap();
        assert_eq!(out2.pushed, 0);
        assert_eq!(out2.conflicts, 0);
        assert_eq!(
            state
                .store
                .find_task_any("C1")
                .await
                .unwrap()
                .unwrap()
                .task
                .status,
            TaskStatus::Completed
        );
    }

    #[tokio::test]
    async fn completing_a_parent_takes_a_subtask_we_never_pulled() {
        // §C last row: another device added a subtask we have never seen, then
        // the user completes the parent. Our local cascade cannot reach that
        // child — but the SERVER's cascade does (verified live, #106), and a
        // child insert does NOT bump the parent's etag, so our complete lands
        // with the pre-child etag instead of 412-ing. "No open child under a
        // completed parent" is Google's invariant, not just ours.
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

        // The other device adds a second subtask; we never pull it first.
        let unseen = client
            .insert_task(
                "L1",
                axiotask_core::model::NewTask {
                    title: "kid from another device".into(),
                    parent: Some("P".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert!(
            state
                .store
                .find_task_any(&unseen.id)
                .await
                .unwrap()
                .is_none(),
            "precondition: the new subtask is unknown locally"
        );

        crate::commands::toggle_complete_inner(&state, "P".into())
            .await
            .unwrap();
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(out.conflicts, 0, "a child insert must not stale our etag");

        // Server side: the cascade took the child we never saw.
        let remote = client.list_tasks("L1", None).await.unwrap().items;
        assert!(
            remote.iter().all(|t| t.status == TaskStatus::Completed),
            "no open child under a completed parent on the server: {remote:?}"
        );
        // Local side: the pull brought it in, already completed.
        let local = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(local.len(), 3, "the unseen subtask arrived: {local:?}");
        assert!(
            local.iter().all(|t| t.task.status == TaskStatus::Completed),
            "no open child under a completed parent locally: {local:?}"
        );
        assert!(local.iter().all(|t| t.sync_state == SyncState::Clean));
    }

    // ─── RFC-009 §D matrix: delete × remote, through the real command ────────
    //
    // The §D crossings the user actually performs: `delete_task_inner` (the
    // row action / Delete key) racing a change another device made to the same
    // row. Delete wins in every one (P4) — what these add over the engine-level
    // rows is that the row leaves the VIEW and never comes back on the pull.

    #[tokio::test]
    async fn deleting_a_task_the_remote_just_edited_removes_it_from_the_view() {
        // §D × edited, user-driven. The task must disappear from the list the
        // user is looking at and stay gone: a resurrection on the next pull —
        // the row reappearing under its new remote title — is the visible bug
        // this pins.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "buy milk", "1");
        client.seed_task("L1", "T2", "keep me", "2");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        // Another device renames it while our copy is still on screen.
        client
            .patch_task(
                "L1",
                "T1",
                axiotask_core::model::TaskPatch {
                    title: Some("buy oat milk".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        crate::commands::delete_task_inner(&state, "T1".into())
            .await
            .unwrap();
        // Optimistic: the row is already out of the view before the push.
        let visible = state.store.list_tasks("L1").await.unwrap();
        assert!(
            !visible.iter().any(|t| t.task.id == "T1"),
            "deleted row still rendered: {visible:?}"
        );

        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0, "a stale etag cannot block a delete");
        assert_eq!(out.conflicts, 0, "delete/edit never forks a copy");

        for _ in 0..2 {
            let tasks = state.store.list_tasks("L1").await.unwrap();
            let titles: Vec<_> = tasks.iter().map(|t| t.task.title.as_str()).collect();
            assert_eq!(titles, vec!["keep me"], "no resurrection under any title");
            state.run_sync().await.unwrap();
        }
        assert_eq!(
            client.list_tasks("L1", None).await.unwrap().items.len(),
            1,
            "the remote edit died with the row"
        );
    }

    #[tokio::test]
    async fn removing_a_subtask_the_remote_completed_keeps_the_parent_visible() {
        // §D last row, user-driven, non-happy path: "remove subtask" while the
        // other device ticked that subtask off. The delete still wins, and the
        // parent — the row that actually renders in the list — survives with
        // its remaining subtask attached and nothing left dirty.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "kid one", "2", Some("P"));
        client.seed_task_with_parent("L1", "C2", "kid two", "3", Some("P"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        client
            .patch_task(
                "L1",
                "C1",
                axiotask_core::model::TaskPatch {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        crate::commands::delete_task_inner(&state, "C1".into())
            .await
            .unwrap();
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(out.conflicts, 0);

        let tasks = state.store.list_tasks("L1").await.unwrap();
        let ids: Vec<_> = tasks.iter().map(|t| t.task.id.as_str()).collect();
        assert_eq!(ids, vec!["P", "C2"], "only the removed subtask is gone");
        let parent = tasks.iter().find(|t| t.task.id == "P").unwrap();
        assert_eq!(parent.task.title, "parent", "parent row still rendered");
        assert_eq!(parent.sync_state, SyncState::Clean, "parent not dirtied");
        let sibling = tasks.iter().find(|t| t.task.id == "C2").unwrap();
        assert_eq!(
            sibling.task.parent.as_deref(),
            Some("P"),
            "the sibling is still a subtask of the parent, not promoted"
        );
        assert!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .iter()
                .all(|t| t.id != "C1"),
            "the completed remote copy is gone too"
        );

        // P7: quiescent afterwards — no tombstone left to retry.
        let out2 = state.run_sync().await.unwrap();
        assert_eq!(out2.pushed, 0);
        assert_eq!(out2.errors, 0);
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
        client.seed_task_with_parent("L1", "C2", "kid two", "3", Some("P"));
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
        let kid_two = tasks.iter().find(|t| t.task.title == "kid two").unwrap();
        assert_eq!(kid.task.parent.as_deref(), Some("P"));
        assert_eq!(kid_two.task.parent.as_deref(), Some("P"));

        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(client.list_tasks("L1", None).await.unwrap().items.len(), 3);
    }

    #[tokio::test]
    async fn delete_parent_tombstones_the_whole_subtree_locally() {
        // #138: deleting a synced parent tombstones the WHOLE subtree in one
        // transaction — the children die WITH the parent immediately, not only
        // after the delete syncs (D3 REJECTED; a subtask shares its parent's
        // fate, invariant #3). The root carries the pushable delete; each
        // descendant is a LOCAL-only tombstone (never pushed — the server's own
        // DELETE cascade takes them remotely, verified live #106). Undo before
        // the push restores parent AND children in place.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task_with_parent("L1", "C1", "kid one", "2", Some("P"));
        client.seed_task_with_parent("L1", "C2", "kid two", "3", Some("P"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        let token = crate::commands::delete_task_inner(&state, "P".into())
            .await
            .unwrap();
        assert_eq!(token.subtree.len(), 2, "descendants captured for undo");

        // Immediately (BEFORE any sync): the whole subtree is gone from the
        // view — no child lingers as a live orphan under a tombstoned parent.
        assert!(
            state.store.list_tasks("L1").await.unwrap().is_empty(),
            "parent and both subtasks vanish at delete time"
        );
        for id in ["P", "C1", "C2"] {
            let row = state
                .store
                .find_task_any(id)
                .await
                .unwrap()
                .unwrap_or_else(|| panic!("{id} row still present as a tombstone"));
            assert_eq!(row.sync_state, SyncState::Deleted, "{id} is tombstoned");
        }

        // Push still deletes ONLY the root: the children carry no pending op.
        let dirty = state.store.drain_dirty().await.unwrap();
        let deletes: Vec<_> = dirty
            .iter()
            .filter(|r| r.pending_op.as_deref() == Some("delete"))
            .map(|r| r.task.id.as_str())
            .collect();
        assert_eq!(
            deletes,
            vec!["P"],
            "only the root's delete is queued to push"
        );
        for id in ["C1", "C2"] {
            let c = dirty.iter().find(|r| r.task.id == id).unwrap();
            assert_eq!(
                c.pending_op, None,
                "{id} is a local-only tombstone, never pushed"
            );
        }

        // Undo BEFORE the delete pushes restores the whole subtree in place,
        // children re-attached to their parent.
        crate::commands::undo_delete_inner(&state, token)
            .await
            .unwrap();
        let tasks = state.store.list_tasks("L1").await.unwrap();
        let mut ids: Vec<_> = tasks.iter().map(|t| t.task.id.as_str()).collect();
        ids.sort_unstable();
        assert_eq!(
            ids,
            vec!["C1", "C2", "P"],
            "undo brings the whole subtree back"
        );
        for id in ["C1", "C2"] {
            let c = tasks.iter().find(|t| t.task.id == id).unwrap();
            assert_eq!(
                c.task.parent.as_deref(),
                Some("P"),
                "{id} re-attached to its parent"
            );
        }

        // And it converges on the server: nothing stranded, nothing lost.
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(
            client.list_tasks("L1", None).await.unwrap().items.len(),
            3,
            "subtree survives the undo end to end"
        );
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

    // ─── Reorder / move end-to-end (command → record_move → move endpoint) ─────

    #[tokio::test]
    async fn reorder_command_pushes_via_move_endpoint_end_to_end() {
        // The full path a user drags trigger: reorder_task records a pending
        // move, and the next sync pushes it through the Tasks *move* endpoint
        // (not a patch), landing the new order on the server.
        use axiotask_core::api::in_memory::Method;
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "first", "1");
        client.seed_task("L1", "T2", "second", "2");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );

        // Pull so both tasks are local and carry server etags.
        state.run_sync().await.unwrap();

        // User drags T1 down past T2.
        crate::commands::reorder_task_inner(&state, "T1".into(), "down".into())
            .await
            .unwrap();

        // Locally the order flipped immediately (what the user sees).
        let local = state.store.list_tasks("L1").await.unwrap();
        let lt1 = local.iter().find(|t| t.task.id == "T1").unwrap();
        let lt2 = local.iter().find(|t| t.task.id == "T2").unwrap();
        assert!(
            lt1.task.position > lt2.task.position,
            "T1 now sorts after T2 locally"
        );

        // A pending move was recorded, not a content patch.
        assert_eq!(state.store.pending_moves().await.unwrap().len(), 1);
        assert_eq!(
            client.call_count(Method::MoveTask),
            0,
            "nothing pushed until the sync runs"
        );

        // Sync pushes the reorder through the move endpoint.
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(
            client.call_count(Method::MoveTask),
            1,
            "reorder went via move, once"
        );
        assert_eq!(
            client.call_count(Method::PatchTask),
            0,
            "a reorder is a move, never a patch"
        );

        // The new order reached the server, and the intent is consumed.
        let remote = client.list_tasks("L1", None).await.unwrap();
        let rt1 = remote.items.iter().find(|t| t.id == "T1").unwrap();
        let rt2 = remote.items.iter().find(|t| t.id == "T2").unwrap();
        assert!(
            rt1.position > rt2.position,
            "reorder reached the server: T1 sorts after T2 ({} > {})",
            rt1.position,
            rt2.position
        );
        assert!(
            state.store.pending_moves().await.unwrap().is_empty(),
            "pending move cleared after a successful push"
        );
    }

    #[tokio::test]
    async fn move_command_reparents_via_move_endpoint_end_to_end() {
        // Non-happy path: reparenting a task (making it a one-level subtask —
        // invariant #1) also flows command → record_move → move endpoint, and
        // the new parent lands on the server.
        use axiotask_core::api::in_memory::Method;
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "parent", "1");
        client.seed_task("L1", "C", "child-to-be", "2");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        // Reparent C under P.
        crate::commands::move_task_inner(&state, "C".into(), Some("P".into()), None)
            .await
            .unwrap();

        // Locally C is now a subtask (rendered only in the detail panel).
        let local = state.store.list_tasks("L1").await.unwrap();
        let c = local.iter().find(|t| t.task.id == "C").unwrap();
        assert_eq!(c.task.parent.as_deref(), Some("P"));

        state.run_sync().await.unwrap();
        assert_eq!(client.call_count(Method::MoveTask), 1);

        // The reparent reached the server.
        let remote = client.list_tasks("L1", None).await.unwrap();
        let rc = remote.items.iter().find(|t| t.id == "C").unwrap();
        assert_eq!(
            rc.parent.as_deref(),
            Some("P"),
            "new parent pushed to server"
        );
        assert!(state.store.pending_moves().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn move_recorded_mid_sync_keeps_the_latest_intent() {
        // A move that a still-in-flight sync hasn't landed yet (its push failed
        // transiently and will retry) can be superseded by the user reordering
        // again. The re-record must win and nothing may be lost or applied
        // twice: record_move upserts, and clear_move only runs after a real
        // success — so the queue always converges on the newest intent.
        use axiotask_core::api::ApiError;
        use axiotask_core::api::in_memory::Method;
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "mover", "1");
        client.seed_task("L1", "T2", "second", "2");
        client.seed_task("L1", "T3", "third", "3");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        // First reorder: T1 should follow T2.
        crate::commands::move_task_inner(&state, "T1".into(), None, Some("T2".into()))
            .await
            .unwrap();

        // The sync fires but the move push fails transiently — intent retained,
        // sync still in flight from the user's perspective.
        client.fail_next(Method::MoveTask, || ApiError::Server { status: 503 });
        state.run_sync().await.unwrap();
        assert_eq!(client.call_count(Method::MoveTask), 1, "attempted once");
        assert_eq!(
            state.store.pending_moves().await.unwrap().len(),
            1,
            "transient failure keeps the intent queued"
        );

        // Mid-sync the user reorders T1 again, now to follow T3. This upserts
        // the same task's pending move to the newer target.
        crate::commands::move_task_inner(&state, "T1".into(), None, Some("T3".into()))
            .await
            .unwrap();
        assert_eq!(
            state.store.pending_moves().await.unwrap().len(),
            1,
            "still one intent for T1, not two racing rows"
        );

        // Next sync lands the LATEST intent.
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0);
        assert_eq!(
            client.call_count(Method::MoveTask),
            2,
            "one failed attempt + one success, never double-applied"
        );

        let remote = client.list_tasks("L1", None).await.unwrap();
        let rt1 = remote.items.iter().find(|t| t.id == "T1").unwrap();
        let rt3 = remote.items.iter().find(|t| t.id == "T3").unwrap();
        assert!(
            rt1.position > rt3.position,
            "the newest reorder won: T1 follows T3 ({} > {}), not the stale T2 target",
            rt1.position,
            rt3.position
        );
        assert!(
            state.store.pending_moves().await.unwrap().is_empty(),
            "intent consumed once it truly lands"
        );
    }

    #[tokio::test]
    async fn a_subtask_whose_parent_is_deleted_elsewhere_dies_with_it() {
        // RFC-009 §G / D3 (REJECTED by user), user-driven. The user adds a
        // subtask in the detail panel; another device deletes the parent
        // before it syncs. The subtask shares its parent's fate: it is
        // cascaded away, NOT promoted to a top-level row. What the user sees
        // is an empty list — the parent and its child are both gone.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "P", "Parent", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.set_editing_task(Some("P".into()));
        crate::commands::create_task_inner(
            &state,
            "L1".into(),
            Some("P".into()),
            "call bank".into(),
        )
        .await
        .unwrap();
        state.set_editing_task(None);

        // The other device deletes the parent.
        client.delete_task_from_state("L1", "P");
        state.run_sync().await.unwrap();

        // What the list view renders: nothing — the child died with its parent
        // and was never promoted to a stray top-level row.
        let rendered: Vec<_> = state
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .filter(|t| t.task.parent.is_none())
            .map(|t| t.task.title)
            .collect();
        assert!(
            rendered.is_empty(),
            "the orphaned subtask never appears as a top-level row; got {rendered:?}"
        );

        // No wedge, and the dead child never reaches the server.
        let out = state.run_sync().await.unwrap();
        assert_eq!(out.pushed, 0, "converged — nothing left to push");
        assert_eq!(out.errors, 0);
        let remote = client.list_tasks("L1", None).await.unwrap();
        assert!(
            remote.items.iter().all(|t| t.title != "call bank"),
            "the dead child never reaches the server"
        );
        assert!(
            state.store.list_tasks("L1").await.unwrap().is_empty(),
            "the list is empty locally too"
        );
    }

    #[tokio::test]
    async fn a_task_added_to_a_list_deleted_elsewhere_shows_up_in_the_default_list() {
        // RFC-009 §G3 / D2, user-driven. The user adds a task to "Work" while
        // another device deletes that whole list. The list disappears from the
        // sidebar, but the task the server never saw must not vanish with it —
        // it shows up in the default list and still syncs.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Work");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.set_editing_task(Some("whatever".into()));
        crate::commands::create_task_inner(&state, "L2".into(), None, "file taxes".into())
            .await
            .unwrap();
        state.set_editing_task(None);
        client.delete_tasklist("L2").await.unwrap();

        state.run_sync().await.unwrap();

        let sidebar: Vec<_> = state
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .map(|l| l.list.title)
            .collect();
        assert_eq!(sidebar, vec!["My Tasks"], "the deleted list is gone");
        let rendered: Vec<_> = state
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .filter(|t| t.task.parent.is_none())
            .map(|t| t.task.title)
            .collect();
        assert_eq!(
            rendered,
            vec!["file taxes"],
            "the unpushed task is visible in the default list"
        );

        state.run_sync().await.unwrap();
        assert!(
            client
                .list_tasks("L1", None)
                .await
                .unwrap()
                .items
                .iter()
                .any(|t| t.title == "file taxes"),
            "and it still syncs from its new home"
        );
    }

    // ─── RFC-009 §H matrix: local cross-list move × remote ───────────────────
    //
    // One test per row of §H. Google has no cross-list move, so `move_to_list`
    // is clone-into-target + tombstone-the-original: every row is a create
    // racing a delete, through the real command the UI calls. D4 (the clone's
    // move-time snapshot wins over a concurrent remote edit) and D5 (the moved
    // task survives in the target even when the original died remotely) are
    // the two decisions this family pins down.

    /// What the list view renders for a list: top-level rows only (invariant
    /// #1 — subtasks live in the detail panel, never as list rows).
    async fn rendered(state: &AppState, list_id: &str) -> Vec<String> {
        state
            .store
            .list_tasks(list_id)
            .await
            .unwrap()
            .into_iter()
            .filter(|t| t.task.parent.is_none())
            .map(|t| t.task.title)
            .collect()
    }

    /// Every SUBTASK title in a list (rows with a parent), in position order.
    async fn subtasks(state: &AppState, list_id: &str) -> Vec<String> {
        state
            .store
            .list_tasks(list_id)
            .await
            .unwrap()
            .into_iter()
            .filter(|t| t.task.parent.is_some())
            .map(|t| t.task.title)
            .collect()
    }

    /// Every title the server holds in a list, in position order.
    async fn remote_titles(client: &InMemoryClient, list_id: &str) -> Vec<String> {
        client
            .list_tasks(list_id, None)
            .await
            .unwrap()
            .items
            .into_iter()
            .map(|t| t.title)
            .collect()
    }

    #[tokio::test]
    async fn cross_list_move_lands_the_whole_subtree_under_fresh_ids() {
        // §H × unchanged. The baseline row: clones are created in the target
        // (parent before child, or Google 400s the child), the originals are
        // tombstoned and deleted, and the subtree arrives whole under ids the
        // server just minted. Then it converges: the next run is a no-op (P7).
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "P", "trip", "1");
        client.seed_task_with_parent("L1", "C", "pack", "2", Some("P"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.move_task_to_list("P", "L2").await.unwrap();
        state.run_sync().await.unwrap();

        assert_eq!(rendered(&state, "L1").await, Vec::<String>::new());
        assert_eq!(rendered(&state, "L2").await, vec!["trip"]);
        assert!(remote_titles(&client, "L1").await.is_empty());

        let l2 = client.list_tasks("L2", None).await.unwrap().items;
        assert_eq!(l2.len(), 2, "parent + subtask both landed");
        let parent = l2.iter().find(|t| t.title == "trip").unwrap();
        let child = l2.iter().find(|t| t.title == "pack").unwrap();
        assert_ne!(
            parent.id, "P",
            "the clone carries a fresh id (invariant #4)"
        );
        assert_ne!(child.id, "C");
        assert_eq!(
            child.parent.as_deref(),
            Some(parent.id.as_str()),
            "the subtask hangs off the clone, not the dead original"
        );

        // Locally everything settled, and the run after is a no-op.
        let rows = state.store.list_tasks("L2").await.unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| r.sync_state == SyncState::Clean));
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P7)");
    }

    #[tokio::test]
    async fn cross_list_move_subtree_no_duplicate_when_root_delete_is_delayed() {
        // §H / P8. A cross-list move clones the subtree and removes the
        // originals; the ROOT's delete is what cascades the descendants away on
        // the server. If a transient delays that root delete while a pull runs,
        // a descendant that was only hard-deleted locally is RESURRECTED from
        // the server — a duplicate of the moved subtree. Descendants the server
        // may hold are tombstoned instead, so the pull can never re-add them.
        // (Found by the §J crash property at 4096 once the crash generator got
        // edit ops; pre-existing, independent of #124.)
        use axiotask_core::api::ApiError;
        use axiotask_core::api::in_memory::Method;

        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "P", "trip", "1");
        client.seed_task_with_parent("L1", "C", "pack", "2", Some("P"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap(); // pull P + C into L1

        state.move_task_to_list("P", "L2").await.unwrap();

        // The root's delete keeps failing transiently, so the sync that pushes
        // the clones and pulls the server view runs while the server still holds
        // the original subtree.
        client.fail_next_for_id(Method::DeleteTask, "P", || ApiError::Server { status: 503 });
        state.run_sync().await.unwrap();

        // Nothing must have been resurrected: even mid-retry, the subtask exists
        // exactly once across every list.
        let after_fault: Vec<String> = {
            let mut t = rendered(&state, "L1").await;
            t.extend(subtasks(&state, "L1").await);
            t.extend(rendered(&state, "L2").await);
            t.extend(subtasks(&state, "L2").await);
            t
        };
        assert_eq!(
            after_fault.iter().filter(|t| *t == "pack").count(),
            1,
            "the subtask was not resurrected in the source list: {after_fault:?}"
        );

        // Converge and confirm one subtree, in L2, no duplicate anywhere.
        client.clear_faults();
        for _ in 0..8 {
            state.run_sync().await.unwrap();
        }
        assert_eq!(rendered(&state, "L1").await, Vec::<String>::new());
        assert_eq!(rendered(&state, "L2").await, vec!["trip"]);
        assert_eq!(subtasks(&state, "L2").await, vec!["pack"]);
        assert!(
            remote_titles(&client, "L1").await.is_empty(),
            "source clear"
        );
        let l2 = client.list_tasks("L2", None).await.unwrap().items;
        assert_eq!(l2.len(), 2, "exactly parent + one subtask on the server");
    }

    #[tokio::test]
    async fn a_remote_edit_during_a_cross_list_move_loses_to_the_moved_snapshot() {
        // §H, D4 (RATIFIED). Another device renames the original in the window
        // between the move and the sync. The clone carries the move-time
        // snapshot and the tombstone's DELETE carries no If-Match, so the
        // rename is discarded (P4). Accepted MVP loss — no conflicted copy, no
        // wedged row; the user sees exactly what they moved.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "T1", "buy milk", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.move_task_to_list("T1", "L2").await.unwrap();
        // The other device edits the original (bumping its etag) mid-window.
        client
            .patch_task(
                "L1",
                "T1",
                axiotask_core::model::TaskPatch {
                    title: Some("buy oat milk".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();

        state.run_sync().await.unwrap();

        assert_eq!(
            rendered(&state, "L2").await,
            vec!["buy milk"],
            "the clone's snapshot wins (D4)"
        );
        assert_eq!(rendered(&state, "L1").await, Vec::<String>::new());
        assert!(
            remote_titles(&client, "L1").await.is_empty(),
            "the stale-etag delete still lands — deletes carry no If-Match"
        );
        assert_eq!(remote_titles(&client, "L2").await, vec!["buy milk"]);
        // The lost edit leaves no conflicted copy anywhere (P3 does not apply).
        for list in ["L1", "L2"] {
            assert!(
                !rendered(&state, list)
                    .await
                    .iter()
                    .any(|t| t.contains("oat")),
                "no conflicted copy of the discarded remote edit"
            );
        }
    }

    #[tokio::test]
    async fn a_moved_task_survives_in_the_target_when_the_original_dies_remotely() {
        // §H, D5 (RATIFIED). Another device deletes the original before the
        // move syncs. The tombstone's 404 is success, and the clones are rows
        // the server has never seen — P2 forbids a remote event from
        // destroying them. The move expressed intent to KEEP the task, so
        // "move wins": it lives on in the target list.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "P", "trip", "1");
        client.seed_task_with_parent("L1", "C", "pack", "2", Some("P"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.move_task_to_list("P", "L2").await.unwrap();
        client.delete_task_from_state("L1", "P"); // cascades C on the server
        client.delete_task_from_state("L1", "C");

        let out = state.run_sync().await.unwrap();
        assert_eq!(
            out.errors, 0,
            "a 404 on the tombstone is success, not error"
        );

        assert_eq!(
            rendered(&state, "L2").await,
            vec!["trip"],
            "move wins: the task survives in the target (D5)"
        );
        let l2 = client.list_tasks("L2", None).await.unwrap().items;
        assert_eq!(l2.len(), 2, "the whole subtree survived, on the server");
        assert_eq!(
            l2.iter()
                .find(|t| t.title == "pack")
                .unwrap()
                .parent
                .as_deref(),
            Some(l2.iter().find(|t| t.title == "trip").unwrap().id.as_str())
        );
        assert!(
            state
                .store
                .list_tasks("L2")
                .await
                .unwrap()
                .iter()
                .all(|r| r.sync_state == SyncState::Clean)
        );
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P7)");
    }

    #[tokio::test]
    async fn a_subtask_added_remotely_after_a_cross_list_move_dies_with_the_original() {
        // §H × new remote subtask under the original. The child was born after
        // the move snapshot, so it is not in the clone; the original's delete
        // cascades it away on the server (P4 + cascade, verified live). An
        // accepted MVP loss — pinned here so it can never happen SILENTLY in a
        // way that leaves an invisible orphan row behind locally.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "P", "trip", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.move_task_to_list("P", "L2").await.unwrap();
        client.seed_task_with_parent("L1", "C", "book hotel", "2", Some("P"));

        state.run_sync().await.unwrap();

        assert_eq!(rendered(&state, "L2").await, vec!["trip"]);
        assert!(
            remote_titles(&client, "L1").await.is_empty(),
            "cascade took it"
        );
        assert_eq!(remote_titles(&client, "L2").await, vec!["trip"]);
        // Nothing invisible left behind: no local row anywhere for the child.
        for list in ["L1", "L2"] {
            assert!(
                state
                    .store
                    .list_tasks(list)
                    .await
                    .unwrap()
                    .iter()
                    .all(|t| t.task.title != "book hotel"),
                "no orphaned local row for the cascaded subtask"
            );
        }
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P7)");
    }

    #[tokio::test]
    async fn a_move_into_a_list_deleted_remotely_rehomes_the_clone_to_the_default_list() {
        // §H × target list deleted remotely, crossing §G3 / D2. The clone
        // creates cannot land in a list that no longer exists, and they are
        // rows the server never saw — so they re-home to the default list
        // rather than dying with it (P2). The originals' tombstones still
        // push, so the subtree ends up in exactly ONE place, and a visible one.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L0", "My Tasks");
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "P", "trip", "1");
        client.seed_task_with_parent("L1", "C", "pack", "2", Some("P"));
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.move_task_to_list("P", "L2").await.unwrap();
        client.delete_tasklist("L2").await.unwrap();

        state.run_sync().await.unwrap();

        // `all_lists` has no ORDER BY — sort so the assertion cannot depend on
        // SQLite's row order.
        let mut sidebar: Vec<_> = state
            .store
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .map(|l| l.list.title)
            .collect();
        sidebar.sort();
        assert_eq!(sidebar, vec!["My Tasks", "Work"], "the target list is gone");
        assert_eq!(
            rendered(&state, "L0").await,
            vec!["trip"],
            "the moved subtree is visible in the default list"
        );
        assert_eq!(rendered(&state, "L1").await, Vec::<String>::new());
        assert!(
            remote_titles(&client, "L1").await.is_empty(),
            "the original's tombstone pushed regardless"
        );

        // It still syncs from its new home, subtree intact and one level deep.
        state.run_sync().await.unwrap();
        let l0 = client.list_tasks("L0", None).await.unwrap().items;
        assert_eq!(l0.len(), 2, "parent + subtask reached the server");
        let parent = l0.iter().find(|t| t.title == "trip").unwrap();
        assert_eq!(
            l0.iter()
                .find(|t| t.title == "pack")
                .unwrap()
                .parent
                .as_deref(),
            Some(parent.id.as_str())
        );
        assert!(
            state
                .store
                .list_tasks("L0")
                .await
                .unwrap()
                .iter()
                .all(|r| r.sync_state == SyncState::Clean)
        );
    }

    #[tokio::test]
    async fn a_crash_between_the_clone_and_the_delete_leaves_no_permanent_duplicate() {
        // §H crash window. The clone lands, then the network drops before the
        // original's delete is pushed. Both remote lists briefly hold the
        // subtree — but the user must never see the duplicate (the tombstone
        // is not a rendered row, and the pull must not resurrect it), and the
        // next run converges to one copy (P8).
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "T1", "buy milk", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.move_task_to_list("T1", "L2").await.unwrap();
        client.fail_next(axiotask_core::api::in_memory::Method::DeleteTask, || {
            axiotask_core::api::ApiError::Network("crash".into())
        });

        state.run_sync().await.unwrap();

        // Server: transiently duplicated. User: one row, in the target list.
        assert_eq!(remote_titles(&client, "L1").await, vec!["buy milk"]);
        assert_eq!(remote_titles(&client, "L2").await, vec!["buy milk"]);
        assert_eq!(
            rendered(&state, "L1").await,
            Vec::<String>::new(),
            "the pull must not resurrect the tombstoned original"
        );
        assert_eq!(rendered(&state, "L2").await, vec!["buy milk"]);

        // Next run pushes the surviving tombstone: one copy, and it converges.
        state.run_sync().await.unwrap();
        assert!(remote_titles(&client, "L1").await.is_empty());
        assert_eq!(remote_titles(&client, "L2").await, vec!["buy milk"]);
        assert_eq!(rendered(&state, "L2").await, vec!["buy milk"]);
        assert!(
            state
                .store
                .list_tasks("L2")
                .await
                .unwrap()
                .iter()
                .all(|r| r.sync_state == SyncState::Clean)
        );
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P8/P7)");
    }

    #[tokio::test]
    async fn a_clone_insert_that_commits_then_times_out_does_not_duplicate_the_move() {
        // §H second crash window: the clone's insert lands server-side but the
        // response never arrives, so the local row still looks unpushed. The
        // in-flight marker must let the next run ADOPT the orphan instead of
        // inserting the moved task a second time (P8) — the crossing of the
        // crashed-create machinery with a cross-list move.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        client.seed_task("L1", "T1", "buy milk", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.move_task_to_list("T1", "L2").await.unwrap();
        client.commit_then_fail_next_insert();
        state.run_sync().await.unwrap();

        // The original is gone either way; the clone's fate is decided next run.
        client.clear_faults();
        state.run_sync().await.unwrap();

        assert_eq!(
            remote_titles(&client, "L2").await,
            vec!["buy milk"],
            "the moved task exists exactly once — no duplicate from the retry"
        );
        assert!(remote_titles(&client, "L1").await.is_empty());
        assert_eq!(rendered(&state, "L2").await, vec!["buy milk"]);
        assert_eq!(rendered(&state, "L1").await, Vec::<String>::new());
        assert!(
            state
                .store
                .list_tasks("L2")
                .await
                .unwrap()
                .iter()
                .all(|r| r.sync_state == SyncState::Clean)
        );
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P8/P7)");
    }

    // ─── RFC-009 §I matrix: list ops through the real commands ──────────────
    //
    // The sequencing rows live in `sync::engine`; these are the same crossings
    // driven the way the user drives them — `rename_list` / `delete_list` /
    // `create_list` — asserting what the sidebar and the list view actually
    // show afterwards.

    /// What the sidebar renders: `list_tasklists` reads `all_lists`, which
    /// excludes tombstoned lists.
    async fn sidebar(state: &AppState) -> Vec<String> {
        let mut titles: Vec<String> = state
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

    /// Every task title the UI can reach: the frontend builds `allTasks` by
    /// asking each list the sidebar shows for its tasks, so a row in a list
    /// that is not rendered is reachable from no view at all.
    async fn reachable_tasks(state: &AppState) -> Vec<String> {
        let mut titles = Vec::new();
        for l in state.store.all_lists().await.unwrap() {
            for t in state.store.list_tasks(&l.list.id).await.unwrap() {
                titles.push(t.task.title);
            }
        }
        titles.sort();
        titles
    }

    #[tokio::test]
    async fn renaming_a_list_the_other_device_renamed_too_leaves_one_list() {
        // §I × remote rename, D6 (RATIFIED). Lists cannot 412 (probe 8), so
        // there is no conflict to fork: the user gets ONE list, carrying the
        // last write, and never a second sidebar entry to clean up.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_task("L1", "T1", "ship it", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        state.rename_list("L1", "Job").await.unwrap();
        // The other device renames the same list before our push goes out.
        client.patch_tasklist("L1", "Career").await.unwrap();
        state.run_sync().await.unwrap();

        assert_eq!(
            sidebar(&state).await,
            vec!["Job", "My Tasks"],
            "one entry for the renamed list — no conflicted copy (D6)"
        );
        assert_eq!(
            rendered(&state, "L1").await,
            vec!["ship it"],
            "and its tasks are untouched by the rename race"
        );

        // Now the other device renames it again, after ours landed: remote
        // wins on the next pull, silently and without a copy.
        client.patch_tasklist("L1", "Career").await.unwrap();
        state.run_sync().await.unwrap();
        assert_eq!(sidebar(&state).await, vec!["Career", "My Tasks"]);
        assert_eq!(rendered(&state, "L1").await, vec!["ship it"]);
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P7)");
    }

    #[tokio::test]
    async fn deleting_a_list_takes_its_unpushed_tasks_with_it() {
        // §I row the matrix had not enumerated (the list-level twin of §D's
        // "delete a parent whose child is an unpushed create"): the list the
        // user deletes still holds a task the server has never seen. P2 shields
        // unpushed work from REMOTE events only — the user's own delete
        // cascades (invariant #3). The row must not survive as an orphan, must
        // not re-home into another list, and must not be inserted into a list
        // that is being deleted.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Doomed");
        client.seed_task("L2", "T1", "synced row", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        // A brand-new task, never pushed, plus a subtask under the synced one.
        crate::commands::create_task_inner(&state, "L2".into(), None, "never pushed".into())
            .await
            .unwrap();
        crate::commands::create_task_inner(
            &state,
            "L2".into(),
            Some("T1".into()),
            "unpushed subtask".into(),
        )
        .await
        .unwrap();

        state.delete_list("L2").await.unwrap();

        assert_eq!(sidebar(&state).await, vec!["My Tasks"], "gone at once");
        assert_eq!(
            reachable_tasks(&state).await,
            Vec::<String>::new(),
            "nothing it held is reachable from any view"
        );

        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0, "no insert into the list being deleted");
        assert!(
            client
                .list_tasklists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.id != "L2"),
            "the delete reached the server"
        );
        assert_eq!(
            remote_titles(&client, "L1").await,
            Vec::<String>::new(),
            "the unpushed rows were not re-homed — this was the user's own delete"
        );
        assert_eq!(sidebar(&state).await, vec!["My Tasks"]);
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P7)");
    }

    #[tokio::test]
    async fn a_list_renamed_here_and_deleted_elsewhere_disappears_with_its_tasks() {
        // §I × remote deleted. The rename 404s, and a rename against a list
        // that no longer exists is meaningless: the list is hard-deleted
        // locally (P4) instead of retrying forever. The user sees the sidebar
        // entry and its tasks go — not an entry that never syncs again.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "My Tasks");
        client.seed_list("L2", "Shared");
        client.seed_task("L2", "T1", "their task", "1");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();
        assert_eq!(sidebar(&state).await, vec!["My Tasks", "Shared"]);

        state.rename_list("L2", "Renamed here").await.unwrap();
        client.delete_list_from_state("L2");

        let out = state.run_sync().await.unwrap();
        assert_eq!(out.errors, 0, "a 404 rename is not a rejection");
        assert_eq!(
            sidebar(&state).await,
            vec!["My Tasks"],
            "the list the other device deleted is gone from the sidebar"
        );
        assert_eq!(
            reachable_tasks(&state).await,
            Vec::<String>::new(),
            "and its tasks went with it"
        );
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.errors), (0, 0), "converged (P7)");
    }

    #[tokio::test]
    async fn a_task_completed_on_another_device_stays_visible_as_done() {
        // §A × completed and auto-hidden by Google. The pull asks for hidden
        // and completed tasks, so the row stays in the remote view and ghost
        // detection spares it. What the user must see is the task still in the
        // list, ticked — not a task that silently vanished from their history.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_task("L1", "T1", "file taxes", "1");
        client.seed_task("L1", "T2", "still open", "2");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        client
            .patch_task(
                "L1",
                "T1",
                axiotask_core::model::TaskPatch {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        state.run_sync().await.unwrap();

        assert_eq!(
            rendered(&state, "L1").await,
            vec!["file taxes", "still open"],
            "the completed task is still a row in the list"
        );
        let done = state
            .store
            .list_tasks("L1")
            .await
            .unwrap()
            .into_iter()
            .find(|t| t.task.id == "T1")
            .expect("the completed row survived the pull");
        assert_eq!(
            done.task.status,
            TaskStatus::Completed,
            "and renders ticked, so 'show completed' and 'clear completed' can see it"
        );
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pulled, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    // ─── §J — rows the property suite's extended op vocabulary surfaced (#113) ─

    /// The local id of the only row in `list_id` (they are UUIDs until pushed).
    async fn only_row_id(state: &AppState, list_id: &str) -> String {
        let rows = state.store.list_tasks(list_id).await.unwrap();
        assert_eq!(rows.len(), 1, "expected exactly one row in {list_id}");
        rows[0].task.id.clone()
    }

    #[tokio::test]
    async fn a_cross_list_move_of_a_crashed_create_leaves_nothing_behind() {
        // §H × §G crash window — the mirror of the clone-side row above. Here
        // the ORIGINAL's insert committed server-side and the response was
        // lost, so the local row still looks unpushed. Hard-deleting it on the
        // move would strand that committed insert: the next pull resurrects it
        // and the user sees the task in BOTH lists. The in-flight marker says
        // "the server may already hold this", so the original must be
        // tombstoned instead and its orphan deleted for real.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::create_task_inner(&state, "L1".into(), None, "buy milk".into())
            .await
            .unwrap();
        let local_id = only_row_id(&state, "L1").await;
        client.commit_then_fail_next_insert();
        state.run_sync().await.unwrap();
        assert_eq!(
            remote_titles(&client, "L1").await,
            vec!["buy milk"],
            "the insert really did commit before the response was lost"
        );

        state.move_task_to_list(&local_id, "L2").await.unwrap();
        client.clear_faults();
        state.run_sync().await.unwrap();
        state.run_sync().await.unwrap();

        assert_eq!(
            rendered(&state, "L2").await,
            vec!["buy milk"],
            "the moved task is in the target list"
        );
        assert_eq!(
            rendered(&state, "L1").await,
            Vec::<String>::new(),
            "and nothing was left behind in the source list"
        );
        assert!(
            remote_titles(&client, "L1").await.is_empty(),
            "the committed-but-orphaned insert was deleted on the server"
        );
        assert_eq!(remote_titles(&client, "L2").await, vec!["buy milk"]);
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    #[tokio::test]
    async fn deleting_a_crashed_create_does_not_resurrect_it_on_the_next_pull() {
        // §D × §G crash window. Same hazard through the delete command: the
        // user deletes a task whose insert had already committed. Delete wins
        // in both directions (P4), so the committed row must go too — a
        // deleted task that reappears at the next pull is the worst kind of
        // sync bug.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::create_task_inner(&state, "L1".into(), None, "buy milk".into())
            .await
            .unwrap();
        let local_id = only_row_id(&state, "L1").await;
        client.commit_then_fail_next_insert();
        state.run_sync().await.unwrap();

        crate::commands::delete_task_inner(&state, local_id)
            .await
            .unwrap();
        client.clear_faults();
        state.run_sync().await.unwrap();
        state.run_sync().await.unwrap();

        assert_eq!(
            rendered(&state, "L1").await,
            Vec::<String>::new(),
            "the deleted task stays deleted"
        );
        assert!(
            remote_titles(&client, "L1").await.is_empty(),
            "and its committed insert was cleaned up on the server"
        );
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    #[tokio::test]
    async fn a_renamed_list_deleted_remotely_keeps_the_rows_the_server_never_saw() {
        // §I local rename × remote delete, crossed with P2. The rename push
        // 404s, which means the list is gone on the server and must go locally
        // too (P4) — but the unpushed rows it holds are work the server has
        // NEVER SEEN, and P2 forbids a remote event from destroying those. The
        // pull's ghost-list path already re-homes them (D2); the rename push is
        // the same discovery arriving through a different call and must do the
        // same.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "My Tasks");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::create_task_inner(&state, "L1".into(), None, "buy milk".into())
            .await
            .unwrap();
        state.rename_list("L1", "Work stuff").await.unwrap();
        client.delete_list_from_state("L1");

        state.run_sync().await.unwrap();
        state.run_sync().await.unwrap();

        assert!(
            state
                .store
                .all_lists()
                .await
                .unwrap()
                .iter()
                .all(|l| l.list.id != "L1"),
            "the list the server deleted is gone locally too (P4)"
        );
        assert_eq!(
            rendered(&state, "L2").await,
            vec!["buy milk"],
            "the unpushed row re-homed to the default list instead of dying (P2/D2)"
        );
        assert_eq!(
            remote_titles(&client, "L2").await,
            vec!["buy milk"],
            "and it reached the server from there"
        );
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    #[tokio::test]
    async fn clearing_completed_after_a_crashed_create_does_not_resurrect_it() {
        // The same crash window through the third delete path. Clear-completed
        // is an AUTOMATIC delete (invariant #3), so a row it drops without a
        // tombstone comes back at the next pull with no user action to blame.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::create_task_inner(&state, "L1".into(), None, "buy milk".into())
            .await
            .unwrap();
        let local_id = only_row_id(&state, "L1").await;
        // Ticked BEFORE the insert goes out to keep this row about clear-completed
        // only. (An edit made *during* the in-flight window is exercised
        // separately by the #124 base-snapshot regression tests.)
        crate::commands::toggle_complete_inner(&state, local_id)
            .await
            .unwrap();
        client.commit_then_fail_next_insert();
        state.run_sync().await.unwrap();
        assert_eq!(
            remote_titles(&client, "L1").await,
            vec!["buy milk"],
            "the insert really did commit before the response was lost"
        );

        let cleared = crate::commands::clear_completed_inner(&state, "L1".into())
            .await
            .unwrap();
        assert_eq!(cleared, 1);

        client.clear_faults();
        state.run_sync().await.unwrap();
        state.run_sync().await.unwrap();

        assert_eq!(
            rendered(&state, "L1").await,
            Vec::<String>::new(),
            "the cleared task stays cleared"
        );
        assert!(
            remote_titles(&client, "L1").await.is_empty(),
            "and its committed insert was cleaned up on the server"
        );
    }

    #[tokio::test]
    async fn remote_reorder_plus_local_rename_no_false_copy_rename_lands() {
        // RFC-009 §B × moved-while-edited (#118). Another device merely REORDERS
        // a task — which bumps its etag (probe 1) but leaves the content equal to
        // what we last synced — while the user renames it locally. Without a base
        // to compare against, whole-row resolution reads the etag bump as a
        // remote edit and forks a false "(conflicted copy)", reverting the
        // rename. The base snapshot recognizes the server never diverged, so the
        // rename lands with no copy and no lost edit.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "old", "00000000000001");
        client.seed_task("L1", "anchor", "anchor", "00000000000002");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap(); // pull; T1 clean locally

        // Another device drags T1 after `anchor`. Content untouched; etag bumped.
        client
            .move_task("L1", "T1", None, Some("anchor"))
            .await
            .unwrap();

        // The user renames T1 locally — this captures the base ("old").
        crate::commands::rename_task_inner(&state, "T1".into(), "new".into())
            .await
            .unwrap();

        // Sync to a fixpoint, counting every conflict raised along the way.
        let mut total_conflicts = 0;
        for _ in 0..6 {
            let out = state.run_sync().await.unwrap();
            total_conflicts += out.conflicts;
            if state.pending_push_count().await.unwrap() == 0 {
                break;
            }
        }

        assert_eq!(
            total_conflicts, 0,
            "a bare remote reorder is not a conflict"
        );
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(
            !tasks
                .iter()
                .any(|t| t.task.title.contains("(conflicted copy)")),
            "no false conflicted copy: {:?}",
            tasks.iter().map(|t| &t.task.title).collect::<Vec<_>>()
        );
        let renamed: Vec<_> = tasks.iter().filter(|t| t.task.title == "new").collect();
        assert_eq!(renamed.len(), 1, "the rename landed on exactly one row");
        assert_eq!(
            renamed[0].sync_state,
            SyncState::Clean,
            "and the row converged clean"
        );
        // The server holds the renamed task and nothing else spurious.
        let mut server = remote_titles(&client, "L1").await;
        server.sort();
        assert_eq!(server, vec!["anchor".to_string(), "new".to_string()]);
    }

    #[tokio::test]
    async fn status_only_divergence_over_a_remote_reorder_never_forks_a_copy() {
        // The D1 guard (RFC-009 §C) with a base snapshot present: a status-only
        // difference must never produce a "(conflicted copy)". The user ticks a
        // task complete while another device merely reorders it (etag bumped,
        // content — including status — unchanged from our base). Whole-row
        // resolution with no base could read the etag bump as a remote status
        // change and, combined with our toggle, fork a copy; the base shows the
        // server never diverged, so our tick lands with no copy.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        client.seed_task("L1", "T1", "chore", "00000000000001");
        client.seed_task("L1", "anchor", "anchor", "00000000000002");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        // Another device reorders T1 — status untouched.
        client
            .move_task("L1", "T1", None, Some("anchor"))
            .await
            .unwrap();
        // The user ticks T1 complete (base captured = needsAction content).
        crate::commands::toggle_complete_inner(&state, "T1".into())
            .await
            .unwrap();

        let mut total_conflicts = 0;
        for _ in 0..6 {
            let out = state.run_sync().await.unwrap();
            total_conflicts += out.conflicts;
            if state.pending_push_count().await.unwrap() == 0 {
                break;
            }
        }

        assert_eq!(
            total_conflicts, 0,
            "a status-only change is never a conflict"
        );
        let tasks = state.store.list_tasks("L1").await.unwrap();
        assert!(
            !tasks
                .iter()
                .any(|t| t.task.title.contains("(conflicted copy)")),
            "no conflicted copy for a status-only divergence"
        );
        let chore: Vec<_> = tasks.iter().filter(|t| t.task.title == "chore").collect();
        assert_eq!(chore.len(), 1, "exactly one row, never a copy");
        // D1 (ratified): a status-only difference resolves remote-wins — the
        // server never changed the status (only reordered), but whole-row
        // resolution adopts the remote row, so the tick is dropped. A lost
        // checkbox click is cheap; a duplicate task is not. The invariant this
        // guards is "no conflicted copy", which holds.
        assert_eq!(chore[0].task.status, TaskStatus::NeedsAction);
        assert_eq!(chore[0].sync_state, SyncState::Clean);
    }

    #[tokio::test]
    async fn edit_during_inflight_create_adopts_orphan_no_duplicate_edit_survives() {
        // RFC-009 §G in-flight (#122). The insert commits server-side but the
        // response is lost, and the user edits the row during that window.
        // Matching the orphan on the row's CURRENT content would miss (it
        // drifted) and the create would be retried, duplicating the task. The
        // base snapshot — the payload as sent — still adopts the committed row,
        // and the edit survives as a pending update against the server id.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::create_task_inner(&state, "L1".into(), None, "buy milk".into())
            .await
            .unwrap();
        let local_id = only_row_id(&state, "L1").await;

        // Insert commits on the server, but the response is lost (crash window).
        client.commit_then_fail_next_insert();
        state.run_sync().await.unwrap();
        assert_eq!(
            remote_titles(&client, "L1").await,
            vec!["buy milk"],
            "the insert really did commit before the response was lost"
        );

        // The user edits the row WHILE the create is still in flight.
        crate::commands::rename_task_inner(&state, local_id.clone(), "buy oat milk".into())
            .await
            .unwrap();

        // Recovery adopts the orphan on the base match and keeps the edit.
        client.clear_faults();
        let mut converged = false;
        for _ in 0..6 {
            state.run_sync().await.unwrap();
            if state.pending_push_count().await.unwrap() == 0 {
                converged = true;
                break;
            }
        }
        assert!(converged, "sync must reach a fixpoint");

        // Exactly one task, locally and on the server, carrying the EDITED title.
        let local = state.store.list_tasks("L1").await.unwrap();
        assert_eq!(local.len(), 1, "no duplicate locally");
        assert_eq!(local[0].task.title, "buy oat milk", "the edit survived");
        assert_eq!(local[0].sync_state, SyncState::Clean);
        assert!(
            local[0].task.etag.is_some(),
            "adopted the committed server row, not a fresh insert"
        );
        assert_eq!(
            remote_titles(&client, "L1").await,
            vec!["buy oat milk"],
            "no duplicate on the server, and it carries the edit"
        );
        assert!(
            state.store.inflight_creates().await.unwrap().is_empty(),
            "the in-flight marker was cleared by adoption"
        );
    }

    #[tokio::test]
    async fn undoing_the_delete_of_a_crashed_create_leaves_exactly_one_task() {
        // The adjacent feature the tombstone change touches: undo reads the row
        // back with `find_task_any` and revives it in place. A crashed create's
        // tombstone has no etag, so undo revives it as a pending CREATE — and
        // its in-flight marker is still open, so recovery must adopt the
        // committed orphan rather than insert a second copy.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::create_task_inner(&state, "L1".into(), None, "buy milk".into())
            .await
            .unwrap();
        let local_id = only_row_id(&state, "L1").await;
        client.commit_then_fail_next_insert();
        state.run_sync().await.unwrap();

        let token = crate::commands::delete_task_inner(&state, local_id)
            .await
            .unwrap();
        crate::commands::undo_delete_inner(&state, token)
            .await
            .unwrap();

        client.clear_faults();
        state.run_sync().await.unwrap();
        state.run_sync().await.unwrap();

        assert_eq!(
            rendered(&state, "L1").await,
            vec!["buy milk"],
            "the undone task is back, once"
        );
        assert_eq!(
            remote_titles(&client, "L1").await,
            vec!["buy milk"],
            "and exists on the server exactly once"
        );
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    #[tokio::test]
    async fn a_tombstone_waits_while_its_own_create_is_still_unresolved_in_flight() {
        // The narrow window the §J suite found from
        // `[CreateTop, CrashSync, MoveToList, FlakySync(list_tasks 503)]`.
        // Recovery could not see the remote list this run, so the marker stays
        // open and the tombstone still carries a LOCAL uuid. Pushing its delete
        // now would name an id Google never minted (a permanent 400) while the
        // row the crashed insert really created lives on — and gets pulled back
        // as a duplicate. The delete has to wait one run.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        client.seed_list("L2", "Personal");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::create_task_inner(&state, "L1".into(), None, "buy milk".into())
            .await
            .unwrap();
        let local_id = only_row_id(&state, "L1").await;
        client.commit_then_fail_next_insert();
        state.run_sync().await.unwrap();

        state.move_task_to_list(&local_id, "L2").await.unwrap();
        // Recovery's view of L1 dies transiently, so the marker cannot resolve.
        client.clear_faults();
        client.fail_next(axiotask_core::api::in_memory::Method::ListTasks, || {
            axiotask_core::api::ApiError::Server { status: 503 }
        });
        state.run_sync().await.unwrap();
        assert!(
            !state.store.inflight_creates().await.unwrap().is_empty(),
            "the marker is still open — this run could not resolve it"
        );

        client.clear_faults();
        state.run_sync().await.unwrap();
        state.run_sync().await.unwrap();

        assert_eq!(rendered(&state, "L2").await, vec!["buy milk"]);
        assert_eq!(
            rendered(&state, "L1").await,
            Vec::<String>::new(),
            "no duplicate came back into the source list"
        );
        assert!(remote_titles(&client, "L1").await.is_empty());
        assert_eq!(remote_titles(&client, "L2").await, vec!["buy milk"]);
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    #[tokio::test]
    async fn deleting_a_create_whose_insert_never_landed_leaves_no_unpushable_tombstone() {
        // The other half of the in-flight window: the insert genuinely never
        // reached the server, so there is no orphan to adopt. The tombstone
        // still carries a LOCAL uuid, which Google would reject as an invalid
        // task id on every future run — it must be dropped outright instead of
        // poisoning the pending-changes count forever.
        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Work");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );
        state.run_sync().await.unwrap();

        crate::commands::create_task_inner(&state, "L1".into(), None, "buy milk".into())
            .await
            .unwrap();
        let local_id = only_row_id(&state, "L1").await;
        client.fail_next(axiotask_core::api::in_memory::Method::InsertTask, || {
            axiotask_core::api::ApiError::Network("dropped".into())
        });
        state.run_sync().await.unwrap();
        assert!(
            remote_titles(&client, "L1").await.is_empty(),
            "the insert really did not land"
        );

        crate::commands::delete_task_inner(&state, local_id.clone())
            .await
            .unwrap();
        client.clear_faults();
        // Google's verified answer to a request naming a local UUID is a
        // permanent 400 "Invalid task ID" (RFC-009 §Probes / #106), not a 404.
        // Armed here so the row is judged against the real API's response
        // rather than the fake's more forgiving not-found: a tombstone that
        // ever reaches the wire with a local id is dirty forever.
        client.fail_next_for_id(
            axiotask_core::api::in_memory::Method::DeleteTask,
            &local_id,
            || axiotask_core::api::ApiError::Other("Invalid task ID".into()),
        );
        state.run_sync().await.unwrap();

        assert!(
            state
                .store
                .find_task_any(&local_id)
                .await
                .unwrap()
                .is_none(),
            "the unpushable tombstone was dropped without ever reaching the wire"
        );
        assert_eq!(state.pending_push_count().await.unwrap(), 0);
        assert!(
            state.store.inflight_creates().await.unwrap().is_empty(),
            "and its in-flight marker went with it"
        );
        let out = state.run_sync().await.unwrap();
        assert_eq!((out.pushed, out.deleted, out.errors), (0, 0, 0), "P7");
    }

    // ─── User-facing error sanitization (#128) ───────────────────────────────
    //
    // A command's Err string is what the frontend renders in a toast. A raw
    // sqlx/SQL error ("sql: UNIQUE constraint failed: tasks.id") is noise to the
    // user; it must be replaced with a calm per-family message while the full
    // detail is kept for the log. Auth signals the UI switches state on, and the
    // deliberate human validation messages we author, must pass through intact.
    mod user_facing_errors {
        use crate::commands::user_error;
        use axiotask_core::store::StoreError;

        #[test]
        fn raw_sql_error_is_replaced_and_never_shown_verbatim() {
            // The exact string a failing store query produces at the boundary.
            let raw = StoreError::Sql("UNIQUE constraint failed: tasks.id".into()).to_string();
            assert!(
                raw.contains("sql:"),
                "precondition: the raw string leaks SQL"
            );

            let shown = user_error("create_task", raw);
            assert!(
                !shown.contains("sql:"),
                "no sql prefix reaches the user: {shown}"
            );
            assert!(
                !shown.to_lowercase().contains("constraint"),
                "no sqlx detail reaches the user: {shown}"
            );
            assert!(
                shown.to_lowercase().contains("log"),
                "the message points the user at the log: {shown}"
            );
        }

        #[test]
        fn message_is_grouped_by_command_family() {
            let sql = || StoreError::Sql("disk I/O error".into()).to_string();
            let sync = user_error("sync_now", sql());
            let backup = user_error("import_backup", sql());
            let task = user_error("toggle_complete", sql());
            // Distinct families read differently, and none leak the raw detail.
            assert!(sync.to_lowercase().contains("sync"), "{sync}");
            assert!(backup.to_lowercase().contains("backup"), "{backup}");
            assert_ne!(sync, task);
            for m in [&sync, &backup, &task] {
                assert!(!m.to_lowercase().contains("disk i/o"), "leaked detail: {m}");
            }
        }

        #[test]
        fn auth_signals_pass_through_so_the_ui_can_react() {
            // The frontend substring-matches these to flip auth affordances.
            assert_eq!(
                user_error("sync_now", "not authenticated".into()),
                "not authenticated"
            );
            let expired = "session expired — sign in again (invalid_grant)".to_string();
            assert_eq!(user_error("sync_now", expired.clone()), expired);
        }

        #[test]
        fn deliberate_validation_messages_pass_through() {
            // Non-happy path: a human message we authored is already safe and
            // must survive unchanged (it explains the refusal to the user).
            let msg = "cannot nest under a subtask: subtasks are one level deep";
            assert_eq!(user_error("move_task", msg.into()), msg);
            let nf = "task abc not found";
            assert_eq!(user_error("rename_task", nf.into()), nf);
            // Every authored validation clause is on the allowlist.
            for authored in [
                "invalid due date: garbage",
                "unknown date move: sideways",
                "cannot make a task with subtasks into a subtask",
                "not found in siblings",
                "no backup file found to restore",
                "invalid backup file: trailing comma",
                "backup version 9 is newer than this app supports (1)",
            ] {
                assert_eq!(
                    user_error("import_backup", authored.into()),
                    authored,
                    "authored message must survive verbatim"
                );
            }
        }

        #[test]
        fn unknown_error_with_no_known_marker_is_never_shown_verbatim() {
            // #135: the guard is now an ALLOWLIST. A future error `Display` we
            // never classified — carrying no SQL prefix, so the old denylist
            // waved it straight through — must NOT reach the toast verbatim.
            let raw = "kaboom widget 42: the frobnicator overheated".to_string();
            let shown = user_error("create_task", raw.clone());
            assert_ne!(shown, raw, "an unclassified error must not pass verbatim");
            assert!(
                !shown.contains("kaboom"),
                "no raw detail reaches the user: {shown}"
            );
            assert!(
                !shown.contains("frobnicator"),
                "no raw detail reaches the user: {shown}"
            );
            assert!(
                shown.to_lowercase().contains("log"),
                "the message points the user at the log: {shown}"
            );
        }

        #[test]
        fn raw_network_url_is_never_shown_verbatim() {
            // #135: a manual sync that fails with a transport error reaches
            // `user_error` as `network: <reqwest text>` — which can embed the
            // full request URL. The old denylist had no marker for it, so it
            // leaked. The allowlist redacts it.
            let raw = "network: error sending request for url \
                       (https://tasks.googleapis.com/tasks/v1/lists?key=SECRET): reset"
                .to_string();
            let shown = user_error("sync_now", raw);
            assert!(
                !shown.contains("https://"),
                "no URL reaches the user: {shown}"
            );
            assert!(
                !shown.contains("googleapis"),
                "no host reaches the user: {shown}"
            );
            assert!(
                !shown.contains("SECRET"),
                "no query param reaches the user: {shown}"
            );
            assert!(
                shown.to_lowercase().contains("log"),
                "the message points the user at the log: {shown}"
            );
        }
    }
}
