# RFC-004: Sync Engine

| Field         | Value                          |
|---------------|--------------------------------|
| Status        | Implemented                    |
| Author(s)     | Illya Yalovyy                  |
| Reviewers     | Sync expert, Senior engineer   |

---

## Summary

Bidirectional sync between the local SQLite cache and the Google Tasks API.
Local writes are instant and offline-capable; a background engine pushes local
mutations and pulls remote changes, reconciling with a documented rule set.

---

## Goals

- **G1** Local-first: UI writes never block on the network.
- **G2** Offline mutations replay correctly on reconnect.
- **G3** Conflicts resolve deterministically (remote-wins for MVP).
- **G4** Idempotent: a no-op sync writes nothing; replaying a dirty row converges.
- **G5** Crash-resumable: a partial run leaves a consistent, retryable state.

## Non-Goals

- Real-time push/webhooks (polling + on-demand triggers suffice).
- Field-level 3-way merge (last-writer/remote-wins).
- Multi-device conflict richness (single user, single backend).

---

## Why this approach is sound

Google Tasks is a **row-state CRUD API** (not an op-log or CRDT backend). For a
single-user local cache over such an API, **dirty-flag reconciliation** is the
standard, correct model:

- Each cached row carries `sync_state` (clean/dirty/deleted) and `pending_op`.
- Push drains dirty rows and applies them via the matching REST verb.
- Pull mirrors server state into clean rows.

We explicitly rejected two alternatives:

- **Operation log / CRDT** — overkill; Google's API is row-state, so ops would
  be flattened to row writes anyway. Adds complexity with no payoff for one user.
- **Etag-only diffing** — can't survive offline edits (no local "base" snapshot).

This is a deliberate, appropriate choice — not a default. The risks below are
the *known* sharp edges of this model, each handled or explicitly accepted.

---

## Engine

A sync run (`SyncEngine::run`) is **serialized by a mutex** (no overlapping
runs) and always records a `sync_log` row (counts, duration, error).

### Push (in order)

1. **Parent creates** first (so children can reference real parent ids).
2. **Remaining ops** by `drain_dirty` priority: create → update → delete.
   - **create** → `insert_task`; on success `finish_create` atomically remaps
     local→remote id (self, children, move intents) **and** marks clean in one
     transaction.
   - **update** → `patch_task` with `If-Match` etag.
   - **delete** → `delete_task`; `404` is treated as success (already gone).
3. **Moves** (reorder/reparent) via the `move_task` endpoint, from the
   `pending_moves` table — a separate axis from field updates, mirroring
   Google's patch-vs-move API split.

### Pull

1. List task lists; upsert.
2. Per list, fetch all pages. Skip rows that are locally dirty (preserve intent).
3. Upsert remote rows whose etag differs from local (idempotent skip otherwise).
4. **Ghost detection:** clean local rows absent from a *complete* remote
   response are deleted (server-side deletions). Skipped if pagination hit a
   transient error (incomplete view must not trigger deletes).

---

## Conflict resolution

| Local | Remote | Resolution |
|---|---|---|
| clean | etag differs | Take remote (clean = no local intent). |
| dirty create | insert ok | `finish_create`: remap + clean (atomic). |
| dirty update | patch ok | Mark clean with server etag. |
| dirty update | `412` stale etag | **Remote wins:** mark clean; next pull overwrites. |
| dirty any | `404` | Hard-delete local (server already removed it). |
| dirty any | transient (5xx/network) | Leave dirty; retry next run. |

---

## Failure modes & hazards (senior-engineer review)

Honest catalog of the sharp edges and how each is handled.

### H1 — Duplicate-on-crash for creates *(inherent, accepted)*
Google's `insert` has **no client idempotency key**. If the app crashes *after*
the server creates the task but *before* the local commit, the next run
re-inserts → a duplicate task on the server. We cannot fully prevent this
without an idempotency token Google does not offer.
**Mitigation:** `finish_create` makes the local remap+clean atomic, eliminating
the *half-applied* state (which previously could both duplicate *and* corrupt
local ids). The residual window (crash between server ack and local commit) is
rare and self-healing on the user's side (delete the dup). **Accepted for MVP.**

### H2 — Silent edit loss on conflict *(accepted, needs UI signal)*
"Remote wins" on `412` discards the local edit with no user-facing notice.
The engine counts conflicts (`SyncOutcome.conflicts`); surfacing a toast
("a remote change overrode your edit") is **Step 9 / RFC-006** and is the top
remaining UX risk. Until then, conflicts are logged.

### H3 — Crash-resumability *(handled by design)*
No transaction spans a whole run. Each row's push is independent; a partial run
leaves remaining dirty rows for the next run and pull re-reconciles. Per-row
operations that touch multiple rows (`finish_create`) are transactional.

### H4 — Ghost detection vs. partial pull *(handled)*
Deleting "local rows missing from remote" is only safe with a *complete* remote
view. A transient pagination error sets `complete = false` and **skips** ghost
detection for that list, preventing false deletions.

### H5 — Concurrent syncs *(handled)*
A mutex serializes runs. Without it, two runs could `drain_dirty` the same rows
and double-push. Covered by `concurrent_syncs_do_not_double_push`.

### H6 — Full fetch every pull *(perf, deferred)*
No `updatedMin`; every pull fetches all tasks. Fine for typical list sizes;
optimize with per-list `updatedMin` + periodic full sweep post-MVP.

### H7 — Move targeting a server-unknown task *(handled)*
A `pending_move` whose task 404s on the move endpoint drops the stale intent
(no infinite retry). FK cascade also clears moves when a task is hard-deleted.

---

## Scheduler

| Trigger | Delay |
|---|---|
| App launch | immediate |
| Local mutation | 2s debounce (coalesces bursts) |
| Periodic | 60s |
| Reconnect | covered by periodic (explicit detection deferred) |

The debounce/period decision (`wait_for_sync_trigger`) is unit-tested with a
paused clock.

---

## Status

All MVP steps implemented and tested (engine, store, HTTP client via wiremock,
scheduler timing, concurrency). Remaining: **H2 conflict toast** (RFC-006) and
**H6 `updatedMin`** (perf). Both are enhancements, not correctness gaps.

## Open questions

- **Q1** Conflict UI copy/UX — RFC-006.
- **Q2** `updatedMin` clock-skew padding (≈5s) when implemented.
- **Q3** Should H1 duplicates be detected by a post-create dedup sweep
  (title+list heuristic)? Likely not worth it; revisit if reported.
