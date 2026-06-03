//! Deterministic in-memory implementation of [`GoogleTasksClient`].
//!
//! Used as a test double for the sync engine and command handlers. Etags are
//! a monotonic counter so conflict scenarios are deterministic. Faults can
//! be queued via [`InMemoryClient::fail_next`].

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
    /// `list_tasks`
    ListTasks,
    /// `insert_task`
    InsertTask,
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
    calls: [u32; 6],
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
        };
        s.tasks.push((list_id.into(), task.clone()));
        task
    }

    /// Schedule a fault to be returned by the next call to `m`.
    pub fn fail_next(&self, m: Method, err: fn() -> ApiError) {
        self.inner.lock().unwrap().faults.push_back((m, err));
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
        let etag = s.fresh_etag();
        let position = format!("{:020}", s.tasks.len() + 1);
        let id = format!("remote-{}", s.etag_counter);
        let task = Task {
            id,
            parent: new.parent,
            position,
            title: new.title,
            notes: new.notes,
            status: new.status.unwrap_or(TaskStatus::NeedsAction),
            due: new.due,
            completed: None,
            etag: Some(etag),
            updated: "2026-01-01T00:00:00Z".into(),
        };
        s.tasks.push((list_id.into(), task.clone()));
        let _ = new.previous;
        Ok(task)
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
        let Some((_, t)) = s.tasks.iter_mut().find(|(_, t)| t.id == id) else {
            return Err(ApiError::NotFound);
        };
        if let Some(want) = etag
            && t.etag.as_deref() != Some(want)
        {
            return Err(ApiError::PreconditionFailed);
        }
        if let Some(title) = patch.title {
            t.title = title;
        }
        if let Some(notes) = patch.notes {
            t.notes = if notes.is_empty() { None } else { Some(notes) };
        }
        if let Some(due) = patch.due {
            t.due = if due.is_empty() { None } else { Some(due) };
        }
        if let Some(status) = patch.status {
            t.status = status;
            t.completed = if status == TaskStatus::Completed {
                Some("2026-01-01T00:00:00Z".into())
            } else {
                None
            };
        }
        t.etag = Some(new_etag);
        Ok(t.clone())
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
            return Err(ApiError::NotFound);
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
    async fn move_task_not_found() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let err = c.move_task("L1", "nope", None, None).await.unwrap_err();
        assert!(matches!(err, ApiError::NotFound));
    }

    #[tokio::test]
    async fn insert_to_nonexistent_list_returns_not_found() {
        let c = InMemoryClient::new();
        let err = c
            .insert_task("no-list", NewTask { title: "x".into(), ..Default::default() })
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
            .patch_task("L1", &t.id, TaskPatch { title: Some("new".into()), ..Default::default() }, None)
            .await
            .unwrap();
        assert_eq!(patched.title, "new");
    }
}
