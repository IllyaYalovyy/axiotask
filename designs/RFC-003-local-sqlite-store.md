# RFC-003: Local SQLite Store

| Field         | Value         |
|---------------|---------------|
| Status        | Draft         |
| Author(s)     | Illya Yalovyy |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

Persist every task list, task, and bit of sync state in a single local SQLite
database. The store is the source of truth the UI reads from, and the queue
the sync engine drains. Local-first writes go here first; the network is
asynchronous.

---

## Goals

- **G1** — Tasks survive restarts, including changes made offline.
- **G2** — A list's full hierarchy loads in one query.
- **G3** — Sync engine can cheaply enumerate dirty rows.
- **G4** — Pre-1.0 there are **no migrations**. The store is a cache of
  Google's data (Google is the source of truth), so a schema change wipes and
  recreates the cache rather than evolving it in place. The schema lives in
  **one file** (`crates/axiotask-core/schema.sql`); `store::open` fingerprints
  it and, on a mismatch, exports the old database to JSON and recreates it from
  the current schema. (Post-1.0, when real user-owned local data exists, this
  becomes versioned forward-only migrations — a separate RFC.)
- **G5** — All queries are compile-time checked (`sqlx`).

## Non-Goals

- **NG1** — Cross-process access (single app instance is fine for MVP).
- **NG2** — Full-text search (later — out of MVP).
- **NG3** — Encryption at rest (Google's data is the source of truth; the local DB is a cache).

---

## Background & Motivation

VISION calls for offline-first behavior. That means the UI must read from a
local store, not the API. SQLite is the obvious fit: single file, embedded,
mature, well-supported by `sqlx`.

---

## Considered Options

### Option A — SQLite via `sqlx`

**Pros**: Compile-time-checked queries, async-native, ergonomic migrations.
**Cons**: Heavier than `rusqlite`; requires `DATABASE_URL` at compile time (mitigated by `sqlx prepare`).

### Option B — SQLite via `rusqlite`

**Pros**: Smaller dep tree, synchronous (simpler).
**Cons**: Queries unchecked at compile time; we'd hand-roll a migrator.

### Option C — `sled` (pure-Rust KV)

**Pros**: All-Rust, no FFI.
**Cons**: No SQL — we'd hand-build every index. Less mature.

---

## Decision

**Chosen option: Option A** (confirmed by user decision in initial plan).
`sqlx` with `offline` mode so CI doesn't need a live DB to compile.

---

## Design

### Schema (initial migration)

```sql
CREATE TABLE task_lists (
  id              TEXT PRIMARY KEY,
  title           TEXT NOT NULL,
  etag            TEXT,
  updated         TEXT NOT NULL,
  local_updated   TEXT NOT NULL,
  sync_state      TEXT NOT NULL CHECK (sync_state IN ('clean','dirty','deleted')),
  deleted_at      TEXT
);

CREATE TABLE tasks (
  id              TEXT PRIMARY KEY,        -- Google id or local UUID
  list_id         TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  parent_id       TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  position        TEXT NOT NULL,           -- Google's lex-sortable string
  title           TEXT NOT NULL,
  notes           TEXT,
  status          TEXT NOT NULL CHECK (status IN ('needsAction','completed')),
  due             TEXT,                    -- RFC3339
  completed_at    TEXT,
  etag            TEXT,
  updated         TEXT NOT NULL,
  local_updated   TEXT NOT NULL,
  sync_state      TEXT NOT NULL CHECK (sync_state IN ('clean','dirty','deleted')),
  pending_op      TEXT CHECK (pending_op IN ('create','update','delete') OR pending_op IS NULL)
);
CREATE INDEX idx_tasks_tree  ON tasks(list_id, parent_id, position);
CREATE INDEX idx_tasks_dirty ON tasks(sync_state) WHERE sync_state != 'clean';

CREATE TABLE id_remap (                    -- local UUID → remote id, after first push
  local_id  TEXT PRIMARY KEY,
  remote_id TEXT NOT NULL UNIQUE
);

CREATE TABLE sync_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ran_at      TEXT NOT NULL,
  duration_ms INTEGER,
  pulled      INTEGER, pushed INTEGER, conflicts INTEGER,
  error       TEXT
);
```

### Repositories

`TaskListRepo` and `TaskRepo` each expose only the operations the rest of the
app actually needs. No generic ORM.

- `TaskRepo::load_tree(list_id) -> Vec<Task>` — single recursive CTE; caller folds into a tree if needed.
- `TaskRepo::upsert_from_remote(task)` — used by sync pull; preserves `sync_state='dirty'` if local has unflushed edits.
- `TaskRepo::mark_dirty(id, op)` — used by command handlers after a local write.
- `TaskRepo::drain_dirty()` — used by sync push.

Database file lives at `dirs::data_dir()/axiotask/axiotask.sqlite`.

---

## Testing Strategy

- **Schema fingerprint (pre-1.0 wipe-and-recreate)**: opening a fresh DB stamps
  the schema fingerprint and creates no backup; reopening a current DB preserves
  its data (no wipe); opening a DB stamped with an incompatible fingerprint
  exports every table to a timestamped JSON file beside the DB, then wipes and
  recreates it from `schema.sql`. Old-schema fixtures (including a parent with a
  subtask) prove the export captures the full subtree before the wipe. The
  export is written with `sync_all` (file + parent directory) so it is durably
  on disk before the wipe runs (#129).
- **Durable-backup gate on wipe (#129)**: the destructive wipe must not run
  unless the pre-wipe backup is durably on disk. If the backup write fails and
  the store holds data Google does not have — a local-only list, or an unpushed
  dirty/deleted row, or a queued move / in-flight create — `open` **fails open**:
  it returns a `WipeAborted` error with a clear message and leaves the data
  intact rather than destroying it. A fully-synced ("clean") cache holds nothing
  Google lacks, so it may still be wiped best-effort even when the backup fails.
  Both paths are covered red-first. The at-risk probe is schema-agnostic and
  conservative: a probe that cannot inspect an old table is treated as at-risk.
- **Repository tests**: in-memory DB per test (`SqlitePool::connect(":memory:")`); coverage target = every public method.
- **Tree query**: property test — generate arbitrary tree shapes, round-trip insert → `load_tree` → assert structure.
- **Dirty queue**: assert ordering invariants (creates before updates before deletes for the same row).

---

## Development Plan

- [ ] **Step 1** — Wire `sqlx` and define migrator *(prerequisite: RFC-001 Step 1)*
- [ ] **Step 2** — Initial migration + connection setup at app data dir *(prerequisite: Step 1)*
- [ ] **Step 3** — `TaskListRepo` + tests *(prerequisite: Step 2)*
- [ ] **Step 4** — `TaskRepo` (single-row CRUD) + tests *(prerequisite: Step 2)*
- [ ] **Step 5** — `TaskRepo::load_tree` + tests *(prerequisite: Step 4)*
- [ ] **Step 6** — Dirty-queue methods + tests *(prerequisite: Step 4)*
- [ ] **Step 7** — `id_remap` + helper to rewrite local→remote after push *(prerequisite: Step 4)*

---

## Open Questions

- [ ] **Q1** — Soft-delete vs hard-delete after server confirms? Soft is safer; cleans up via a sweeper.
- [ ] **Q2** — Should `position` be stored as TEXT (Google's format) or recomputed locally as a `f64`? Google's format wins for round-trip fidelity.
- [ ] **Q3** — Do we need WAL mode? Probably yes — single writer, occasional readers.
