//! Deterministic in-memory implementation of [`GoogleTasksClient`].
//!
//! Used as a test double for the sync engine and command handlers. Etags are
//! a monotonic counter so conflict scenarios are deterministic. Faults can be
//! queued via [`InMemoryClient::fail_next`] (untargeted, FIFO per method),
//! [`InMemoryClient::fail_next_for_id`] (a single-task method against one id),
//! or [`InMemoryClient::fail_list_tasks_page`] (a specific `list_tasks` page).
//!
//! `list_tasks` mirrors the live API's pagination and ordering: it returns a
//! list's tasks sorted by their opaque lexicographic `position` string, and
//! [`InMemoryClient::set_page_size`] splits the result into pages with real
//! `next_page_token`s so multi-page scroll + resume can be exercised. `move`
//! and `insert` share one positioning rule, so a moved task sorts into its
//! requested slot on the next `list_tasks`.
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
//! - a `move` issues a fresh etag, and does NOT cap nesting depth.
//! - a `move` naming a `previous` that no longer exists is a **404** — unlike
//!   an unknown SUBJECT id, which is a 400.
//! - a `move` naming a `parent` that no longer exists is a permanent 400, the
//!   same rule `insert` applies to the same field. The exact live status for
//!   this one case was NOT probed separately (probe 2 covered `previous` and
//!   the subject id); what matters is that it is a permanent rejection, since
//!   Google's cascade means it can only ever be reached by racing a delete.
//!   Modelling it as success let the fake hold a task whose parent it did not
//!   have — a state the real service cannot be in, and one our pull re-detaches
//!   on every run, so sync never settles (found by the §J suite, #113).
//! - attaching an open task to a **completed** parent (by `insert` with a
//!   `parent`, or by `move`) completes it: the response body itself already
//!   carries `status: completed`, and the cascade reaches the attached
//!   subtree.
//! - inserting a child does NOT bump the parent's etag, so a complete pushed
//!   with a pre-child etag lands and the cascade takes children the client
//!   never pulled.
//!
//! Known, deliberate divergences from the live API (recorded so nobody
//! "fixes" the fake into a fiction — see RFC-009 §"Probes"):
//! - **Soft delete.** Google soft-deletes: after `DELETE`, a direct `GET` by
//!   id still returns 200 with `deleted: true`, the row vanishes from
//!   `tasks.list`, and a later `PATCH` returns 200 but is silently ignored
//!   (the row stays deleted). The fake hard-removes instead, so `get`/`patch`
//!   answer 404. The observable-through-a-pull behavior — the row disappears
//!   from `list_tasks` and no write revives it — is identical; only the
//!   by-id status differs. Tracked for the engine's §B×deleted row.
//! - **`DELETE` honors `If-Match`** live (stale etag → 412, task survives;
//!   current etag → 204). `HttpClient::delete_task` deliberately sends none,
//!   making our deletes unconditional (RFC-009 P4, "delete wins"), and the
//!   trait has no etag parameter — so the fake has none either.

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

/// What a targeted fault is scoped to. `Id` matches a single-task method
/// (`get`/`patch`/`delete`/`move`) invoked against that task id; `Page` matches
/// a specific `list_tasks` page (0-based) so a fault can be injected mid-scroll.
#[derive(Debug, Clone, PartialEq, Eq)]
enum FaultTarget {
    Id(String),
    Page(usize),
}

/// A fault scoped to a specific target, fired the first time a matching call is
/// made and removed on fire. Order-independent (unlike the untargeted queue) so
/// a test can arm "fail patch of T2" without caring what else is patched first.
#[derive(Debug, Clone)]
struct TargetedFault {
    method: Method,
    target: FaultTarget,
    err: fn() -> ApiError,
}

