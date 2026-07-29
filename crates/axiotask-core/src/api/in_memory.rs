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
//! - `title` over 1024 characters, or `notes` over 8192 characters, is a
//!   permanent 400 ("invalid argument") on both insert and patch — the same
//!   permanent-rejection shape a bare `due` draws, so an oversize edit drives
//!   the engine's forever-`Reject` push path (#146). Google counts characters,
//!   not bytes. Limits are from the Google Tasks docs, verified 2026-07-28.
//! - deleting a parent task deletes its descendants server-side.
//! - completing a parent task auto-completes its whole subtree server-side,
//!   and re-opening a subtask whose parent is still completed returns 200 but
//!   is silently ignored (the subtask stays completed). Re-opening the parent
//!   does NOT reopen its children. All verified against the live service; see
//!   the `live_api_probe` example for the reproducible probe harness.
//! - a `move` issues a fresh etag, and does NOT cap nesting depth.
//! - a `move` naming a `previous` that no longer exists is a **404** — unlike
//!   an unknown SUBJECT id, which is a 400.
//! - a `move` naming a `parent` that no longer exists is modeled as a permanent
//!   400, the same rule `insert` applies to the same field. Probe round 2c
//!   (#114) was added to pin the exact live status (400 vs 404) for both an
//!   unknown and a soft-deleted parent; either way it is a permanent rejection,
//!   which is all the engine keys off. This case can only ever be reached by
//!   racing a delete, since Google's cascade means a live parent vanishes only
//!   mid-flight. Modelling it as success let the fake hold a task whose parent
//!   it did not have — a state the real service cannot be in, and one our pull
//!   re-detaches on every run, so sync never settles (found by §J, #113).
//! - attaching an open task to a **completed** parent (by `insert` with a
//!   `parent`, or by `move`) completes it: the response body itself already
//!   carries `status: completed`, and the cascade reaches the attached
//!   subtree.
//! - inserting a child does NOT bump the parent's etag, so a complete pushed
//!   with a pre-child etag lands and the cascade takes children the client
//!   never pulled.
//!
//! - **Soft delete.** Google soft-deletes, and the fake now models it: a
//!   `DELETE` moves the row (and its cascade subtree) into a `deleted` set
//!   instead of dropping it. A direct `get` still returns 200 (its `deleted`
//!   flag lives on the wire only; our typed `Task` drops it), a later `patch`
//!   returns 200 but is silently ignored (the row stays deleted, and — key for
//!   P4 — does NOT 412 on a stale etag), and the row is absent from
//!   `list_tasks` (which defaults to `showDeleted=false`). The engine converges
//!   §B×deleted through ghost detection on the pull, exactly as live. Verified
//!   live (RFC-009 #106; exact echo body + stale-etag PATCH pinned by probe
//!   round 2 — see the `live_api_probe` example).
//!
//! Known, deliberate divergences from the live API (recorded so nobody
//! "fixes" the fake into a fiction — see RFC-009 §"Probes"):
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
    /// Soft-deleted rows, moved OUT of `tasks` by a `delete`. Google
    /// soft-deletes: a deleted row vanishes from `tasks.list` (which defaults
    /// to `showDeleted=false`) but a direct `get` still returns it (200,
    /// `deleted: true`) and a `patch` is accepted-but-ignored. Keeping them in
    /// a separate collection means every internal query over `tasks`
    /// (insert/move parent checks, positioning, completion cascade) naturally
    /// sees only live rows, exactly as the live service does.
    deleted: Vec<(String, Task)>, // (list_id, task)
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
    /// Methods whose next call commits its mutation server-side and THEN returns
    /// a network error — models a response lost after the server already applied
    /// the change (the at-least-once hazard). Fired and consumed per method, so
    /// arming several methods loses one response each. Generalizes the historic
    /// insert-only lost-response fault to every mutating method, so a lost
    /// PATCH/DELETE/MOVE response can be exercised, not just a lost create.
    commit_then_fail: Vec<Method>,
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

    /// Consume a "commit then fail" arming for `m` if one is pending, returning
    /// whether THIS call's response should be lost after its mutation committed.
    fn take_commit_then_fail(&mut self, m: Method) -> bool {
        if let Some(pos) = self.commit_then_fail.iter().position(|&x| x == m) {
            self.commit_then_fail.remove(pos);
            true
        } else {
            false
        }
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

    /// Soft-delete `id` and its whole subtree the way the live service does:
    /// the rows move out of the live set into `deleted`, so they disappear from
    /// `list_tasks` while a direct `get`/`patch` still reaches them. Mirrors
    /// the DELETE endpoint's server-side cascade (a parent's delete takes its
    /// descendants). Returns how many rows were moved — `0` when `id` names no
    /// live task, which the callers turn into a 404.
    fn soft_delete_subtree(&mut self, id: &str) -> usize {
        if !self.tasks.iter().any(|(_, t)| t.id == id) {
            return 0;
        }
        // Collect the subtree: the root plus every transitive descendant.
        let mut subtree: std::collections::HashSet<String> =
            std::collections::HashSet::from([id.to_string()]);
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
        let mut moved = 0;
        let mut i = 0;
        while i < self.tasks.len() {
            if subtree.contains(&self.tasks[i].1.id) {
                let row = self.tasks.remove(i);
                self.deleted.push(row);
                moved += 1;
            } else {
                i += 1;
            }
        }
        moved
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

/// Live-API field-size limits, from the Google Tasks docs (verified 2026-07-28,
/// `developers.google.com/tasks/reference/rest/v1/tasks`): `title` ≤ 1024
/// characters, `notes` ≤ 8192 characters. Either overflow is a permanent 400
/// ("invalid argument"), the same permanent-rejection shape as a bare `due` —
/// so an oversize edit drives the engine's `PushFailure::Reject` path (#146).
const MAX_TITLE_CHARS: usize = 1024;
const MAX_NOTES_CHARS: usize = 8192;

/// Reject a `title`/`notes` that exceeds the documented length. Google counts
/// characters, not bytes, so this counts `char`s. `None` (field absent from the
/// request) passes through untouched.
fn validate_sizes(title: Option<&str>, notes: Option<&str>) -> Result<(), ApiError> {
    if title.is_some_and(|t| t.chars().count() > MAX_TITLE_CHARS) {
        return Err(ApiError::Other(
            "400: Request contains an invalid argument. (title too long)".into(),
        ));
    }
    if notes.is_some_and(|n| n.chars().count() > MAX_NOTES_CHARS) {
        return Err(ApiError::Other(
            "400: Request contains an invalid argument. (notes too long)".into(),
        ));
    }
    Ok(())
}

/// A hook fired at the START of every [`GoogleTasksClient`] call on this
/// client — receiving the client itself and the [`Method`] about to run,
/// BEFORE that call takes the state lock or does any work. It exists to
/// interleave a server-side mutation (another device racing us) at a precise
/// point INSIDE one sync run: the engine makes many calls per run, and the
/// existing fault/`*_from_state` helpers only mutate at op boundaries, never
/// between the engine's own list/get/push/pull calls. The hook receives
/// `&InMemoryClient` so it can drive the same synchronous helpers
/// (`seed_task`/`seed_list`/`delete_task_from_state`/`delete_list_from_state`).
///
/// It is `FnMut` and SYNCHRONOUS (the trait methods are async, but the hook is
/// not, so it must use the sync helpers above, not the async trait methods).
/// It fires with its own slot emptied, so a re-entrant client call from inside
/// the hook does NOT re-fire it — no recursion and no deadlock on the inner
/// lock.
type OnCall = Box<dyn FnMut(&InMemoryClient, Method) + Send>;

/// In-memory test double. Cheap to clone the handle (interior `Mutex`).
#[derive(Default)]
pub struct InMemoryClient {
    inner: Mutex<State>,
    /// Optional per-call interleave hook; see [`OnCall`] and
    /// [`InMemoryClient::set_on_call`]. Held under its OWN mutex, separate from
    /// `inner`, so the hook can re-enter and lock `inner` without deadlocking.
    on_call: Mutex<Option<OnCall>>,
}

// Hand-written because `OnCall` (a boxed closure) is not `Debug`; we report
// only whether a hook is currently armed.
impl std::fmt::Debug for InMemoryClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InMemoryClient")
            .field("inner", &self.inner)
            .field(
                "on_call_armed",
                &self.on_call.lock().map(|g| g.is_some()).unwrap_or(true),
            )
            .finish()
    }
}

