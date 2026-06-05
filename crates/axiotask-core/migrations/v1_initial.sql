-- Schema v1. Applied when PRAGMA user_version < 1.
-- See designs/RFC-003-local-sqlite-store.md and RFC-004-sync-engine.md.
--
-- Design notes:
--  * The local store is a CACHE of Google Tasks plus per-row sync metadata.
--  * Domain columns mirror the Google Tasks API; sync columns drive the
--    dirty-flag reconciliation engine (RFC-004).
--  * Pending mutations are tracked on two orthogonal axes:
--      - tasks.pending_op  : field-level create/update/delete (patch endpoint)
--      - pending_moves      : structural reorder/reparent (move endpoint)
--    A task may have both simultaneously (e.g. edited AND moved before sync).
--  * Timestamps are RFC-3339 TEXT (lexically sortable; SQLite has no native
--    datetime). Dates (due) are date-only RFC-3339.

CREATE TABLE task_lists (
  id              TEXT PRIMARY KEY,          -- Google id, or local UUID before first push
  title           TEXT NOT NULL,
  etag            TEXT,                       -- NULL for local-only rows
  updated         TEXT NOT NULL,              -- server 'updated' (RFC-3339)
  local_updated   TEXT NOT NULL,              -- local last-edit (RFC-3339)
  sync_state      TEXT NOT NULL CHECK (sync_state IN ('clean','dirty','deleted')),
  pending_op      TEXT CHECK (pending_op IN ('create','update','delete') OR pending_op IS NULL)
);

CREATE TABLE tasks (
  id              TEXT PRIMARY KEY,          -- Google id, or local UUID before first push
  list_id         TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  parent_id       TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  position        TEXT NOT NULL,             -- opaque Google lex-sortable position
  title           TEXT NOT NULL,
  notes           TEXT,
  status          TEXT NOT NULL CHECK (status IN ('needsAction','completed')),
  due             TEXT,                       -- date-only RFC-3339
  completed_at    TEXT,                       -- RFC-3339, set when status=completed
  etag            TEXT,                       -- NULL for local-only rows
  updated         TEXT NOT NULL,              -- server 'updated'
  local_updated   TEXT NOT NULL,              -- local last-edit
  sync_state      TEXT NOT NULL CHECK (sync_state IN ('clean','dirty','deleted')),
  pending_op      TEXT CHECK (pending_op IN ('create','update','delete') OR pending_op IS NULL)
);

CREATE INDEX idx_tasks_tree  ON tasks(list_id, parent_id, position);
CREATE INDEX idx_tasks_dirty ON tasks(sync_state) WHERE sync_state != 'clean';
CREATE INDEX idx_tasks_due   ON tasks(due) WHERE due IS NOT NULL;

-- Structural reorder/reparent intents, pushed via the Tasks move endpoint.
-- FK-cascaded so a deleted task can never leave an orphan move behind.
CREATE TABLE pending_moves (
  task_id     TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
  list_id     TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  parent_id   TEXT,                           -- target parent (NULL = top-level)
  previous_id TEXT                            -- task to follow (NULL = first)
);

-- Observability: one row per sync run.
CREATE TABLE sync_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ran_at      TEXT NOT NULL,
  duration_ms INTEGER,
  pulled      INTEGER NOT NULL DEFAULT 0,
  pushed      INTEGER NOT NULL DEFAULT 0,
  conflicts   INTEGER NOT NULL DEFAULT 0,
  error       TEXT
);

-- Crash-safety for non-idempotent creates. A row is written here BEFORE
-- calling Google's insert (which has no idempotency key) and cleared in the
-- same transaction that finalizes the create. If the app crashes between the
-- server ack and the local commit, recovery finds the in-flight marker and
-- adopts the orphaned remote task instead of re-inserting (no duplicate).
CREATE TABLE inflight_creates (
  local_id  TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
  list_id   TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE
);
