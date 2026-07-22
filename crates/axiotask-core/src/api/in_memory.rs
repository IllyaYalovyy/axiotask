//! Deterministic in-memory implementation of [`GoogleTasksClient`].
//!
//! Used as a test double for the sync engine and command handlers. Etags are
//! a monotonic counter so conflict scenarios are deterministic. Faults can
//! be queued via [`InMemoryClient::fail_next`].
//!
//! The fake models the REAL Google Tasks API's strictness, verified against
//! the live service — a permissive fake lets the whole test suite pass while
//! production sync is broken:
//! - `due` must be a full RFC-3339 timestamp; a bare `YYYY-MM-DD` is rejected
//!   with a permanent 400. Accepted values are normalized to
//!   `YYYY-MM-DDT00:00:00.000Z` in responses. An empty string clears it.
//! - inserting under a nonexistent `parent` is a permanent 400.
//! - deleting a parent task deletes its descendants server-side.
//! - completing a parent task auto-completes its whole subtree server-side,
//!   and re-opening a subtask whose parent is still completed returns 200 but
//!   is silently ignored (the subtask stays completed). Re-opening the parent
//!   does NOT reopen its children. All verified against the live service; see
//!   the `live_api_probe` example for the reproducible probe harness.

use std::collections::VecDeque;
use std::sync::Mutex;

use async_trait::async_trait;

use super::{ApiError, GoogleTasksClient};
use crate::model::{NewTask, Page, Task, TaskList, TaskPatch, TaskStatus};

/// Per-method fault injection key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    /// `list_tasklists`
    ListTaskLists,
    /// `insert_tasklist`
    InsertTaskList,
    /// `patch_tasklist`
    PatchTaskList,
    /// `delete_tasklist`
    DeleteTaskList,
    /// `list_tasks`
    ListTasks,
    /// `insert_task`
    InsertTask,
    /// `get_task`
    GetTask,
    /// `patch_task`
    PatchTask,
    /// `delete_task`
    DeleteTask,
    /// `move_task`
    MoveTask,
}

#[derive(Debug, Default)]
struct State {
    lists: Vec<TaskList>,
    tasks: Vec<(String, Task)>, // (list_id, task)
    etag_counter: u64,
    faults: VecDeque<(Method, fn() -> ApiError)>,
    /// Number of recorded calls per method.
    calls: [u32; 10],
    /// When set, the next `insert_task` commits the task server-side but then
    /// returns a network error — models a response timeout after the server
    /// already created the row (the at-least-once create hazard).
    commit_then_fail_insert: bool,
}

impl State {
    fn new() -> Self {
        Self::default()
    }

    fn fresh_etag(&mut self) -> String {
        self.etag_counter += 1;
        format!("etag-{}", self.etag_counter)
    }

    fn next_fault(&mut self, m: Method) -> Option<ApiError> {
        if let Some(front) = self.faults.front()
            && front.0 == m
        {
            let (_, f) = self.faults.pop_front().unwrap();
            return Some(f());
        }
        None
    }

    fn record(&mut self, m: Method) {
        self.calls[m as usize] += 1;
    }
}

/// Validate + canonicalize a due value the way the live API does: `None`
/// passes through, `""` means clear (→ `None`), anything else must be a full
/// RFC-3339 timestamp (a bare date draws a permanent 400) and is normalized
/// to `T00:00:00.000Z`.
fn validate_due(due: Option<String>) -> Result<Option<String>, ApiError> {
    match due.as_deref() {
        None | Some("") => Ok(None),
        Some(raw) => {
            if raw.len() < 20 || !raw[10..].starts_with('T') || !raw.ends_with('Z') {
                return Err(ApiError::Other(
                    "400: Request contains an invalid argument. (due)".into(),
                ));
            }
            crate::dates::normalize_due(raw).map(Some).ok_or_else(|| {
                ApiError::Other("400: Request contains an invalid argument. (due)".into())
            })
        }
    }
}

/// In-memory test double. Cheap to clone the handle (interior `Mutex`).
#[derive(Debug, Default)]
pub struct InMemoryClient {
    inner: Mutex<State>,
}

