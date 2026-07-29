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
//! ## Operation vocabulary (RFC-009 §J, #113)
//!
//! The generator covers the WHOLE conflict matrix, not just the create/edit
//! /delete core the suite started with. Every family in RFC-009 has at least
//! one op, on both sides of the wire:
//!
//!  * §B/§C edit + complete — `Rename`, `SetDue`, `Toggle`, and their remote
//!    twins `RemoteEdit` / `RemoteComplete` (another device, no `If-Match`),
//!    which is what actually manufactures the `412` conflict path.
//!  * §D delete — `Delete`, plus `RemoteDelete`, whose server-side CASCADE to
//!    subtasks (verified live, #106) is the remote cascade §J names.
//!  * §E/§F reorder, demote, promote — `Reorder`, plus explicit `Demote` /
//!    `Promote` ops. `MoveAfter` reaches reparenting only by accident (it
//!    needs to draw a subtask as the anchor); the explicit ops make the §F
//!    family a first-class citizen of every sequence.
//!  * §G create — `CreateTop`, `CreateSub`, `RemoteCreate` (§A pull mirror).
//!  * §H cross-list move — `MoveToList`, over lists the sequence itself
//!    created. Ids are re-created by the move (invariant #4), so the panel
//!    hold is re-pointed exactly as the UI re-points it.
//!  * §I list ops — `CreateList`, `RenameList`, `DeleteList` and the remote
//!    `RemoteRenameList` / `RemoteDeleteList`, the latter driving the P2/D2
//!    re-homing of rows the server has never seen.
//!
//! The harness is therefore MULTI-LIST: tasks are addressed by title across
//! every list, and the invariants are asserted over the whole store rather
//! than over one working list.
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
//!  * lists are ordered by TITLE for the same reason — a list id is either
//!    server-assigned or a random UUID, so an id order would send the same op
//!    sequence to different lists on different runs.
//!
//! `AXIOTASK_PROPTEST_CASES` raises the depth for a soak. The seed is fixed,
//! so a deeper run explores a strict SUPERSET: 1024 and 4096 each found a bug
//! 256 does not reach (see RFC-009 §J), which makes a soak worth running
//! before any change to push ordering or crash recovery.

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};
    use std::fmt::Write as _;
    use std::sync::Arc;

    use axiotask_core::api::in_memory::Method;
    use axiotask_core::api::{ApiError, GoogleTasksClient, InMemoryClient};
    use axiotask_core::model::{NewTask, Task, TaskPatch, TaskStatus};
    use axiotask_core::store::{StoredTask, StoredTaskList, SyncState};
    use axiotask_core::sync::SyncOutcome;
    use proptest::prelude::*;
    use proptest::test_runner::{Config, RngAlgorithm, TestRng, TestRunner};

    use crate::state::AppState;

    /// The list the harness starts from. Seeded on the server, so its id is
    /// stable across the whole run (no list-create remap to chase). Sequences
    /// create, rename and delete further lists around it.
    const LIST: &str = "L1";

    /// Upper bound on the recovery runs a fixpoint may take. Each healthy run
    /// makes progress (push a batch, adopt an orphan, backfill a web view
    /// link), so a sequence that still hasn't settled after this many runs is
    /// not "slow" — it is stuck, which is exactly what these tests hunt for.
    const MAX_HEAL_RUNS: usize = 16;

    /// Upper bound on the ROUNDS a two-device fixpoint may take, where a round
    /// drains device A to its own fixpoint and then device B. Each round after
    /// the first can only exist because the previous round's drain changed the
    /// server in a way the other device must still pull (a conflict fork, a D7
    /// flatten repair). A correct engine settles that hand-off in a couple of
    /// rounds; a system still churning after this many is not slow — it is a
    /// non-terminating reconcile, which is exactly what the dual soak hunts.
    const MAX_DUAL_ROUNDS: usize = 16;

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
        /// New top-level task in the i-th live list.
        CreateTop(u8),
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
        /// §F demote: tuck the i-th live task under the top-level sibling
        /// directly above it.
        Demote(u8),
        /// §F promote: lift the i-th live subtask back to top level, right
        /// after its former parent.
        Promote(u8),
        /// §H cross-list move: send the i-th live task (and its subtree) to
        /// the j-th other list. Every id in the subtree is re-created.
        MoveToList(u8, u8),
        /// §I: a new syncable list.
        CreateList,
        /// §I: rename the i-th live list.
        RenameList(u8),
        /// §I: delete the i-th live list, cascading to its tasks.
        DeleteList(u8),
        /// §B remote side: another device edits the i-th PUSHED task's notes.
        RemoteEdit(u8),
        /// §C remote side: another device ticks the i-th pushed task.
        RemoteComplete(u8),
        /// §D remote side: another device deletes the i-th pushed task. The
        /// server cascades to its subtasks (verified live, #106).
        RemoteDelete(u8),
        /// §A pull mirror: another device adds a task to the i-th pushed list.
        RemoteCreate(u8),
        /// §G/#145: another device creates a task whose CONTENT duplicates the
        /// i-th live SUBTASK of ours, but TOP-LEVEL — a different parent
        /// identity. If our subtask is mid-flight, recovery must adopt only the
        /// orphan under OUR parent, never this same-content look-alike.
        RemoteCreateDup(u8),
        /// §F/§G residual: another device demotes the i-th pushed top-level
        /// task under a pushed top-level sibling on the SERVER. Google does not
        /// cap depth, so if that task already carries a subtask this lands a
        /// third level (`P > T > C`) no push-side guard can catch — the D7
        /// pull-side repair must flatten it.
        RemoteDemote(u8),
        /// §I remote side: another device renames the i-th pushed list (D6).
        RemoteRenameList(u8),
        /// §I remote side / P2: another device deletes the i-th pushed list.
        RemoteDeleteList(u8),
        /// Open the detail panel / inline editor on the i-th live task, which
        /// HOLDS that task's create push.
        OpenPanel(u8),
        /// Close the panel, releasing the hold.
        ClosePanel,
        /// A healthy sync run.
        Sync,
        /// A sync run with one transient fault armed (5xx / network drop).
        FlakySync(u8),
        /// A sync run where one mutating call commits server-side but its
        /// response is lost — the at-least-once hazard. The `u8` selects WHICH
        /// method (insert / patch / delete / move) loses its response, so the
        /// generalization covers a lost create (in-flight marker), a lost edit
        /// (self-content 412), a lost delete (retry 404s) and a lost move.
        CrashSync(u8),
        /// A sync run that dies FATALLY partway through the push (RFC-009
        /// P7/P8). An auth error aborts the whole run: `run_sync` returns
        /// `Err`, every push step after the failing call is skipped, and the
        /// pull never runs at all — the run is left partly applied. Unlike
        /// `FlakySync` (a transient just leaves one row dirty and the run still
        /// completes `Ok`), this is the abrupt-death crash window. The `u8`
        /// selects WHICH method takes the fatal error, which varies the abort
        /// point: a list/insert abort strands the task pushes queued behind it,
        /// while a patch/delete/move abort lands the earlier creates first — a
        /// genuine partial push. The heal + convergence oracles then prove the
        /// crash window drains with no duplicate and no loss.
        AbortSync(u8),
        /// Process death and relaunch over the SAME persisted store. The store
        /// survives (tombstoned deletes, dirty rows, in-flight-create markers),
        /// but everything in process memory dies: the panel's held create and
        /// the undo token the frontend was holding. The store alone must carry
        /// enough state to converge — an unpushed delete pushed EXACTLY once,
        /// the released create landed, no row resurrected.
        Restart,
    }

    /// Transient faults only: a permanent rejection would legitimately leave a
    /// row dirty forever, which is a different (already covered) behavior.
    const TRANSIENT: [(Method, fn() -> ApiError); 9] = [
        (Method::ListTasks, || ApiError::Server { status: 503 }),
        (Method::InsertTask, || ApiError::Network("reset".into())),
        (Method::PatchTask, || ApiError::Server { status: 500 }),
        (Method::DeleteTask, || ApiError::Network("timeout".into())),
        (Method::MoveTask, || ApiError::RateLimited),
        (Method::ListTaskLists, || ApiError::Server { status: 502 }),
        // §I list ops fail transiently too, and a half-pushed list is the
        // state the create/rename/delete rows have to survive.
        (Method::InsertTaskList, || ApiError::Network("reset".into())),
        (Method::PatchTaskList, || ApiError::Server { status: 500 }),
        (Method::DeleteTaskList, || ApiError::RateLimited),
    ];

    const DATE_MOVES: [&str; 5] = ["Today", "Tomorrow", "NextWeek", "NextMonth", "Clear"];

    // ─── Harness ─────────────────────────────────────────────────────────────

    /// A whole app instance: real store, real sync engine, fake Google.
    struct Harness {
        client: Arc<InMemoryClient>,
        state: Arc<AppState>,
        /// Every task this harness created, in creation order, identified by
        /// its CURRENT title. Titles are unique per harness, so this is a
        /// stable handle that survives the local→server id remap AND the
        /// wholesale id re-creation of a cross-list move (invariant #4).
        names: Vec<String>,
        next_name: u32,
        /// The task id the detail panel currently holds, mirrored so a
        /// cross-list move can re-point it the way the UI does.
        held: Option<String>,
        /// Prefix stamped onto every title and list-title this engine mints.
        /// Empty for a lone engine (so the single-engine suite keeps its
        /// `t001`/`L001` handles verbatim). The dual harness gives its two
        /// engines DISTINCT namespaces so their handles never collide on the
        /// one shared server they both push to.
        namespace: &'static str,
    }

    impl Harness {
        async fn new() -> Self {
            let client = Arc::new(InMemoryClient::new());
            client.seed_list(LIST, "Inbox");
            Self::on_shared_client(client, "").await
        }

        /// Build one engine over an ALREADY-SEEDED shared client, tagging its
        /// handles with `namespace`. The dual harness builds two of these on
        /// one client; a lone engine passes `""`.
        async fn on_shared_client(client: Arc<InMemoryClient>, namespace: &'static str) -> Self {
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
                held: None,
                namespace,
            }
        }

        fn fresh_name(&mut self) -> String {
            self.next_name += 1;
            format!("{}t{:03}", self.namespace, self.next_name)
        }

        /// A list title. Distinct namespace from task titles so a list can
        /// never shadow a task handle.
        fn fresh_list_name(&mut self) -> String {
            self.next_name += 1;
            format!("{}L{:03}", self.namespace, self.next_name)
        }

        /// Set (or clear) the panel hold, keeping the harness's mirror of it
        /// in step so a cross-list move can re-point instead of stranding it.
        fn hold(&mut self, id: Option<String>) {
            self.state.set_editing_task(id.clone());
            self.held = id;
        }

        /// Lists an op may target, in a deterministic order. Sorted by TITLE:
        /// list ids are server-assigned or random UUIDs, so ordering by id
        /// would make the same op sequence touch different lists on different
        /// runs. Titles are unique per harness and every rename is itself a
        /// deterministic op, so this order is reproducible.
        ///
        /// Local-only lists are excluded — they never sync, so a task placed
        /// in one could never converge, which says nothing about sync.
        async fn lists(&self) -> Vec<StoredTaskList> {
            let mut ls: Vec<StoredTaskList> = self
                .state
                .store
                .all_lists()
                .await
                .expect("lists")
                .into_iter()
                .filter(|l| !l.local_only && l.sync_state != SyncState::Deleted)
                .collect();
            ls.sort_by(|a, b| a.list.title.cmp(&b.list.title));
            ls
        }

        /// Every task row across every list, keyed by title.
        async fn all_rows(&self) -> Vec<StoredTask> {
            let mut out = Vec::new();
            for l in self.state.store.all_lists().await.expect("lists") {
                out.extend(
                    self.state
                        .store
                        .list_tasks(&l.list.id)
                        .await
                        .expect("list_tasks"),
                );
            }
            out
        }

        /// Live tasks in harness creation order, ACROSS EVERY LIST — a task
        /// that moved lists is the same logical task and keeps its handle. A
        /// task the store no longer holds (deleted, cascade-deleted with its
        /// parent, or gone with its list) simply drops out.
        async fn live(&self) -> Vec<StoredTask> {
            let rows = self.all_rows().await;
            let by_title: HashMap<&str, &StoredTask> =
                rows.iter().map(|r| (r.task.title.as_str(), r)).collect();
            self.names
                .iter()
                .filter_map(|n| by_title.get(n.as_str()).map(|r| (*r).clone()))
                .collect()
        }

        /// Live tasks that the server has actually seen — the only ones a
        /// "another device did X" op can touch.
        async fn pushed(&self) -> Vec<StoredTask> {
            self.live()
                .await
                .into_iter()
                .filter(|t| t.task.etag.is_some() && t.sync_state != SyncState::Deleted)
                .collect()
        }

        /// Lists the server has actually seen.
        async fn pushed_lists(&self) -> Vec<StoredTaskList> {
            self.lists()
                .await
                .into_iter()
                .filter(|l| l.list.etag.is_some())
                .collect()
        }

        /// Create a top-level task in a named list; returns its title, which
        /// is the handle every later op addresses it by.
        async fn create_top_in(&mut self, list_id: &str) -> String {
            let title = self.fresh_name();
            crate::commands::create_task_inner(
                &self.state,
                list_id.to_string(),
                None,
                title.clone(),
            )
            .await
            .expect("create");
            self.names.push(title.clone());
            title
        }

        /// Whether `id` has any child anywhere in the store.
        async fn has_children(&self, id: &str) -> bool {
            self.all_rows()
                .await
                .iter()
                .any(|r| r.task.parent.as_deref() == Some(id))
        }

        // One arm per operation: splitting the dispatcher would scatter the
        // model without making any arm easier to read.
        #[allow(clippy::too_many_lines)]
        async fn apply(&mut self, op: Op) {
            match op {
                Op::CreateTop(i) => {
                    let lists = self.lists().await;
                    let Some(list) = pick(&lists, i) else { return };
                    let list_id = list.list.id.clone();
                    self.create_top_in(&list_id).await;
                }
                Op::CreateSub(i) => {
                    let live = self.live().await;
                    let tops: Vec<_> = live.iter().filter(|t| t.task.parent.is_none()).collect();
                    let Some(parent) = pick(&tops, i) else { return };
                    // A subtask belongs to its parent's list, whichever list a
                    // cross-list move has since put the parent in.
                    let (list_id, parent_id) = (parent.list_id.clone(), parent.task.id.clone());
                    let title = self.fresh_name();
                    crate::commands::create_task_inner(
                        &self.state,
                        list_id,
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
                    self.hold(None);
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
                    if t.task.id == anchor.task.id || t.list_id != anchor.list_id {
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
                Op::Demote(i) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    // Only a childless top-level row can be demoted: anything
                    // else would nest a third level, which the command refuses
                    // (invariant #1, §F).
                    if t.task.parent.is_some() || self.has_children(&t.task.id).await {
                        return;
                    }
                    let rows = self
                        .state
                        .store
                        .list_tasks(&t.list_id)
                        .await
                        .expect("list_tasks");
                    let tops: Vec<&StoredTask> =
                        rows.iter().filter(|r| r.task.parent.is_none()).collect();
                    let Some(here) = tops.iter().position(|r| r.task.id == t.task.id) else {
                        return;
                    };
                    let Some(parent) = here.checked_sub(1).map(|k| tops[k]) else {
                        return; // already the first row: nothing above to tuck under
                    };
                    crate::commands::move_task_inner(
                        &self.state,
                        t.task.id.clone(),
                        Some(parent.task.id.clone()),
                        None,
                    )
                    .await
                    .expect("demote");
                }
                Op::Promote(i) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    let Some(parent_id) = t.task.parent.clone() else {
                        return; // already top level
                    };
                    // Lands directly after its former parent, which is where
                    // the keyboard promote puts it.
                    crate::commands::move_task_inner(
                        &self.state,
                        t.task.id.clone(),
                        None,
                        Some(parent_id),
                    )
                    .await
                    .expect("promote");
                }
                Op::MoveToList(i, j) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    let targets: Vec<StoredTaskList> = self
                        .lists()
                        .await
                        .into_iter()
                        .filter(|l| l.list.id != t.list_id)
                        .collect();
                    let Some(target) = pick(&targets, j) else {
                        return;
                    };
                    let new_root = self
                        .state
                        .move_task_to_list(&t.task.id, &target.list.id)
                        .await
                        .expect("move_to_list");
                    // The move re-creates every id in the subtree (invariant
                    // #4). The UI re-points the open panel at the new root and
                    // closes it if the held row was a descendant; mirror both.
                    if self.held.as_deref() == Some(t.task.id.as_str()) {
                        self.hold(Some(new_root));
                    } else if let Some(h) = self.held.clone()
                        && self
                            .state
                            .store
                            .find_task_any(&h)
                            .await
                            .expect("find held")
                            .is_none()
                    {
                        self.hold(None);
                    }
                }
                Op::CreateList => {
                    let title = self.fresh_list_name();
                    self.state
                        .create_list(&title, false)
                        .await
                        .expect("create_list");
                }
                Op::RenameList(i) => {
                    let lists = self.lists().await;
                    let Some(l) = pick(&lists, i) else { return };
                    let id = l.list.id.clone();
                    let title = self.fresh_list_name();
                    self.state.rename_list(&id, &title).await.expect("rename");
                }
                Op::DeleteList(i) => {
                    let lists = self.lists().await;
                    // Keep at least one syncable list standing: with none left
                    // every later op is a no-op, which explores nothing.
                    if lists.len() < 2 {
                        return;
                    }
                    let Some(l) = pick(&lists, i) else { return };
                    let id = l.list.id.clone();
                    // The panel cannot survive a list that took its row.
                    self.hold(None);
                    self.state.delete_list(&id).await.expect("delete_list");
                }
                Op::RemoteEdit(i) => {
                    let pushed = self.pushed().await;
                    let Some(t) = pick(&pushed, i) else { return };
                    let (list_id, id) = (t.list_id.clone(), t.task.id.clone());
                    let note = self.fresh_name();
                    // No `If-Match`: another device's edit always lands, and
                    // OUR next push is the one that meets the 412 (§B).
                    let _ = self
                        .client
                        .patch_task(
                            &list_id,
                            &id,
                            TaskPatch {
                                notes: Some(note),
                                ..TaskPatch::default()
                            },
                            None,
                        )
                        .await;
                }
                Op::RemoteComplete(i) => {
                    let pushed = self.pushed().await;
                    let Some(t) = pick(&pushed, i) else { return };
                    let status = if t.task.status == TaskStatus::Completed {
                        TaskStatus::NeedsAction
                    } else {
                        TaskStatus::Completed
                    };
                    let _ = self
                        .client
                        .patch_task(
                            &t.list_id,
                            &t.task.id,
                            TaskPatch {
                                status: Some(status),
                                ..TaskPatch::default()
                            },
                            None,
                        )
                        .await;
                }
                Op::RemoteDelete(i) => {
                    let pushed = self.pushed().await;
                    let Some(t) = pick(&pushed, i) else { return };
                    // Google cascades to subtasks on its side (#106 probe 5).
                    let _ = self.client.delete_task(&t.list_id, &t.task.id).await;
                }
                Op::RemoteCreate(i) => {
                    let lists = self.pushed_lists().await;
                    let Some(l) = pick(&lists, i) else { return };
                    let list_id = l.list.id.clone();
                    let title = self.fresh_name();
                    if self
                        .client
                        .insert_task(
                            &list_id,
                            NewTask {
                                title: title.clone(),
                                ..NewTask::default()
                            },
                        )
                        .await
                        .is_ok()
                    {
                        // A row we never created locally is still a row the
                        // pull must land, so it joins the handle list.
                        self.names.push(title);
                    }
                }
                Op::RemoteCreateDup(i) => {
                    // Reuse a live SUBTASK's current title as the foreign row's
                    // content and insert it TOP-LEVEL — a different parent
                    // identity than the subtask carries. When our subtask is
                    // mid-flight, the next recovery must NOT adopt this
                    // look-alike (#145). Untracked on purpose: it duplicates a
                    // title, so it can't join the title-keyed handle list;
                    // id-keyed convergence still covers it.
                    let live = self.live().await;
                    let subs: Vec<&StoredTask> =
                        live.iter().filter(|t| t.task.parent.is_some()).collect();
                    let Some(t) = pick(&subs, i) else { return };
                    let (list_id, title) = (t.list_id.clone(), t.task.title.clone());
                    let _ = self
                        .client
                        .insert_task(
                            &list_id,
                            NewTask {
                                title,
                                ..NewTask::default()
                            },
                        )
                        .await;
                }
                Op::RemoteDemote(i) => {
                    // Another device demotes a pushed top-level task under a
                    // pushed top-level sibling on the server. If the task
                    // already has a subtask, this makes the server hold a third
                    // level — the exact §F/§G residual D7 repairs on the pull.
                    let pushed = self.pushed().await;
                    let Some(t) = pick(&pushed, i) else { return };
                    if t.task.parent.is_some() {
                        return; // only a top-level row can be demoted here
                    }
                    // A different pushed top-level row in the same list. Both
                    // ends are top-level, so the reparent can never form a
                    // cycle. No `If-Match`: another device's move always lands.
                    let siblings: Vec<&StoredTask> = pushed
                        .iter()
                        .filter(|r| {
                            r.list_id == t.list_id
                                && r.task.parent.is_none()
                                && r.task.id != t.task.id
                        })
                        .collect();
                    let Some(parent) = pick(&siblings, i) else {
                        return;
                    };
                    let _ = self
                        .client
                        .move_task(&t.list_id, &t.task.id, Some(&parent.task.id), None)
                        .await;
                }
                Op::RemoteRenameList(i) => {
                    let lists = self.pushed_lists().await;
                    let Some(l) = pick(&lists, i) else { return };
                    let id = l.list.id.clone();
                    let title = self.fresh_list_name();
                    let _ = self.client.patch_tasklist(&id, &title).await;
                }
                Op::RemoteDeleteList(i) => {
                    let lists = self.pushed_lists().await;
                    if self.lists().await.len() < 2 {
                        return;
                    }
                    let Some(l) = pick(&lists, i) else { return };
                    let _ = self.client.delete_tasklist(&l.list.id).await;
                }
                Op::OpenPanel(i) => {
                    let live = self.live().await;
                    let Some(t) = pick(&live, i) else {
                        return;
                    };
                    let id = t.task.id.clone();
                    self.hold(Some(id));
                }
                Op::ClosePanel => self.hold(None),
                Op::Sync => {
                    self.state.run_sync().await.expect("sync");
                }
                Op::FlakySync(k) => {
                    let (m, e) = TRANSIENT[k as usize % TRANSIENT.len()];
                    self.client.fail_next(m, e);
                    self.state.run_sync().await.expect("flaky sync");
                }
                Op::CrashSync(k) => {
                    // Lose the response of ONE mutating call after the server
                    // commits it — the at-least-once hazard, generalized past
                    // inserts to edits, deletes and moves. The next run must
                    // reconverge with no duplicate and no lost edit.
                    const LOST: [Method; 4] = [
                        Method::InsertTask,
                        Method::PatchTask,
                        Method::DeleteTask,
                        Method::MoveTask,
                    ];
                    self.client
                        .commit_then_fail_next(LOST[k as usize % LOST.len()]);
                    self.state.run_sync().await.expect("crash sync");
                }
                Op::AbortSync(k) => {
                    // A FATAL error mid-push: an auth failure is classified
                    // `Abort` on every push path, so it propagates out of the
                    // engine and `run_sync` returns `Err`. The run is left
                    // partly applied — steps before the failing call committed,
                    // everything after (including the whole pull) did not — so
                    // the harness must TOLERATE the error rather than
                    // `.expect()` it (that is exactly the state being tested).
                    const FATAL: [Method; 5] = [
                        Method::InsertTask,
                        Method::PatchTask,
                        Method::DeleteTask,
                        Method::MoveTask,
                        Method::PatchTaskList,
                    ];
                    self.client
                        .fail_next(FATAL[k as usize % FATAL.len()], || ApiError::Unauthorized);
                    let _ = self.state.run_sync().await;
                    // The fatal condition lasts one run (a token refresh or a
                    // restart clears it). A run that never called the armed
                    // method leaves the fault queued; disarm it so it can't
                    // fire — and abort — a later op that DOES `.expect()`.
                    self.client.clear_faults();
                }
                Op::Restart => {
                    // Relaunch over the same store. The held create and any
                    // undo token die with the process; the store's pending
                    // work (tombstones, dirty rows, in-flight markers) is all
                    // that survives to drive convergence.
                    self.state = Arc::new(self.state.simulate_restart());
                    self.held = None;
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
        async fn heal(&mut self) -> usize {
            self.client.clear_faults();
            self.hold(None);
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

    // ─── Dual harness: two devices, one server ───────────────────────────────

    /// Which of the two devices an op is aimed at.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Side {
        A,
        B,
    }

    impl Side {
        fn other(self) -> Side {
            match self {
                Side::A => Side::B,
                Side::B => Side::A,
            }
        }
    }

    /// One step of a two-device interleaving.
    #[derive(Debug, Clone)]
    enum DualOp {
        /// The interleaved RUN LOOP: apply a single op to one device. Syncs are
        /// ordinary `Op::Sync`/`FlakySync`/`CrashSync` values, so the two
        /// devices' pushes and pulls land against the one shared server in
        /// whatever order the generator drew — the interleaving nobody writes
        /// down by hand.
        Step(Side, Op),
        /// An OFFLINE BATCH: one device goes offline and applies a run of local
        /// mutations WITH NO SYNC OF ITS OWN, while the OTHER device stays
        /// online and syncs after each edit — so the server advances underneath
        /// the offline one. The batch is reconciled only when a later
        /// `Step(side, Op::Sync)` or the final `heal` reconnects the device,
        /// which is where the two divergent histories merge (the classic
        /// two-devices-edited-offline crossing).
        Offline(Side, Vec<Op>),
    }

    /// Two whole app instances — separate stores and sync engines — pushing to
    /// and pulling from ONE shared fake Google. The invariant that makes the
    /// n:1 oracle sound: whatever the server converges to, BOTH devices pull
    /// it, so a correct pair each mirrors the server exactly. The only way
    /// `dump A == dump B == server` can break is a REAL engine bug — a device
    /// that believes it is clean while diverging from the server (a dropped
    /// pull, a phantom local row, a row wedged dirty that never drains).
    struct DualHarness {
        a: Harness,
        b: Harness,
    }

    impl DualHarness {
        async fn new() -> Self {
            let client = Arc::new(InMemoryClient::new());
            client.seed_list(LIST, "Inbox");
            // Build A first, so its bootstrap "My Tasks" reaches the server;
            // B then ADOPTS that list by title on its own first pull instead
            // of forking a duplicate (`adoptable_list`, reconcile.rs). Distinct
            // namespaces keep every task and list handle disjoint across the
            // two devices sharing this one server. `a.client` and `b.client`
            // are this same shared handle.
            let a = Harness::on_shared_client(client.clone(), "a").await;
            let b = Harness::on_shared_client(client.clone(), "b").await;
            Self { a, b }
        }

        fn side(&mut self, s: Side) -> &mut Harness {
            match s {
                Side::A => &mut self.a,
                Side::B => &mut self.b,
            }
        }

        async fn apply(&mut self, dop: &DualOp) {
            match dop {
                DualOp::Step(s, op) => self.side(*s).apply(*op).await,
                DualOp::Offline(s, batch) => {
                    for op in batch {
                        self.side(*s).apply(*op).await;
                        // The other device stays online, advancing the server
                        // underneath the offline one. Tolerate any fault an op
                        // left armed on the shared client (a transient leaves
                        // the run `Ok`; a stray fatal is cleared at heal).
                        let other = s.other();
                        let _ = self.side(other).state.run_sync().await;
                    }
                }
            }
        }

        async fn apply_all(&mut self, ops: &[DualOp]) {
            for op in ops {
                self.apply(op).await;
            }
        }

        /// Drive both devices to a shared fixpoint. Each round drains A to its
        /// own fixpoint (`Harness::heal`), then B; when a round finds BOTH
        /// already drained — each device's first run a no-op — no pending work
        /// remains on either side and neither changed the server, so the server
        /// and both caches agree. `Harness::heal` clears faults and drops holds
        /// on each device first.
        async fn heal(&mut self) {
            for _round in 0..MAX_DUAL_ROUNDS {
                let ra = self.a.heal().await;
                let rb = self.b.heal().await;
                if ra == 1 && rb == 1 {
                    return;
                }
            }
            panic!(
                "no two-device fixpoint after {MAX_DUAL_ROUNDS} rounds\n== A ==\n{}\n== B ==\n{}",
                self.a.dump().await,
                self.b.dump().await
            );
        }
    }

    /// The n:1 FIXPOINT ORACLE: after a shared fixpoint, each device's cache
    /// equals the server field-for-field — and therefore each other. A device
    /// that dropped a pull, kept a phantom row, or wedged a row dirty shows up
    /// here as a set that differs from the server the other device agrees with.
    async fn assert_dual_converged(d: &DualHarness, ctx: &str) {
        let server = d.a.server_rows().await;
        let a = d.a.local_rows().await;
        let b = d.b.local_rows().await;
        // a == server && b == server ⇒ a == b == server (the n:1 fixpoint).
        assert_eq!(
            a,
            server,
            "{ctx}: device A diverges from the server\n== A local ==\n{}\n== B local ==\n{}",
            d.a.dump().await,
            d.b.dump().await
        );
        assert_eq!(
            b,
            server,
            "{ctx}: device B diverges from the server\n== A local ==\n{}\n== B local ==\n{}",
            d.a.dump().await,
            d.b.dump().await
        );
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

    /// Schema invariant (schema.sql, RFC-009 §B, #134): a `clean` row carries no
    /// base snapshot. base_* is captured only while a row is dirty / a create is
    /// in flight, and cleared the moment the row agrees with the server again. A
    /// clean row with a lingering base would make a future 412 compare the
    /// refetched remote against stale content.
    ///
    /// #134 clears base on clean CREATE landings (`finish_create`, both the push
    /// and crash-adoption paths). #139 closed the remaining leak in the broader
    /// op mix: the 412 `ConflictedCopy` resolver lands the canonical row clean
    /// via a dirty→clean `upsert_task`, which now clears the base. So this is
    /// wired into BOTH the crash-recovery property AND the convergence/fixpoint
    /// soak (`prop_local_converges_with_server`) — a fixpoint over the full op
    /// mix must leave every clean row base-free.
    async fn assert_base_null_when_clean(h: &Harness, ctx: &str) {
        let dump = h.dump().await;
        for t in h.all_rows().await {
            if t.sync_state == SyncState::Clean {
                assert!(
                    h.state
                        .store
                        .base_snapshot(&t.task.id)
                        .await
                        .expect("base_snapshot")
                        .is_none(),
                    "{ctx}: clean task {} still carries a base snapshot\n{dump}",
                    t.task.id
                );
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
            6 => any::<u8>().prop_map(Op::CreateTop),
            4 => any::<u8>().prop_map(Op::CreateSub),
            3 => any::<u8>().prop_map(Op::Rename),
            3 => (any::<u8>(), any::<u8>()).prop_map(|(i, d)| Op::SetDue(i, d)),
            3 => any::<u8>().prop_map(Op::Toggle),
            2 => any::<u8>().prop_map(Op::Delete),
            2 => (any::<u8>(), any::<bool>()).prop_map(|(i, u)| Op::Reorder(i, u)),
            2 => (any::<u8>(), any::<u8>()).prop_map(|(i, j)| Op::MoveAfter(i, j)),
            2 => any::<u8>().prop_map(Op::Demote),
            2 => any::<u8>().prop_map(Op::Promote),
            2 => (any::<u8>(), any::<u8>()).prop_map(|(i, j)| Op::MoveToList(i, j)),
            2 => Just(Op::CreateList),
            1 => any::<u8>().prop_map(Op::RenameList),
            1 => any::<u8>().prop_map(Op::DeleteList),
            2 => any::<u8>().prop_map(Op::RemoteEdit),
            2 => any::<u8>().prop_map(Op::RemoteComplete),
            2 => any::<u8>().prop_map(Op::RemoteDelete),
            2 => any::<u8>().prop_map(Op::RemoteCreate),
            2 => any::<u8>().prop_map(Op::RemoteCreateDup),
            2 => any::<u8>().prop_map(Op::RemoteDemote),
            1 => any::<u8>().prop_map(Op::RemoteRenameList),
            1 => any::<u8>().prop_map(Op::RemoteDeleteList),
            2 => any::<u8>().prop_map(Op::OpenPanel),
            2 => Just(Op::ClosePanel),
            5 => Just(Op::Sync),
            3 => any::<u8>().prop_map(Op::FlakySync),
            1 => any::<u8>().prop_map(Op::CrashSync),
            1 => any::<u8>().prop_map(Op::AbortSync),
            1 => Just(Op::Restart),
        ]
    }

    fn any_ops() -> impl Strategy<Value = Vec<Op>> {
        prop::collection::vec(any_op(), 1..40)
    }

    /// Creates and subtask creates only, with crash-y syncs — the shape the
    /// crash-safety invariant is about. Cross-list moves join it because a
    /// move IS a create family (§H): the clone it inserts can crash mid-flight
    /// exactly like any other create, and a duplicate there is the same bug.
    ///
    /// Edits (`Rename`, `Toggle`, `SetDue`) are in the mix so the generator
    /// explores an edit made DURING the in-flight window (#122): with the base
    /// snapshot now recording the insert payload, orphan adoption matches on it
    /// and the edit survives as a pending update — no duplicate. Before #124
    /// this op family was deliberately kept out because it duplicated the task.
    ///
    /// The crash here is deliberately the LOST-INSERT one (`CrashSync(0)` →
    /// `Method::InsertTask`): this test's invariant is "a crashed create never
    /// duplicates", asserted as an exact title set. A lost PATCH is a different
    /// (also legitimate) shape — a divergent re-edit over a committed-but-lost
    /// edit forks a conflicted copy (P3), which is an EXTRA title by design and
    /// so is exercised in the general convergence properties (`any_ops`), not
    /// this create-duplication one.
    fn crash_ops() -> impl Strategy<Value = Vec<Op>> {
        prop::collection::vec(
            prop_oneof![
                5 => any::<u8>().prop_map(Op::CreateTop),
                5 => any::<u8>().prop_map(Op::CreateSub),
                3 => any::<u8>().prop_map(Op::Rename),
                2 => any::<u8>().prop_map(Op::Toggle),
                2 => (any::<u8>(), any::<u8>()).prop_map(|(i, d)| Op::SetDue(i, d)),
                2 => (any::<u8>(), any::<u8>()).prop_map(|(i, j)| Op::MoveToList(i, j)),
                1 => Just(Op::CreateList),
                3 => Just(Op::CrashSync(0)),
                2 => Just(Op::Sync),
                2 => any::<u8>().prop_map(Op::FlakySync),
            ],
            2..18,
        )
    }

    // ─── Dual strategies ─────────────────────────────────────────────────────

    fn side() -> impl Strategy<Value = Side> {
        prop_oneof![Just(Side::A), Just(Side::B)]
    }

    /// The LOCAL user vocabulary only — no `Sync`/`FlakySync`/`CrashSync`/
    /// `AbortSync`/`Restart`, and none of the `Remote*` phantom-device ops.
    /// An offline batch is one device editing its own cache with the wire
    /// down; a sync inside the batch would defeat the point, and a phantom
    /// remote hit would be a THIRD device, which the interleaved `Step` ops
    /// already supply. Weighted like `any_op`'s local core so batches build a
    /// real tree to mutate rather than churning empty indices.
    fn local_mutation_op() -> impl Strategy<Value = Op> {
        prop_oneof![
            6 => any::<u8>().prop_map(Op::CreateTop),
            4 => any::<u8>().prop_map(Op::CreateSub),
            3 => any::<u8>().prop_map(Op::Rename),
            3 => (any::<u8>(), any::<u8>()).prop_map(|(i, d)| Op::SetDue(i, d)),
            3 => any::<u8>().prop_map(Op::Toggle),
            2 => any::<u8>().prop_map(Op::Delete),
            2 => (any::<u8>(), any::<bool>()).prop_map(|(i, u)| Op::Reorder(i, u)),
            2 => (any::<u8>(), any::<u8>()).prop_map(|(i, j)| Op::MoveAfter(i, j)),
            2 => any::<u8>().prop_map(Op::Demote),
            2 => any::<u8>().prop_map(Op::Promote),
            2 => (any::<u8>(), any::<u8>()).prop_map(|(i, j)| Op::MoveToList(i, j)),
            2 => Just(Op::CreateList),
            1 => any::<u8>().prop_map(Op::RenameList),
            1 => any::<u8>().prop_map(Op::DeleteList),
            2 => any::<u8>().prop_map(Op::OpenPanel),
            2 => Just(Op::ClosePanel),
        ]
    }

    /// One dual step: mostly interleaved single ops on either device (`any_op`,
    /// so syncs, crashes and phantom-remote events are all in the mix on both
    /// sides), with a minority of offline batches on one device while the other
    /// stays live.
    fn dual_op() -> impl Strategy<Value = DualOp> {
        prop_oneof![
            8 => (side(), any_op()).prop_map(|(s, op)| DualOp::Step(s, op)),
            2 => (side(), prop::collection::vec(local_mutation_op(), 2..8))
                .prop_map(|(s, batch)| DualOp::Offline(s, batch)),
        ]
    }

    fn dual_ops() -> impl Strategy<Value = Vec<DualOp>> {
        prop::collection::vec(dual_op(), 1..24)
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
                assert_base_null_when_clean(&h, "after convergence").await;
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
                    let id = t.task.id.clone();
                    h.hold(Some(id));
                }
                h.client.clear_faults();
                // A brand-new TOP-LEVEL task in a list the server ALREADY
                // knows: it is not the held row, it has no parent that could
                // delay it, and no unpushed list create stands in front of it
                // either. (A list create is itself held while the panel is
                // open — a list-id remap moves the held row between lists — so
                // a task in a brand-new list is legitimately deferred as well.
                // That work is covered by the release assertions below.)
                let Some(pushed_list) = h.pushed_lists().await.first().cloned() else {
                    return;
                };
                let behind_hold = h.create_top_in(&pushed_list.list.id).await;
                // Plus a subtask, which may land under the held row and then
                // legitimately waits for its parent's id.
                h.apply(Op::CreateSub(0)).await;
                for _ in 0..3 {
                    h.state.run_sync().await.expect("held sync");
                }

                // Across every list: a sequence may have moved the working
                // list's contents elsewhere, or deleted it outright.
                let server_titles: HashSet<String> =
                    h.server_rows().await.into_iter().map(|r| r.title).collect();
                // The hold defers exactly ONE create, never the rest — unless
                // the row's own LIST is still unpushed, which parks it behind
                // the same hold for a legitimate reason (a list create is held
                // too: remapping a list id moves the held row between lists).
                // A remote list delete can demote a pushed list back to an
                // unpushed create mid-run, so this is re-checked here rather
                // than assumed from the snapshot taken above. Nothing is lost
                // either way — the release assertions below prove it.
                let lists_now = h.lists().await;
                let blocked_by_its_list = h
                    .live()
                    .await
                    .into_iter()
                    .find(|t| t.task.title == behind_hold)
                    .is_some_and(|r| {
                        lists_now
                            .iter()
                            .any(|l| l.list.id == r.list_id && l.list.etag.is_none())
                    });
                assert!(
                    blocked_by_its_list || server_titles.contains(&behind_hold),
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
                // Every list: a cross-list move re-creates the task under a
                // new id in another list, and a duplicate would hide there.
                let mut server: Vec<String> =
                    h.server_rows().await.into_iter().map(|r| r.title).collect();
                server.sort();
                let mut local: Vec<String> = h
                    .all_rows()
                    .await
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
                assert_base_null_when_clean(&h, "after crash recovery").await;
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

    /// PARENT-IDENTITY ADOPTION (#145), end to end. A subtask create whose
    /// insert is LOST PRE-COMMIT (`FlakySync(1)` → `Method::InsertTask`
    /// transient, so nothing commits and the create stays in-flight) coincides
    /// with another device inserting an identical-content row TOP-LEVEL. The
    /// only remote look-alike at recovery is the foreign top-level row.
    ///
    /// This is deterministic, not a property, on purpose: after a mis-adoption
    /// the following pull heals local and server into AGREEMENT (our subtask is
    /// silently swallowed into the foreign row), so the convergence oracle
    /// cannot see the loss. The catchable signal is STRUCTURAL — our subtask
    /// must still exist under its own parent AND the foreign row must survive as
    /// its own top-level task. Before #145 adoption ignored parent identity and
    /// claimed the foreign row as ours, so exactly one of those two rows
    /// vanished. `RemoteCreateDup` also rides the general soak (`any_ops`) for
    /// breadth: duplicate content must flow through adoption and pull with no
    /// panic and no divergence.
    #[test]
    fn orphan_adoption_never_claims_a_foreign_parent() {
        run_case(|| async move {
            let mut h = Harness::new().await;
            // Two synced top-level parents in the same list.
            h.apply(Op::CreateTop(0)).await; // t001 = P1
            h.apply(Op::CreateTop(0)).await; // t002 = P2
            h.apply(Op::Sync).await;
            let p1_id = h
                .live()
                .await
                .into_iter()
                .find(|t| t.task.title == "t001")
                .expect("P1 pushed")
                .task
                .id;

            // A subtask under P1 whose insert is lost pre-commit → in-flight,
            // nothing committed server-side.
            h.apply(Op::CreateSub(0)).await; // t003 under P1
            h.apply(Op::FlakySync(1)).await; // its insert fails pre-commit
            // Another device inserts an identical-content row TOP-LEVEL.
            h.apply(Op::RemoteCreateDup(0)).await; // foreign top-level "t003"

            h.heal().await;

            let server = h.server_rows().await;
            let ours = server
                .iter()
                .filter(|r| r.title == "t003" && r.parent.as_deref() == Some(p1_id.as_str()))
                .count();
            let foreign = server
                .iter()
                .filter(|r| r.title == "t003" && r.parent.is_none())
                .count();
            assert_eq!(
                ours,
                1,
                "our subtask must land under P1, not be swallowed by the foreign row\n{}",
                h.dump().await
            );
            assert_eq!(
                foreign,
                1,
                "the foreign top-level look-alike must survive as its own row\n{}",
                h.dump().await
            );
            assert_converged(&h, "after #145 recovery").await;
            assert_parent_integrity(&h, "after #145 recovery").await;
        });
    }

    /// RESTART — HELD CREATE DIES WITH THE PROCESS. A create held by an open
    /// panel never pushes while the panel is up (its id must stay stable for
    /// the UI). But the panel lives only in process memory: when the process
    /// dies, so does the hold, and the surviving store row must push on its
    /// own. Deterministic on purpose — the interesting window (a create still
    /// unpushed at the instant of death) is a fixed shape, not a distribution.
    #[test]
    fn restart_drops_the_held_create_which_then_pushes() {
        run_case(|| async move {
            let mut h = Harness::new().await;
            h.apply(Op::CreateTop(0)).await; // t001: a fresh, unpushed create.
            h.apply(Op::OpenPanel(0)).await; // the panel now HOLDS its create.

            // A sync with the panel open leaves the held create unpushed: no
            // etag locally, absent on the server.
            h.state.run_sync().await.expect("held sync");
            let held = h
                .live()
                .await
                .into_iter()
                .find(|t| t.task.title == "t001")
                .expect("t001 live");
            assert!(
                held.task.etag.is_none(),
                "the held create must stay unpushed while the panel holds it\n{}",
                h.dump().await
            );
            assert!(
                !h.server_rows().await.iter().any(|r| r.title == "t001"),
                "the held create must not reach the server while the panel holds it\n{}",
                h.dump().await
            );

            // Process death: the panel and its hold vanish with the window.
            h.apply(Op::Restart).await;

            // Drive sync DIRECTLY — not `heal()`, which would itself drop the
            // hold — so the ONLY thing that can release this create is the
            // restart. If the hold survived the process, these runs push
            // nothing and the assertions below fail.
            for _ in 0..3 {
                h.state.run_sync().await.expect("post-restart sync");
            }
            assert!(
                h.server_rows().await.iter().any(|r| r.title == "t001"),
                "the once-held create must push after the restart drops the hold\n{}",
                h.dump().await
            );
            assert_eq!(
                h.state.pending_push_count().await.expect("pending"),
                0,
                "restart must leave no create parked behind a dead hold\n{}",
                h.dump().await
            );
            assert_converged(&h, "after restart releases the held create").await;
        });
    }

    /// RESTART — UNDO TOKEN DIES, DELETE PUSHES EXACTLY ONCE. Deleting a pushed
    /// task tombstones it locally and hands the frontend an undo token; the
    /// delete has not pushed yet. If the process dies here, the token (held only
    /// in the frontend) is gone — the delete can no longer be undone — but the
    /// persisted tombstone must still reach Google, exactly once, and the row
    /// must never come back. Non-happy path: the death lands in the delete's
    /// pending window, and the store alone has to carry it home.
    #[test]
    fn restart_kills_the_undo_token_and_pushes_the_delete_exactly_once() {
        run_case(|| async move {
            let mut h = Harness::new().await;
            h.apply(Op::CreateTop(0)).await; // t001
            h.apply(Op::Sync).await; // push it to the server.

            let t = h
                .pushed()
                .await
                .into_iter()
                .find(|t| t.task.title == "t001")
                .expect("t001 pushed");
            let id = t.task.id.clone();

            // Delete it: the command tombstones the row and returns an undo
            // token. The delete has NOT pushed — the server still holds t001.
            let token = crate::commands::delete_task_inner(&h.state, id.clone())
                .await
                .expect("delete");
            assert!(
                h.server_rows().await.iter().any(|r| r.id == id),
                "the server must still hold t001 before the delete pushes"
            );
            let deletes_before = h.client.call_count(Method::DeleteTask);

            // Process death: the undo token dies with the frontend. Model it
            // by dropping the token and never calling undo_delete.
            h.apply(Op::Restart).await;
            drop(token);

            // The surviving tombstone is all that drives the delete now.
            h.heal().await;

            // Exactly once: the drain issued a single successful DELETE.
            assert_eq!(
                h.client.call_count(Method::DeleteTask),
                deletes_before + 1,
                "the surviving tombstone must push its delete exactly once\n{}",
                h.dump().await
            );
            // Gone on the server AND locally — no resurrection, no stray row.
            assert!(
                !h.server_rows().await.iter().any(|r| r.id == id),
                "t001 must be deleted on the server after the restart\n{}",
                h.dump().await
            );
            assert!(
                h.state
                    .store
                    .find_task_any(&id)
                    .await
                    .expect("find")
                    .is_none(),
                "the local tombstone must be cleared once the delete pushes\n{}",
                h.dump().await
            );
            assert_converged(&h, "after restart pushes the delete").await;

            // And never again: a further run neither re-pushes nor resurrects.
            let out = h.state.run_sync().await.expect("extra sync");
            assert!(
                is_noop(&out),
                "a post-drain sync re-touched the deleted row: {out:?}\n{}",
                h.dump().await
            );
            assert_eq!(
                h.client.call_count(Method::DeleteTask),
                deletes_before + 1,
                "the delete must never push a second time"
            );
        });
    }

    // ─── Dual-engine invariants (#152) ───────────────────────────────────────

    /// TWO-DEVICE CONVERGENCE — the n:1 fixpoint. Two real app instances edit
    /// the SAME server over a random interleaving of per-device ops and offline
    /// batches. Once both drain and mutually pull to a shared fixpoint, each
    /// device's cache equals the server field-for-field — so `dump A == dump B
    /// == server`. This is the crossing the single-engine soak cannot see: a
    /// device that silently diverges from what ANOTHER device already agreed
    /// with the server on. Structural and metadata invariants (parent tree,
    /// `base_* NULL iff clean`, zero pending work) are asserted on BOTH devices.
    #[test]
    fn prop_dual_two_devices_converge_on_the_server() {
        check(DEFAULT_CASES, dual_ops(), |ops| {
            run_case(|| async move {
                let mut d = DualHarness::new().await;
                d.apply_all(&ops).await;
                d.heal().await;

                assert_dual_converged(&d, &format!("after {ops:?}")).await;
                // Neither device is left holding pending work once the shared
                // fixpoint is reached (P7/P8 — convergence in finite runs).
                for (name, h) in [("A", &d.a), ("B", &d.b)] {
                    assert_eq!(
                        h.state.pending_push_count().await.expect("pending"),
                        0,
                        "device {name} left pending work at the fixpoint for {ops:?}\n{}",
                        h.dump().await
                    );
                    assert_parent_integrity(h, &format!("device {name} after dual convergence"))
                        .await;
                    assert_base_null_when_clean(
                        h,
                        &format!("device {name} after dual convergence"),
                    )
                    .await;
                }

                // Idempotency at the shared fixpoint: one more run on either
                // device touches nothing (a second run against a quiescent
                // remote is a no-op).
                let extra_a = d.a.state.run_sync().await.expect("A extra");
                let extra_b = d.b.state.run_sync().await.expect("B extra");
                assert!(
                    is_noop(&extra_a) && is_noop(&extra_b),
                    "a run after the dual fixpoint was not a no-op (A={extra_a:?} B={extra_b:?}) for {ops:?}"
                );
            });
        });
    }

    /// TWO DEVICES EDIT THE SAME TASK OFFLINE, then both reconnect — the
    /// canonical crossing, pinned deterministically so the merge is exact and
    /// not left to the generator to stumble on. Device A and device B each
    /// rename the one shared task while the wire is down; when both sync, the
    /// engine resolves the 412 (last-writer's push meets a stale `If-Match`)
    /// and BOTH caches settle onto whatever the server holds. The oracle proves
    /// they agree; the count proves the resolution did not spawn an unbounded
    /// pile of conflicted copies.
    #[test]
    fn dual_two_devices_edit_the_same_task_offline_then_converge() {
        run_case(|| async move {
            let mut d = DualHarness::new().await;

            // A creates one task in the shared Inbox and pushes it; B pulls it,
            // so both devices now hold the same server row. A tracks the handle
            // (its own creation); the id is server-assigned after A's push.
            d.a.create_top_in(LIST).await; // "at001"
            d.a.state.run_sync().await.expect("A push");
            d.b.state.run_sync().await.expect("B pull");
            let shared_id =
                d.a.live()
                    .await
                    .into_iter()
                    .find(|t| t.task.title == "at001")
                    .expect("A pushed the shared task")
                    .task
                    .id
                    .clone();
            assert!(
                d.b.all_rows()
                    .await
                    .iter()
                    .any(|r| r.task.id == shared_id && r.task.title == "at001"),
                "B must have pulled the shared task before editing it\n{}",
                d.b.dump().await
            );

            // Both edit it OFFLINE (no sync): A sets a due date, B renames it.
            d.a.apply(Op::SetDue(0, 0)).await; // "Today" on A's copy
            crate::commands::rename_task_inner(&d.b.state, shared_id.clone(), "renamed".into())
                .await
                .expect("B rename");

            // Reconnect both and drive to the shared fixpoint.
            d.heal().await;

            assert_dual_converged(&d, "after both devices edited the same task offline").await;
            // The shared task still exists exactly once on the server — the
            // merge converged, it did not lose the row or fork it endlessly.
            let survivors =
                d.a.server_rows()
                    .await
                    .into_iter()
                    .filter(|r| r.id == shared_id)
                    .count();
            assert_eq!(
                survivors,
                1,
                "the shared task must survive the offline merge exactly once\n{}",
                d.a.dump().await
            );
        });
    }

    // ─── Dual-engine scenario pins (#153) ────────────────────────────────────

    /// The suffix the conflicted-copy resolver stamps onto the losing edit
    /// (`reconcile::conflicted_copy`). A server row carrying it is a forked
    /// copy; counting them is how termination is asserted.
    const CONFLICTED_SUFFIX: &str = " (conflicted copy)";

    /// TWO-SIDED CONFLICTED-COPY TERMINATION + AGREEMENT. Both devices rename
    /// the SAME shared task to DISTINCT titles while offline — a two-sided
    /// title divergence, the crossing that forces the 412 resolver to fork a
    /// "(conflicted copy)" rather than silently adopt one side (P3: nothing is
    /// discarded). The pin proves three things a lone-engine soak cannot see at
    /// once: (1) AGREEMENT — both caches and the server end field-for-field
    /// equal; (2) TERMINATION — the fork count settles at exactly ONE, the
    /// loser's edit, and does not breed copies-of-copies; (3) NO DATA LOSS —
    /// both renamed titles survive, one as the canonical row and one as the
    /// conflicted copy. Idempotency then proves the resolved state is a genuine
    /// fixpoint: another full round on either device neither forks again nor
    /// changes anything (P7/P8).
    #[test]
    fn dual_two_sided_conflicted_copy_terminates_and_agrees() {
        run_case(|| async move {
            let mut d = DualHarness::new().await;

            // A creates one task in the shared Inbox and pushes it; B pulls it,
            // so both devices hold the same server row under the same id.
            d.a.create_top_in(LIST).await; // "at001"
            d.a.state.run_sync().await.expect("A push");
            d.b.state.run_sync().await.expect("B pull");
            let shared_id =
                d.a.live()
                    .await
                    .into_iter()
                    .find(|t| t.task.title == "at001")
                    .expect("A pushed the shared task")
                    .task
                    .id
                    .clone();
            assert!(
                d.b.all_rows()
                    .await
                    .iter()
                    .any(|r| r.task.id == shared_id && r.task.title == "at001"),
                "B must have pulled the shared task before editing it\n{}",
                d.b.dump().await
            );

            // Both rename it OFFLINE to DISTINCT titles — a two-sided title
            // divergence. Whoever's push lands first wins the row; the other
            // meets a 412 and must fork its edit as a conflicted copy.
            crate::commands::rename_task_inner(&d.a.state, shared_id.clone(), "shared-A".into())
                .await
                .expect("A rename");
            crate::commands::rename_task_inner(&d.b.state, shared_id.clone(), "shared-B".into())
                .await
                .expect("B rename");

            // Reconnect both and drive to the shared fixpoint.
            d.heal().await;
            assert_dual_converged(&d, "after a two-sided offline title edit").await;

            // TERMINATION: exactly ONE conflicted copy on the server — the
            // resolver forked the loser once and stopped, it did not breed
            // copies of the copy.
            let server = d.a.server_rows().await;
            let copies: Vec<&Row> = server
                .iter()
                .filter(|r| r.title.ends_with(CONFLICTED_SUFFIX))
                .collect();
            assert_eq!(
                copies.len(),
                1,
                "expected exactly one conflicted copy, got {}\n{}",
                copies.len(),
                d.a.dump().await
            );

            // NO DATA LOSS (P3): both renamed titles survive — one as the
            // canonical row, one as the forked copy — regardless of which side
            // won the etag race. Compare the SET so the pin does not couple to
            // heal order.
            let copy_base = copies[0]
                .title
                .strip_suffix(CONFLICTED_SUFFIX)
                .expect("suffix present")
                .to_string();
            let canonical: HashSet<String> = server
                .iter()
                .filter(|r| !r.title.ends_with(CONFLICTED_SUFFIX))
                .map(|r| r.title.clone())
                .collect();
            assert!(
                canonical.contains("shared-A") || canonical.contains("shared-B"),
                "the winning edit must survive as a canonical row\n{}",
                d.a.dump().await
            );
            let survived: HashSet<String> = canonical
                .into_iter()
                .filter(|t| t == "shared-A" || t == "shared-B")
                .chain(std::iter::once(copy_base))
                .collect();
            assert_eq!(
                survived,
                HashSet::from(["shared-A".to_string(), "shared-B".to_string()]),
                "both offline edits must survive the fork (one canonical, one copy)\n{}",
                d.a.dump().await
            );

            // Both devices are drained and structurally sound at the fixpoint.
            for (name, h) in [("A", &d.a), ("B", &d.b)] {
                assert_eq!(
                    h.state.pending_push_count().await.expect("pending"),
                    0,
                    "device {name} left pending work after the fork\n{}",
                    h.dump().await
                );
                assert_base_null_when_clean(h, &format!("device {name} after the fork")).await;
            }

            // IDEMPOTENCY / no re-forking: a further full round on either device
            // is a no-op and the copy count is still exactly one.
            let extra_a = d.a.state.run_sync().await.expect("A extra");
            let extra_b = d.b.state.run_sync().await.expect("B extra");
            assert!(
                is_noop(&extra_a) && is_noop(&extra_b),
                "a run after the fork was not a no-op (A={extra_a:?} B={extra_b:?})"
            );
            let copies_after =
                d.a.server_rows()
                    .await
                    .into_iter()
                    .filter(|r| r.title.ends_with(CONFLICTED_SUFFIX))
                    .count();
            assert_eq!(
                copies_after,
                1,
                "the conflicted copy must not re-fork on a quiescent re-run\n{}",
                d.a.dump().await
            );
        });
    }

    /// RACING D7 REPAIRS WITH A BOUNDED MOVE COUNT. A third level (`P > T > C`)
    /// is planted on the ONE shared server — the §F/§G residual Google's
    /// depth-uncapped `move` lets exist — while BOTH devices hold `T > C` and
    /// `P` synced. Each device's next pull re-nests `C` under `T` and D7 fires
    /// the corrective flatten `move`, so the two engines RACE to repair the same
    /// grandchild. The engine documents this as "idempotent under racing
    /// repairs" (`repair_third_level`): moving an already-top-level row to
    /// top-level is a no-op the server accepts, and a flattened grandchild is no
    /// longer detected. This pin makes that claim load-bearing: the total number
    /// of corrective `move` calls the pair issues is BOUNDED by a small constant
    /// — a buggy repair that re-fired every run, or two engines that ping-ponged
    /// the row, would blow the bound long before it blew the round cap. Both
    /// devices converge and neither is left holding a two-level tree
    /// (invariant #1).
    #[test]
    #[allow(clippy::too_many_lines)] // one linear scenario reads best undivided
    fn dual_racing_d7_repairs_have_a_bounded_move_count() {
        run_case(|| async move {
            let mut d = DualHarness::new().await;
            let client = d.a.client.clone(); // the one shared server

            // A builds `T > C` and a sibling `P`, all top-level except C, then
            // pushes; B pulls, so both devices hold the flat tree synced clean.
            d.a.create_top_in(LIST).await; // "at001" == T
            d.a.state.run_sync().await.expect("A push T");
            let t_id =
                d.a.live()
                    .await
                    .into_iter()
                    .find(|t| t.task.title == "at001")
                    .expect("T pushed")
                    .task
                    .id
                    .clone();
            crate::commands::create_task_inner(
                &d.a.state,
                LIST.to_string(),
                Some(t_id.clone()),
                "at002".into(), // C, subtask of T
            )
            .await
            .expect("A create C");
            d.a.names.push("at002".into());
            crate::commands::create_task_inner(
                &d.a.state,
                LIST.to_string(),
                None,
                "at003".into(), // P, top-level sibling
            )
            .await
            .expect("A create P");
            d.a.names.push("at003".into());
            d.a.state.run_sync().await.expect("A push C+P");
            d.b.state.run_sync().await.expect("B pull tree");

            let c_id =
                d.a.live()
                    .await
                    .into_iter()
                    .find(|t| t.task.title == "at002")
                    .expect("C pushed")
                    .task
                    .id
                    .clone();
            let p_id =
                d.a.live()
                    .await
                    .into_iter()
                    .find(|t| t.task.title == "at003")
                    .expect("P pushed")
                    .task
                    .id
                    .clone();

            // Plant the third level ON THE SERVER: demote T under P (another
            // device's move, no If-Match). The server now holds `P > T > C`, a
            // grandchild no push-side guard can catch — exactly what D7 flattens
            // on the pull. Snapshot the move counter AFTER this setup move so
            // only the corrective repairs are counted.
            client
                .move_task(LIST, &t_id, Some(&p_id), None)
                .await
                .expect("server demote T under P");
            assert!(
                d.b.all_rows().await.iter().any(|r| r.task.id == c_id),
                "B must still hold C before the race\n{}",
                d.b.dump().await
            );
            let moves_before = client.call_count(Method::MoveTask);

            // Force a genuine TWO-SIDED race: arm the next corrective move to
            // fail transiently, so device A flattens C locally and defers its
            // server move (the server stays `P > T > C`), then device B pulls
            // the STILL-nested tree and issues its own corrective move. Both
            // engines act on the same grandchild.
            client.fail_next(Method::MoveTask, || ApiError::RateLimited);
            d.a.state
                .run_sync()
                .await
                .expect("A repair (move deferred)");
            d.b.state.run_sync().await.expect("B repair");

            // Drive both to the shared fixpoint and prove convergence.
            d.heal().await;
            assert_dual_converged(&d, "after racing D7 repairs").await;
            for (name, h) in [("A", &d.a), ("B", &d.b)] {
                assert_parent_integrity(h, &format!("device {name} after racing D7")).await;
                assert_eq!(
                    h.state.pending_push_count().await.expect("pending"),
                    0,
                    "device {name} left pending work after the D7 race\n{}",
                    h.dump().await
                );
            }
            // C ended up top-level on both devices — the flatten actually landed
            // and was not merely deferred forever (P5: moves degrade, never
            // wedge).
            for (name, h) in [("A", &d.a), ("B", &d.b)] {
                let dump = h.dump().await;
                let c = h
                    .all_rows()
                    .await
                    .into_iter()
                    .find(|r| r.task.id == c_id)
                    .unwrap_or_else(|| panic!("device {name} lost C\n{dump}"));
                assert!(
                    c.task.parent.is_none(),
                    "device {name}: C must be top-level after the flatten, parent={:?}\n{dump}",
                    c.task.parent
                );
            }

            // THE BOUND: the two racing engines issue a SMALL, constant number
            // of corrective moves for the one grandchild — A's deferred attempt,
            // B's landing move, and at most a couple of re-confirmations as the
            // caches reconcile. A non-terminating repair would climb toward the
            // round × heal-run ceiling; 6 sits far below it yet above the real
            // traffic (measured: 2).
            let corrective_moves = client.call_count(Method::MoveTask) - moves_before;
            assert!(
                corrective_moves <= 6,
                "racing D7 repairs issued {corrective_moves} corrective moves (expected a small \
                 bounded count); a repair that re-fires every run is the bug this guards\n{}",
                d.a.dump().await
            );
        });
    }
}
