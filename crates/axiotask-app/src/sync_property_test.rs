//! Property / invariant tests for sync over RANDOM operation orderings (#104).
//!
//! The rest of the suite is example-based: it proves that a specific, chosen
//! interleaving behaves. The bug class that shipped (a held create that never
//! synced) lives in the interleavings nobody thought to write down. These tests
//! generate random sequences of real user operations — the same
//! `commands::*_inner` functions the Tauri commands call — against the real
//! store and the real sync engine, and assert INVARIANTS ON STATE (local store
//! rows and server rows), never "a call happened".
//!
//! The six invariants, one test each, from the issue:
//!  * eventual push   — pending work drains to zero under repeated healthy runs
//!  * convergence     — local == server field-for-field after push + pull
//!  * idempotency     — a run after the fixpoint changes nothing
//!  * deferral safety — everything held by an open panel completes once it closes
//!  * crash safety    — nested creates + in-flight markers yield no duplicates
//!  * parent integrity— no child ever points at a parent that isn't there
//!
//! ## Determinism (no flaky tests)
//!
//! Two sources of randomness are pinned:
//!  * proptest runs on a `deterministic_rng`, so every run explores the SAME
//!    sequences. A failure here is a real defect, reproducible on the next run,
//!    never a coin flip. `failure_persistence` is off — no regression files.
//!  * an op refers to a task by its position in the harness's own creation
//!    order, resolved through a UNIQUE TITLE, never through the random UUID the
//!    store assigns (which also gets remapped to a server id mid-run). The same
//!    op sequence therefore touches the same logical tasks every time.

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};
    use std::fmt::Write as _;
    use std::sync::Arc;

    use axiotask_core::api::in_memory::Method;
    use axiotask_core::api::{ApiError, GoogleTasksClient, InMemoryClient};
    use axiotask_core::model::{Task, TaskStatus};
    use axiotask_core::store::{StoredTask, SyncState};
    use axiotask_core::sync::SyncOutcome;
    use proptest::prelude::*;
    use proptest::test_runner::{Config, RngAlgorithm, TestRng, TestRunner};

    use crate::state::AppState;

    /// The list every generated operation works in. Seeded on the server, so
    /// its id is stable across the whole run (no list-create remap to chase).
    const LIST: &str = "L1";

    /// Upper bound on the recovery runs a fixpoint may take. Each healthy run
    /// makes progress (push a batch, adopt an orphan, backfill a web view
    /// link), so a sequence that still hasn't settled after this many runs is
    /// not "slow" — it is stuck, which is exactly what these tests hunt for.
    const MAX_HEAL_RUNS: usize = 16;

    /// Sequences explored per invariant on a normal `cargo test`. Sized so all
    /// six together stay well under a minute — a property suite that makes the
    /// default test run painful gets skipped, which protects nothing. Deep
    /// soaks raise it through `AXIOTASK_PROPTEST_CASES` (see `check`).
    const DEFAULT_CASES: u32 = 256;

    // ─── Operations ──────────────────────────────────────────────────────────

    /// One user-or-system action. Indices are resolved modulo the number of
    /// live tasks at execution time, so every generated value is meaningful.
    #[derive(Debug, Clone, Copy)]
    enum Op {
        /// New top-level task.
        CreateTop,
        /// New subtask under the i-th live TOP-LEVEL task (one level only).
        CreateSub(u8),
        /// Rename the i-th live task.
        Rename(u8),
        /// Apply a date move to the i-th live task.
        SetDue(u8, u8),
        /// Toggle completion of the i-th live task (cascades to its subtree).
        Toggle(u8),
        /// Delete the i-th live task (cascades to its subtree).
        Delete(u8),
        /// Keyboard reorder of the i-th live task among its siblings.
        Reorder(u8, bool),
        /// Drag the i-th live task to sit after the j-th one, adopting its
        /// parent — the reparent path, kept to one level.
        MoveAfter(u8, u8),
        /// Open the detail panel / inline editor on the i-th live task, which
        /// HOLDS that task's create push.
        OpenPanel(u8),
        /// Close the panel, releasing the hold.
        ClosePanel,
        /// A healthy sync run.
        Sync,
        /// A sync run with one transient fault armed (5xx / network drop).
        FlakySync(u8),
        /// A sync run where an insert commits server-side but the response is
        /// lost — the at-least-once create hazard that leaves an in-flight
        /// marker behind.
        CrashSync,
    }

    /// Transient faults only: a permanent rejection would legitimately leave a
    /// row dirty forever, which is a different (already covered) behavior.
    const TRANSIENT: [(Method, fn() -> ApiError); 6] = [
        (Method::ListTasks, || ApiError::Server { status: 503 }),
        (Method::InsertTask, || ApiError::Network("reset".into())),
        (Method::PatchTask, || ApiError::Server { status: 500 }),
        (Method::DeleteTask, || ApiError::Network("timeout".into())),
        (Method::MoveTask, || ApiError::RateLimited {
            retry_after: None,
        }),
        (Method::ListTaskLists, || ApiError::Server { status: 502 }),
    ];

    const DATE_MOVES: [&str; 5] = ["Today", "Tomorrow", "NextWeek", "NextMonth", "Clear"];

    // ─── Harness ─────────────────────────────────────────────────────────────

    /// A whole app instance: real store, real sync engine, fake Google.
    struct Harness {
        client: Arc<InMemoryClient>,
        state: Arc<AppState>,
        /// Every task this harness created, in creation order, identified by
        /// its CURRENT title. Titles are unique per harness, so this is a
        /// stable handle that survives the local→server id remap.
        names: Vec<String>,
        next_name: u32,
    }

    impl Harness {
        async fn new() -> Self {
            let client = Arc::new(InMemoryClient::new());
            client.seed_list(LIST, "Inbox");
            let state = Arc::new(
                AppState::new_memory_with_push(client.clone())
                    .await
                    .expect("state"),
            );
            // Start from a synced app: the working list exists locally (pulled)
            // and the bootstrap "My Tasks" list has been pushed. Ops then run
            // against a realistic post-first-sync state.
            state.run_sync().await.expect("initial sync");
            Self {
                client,
                state,
                names: Vec::new(),
                next_name: 0,
            }
        }

        fn fresh_name(&mut self) -> String {
            self.next_name += 1;
            format!("t{:03}", self.next_name)
        }

        /// Live tasks of the working list in harness creation order. A task the
        /// store no longer holds (deleted, or cascade-deleted with its parent)
        /// simply drops out.
        async fn live(&self) -> Vec<StoredTask> {
            let rows = self.state.store.list_tasks(LIST).await.expect("list_tasks");
            let by_title: HashMap<&str, &StoredTask> =
                rows.iter().map(|r| (r.task.title.as_str(), r)).collect();
            self.names
                .iter()
                .filter_map(|n| by_title.get(n.as_str()).map(|r| (*r).clone()))
                .collect()
        }

        /// Whether `id` has any child in the working list.
        async fn has_children(&self, id: &str) -> bool {
            self.state
                .store
                .list_tasks(LIST)
                .await
                .expect("list_tasks")
                .iter()
                .any(|r| r.task.parent.as_deref() == Some(id))
        }

        // One arm per operation: splitting the dispatcher would scatter the
        // model without making any arm easier to read.
        #[allow(clippy::too_many_lines)]
        async fn apply(&mut self, op: Op) {
            match op {
                Op::CreateTop => {
                    let title = self.fresh_name();
                    crate::commands::create_task_inner(
                        &self.state,
                        LIST.into(),
                        None,
                        title.clone(),
                    )
                    .await
                    .expect("create");
                    self.names.push(title);
                }
                Op::CreateSub(i) => {
                    let live = self.live().await;
                    let tops: Vec<_> = live.iter().filter(|t| t.task.parent.is_none()).collect();
                    let Some(parent) = pick(&tops, i) else { return };
                    let parent_id = parent.task.id.clone();
                    let title = self.fresh_name();
                    crate::commands::create_task_inner(
                        &self.state,
                        LIST.into(),
                        Some(parent_id),
                        title.clone(),
                    )
                    .await
                    .expect("create sub");
                    self.names.push(title);
                }
                Op::Rename(i) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    let (id, old) = (t.task.id.clone(), t.task.title.clone());
                    let new = self.fresh_name();
                    crate::commands::rename_task_inner(&self.state, id, new.clone())
                        .await
                        .expect("rename");
                    // Keep the handle pointing at the same logical task.
                    if let Some(slot) = self.names.iter_mut().find(|n| **n == old) {
                        *slot = new;
                    }
                }
                Op::SetDue(i, d) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    let mv = DATE_MOVES[d as usize % DATE_MOVES.len()];
                    crate::commands::set_due_inner(&self.state, t.task.id.clone(), mv.into())
                        .await
                        .expect("set_due");
                }
                Op::Toggle(i) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    crate::commands::toggle_complete_inner(&self.state, t.task.id.clone())
                        .await
                        .expect("toggle");
                }
                Op::Delete(i) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    let id = t.task.id.clone();
                    // Deleting the row the panel holds would leave a hold on a
                    // task that no longer exists; the UI closes the panel, so
                    // mirror that here.
                    self.state.set_editing_task(None);
                    crate::commands::delete_task_inner(&self.state, id)
                        .await
                        .expect("delete");
                }
                Op::Reorder(i, up) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    let dir = if up { "up" } else { "down" };
                    crate::commands::reorder_task_inner(&self.state, t.task.id.clone(), dir.into())
                        .await
                        .expect("reorder");
                }
                Op::MoveAfter(i, j) => {
                    let live = self.live().await;
                    let (Some(t), Some(anchor)) = (pick(&live, i), pick(&live, j)) else {
                        return;
                    };
                    if t.task.id == anchor.task.id {
                        return;
                    }
                    let new_parent = anchor.task.parent.clone();
                    // Subtasks are strictly one level: a task may only adopt a
                    // parent if it has no children of its own, and may never
                    // become its own descendant's child.
                    if new_parent.as_deref() == Some(t.task.id.as_str()) {
                        return;
                    }
                    if new_parent.is_some() && self.has_children(&t.task.id).await {
                        return;
                    }
                    crate::commands::move_task_inner(
                        &self.state,
                        t.task.id.clone(),
                        new_parent,
                        Some(anchor.task.id.clone()),
                    )
                    .await
                    .expect("move");
                }
                Op::OpenPanel(i) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    self.state.set_editing_task(Some(t.task.id.clone()));
                }
                Op::ClosePanel => self.state.set_editing_task(None),
                Op::Sync => {
                    self.state.run_sync().await.expect("sync");
                }
                Op::FlakySync(k) => {
                    let (m, e) = TRANSIENT[k as usize % TRANSIENT.len()];
                    self.client.fail_next(m, e);
                    self.state.run_sync().await.expect("flaky sync");
                }
                Op::CrashSync => {
                    self.client.commit_then_fail_next_insert();
                    self.state.run_sync().await.expect("crash sync");
                }
            }
        }

        async fn apply_all(&mut self, ops: &[Op]) {
            for op in ops {
                self.apply(*op).await;
            }
        }

        /// Drop every hold and fault, then sync until nothing changes.
        /// Returns the number of runs the fixpoint took.
        async fn heal(&self) -> usize {
            self.client.clear_faults();
            self.state.set_editing_task(None);
            for run in 1..=MAX_HEAL_RUNS {
                let out = self.state.run_sync().await.expect("healthy sync");
                if is_noop(&out) {
                    return run;
                }
            }
            panic!(
                "no sync fixpoint after {MAX_HEAL_RUNS} healthy runs — pending={:?}\n{}",
                self.state.pending_push_count().await,
                self.dump().await
            );
        }

        // ── State readers ────────────────────────────────────────────────────

        async fn server_tasks(&self, list_id: &str) -> Vec<Task> {
            let mut all = Vec::new();
            let mut token: Option<String> = None;
            loop {
                let page = self
                    .client
                    .list_tasks(list_id, token.as_deref())
                    .await
                    .expect("server list_tasks");
                all.extend(page.items);
                match page.next_page_token {
                    Some(t) => token = Some(t),
                    None => break,
                }
            }
            all
        }

        /// Every local task row across every list, as comparable records.
        async fn local_rows(&self) -> Vec<Row> {
            let mut out = Vec::new();
            for l in self.state.store.all_lists().await.expect("lists") {
                for t in self
                    .state
                    .store
                    .list_tasks(&l.list.id)
                    .await
                    .expect("list_tasks")
                {
                    out.push(Row::of(&l.list.id, &t.task));
                }
            }
            out.sort();
            out
        }

        async fn server_rows(&self) -> Vec<Row> {
            let mut out = Vec::new();
            for l in self.client.list_tasklists().await.expect("server lists") {
                for t in self.server_tasks(&l.id).await {
                    out.push(Row::of(&l.id, &t));
                }
            }
            out.sort();
            out
        }

        /// Full local state, including sync metadata — the byte-for-byte
        /// snapshot idempotency compares.
        async fn dump(&self) -> String {
            let mut s = String::new();
            let mut lists = self.state.store.all_lists().await.expect("lists");
            lists.sort_by(|a, b| a.list.id.cmp(&b.list.id));
            for l in lists {
                let _ = writeln!(
                    s,
                    "LIST {} '{}' etag={:?} state={:?} op={:?} local_only={}",
                    l.list.id, l.list.title, l.list.etag, l.sync_state, l.pending_op, l.local_only
                );
                let mut tasks = self
                    .state
                    .store
                    .list_tasks(&l.list.id)
                    .await
                    .expect("list_tasks");
                tasks.sort_by(|a, b| a.task.id.cmp(&b.task.id));
                for t in tasks {
                    let _ = writeln!(
                        s,
                        "  TASK {} parent={:?} '{}' due={:?} status={:?} etag={:?} pos={} state={:?} op={:?}",
                        t.task.id,
                        t.task.parent,
                        t.task.title,
                        t.task.due,
                        t.task.status,
                        t.task.etag,
                        t.task.position,
                        t.sync_state,
                        t.pending_op
                    );
                }
            }
            let mut moves = self
                .state
                .store
                .pending_moves()
                .await
                .expect("pending_moves");
            moves.sort_by(|a, b| a.task_id.cmp(&b.task_id));
            for m in moves {
                let _ = writeln!(
                    s,
                    "  MOVE {} parent={:?} previous={:?}",
                    m.task_id, m.parent_id, m.previous_id
                );
            }
            for (local, list) in self.state.store.inflight_creates().await.expect("inflight") {
                let _ = writeln!(s, "  INFLIGHT {local} in {list}");
            }
            s
        }
    }

    /// A task reduced to the fields that must agree between the local cache
    /// and Google. `position` is deliberately excluded: the move endpoint
    /// returns a fresh etag that pull then skips, so the opaque position string
    /// stays server-authoritative and is only re-adopted on a fresh sync.
    #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
    struct Row {
        list_id: String,
        id: String,
        parent: Option<String>,
        title: String,
        notes: Option<String>,
        due: Option<String>,
        completed: bool,
    }

    impl Row {
        fn of(list_id: &str, t: &Task) -> Self {
            Self {
                list_id: list_id.to_string(),
                id: t.id.clone(),
                parent: t.parent.clone(),
                title: t.title.clone(),
                // Google returns cleared notes as absent; "" and None are the
                // same user-visible state.
                notes: t.notes.clone().filter(|n| !n.is_empty()),
                due: t
                    .due
                    .as_deref()
                    .and_then(axiotask_core::dates::normalize_due),
                completed: t.status == TaskStatus::Completed,
            }
        }
    }

    /// Pick the `i`-th element modulo the length; `None` when empty.
    fn pick<T>(items: &[T], i: u8) -> Option<&T> {
        if items.is_empty() {
            None
        } else {
            Some(&items[i as usize % items.len()])
        }
    }

    /// A run that changed nothing, locally or remotely.
    fn is_noop(o: &SyncOutcome) -> bool {
        o.pulled == 0
            && o.pushed == 0
            && o.conflicts == 0
            && o.deleted == 0
            && o.errors == 0
            && !o.lists_changed
            && o.changed_list_ids.is_empty()
    }

    // ─── Universal structural invariants ─────────────────────────────────────

    /// No child ever points at a parent that isn't in the same list, and the
    /// tree is never deeper than one level (subtasks are strictly one level).
    async fn assert_parent_integrity(h: &Harness, ctx: &str) {
        let dump = h.dump().await;
        for l in h.state.store.all_lists().await.expect("lists") {
            let tasks = h
                .state
                .store
                .list_tasks(&l.list.id)
                .await
                .expect("list_tasks");
            for t in &tasks {
                let Some(p) = t.task.parent.as_deref() else {
                    continue;
                };
                // `find_task_any` on purpose: a parent whose delete hasn't
                // pushed yet is a TOMBSTONE — hidden from every view, but still
                // a real row, and the child goes with it when the delete lands.
                // What must never happen is a pointer at nothing at all.
                let parent = h
                    .state
                    .store
                    .find_task_any(p)
                    .await
                    .expect("find parent")
                    .unwrap_or_else(|| {
                        panic!(
                            "{ctx}: task {} points at missing parent {p}\n{dump}",
                            t.task.id
                        )
                    });
                assert!(
                    parent.task.parent.is_none(),
                    "{ctx}: task {} is nested two levels deep (parent {p} itself has a parent)\n{dump}",
                    t.task.id
                );
            }
        }
    }

    /// After a fixpoint there are no tombstones left, so every visible task's
    /// parent must be visible too — nothing is stranded under a deleted row.
    async fn assert_no_stranded_children(h: &Harness, ctx: &str) {
        let dump = h.dump().await;
        for l in h.state.store.all_lists().await.expect("lists") {
            let tasks = h
                .state
                .store
                .list_tasks(&l.list.id)
                .await
                .expect("list_tasks");
            let visible: HashSet<&str> = tasks.iter().map(|t| t.task.id.as_str()).collect();
            for t in &tasks {
                if let Some(p) = t.task.parent.as_deref() {
                    assert!(
                        visible.contains(p),
                        "{ctx}: task {} is stranded under invisible parent {p}\n{dump}",
                        t.task.id
                    );
                }
            }
        }
    }

    async fn assert_converged(h: &Harness, ctx: &str) {
        let local = h.local_rows().await;
        let server = h.server_rows().await;
        assert_eq!(
            local,
            server,
            "{ctx}: local and server diverge\nlocal state:\n{}",
            h.dump().await
        );
    }

    // ─── Strategies ──────────────────────────────────────────────────────────

    /// The full operation mix. Creates are weighted up so sequences actually
    /// build a tree to mutate; syncs are frequent so pushes and pulls interleave
    /// with edits rather than all landing at the end.
    fn any_op() -> impl Strategy<Value = Op> {
        prop_oneof![
            6 => Just(Op::CreateTop),
            4 => any::<u8>().prop_map(Op::CreateSub),
            3 => any::<u8>().prop_map(Op::Rename),
            3 => (any::<u8>(), any::<u8>()).prop_map(|(i, d)| Op::SetDue(i, d)),
            3 => any::<u8>().prop_map(Op::Toggle),
            2 => any::<u8>().prop_map(Op::Delete),
            2 => (any::<u8>(), any::<bool>()).prop_map(|(i, u)| Op::Reorder(i, u)),
            2 => (any::<u8>(), any::<u8>()).prop_map(|(i, j)| Op::MoveAfter(i, j)),
            2 => any::<u8>().prop_map(Op::OpenPanel),
            2 => Just(Op::ClosePanel),
            5 => Just(Op::Sync),
            3 => any::<u8>().prop_map(Op::FlakySync),
            1 => Just(Op::CrashSync),
        ]
    }

    fn any_ops() -> impl Strategy<Value = Vec<Op>> {
        prop::collection::vec(any_op(), 1..40)
    }

    /// Creates and subtask creates only, with crash-y syncs — the shape the
    /// crash-safety invariant is about.
    fn crash_ops() -> impl Strategy<Value = Vec<Op>> {
        prop::collection::vec(
            prop_oneof![
                5 => Just(Op::CreateTop),
                5 => any::<u8>().prop_map(Op::CreateSub),
                3 => Just(Op::CrashSync),
                2 => Just(Op::Sync),
                2 => any::<u8>().prop_map(Op::FlakySync),
            ],
            2..18,
        )
    }

    /// Deterministic, reproducible property runner. Every invocation explores
    /// the same sequences, so a failure is a defect and never a coin flip.
    ///
    /// `cases` is the default depth: enough to hunt interleavings on every
    /// `cargo test` without making the suite slow. `AXIOTASK_PROPTEST_CASES`
    /// overrides it for a deep soak run — the RNG is seeded identically, so a
    /// deeper run explores a SUPERSET of the sequences the default run does,
    /// and anything it finds reproduces at that depth forever after.
    fn check<S: Strategy>(cases: u32, strategy: S, test: impl Fn(S::Value))
    where
        S::Value: std::fmt::Debug,
    {
        let cases = std::env::var("AXIOTASK_PROPTEST_CASES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(cases);
        let mut runner = TestRunner::new_with_rng(
            Config {
                cases,
                max_shrink_iters: 256,
                failure_persistence: None,
                ..Config::default()
            },
            TestRng::deterministic_rng(RngAlgorithm::ChaCha),
        );
        runner
            .run(&strategy, |value| {
                test(value);
                Ok(())
            })
            .expect("property holds");
    }

    /// Each case gets its own single-threaded runtime and its own in-memory
    /// database, so no state leaks between cases.
    fn run_case<F: std::future::Future<Output = ()>>(f: impl FnOnce() -> F) {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(f());
    }

    // ─── The six invariants ──────────────────────────────────────────────────

    /// EVENTUAL PUSH: whatever the user did, and whatever transient failures
    /// and crashes happened along the way, repeated healthy runs drain every
    /// pending change — no dirty row, tombstone, move intent or in-flight
    /// marker survives.
    #[test]
    fn prop_eventual_push_drains_all_pending_work() {
        check(DEFAULT_CASES, any_ops(), |ops| {
            run_case(|| async move {
                let mut h = Harness::new().await;
                h.apply_all(&ops).await;
                h.heal().await;

                let pending = h.state.pending_push_count().await.expect("pending");
                assert_eq!(
                    pending,
                    0,
                    "pending work never drained for {ops:?}\n{}",
                    h.dump().await
                );
                assert!(
                    h.state
                        .store
                        .pending_moves()
                        .await
                        .expect("moves")
                        .is_empty(),
                    "move intents left over for {ops:?}\n{}",
                    h.dump().await
                );
                assert!(
                    h.state
                        .store
                        .inflight_creates()
                        .await
                        .expect("inflight")
                        .is_empty(),
                    "in-flight markers left over for {ops:?}\n{}",
                    h.dump().await
                );
            });
        });
    }

    /// CONVERGENCE: once everything is pushed and pulled, the local cache and
    /// the server hold the same tasks with the same fields — same ids, parents,
    /// titles, due dates and completion.
    #[test]
    fn prop_local_converges_with_server() {
        check(DEFAULT_CASES, any_ops(), |ops| {
            run_case(|| async move {
                let mut h = Harness::new().await;
                h.apply_all(&ops).await;
                h.heal().await;
                assert_converged(&h, &format!("after {ops:?}")).await;
                assert_parent_integrity(&h, "after convergence").await;
            });
        });
    }

    /// IDEMPOTENCY: a sync run made after the fixpoint is a genuine no-op — it
    /// reports nothing and leaves the store byte-for-byte identical, sync
    /// metadata included. (A partial or failed run before it changes nothing
    /// about that: the recovery runs absorb it.)
    #[test]
    fn prop_sync_after_fixpoint_is_a_no_op() {
        check(DEFAULT_CASES, any_ops(), |ops| {
            run_case(|| async move {
                let mut h = Harness::new().await;
                h.apply_all(&ops).await;
                h.heal().await;

                let before = h.dump().await;
                let out = h.state.run_sync().await.expect("extra sync");
                assert!(
                    is_noop(&out),
                    "extra run was not a no-op ({out:?}) for {ops:?}\n{before}"
                );
                assert_eq!(
                    before,
                    h.dump().await,
                    "extra run mutated the store for {ops:?}"
                );
            });
        });
    }

    /// DEFERRAL SAFETY: while the panel holds a task, that ONE create waits —
    /// but nothing else does, and every held change completes once the hold is
    /// released. This is the shipped-bug class: work parked behind a hold that
    /// never resumes.
    #[test]
    fn prop_held_work_completes_once_the_hold_clears() {
        check(DEFAULT_CASES, any_ops(), |ops| {
            run_case(|| async move {
                let mut h = Harness::new().await;
                h.apply_all(&ops).await;

                // End the sequence mid-edit: open the panel on a live task,
                // add work behind it, and sync repeatedly with the hold up.
                let live = h.live().await;
                // Hold a TOP-LEVEL row: a subtask can legitimately vanish
                // mid-hold when its parent's pending delete pushes and cascades
                // (deletes beat holds, by design), which says nothing about the
                // hold itself.
                let held = live.iter().find(|t| t.task.parent.is_none()).cloned();
                if let Some(t) = &held {
                    h.state.set_editing_task(Some(t.task.id.clone()));
                }
                h.client.clear_faults();
                // A brand-new TOP-LEVEL task: it is not the held row, and it
                // has no parent that could legitimately delay it.
                h.apply(Op::CreateTop).await;
                let behind_hold = h.names.last().cloned().expect("created a task");
                // Plus a subtask, which may land under the held row and then
                // legitimately waits for its parent's id.
                h.apply(Op::CreateSub(0)).await;
                for _ in 0..3 {
                    h.state.run_sync().await.expect("held sync");
                }

                let server_titles: HashSet<String> = h
                    .server_tasks(LIST)
                    .await
                    .into_iter()
                    .map(|t| t.title)
                    .collect();
                // The hold defers exactly ONE create, never the rest.
                assert!(
                    server_titles.contains(&behind_hold),
                    "a create behind the hold never pushed ({behind_hold}) for {ops:?}\n{}",
                    h.dump().await
                );
                // ...and it really does defer that one: a held row whose create
                // has not completed still carries its ORIGINAL local id and its
                // pending create. (The hold exists to keep that id valid for
                // the open panel, so the id — not the server — is the thing to
                // check: a crashed earlier attempt may already have left the
                // task on the server.)
                // Only a genuinely UNPUSHED create is subject to the hold. A
                // clean row can carry a null etag too (pull detaches a child
                // whose parent it hasn't seen yet), and that is not held work.
                if let Some(t) = &held
                    && t.sync_state == SyncState::Dirty
                    && t.pending_op.as_deref() == Some("create")
                {
                    let now = h
                        .state
                        .store
                        .find_task_any(&t.task.id)
                        .await
                        .expect("find held");
                    assert!(
                        now.as_ref()
                            .is_some_and(|r| r.task.etag.is_none()
                                && r.pending_op.as_deref() == Some("create")),
                        "the held create was completed/remapped mid-edit ({}) for {ops:?}\nheld before={t:?}\nheld now={now:?}\n{}",
                        t.task.title,
                        h.dump().await
                    );
                }

                // Release: everything the hold deferred must complete.
                h.heal().await;
                assert_eq!(
                    h.state.pending_push_count().await.expect("pending"),
                    0,
                    "held work never completed for {ops:?}\n{}",
                    h.dump().await
                );
                assert_converged(&h, &format!("after releasing hold, {ops:?}")).await;
            });
        });
    }

    /// CRASH SAFETY: inserts whose response is lost after the server committed
    /// them — repeatedly, with nesting, so several in-flight markers can be
    /// open at once — must never leave a duplicate. Every title exists exactly
    /// once locally and exactly once on the server.
    #[test]
    fn prop_crashed_creates_never_duplicate() {
        check(DEFAULT_CASES, crash_ops(), |ops| {
            run_case(|| async move {
                let mut h = Harness::new().await;
                h.apply_all(&ops).await;
                h.heal().await;

                let expected: HashSet<String> = h.names.iter().cloned().collect();
                let mut server: Vec<String> = h
                    .server_tasks(LIST)
                    .await
                    .into_iter()
                    .map(|t| t.title)
                    .collect();
                server.sort();
                let mut local: Vec<String> = h
                    .state
                    .store
                    .list_tasks(LIST)
                    .await
                    .expect("list_tasks")
                    .into_iter()
                    .map(|t| t.task.title)
                    .collect();
                local.sort();

                let mut want: Vec<String> = expected.into_iter().collect();
                want.sort();
                assert_eq!(
                    server,
                    want,
                    "server task set wrong after crashes for {ops:?}\n{}",
                    h.dump().await
                );
                assert_eq!(
                    local,
                    want,
                    "local task set wrong after crashes for {ops:?}\n{}",
                    h.dump().await
                );
                assert_parent_integrity(&h, "after crash recovery").await;
            });
        });
    }

    /// PARENT INTEGRITY: pulls that arrive in pages, with a page dropped
    /// mid-scroll, can hand the engine a child before its parent. It may detach
    /// such a row, but it must never leave a dangling parent pointer, and once
    /// a complete pull lands the child is re-linked to exactly the parent the
    /// server says it has.
    #[test]
    fn prop_parent_integrity_under_paged_and_partial_pulls() {
        check(DEFAULT_CASES, any_ops(), |ops| {
            run_case(|| async move {
                let mut h = Harness::new().await;
                // Small pages + a dropped page force the detach/relink path.
                h.client.set_page_size(2);
                h.apply_all(&ops).await;
                h.client
                    .fail_list_tasks_page(1, || ApiError::Server { status: 503 });
                let _ = h.state.run_sync().await.expect("partial pull");
                assert_parent_integrity(&h, "immediately after a partial pull").await;

                h.heal().await;
                assert_parent_integrity(&h, "after a complete pull").await;
                assert_no_stranded_children(&h, "after a complete pull").await;
                assert_converged(&h, &format!("parent relink, {ops:?}")).await;
            });
        });
    }
}
