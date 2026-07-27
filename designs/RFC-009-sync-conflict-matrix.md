# RFC-009: Sync Conflict Matrix — every local×remote permutation

| Field         | Value                                      |
|---------------|--------------------------------------------|
| Status        | Review                                     |
| Author(s)     | Illya Yalovyy                              |
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

Each `gap`/`untested` row maps to a tracked task (see Development Plan). The
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
- **P2 — Unpushed work is untouchable.** *(**RATIFIED** 2026-07-24, with
  #110)* A row the server has **never seen** (no etag: an unpushed create, a
  conflicted copy, a cross-list clone) is never destroyed by any remote event.
  It re-homes or waits; it never dies. Remote authority cannot extend to rows
  it has no knowledge of. P2 shields work from *remote* events only: the
  user's own delete still cascades over unpushed rows (invariant #3, P4), and
  a row that carries an etag is not covered at all — it dies with its parent
  or its list (P1).
- **P3 — Edit/edit → conflicted copy.** Remote becomes canonical; the local
  edit survives as a "(conflicted copy)" task. The divergence test for the
  conflict path covers exactly the fields the user types — title, notes, due
  (`same_typed_content`, sync/reconcile.rs) — never position, parent, etag, or
  **status** (D1, ratified). Elsewhere (crashed-create adoption, pull
  filtering) `same_content` still counts status too.
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
  showHidden=true`, http.rs) → must **not** be ghost-deleted. `settled` (#112)
  — pinned on the wire (`list_tasks_asks_for_completed_and_hidden_tasks`
  matches **both** query params, so dropping either fails the request), and
  the consequence of dropping them is pinned above it: the row falls out of the
  remote view, ghost detection reads "absent from the server" and deletes it.
  Tested for a top-level row and for a completed **subtask** of an open parent
  (which must also stay attached, never promoted to a list row — invariant #1),
  and end to end through the list view.
- × list renamed → upsert. × list deleted → local list and its clean rows
  removed. `settled` (#101) — but see G3/P2 for dirty rows in that list.

### B. Local `update` (content edit) × remote

- × unchanged → PATCH with If-Match lands; **response body adopted** (server
  may coerce fields silently — P6). `settled`
- × edited, content-fields end up equal → 412 → refetch → adopt etag, no copy.
  `settled` (#100)
- × edited, divergent → 412 → refetch → remote canonical + "(conflicted
  copy)". `settled` (#100)
- × moved/reordered/reparented (content untouched) → a move **does** bump the
  etag (probed): 412 → refetch → content-fields equal → adopt etag; position
  arrives on pull. No false conflicted copy from the *comparison*, which
  excludes position/parent. `settled` (#107)
- × moved/reordered/reparented **while the local edit changed content** → the
  refetched remote still holds the PRE-EDIT content. A **per-row base snapshot**
  (the content as of the last server agreement, #124) tells "only we changed it"
  from "they changed it too": on the `412`, if the refetched remote equals the
  base, a bare reorder bumped the etag and the server never diverged from us —
  adopt the fresh etag and re-push the local edit; no conflicted copy, no
  reverted edit. Only when the remote diverges from the base (a genuine remote
  content edit) does P3 fork a copy. `settled` (#124) — this is base-version
  conflict *detection*, not a field-level merge, so NG1 still holds. The base is
  captured when a clean row is first edited and cleared when it goes clean
  again; a mid-flight re-edit re-bases to the just-pushed body. Regression:
  `remote_reorder_plus_local_rename_no_false_copy_rename_lands` (red first).
- × deleted → **not a 404.** Deletes are soft: the PATCH returns **200** with a
  body echoing our edit, but the row stays deleted and never reappears in
  `list_tasks`. The edit is lost and the local row is removed by **ghost
  detection on the pull**, not by a `NotFound` branch (P4 still holds).
  `settled` (#107) — the test asserts the OUTCOME (row gone, edit discarded,
  no copy, no error), which both paths share; the fake hard-deletes, so it
  reaches that outcome through the 404 branch. No test asserts the path, and
  none may.
- × parent-deleted (cascade removed the subtask we edited) → identical to the
  row above: 200-but-ignored, then ghost-deleted on pull. `settled` (#107)
- × 412 then refetch 404 → hard-delete. `settled`
- × 412 then refetch transient → stays dirty, retries. `settled` (#100)

### C. Local complete / un-complete × remote

- Local complete parent → local cascade + server cascade both run; children's
  updates align; every landed response body adopted (P6). `settled` (#107)
- × remote edited same row → 412 → title **and** status diverge → conflicted
  copy (P3). `settled` (#107)
- **Status-only divergence** (title/notes/due equal; only status differs, e.g.
  local complete × remote un-complete) → **remote wins, no copy** — a lost
  checkbox click is cheap, a duplicate task is expensive and confusing.
  `settled` (D1 **ratified**; implemented in #107 —
  `reconcile::resolve_conflict` compares typed content only).
- Local un-complete subtask × remote parent-completed → Google returns 200 and
  silently ignores the reopen (verified live); response-body adoption converges
  local back to completed — no wedge, no etag freeze. `settled` (#107)
- Local complete × remote deleted → row gone (P4). `settled` (#107) — same
  path caveat as §B × deleted: live it is 200-then-ghost-detection, the fake
  reaches the same outcome via 404.
- Local complete parent × remote added a new subtask meanwhile → our local
  cascade never saw the new child, but **the server's cascade takes it**
  (probed). A child insert also does **not** bump the parent's etag, so our
  complete lands with the pre-child etag — no spurious 412. The invariant "no
  open child under a completed parent" is **Google's**, not just ours.
  `settled` (#107)

### D. Local `delete` × remote

- × unchanged → DELETE; remote 404 counts as success; tombstone cleared.
  `settled`
- × edited → DELETE is **unconditional** (no If-Match, http.rs:462) → delete
  lands, remote edit lost (P4, ratified). `settled` (#108) — pinned at three
  layers: the transport sends no `If-Match`, `plan_delete` takes no remote
  state at all (adding one would not compile), and the crossing is asserted
  end to end on both sides.
- × completed / un-completed → same: delete wins. `settled` (#108) — the same
  test also guards D1 from leaking out of the 412 path and resurrecting a
  deleted row.
- × moved / reparented → delete by id still lands; the new parent it was
  dragged under is untouched. `settled` (#108)
- × new remote subtask appeared under the deleted parent → server cascade
  deletes the remote-born child with its parent. Consequence of P4 + Google's
  cascade. Accepted; the child never surfaces locally, not even as an orphan.
  `settled` (#108)
- × already deleted remotely → 404 → success. `settled`
- Local delete of one subtask ("remove subtask") × any of the above on the
  child → same rows as above, parent unaffected: not dirtied, etag unchanged,
  siblings still attached. `settled` (#108)
- Local delete of a parent whose child is an **unpushed** create → creates
  push before deletes, so the child is inserted and then removed by the
  parent's cascade; both sides converge with nothing dirty and no child left
  naming a dead parent id. P2 is not in play — it protects unpushed rows from
  *remote* events, not from the user's own cascade delete (invariant #3).
  `settled` (#108)
- Local delete of a create whose **insert crashed mid-flight** (committed
  server-side, response lost) → the row looks unpushed but an in-flight marker
  says the server may hold it. It must be **tombstoned, not hard-deleted**: a
  hard delete FK-cascades the marker away and strands the committed row, which
  the next pull then resurrects. Recovery adopts the orphan onto the tombstone
  (id only — never a resurrection) and the delete reaches it; when no orphan
  exists the tombstone is dropped, because a local UUID on the wire is a
  permanent 400. `settled` (#113, defect #120) — a row the matrix had not
  enumerated, found by the §J property suite. Same rule at all three delete
  paths: `delete_task`, `clear_completed`, and the cross-list move in §H.
- ...and that tombstone must **not be pushed while its own create is still
  unresolved in flight** (`reconcile::mutation_is_pushable`): a run whose
  recovery could not see the list leaves the marker open and the local UUID in
  place, and a delete sent against it is a permanent 400 that would also
  "succeed" against the fake while the committed row lives on. Updates take
  the same gate. `settled` (#113) — found by the §J suite at 1024 cases from
  `[CreateTop, CrashSync, MoveToList, FlakySync(list_tasks 503)]`, i.e. only
  once a transient fault was crossed with the crash window and a move.
- **Answered:** Google's DELETE **does** accept `If-Match` (stale → 412, task
  survives; current → 204). P4 is therefore a *choice*, not a physical
  constraint: `http.rs::delete_task` sends no `If-Match` on purpose (pinned by
  `delete_task_sends_no_if_match`). A future option to detect delete/edit
  races exists if D4 is revisited.

### E. Local reorder (`move`, previous-sibling) × remote

- × unchanged → move lands; **response body adopted** when the row is clean,
  meta-only when dirty (P6, the #104 fix). `settled` (#103/#104)
- × remote reordered the same list → last-writer-wins on position (P5); pull
  converges both sides. `settled` (#109)
- × task deleted remotely → the move is rejected (an unknown SUBJECT id is a
  permanent **400** "Invalid task ID", probe 2 — *not* a 404); the intent is
  counted and dropped and the row ghost-deletes on pull. `settled` (#109)
- × previous-sibling deleted **locally** → degrade to reparent-only, ordering
  dropped (local `task_exists` guard). `settled` (#104)
- × previous-sibling deleted **remotely** (still exists locally, guard passes)
  → server answers **404 "Previous task id not found"** (probed). The status is
  genuinely ambiguous — the same 404 also means "the subject is gone" — so the
  engine no longer guesses: a 404 on a call that named a `previous` **drops the
  ordering half and retries the reparent alone** (`MoveFailure::
  DropPreviousAndRetry`, the P5 ladder). If that second call 404s it named no
  `previous`, so "the subject is gone" is the only reading left and the intent
  is dropped. At most two calls, ever. `settled` (#109) — before this, the
  demote was silently reverted whenever the anchor sibling had died remotely.
- × remote edited same row content → move is orthogonal; move lands, remote
  content arrives via response-body adoption / pull. Converges to remote
  content + last-written order. `settled` (#109)
- Any move that is **refused or permanently rejected** must also undo the
  optimistic local half: the UI already applied the new parent/position, and
  the row's etag still matches the server's, so the pull would skip the row and
  freeze the divergence (P6). The engine drops the etag on such a row
  (`revert_local_move`) so the same run's pull re-adopts the server's placement.
  Clean rows only — a dirty row's own update push owns its etag. `settled`
  (#109) — added by this step; the matrix had not enumerated it.

### F. Local demote / promote (`move` with parent change) × remote

- Demote under P, P alive → move parent=P lands. `settled` (#103)
- Demote under P × P deleted **remotely** → two legal serializations: (a) the
  server processes the delete first → our move names a dead parent id and is
  permanently rejected → drop intent, task stays top-level and survives;
  (b) the move lands first → P's delete cascades the task on the server → it
  ghost-deletes locally. Both end with local == remote. The *invariant* is
  convergence, not which serialization won. `settled` (#109) — the exact status
  for (a) is **not probed** (an insert naming an unresolved parent is a
  permanent 400, and so is a move naming an unknown subject; an unknown
  `previous` is a 404), so the test injects **both** permanent statuses and
  demands the same outcome from each, rather than encoding a guess in the fake.
- Demote under P × P **completed** remotely → the move is **accepted (200)**
  and the server's cascade **completes the demoted task**, visible in the move
  response body (probed). Response-body adoption (P6) converges it; the user
  sees their open task become done. No wedge. `settled` (#109)
- Demote a task × remote gave it a subtask meanwhile → the move creates a 3rd
  level and the server **accepts it (200)** — Google does *not* cap depth
  (probed; this corrects an earlier claim). So invariant #1 (strictly one
  level) is **ours to enforce client-side**. Now refused at both gates:
  `commands::move_task` rejects the demote outright (the last gate before the
  store records the intent), and `reconcile::plan_move` returns
  `MoveIntent::Refuse` when the row has picked up subtasks — or the target
  parent has become a subtask — since the intent was recorded. The refused row
  reverts to the server's placement via `revert_local_move`. `settled` (#109).
  **Residual race** — the remote-born subtask arrives *after* our demote
  already landed: the server holds a grandchild we never asked for. Repaired
  per **D7** (ratified): the pull detects any row a third level deep, promotes
  the grandchild to top-level in its list, pushes the corrective move so the
  server converges (a local-only repair would re-trigger every pull, P7),
  and counts the repair as a **conflict** in the sync outcome — visible,
  never silent. The repair is idempotent under racing repairs. `settled`
  (#119) — `reconcile::third_level_ids` detects a grandchild under a **clean**
  (server-confirmed) subtask over the local store after upsert — not the
  fetched batch, so a paged pull that lands the demotion without re-fetching
  the grandchild still repairs it, and the clean-middle guard ignores an
  un-pushed optimistic demote. `SyncEngine::repair_third_level` moves a synced
  grandchild and promotes a still-queued create locally. When the corrective
  move does not land it still flattens the row **locally**
  (`promote_and_detach`), because invariant #1 is absolute even mid-flight (the
  soak asserts it right after a partial pull, where ghost removal is skipped): a
  transient failure re-nests + re-detects until the server converges too (P7); a
  permanent one (the grandchild is gone on the server) is ghost-removed on the
  next complete pull. It drops the etag only for a **Clean** row (same guard as
  `revert_local_move`, #130): a dirty grandchild keeps its etag so its own
  content push stays `If-Match`-guarded (P6) rather than blind-overwriting a
  concurrent remote edit; that push re-examines the row and adopts the response
  body anyway. Red-first + 2000-case soak (a new `RemoteDemote` op drives
  both vectors); the soak also surfaced a latent FK crash — `apply_pushed_task`
  adopting a parent this device no longer holds — now detached like the pull's
  unknown-parent case.
- Promote/detach (parent cleared) × remote deleted the row → rejected → drop
  intent; row ghost-deletes (P4); the old parent is untouched. `settled` (#109)
- Promote × remote reparented the same row elsewhere → last-writer-wins (P5);
  pull converges. `settled` (#109)
- Local update + local move on the same row in one run → push order is
  updates-then-moves; both land; final state = new content at new position.
  `settled` (#103, re-pinned by #109 with an etag/content-coherence assertion).

- Local demote × the target parent deleted remotely → the move is rejected
  (the parent id is not a task the server has), the intent is dropped and the
  optimistic local placement is undone, so the row stays top-level and clean.
  `settled` (#113) — found by the §J suite from `[Demote, RemoteDelete]`. The
  crossing was invisible before because the fake accepted a `parent` it did
  not have (defect #123): the resulting server row pointed at a deleted
  parent, our pull detached it and dropped its etag on **every** run, and sync
  never settled (P7). `in_memory::move_task` now applies the same permanent
  rejection `insert_task` already applies to that field.

### G. Local `create` × remote

- Top-level create, list alive → insert → `finish_create` remap; in-flight
  marker crash-safety; held-create deferral. `settled` (H1, #102, #104)
- Create whose insert crashed mid-flight (committed server-side, response lost)
  **and was then edited during the window** → recovery matches the orphan on the
  create's **base snapshot** — the insert payload as sent, recorded in
  `inflight_creates.base_local_updated` and `tasks.base_*` before the insert —
  not the row's now-drifted content, so it adopts instead of re-inserting; the
  edit survives as a pending `update` against the adopted id (`finish_create`'s
  drain-snapshot guard, fed the recorded `base_local_updated`). The pull's own
  front-run guard (`pull_batch`) matches on the same base, so the committed
  orphan is never pulled as a duplicate clean row while its marker is open. Base
  matching tolerates the ONE status coercion Google applies — a subtask stored
  completed under a completed parent (RFC-009 §G cascade) — for any row with a
  parent. `settled` (#124) — before this, an edit in the window broke adoption
  and duplicated the task (#122). Regression:
  `edit_during_inflight_create_adopts_orphan_no_duplicate_edit_survives` (red
  first) and the §J property generator now exercises the op.
- **G3.** Create in a list deleted remotely → insert fails; meanwhile pull
  removes the local list, and the FK cascade would take the unpushed row with
  it — destroying work the server never saw, violating P2. Rows **without
  etags** in a remotely-deleted list are **re-homed to the default list**
  (still dirty, push next run); rows *with* etags die with the list (P1/P4).
  `settled` (D2 **ratified**; implemented in #110 —
  `reconcile::rehome_target` + `Store::rehome_unpushed_tasks`). The target is
  the surviving list titled "My Tasks" (Google's default-list title, and the
  one our own offline bootstrap uses), else the alphabetically first list,
  ties broken by id so the choice never depends on store iteration order.
  Local-only lists (they never push) and lists the user has tombstoned are not
  candidates, nor is any *other* list this same pull is about to remove. An
  unpushed subtree re-homes intact; an unpushed subtask whose parent stays
  behind **dies with its parent** (D3 rejected — no promotion; the
  promote-then-re-home edge #110 shipped was removed by #125). **Boundary:**
  when nothing can take the
  rows, the dying list is **kept as an unpushed list create** instead of being
  dropped — it is re-created (or adopted by title) on the next push and the
  rows land in it, so P2 holds even for an account with no other list.
- Subtask create × parent deleted remotely → **the child dies with the
  parent** (D3 REJECTED by user 2026-07-24: no auto-promotion; a subtask
  shares its parent's fate, remote or local, same as invariant #3). The
  parent's local removal FK-cascades the unpushed child away, which is also
  the no-wedge guarantee — no dead-parent insert survives to retry. `settled`
  (#125) — #110 had implemented the now-rejected promotion
  (`Store::remove_ghost_task` promote-before-ghost-delete, plus the
  update-404 / conflict-refetch-404 promotions); #125 removed it without
  trace and pinned the cascade outcome red-first.
- Subtask create × parent **demoted** remotely → push runs before pull, so
  the queued insert cannot know its parent is now a subtask; the server
  accepts it (no depth cap, probed) and **we ourselves create the 3rd level**
  (`parent_is_pushable` checks Synced, not depth — and cannot do better,
  since the demote is unseen until the pull). This is the most practical
  3rd-level vector: an offline device with a queued subtask create racing a
  demote from another device. No push-side guard can close it; the pull-side
  D7 repair (§F) catches it within one round-trip. `settled` (#119) — if the
  create already landed it is moved to top-level; if it is still queued (its
  push held) it is promoted locally so the tree is one level immediately and it
  pushes as a top-level create.
- Subtask create × parent **completed** remotely → the insert is **accepted**
  and the child is created **already completed**, in the insert response body
  (probed). The row converges to `completed` in the same run and no wedge
  remains. `settled` (#110). Note the *mechanism*: `finish_create` adopts the
  id, etag, `updated` and position but **not** the response's content fields,
  so convergence comes from the pull that follows — the freshly created row
  has no stored `webViewLink` yet, so it is not an etag-skip candidate and the
  pull upserts the server's version over it. P6 therefore holds for this row
  by way of the pull, not by way of the insert response.
- Create racing an identical remote create (same content, not ours) →
  in-flight adoption applies **only** to rows with in-flight markers; otherwise
  both tasks live (duplicate titles are legal). `settled` (#110) — keep as a
  matrix row so adoption is never "generalized" into content-dedup.
- Held create (detail panel open) × everything → held row waits; recovery
  skips it; all other creates push — and a remote list delete in the same
  window re-homes it rather than destroying it (P2). `settled` (#104, #110)

### H. Local cross-list move (clone + delete) × remote

- × unchanged → clones created in target (parents first), originals tombstoned
  and deleted; subtree arrives whole; ids fresh. `settled` (#111)
- × remote edited the original mid-window → the clone carries the content
  snapshot from move time; the tombstone's unconditional delete discards the
  remote edit (P4). **Accepted MVP loss.** `settled` (#111, D4 ratified) — the
  fetch-compare alternative probe 7 leaves available was NOT taken.
- × original deleted remotely → tombstone 404 = success; clones still push →
  the task **survives in the target list** ("move wins"): the clones are
  unpushed rows under P2, and the user's move expressed intent to keep the
  task. `settled` (#111, D5 ratified).
- × new remote subtask under the original → not in the clone snapshot; dies
  with the original's cascade delete. Accepted (P4 + cascade). `settled`
  (#111) — and no invisible local orphan is left behind.
- × target list deleted remotely → clone creates fail → re-home per D2 to the
  default list; originals' tombstones still push. The subtree survives,
  somewhere visible. `settled` (#111) — the D2 mechanism has been in place
  since #110 (clones are etag-less rows, so they re-home like any other
  unpushed work); the crossing is now tested end to end.
- Crash between pushing clones and pushing deletes → both lists briefly hold
  the subtree; next run pushes the tombstones → converges, no permanent
  duplicate (P8). `settled` (#111) — and the local view never shows the
  duplicate: the pull does not resurrect the tombstoned original.
- Crash *inside* a clone insert (committed server-side, response lost) → the
  in-flight marker adopts the orphan on the next run rather than inserting the
  moved task twice (P8). Not enumerated before #111; `settled` (#111).
- Crash inside the **original's** insert, then the move → the source row looks
  unpushed but its in-flight marker says the server may already hold it, so it
  is tombstoned rather than hard-deleted (§D). Otherwise the committed insert
  is stranded in the SOURCE list and the next pull shows the task in **both**
  lists. Not enumerated before #113; `settled` (#113, defect #120) — found by
  the §J property suite from `[CreateTop, CrashSync, MoveToList]`.

### I. Local list ops × remote

- Local rename × remote rename → **list etags never 412** (probed): a stale
  `If-Match` still returns 200 and the rename lands. Renames are
  last-writer-wins **by server design**, so **D6 (remote wins, no copy) is
  forced rather than chosen** — conflict detection for lists is impossible.
  `settled` (D6 **ratified**; #112). Both serializations are tested and both
  end with **one** list: ours lands last → our title, theirs lands last → the
  pull adopts theirs. No conflicted copy exists for lists, and none may be
  invented: `patch_tasklist_sends_no_if_match` pins the absent precondition,
  and `plan_list_pull` deliberately compares the *title* rather than skipping
  on a matching etag, so a remote rename can never be frozen out of the pull
  (the P6 failure mode at list level).
- Local list delete × remote added tasks to it meanwhile → the list delete
  cascades them on the server (P4). Accepted. `settled` (#112) — the
  remote-born row also never lands as a **local orphan** (a row in a list that
  no longer exists, reachable from no view). Non-happy path tested too: while
  the delete push retries after a transient, the pull still sees both the list
  and that task, and neither may resurface — the tombstone is protected twice,
  by `plan_list_pull` (`KeepLocal`) and by the store's clean-guarded
  `upsert_remote_list`.
- Local list delete × already deleted remotely → 404 = success. `settled`
  (#101, crossing added in #112: no error counted, no tombstone left to retry
  forever)
- Local list create → adopt an existing remote list of the same title instead
  of duplicating ("My Tasks"). `settled` (#112) — including that tasks queued
  in the local list follow it onto the adopted remote id and push there.
- Local rename × remote deleted → NotFound → hard-delete local list (P4).
  `settled` (#101, user-visible crossing added in #112: the sidebar entry and
  its tasks both go, rather than a list that never syncs again) — **but the
  rows the server never saw re-home first** (P2/D2). The hard delete
  FK-cascaded them away, destroying unpushed work on a *remote* event; the
  pull's ghost-list path already did the re-homing and the rename push is the
  same discovery arriving through a different call, so both now share
  `engine::rehome_before_dropping`. With nowhere to re-home, the list is kept
  as an unpushed create instead of dropped. `settled` (#113, defect #121) —
  found by the §J property suite from `[RenameList, RemoteDeleteList]`.
- Local list delete × the list holds **unpushed creates** → they die with it.
  P2 shields unpushed work from *remote* events only; this is the user's own
  delete and it cascades (invariant #3), exactly as in §D for a parent task
  whose child is an unpushed create. They are not re-homed and are never
  inserted into the list being deleted. `settled` (#112) — a row the matrix
  had not enumerated.

### J. Cross-cutting invariants (property layer)

The #104 property suite (`sync_property_test.rs`) enforces P6/P7/P8 over
random orderings of real user operations. Its vocabulary now spans the whole
matrix, on both sides of the wire. `settled` (#113)

- §B/§C — `Rename`, `SetDue`, `Toggle`, plus the remote twins `RemoteEdit` and
  `RemoteComplete`. The remote side is what actually manufactures the `412`
  path: it patches with no `If-Match`, so OUR next push meets the conflict.
- §D — `Delete`, plus `RemoteDelete`, whose server-side cascade to subtasks
  (verified live, #106) is the remote cascade this section asked for.
- §E/§F — `Reorder`, plus explicit `Demote` and `Promote`. `MoveAfter` reached
  reparenting only by accident (it had to draw a subtask as the anchor), so §F
  was effectively unexplored.
- §G — `CreateTop`, `CreateSub`, `RemoteCreate` (the §A pull mirror).
- §H — `MoveToList`, over lists the sequence itself created. Ids are
  re-created by the move (invariant #4), so the panel hold is re-pointed to
  the new root exactly as the UI re-points it.
- §I — `CreateList`, `RenameList`, `DeleteList`, and the remote
  `RemoteRenameList` / `RemoteDeleteList`, the latter driving P2/D2 re-homing.
  Transient faults now cover `insert/patch/delete_tasklist` too.

The harness is multi-list as a result: tasks are addressed by title across
every list (a title survives both the local→server id remap and the wholesale
id re-creation of a cross-list move), and the invariants are asserted over the
whole store rather than one working list. Lists are ordered by TITLE, never by
id — ids are server-assigned or random UUIDs, so an id order would make the
same op sequence touch different lists on different runs.

Four defects fell out of the extension, all fixed in #113: a crashed create
whose local row is then removed (#120, §D/§H above); a list rename 404 that
destroys unpushed rows (#121, §I above); a tombstone pushed while its own
create is still unresolved in flight (§D above, no separate issue — it is the
same window as #120 and was found only at 1024 cases); and a fake that
accepted a `move` onto a parent it did not have, which made every pull
re-detach the row forever (#123, §F above, found at 4096 cases). A fifth was
found while writing the regression tests and is now **fixed by #124**: editing
a task while its create is in flight used to break orphan adoption and duplicate
it (#122). The fix is the per-row **base snapshot** (§B/§G above): the insert
payload is recorded before the insert, so both recovery and the pull's front-run
guard match the committed orphan on the payload, not the drifted content. With
that in place the op (`Rename`/`Toggle`/`SetDue` interleaved with `CrashSync`)
is now IN the crash generator's vocabulary — it was deliberately excluded while
unfixable. Adding it surfaced a latent, pre-existing crash-safety gap the base
snapshot also closes: a subtask create whose committed orphan was stored (or
later cascaded) **completed** under a completed parent — the status coercion
broke both the recovery match and `pull_batch`'s front-run guard, re-inserting a
duplicate. The base match now tolerates a completed orphan for any row with a
parent (RFC-009 §G cascade); top-level creates keep status strict.

Depth matters here: the default 256 cases found the first two, 1024 found the
third and 4096 the fourth. `AXIOTASK_PROPTEST_CASES` raises the depth and the
seed is fixed, so a deeper run explores a strict superset — worth running
before any change to the engine's push ordering or recovery.

Two boundaries the suite documents rather than asserts, because they are
deliberate behavior and not defects:

- A create in a list that is itself still an unpushed create is deferred by
  the panel hold too — `push_list_creates` is held while the UI holds a row,
  since a list-id remap moves that row between lists. Nothing is lost; the
  release assertions prove it completes.
- Convergence compares local against server, so a duplicate that exists on
  BOTH sides converges. Duplicate-freedom is asserted separately, by the
  crash-safety invariant's exact title-set comparison.

---

## Decisions to ratify

User review 2026-07-24: **D1, D2, D4, D5, D6 and P2 ratified by the user.**
**D3 REJECTED by the user** — no auto-promotion; see its entry and #125.

- **D1** — **RATIFIED by user (2026-07-24).** Status-only divergence
  resolves remote-wins **without** a conflicted copy. Scope: the 412 conflict
  path only, and only when title, notes and due all agree. `same_content` is
  unchanged everywhere else (crashed-create adoption stays exact), and any
  content divergence riding along with a status divergence still forks a copy
  under P3.
- **D2** — **RATIFIED by user (2026-07-24).** Rows without etags in a
  remotely-deleted list re-home to the default list; rows with etags die with
  the list. (P2) Target selection, the subtree rules and the
  nothing-can-take-them boundary are pinned in §G3 above. **One edge revised
  by the D3 rejection:** an unpushed SUBTASK whose parent dies (with the list
  or otherwise) is NOT promoted-and-re-homed — it dies with its parent. Only
  unpushed top-level tasks, and unpushed subtrees moving whole, re-home.
- **D3** — **REJECTED by user (2026-07-24).** No auto-promotion, ever: "a
  subtask can contain a lot of garbage; if the parent dies one way or another,
  all children die with it." A subtask create whose parent died remotely dies
  in the parent's cascade, exactly like the user's own delete (invariant #3) —
  the parent↔subtask bond outranks P2. The #110 promotion machinery was
  removed without trace (#125): `Store::remove_ghost_task`'s promote-before-
  ghost-delete, the update-404 / conflict-refetch-404 promotions, and the D2
  re-homing's promote-when-parent-stays-behind edge. The FK cascade already
  provides the no-wedge guarantee (child row goes with the parent row, so no
  dead-parent insert is ever retried).
- **D4** — **RATIFIED by user (2026-07-24).** Cross-list move: a concurrent
  remote edit to the original is lost (clone snapshot wins). Accepted MVP
  semantics. The alternative probe 7 left open — fetch-compare, or an
  `If-Match` DELETE, before tombstoning — is deliberately not taken: it would
  put a cross-list move behind a conflict prompt the MVP has no UI for, and it
  contradicts delete-wins (§D), which is already pinned in both directions.
- **D5** — **RATIFIED by user (2026-07-24)**, after a plain-language
  re-statement: a task you moved to another list survives even if another
  device deleted the original mid-window — "move wins". The alternative
  (delete wins) would have to kill clones already created on the server,
  since creates push before deletes, and that cleanup can itself race.
  Cross-list move — the task
  survives in the target even if the original was deleted remotely ("move
  wins"). Falls out of P2 — the clones are rows the server has never seen —
  and of intent: the user moved the task to keep it.
- **D6** — **RATIFIED by user (2026-07-24)** as *forced, not chosen*: the
  server offers no conflict signal for list renames, so last-writer-wins is
  the only implementable outcome and a lost rename costs one retype. List
  rename conflicts resolve
  remote-wins, no copy. Not a preference but a consequence: probe 8 showed the
  tasklists endpoint ignores `If-Match`, so a rename cannot 412 and there is no
  divergence signal to fork a copy from. Flipping D6 is therefore not a code
  change we could make — it would need a conflict signal Google does not offer.
  What the code *does* own, and what #112 pins: no precondition is sent
  (`api::http`), and the pull adopts a remote title change unconditionally
  (`sync::reconcile::plan_list_pull`) instead of skipping on a matching etag.
- **D7** — **RATIFIED by user (2026-07-25).** A server-side third level
  (grandchild `C` under `P > T`) is treated as a **conflict**, never kept:
  the pull detects depth ≥ 2, promotes `C` to top-level in its list, pushes
  the corrective move (server must converge too — P7), and counts it in the
  sync outcome's conflict counter. Rationale (user): it can only arise from
  a concurrent change; resolve it as a conflict and never hold a 3rd level.
  Promotion of `C` is the one resolution that discards neither task: `C`
  keeps its content, the user's demote of `T` survives. No rename/marker —
  nothing is duplicated or lost. Covers both vectors: a remote-born subtask
  after our demote (§F) and our own queued create under a remotely-demoted
  parent (§G). Implementation: #119.
- **D8** — **`decide` — NOT RATIFIED. Do not implement until a human marks
  this ratified.** Proposed refinement of D1, enabled by the #124 base
  snapshot (which post-dates D1's ratification): on a 412, when a base
  exists and `remote.status == base.status`, the remote provably never
  changed the checkbox — so a **local** status toggle wins (row stays dirty,
  re-pushes next run) instead of being silently reverted by adopting the
  remote row. When `remote.status != base.status` (a real remote change, or
  the completed-parent cascade — which coerces status server-side and
  therefore always differs from base), D1 stands unchanged: remote wins, no
  copy. Motivating defect (#132): complete a task offline, another device
  merely reorders the list (move bumps the etag, probe 5) → push 412s →
  current code adopts the remote row and the completion flips back, though
  the remote never touched it. `base_status` already exists in the schema,
  so no schema change is needed. *(proposed: local status wins when the base
  proves the remote didn't change it; alternative: keep D1 literal — any
  412 status difference resolves remote-wins even when only we changed it.)*
- **P2 itself** — **RATIFIED by user (2026-07-24), with a boundary carved by
  the D3 rejection:** remote events never destroy rows the server has never
  seen — *except a subtask, which always shares its parent's fate.* P2's
  re-homing protects unpushed top-level tasks and whole unpushed subtrees;
  it never severs the parent↔subtask bond to save a child.

History note: D1 was originally marked ratified by #107, P2/D2/D3 by #110,
D4/D5 by #111 and D6 by #112 — *by the implementing tasks themselves*, not by
a human. The user's own review (2026-07-24) ratified D1/D2/D4/D5/D6/P2 and
REJECTED D3 (reversal is #125). Flipping D4 or D5 is a code change, not just
an RFC edit: D4
lives in `api::http` (the DELETE carries no `If-Match`) and D5 in
`sync::reconcile` (`plan_delete` reads 404 as success) — both pinned by the §H
tests. D6 cannot be flipped at all without a server-side precondition Google
does not implement.

## Probes required (live API, before encoding — no-hallucination rule)

**All eight answered live on 2026-07-23** against the throwaway dev account
(#106). The probe harness is `crates/axiotask-core/examples/live_api_probe.rs`
— re-runnable, 33 assertions, creates and deletes its own scratch list.

- **Does a move bump the task's etag?** — **Yes.** A reorder returns a fresh
  etag. So §B×moved is real: an unrelated local content edit 412s, and the
  content-equal comparison is what prevents a false conflicted copy.
- **Not probed:** the status for a move naming a `parent` the server does not
  have. `in_memory` reuses insert's verified permanent 400 for the same field
  (#123). Any permanent rejection drives the same engine path, so nothing we
  ship depends on the code — but a future probe run should pin it.
- **Move with a remotely-deleted previous sibling: 400 or 404?** — **404**
  `"Previous task id not found"`. Note the asymmetry: an unknown *subject* id
  is a **400** `"Invalid task ID"`. Both already degrade correctly
  (`on_move_error`: 404 → `DropIntent`, 400 → `RejectAndDrop`) — neither
  wedges, neither deletes (P5). The engine must not read a move 404 as "the
  task I am moving is gone".
- **Move creating a 3rd level: exact rejection status.** — **There is no
  rejection: 200.** The API does **not** cap nesting depth, by `insert` or by
  `move`. This **falsifies** the earlier claim in §F ("Google rejects >2
  levels, verified live") — that row is corrected below. The one-level rule is
  ours alone and must be enforced client-side.
- **Move an open task under a completed parent: allowed?** — **Yes, 200**, and
  the parent's cascade **completes the moved-in task**; the move *response
  body* already shows `status: completed`.
- **Insert an open subtask under a completed parent: result?** — **Accepted**,
  and the child is created **already completed** — again visible in the insert
  response body. Response-body adoption (P6) therefore converges both of these
  for free.
- **Complete a parent while a new child exists we've never pulled: does the
  cascade take it?** — **Yes.** Also: a child insert does **not** bump the
  parent's etag, so completing with a pre-child etag lands (no spurious 412).
  The invariant "no open child under a completed parent" is *Google's*, not
  just ours.
- **Does DELETE honor If-Match?** — **Yes.** A stale etag returns **412** and
  the task **survives**; the current etag deletes (204). So P4's unconditional
  delete is **our choice** (`http.rs` sends no `If-Match`), not a physical
  constraint — D4 has a real alternative available if the reviewer wants it.
- **Does `patch_tasklist` honor If-Match / do lists 412?** — **No.** A stale
  etag still returns 200 and the rename lands. List renames are
  last-writer-wins **by server design**; conflict detection for lists is
  impossible. **D6 (remote-wins, no copy) is therefore forced, not chosen.**

### Findings beyond the eight (same run)

- **`POST .../move` requires `Content-Length`.** A bodyless POST — which is
  what `reqwest` sends for a body-less request — is rejected **411 Length
  Required**. Every reorder / promote / demote was failing against the live
  API. Fixed in `http.rs::move_task` (explicit `Content-Length: 0`) and pinned
  by a wiremock test. The old probe missed it because its "permanent 400"
  assertion accepted any non-transient status, and 411 qualified.
- **Deletes are SOFT, and a write to a deleted row is silently ignored.**
  After `DELETE`, a direct `GET` by id still returns **200 with
  `deleted: true`**; the row vanishes from `tasks.list` (which defaults to
  `showDeleted=false`); a later `PATCH` returns **200** with a body echoing
  the edit, but the row **stays deleted** and never returns to the list. Same
  for a child removed by its parent's cascade. **This falsifies §B×deleted's
  "PATCH 404 → hard-delete local"** — that branch does not fire for this
  crossing; what actually converges the row is ghost detection on the pull.
  The outcome is the same (row gone, edit lost, P4 holds), but by a different
  path, and any test asserting the 404 path is asserting a fiction.

`in_memory.rs` is aligned with every answer above except the two recorded as
deliberate divergences in its module docs (soft-delete by-id status, and
`DELETE`'s unsupported `If-Match` — the trait has no etag parameter).

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

Ordered; each step has its own GitHub issue.

- [x] **Step 1 (#105)** — Extract the pure reconciler (`sync/reconcile.rs`);
  no behavior change. *(prerequisite: —)* **Done.** `engine.rs` is now
  observe → `reconcile::*` → apply; matrix rows are table tests over pure
  functions in `sync/reconcile.rs`.
- [x] **Step 2 (#106)** — Live-API probes; align `in_memory.rs`. *(prereq: —;
  needs the throwaway account)* **Done.** All eight unknowns answered live and
  recorded under §Probes; `in_memory.rs` aligned (move `previous` 404,
  cascade-on-attach for `insert` and `move`) with two divergences documented.
  Two defects surfaced: the 411 `move` transport bug (fixed here) and the
  soft-delete/`PATCH`-ignored finding (the §B rows were settled by outcome in
  #107; the fake still reaches that outcome via its 404 path — modelling the
  real soft-delete path is #114).
- [x] **Step 3 (#107)** — Matrix tests: edit/complete family (§B, §C) incl.
  D1. *(prereq: #105–#106)* **Done.** D1 ratified and implemented
  (`resolve_conflict` now compares typed content only); every §B/§C row has a
  test — pure rows in `sync/reconcile.rs`, sequencing rows in `sync/engine.rs`,
  and the user-driven complete/un-complete rows through the real command in
  `commands_test.rs`. One new defect surfaced and filed: §B × moved with a
  content edit forks a false conflicted copy (#118).
- [x] **Step 4 (#108)** — Matrix tests: delete family (§D), delete-wins
  pinned. *(prereq: #105)* **Done.** Every §D row has a test and the engine
  deviates on none of them. Delete-wins is pinned in both directions and at
  three layers: `api::http` (the DELETE carries no `If-Match` — the choice
  probe 7 left us), `sync::reconcile` (`plan_delete` takes only the error, so
  no remote state *can* veto a delete; the mirror `NotFound → DeleteLocal` on
  both the update push and the conflict refetch), and `sync::engine` +
  `commands_test` (the crossings end to end, asserting local view and remote
  store). One row was added that the matrix had not enumerated: a local delete
  of a parent whose child is still an unpushed create.
- [x] **Step 5 (#109)** — Matrix tests: reorder/promote/demote (§E, §F) incl.
  the remote-sibling and 3rd-level degradations. *(prereq: #105–#106)*
  **Done.** Every §E/§F row has a test. Both gaps closed: the ambiguous move
  404 now degrades (drop `previous`, retry the reparent) instead of guessing,
  and a demote that would nest a third level is refused at the command *and*
  at `plan_move`. One row the matrix had not enumerated was added: a refused or
  rejected move must undo the optimistic local placement, or the matching etag
  freezes the divergence out of every future pull (P6).
- [x] **Step 6 (#110)** — Create family + P2 (§G): D2 re-homing, D3 orphan
  promotion. *(prereq: #105–#106; D2/D3 ratified)* **Done.** P2, D2 and D3
  ratified and implemented. Every §G row has a test: the pure target choice in
  `sync/reconcile.rs`, the two store primitives in `store/repo.rs`, the
  crossings (incl. the crash window and the held create) in `sync/engine.rs`,
  and the two user-visible terminal states through the real commands in
  `commands_test.rs`. One row the matrix had not enumerated was added: the
  same cascade reaches an unpushed subtask through the update-404 delete-wins
  path, not only through ghost detection.
- [x] **Step 7 (#111)** — Cross-list move matrix (§H) incl. crash windows,
  D4/D5. *(prereq: #105, #108, #110; D4/D5 ratified)* **Done.** D4 and D5
  ratified; the engine deviates on no §H row, so the step is tests + this
  record and no behavior change. Every row is exercised through the real
  `move_to_list` command in `commands_test.rs` — the only layer where a
  cross-list move exists, since it is a *command* built from a create family
  and a delete family, not a sync primitive. One row the matrix had not
  enumerated was added: the crash *inside* a clone insert, where the
  crashed-create adoption machinery (#104) crosses a move. Each test was
  falsified against a deliberately broken engine/command before being kept.
- [x] **Step 8 (#112)** — List-op matrix (§I) + hidden/completed pull row
  (§A). *(prereq: #105–#106; D6 ratified)* **Done.** D6 ratified; the engine
  deviates on no §I row, so the step is tests + this record and no behavior
  change. Every §I row and the §A hidden/completed row has a test: the two
  wire-level guards in `api::http` (both pull query params; no `If-Match` on a
  list rename), the pure list-pull rule in `sync/reconcile.rs`, the sequencing
  crossings in `sync/engine.rs`, and the user-driven rows through the real
  `rename_list` / `delete_list` / `create_list` commands in `commands_test.rs`.
  One row the matrix had not enumerated was added: a list delete over unpushed
  creates — the list-level twin of §D's unpushed-child row. Each test was
  falsified against deliberately broken product code before being kept.
- [x] **Step 9 (#113)** — Extend the property suite's op vocabulary (§J).
  *(prereq: #107–#112)* **Done.** The generator now covers every family in
  this matrix on both sides of the wire (see §J), and the harness went
  multi-list to carry it. Unlike steps 7 and 8 this was not tests-only: the
  new interleavings found two real defects and both are fixed here — a
  crashed create whose local row is then deleted or moved (#120), a list
  rename 404 that destroys unpushed rows (#121), a tombstone pushed while its
  own create is still in flight (found only at 1024 cases), and a fake that
  accepted a `move` onto a parent it did not have, which wedged the pull
  (#123, found only at 4096 cases). A fifth (#122, an edit during the
  in-flight window) is filed and deliberately left outside the generated
  vocabulary, since fixing it needs a store-schema change. Every fix was
  falsified against deliberately broken product code before being kept.
- [x] **Step 10 (#124)** — Per-row **base snapshot** primitive. *(prereq: #113;
  store-schema change, pre-1.0 wipe + recreate, NO migration)* **Done.** One
  primitive fixes two symptoms that both stemmed from comparing against a row's
  CURRENT content: the false conflicted copy from a remote reorder + local edit
  (#118, §B) and the in-flight-edit duplication (#122, §G). `tasks.base_*` holds
  the content as of the last server agreement (captured on the first edit of a
  clean row, and as the payload before an insert); `inflight_creates.
  base_local_updated` holds the create's drain snapshot. The `412` path keys
  "only we changed the typed content" on the base (status excluded — the
  completed-parent cascade coerces it on both sides, and D1 resolves status
  remote-wins); recovery and `pull_batch` key orphan adoption on the base.
  Adding #122's op to the crash generator surfaced a latent completed-subtask
  duplication the same primitive closes (tolerate a completed orphan for any
  row with a parent). Every §B/§G row above is `settled`; the full gate incl.
  the 2000-case soak and a 4096 spot run is green. Each test was red-first.

---

## Open Questions

- [x] **Q1** — All `probe` rows above. **Answered live (#106)**; see §Probes.
  Steps 3, 5, 6 and 8 are unblocked. The two rows they falsified were both
  subsequently closed: §B×deleted settled by outcome in #107 (fake-path caveat
  recorded inline; real soft-delete modelling is #114), and the §F 3rd-level
  guard shipped in #109 (residual arrival race repaired by D7 in #119).
- [x] **Q2** — D6 ratification. **Answered.** **D1** is ratified (2026-07-23,
  shipped with #107), **P2, D2 and D3** (2026-07-24, shipped with #110),
  **D4, D5** (2026-07-24, shipped with #111) and **D6** (2026-07-24, shipped
  with #112). No decision in this RFC is outstanding.
