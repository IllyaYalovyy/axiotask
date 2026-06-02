# RFC-004: Sync Engine

| Field         | Value         |
|---------------|---------------|
| Status        | Draft         |
| Author(s)     | Illya Yalovyy |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

Bidirectional sync between the local store ([[RFC-003-local-sqlite-store]]) and
Google Tasks ([[RFC-002-google-tasks-api-client]]). The engine pulls remote
changes into the cache, pushes local dirty rows out, and resolves conflicts
predictably. It is the most subtle component of the MVP and the largest
source of test surface.

---

## Goals

- **G1** — Local-first writes always succeed instantly; the network is asynchronous.
- **G2** — Offline mutations replay correctly on reconnect (10+ creates, edits, deletes while offline → all land, in order).
- **G3** — Conflicts resolve deterministically with a documented rule set.
- **G4** — Sync is idempotent — replaying the same dirty row produces the same outcome.
- **G5** — A sync run never corrupts data on failure; it is transactional at the per-record level.

## Non-Goals

- **NG1** — Real-time sync (webhooks/push). Polling + on-demand triggers are enough for MVP.
- **NG2** — Three-way merge of `notes` field. Last-writer-wins by `updated` timestamp.
- **NG3** — Cross-list moves (Google API doesn't natively support it; out of MVP).

---

## Background & Motivation

VISION: "Local-first, sync-second… conflicts are resolved predictably." The
UI must remain responsive even when offline or on a slow link, and the user
must be able to trust that no edit silently disappears.

---

## Considered Options

### Option A — Operation log (CRDT-ish)

Local mutations recorded as discrete ops; replayed against remote.

**Pros**: Clean offline replay, full audit trail.
**Cons**: Heavy. Most ops don't compose cleanly with Google's API (which is row-state, not op-stream).

### Option B — Dirty-flag reconciliation (the proposal)

Local rows carry `sync_state` + `pending_op`; reconciler pushes them, then pulls remote, applying conflict rules.

**Pros**: Simple, matches Google's row-state API, easy to test.
**Cons**: Some loss of intent (e.g., A→B→A edits look like no-op locally).

### Option C — Bidirectional diff via etags only

Use etags as the only conflict signal.

**Pros**: Tiniest local state.
**Cons**: Doesn't survive offline edits with no local "old" snapshot.

---

## Decision

**Chosen option: Option B** — dirty-flag reconciliation.

---

## Design

### Phases of a sync run

1. **Push** dirty rows. Order: creates (parents before children, by tree depth) → updates → deletes.
2. **Remap** any local UUIDs that became remote IDs (write to `id_remap`, rewrite `parent_id` of children).
3. **Pull** per list using `updatedMin` = max(`updated`) we've seen for that list, plus a full sweep on first run.
4. **Reconcile** each incoming row against local state per conflict rules below.
5. **Log** outcome to `sync_log`.

### Conflict rules

For a single task `T`:

| Local state | Remote state | Resolution |
|---|---|---|
| `clean` | newer | Remote wins (overwrite local). |
| `dirty`, pushed successfully | echoes back | Mark `clean`. |
| `dirty`, push got `412 Precondition Failed` (stale etag) | conflicting | Pull remote, then **field-level merge**: `status` → newer-wins, `title`/`notes` → newer-wins by `updated`, `position` → local wins if not yet on server, else remote. Mark `dirty` if local change preserved. |
| `dirty` (delete) | server still exists | Push delete with etag; if `412`, treat as "remote changed since" — keep delete intent, retry after pull. |
| `clean` | server deleted | Hard-delete locally. |
| `dirty` (anything) | server deleted | Local wins for `create`/`update` (resurrects task — log warning); local `delete` no-ops. |

### Scheduler

- **On launch**: pull all lists, push any dirty rows from a previous session.
- **On user mutation**: schedule a sync in 2s (debounced).
- **Periodic**: every 60s while app focused; 5min while backgrounded.
- **On network reconnect**: trigger immediately.

### Concurrency

A single `Mutex<SyncState>` guards a sync run — no overlapping syncs. UI
writes never wait on sync.

---

## Testing Strategy

This is the biggest TDD investment.

- **Per-rule tests**: each row of the conflict table → at least one focused test against `InMemoryClient` + `:memory:` SQLite.
- **Property tests** (`proptest`): generate random mutation streams (local + remote), apply, assert convergence.
- **Offline burst test**: simulate 50 local mutations with the client returning network errors; reconnect; assert all land in correct order.
- **Idempotency**: run sync twice with no changes in between; second run must be a no-op (zero writes either side).
- **Fault injection**: use `InMemoryClient::fail_next` to inject `429`, `5xx`, `412` at every step; assert recovery.
- **`sync_log`** asserted by each test to confirm metric accounting.

---

## Development Plan

- [ ] **Step 1** — Per-list pull (no conflicts) + tests *(prerequisite: RFC-002 + RFC-003)*
- [ ] **Step 2** — Push: creates (with id remap) + tests *(prerequisite: Step 1)*
- [ ] **Step 3** — Push: updates with etag, handle `412` → field merge + tests *(prerequisite: Step 2)*
- [ ] **Step 4** — Push: deletes (incl. tombstone handling) + tests *(prerequisite: Step 3)*
- [ ] **Step 5** — Conflict resolution full table + property tests *(prerequisite: Step 4)*
- [ ] **Step 6** — Scheduler (startup / debounced / periodic / reconnect) *(prerequisite: Step 5)*
- [ ] **Step 7** — `sync_log` + observable `SyncStatus` event for UI badge *(prerequisite: Step 5)*

---

## Open Questions

- [ ] **Q1** — Field-level merge for `notes` — do we attempt a textual 3-way merge, or strictly last-writer-wins? MVP: last-writer-wins.
- [ ] **Q2** — `updatedMin` is per-list; do we trust server clock skew, or pad by N seconds?
- [ ] **Q3** — Surfacing conflict-resolution decisions to the user (toast? log only?) — defer to RFC-006.
- [ ] **Q4** — Rate-limit handling: do we coalesce many small patches into one push burst, or fire them as they happen?
