//! Tauri IPC commands. Each function is exposed to the Svelte frontend.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tauri::State;

use crate::state::AppState;
use axiotask_core::dates::{DateMove, apply_date_move};
use axiotask_core::model::TaskStatus;
use axiotask_core::store::{StoredTask, SyncState};

/// DTO sent to the frontend for a task list.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskListView {
    pub id: String,
    pub title: String,
    /// Local-only lists never sync to Google. The UI badges them so the user
    /// knows the list (and its tasks) stay on this device.
    pub local_only: bool,
}

/// DTO sent to the frontend for a task.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskView {
    pub id: String,
    pub parent_id: Option<String>,
    pub title: String,
    pub notes: Option<String>,
    pub status: String,
    pub due: Option<String>,
    pub position: String,
    pub sync_state: String,
    /// Absolute link to the task in the Google Tasks web UI, when known.
    pub web_view_link: Option<String>,
}

impl From<&StoredTask> for TaskView {
    fn from(st: &StoredTask) -> Self {
        Self {
            id: st.task.id.clone(),
            parent_id: st.task.parent.clone(),
            title: st.task.title.clone(),
            notes: st.task.notes.clone(),
            status: st.task.status.as_api_str().to_string(),
            due: st.task.due.clone(),
            position: st.task.position.clone(),
            sync_state: st.sync_state.as_str().to_string(),
            web_view_link: st.task.web_view_link.clone(),
        }
    }
}

#[tauri::command]
pub async fn list_tasklists(state: State<'_, Arc<AppState>>) -> Result<Vec<TaskListView>, String> {
    let lists = state.store.all_lists().await.map_err(|e| e.to_string())?;
    Ok(lists
        .iter()
        .map(|l| TaskListView {
            id: l.list.id.clone(),
            title: l.list.title.clone(),
            local_only: l.local_only,
        })
        .collect())
}

#[tauri::command]
pub async fn create_list(
    state: State<'_, Arc<AppState>>,
    title: String,
    local_only: Option<bool>,
) -> Result<TaskListView, String> {
    let stored = state
        .create_list(&title, local_only.unwrap_or(false))
        .await?;
    Ok(TaskListView {
        id: stored.list.id,
        title: stored.list.title,
        local_only: stored.local_only,
    })
}

#[tauri::command]
pub async fn rename_list(
    state: State<'_, Arc<AppState>>,
    id: String,
    title: String,
) -> Result<(), String> {
    state.rename_list(&id, &title).await
}

#[tauri::command]
pub async fn delete_list(state: State<'_, Arc<AppState>>, id: String) -> Result<(), String> {
    state.delete_list(&id).await
}

#[tauri::command]
pub async fn list_tasks(
    state: State<'_, Arc<AppState>>,
    list_id: String,
) -> Result<Vec<TaskView>, String> {
    let tasks = state
        .store
        .list_tasks(&list_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(tasks.iter().map(TaskView::from).collect())
}

#[tauri::command]
pub async fn create_task(
    state: State<'_, Arc<AppState>>,
    list_id: String,
    parent_id: Option<String>,
    title: String,
) -> Result<TaskView, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let now = now_str();
    let stored = StoredTask {
        task: axiotask_core::model::Task {
            id: id.clone(),
            parent: parent_id,
            position: "00000000000000000000".into(),
            title,
            notes: None,
            status: TaskStatus::NeedsAction,
            due: None,
            completed: None,
            etag: None,
            updated: now.clone(),
            web_view_link: None,
        },
        list_id,
        sync_state: SyncState::Dirty,
        local_updated: now,
        pending_op: Some("create".into()),
    };
    state
        .store
        .upsert_task(&stored)
        .await
        .map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(TaskView::from(&stored))
}

