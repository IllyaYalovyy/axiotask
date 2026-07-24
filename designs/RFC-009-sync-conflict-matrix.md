# RFC-009: Sync Conflict Matrix — every local×remote permutation

| Field         | Value                                      |
|---------------|--------------------------------------------|
| Status        | Review                                     |
| Author(s)     | Illya Yalovyy, Claude                      |
| Supersedes    | RFC-004 §Conflict resolution (extends it)  |
| Superseded by | —                                          |

---

## Summary

RFC-004 defines the sync engine's mechanics and resolves conflicts for the
*update* path only. This RFC enumerates **every** permutation of a local
pending operation against a concurrent remote change — edits, completes,
deletes, reorders, promote/demote, subtask add/remove, cross-list moves, and
list operations — and pins the expected outcome for each. Every row is tagged
with its status: `settled` (code + test agree), `untested` (code does it, no
test proves it), `gap` (behavior undefined or wrong vs. the expected outcome),
`decide` (a product decision this RFC proposes and the review must ratify), or
`probe` (real Google semantics unverified — must be checked live before being
encoded, per the no-hallucination rule).

Each `gap`/`untested` row maps to a fleet task (see Development Plan). The
matrix is enforced by unit tests against a **pure decision core** extracted
from the engine (Testing Strategy), so a row is cheap to test and impossible
to silently drop.

---

## Goals

- **G1** — Every local×remote crossing has a *written* expected outcome; no
  behavior exists only as an accident of implementation.
- **G2** — Every crossing is enforced by a unit test that would fail if the
  outcome changed.
- **G3** — The decision logic is testable without IO (pure functions over
  row-state × observation).
- **G4** — Unverified Google semantics are probed live before being encoded in
  the fake or the engine.

## Non-Goals

- **NG1** — Field-level 3-way merge. Whole-row resolution stays (RFC-004).
- **NG2** — Real-time/webhook sync.
- **NG3** — Changing the push-first order. Ratified separately in
  `design_decisions.md` ("Push or pull first?"): the order is not the safety
  mechanism; per-row etag guards are.

---

## Principles (the rules every row derives from)

- **P1 — Remote authority.** Google is canonical for every row it knows
  (i.e. every local row carrying a server etag). On true divergence, remote
  wins.
- **P2 — Unpushed work is untouchable.** *(decide — new principle)* A row the
  server has **never seen** (no etag: an unpushed create, a conflicted copy, a
  cross-list clone) is never destroyed by any remote event. It re-homes or
  waits; it never dies. Remote authority cannot extend to rows it has no
  knowledge of.
- **P3 — Edit/edit → conflicted copy.** Remote becomes canonical; the local
  edit survives as a "(conflicted copy)" task. Content comparison covers
  exactly title, notes, due, status (`same_content`, engine.rs) — never
  position, parent, or etag.
- **P4 — Delete wins, both directions.** Local-edit × remote-delete: the local
  row is hard-deleted, edit discarded. Local-delete × remote-edit: the
  unconditional DELETE lands, remote edit discarded. Cascades included. No
  conflicted copy. (Ratified in `design_decisions.md` this cycle.)
- **P5 — Moves degrade, never wedge.** The move endpoint has no etag, so moves
  are last-writer-wins. A move whose referenced task/parent/sibling vanished
  degrades stepwise — drop ordering, keep reparent; or drop the whole intent —
  and never retries forever, never deletes a task, never errors the run.