impl InMemoryClient {
    /// Construct an empty client.
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(State::new()),
        }
    }

    /// Seed a task list. Returns the seeded list (with etag/updated filled).
    pub fn seed_list(&self, id: &str, title: &str) -> TaskList {
        let mut s = self.inner.lock().unwrap();
        let etag = s.fresh_etag();
        let list = TaskList {
            id: id.into(),
            title: title.into(),
            etag: Some(etag),
            updated: "2026-01-01T00:00:00Z".into(),
        };
        s.lists.push(list.clone());
        list
    }

    /// Seed a task. Caller controls id, parent, position to make tests deterministic.
    pub fn seed_task(&self, list_id: &str, id: &str, title: &str, position: &str) -> Task {
        self.seed_task_with_parent(list_id, id, title, position, None)
    }

    /// Seed a task with optional parent. Used for hierarchy tests.
    pub fn seed_task_with_parent(
        &self,
        list_id: &str,
        id: &str,
        title: &str,
        position: &str,
        parent: Option<&str>,
    ) -> Task {
        let mut s = self.inner.lock().unwrap();
        assert!(
            s.lists.iter().any(|l| l.id == list_id),
            "seed_task: list {list_id} not seeded"
        );
        let etag = s.fresh_etag();
        let task = Task {
            id: id.into(),
            parent: parent.map(String::from),
            position: position.into(),
            title: title.into(),
            notes: None,
            status: TaskStatus::NeedsAction,
            due: None,
            completed: None,
            etag: Some(etag),
            updated: "2026-01-01T00:00:00Z".into(),
            web_view_link: Some(format!("https://tasks.google.com/task/{id}")),
        };
        s.tasks.push((list_id.into(), task.clone()));
        task
    }

    /// Schedule a fault to be returned by the next call to `m`.
    pub fn fail_next(&self, m: Method, err: fn() -> ApiError) {
        self.inner.lock().unwrap().faults.push_back((m, err));
    }

    /// Make the next `insert_task` commit the task server-side but return a
    /// network error — models a response timeout after the server committed.
    pub fn commit_then_fail_next_insert(&self) {
        self.inner.lock().unwrap().commit_then_fail_insert = true;
    }

    /// Remove a task from internal state (simulates server-side deletion by another client).
    pub fn delete_task_from_state(&self, list_id: &str, task_id: &str) {
        let mut s = self.inner.lock().unwrap();
        s.tasks
            .retain(|(lid, t)| !(lid == list_id && t.id == task_id));
    }

    /// How many times `m` has been invoked.
    pub fn call_count(&self, m: Method) -> u32 {
        self.inner.lock().unwrap().calls[m as usize]
    }
}

