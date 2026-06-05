-- Initial schema. See designs/RFC-003-local-sqlite-store.md.

CREATE TABLE IF NOT EXISTS task_lists (
  id              TEXT PRIMARY KEY,
  title           TEXT NOT NULL,
  etag            TEXT,
  updated         TEXT NOT NULL,
  local_updated   TEXT NOT NULL,
  sync_state      TEXT NOT NULL CHECK (sync_state IN ('clean','dirty','deleted')),
  deleted_at      TEXT
);

CREATE TABLE IF NOT EXISTS tasks (
  id              TEXT PRIMARY KEY,
  list_id         TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  parent_id       TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  position        TEXT NOT NULL,
  title           TEXT NOT NULL,
  notes           TEXT,
  status          TEXT NOT NULL CHECK (status IN ('needsAction','completed')),
  due             TEXT,
  completed_at    TEXT,
  etag            TEXT,
  updated         TEXT NOT NULL,
  local_updated   TEXT NOT NULL,
  sync_state      TEXT NOT NULL CHECK (sync_state IN ('clean','dirty','deleted')),
  pending_op      TEXT CHECK (pending_op IN ('create','update','delete') OR pending_op IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_tasks_tree  ON tasks(list_id, parent_id, position);
CREATE INDEX IF NOT EXISTS idx_tasks_dirty ON tasks(sync_state) WHERE sync_state != 'clean';

CREATE TABLE IF NOT EXISTS id_remap (
  local_id  TEXT PRIMARY KEY,
  remote_id TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS sync_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ran_at      TEXT NOT NULL,
  duration_ms INTEGER,
  pulled      INTEGER,
  pushed      INTEGER,
  conflicts   INTEGER,
  error       TEXT
);

-- Pending position/parent moves to push via the Tasks move API.
-- Separate from the dirty/pending_op flow because Google handles
-- reordering and reparenting through a distinct endpoint, not patch.
CREATE TABLE IF NOT EXISTS pending_moves (
  task_id     TEXT PRIMARY KEY,
  list_id     TEXT NOT NULL,
  parent_id   TEXT,
  previous_id TEXT
);