#[tauri::command]
pub async fn rename_task(
    state: State<'_, Arc<AppState>>,
    id: String,
    title: String,
) -> Result<(), String> {
    let tasks = find_task(&state, &id).await?;
    let mut t = tasks;
    t.task.title = title;
    t.sync_state = SyncState::Dirty;
    t.pending_op = Some(if t.task.etag.is_none() {
        "create".into()
    } else {
        "update".into()
    });
    t.local_updated = now_str();
    state
        .store
        .upsert_task(&t)
        .await
        .map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(())
}

#[tauri::command]
pub async fn toggle_complete(state: State<'_, Arc<AppState>>, id: String) -> Result<(), String> {
    toggle_complete_inner(&state, id).await
}

/// The command's logic, callable without a Tauri runtime so tests exercise the
/// real behavior instead of a re-implementation.
pub(crate) async fn toggle_complete_inner(state: &AppState, id: String) -> Result<(), String> {
    let mut t = find_task(state, &id).await?;
    t.task.status = match t.task.status {
        TaskStatus::NeedsAction => TaskStatus::Completed,
        TaskStatus::Completed => TaskStatus::NeedsAction,
    };
    t.task.completed = if t.task.status == TaskStatus::Completed {
        Some(now_str())
    } else {
        None
    };
    t.sync_state = SyncState::Dirty;
    t.pending_op = Some(dirty_op(t.task.etag.as_deref()));
    t.local_updated = now_str();

    // Completing a parent completes its open descendants — Google does this
    // server-side (verified live), so mirror it locally and push the same,
    // keeping UI state, subtask progress, and date propagation truthful now
    // instead of after the next pull. Un-completing does NOT cascade: the
    // server leaves children completed in that direction (also verified).
    let cascade = t.task.status == TaskStatus::Completed;
    state
        .store
        .upsert_task(&t)
        .await
        .map_err(|e| e.to_string())?;
    if cascade {
        let siblings = state
            .store
            .list_tasks(&t.list_id)
            .await
            .map_err(|e| e.to_string())?;
        let mut frontier = vec![id.clone()];
        while let Some(pid) = frontier.pop() {
            for child in siblings
                .iter()
                .filter(|c| c.task.parent.as_deref() == Some(pid.as_str()))
            {
                frontier.push(child.task.id.clone());
                if child.task.status == TaskStatus::Completed {
                    continue;
                }
                let mut c = child.clone();
                c.task.status = TaskStatus::Completed;
                c.task.completed = Some(now_str());
                c.sync_state = SyncState::Dirty;
                c.pending_op = Some(dirty_op(c.task.etag.as_deref()));
                c.local_updated = now_str();
                state
                    .store
                    .upsert_task(&c)
                    .await
                    .map_err(|e| e.to_string())?;
            }
        }
    }
    state.schedule_sync();
    Ok(())
}

/// A descendant captured in a [`DeleteToken`], so undo can rebuild the whole
/// subtree even after the parent's delete pushed (the server cascades child
/// deletion when a parent dies — verified live — and the local FK mirrors it).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtreeEntry {
    pub id: String,
    pub parent_id: Option<String>,
    pub title: String,
    pub notes: Option<String>,
    pub status: String,
    pub due: Option<String>,
    pub position: String,
}

/// Token returned by delete_task to enable undo.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeleteToken {
    pub id: String,
    pub list_id: String,
    pub parent_id: Option<String>,
    pub title: String,
    pub notes: Option<String>,
    pub status: String,
    pub due: Option<String>,
    pub position: String,
    pub had_etag: bool,
    /// Descendants at delete time, parents before children.
    #[serde(default)]
    pub subtree: Vec<SubtreeEntry>,
}

#[tauri::command]
pub async fn delete_task(
    state: State<'_, Arc<AppState>>,
    id: String,
) -> Result<DeleteToken, String> {
    delete_task_inner(&state, id).await
}