#[derive(Debug, Default)]
struct State {
    lists: Vec<TaskList>,
    tasks: Vec<(String, Task)>, // (list_id, task)
    etag_counter: u64,
    faults: VecDeque<(Method, fn() -> ApiError)>,
    /// Faults scoped to a specific task id or `list_tasks` page.
    targeted_faults: Vec<TargetedFault>,
    /// `list_tasks` page size. `None` returns the whole list in one page (the
    /// historic behavior); `Some(n)` splits it into `n`-item pages with real
    /// `next_page_token`s so multi-page scroll + resume can be exercised.
    page_size: Option<usize>,
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

    /// Fire and consume a targeted fault whose method and target match, if any.
    fn next_targeted_fault(&mut self, m: Method, target: &FaultTarget) -> Option<ApiError> {
        let idx = self
            .targeted_faults
            .iter()
            .position(|f| f.method == m && &f.target == target)?;
        Some((self.targeted_faults.remove(idx).err)())
    }

    fn record(&mut self, m: Method) {
        self.calls[m as usize] += 1;
    }

    /// Compute the opaque, lexicographically-sortable `position` for a task
    /// placed after `previous` among its siblings — the same rule the live API
    /// applies for both `insert` and `move`. With `previous`, we append `'+'`
    /// (0x2B, below every digit) to the anchor's position, which sorts strictly
    /// after the anchor and before the anchor's original successor (whose
    /// position starts with a digit). With no `previous`, the task goes to the
    /// very top: `'!'` (0x21) sorts before any digit, and a descending counter
    /// keeps successive top inserts above one another. Call `fresh_etag` first
    /// so the counter has advanced.
    fn position_after(&self, previous: Option<&str>) -> Result<String, ApiError> {
        match previous {
            Some(prev) => match self.tasks.iter().find(|(_, t)| t.id == prev) {
                Some((_, p)) => Ok(format!("{}+", p.position)),
                // Live-API behavior: a `previous` that does not exist is a
                // 404 "Previous task id not found" — note the asymmetry with an
                // unknown SUBJECT id, which is a 400. Verified live.
                None => Err(ApiError::NotFound),
            },
            None => Ok(format!("!{:019}", u64::MAX - self.etag_counter)),
        }
    }

    /// Is `id` a task the server currently considers completed?
    fn is_completed(&self, id: &str) -> bool {
        self.tasks
            .iter()
            .any(|(_, t)| t.id == id && t.status == TaskStatus::Completed)
    }

