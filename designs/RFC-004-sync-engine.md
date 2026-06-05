# RFC-004: Sync Engine

| Field         | Value         |
|---------------|---------------|
| Status        | Active        |
| Author(s)     | Illya Yalovyy |
| Reviewed by   | Sync Expert   |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

Bidirectional sync between the local SQLite store and Google Tasks API.
The engine pulls remote changes into the cache, pushes local dirty rows out,
and resolves conflicts predictably.

---

## Goals

- **G1** — Local-first writes always succeed instantly; the network is asynchronous.
- **G2** — Offline mutations replay correctly on reconnect.
- **G3** — Conflicts resolve deterministically with a documented rule set.
- **G4** — Sync is idempotent — replaying the same dirty row produces the same outcome.
- **G5** — A sync run never corrupts data on failure; it is transactional at the per-record level.

## Non-Goals

- Real-time sync (webhooks/push). Polling + on-demand triggers are enough.
- Three-way merge of `notes` field. Last-writer-wins by `updated` timestamp.
- Cross-list moves via a single API call (Google doesn't support it natively).

---

## Architecture

```
┌──────────┐   push dirty   ┌─────────────────┐
│  SQLite  │ ─────────────→ │  Google Tasks   │
│  Store   │ ←───────────── │  API            │
└──────────┘   pull remote   └─────────────────┘
      ↑
      │ reads/writes
      ↓
┌──────────┐
│  UI      │  (never blocks on sync)
└──────────┘
```

### Phases of a sync run

1. **Push** dirty rows. Order: creates → updates → deletes.
   - Creates: parents before children (by tree depth).
   - After successful create: remap local UUID → remote ID.
2. **Pull** all lists + tasks per list.
   - Skip rows that are locally dirty (preserve local intent).
   - Insert parents before children (FK safety).
3. **Reconcile** — handle 412 (stale etag) during push.

### Single-mutex concurrency

One `Mutex` guards a sync run — no overlapping syncs. UI writes never wait.

---

## Conflict Resolution

| Local state | Remote state | Resolution |
|---|---|---|
| `clean` | newer `updated` | Remote overwrites local. |
| `dirty` (create) | push succeeds | Mark `clean`, remap ID. |
| `dirty` (update) | push succeeds (etag matches) | Mark `clean`. |
| `dirty` (update) | push fails `412` | **Remote wins for MVP**. Mark local `clean` on next pull. |
| `dirty` (delete) | push succeeds or `404` | Hard-delete local row. |
| `dirty` (any) | server returns `404` | Hard-delete local row (server already removed it). |
| `dirty` (any) | transient error (5xx, network) | Skip, retry next run. |

**Future (post-MVP):** On 412, pull remote version and do field-level merge:
- `title`, `notes` → newer `updated` wins
- `status` → newer wins
- `position` → local wins if not yet synced, else remote
- `due` → newer wins

---

## Expert Review Findings

### Critical issues in current implementation

**1. `drain_dirty` reads then relies on stale data.**
The pull phase calls `drain_dirty()` to build a skip-set of dirty IDs. But `drain_dirty()` also returns the *rows* for pushing. If push mutates the store (remap, mark clean, delete), the skip-set computed before pull is stale. Currently this is fine because push runs before pull, but the code is fragile.

**Fix:** Separate "get dirty IDs for skip-set" from "get dirty rows for push". The skip-set should be computed *after* push completes, right before pull starts.

**2. `resolve_conflict` is a no-op.**
On 412, the engine logs a conflict count but takes no action. The dirty row remains dirty with a stale etag. On next sync, it will 412 again forever — an infinite conflict loop.

**Fix:** On 412, mark the local row `clean` and let the next pull overwrite it (remote-wins). This is the documented MVP strategy but isn't implemented.

**3. Pull doesn't detect server-side deletions.**
If a task is deleted on the server, it simply doesn't appear in the pull response. But the local `clean` copy remains forever — a ghost row.

**Fix:** After pulling all tasks for a list, compare against local `clean` rows. Any local clean row not present in the remote response should be hard-deleted. (Dirty rows are exempt — they haven't been pushed yet.)

**4. No `updatedMin` optimization.**
Every pull fetches ALL tasks for every list. For users with hundreds of tasks, this is wasteful and slow.

**Fix (post-MVP):** Track `last_sync_at` per list. Use `updatedMin` parameter on `list_tasks`. Still needs occasional full sweep to detect server-side deletions.

**5. `sync_log` table exists but is never written to.**
The schema has `sync_log` but the engine doesn't record outcomes.

**Fix:** Write a row to `sync_log` after each run. Useful for debugging.

### Recommendations for safe push re-enablement

1. Fix #2 (conflict loop) — **required before enabling push**.
2. Fix #3 (ghost rows) — **required for data correctness**.
3. Fix #1 (stale skip-set) — low risk currently but should be cleaned up.
4. Fix #5 (sync_log) — useful for debugging but not blocking.
5. Fix #4 (updatedMin) — performance optimization, defer.

---

## Scheduler (Step 6)

| Trigger | Delay | Notes |
|---|---|---|
| App launch | 0 (immediate) | Already implemented. |
| After local mutation | 2s debounce | Coalesce rapid edits. |
| Periodic (app focused) | 60s | Catch remote changes. |
| Periodic (app backgrounded) | 5min | Battery friendly. |
| Network reconnect | 0 | Not yet detectable in Tauri without plugin. Defer. |

---

## Development Plan (Updated)

- [x] Step 1 — Pull (no conflicts)
- [x] Step 2 — Push creates (with id remap)
- [x] Step 3 — Push updates with etag
- [x] Step 4 — Push deletes
- [ ] **Step 5a** — Fix conflict loop: on 412, mark clean + let pull overwrite
- [ ] **Step 5b** — Fix ghost rows: detect server-side deletions during pull
- [ ] **Step 5c** — Fix stale skip-set: recompute after push
- [ ] **Step 6** — Scheduler (debounced + periodic)
- [ ] **Step 7** — Write sync_log after each run
- [ ] **Step 8** — Re-enable push (config-driven, remove hardcode)
- [ ] **Step 9** — UI: sync status indicator + conflict toast

---

## Open Questions

- **Q1** — Field-level merge: defer to post-MVP. Remote-wins is acceptable.
- **Q2** — `updatedMin` clock skew: pad by 5 seconds. Defer to post-MVP.
- **Q3** — User notification on conflict: show toast "Remote change overrode your edit for {title}". Implement in Step 9.
- **Q4** — Rate limiting: honor `retry_after` header, skip that list, continue. Already handled by `is_transient()`.