/// The command's logic, callable without a Tauri runtime so tests exercise the
/// real behavior instead of a re-implementation.
pub(crate) async fn delete_task_inner(state: &AppState, id: String) -> Result<DeleteToken, String> {
    let t = find_task(state, &id).await?;

    // Snapshot the descendants (BFS → parents before children) so undo can
    // rebuild them after the delete's server-side cascade destroyed them.
    let list = state
        .store
        .list_tasks(&t.list_id)
        .await
        .map_err(|e| e.to_string())?;
    let mut subtree = Vec::new();
    let mut frontier = vec![id.clone()];
    while let Some(pid) = frontier.pop() {
        for c in list
            .iter()
            .filter(|c| c.task.parent.as_deref() == Some(pid.as_str()))
        {
            frontier.push(c.task.id.clone());
            subtree.push(SubtreeEntry {
                id: c.task.id.clone(),
                parent_id: c.task.parent.clone(),
                title: c.task.title.clone(),
                notes: c.task.notes.clone(),
                status: c.task.status.as_api_str().to_string(),
                due: c.task.due.clone(),
                position: c.task.position.clone(),
            });
        }
    }

    let token = DeleteToken {
        id: t.task.id.clone(),
        list_id: t.list_id.clone(),
        parent_id: t.task.parent.clone(),
        title: t.task.title.clone(),
        notes: t.task.notes.clone(),
        status: t.task.status.as_api_str().to_string(),
        due: t.task.due.clone(),
        position: t.task.position.clone(),
        had_etag: t.task.etag.is_some(),
        subtree,
    };

    if t.task.etag.is_none() {
        // Never pushed — just hard-delete locally.
        state
            .store
            .delete_task_hard(&id)
            .await
            .map_err(|e| e.to_string())?;
    } else {
        let mut t = t;
        t.sync_state = SyncState::Deleted;
        t.pending_op = Some("delete".into());
        t.local_updated = now_str();
        state
            .store
            .upsert_task(&t)
            .await
            .map_err(|e| e.to_string())?;
    }
    state.schedule_sync();
    Ok(token)
}

#[tauri::command]
pub async fn undo_delete(
    state: State<'_, Arc<AppState>>,
    token: DeleteToken,
) -> Result<(), String> {
    undo_delete_inner(&state, token).await
}

/// The command's logic, callable without a Tauri runtime so tests exercise the
/// real behavior instead of a re-implementation.
pub(crate) async fn undo_delete_inner(state: &AppState, token: DeleteToken) -> Result<(), String> {
    let now = now_str();
    let status = match token.status.as_str() {
        "completed" => TaskStatus::Completed,
        _ => TaskStatus::NeedsAction,
    };

    // If the tombstone is still present (delete not yet pushed), revive it in
    // place — preserving its etag — so the un-pushed delete simply never fires.
    // Reviving as a fresh 'create' here would leave the original remote task
    // un-deleted AND create a second one → duplicate.
    if let Some(mut existing) = state
        .store
        .find_task_any(&token.id)
        .await
        .map_err(|e| e.to_string())?
    {
        existing.task.status = status;
        existing.task.completed = None;
        existing.local_updated = now.clone();
        if existing.task.etag.is_some() {
            // Was synced and the delete hasn't pushed. Revive as a dirty
            // UPDATE, not clean: the tombstone may be sitting on top of an
            // edit that never pushed, and reviving clean would silently drop
            // that edit from the push queue. If nothing actually changed, the
            // extra patch is an idempotent no-op.
            existing.sync_state = SyncState::Dirty;
            existing.pending_op = Some("update".into());
        } else {
            existing.sync_state = SyncState::Dirty;
            existing.pending_op = Some("create".into());
        }
        state
            .store
            .upsert_task(&existing)
            .await
            .map_err(|e| e.to_string())?;
        restore_subtree(state, &token, &now).await?;
        state.schedule_sync();
        return Ok(());
    }

    // Tombstone gone (delete already pushed) → recreate as a fresh task. If
    // its original parent no longer exists (deleted separately), fall back to
    // top level instead of failing the FK.
    let parent = match &token.parent_id {
        Some(p)
            if state
                .store
                .find_task_any(p)
                .await
                .map_err(|e| e.to_string())?
                .is_some() =>
        {
            Some(p.clone())
        }
        _ => None,
    };
    let stored = StoredTask {
        task: axiotask_core::model::Task {
            id: token.id.clone(),
            parent,
            position: token.position.clone(),
            title: token.title.clone(),
            notes: token.notes.clone(),
            status,
            due: token.due.clone(),
            completed: None,
            etag: None,
            updated: now.clone(),
            web_view_link: None,
        },
        list_id: token.list_id.clone(),
        sync_state: SyncState::Dirty,
        pending_op: Some("create".into()),
        local_updated: now.clone(),
    };
    state
        .store
        .upsert_task(&stored)
        .await
        .map_err(|e| e.to_string())?;
    restore_subtree(state, &token, &now).await?;
    state.schedule_sync();
    Ok(())
}

