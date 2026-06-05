//! Tauri IPC commands. Each function is exposed to the Svelte frontend.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tauri::State;

use crate::state::AppState;
use axiotask_core::dates::{DateMove, apply_date_move};
use axiotask_core::model::{TaskStatus};
use axiotask_core::store::{StoredTask, SyncState};

/// DTO sent to the frontend for a task list.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskListView {
    pub id: String,
    pub title: String,
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
        })
        .collect())
}

#[tauri::command]
pub async fn create_list(
    state: State<'_, Arc<AppState>>,
    title: String,
) -> Result<TaskListView, String> {
    use axiotask_core::model::TaskList;
    use axiotask_core::store::StoredTaskList;
    let id = uuid::Uuid::new_v4().to_string();
    let now = now_str();
    let stored = StoredTaskList {
        list: TaskList {
            id: id.clone(),
            title: title.clone(),
            etag: None,
            updated: now.clone(),
        },
        sync_state: SyncState::Dirty,
        local_updated: now,
        pending_op: Some("create".into()),
    };
    state.store.upsert_list(&stored).await.map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(TaskListView { id, title })
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
pub async fn delete_list(
    state: State<'_, Arc<AppState>>,
    id: String,
) -> Result<(), String> {
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
    let now = jiff::Zoned::now()
        .strftime("%Y-%m-%dT%H:%M:%SZ")
        .to_string();
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
    state.store.upsert_task(&t).await.map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(())
}

#[tauri::command]
pub async fn toggle_complete(
    state: State<'_, Arc<AppState>>,
    id: String,
) -> Result<(), String> {
    let mut t = find_task(&state, &id).await?;
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
    state.store.upsert_task(&t).await.map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(())
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
}

#[tauri::command]
pub async fn delete_task(state: State<'_, Arc<AppState>>, id: String) -> Result<DeleteToken, String> {
    let t = find_task(&state, &id).await?;
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
        state.store.upsert_task(&t).await.map_err(|e| e.to_string())?;
    }
    state.schedule_sync();
    Ok(token)
}

#[tauri::command]
pub async fn undo_delete(state: State<'_, Arc<AppState>>, token: DeleteToken) -> Result<(), String> {
    let now = now_str();
    let status = match token.status.as_str() {
        "completed" => TaskStatus::Completed,
        _ => TaskStatus::NeedsAction,
    };

    // If the tombstone is still present (delete not yet pushed), revive it in
    // place — preserving its etag — so the un-pushed delete simply never fires.
    // Reviving as a fresh 'create' here would leave the original remote task
    // un-deleted AND create a second one → duplicate.
    if let Some(mut existing) = state.store.find_task_any(&token.id).await.map_err(|e| e.to_string())? {
        existing.task.status = status;
        existing.task.completed = None;
        existing.local_updated = now;
        if existing.task.etag.is_some() {
            // Was synced and the delete hasn't pushed → restore to clean.
            existing.sync_state = SyncState::Clean;
            existing.pending_op = None;
        } else {
            existing.sync_state = SyncState::Dirty;
            existing.pending_op = Some("create".into());
        }
        state.store.upsert_task(&existing).await.map_err(|e| e.to_string())?;
        state.schedule_sync();
        return Ok(());
    }

    // Tombstone gone (delete already pushed) → recreate as a fresh task.
    let stored = StoredTask {
        task: axiotask_core::model::Task {
            id: token.id,
            parent: token.parent_id,
            position: token.position,
            title: token.title,
            notes: token.notes,
            status,
            due: token.due,
            completed: None,
            etag: None,
            updated: now.clone(),
        },
        list_id: token.list_id,
        sync_state: SyncState::Dirty,
        pending_op: Some("create".into()),
        local_updated: now,
    };
    state.store.upsert_task(&stored).await.map_err(|e| e.to_string())?;
    state.schedule_sync();
    Ok(())
}

