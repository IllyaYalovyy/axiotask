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

Lists and tasks both follow the dirty-flag model. Ordering guarantees
referential validity on the server:

1. **List creates** first — a task can't be inserted into a list that doesn't
   exist remotely yet. `insert_tasklist`, then `remap_list_id` rewrites the
   local list UUID → server id across the list row, all its tasks' `list_id`,
   move intents, and in-flight markers (one transaction). Adopts an existing
   remote list of the same title instead of duplicating (covers default
   "My Tasks").
2. **Parent task creates** (so children can reference real parent ids).
3. **Remaining task ops** by `drain_dirty` priority: create → update → delete.
   - **create** → `insert_task`; `finish_create` atomically remaps id (self,
     children, move intents) and marks clean. In-flight marker for crash safety.
   - **update** → `patch_task` with `If-Match` etag.
   - **delete** → `delete_task`; `404` treated as success.
4. **Moves** (reorder/reparent) via `move_task`, from `pending_moves` — a
   separate axis from field updates, mirroring Google's patch-vs-move split.
5. **List renames/deletes** last (after task ops, so a deleted list's task
   tombstones push first): `patch_tasklist` / `delete_tasklist`.

### Pull

1. List task lists; upsert.
2. Per list, fetch all pages. Skip rows that are locally dirty (preserve intent)
   **and** remote rows whose content matches a pending in-flight create — those
   are the (possibly committed) result of an interrupted create and must be
   adopted by id-remap, not pulled as a separate clean row (which would both
   duplicate and cause a PK collision on the next recovery).
3. Upsert remote rows whose etag differs from local (idempotent skip otherwise).
4. **Ghost detection:** clean local rows absent from a *complete* remote
   response are deleted (server-side deletions). Skipped if pagination hit a
   transient error (incomplete view must not trigger deletes).

### Create attempt discipline

A parentless create is attempted **exactly once per run** (pass 1); the second
pass pushes only child creates. Re-attempting a parentless create in the same
run could double-insert one whose response timed out after the server
committed it — the in-flight orphan recovery only runs at the *start* of a run,
not between passes.

---

## Conflict resolution

| Local | Remote | Resolution |
|---|---|---|
| clean | etag differs | Take remote (clean = no local intent). |
| dirty create | insert ok | `finish_create`: remap + clean (atomic). |
| dirty update | patch ok | Mark clean with server etag. |
| dirty update | `412` stale etag, identical content | Adopt remote etag (no real divergence). |
| dirty update | `412` stale etag, divergent content | **Conflicted copy:** remote becomes canonical; local edit kept as a new "(conflicted copy)" task. Nothing lost. |
| dirty update | `412` then `404` on refetch | Hard-delete local (server removed it). |
| dirty any | `404` | Hard-delete local (server already removed it). |
| dirty any | transient (5xx/network) | Leave dirty; retry next run. |

---

## Failure modes & hazards (senior-engineer review)

Honest catalog of the sharp edges and how each is handled.

### H1 — Duplicate-on-crash for creates *(RESOLVED — in-flight recovery)*
Google's `insert` has no idempotency key, so a crash between the server ack
and the local commit could re-insert → a duplicate. Two-part fix:
- `finish_create` makes remap + mark-clean atomic (no half-applied state).
- An `inflight_creates` marker is written *before* the insert and cleared in
  the finalize transaction. On the next run, `recover_inflight_creates` looks
  for an orphaned remote task (our exact content, an id we never recorded) and
  **adopts** it via `finish_create` instead of re-inserting. If no orphan
  exists the insert never landed, so the marker is cleared and the create
  retries normally.
This is scoped strictly to in-flight creates — it is **not** a general dedup
sweep, so it can never merge unrelated tasks. Covered by
`crash_during_create_adopts_orphan_no_duplicate` and
`crash_before_insert_reached_server_reinserts`.

### H2 — Edit loss on conflict *(RESOLVED — conflicted copy)*
A `412` no longer discards the local edit. The engine refetches the remote
task; if content is identical it simply adopts the etag, otherwise it keeps the
remote as canonical AND preserves the local edit as a new "(conflicted copy)"
task (Dropbox model). Nothing is silently lost, and the copy is its own visible
user signal — no clock comparison, no toast needed. This deliberately avoids
last-writer-wins-by-timestamp, which is unsound across local vs. server clocks.

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

### H8 — Pull vs. live edit race *(handled)*
The sync loop and Tauri command handlers run concurrently on the same runtime
with no lock between them. Pull snapshots the dirty skip-set, then upserts each
remote row; a UI edit that dirties a task *between* the snapshot and its upsert
would otherwise be clobbered (and its dirty flag cleared) — a lost edit.
`upsert_remote_task` makes skip-if-dirty atomic with the write
(`ON CONFLICT DO UPDATE … WHERE sync_state = 'clean'`), and ghost deletion uses
`delete_task_hard_if_clean`. A concurrently-dirtied row is never overwritten or
deleted by pull; its edit pushes next run. Covered by
`upsert_remote_task_does_not_clobber_dirty` / `delete_task_hard_if_clean_spares_dirty`.

### H6 — Full fetch every pull *(deliberate: correctness over perf)*
Every pull fetches all tasks. This is *correct* and also powers ghost
detection. `updatedMin` would reduce bandwidth but adds clock-skew and
missed-deletion failure modes. Full fetch is the rock-solid default; revisit
only if profiling demands it (then with a periodic full sweep — see Q1).

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

All correctness hazards (H1–H7) are resolved or handled by design — **no
accepted compromises remain**. Implemented and tested: engine, store, HTTP
client (wiremock), scheduler timing, concurrency guard, conflicted-copy
resolution, crash-safe create recovery.

`updatedMin` incremental pull is **intentionally not implemented**: a full
fetch is *correct* (it also drives ghost detection), and `updatedMin` trades
that simplicity for a perf gain plus subtle clock-skew/deletion-detection
failure modes. Keeping the simpler correct path is the rock-solid choice, not
a compromise. It can be added behind a periodic full-sweep if profiling ever
demands it.

## Open questions

- **Q1** If `updatedMin` is ever added for perf, pad the cursor by ~5s for
  server clock skew and keep a periodic full sweep for deletion detection.