/// Recreate the descendants captured at delete time that no longer exist
/// locally (the push of the parent's delete cascaded them away, both on the
/// server and via the local FK). Entries are ordered parents-before-children,
/// and each is revived as a fresh dirty CREATE — the old remote ids are dead.
/// Descendants that still exist (delete never pushed) are left untouched.
async fn restore_subtree(state: &AppState, token: &DeleteToken, now: &str) -> Result<(), String> {
    for e in &token.subtree {
        if state
            .store
            .find_task_any(&e.id)
            .await
            .map_err(|err| err.to_string())?
            .is_some()
        {
            continue;
        }
        let status = match e.status.as_str() {
            "completed" => TaskStatus::Completed,
            _ => TaskStatus::NeedsAction,
        };
        let stored = StoredTask {
            task: axiotask_core::model::Task {
                id: e.id.clone(),
                parent: e.parent_id.clone(),
                position: e.position.clone(),
                title: e.title.clone(),
                notes: e.notes.clone(),
                status,
                due: e.due.clone(),
                completed: None,
                etag: None,
                updated: now.to_string(),
                web_view_link: None,
            },
            list_id: token.list_id.clone(),
            sync_state: SyncState::Dirty,
            pending_op: Some("create".into()),
            local_updated: now.to_string(),
        };
        state
            .store
            .upsert_task(&stored)
            .await
            .map_err(|err| err.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub async fn set_due(
    state: State<'_, Arc<AppState>>,
    id: String,
    mv: String,
) -> Result<(), String> {
    set_due_inner(&state, id, mv).await
}

/// The command's logic, callable without a Tauri runtime so tests exercise the
/// real behavior instead of a re-implementation.
pub(crate) async fn set_due_inner(state: &AppState, id: String, mv: String) -> Result<(), String> {
    let mut t = find_task(state, &id).await?;

    if let Some(raw) = mv.strip_prefix("raw:") {
        // Direct date string from the calendar picker / detail panel. Must be
        // canonicalized: Google rejects a bare "YYYY-MM-DD" with a permanent
        // 400, which would poison this row's push on every future sync run.
        t.task.due = Some(
            axiotask_core::dates::normalize_due(raw)
                .ok_or_else(|| format!("invalid due date: {raw}"))?,
        );
    } else {
        let date_move = match mv.as_str() {
            "Today" => DateMove::Today,
            "Tomorrow" => DateMove::Tomorrow,
            "NextWeek" => DateMove::NextWeek,
            "NextMonth" => DateMove::NextMonth,
            "Clear" => DateMove::Clear,
            _ => return Err(format!("unknown date move: {mv}")),
        };
        let today = jiff::Zoned::now().date();
        let new_due = apply_date_move(today, date_move);
        t.task.due = new_due.map(|d| format!("{d}T00:00:00.000Z"));
    }

    t.sync_state = SyncState::Dirty;
    t.pending_op = Some(dirty_op(t.task.etag.as_deref()));
    t.local_updated = now_str();
    state
        .store
        .upsert_task(&t)
        .await
        .map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(())
}

#[tauri::command]
pub async fn move_task(
    state: State<'_, Arc<AppState>>,
    id: String,
    parent_id: Option<String>,
    previous_id: Option<String>,
) -> Result<(), String> {
    let mut t = find_task(&state, &id).await?;
    t.task.parent = parent_id.clone();
    if let Some(ref prev) = previous_id {
        t.task.position = format!("after-{prev}");
    } else {
        t.task.position = "00000000000001".into();
    }
    // Local position/parent updated immediately. The actual reorder is pushed
    // via the move API (recorded in pending_moves), not patch_task.
    t.local_updated = now_str();
    state
        .store
        .upsert_task(&t)
        .await
        .map_err(|e| e.to_string())?;
    state
        .store
        .record_move(
            &id,
            &t.list_id,
            parent_id.as_deref(),
            previous_id.as_deref(),
        )
        .await
        .map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(())
}

#[tauri::command]
pub async fn move_to_list(
    state: State<'_, Arc<AppState>>,
    id: String,
    target_list_id: String,
) -> Result<String, String> {
    state.move_task_to_list(&id, &target_list_id).await
}

#[tauri::command]
pub async fn clear_completed(
    state: State<'_, Arc<AppState>>,
    list_id: String,
) -> Result<u32, String> {
    clear_completed_inner(&state, list_id).await
}

/// The command's logic, callable without a Tauri runtime so tests exercise the
/// real behavior instead of a re-implementation.
pub(crate) async fn clear_completed_inner(
    state: &AppState,
    list_id: String,
) -> Result<u32, String> {
    let tasks = state
        .store
        .list_tasks(&list_id)
        .await
        .map_err(|e| e.to_string())?;

    // Deleting a task deletes its descendants — on Google (verified live) and
    // locally via the FK cascade. A completed parent can still shelter OPEN
    // subtasks (e.g. completed remotely before its children, or local edits),
    // so deleting it would destroy unfinished work. Skip those parents.
    let has_open_descendant = |root: &str| -> bool {
        let mut frontier = vec![root.to_string()];
        while let Some(pid) = frontier.pop() {
            for c in tasks
                .iter()
                .filter(|c| c.task.parent.as_deref() == Some(pid.as_str()))
            {
                if c.task.status != TaskStatus::Completed {
                    return true;
                }
                frontier.push(c.task.id.clone());
            }
        }
        false
    };

    let mut count = 0u32;
    for t in &tasks {
        if t.task.status == TaskStatus::Completed {
            if has_open_descendant(&t.task.id) {
                tracing::info!(id = %t.task.id, "clear-completed: skipping parent with open subtasks");
                continue;
            }
            if t.task.etag.is_none() {
                state
                    .store
                    .delete_task_hard(&t.task.id)
                    .await
                    .map_err(|e| e.to_string())?;
            } else {
                let mut d = t.clone();
                d.sync_state = SyncState::Deleted;
                d.pending_op = Some("delete".into());
                d.local_updated = now_str();
                state
                    .store
                    .upsert_task(&d)
                    .await
                    .map_err(|e| e.to_string())?;
            }
            count += 1;
        }
    }
    state.schedule_sync();
    Ok(count)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncRunView {
    pub summary: String,
    pub changed_list_ids: Vec<String>,
    pub lists_changed: bool,
}

#[tauri::command]
pub async fn sync_now(state: State<'_, Arc<AppState>>) -> Result<SyncRunView, String> {
    let outcome = state.run_sync_if_authed().await?;
    Ok(SyncRunView {
        summary: format!(
            "pulled={}, pushed={}, conflicts={}, deleted={}",
            outcome.pulled, outcome.pushed, outcome.conflicts, outcome.deleted
        ),
        changed_list_ids: outcome.changed_list_ids,
        lists_changed: outcome.lists_changed,
    })
}

#[tauri::command]
pub async fn fresh_sync(state: State<'_, Arc<AppState>>) -> Result<String, String> {
    // Drop synced local data and re-pull from Google. Local-only lists are
    // preserved — they exist nowhere else and a fresh pull cannot recreate them.
    state
        .store
        .clear_synced()
        .await
        .map_err(|e| e.to_string())?;
    let outcome = state.run_sync_if_authed().await?;
    Ok(format!(
        "fresh sync: pulled={}, lists and tasks rebuilt from remote",
        outcome.pulled
    ))
}

#[tauri::command]
pub async fn set_notes(
    state: State<'_, Arc<AppState>>,
    id: String,
    notes: String,
) -> Result<(), String> {
    let mut t = find_task(&state, &id).await?;
    t.task.notes = if notes.is_empty() { None } else { Some(notes) };
    t.sync_state = SyncState::Dirty;
    t.pending_op = Some(dirty_op(t.task.etag.as_deref()));
    t.local_updated = now_str();
    state
        .store
        .upsert_task(&t)
        .await
        .map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(())
}

#[tauri::command]
pub async fn reorder_task(
    state: State<'_, Arc<AppState>>,
    id: String,
    direction: String,
) -> Result<(), String> {
    let t = find_task(&state, &id).await?;
    let all = state
        .store
        .list_tasks(&t.list_id)
        .await
        .map_err(|e| e.to_string())?;
    // Find siblings (same parent)
    let siblings: Vec<_> = all
        .iter()
        .filter(|s| s.task.parent == t.task.parent)
        .collect();
    let idx = siblings
        .iter()
        .position(|s| s.task.id == id)
        .ok_or("not found in siblings")?;
    let swap_idx = match direction.as_str() {
        "up" if idx > 0 => idx - 1,
        "down" if idx < siblings.len() - 1 => idx + 1,
        _ => return Ok(()), // no-op at boundary
    };

    // Swap local positions so the UI reflects the new order immediately.
    let mut current = t.clone();
    let mut other = siblings[swap_idx].clone();
    std::mem::swap(&mut current.task.position, &mut other.task.position);
    current.local_updated = now_str();
    other.local_updated = now_str();
    state
        .store
        .upsert_task(&current)
        .await
        .map_err(|e| e.to_string())?;
    state
        .store
        .upsert_task(&other)
        .await
        .map_err(|e| e.to_string())?;

    // Determine the sibling the task now follows, and record a move to push
    // via the Tasks move API (Google reorders through move, not patch).
    let new_previous: Option<String> = match direction.as_str() {
        "up" => (idx >= 2).then(|| siblings[idx - 2].task.id.clone()),
        _ /* down */ => Some(siblings[idx + 1].task.id.clone()),
    };
    state
        .store
        .record_move(
            &id,
            &t.list_id,
            t.task.parent.as_deref(),
            new_previous.as_deref(),
        )
        .await
        .map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(())
}

#[tauri::command]
pub async fn auth_status(state: State<'_, Arc<AppState>>) -> Result<bool, String> {
    Ok(state.is_authenticated())
}

#[tauri::command]
pub async fn auth_login(state: State<'_, Arc<AppState>>) -> Result<bool, String> {
    // Returns `true` rather than `()`: Tauri resolves a unit Ok as `null`,
    // which is exactly what the frontend's error wrapper returns on failure —
    // a successful login was indistinguishable from a failed one, so the UI
    // never flipped to signed-in until a restart (#45).
    state.start_login().await?;
    Ok(true)
}

#[tauri::command]
pub async fn auth_logout(state: State<'_, Arc<AppState>>) -> Result<(), String> {
    state.logout().await
}

#[tauri::command]
pub async fn open_url(url: String) -> Result<(), String> {
    open::that(&url).map_err(|e| e.to_string())
}

/// Sync status and running stats, surfaced to the Properties dialog.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncStatusView {
    /// RFC-3339 timestamp of the last successful sync, or null if none yet.
    pub last_synced: Option<String>,
    pub last_pulled: u32,
    pub last_pushed: u32,
    pub last_conflicts: u32,
    pub last_deleted: u32,
    pub changed_list_ids: Vec<String>,
    pub lists_changed: bool,
    /// Successful syncs since the app started.
    pub total_syncs: u64,
    /// Most recent sync error, cleared on the next success.
    pub last_error: Option<String>,
    /// The stored session is dead — the user must sign in again. Rides on the
    /// `sync-updated` event so the main window can show a re-auth action.
    pub needs_reauth: bool,
}

impl From<&crate::state::SyncStatus> for SyncStatusView {
    fn from(s: &crate::state::SyncStatus) -> Self {
        Self {
            last_synced: s.last_synced.clone(),
            last_pulled: s.last_pulled,
            last_pushed: s.last_pushed,
            last_conflicts: s.last_conflicts,
            last_deleted: s.last_deleted,
            changed_list_ids: s.changed_list_ids.clone(),
            lists_changed: s.lists_changed,
            total_syncs: s.total_syncs,
            last_error: s.last_error.clone(),
            needs_reauth: s.needs_reauth,
        }
    }
}

/// Everything the Properties dialog needs in a single round-trip.
// A flat wire DTO mirroring independent UI toggles — grouping the bools into
// enums would only complicate the frontend contract.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    /// App version (from Cargo).
    pub version: String,
    /// Active instance prefix (`AXIOTASK_PREFIX`), or null for the default
    /// (production) instance. Shown so the user can tell instances apart.
    pub instance: Option<String>,
    /// Read-write sync (push local changes) vs. read-only (pull only).
    pub push_enabled: bool,
    /// Auto-sync on startup.
    pub auto_sync_on_start: bool,
    /// Whether the user is signed in to Google.
    pub authenticated: bool,
    /// Tokens exist but the session is dead (refresh permanently denied,
    /// e.g. `invalid_grant`) — the user must sign in again before anything
    /// syncs. Background syncs are paused while this is set.
    pub needs_reauth: bool,
    /// OAuth scopes the app is configured to request (what it can access).
    pub scopes: Vec<String>,
    /// Local SQLite database path.
    pub db_path: String,
    /// Config file path (where settings are saved).
    pub config_path: String,
    /// Local changes awaiting push (0 in a fully-synced state).
    pub pending_pushes: u32,
    /// Last sync outcome and stats.
    pub sync: SyncStatusView,
}

/// Assemble the full settings snapshot from app state.
async fn build_settings(state: &AppState) -> Result<AppSettings, String> {
    let status = state.sync_status().await;
    Ok(AppSettings {
        version: env!("CARGO_PKG_VERSION").to_string(),
        instance: axiotask_core::config::instance_prefix(),
        push_enabled: state.is_push_enabled(),
        auto_sync_on_start: state.auto_sync_on_start(),
        authenticated: state.is_authenticated(),
        needs_reauth: state.needs_reauth(),
        scopes: state.scopes(),
        db_path: state.db_path().display().to_string(),
        config_path: state.config_path().display().to_string(),
        pending_pushes: state.pending_push_count().await?,
        sync: SyncStatusView::from(&status),
    })
}

/// Read the current application settings and sync status.
#[tauri::command]
pub async fn get_settings(state: State<'_, Arc<AppState>>) -> Result<AppSettings, String> {
    build_settings(&state).await
}

/// Toggle read-write sync (push enabled) vs. read-only. Persists to config and
/// returns the refreshed settings so the UI stays in sync.
#[tauri::command]
pub async fn set_push_enabled(
    state: State<'_, Arc<AppState>>,
    enabled: bool,
) -> Result<AppSettings, String> {
    state.set_push_enabled(enabled)?;
    build_settings(&state).await
}

/// Mark whether the user is actively editing a task, so background pushes are
/// held until they finish (prevents a create's id remap mid-edit).
#[tauri::command]
pub async fn set_editing(state: State<'_, Arc<AppState>>, editing: bool) -> Result<(), String> {
    state.set_editing(editing);
    Ok(())
}

/// Toggle auto-sync on startup. Persists to config and returns refreshed
/// settings.
#[tauri::command]
pub async fn set_auto_sync(
    state: State<'_, Arc<AppState>>,
    enabled: bool,
) -> Result<AppSettings, String> {
    state.set_auto_sync_on_start(enabled)?;
    build_settings(&state).await
}

/// Result of an export, surfaced to the UI for a confirmation toast.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportResult {
    /// Absolute path the backup was written to.
    pub path: String,
    /// Number of task lists included.
    pub lists: usize,
    /// Total number of tasks included.
    pub tasks: usize,
    /// Size of the written file in bytes.
    pub bytes: usize,
}

/// Export a complete, human-readable JSON backup of every list and task.
///
/// Writes to `path` when given (non-empty), otherwise to a timestamped file in
/// the default backups directory. The backup is lossless: every field and all
/// sync metadata are preserved (see [`axiotask_core::export`]).
#[tauri::command]
pub async fn export_backup(
    state: State<'_, Arc<AppState>>,
    path: Option<String>,
) -> Result<ExportResult, String> {
    let backup = state.build_backup().await?;
    let json = backup.to_json_pretty().map_err(|e| e.to_string())?;

    let target = match path {
        Some(p) if !p.trim().is_empty() => std::path::PathBuf::from(p),
        _ => crate::state::default_backup_path(),
    };
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&target, json.as_bytes()).map_err(|e| e.to_string())?;

    Ok(ExportResult {
        path: target.display().to_string(),
        lists: backup.lists.len(),
        tasks: backup.task_count(),
        bytes: json.len(),
    })
}