    /// Complete every descendant of `root` (excluding `root` itself), each
    /// getting a fresh etag and a `completed` stamp — the live API's cascade.
    fn cascade_complete_descendants(&mut self, root: &str) {
        let mut subtree: std::collections::HashSet<String> =
            std::collections::HashSet::from([root.to_string()]);
        loop {
            let n = subtree.len();
            let more: Vec<String> = self
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
        let to_complete: Vec<String> = self
            .tasks
            .iter()
            .filter(|(_, t)| {
                t.id != root && subtree.contains(&t.id) && t.status != TaskStatus::Completed
            })
            .map(|(_, t)| t.id.clone())
            .collect();
        for cid in to_complete {
            let e = self.fresh_etag();
            if let Some((_, t)) = self.tasks.iter_mut().find(|(_, t)| t.id == cid) {
                t.status = TaskStatus::Completed;
                t.completed = Some("2026-01-01T00:00:00Z".into());
                t.etag = Some(e);
            }
        }
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

    /// Schedule a fault that fires only when `m` (`get`/`patch`/`delete`/`move`)
    /// is invoked against `id`. Order-independent: unrelated tasks touched first
    /// pass through untouched. Consumed on the first matching call.
    pub fn fail_next_for_id(&self, m: Method, id: &str, err: fn() -> ApiError) {
        self.inner
            .lock()
            .unwrap()
            .targeted_faults
            .push(TargetedFault {
                method: m,
                target: FaultTarget::Id(id.into()),
                err,
            });
    }

    /// Schedule a fault that fires only when `list_tasks` is called for the
    /// given 0-based page. Models a network drop partway through a paged scroll.
    pub fn fail_list_tasks_page(&self, page: usize, err: fn() -> ApiError) {
        self.inner
            .lock()
            .unwrap()
            .targeted_faults
            .push(TargetedFault {
                method: Method::ListTasks,
                target: FaultTarget::Page(page),
                err,
            });
    }

    /// Split `list_tasks` responses into pages of at most `size` items, with a
    /// real `next_page_token` between them. Default (unset) returns everything
    /// in a single page.
    pub fn set_page_size(&self, size: usize) {
        self.inner.lock().unwrap().page_size = Some(size);
    }

    /// Make the next `insert_task` commit the task server-side but return a
    /// network error — models a response timeout after the server committed.
    pub fn commit_then_fail_next_insert(&self) {
        self.inner.lock().unwrap().commit_then_fail_insert = true;
    }

    /// Disarm every queued fault — untargeted, targeted, and the pending
    /// commit-then-fail insert. Lets a test switch from a chaotic phase to a
    /// provably healthy one: an armed-but-never-fired fault would otherwise
    /// still be waiting in the queue and fire during the recovery phase.
    pub fn clear_faults(&self) {
        let mut s = self.inner.lock().unwrap();
        s.faults.clear();
        s.targeted_faults.clear();
        s.commit_then_fail_insert = false;
    }

    /// Remove a task from internal state (simulates server-side deletion by another client).
    pub fn delete_task_from_state(&self, list_id: &str, task_id: &str) {
        let mut s = self.inner.lock().unwrap();
        s.tasks
            .retain(|(lid, t)| !(lid == list_id && t.id == task_id));
    }

    /// Remove a list (and its tasks) from internal state, simulating a list
    /// deleted server-side by another client. Single-task/list methods against
    /// it then naturally return [`ApiError::NotFound`], and a pull will not
    /// resurrect it.
    pub fn delete_list_from_state(&self, list_id: &str) {
        let mut s = self.inner.lock().unwrap();
        s.lists.retain(|l| l.id != list_id);
        s.tasks.retain(|(lid, _)| lid != list_id);
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
        page_token: Option<&str>,
    ) -> Result<Page<Task>, ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::ListTasks);
        // Decode the page cursor first — it identifies which page a per-page
        // fault targets. Tokens are our own opaque `page-N` strings; anything
        // else is a client bug the live API would reject with a 400.
        let page_index = match page_token {
            None => 0,
            Some(tok) => match tok
                .strip_prefix("page-")
                .and_then(|n| n.parse::<usize>().ok())
            {
                Some(i) => i,
                None => return Err(ApiError::Other("400: Invalid page token".into())),
            },
        };
        if let Some(e) = s.next_fault(Method::ListTasks) {
            return Err(e);
        }
        if let Some(e) = s.next_targeted_fault(Method::ListTasks, &FaultTarget::Page(page_index)) {
            return Err(e);
        }
        // Google returns a list's tasks ordered by their opaque, lexicographic
        // `position` string; mirror that so ordering tests see a real order.
        let mut items: Vec<Task> = s
            .tasks
            .iter()
            .filter(|(lid, _)| lid == list_id)
            .map(|(_, t)| t.clone())
            .collect();
        items.sort_by(|a, b| a.position.cmp(&b.position));

        let page_size = s.page_size.unwrap_or(items.len().max(1));
        let start = page_index.saturating_mul(page_size);
        let end = start.saturating_add(page_size).min(items.len());
        let page_items = if start < items.len() {
            items[start..end].to_vec()
        } else {
            Vec::new()
        };
        let next_page_token = if end < items.len() {
            Some(format!("page-{}", page_index + 1))
        } else {
            None
        };
        Ok(Page {
            items: page_items,
            next_page_token,
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
        // Live-API rule: a task inserted under a COMPLETED parent is completed
        // by the server's cascade immediately — the insert RESPONSE already
        // carries status=completed. Verified live (RFC-009 probe 5).
        let parent_completed = new.parent.as_deref().is_some_and(|p| s.is_completed(p));
        let etag = s.fresh_etag();
        // Live-API positioning: with `previous`, insert right after it; with
        // none, insert FIRST. See `State::position_after`.
        let position = s.position_after(new.previous.as_deref())?;
        let id = format!("remote-{}", s.etag_counter);
        let web_view_link = Some(format!("https://tasks.google.com/task/{id}"));
        let status = if parent_completed {
            TaskStatus::Completed
        } else {
            new.status.unwrap_or(TaskStatus::NeedsAction)
        };
        let task = Task {
            id,
            parent: new.parent,
            position,
            title: new.title,
            notes: new.notes,
            status,
            due,
            completed: if status == TaskStatus::Completed {
                Some("2026-01-01T00:00:00Z".into())
            } else {
                None
            },
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
        if let Some(e) = s.next_targeted_fault(Method::GetTask, &FaultTarget::Id(id.into())) {
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
        if let Some(e) = s.next_targeted_fault(Method::PatchTask, &FaultTarget::Id(id.into())) {
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
            s.cascade_complete_descendants(&result.id);
        }
        Ok(result)
    }

    async fn delete_task(&self, list_id: &str, id: &str) -> Result<(), ApiError> {
        let mut s = self.inner.lock().unwrap();
        s.record(Method::DeleteTask);
        if let Some(e) = s.next_fault(Method::DeleteTask) {
            return Err(e);
        }
        if let Some(e) = s.next_targeted_fault(Method::DeleteTask, &FaultTarget::Id(id.into())) {
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
        if let Some(e) = s.next_targeted_fault(Method::MoveTask, &FaultTarget::Id(id.into())) {
            return Err(e);
        }
        if !s.lists.iter().any(|l| l.id == list_id) {
            return Err(ApiError::NotFound);
        }
        if !s.tasks.iter().any(|(_, t)| t.id == id) {
            // Live-API behavior: an unknown task id in a move is a permanent
            // 400 "Invalid task ID" (verified live), NOT a 404.
            return Err(ApiError::Other("400: Invalid task ID".into()));
        }
        // Same strictness `insert_task` already applies to the same field: an
        // unknown parent id is a permanent 400. Without it the fake happily
        // parents a task onto a task it does not have, producing a server
        // state Google cannot be in (its deletes cascade) — and our pull then
        // detaches that row on every single run, so sync never settles. Found
        // by the §J property suite (#113). NOTE: probe 2 verified the statuses
        // for an unknown `previous` (404) and an unknown SUBJECT id (400); the
        // status for an unknown `parent` on a MOVE was not probed separately,
        // so this reuses insert's verified rule for the same field. The engine
        // treats every permanent rejection the same way, so the choice between
        // 400 and 404 changes nothing it does.
        if let Some(p) = parent
            && !s.tasks.iter().any(|(_, t)| t.id == p)
        {
            return Err(ApiError::Other("400: Invalid task ID (parent)".into()));
        }
        let new_etag = s.fresh_etag();
        // Real lexicographic placement: derive a `position` that sorts the task
        // into the requested slot among its siblings, exactly like `insert`.
        // An unknown `previous` is a 404 (same as the live API).
        let position = s.position_after(previous)?;
        // Live-API rule: moving an open task under a COMPLETED parent is
        // accepted, and the parent's completion cascade takes the newly
        // attached task (and its subtree) — the move RESPONSE already shows it
        // completed. Verified live (RFC-009 probe 4).
        let dest_completed = parent.is_some_and(|p| s.is_completed(p));
        let t = s.tasks.iter_mut().find(|(_, t)| t.id == id).map(|(_, t)| t);
        let t = t.expect("presence checked above");
        t.parent = parent.map(String::from);
        t.position = position;
        t.etag = Some(new_etag);
        if dest_completed && t.status != TaskStatus::Completed {
            t.status = TaskStatus::Completed;
            t.completed = Some("2026-01-01T00:00:00Z".into());
        }
        let result = t.clone();
        if dest_completed {
            s.cascade_complete_descendants(&result.id);
        }
        Ok(result)
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
    async fn move_task_rejects_an_unknown_parent() {
        // The same strictness `insert_task` applies to the same field. Without
        // it the fake can hold a task whose parent it does not have — a state
        // Google cannot be in, and one our pull re-detaches on every run.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "T1", "child", "00000000000001");
        let err = c
            .move_task("L1", "T1", Some("gone"), None)
            .await
            .expect_err("an unknown parent is a permanent rejection");
        assert!(!err.is_transient(), "and it must not be retried forever");
        let after = c.list_tasks("L1", None).await.unwrap().items;
        assert_eq!(
            after[0].parent, None,
            "the rejected move left the task where it was"
        );
    }

    #[tokio::test]
    async fn move_task_updates_parent_and_position() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "T1", "parent", "00000000000001");
        c.seed_task("L1", "T2", "child", "00000000000002");
        let moved = c.move_task("L1", "T2", Some("T1"), None).await.unwrap();
        assert_eq!(moved.parent.as_deref(), Some("T1"));
        // No `previous` → placed at the top of its siblings; `'!'` sorts below
        // every digit-led seeded position.
        assert!(
            moved.position.as_str() < "00000000000001",
            "top slot sorts before existing positions, got {}",
            moved.position
        );
    }

    #[tokio::test]
    async fn move_task_with_previous_sets_position() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "T1", "first", "00000000000001");
        c.seed_task("L1", "T2", "second", "00000000000002");
        let moved = c.move_task("L1", "T2", None, Some("T1")).await.unwrap();
        // Placed immediately after T1: sorts after T1 and before T2's original slot.
        assert!(moved.position.as_str() > "00000000000001");
        assert!(moved.position.as_str() < "00000000000002");
        assert!(moved.parent.is_none());
    }

    #[tokio::test]
    async fn move_with_an_unknown_previous_sibling_is_not_found() {
        // Live-API behavior (RFC-009 probe 2, verified via `live_api_probe`):
        // a move naming a `previous` that no longer exists answers
        // 404 "Previous task id not found" — NOT the 400 that an unknown
        // SUBJECT id draws. The asymmetry matters: a move 404 does not imply
        // "the task I am moving is gone".
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "T1", "only", "00000000000001");
        let err = c
            .move_task("L1", "T1", None, Some("ghost"))
            .await
            .unwrap_err();
        assert!(matches!(err, ApiError::NotFound), "got {err:?}");
        assert!(!err.is_transient());
    }

    #[tokio::test]
    async fn move_bumps_the_task_etag() {
        // RFC-009 probe 1: a move DOES issue a fresh etag, so a concurrent
        // local content edit 412s on a row whose content never changed.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let anchor = c.seed_task("L1", "A", "anchor", "00000000000001");
        let subject = c.seed_task("L1", "B", "subject", "00000000000002");
        let moved = c
            .move_task("L1", &subject.id, None, Some(&anchor.id))
            .await
            .unwrap();
        assert!(moved.etag.is_some());
        assert_ne!(
            moved.etag, subject.etag,
            "a move must issue a fresh etag, like the live API"
        );
    }

    #[tokio::test]
    async fn move_creating_a_third_level_is_accepted() {
        // RFC-009 probe 3: the API does NOT cap nesting depth — a move under a
        // task that already has a parent succeeds. Our app self-limits to one
        // level of subtasks; the server does not enforce it for us, so the fake
        // must not either (or the engine is tested against a fiction).
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "L1T", "level-1", "00000000000001");
        c.seed_task_with_parent("L1", "L2T", "level-2", "00000000000002", Some("L1T"));
        c.seed_task("L1", "X", "to-demote", "00000000000003");
        let moved = c.move_task("L1", "X", Some("L2T"), None).await.unwrap();
        assert_eq!(moved.parent.as_deref(), Some("L2T"));
    }