- **P6 — Etag–content coherence.** A local etag equal to the remote etag
  implies local content-fields equal remote content-fields. A violation
  freezes the row out of every future pull (the #104 bug class). Every push
  path must adopt the **response body**, not just the etag.
- **P7 — Convergence.** With a quiescent remote, one `run()` reaches the
  fixpoint and the next `run()` is a no-op (no writes, no API mutations).
- **P8 — Crash windows converge.** No transaction spans a run. Any crash
  between per-row operations leaves a state the next run drives to the same
  fixpoint — no duplicates (in-flight markers), no loss.

## Vocabulary

Local pending state of a row (how UI operations decompose):

- `clean` — no local intent.
- `create` — unpushed insert (top-level or subtask; "add subtask" is a create
  with a parent id).
- `update` — content edit: title/notes/due, or status (complete/un-complete;
  a local parent-complete also writes each subtask as an update, mirroring
  Google's cascade).
- `delete` — tombstone ("remove subtask" is a delete of the child; deleting a
  parent tombstones the whole subtree).
- `move` — position and/or parent intent: reorder (previous sibling), demote
  (parent set), promote/detach (parent cleared).
- `cross-list move` — compound: clone the subtree under **fresh ids** in the
  target list (creates) + tombstone the original subtree (deletes)
  (state.rs `move_task_to_list`).
- list ops — list create / rename / delete.

Remote conditions on the same row (or its surroundings) since our last sync:

- unchanged · edited · completed · un-completed · deleted · moved/reordered ·
  reparented · parent-deleted (cascades to the row) · parent-completed
  (cascades to the row) · new-child-appeared · list-renamed · list-deleted.

---

## The matrix

### A. Local `clean` × remote anything (pull mirror)

- × edited / completed / un-completed / moved / reparented → pull upserts;
  local mirrors remote. `settled`
- × deleted, or parent-deleted cascade → ghost detection removes the local row
  — only when the remote view is complete (H4). `settled` (#99)
- × new task / new subtask appeared → pulled parents-first; a child whose
  parent isn't visible yet is detached with etag dropped so it re-links next
  pull. `settled`
- × completed and auto-hidden by Google → still pulled (`showCompleted=true&
  showHidden=true`, http.rs:349) → must **not** be ghost-deleted. `untested`
  — needs an explicit test so nobody ever "optimizes" the query params.
- × list renamed → upsert. × list deleted → local list and its clean rows
  removed. `settled` (#101) — but see G3/P2 for dirty rows in that list.

### B. Local `update` (content edit) × remote

- × unchanged → PATCH with If-Match lands; **response body adopted** (server
  may coerce fields silently — P6). `settled`
- × edited, content-fields end up equal → 412 → refetch → adopt etag, no copy.
  `settled` (#100)
- × edited, divergent → 412 → refetch → remote canonical + "(conflicted
  copy)". `settled` (#100)
- × moved/reordered/reparented (content untouched) → if the move bumped the
  etag: 412 → refetch → content-fields equal → adopt etag; position arrives on
  pull. **No false conflicted copy** — comparison excludes position/parent.
  `untested` (also `probe`: does a move bump the task etag?)
- × deleted → PATCH 404 → hard-delete local, edit discarded (P4).
  `settled` code (engine.rs push_update NotFound); `untested` as an explicit
  matrix row.
- × parent-deleted (cascade removed the subtask we edited) → same as deleted:
  404 → row gone, edit gone (P4). `untested`
- × 412 then refetch 404 → hard-delete. `settled`
- × 412 then refetch transient → stays dirty, retries. `settled` (#100)

### C. Local complete / un-complete × remote

- Local complete parent → local cascade + server cascade both run; children's
  updates align; every landed response body adopted (P6). `untested` as an
  end-to-end matrix row (#104 fixed the adoption half).
- × remote edited same row → 412 → title **and** status diverge → conflicted
  copy (P3). `untested`
- **Status-only divergence** (title/notes/due equal; only status differs, e.g.
  local complete × remote un-complete) → today: conflicted copy. **Proposal:
  remote wins, no copy** — a lost checkbox click is cheap, a duplicate task is
  expensive and confusing. `decide` (D1)
- Local un-complete subtask × remote parent-completed → Google returns 200 and
  silently ignores the reopen (verified live); response-body adoption converges
  local back to completed — no wedge, no etag freeze. `untested` as an explicit
  matrix row (the adoption exists; engine.rs:660-664).
- Local complete × remote deleted → 404 → row gone (P4). `untested`
- Local complete parent × remote added a new subtask meanwhile → our local
  cascade never saw the new child. Does the server's cascade complete it?
  `probe` — then converge on pull; invariant: no open child under a completed
  parent after the run that pulls it. (Whether that invariant is Google's or
  ours is part of the probe.)

### D. Local `delete` × remote

- × unchanged → DELETE; remote 404 counts as success; tombstone cleared.
  `settled`
- × edited → DELETE is **unconditional** (no If-Match, http.rs:462) → delete
  lands, remote edit lost (P4, ratified). `untested` — needs a test asserting
  the *documented* semantics so a future change is deliberate.
- × completed / un-completed → same: delete wins. `untested`
- × moved / reparented → delete by id still lands. `untested`
- × new remote subtask appeared under the deleted parent → server cascade
  deletes the remote-born child with its parent. Consequence of P4 + Google's
  cascade. Accepted; must be written down and tested against the fake.
  `untested`
- × already deleted remotely → 404 → success. `settled`
- Local delete of one subtask ("remove subtask") × any of the above on the
  child → same rows as above, parent unaffected. `untested`
- `probe`: does Google's DELETE accept If-Match at all? If yes, a future
  option to detect delete/edit races exists; if no, P4 is also a physical
  constraint. Record the answer in the fake either way.

### E. Local reorder (`move`, previous-sibling) × remote

- × unchanged → move lands; **response body adopted** when the row is clean,
  meta-only when dirty (P6, the #104 fix). `settled` (#103/#104)
- × remote reordered the same list → last-writer-wins on position (P5); pull
  converges both sides. `untested` as an explicit crossing.
- × task deleted remotely → move endpoint 404 → drop the intent (H7); row
  ghost-deletes on pull. `settled`
- × previous-sibling deleted **locally** → degrade to reparent-only, ordering
  dropped (local `task_exists` guard). `settled` (#104)
- × previous-sibling deleted **remotely** (still exists locally, guard passes)
  → server rejects the stale sibling ref (`probe`: 400 or 404?). Expected:
  degrade to reparent-only / append, never wedge, never lose the task (P5).
  `gap` — no code path distinguishes this today; the intent must not retry
  forever.
- × remote edited same row content → move is orthogonal; move lands, remote
  content arrives via response-body adoption / pull. Converges to remote
  content + last-written order. `untested`

### F. Local demote / promote (`move` with parent change) × remote

- Demote under P, P alive → move parent=P lands. `settled` (#103)
- Demote under P × P deleted **remotely** → two legal serializations: (a) the
  server processes the delete first → our move 404s → drop intent, task stays
  top-level and survives; (b) the move lands first → P's delete cascades the
  task on the server → it ghost-deletes locally. Both end with local == remote.
  Expected: no wedge, no duplicate, no divergence — the *invariant* is
  convergence, not which serialization won. `untested` (test both orders via
  the fake).
- Demote under P × P **completed** remotely → can an open task move under a
  completed parent? `probe`. Whatever the answer: converge, no wedge (P5).
- Demote a task × remote gave it a subtask meanwhile → the move would create a
  3rd level; Google rejects >2 levels (verified live). Expected: server error
  → drop the move intent, task stays top-level, run continues (P5). `gap` —
  encode once the exact status code is probed.
- Promote/detach (parent cleared) × remote deleted the row → 404 → drop
  intent; row ghost-deletes (P4). `untested`
- Promote × remote reparented the same row elsewhere → last-writer-wins (P5);
  pull converges. `untested`
- Local update + local move on the same row in one run → push order is
  updates-then-moves; both land; final state = new content at new position.
  `settled` (#103) — keep a matrix row anyway.

### G. Local `create` × remote

- Top-level create, list alive → insert → `finish_create` remap; in-flight
  marker crash-safety; held-create deferral. `settled` (H1, #102, #104)
- **G3.** Create in a list deleted remotely → insert fails; meanwhile pull
  removes the local list, and the FK cascade would take the unpushed row with
  it — destroying work the server never saw, violating P2. Expected
  (`decide` D2): rows **without etags** in a remotely-deleted list are
  **re-homed to the default list** (still dirty, push next run); rows *with*
  etags die with the list (P1/P4). `gap`
- Subtask create × parent deleted remotely → the insert names a dead parent id
  → permanent 400 ("Invalid task ID", verified live for unresolved parents) →
  today the row stays dirty forever. Expected (`decide` D3): **promote to a
  top-level create in the same list** — the unpushed child never dies (P2) and
  never wedges. `gap`
- Subtask create × parent **completed** remotely → what does Google do with an
  open child inserted under a completed parent? `probe` → then: converge, no
  wedge.
- Create racing an identical remote create (same content, not ours) →
  in-flight adoption applies **only** to rows with in-flight markers; otherwise
  both tasks live (duplicate titles are legal). `settled` — keep as a matrix
  row so adoption is never "generalized" into content-dedup.
- Held create (detail panel open) × everything → held row waits; recovery
  skips it; all other creates push. `settled` (#104)

### H. Local cross-list move (clone + delete) × remote

- × unchanged → clones created in target (parents first), originals tombstoned
  and deleted; subtree arrives whole; ids fresh. `untested` end-to-end at the
  sync layer.
- × remote edited the original mid-window → the clone carries the content
  snapshot from move time; the tombstone's unconditional delete discards the
  remote edit (P4). **Accepted MVP loss** — record + test. `decide` (D4:
  accept, or fetch-compare before delete once the DELETE If-Match probe (D§)
  answers).
- × original deleted remotely → tombstone 404 = success; clones still push →
  the task **survives in the target list** ("move wins"): the clones are
  unpushed rows under P2, and the user's move expressed intent to keep the
  task. `decide` (D5) + `untested`.
- × new remote subtask under the original → not in the clone snapshot; dies
  with the original's cascade delete. Accepted (P4 + cascade); record + test.
  `untested`
- × target list deleted remotely → clone creates fail → re-home per D2 to the
  default list; originals' tombstones still push. The subtree survives,
  somewhere visible. `gap` (depends on D2)
- Crash between pushing clones and pushing deletes → both lists briefly hold
  the subtree; next run pushes the tombstones → converges, no permanent
  duplicate (P8). `untested`

### I. Local list ops × remote

- Local rename × remote rename → does `patch_tasklist` carry If-Match, and do
  list etags 412? `probe`. Expected either way: **remote wins, no conflicted
  copy** — a list title is cheap, a duplicate list is not. `decide` (D6)
- Local list delete × remote added tasks to it meanwhile → the list delete
  cascades them on the server (P4). Accepted; record + test. `untested`
- Local list delete × already deleted remotely → 404 = success. `settled`
  (#101)
- Local list create → adopt an existing remote list of the same title instead
  of duplicating ("My Tasks"). `settled`
- Local rename × remote deleted → NotFound → hard-delete local list (P4).
  `settled` (#101)

### J. Cross-cutting invariants (property layer)

The #104 property suite (`sync_property_test.rs`) enforces P6/P7/P8 over
random orderings of: create, edit, complete, delete, reorder, crash, partial
pull. Its operation vocabulary must grow to cover the rest of this matrix:
demote/promote, cross-list move, list delete, remote cascades. `gap`

---

## Decisions to ratify

- **D1** — Status-only divergence resolves remote-wins **without** a
  conflicted copy. (Today it produces a copy.)
- **D2** — Rows without etags in a remotely-deleted list re-home to the
  default list; rows with etags die with the list. (P2)
- **D3** — A subtask create whose parent died remotely promotes to a top-level
  create in the same list. (P2)
- **D4** — Cross-list move: a concurrent remote edit to the original is lost
  (clone snapshot wins). Accepted MVP semantics.
- **D5** — Cross-list move: the task survives in the target even if the
  original was deleted remotely ("move wins").
- **D6** — List rename conflicts resolve remote-wins, no copy.
- **P2 itself** — remote events never destroy rows the server has never seen.

## Probes required (live API, before encoding — no-hallucination rule)

- Does a move bump the task's etag?
- Move with a remotely-deleted previous sibling: 400 or 404?
- Move creating a 3rd level: exact rejection status.
- Move an open task under a completed parent: allowed?
- Insert an open subtask under a completed parent: result?
- Complete a parent while a new child exists we've never pulled: does the
  cascade take it?
- Does DELETE honor If-Match?
- Does `patch_tasklist` honor If-Match / do lists 412?

Every answer lands in `in_memory.rs` (kept exactly as strict as Google) and is
cited in the task report.

---

## Testing Strategy

**Extract a pure decision core.** `engine.rs` is 3.8k lines where decision
logic and IO interleave; testing a matrix row today means staging a full
engine + fake + store. Extract the *decisions* into pure functions —
`(local row state, observed API result) → SyncAction` — in a new
`sync/reconcile.rs`, with the engine reduced to: observe, decide, apply.
Matrix rows then become table-driven unit tests over pure functions (one
assertion per row of this RFC), while the existing integration + property
suites keep proving the wiring. **No behavior change** — the extraction task
is green against the entire existing suite before any matrix test is added.

Layers:

- **Unit (pure)** — every matrix row above, table-driven against
  `reconcile.rs`. Cheap, exhaustive, IO-free.
- **Integration (engine + in-memory fake)** — the crossings that are about
  *sequencing* (crash windows, both serializations in F, cross-list clone /
  delete windows) — the fake stays as strict as Google.
- **Property (#104 suite)** — extended op vocabulary; P6/P7/P8 over random
  interleavings.
- **Live probes** — the listed unknowns, one-off, recorded into the fake.

What cannot be unit-tested and why: true concurrent mutation *during* a single
HTTP call (server-side race) — covered by the 412/404 branches, which are the
server's serialization of exactly that race.

---

## Development Plan

Ordered; each step is a ktask fleet task with its own GitHub issue
(queued as ktask 67–75).

- [ ] **Step 1 (#105)** — Extract the pure reconciler (`sync/reconcile.rs`);
  no behavior change. *(prerequisite: —)*
- [ ] **Step 2 (#106)** — Live-API probes; align `in_memory.rs`. *(prereq: —;
  needs the throwaway account)*
- [ ] **Step 3 (#107)** — Matrix tests: edit/complete family (§B, §C) incl.
  D1. *(prereq: #105–#106)*
- [ ] **Step 4 (#108)** — Matrix tests: delete family (§D), delete-wins
  pinned. *(prereq: #105)*
- [ ] **Step 5 (#109)** — Matrix tests: reorder/promote/demote (§E, §F) incl.
  the remote-sibling and 3rd-level degradations. *(prereq: #105–#106)*
- [ ] **Step 6 (#110)** — Create family + P2 (§G): D2 re-homing, D3 orphan
  promotion. *(prereq: #105–#106; D2/D3 ratified)*
- [ ] **Step 7 (#111)** — Cross-list move matrix (§H) incl. crash windows,
  D4/D5. *(prereq: #105, #108, #110; D4/D5 ratified)*
- [ ] **Step 8 (#112)** — List-op matrix (§I) + hidden/completed pull row
  (§A). *(prereq: #105–#106; D6 ratified)*
- [ ] **Step 9 (#113)** — Extend the property suite's op vocabulary (§J).
  *(prereq: #107–#112)*

---

## Open Questions

- [ ] **Q1** — All `probe` rows above (blocking Steps 3, 5, 6, 8 where
  marked).
- [ ] **Q2** — D1–D6 + P2 ratification by the reviewer.