/// Result of an import/restore, surfaced to the UI for a confirmation toast.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportResult {
    /// Absolute path the backup was read from.
    pub path: String,
    /// Number of task lists restored.
    pub lists: usize,
    /// Total number of tasks restored.
    pub tasks: usize,
}

/// Restore a JSON backup into the local store (inverse of [`export_backup`]).
///
/// Reads from `path` when given (non-empty), otherwise from the most recent
/// file in the default backups directory. The restore is a non-destructive
/// merge: rows in the backup are upserted by id, but local rows absent from the
/// backup are left untouched, so an import can never silently lose data.
///
/// Backups produced by a newer schema version are refused rather than guessed
/// at, matching the contract in [`axiotask_core::export`].
#[tauri::command]
pub async fn import_backup(
    state: State<'_, Arc<AppState>>,
    path: Option<String>,
) -> Result<ImportResult, String> {
    let target = match path {
        Some(p) if !p.trim().is_empty() => std::path::PathBuf::from(p.trim()),
        _ => crate::state::latest_backup_path().ok_or("no backup file found to restore")?,
    };

    let json = std::fs::read_to_string(&target).map_err(|e| e.to_string())?;
    let backup = axiotask_core::export::Backup::from_json(&json)
        .map_err(|e| format!("invalid backup file: {e}"))?;

    if backup.version > axiotask_core::export::BACKUP_VERSION {
        return Err(format!(
            "backup version {} is newer than this app supports ({})",
            backup.version,
            axiotask_core::export::BACKUP_VERSION
        ));
    }

    let summary = state.restore_backup(backup).await?;

    Ok(ImportResult {
        path: target.display().to_string(),
        lists: summary.lists,
        tasks: summary.tasks,
    })
}

async fn find_task(state: &AppState, id: &str) -> Result<StoredTask, String> {
    // Search all lists for this task id.
    let lists = state.store.all_lists().await.map_err(|e| e.to_string())?;
    for list in &lists {
        let tasks = state
            .store
            .list_tasks(&list.list.id)
            .await
            .map_err(|e| e.to_string())?;
        if let Some(t) = tasks.into_iter().find(|t| t.task.id == id) {
            return Ok(t);
        }
    }
    Err(format!("task {id} not found"))
}

fn now_str() -> String {
    axiotask_core::dates::now_utc_string()
}

/// Pending op for a field edit. A row that was never pushed (no etag) must
/// stay a `create` — flipping it to `update` would make push patch a
/// non-existent remote id, 404, and delete the task. Otherwise it's `update`.
pub(crate) fn dirty_op(etag: Option<&str>) -> String {
    if etag.is_none() { "create" } else { "update" }.into()
}