    #[tokio::test]
    async fn moving_an_open_task_under_a_completed_parent_completes_it() {
        // RFC-009 probe 4: the move is accepted (200) and the parent's
        // completion cascade takes the newly attached child.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let p = c.seed_task("L1", "P", "done-parent", "00000000000001");
        c.patch_task(
            "L1",
            "P",
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            p.etag.as_deref(),
        )
        .await
        .unwrap();
        c.seed_task("L1", "X", "open-task", "00000000000002");

        let moved = c.move_task("L1", "X", Some("P"), None).await.unwrap();
        assert_eq!(moved.parent.as_deref(), Some("P"));
        assert_eq!(
            moved.status,
            TaskStatus::Completed,
            "the move response already shows the cascaded completion"
        );
        let refetched = c.get_task("L1", "X").await.unwrap();
        assert_eq!(refetched.status, TaskStatus::Completed);
        assert!(refetched.completed.is_some(), "carries a completed stamp");
    }

    #[tokio::test]
    async fn moving_a_task_under_an_open_parent_leaves_it_open() {
        // The non-happy-path guard for the row above: the cascade must key off
        // the DESTINATION parent's status, not fire on every reparent.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "P", "open-parent", "00000000000001");
        c.seed_task("L1", "X", "open-task", "00000000000002");
        let moved = c.move_task("L1", "X", Some("P"), None).await.unwrap();
        assert_eq!(moved.status, TaskStatus::NeedsAction);
        assert!(moved.completed.is_none());
    }