#[tauri::command]
pub async fn set_due(
    state: State<'_, Arc<AppState>>,
    id: String,
    mv: String,
) -> Result<(), String> {
    let mut t = find_task(&state, &id).await?;

    if let Some(raw) = mv.strip_prefix("raw:") {
        // Direct date string from detail panel
        t.task.due = Some(raw.to_string());
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
    state.store.upsert_task(&t).await.map_err(|e| e.to_string())?;
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
    state.store.upsert_task(&t).await.map_err(|e| e.to_string())?;
    state
        .store
        .record_move(&id, &t.list_id, parent_id.as_deref(), previous_id.as_deref())
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
) -> Result<(), String> {
    state.move_task_to_list(&id, &target_list_id).await
}

#[tauri::command]
pub async fn clear_completed(
    state: State<'_, Arc<AppState>>,
    list_id: String,
) -> Result<u32, String> {
    let tasks = state.store.list_tasks(&list_id).await.map_err(|e| e.to_string())?;
    let mut count = 0u32;
    for t in tasks {
        if t.task.status == TaskStatus::Completed {
            if t.task.etag.is_none() {
                state.store.delete_task_hard(&t.task.id).await.map_err(|e| e.to_string())?;
            } else {
                let mut d = t;
                d.sync_state = SyncState::Deleted;
                d.pending_op = Some("delete".into());
                d.local_updated = now_str();
                state.store.upsert_task(&d).await.map_err(|e| e.to_string())?;
            }
            count += 1;
        }
    }
    state.schedule_sync();
    Ok(count)
}

#[tauri::command]
pub async fn sync_now(state: State<'_, Arc<AppState>>) -> Result<String, String> {
    let outcome = state.run_sync_if_authed().await?;
    Ok(format!(
        "pulled={}, pushed={}, conflicts={}, deleted={}",
        outcome.pulled, outcome.pushed, outcome.conflicts, outcome.deleted
    ))
}

#[tauri::command]
pub async fn fresh_sync(state: State<'_, Arc<AppState>>) -> Result<String, String> {
    // Drop all local data and re-pull from Google
    state.store.clear_all().await.map_err(|e| e.to_string())?;
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
    state.store.upsert_task(&t).await.map_err(|e| e.to_string())?;
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
    let all = state.store.list_tasks(&t.list_id).await.map_err(|e| e.to_string())?;
    // Find siblings (same parent)
    let siblings: Vec<_> = all.iter().filter(|s| s.task.parent == t.task.parent).collect();
    let idx = siblings.iter().position(|s| s.task.id == id).ok_or("not found in siblings")?;
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
    state.store.upsert_task(&current).await.map_err(|e| e.to_string())?;
    state.store.upsert_task(&other).await.map_err(|e| e.to_string())?;

    // Determine the sibling the task now follows, and record a move to push
    // via the Tasks move API (Google reorders through move, not patch).
    let new_previous: Option<String> = match direction.as_str() {
        "up" => (idx >= 2).then(|| siblings[idx - 2].task.id.clone()),
        _ /* down */ => Some(siblings[idx + 1].task.id.clone()),
    };
    state
        .store
        .record_move(&id, &t.list_id, t.task.parent.as_deref(), new_previous.as_deref())
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
pub async fn auth_login(state: State<'_, Arc<AppState>>) -> Result<(), String> {
    state.start_login().await
}

#[tauri::command]
pub async fn auth_logout(state: State<'_, Arc<AppState>>) -> Result<(), String> {
    state.logout()
}

#[tauri::command]
pub async fn open_url(url: String) -> Result<(), String> {
    open::that(&url).map_err(|e| e.to_string())
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
    jiff::Zoned::now()
        .strftime("%Y-%m-%dT%H:%M:%SZ")
        .to_string()
}

/// Pending op for a field edit. A row that was never pushed (no etag) must
/// stay a `create` — flipping it to `update` would make push patch a
/// non-existent remote id, 404, and delete the task. Otherwise it's `update`.
pub(crate) fn dirty_op(etag: Option<&str>) -> String {
    if etag.is_none() { "create" } else { "update" }.into()
}