impl InMemoryClient {
    /// Construct an empty client.
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(State::new()),
            on_call: Mutex::new(None),
        }
    }

    /// Install (or replace) the per-call interleave hook. See [`OnCall`] for
    /// the contract; [`InMemoryClient::clear_on_call`] removes it.
    pub fn set_on_call<F>(&self, hook: F)
    where
        F: FnMut(&InMemoryClient, Method) + Send + 'static,
    {
        *self.on_call.lock().unwrap() = Some(Box::new(hook));
    }

    /// Remove any installed on_call hook.
    pub fn clear_on_call(&self) {
        *self.on_call.lock().unwrap() = None;
    }

    /// Fire the on_call hook (if armed) for method `m`. Taken out of its slot
    /// while running so a re-entrant call from inside the hook sees an empty
    /// slot instead of recursing or deadlocking, then restored unless the hook
    /// replaced or cleared it.
    fn fire_on_call(&self, m: Method) {
        let taken = self.on_call.lock().unwrap().take();
        if let Some(mut hook) = taken {
            hook(self, m);
            let mut slot = self.on_call.lock().unwrap();
            if slot.is_none() {
                *slot = Some(hook);
            }
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
            deleted: false,
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

    /// Arm a lost-response fault on the next call to `m`: it commits its
    /// mutation server-side, then returns a network error — the at-least-once
    /// hazard where a response is lost after the server already applied the
    /// change. Defined for the mutating methods (`insert`/`patch`/`delete`/
    /// `move`); arming a read-only method has no committed mutation to preserve,
    /// so its call simply never checks the arming.
    pub fn commit_then_fail_next(&self, m: Method) {
        self.inner.lock().unwrap().commit_then_fail.push(m);
    }

    /// Back-compat shorthand for the insert-only lost-response fault — the same
    /// as `commit_then_fail_next(Method::InsertTask)`.
    pub fn commit_then_fail_next_insert(&self) {
        self.commit_then_fail_next(Method::InsertTask);
    }

    /// Disarm every queued fault — untargeted, targeted, and every pending
    /// commit-then-fail lost response. Lets a test switch from a chaotic phase to a
    /// provably healthy one: an armed-but-never-fired fault would otherwise
    /// still be waiting in the queue and fire during the recovery phase.
    pub fn clear_faults(&self) {
        let mut s = self.inner.lock().unwrap();
        s.faults.clear();
        s.targeted_faults.clear();
        s.commit_then_fail.clear();
    }

    /// Soft-delete a task server-side, the way another client's `DELETE`
    /// would: the row (and its subtree, per Google's cascade) leaves
    /// `list_tasks`, but a direct `get` still returns it (200, `deleted:true`)
    /// and a `patch` is accepted-but-ignored — so a local pending edit against
    /// it converges through ghost detection on the pull, not a 404. Mirrors
    /// [`GoogleTasksClient::delete_task`] without recording a call or consuming
    /// a fault. `list_id` is accepted for call-site clarity; the subtree is
    /// resolved by id (ids are unique across lists).
    pub fn delete_task_from_state(&self, _list_id: &str, task_id: &str) {
        self.inner.lock().unwrap().soft_delete_subtree(task_id);
    }

    /// Insert a task server-side the way another client's create would, but
    /// TOLERANT of a racing delete: if `list_id` no longer exists (our own
    /// in-flight run may have deleted it moments earlier) the insert is a safe
    /// no-op instead of a panic. This is the create counterpart to
    /// [`InMemoryClient::delete_task_from_state`] and, like it, records no call
    /// and consumes no fault — so it can be driven from an on_call hook to model
    /// "another device created a task mid-run". (Setup-time seeding should still
    /// use [`InMemoryClient::seed_task`], whose assertion catches typos.)
    pub fn seed_task_if_list_exists(&self, list_id: &str, id: &str, title: &str, position: &str) {
        let mut s = self.inner.lock().unwrap();
        if !s.lists.iter().any(|l| l.id == list_id) {
            return;
        }
        let etag = s.fresh_etag();
        s.tasks.push((
            list_id.into(),
            Task {
                id: id.into(),
                parent: None,
                position: position.into(),
                title: title.into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: Some(etag),
                updated: "2026-01-01T00:00:00Z".into(),
                web_view_link: Some(format!("https://tasks.google.com/task/{id}")),
                deleted: false,
            },
        ));
    }

    /// Remove a list (and its tasks) from internal state, simulating a list
    /// deleted server-side by another client. Single-task/list methods against
    /// it then naturally return [`ApiError::NotFound`], and a pull will not
    /// resurrect it.
    pub fn delete_list_from_state(&self, list_id: &str) {
        let mut s = self.inner.lock().unwrap();
        s.lists.retain(|l| l.id != list_id);
        s.tasks.retain(|(lid, _)| lid != list_id);
        s.deleted.retain(|(lid, _)| lid != list_id);
    }

    /// How many times `m` has been invoked.
    pub fn call_count(&self, m: Method) -> u32 {
        self.inner.lock().unwrap().calls[m as usize]
    }
}

#[async_trait]
impl GoogleTasksClient for InMemoryClient {
    async fn list_tasklists(&self) -> Result<Vec<TaskList>, ApiError> {
        self.fire_on_call(Method::ListTaskLists);
        let mut s = self.inner.lock().unwrap();
        s.record(Method::ListTaskLists);
        if let Some(e) = s.next_fault(Method::ListTaskLists) {
            return Err(e);
        }
        Ok(s.lists.clone())
    }

    async fn insert_tasklist(&self, title: &str) -> Result<TaskList, ApiError> {
        self.fire_on_call(Method::InsertTaskList);
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
        self.fire_on_call(Method::PatchTaskList);
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
        self.fire_on_call(Method::DeleteTaskList);
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
        s.deleted.retain(|(lid, _)| lid != id); // its tombstones go too
        Ok(())
    }

    async fn list_tasks(
        &self,
        list_id: &str,
        page_token: Option<&str>,
    ) -> Result<Page<Task>, ApiError> {
        self.fire_on_call(Method::ListTasks);
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
        self.fire_on_call(Method::InsertTask);
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
        validate_sizes(Some(&new.title), new.notes.as_deref())?;
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
            deleted: false,
        };
        s.tasks.push((list_id.into(), task.clone()));
        if s.take_commit_then_fail(Method::InsertTask) {
            return Err(ApiError::Network("response timeout after commit".into()));
        }
        Ok(task)
    }

    async fn get_task(&self, list_id: &str, id: &str) -> Result<Task, ApiError> {
        self.fire_on_call(Method::GetTask);
        let mut s = self.inner.lock().unwrap();
        s.record(Method::GetTask);
        if let Some(e) = s.next_fault(Method::GetTask) {
            return Err(e);
        }
        if let Some(e) = s.next_targeted_fault(Method::GetTask, &FaultTarget::Id(id.into())) {
            return Err(e);
        }
        if let Some((_, t)) = s.tasks.iter().find(|(lid, t)| lid == list_id && t.id == id) {
            return Ok(t.clone());
        }
        // Live-API behavior: a soft-deleted task still answers 200 on a direct
        // get (flagged `deleted:true` server-side, now carried on the wire).
        // Normal §B×deleted still converges via ghost detection on the pull; the
        // flag only matters when a 412 conflict refetch lands on a tombstone
        // (the delete×edit race, #141) — then it resolves P4 delete-wins.
        if let Some((_, t)) = s
            .deleted
            .iter()
            .find(|(lid, t)| lid == list_id && t.id == id)
        {
            return Ok(Task {
                deleted: true,
                ..t.clone()
            });
        }
        Err(ApiError::NotFound)
    }

    async fn patch_task(
        &self,
        list_id: &str,
        id: &str,
        patch: TaskPatch,
        etag: Option<&str>,
    ) -> Result<Task, ApiError> {
        self.fire_on_call(Method::PatchTask);
        let mut s = self.inner.lock().unwrap();
        s.record(Method::PatchTask);
        if let Some(e) = s.next_fault(Method::PatchTask) {
            return Err(e);
        }
        if let Some(e) = s.next_targeted_fault(Method::PatchTask, &FaultTarget::Id(id.into())) {
            return Err(e);
        }
        // Argument validation precedes resource lookup on the live API: an
        // oversize title/notes is a permanent 400 regardless of the target row's
        // state (live, deleted, or absent).
        validate_sizes(patch.title.as_deref(), patch.notes.as_deref())?;
        if !s.lists.iter().any(|l| l.id == list_id) {
            return Err(ApiError::NotFound);
        }
        let new_etag = s.fresh_etag();
        let Some(idx) = s.tasks.iter().position(|(_, t)| t.id == id) else {
            // Live-API behavior: a PATCH to a soft-deleted task returns 200 with
            // a body echoing the requested edit, but the row stays deleted and
            // never returns to `list_tasks` — the "accepted then silently
            // ignored" shape (verified live, RFC-009 #106; the exact echo body
            // and whether a stale If-Match still 200s are pinned by probe round
            // 2). §B×deleted therefore converges through ghost detection on the
            // pull, not this method's 404. The echo is NOT persisted, so the
            // row remains deleted; the etag is left unchanged (nothing changed
            // server-side). This must NOT 412 on a stale etag: a fork on a
            // delete/edit race would violate P4 (delete wins, no conflicted
            // copy).
            if let Some((_, dt)) = s
                .deleted
                .iter()
                .find(|(lid, t)| lid == list_id && t.id == id)
            {
                let mut echo = dt.clone();
                if let Some(title) = patch.title {
                    echo.title = title;
                }
                if let Some(notes) = patch.notes {
                    echo.notes = if notes.is_empty() { None } else { Some(notes) };
                }
                if let Some(due) = patch.due {
                    echo.due = validate_due(Some(due))?;
                }
                if let Some(status) = patch.status {
                    echo.status = status;
                    echo.completed = if status == TaskStatus::Completed {
                        Some("2026-01-01T00:00:00Z".into())
                    } else {
                        None
                    };
                }
                return Ok(echo);
            }
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
        // Lost-response hazard: the patch committed above (new etag, new
        // content), but its response is dropped. Our retry meets a 412 whose
        // remote already carries OUR OWN content — the self-content 412 the
        // engine must absorb by adopting the remote etag, with no copy.
        if s.take_commit_then_fail(Method::PatchTask) {
            return Err(ApiError::Network("response timeout after commit".into()));
        }
        Ok(result)
    }

    async fn delete_task(&self, list_id: &str, id: &str) -> Result<(), ApiError> {
        self.fire_on_call(Method::DeleteTask);
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
        // Live-API behavior: DELETE soft-deletes. The row leaves `list_tasks`
        // but a direct `get`/`patch` still reaches it (verified live, RFC-009
        // #106). The server cascades to descendants, so the whole subtree goes.
        if s.soft_delete_subtree(id) == 0 {
            return Err(ApiError::NotFound);
        }
        // Lost-response hazard: the subtree is already soft-deleted, but the
        // response is dropped. Our retry meets a 404 (the row is gone), which
        // the engine treats as a completed delete — it must converge, not fail.
        if s.take_commit_then_fail(Method::DeleteTask) {
            return Err(ApiError::Network("response timeout after commit".into()));
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
        self.fire_on_call(Method::MoveTask);
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
        // for an unknown `previous` (404) and an unknown SUBJECT id (400);
        // probe round 2c (#114) pins the status for an unknown/soft-deleted
        // `parent` on a MOVE. This reuses insert's verified rule for the same
        // field; the engine treats every permanent rejection the same way, so
        // the choice between 400 and 404 changes nothing it does.
        if let Some(p) = parent
            && !s.tasks.iter().any(|(_, t)| t.id == p)
        {
            return Err(ApiError::Other("400: Invalid task ID (parent)".into()));
        }
        // A task cannot become its own descendant: Google's model is a forest,
        // so a move whose target parent is the task itself or anywhere in its
        // own subtree is a permanent 400 — evaluated against CURRENT server
        // state, the same "Invalid task ID" as an unknown parent. Two devices
        // each demoting the opposite end of a pair from stale views (the
        // classic offline race) otherwise let the fake hold a parent CYCLE
        // Google never could — a state the pull cannot topologically order, so
        // a child lands before its parent and fails the FK (#155). Walk up from
        // the target parent: reaching `id` proves the move closes a cycle.
        if let Some(p) = parent {
            let mut cur = Some(p);
            while let Some(c) = cur {
                if c == id {
                    return Err(ApiError::Other("400: Invalid task ID (parent)".into()));
                }
                cur = s
                    .tasks
                    .iter()
                    .find(|(_, t)| t.id == c)
                    .and_then(|(_, t)| t.parent.as_deref());
            }
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
        // Lost-response hazard: the move committed above (new parent/position/
        // etag), but the response is dropped. Our retry re-sends the same move;
        // it must reconverge to the state the server already holds, not wedge.
        if s.take_commit_then_fail(Method::MoveTask) {
            return Err(ApiError::Network("response timeout after commit".into()));
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
    async fn delete_soft_deletes_gone_from_list_but_still_gettable() {
        // Live-API soft delete (RFC-009 #106): after DELETE the row vanishes
        // from `list_tasks` (showDeleted defaults off) but a direct `get` still
        // returns 200 — it is NOT hard-removed.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let t = c.seed_task("L1", "T1", "first", "00000000000001");
        c.delete_task("L1", &t.id).await.unwrap();

        assert!(
            c.list_tasks("L1", None).await.unwrap().items.is_empty(),
            "a deleted task is absent from list_tasks"
        );
        let got = c
            .get_task("L1", &t.id)
            .await
            .expect("a soft-deleted task still answers 200 on a direct get");
        assert_eq!(got.id, "T1");
    }

    #[tokio::test]
    async fn patch_of_a_deleted_task_is_200_but_ignored() {
        // Live-API behavior: a PATCH to a soft-deleted task returns 200 with a
        // body echoing the edit, but the row stays deleted and never returns to
        // list_tasks. The stored row is untouched.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let t = c.seed_task("L1", "T1", "first", "00000000000001");
        c.delete_task("L1", &t.id).await.unwrap();

        let echo = c
            .patch_task(
                "L1",
                &t.id,
                TaskPatch {
                    title: Some("edit-after-delete".into()),
                    ..Default::default()
                },
                None,
            )
            .await
            .expect("PATCH of a deleted task is accepted (200), not a 404");
        assert_eq!(
            echo.title, "edit-after-delete",
            "the 200 body echoes the requested edit"
        );
        // …but nothing was revived: still gone from list_tasks, and the stored
        // row keeps its original title.
        assert!(c.list_tasks("L1", None).await.unwrap().items.is_empty());
        assert_eq!(
            c.get_task("L1", &t.id).await.unwrap().title,
            "first",
            "the edit was silently ignored server-side"
        );
    }

    #[tokio::test]
    async fn oversize_title_and_notes_are_permanent_400s() {
        // Live-API limits (Google Tasks docs, verified 2026-07-28): title ≤ 1024
        // chars, notes ≤ 8192 chars. One character past either bound is a
        // permanent 400 on both insert and patch; the exact boundary is
        // accepted. Google counts characters, not bytes.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");

        // Insert: the boundary lengths are accepted.
        let ok = c
            .insert_task(
                "L1",
                NewTask {
                    title: "t".repeat(MAX_TITLE_CHARS),
                    notes: Some("n".repeat(MAX_NOTES_CHARS)),
                    ..Default::default()
                },
            )
            .await
            .expect("title=1024, notes=8192 are exactly at the limit → accepted");

        // Insert: one char over the title limit is a permanent 400.
        let title_err = c
            .insert_task(
                "L1",
                NewTask {
                    title: "t".repeat(MAX_TITLE_CHARS + 1),
                    ..Default::default()
                },
            )
            .await
            .unwrap_err();
        assert!(matches!(title_err, ApiError::Other(_)), "got {title_err:?}");
        assert!(!title_err.is_transient(), "an oversize title never retries");

        // Insert: one char over the notes limit is a permanent 400.
        let notes_err = c
            .insert_task(
                "L1",
                NewTask {
                    title: "ok".into(),
                    notes: Some("n".repeat(MAX_NOTES_CHARS + 1)),
                    ..Default::default()
                },
            )
            .await
            .unwrap_err();
        assert!(matches!(notes_err, ApiError::Other(_)), "got {notes_err:?}");
        assert!(!notes_err.is_transient(), "an oversize note never retries");

        // Patch: an oversize notes edit on an existing row is the same 400 —
        // and it does NOT mutate the stored row (the reject is total).
        let patch_err = c
            .patch_task(
                "L1",
                &ok.id,
                TaskPatch {
                    notes: Some("n".repeat(MAX_NOTES_CHARS + 1)),
                    ..Default::default()
                },
                ok.etag.as_deref(),
            )
            .await
            .unwrap_err();
        assert!(matches!(patch_err, ApiError::Other(_)), "got {patch_err:?}");
        assert!(!patch_err.is_transient());
        assert_eq!(
            c.get_task("L1", &ok.id).await.unwrap().etag,
            ok.etag,
            "a rejected oversize patch leaves the row (and its etag) untouched"
        );

        // Multi-byte characters count as characters, not bytes: 1024 emoji
        // (~4 bytes each) is within the title limit even though the byte length
        // is far over 1024.
        c.insert_task(
            "L1",
            NewTask {
                title: "😀".repeat(MAX_TITLE_CHARS),
                ..Default::default()
            },
        )
        .await
        .expect("1024 multi-byte chars is 1024 chars, within the limit");
    }

    #[tokio::test]
    async fn empty_notes_patch_clears_the_field_to_none() {
        // Live-API rule (RFC-009): sending `notes: ""` CLEARS the field — the
        // server stores and returns absent notes, never a stored empty string.
        // The fake mirrors this so a note-clear round-trips as `None`, which is
        // what `same_content` compares against (no phantom conflict).
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let t = c
            .insert_task(
                "L1",
                NewTask {
                    title: "has notes".into(),
                    notes: Some("something".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(t.notes.as_deref(), Some("something"));

        let cleared = c
            .patch_task(
                "L1",
                &t.id,
                TaskPatch {
                    notes: Some(String::new()),
                    ..Default::default()
                },
                t.etag.as_deref(),
            )
            .await
            .unwrap();
        assert_eq!(cleared.notes, None, "empty-string notes clears to None");
        // And the stored row (not just the echo) is cleared.
        assert_eq!(c.get_task("L1", &t.id).await.unwrap().notes, None);
    }

    #[tokio::test]
    async fn empty_title_is_accepted_not_rejected() {
        // Google Tasks allows an untitled task: a just-created task starts with
        // an empty title and gets named later. An empty title is a valid value,
        // NOT the "invalid argument" that an oversize title is — so neither
        // insert nor patch may reject it. (Contrast with
        // `oversize_title_and_notes_are_permanent_400s`.)
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let t = c
            .insert_task(
                "L1",
                NewTask {
                    title: String::new(),
                    ..Default::default()
                },
            )
            .await
            .expect("an empty title is a valid untitled task, not a 400");
        assert_eq!(t.title, "");

        let renamed = c
            .patch_task(
                "L1",
                &t.id,
                TaskPatch {
                    title: Some("named now".into()),
                    ..Default::default()
                },
                t.etag.as_deref(),
            )
            .await
            .unwrap();
        // And clearing a title back to empty is likewise accepted, not a 400.
        let recleared = c
            .patch_task(
                "L1",
                &t.id,
                TaskPatch {
                    title: Some(String::new()),
                    ..Default::default()
                },
                renamed.etag.as_deref(),
            )
            .await
            .expect("clearing a title to empty is accepted");
        assert_eq!(recleared.title, "");
    }

    #[tokio::test]
    async fn patch_of_a_deleted_task_with_a_stale_etag_still_200s_no_412() {
        // P4 guard: a delete/edit race must never fork. The engine cannot see
        // the `deleted` flag through the typed client, so if a stale-etag PATCH
        // to a deleted row 412'd, the 412-resolution path would refetch it and
        // fabricate a conflicted copy of a row that is actually gone. The live
        // service answers 200-and-ignore regardless of If-Match (pinned by
        // probe round 2); the fake must too.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        let t = c.seed_task("L1", "T1", "first", "00000000000001");
        c.delete_task("L1", &t.id).await.unwrap();

        let resp = c
            .patch_task(
                "L1",
                &t.id,
                TaskPatch {
                    title: Some("nope".into()),
                    ..Default::default()
                },
                Some("definitely-stale-etag"),
            )
            .await;
        assert!(
            resp.is_ok(),
            "a stale etag must not 412 a deleted row: got {resp:?}"
        );
        assert!(c.list_tasks("L1", None).await.unwrap().items.is_empty());
    }

    #[tokio::test]
    async fn delete_soft_deletes_the_whole_subtree() {
        // The server cascades a delete to descendants; each is soft-deleted
        // (gone from list_tasks, still gettable), not left stranded.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "P", "parent", "1");
        c.seed_task_with_parent("L1", "C", "child", "2", Some("P"));
        c.seed_task_with_parent("L1", "G", "grandchild", "3", Some("C"));

        c.delete_task("L1", "P").await.unwrap();

        assert!(
            c.list_tasks("L1", None).await.unwrap().items.is_empty(),
            "parent and every descendant leave list_tasks"
        );
        for id in ["P", "C", "G"] {
            assert!(
                c.get_task("L1", id).await.is_ok(),
                "{id} is soft-deleted, not hard-removed"
            );
        }
    }

    #[tokio::test]
    async fn deleting_a_parent_prevents_new_inserts_under_it() {
        // A soft-deleted parent is not a live task, so an insert naming it is a
        // permanent 400 — the same rule an unknown parent draws. Guards that
        // deleted rows stay out of the live parent set.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "P", "parent", "1");
        c.delete_task("L1", "P").await.unwrap();
        let err = c
            .insert_task(
                "L1",
                NewTask {
                    title: "orphan".into(),
                    parent: Some("P".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap_err();
        assert!(!err.is_transient(), "unknown/deleted parent is permanent");
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
    async fn move_task_rejects_a_cycle() {
        // A task cannot become its own descendant (Google's forest model,
        // #155). Reparenting T1 under its own child T2 would form a cycle
        // T1→T2→T1 — a state Google never holds and one our pull cannot
        // topologically order. It is a permanent 400, and the tree is left
        // exactly as it was.
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        c.seed_task("L1", "T1", "parent", "00000000000001");
        c.seed_task("L1", "T2", "child", "00000000000002");
        c.move_task("L1", "T2", Some("T1"), None).await.unwrap(); // T2 under T1

        let err = c
            .move_task("L1", "T1", Some("T2"), None)
            .await
            .expect_err("moving a task under its own child is a cycle");
        assert!(!err.is_transient(), "a cycle is a permanent rejection");

        // Direct self-parent is rejected the same way.
        let self_err = c
            .move_task("L1", "T1", Some("T1"), None)
            .await
            .expect_err("a task cannot be its own parent");
        assert!(!self_err.is_transient());

        // Nothing moved: T1 stayed top-level, T2 stayed under T1.
        let after = c.list_tasks("L1", None).await.unwrap().items;
        let t1 = after.iter().find(|t| t.id == "T1").unwrap();
        let t2 = after.iter().find(|t| t.id == "T2").unwrap();
        assert_eq!(t1.parent, None, "the rejected cycle left T1 top-level");
        assert_eq!(t2.parent.as_deref(), Some("T1"), "T2 stayed under T1");
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