    #[tokio::test]
    async fn inserting_a_subtask_under_a_completed_parent_returns_it_completed() {
        // RFC-009 probe 5: the insert is accepted, and the child comes back
        // ALREADY completed — in the insert response itself, so a client that
        // adopts the response body converges immediately.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let p = c.seed_task("L1", "P", "done-parent", "00000000000001");
        c.patch_task(
            "L1",
            "P",
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            p.etag.as_deref(),
        )
        .await
        .unwrap();

        let child = c
            .insert_task(
                "L1",
                NewTask {
                    title: "new-subtask".into(),
                    parent: Some("P".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(
            child.status,
            TaskStatus::Completed,
            "insert response already carries the cascaded completion"
        );
        assert!(child.completed.is_some());
        assert_eq!(
            c.get_task("L1", &child.id).await.unwrap().status,
            TaskStatus::Completed
        );
    }

    #[tokio::test]
    async fn inserting_a_child_does_not_change_the_parents_etag() {
        // RFC-009 probe 6, first half: another client adding a subtask does not
        // stale our copy of the parent — so a local complete does not spuriously
        // 412 on a parent we never edited.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let p = c.seed_task("L1", "P", "parent", "00000000000001");
        c.insert_task(
            "L1",
            NewTask {
                title: "late-child".into(),
                parent: Some("P".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(
            c.get_task("L1", "P").await.unwrap().etag,
            p.etag,
            "a child insert must leave the parent's etag alone"
        );
    }

    #[tokio::test]
    async fn completing_a_parent_cascades_to_a_child_we_never_pulled() {
        // RFC-009 probe 6, second half: the server cascade covers children the
        // client has never seen, and completing with the pre-child etag lands.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let p = c.seed_task("L1", "P", "parent", "00000000000001");
        let snapshot_etag = p.etag.clone();
        let unseen = c
            .insert_task(
                "L1",
                NewTask {
                    title: "unseen-child".into(),
                    parent: Some("P".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();

        c.patch_task(
            "L1",
            "P",
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            snapshot_etag.as_deref(),
        )
        .await
        .expect("completing with the pre-child etag must not 412");

        assert_eq!(
            c.get_task("L1", &unseen.id).await.unwrap().status,
            TaskStatus::Completed,
            "the cascade takes a child the client never pulled"
        );
    }

    #[tokio::test]
    async fn list_tasks_returns_position_order_not_insertion_order() {
        // Seed out of position order; list_tasks must sort by position.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "T-c", "third", "00000000000003");
        c.seed_task("L1", "T-a", "first", "00000000000001");
        c.seed_task("L1", "T-b", "second", "00000000000002");
        let ids: Vec<String> = c
            .list_tasks("L1", None)
            .await
            .unwrap()
            .items
            .into_iter()
            .map(|t| t.id)
            .collect();
        assert_eq!(ids, vec!["T-a", "T-b", "T-c"]);
    }

    #[tokio::test]
    async fn move_reorders_task_in_subsequent_list() {
        // A real lexicographic move must change where the task appears on the
        // NEXT list_tasks, not just stamp an opaque field.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "A", "a", "00000000000001");
        c.seed_task("L1", "B", "b", "00000000000002");
        c.seed_task("L1", "C", "c", "00000000000003");
        // Move C to sit right after A → order becomes A, C, B.
        c.move_task("L1", "C", None, Some("A")).await.unwrap();
        let ids: Vec<String> = c
            .list_tasks("L1", None)
            .await
            .unwrap()
            .items
            .into_iter()
            .map(|t| t.id)
            .collect();
        assert_eq!(ids, vec!["A", "C", "B"]);
    }

    #[tokio::test]
    async fn list_tasks_paginates_with_real_tokens() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        for i in 1..=5 {
            c.seed_task("L1", &format!("T{i}"), "t", &format!("{i:014}"));
        }
        c.set_page_size(2);

        let p0 = c.list_tasks("L1", None).await.unwrap();
        assert_eq!(p0.items.len(), 2);
        let tok0 = p0.next_page_token.expect("more pages after page 0");

        let p1 = c.list_tasks("L1", Some(&tok0)).await.unwrap();
        assert_eq!(p1.items.len(), 2);
        let tok1 = p1.next_page_token.expect("more pages after page 1");

        let p2 = c.list_tasks("L1", Some(&tok1)).await.unwrap();
        assert_eq!(p2.items.len(), 1);
        assert!(p2.next_page_token.is_none(), "last page has no token");

        // Pages concatenate to the full list, in position order, no dupes.
        let mut ids: Vec<String> = p0
            .items
            .into_iter()
            .chain(p1.items)
            .chain(p2.items)
            .map(|t| t.id)
            .collect();
        assert_eq!(ids, vec!["T1", "T2", "T3", "T4", "T5"]);
        ids.dedup();
        assert_eq!(ids.len(), 5, "no task appears on two pages");
    }

    #[tokio::test]
    async fn fail_list_tasks_page_targets_one_page_only() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        for i in 1..=4 {
            c.seed_task("L1", &format!("T{i}"), "t", &format!("{i:014}"));
        }
        c.set_page_size(2);
        // Drop the network on the SECOND page (index 1); page 0 must still load.
        c.fail_list_tasks_page(1, || ApiError::Server { status: 503 });

        let p0 = c.list_tasks("L1", None).await.unwrap();
        let tok0 = p0.next_page_token.unwrap();
        let err = c.list_tasks("L1", Some(&tok0)).await.unwrap_err();
        assert!(matches!(err, ApiError::Server { status: 503 }));
        // The fault is consumed: a retry of page 1 now succeeds.
        assert!(c.list_tasks("L1", Some(&tok0)).await.is_ok());
    }

    #[tokio::test]
    async fn fail_next_for_id_targets_only_that_task() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "T1", "one", "00000000000001");
        c.seed_task("L1", "T2", "two", "00000000000002");
        // Arm a fault for patching T2; patching T1 first must pass through.
        c.fail_next_for_id(Method::PatchTask, "T2", || ApiError::Server { status: 500 });

        let ok = c
            .patch_task(
                "L1",
                "T1",
                TaskPatch {
                    title: Some("edited".into()),
                    ..Default::default()
                },
                None,
            )
            .await;
        assert!(ok.is_ok(), "unrelated task is unaffected by the id fault");

        let err = c
            .patch_task(
                "L1",
                "T2",
                TaskPatch {
                    title: Some("edited".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .unwrap_err();
        assert!(matches!(err, ApiError::Server { status: 500 }));
        // Consumed on fire: the next patch of T2 succeeds.
        assert!(
            c.patch_task(
                "L1",
                "T2",
                TaskPatch {
                    title: Some("again".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .is_ok()
        );
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