#[async_trait]
impl GoogleTasksClient for InMemoryClient {
    async fn list_tasklists(&self) -> Result<Vec<TaskList>, ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::ListTaskLists);
        if let Some(e) = s.next_fault(Method::ListTaskLists) {
            return Err(e);
        }
        Ok(s.lists.clone())
    }

    async fn insert_tasklist(&self, title: &str) -> Result<TaskList, ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::InsertTaskList);
        if let Some(e) = s.next_fault(Method::InsertTaskList) {
            return Err(e);
        }
        let etag = s.fresh_etag();
        let id = format!("remote-list-{}", s.etag_counter);
        let list = TaskList {
            id,
            title: title.into(),
            etag: Some(etag),
            updated: "2026-01-01T00:00:00Z".into(),
        };
        s.lists.push(list.clone());
        Ok(list)
    }

    async fn patch_tasklist(&self, id: &str, title: &str) -> Result<TaskList, ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::PatchTaskList);
        if let Some(e) = s.next_fault(Method::PatchTaskList) {
            return Err(e);
        }
        let etag = s.fresh_etag();
        let Some(l) = s.lists.iter_mut().find(|l| l.id == id) else {
            return Err(ApiError::NotFound);
        };
        l.title = title.into();
        l.etag = Some(etag);
        Ok(l.clone())
    }

    async fn delete_tasklist(&self, id: &str) -> Result<(), ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::DeleteTaskList);
        if let Some(e) = s.next_fault(Method::DeleteTaskList) {
            return Err(e);
        }
        let before = s.lists.len();
        s.lists.retain(|l| l.id != id);
        if s.lists.len() == before {
            return Err(ApiError::NotFound);
        }
        s.tasks.retain(|(lid, _)| lid != id); // server cascades
        Ok(())
    }

    async fn list_tasks(
        &self,
        list_id: &str,
        _page_token: Option<&str>,
    ) -> Result<Page<Task>, ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::ListTasks);
        if let Some(e) = s.next_fault(Method::ListTasks) {
            return Err(e);
        }
        let items: Vec<Task> = s
            .tasks
            .iter()
            .filter(|(lid, _)| lid == list_id)
            .map(|(_, t)| t.clone())
            .collect();
        Ok(Page {
            items,
            next_page_token: None,
        })
    }

    async fn insert_task(&self, list_id: &str, new: NewTask) -> Result<Task, ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::InsertTask);
        if let Some(e) = s.next_fault(Method::InsertTask) {
            return Err(e);
        }
        if !s.lists.iter().any(|l| l.id == list_id) {
            return Err(ApiError::NotFound);
        }
        // Live-API strictness: an unknown parent id is a permanent 400 —
        // exactly what pushing a child create before its parent resolved does.
        if let Some(p) = new.parent.as_deref()
            && !s.tasks.iter().any(|(_, t)| t.id == p)
        {
            return Err(ApiError::Other("400: Invalid task ID (parent)".into()));
        }
        let due = validate_due(new.due)?;
        let etag = s.fresh_etag();
        // Live-API positioning: with `previous`, insert right after it; with
        // none, insert FIRST. Positions are opaque lexicographically-sortable
        // strings. '+' sorts before digits, so "P+" lands between P and the
        // next sibling, and '!' sorts before everything numeric (top slot,
        // successive top-inserts each land above the previous).
        let position = match new.previous.as_deref() {
            Some(prev) => match s.tasks.iter().find(|(_, t)| t.id == prev) {
                Some((_, p)) => format!("{}+", p.position),
                None => return Err(ApiError::Other("400: Invalid task ID (previous)".into())),
            },
            None => format!("!{:019}", u64::MAX - s.etag_counter),
        };
        let id = format!("remote-{}", s.etag_counter);
        let web_view_link = Some(format!("https://tasks.google.com/task/{id}"));
        let task = Task {
            id,
            parent: new.parent,
            position,
            title: new.title,
            notes: new.notes,
            status: new.status.unwrap_or(TaskStatus::NeedsAction),
            due,
            completed: None,
            etag: Some(etag),
            updated: "2026-01-01T00:00:00Z".into(),
            web_view_link,
        };
        s.tasks.push((list_id.into(), task.clone()));
        if s.commit_then_fail_insert {
            s.commit_then_fail_insert = false;
            return Err(ApiError::Network("response timeout after commit".into()));
        }
        Ok(task)
    }

    async fn get_task(&self, list_id: &str, id: &str) -> Result<Task, ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::GetTask);
        if let Some(e) = s.next_fault(Method::GetTask) {
            return Err(e);
        }
        s.tasks
            .iter()
            .find(|(lid, t)| lid == list_id && t.id == id)
            .map(|(_, t)| t.clone())
            .ok_or(ApiError::NotFound)
    }

    async fn patch_task(
        &self,
        list_id: &str,
        id: &str,
        patch: TaskPatch,
        etag: Option<&str>,
    ) -> Result<Task, ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::PatchTask);
        if let Some(e) = s.next_fault(Method::PatchTask) {
            return Err(e);
        }
        if !s.lists.iter().any(|l| l.id == list_id) {
            return Err(ApiError::NotFound);
        }
        let new_etag = s.fresh_etag();
        let Some(idx) = s.tasks.iter().position(|(_, t)| t.id == id) else {
            return Err(ApiError::NotFound);
        };
        if let Some(want) = etag
            && s.tasks[idx].1.etag.as_deref() != Some(want)
        {
            return Err(ApiError::PreconditionFailed);
        }
        let patched_due = match patch.due {
            Some(due) => Some(validate_due(Some(due))?),
            None => None,
        };
        // Live-API rule: re-opening a subtask whose parent is still completed
        // returns 200 but is silently ignored server-side. Evaluate before we
        // mutate anything (the parent's status may itself be about to change).
        let parent_completed = s.tasks[idx]
            .1
            .parent
            .clone()
            .and_then(|p| s.tasks.iter().find(|(_, t)| t.id == p))
            .is_some_and(|(_, p)| p.status == TaskStatus::Completed);
        let silently_ignore_reopen =
            patch.status == Some(TaskStatus::NeedsAction) && parent_completed;

        let t = &mut s.tasks[idx].1;
        if let Some(title) = patch.title {
            t.title = title;
        }
        if let Some(notes) = patch.notes {
            t.notes = if notes.is_empty() { None } else { Some(notes) };
        }
        if let Some(due) = patched_due {
            t.due = due;
        }
        let mut cascade_complete = false;
        if let Some(status) = patch.status
            && !silently_ignore_reopen
        {
            t.status = status;
            t.completed = if status == TaskStatus::Completed {
                Some("2026-01-01T00:00:00Z".into())
            } else {
                None
            };
            cascade_complete = status == TaskStatus::Completed;
        }
        t.etag = Some(new_etag);
        let result = t.clone();

        // Live-API cascade: completing a parent auto-completes its whole
        // subtree server-side, each descendant getting a fresh etag + completed
        // timestamp. Un-completing a parent does NOT reopen children, so this
        // only runs on completion.
        if cascade_complete {
            let mut subtree: std::collections::HashSet<String> =
                std::collections::HashSet::from([result.id.clone()]);
            loop {
                let n = subtree.len();
                let more: Vec<String> = s
                    .tasks
                    .iter()
                    .filter(|(_, t)| t.parent.as_deref().is_some_and(|p| subtree.contains(p)))
                    .map(|(_, t)| t.id.clone())
                    .collect();
                subtree.extend(more);
                if subtree.len() == n {
                    break;
                }
            }
            let to_complete: Vec<String> = s
                .tasks
                .iter()
                .filter(|(_, t)| {
                    t.id != result.id
                        && subtree.contains(&t.id)
                        && t.status != TaskStatus::Completed
                })
                .map(|(_, t)| t.id.clone())
                .collect();
            for cid in to_complete {
                let e = s.fresh_etag();
                if let Some((_, t)) = s.tasks.iter_mut().find(|(_, t)| t.id == cid) {
                    t.status = TaskStatus::Completed;
                    t.completed = Some("2026-01-01T00:00:00Z".into());
                    t.etag = Some(e);
                }
            }
        }
        Ok(result)
    }

    async fn delete_task(&self, list_id: &str, id: &str) -> Result<(), ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::DeleteTask);
        if let Some(e) = s.next_fault(Method::DeleteTask) {
            return Err(e);
        }
        if !s.lists.iter().any(|l| l.id == list_id) {
            return Err(ApiError::NotFound);
        }
        let before = s.tasks.len();
        s.tasks.retain(|(_, t)| t.id != id);
        if s.tasks.len() == before {
            return Err(ApiError::NotFound);
        }
        // Live-API behavior: deleting a parent deletes its descendants too.
        loop {
            let alive: std::collections::HashSet<String> =
                s.tasks.iter().map(|(_, t)| t.id.clone()).collect();
            let n = s.tasks.len();
            s.tasks
                .retain(|(_, t)| t.parent.as_deref().is_none_or(|p| alive.contains(p)));
            if s.tasks.len() == n {
                break;
            }
        }
        Ok(())
    }

    async fn move_task(
        &self,
        list_id: &str,
        id: &str,
        parent: Option<&str>,
        previous: Option<&str>,
    ) -> Result<Task, ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::MoveTask);
        if let Some(e) = s.next_fault(Method::MoveTask) {
            return Err(e);
        }
        if !s.lists.iter().any(|l| l.id == list_id) {
            return Err(ApiError::NotFound);
        }
        let new_etag = s.fresh_etag();
        let Some((_, t)) = s.tasks.iter_mut().find(|(_, t)| t.id == id) else {
            // Live-API behavior: an unknown task id in a move is a permanent
            // 400 "Invalid task ID" (verified live), NOT a 404.
            return Err(ApiError::Other("400: Invalid task ID".into()));
        };
        t.parent = parent.map(String::from);
        t.position = match previous {
            Some(p) => format!("after-{p}"),
            None => "00000000000001".into(),
        };
        t.etag = Some(new_etag);
        Ok(t.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn seeded_lists_are_returned() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let lists = c.list_tasklists().await.unwrap();
        assert_eq!(lists.len(), 1);
        assert_eq!(lists[0].title, "Inbox");
    }

    #[tokio::test]
    async fn insert_then_patch_changes_etag() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let inserted = c
            .insert_task(
                "L1",
                NewTask {
                    title: "foo".into(),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        let before_etag = inserted.etag.clone().unwrap();
        let patched = c
            .patch_task(
                "L1",
                &inserted.id,
                TaskPatch {
                    title: Some("bar".into()),
                    ..Default::default()
                },
                Some(&before_etag),
            )
            .await
            .unwrap();
        assert_eq!(patched.title, "bar");
        assert_ne!(patched.etag, Some(before_etag));
    }

    #[tokio::test]
    async fn stale_etag_returns_precondition_failed() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let t = c
            .insert_task(
                "L1",
                NewTask {
                    title: "x".into(),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        let err = c
            .patch_task(
                "L1",
                &t.id,
                TaskPatch {
                    title: Some("y".into()),
                    ..Default::default()
                },
                Some("wrong-etag"),
            )
            .await
            .unwrap_err();
        assert!(matches!(err, ApiError::PreconditionFailed));
    }

    #[tokio::test]
    async fn fail_next_injects_one_error() {
        let c = InMemoryClient::new();
        c.fail_next(Method::ListTaskLists, || ApiError::Server { status: 503 });
        let err = c.list_tasklists().await.unwrap_err();
        assert!(matches!(err, ApiError::Server { status: 503 }));
        // Second call succeeds.
        assert!(c.list_tasklists().await.is_ok());
    }

    #[tokio::test]
    async fn call_count_tracks_each_method() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.list_tasklists().await.unwrap();
        c.list_tasklists().await.unwrap();
        assert_eq!(c.call_count(Method::ListTaskLists), 2);
        assert_eq!(c.call_count(Method::InsertTask), 0);
    }

    #[tokio::test]
    async fn delete_then_patch_returns_not_found() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let t = c.seed_task("L1", "T1", "first", "00000000000001");
        c.delete_task("L1", &t.id).await.unwrap();
        let err = c
            .patch_task(
                "L1",
                &t.id,
                TaskPatch {
                    title: Some("nope".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap_err();
        assert!(matches!(err, ApiError::NotFound));
    }

    #[tokio::test]
    async fn move_task_updates_parent_and_position() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "T1", "parent", "00000000000001");
        c.seed_task("L1", "T2", "child", "00000000000002");
        let moved = c.move_task("L1", "T2", Some("T1"), None).await.unwrap();
        assert_eq!(moved.parent.as_deref(), Some("T1"));
        assert_eq!(moved.position, "00000000000001");
    }

    #[tokio::test]
    async fn move_task_with_previous_sets_position() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "T1", "first", "00000000000001");
        c.seed_task("L1", "T2", "second", "00000000000002");
        let moved = c.move_task("L1", "T2", None, Some("T1")).await.unwrap();
        assert_eq!(moved.position, "after-T1");
        assert!(moved.parent.is_none());
    }

    #[tokio::test]
    async fn move_task_unknown_id_is_permanent_400() {
        // Live-API behavior: moving an unknown id is 400 "Invalid task ID",
        // not 404 — a non-transient rejection.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let err = c.move_task("L1", "nope", None, None).await.unwrap_err();
        assert!(matches!(err, ApiError::Other(_)));
        assert!(!err.is_transient());
    }

    #[tokio::test]
    async fn completing_a_parent_completes_its_subtree_server_side() {
        // Live-API behavior (verified via the throwaway account): completing a
        // parent auto-completes its descendants server-side, each with a fresh
        // etag. The fake must mirror this or the sync engine's cascade logic is
        // tested against a fiction.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let p = c.seed_task("L1", "P", "parent", "1");
        c.seed_task_with_parent("L1", "C1", "kid", "2", Some("P"));
        c.seed_task_with_parent("L1", "C2", "grandkid", "3", Some("C1"));

        c.patch_task(
            "L1",
            &p.id,
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            p.etag.as_deref(),
        )
        .await
        .unwrap();

        let all = c.list_tasks("L1", None).await.unwrap().items;
        assert!(
            all.iter().all(|t| t.status == TaskStatus::Completed),
            "parent and every descendant are completed"
        );
        assert!(
            all.iter()
                .all(|t| t.completed.as_deref() == Some("2026-01-01T00:00:00Z")),
            "each cascaded task carries a completed timestamp"
        );
    }

    #[tokio::test]
    async fn reopening_a_child_of_a_completed_parent_is_silently_ignored() {
        // Live-API behavior: patching a subtask back to needsAction while its
        // parent is still completed returns 200 but is a no-op server-side.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let p = c.seed_task("L1", "P", "parent", "1");
        c.seed_task_with_parent("L1", "C1", "kid", "2", Some("P"));

        c.patch_task(
            "L1",
            &p.id,
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            p.etag.as_deref(),
        )
        .await
        .unwrap();

        // Try to reopen the child while the parent stays completed → 200, no-op.
        let child = c.get_task("L1", "C1").await.unwrap();
        let resp = c
            .patch_task(
                "L1",
                "C1",
                TaskPatch {
                    status: Some(TaskStatus::NeedsAction),
                    ..Default::default()
                },
                child.etag.as_deref(),
            )
            .await
            .unwrap();
        assert_eq!(
            resp.status,
            TaskStatus::Completed,
            "reopen of a completed parent's child is silently ignored"
        );
        let refetched = c.get_task("L1", "C1").await.unwrap();
        assert_eq!(refetched.status, TaskStatus::Completed);
    }

    #[tokio::test]
    async fn reopening_a_parent_does_not_reopen_its_children() {
        // Live-API behavior: un-completing a parent leaves its children done.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let p = c.seed_task("L1", "P", "parent", "1");
        c.seed_task_with_parent("L1", "C1", "kid", "2", Some("P"));
        c.patch_task(
            "L1",
            &p.id,
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            p.etag.as_deref(),
        )
        .await
        .unwrap();

        let parent = c.get_task("L1", "P").await.unwrap();
        c.patch_task(
            "L1",
            "P",
            TaskPatch {
                status: Some(TaskStatus::NeedsAction),
                ..Default::default()
            },
            parent.etag.as_deref(),
        )
        .await
        .unwrap();

        assert_eq!(
            c.get_task("L1", "P").await.unwrap().status,
            TaskStatus::NeedsAction
        );
        assert_eq!(
            c.get_task("L1", "C1").await.unwrap().status,
            TaskStatus::Completed,
            "child stays completed after the parent reopens"
        );
    }

    #[tokio::test]
    async fn insert_to_nonexistent_list_returns_not_found() {
        let c = InMemoryClient::new();
        let err = c
            .insert_task(
                "no-list",
                NewTask {
                    title: "x".into(),
                    ..Default::default()
                },
            )
            .await
            .unwrap_err();
        assert!(matches!(err, ApiError::NotFound));
    }

    #[tokio::test]
    async fn patch_without_etag_always_succeeds() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let t = c.seed_task("L1", "T1", "orig", "1");
        let patched = c
            .patch_task(
                "L1",
                &t.id,
                TaskPatch {
                    title: Some("new".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap();
        assert_eq!(patched.title, "new");
    }
}
