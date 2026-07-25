-- Schema v1. Applied when PRAGMA user_version < 1.
-- See designs/RFC-003-local-sqlite-store.md and RFC-004-sync-engine.md.
--
-- v1 is the clean pre-1.0 baseline. It first drops any tables left by the
-- earlier unversioned `CREATE TABLE IF NOT EXISTS` schema so a dev database
-- created before migration versioning is reset to this schema. There is no
-- pre-1.0 data to preserve. user_version gates this to run exactly once;
-- it is a no-op on a fresh database. Future migrations (v2+) MUST NOT drop —
-- they evolve the schema in place.
DROP TABLE IF EXISTS inflight_creates;
DROP TABLE IF EXISTS pending_moves;
DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS task_lists;
DROP TABLE IF EXISTS id_remap;
DROP TABLE IF EXISTS sync_log;
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
  pending_op      TEXT CHECK (pending_op IN ('create','update','delete') OR pending_op IS NULL),
  -- Base snapshot: the content fields as of this row's last agreement with the
  -- server (RFC-009 §B/§G, #124). Captured when a clean row is first edited
  -- (base = last-synced content) and when an insert payload goes out (base =
  -- payload as sent). NULL while the row is clean. On a 412 the refetched
  -- remote equal to the base means only WE diverged — a remote reorder bumped
  -- the etag without touching content — so our edit wins with no conflicted
  -- copy (#118). Orphan adoption after a crashed create matches on the base,
  -- immune to an edit made during the in-flight window (#122).
  base_title      TEXT,
  base_notes      TEXT,
  base_due        TEXT,
  base_status     TEXT CHECK (base_status IN ('needsAction','completed') OR base_status IS NULL)
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
  list_id   TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  -- The row's local_updated at the moment the insert payload was drained and
  -- sent (#124/#122). Crash recovery passes it to finish_create as the
  -- drain snapshot, so an edit made during the in-flight window keeps its
  -- dirty flag (rewritten create->update) instead of being wiped clean.
  base_local_updated TEXT
);
