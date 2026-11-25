BEGIN TRANSACTION;
CREATE TABLE inflight_creates (
  local_id  TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
  list_id   TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  base_local_updated TEXT
);
CREATE TABLE pending_moves (
  task_id     TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
  list_id     TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  parent_id   TEXT,
  previous_id TEXT
);
CREATE TABLE sync_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ran_at      TEXT NOT NULL,
  duration_ms INTEGER,
  pulled      INTEGER NOT NULL DEFAULT 0,
  pushed      INTEGER NOT NULL DEFAULT 0,
  conflicts   INTEGER NOT NULL DEFAULT 0,
  error       TEXT
);
CREATE TABLE task_lists (
  id              TEXT PRIMARY KEY,
  remote_id       TEXT UNIQUE,
  title           TEXT NOT NULL,
  etag            TEXT,
  updated         TEXT NOT NULL,
  local_updated   TEXT NOT NULL,
  sync_state      TEXT NOT NULL CHECK (sync_state IN ('clean','dirty','deleted')),
  pending_op      TEXT CHECK (pending_op IN ('create','update','delete') OR pending_op IS NULL),
  local_only      INTEGER NOT NULL DEFAULT 0
);
INSERT INTO "task_lists" VALUES('d5c03938-83ba-4b61-a7cb-38623aff4f2e',NULL,'My Tasks',NULL,'2026-11-25T07:33:21.693271Z','2026-11-25T07:33:21.693271Z','dirty','create',0);
INSERT INTO "task_lists" VALUES('fixture-list-local',NULL,'Fixture list never sent to Google',NULL,'2026-01-02T03:04:05Z','2026-01-02T03:04:05Z','dirty','create',0);
INSERT INTO "task_lists" VALUES('fixture-list-synced','remote-list-1','Fixture list from Google',NULL,'2026-01-02T03:04:05Z','2026-01-02T03:04:05Z','clean',NULL,0);
CREATE TABLE tasks (
  id              TEXT PRIMARY KEY,
  remote_id       TEXT UNIQUE,
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
  pending_op      TEXT CHECK (pending_op IN ('create','update','delete') OR pending_op IS NULL),
  base_title      TEXT,
  base_notes      TEXT,
  base_due        TEXT,
  base_status     TEXT CHECK (base_status IN ('needsAction','completed') OR base_status IS NULL),
  web_view_link   TEXT
);
INSERT INTO "tasks" VALUES('fixture-task-local',NULL,'fixture-list-local',NULL,'00000000000000000001','Fixture task never sent to Google','Only this device has it.','needsAction','2026-03-04T00:00:00.000Z',NULL,NULL,'2026-01-02T03:04:05Z','2026-01-02T03:04:05Z','dirty','create',NULL,NULL,NULL,NULL,NULL);
INSERT INTO "tasks" VALUES('fixture-subtask-local',NULL,'fixture-list-local','fixture-task-local','00000000000000000001','Fixture subtask never sent to Google',NULL,'needsAction',NULL,NULL,NULL,'2026-01-02T03:04:05Z','2026-01-02T03:04:05Z','dirty','create',NULL,NULL,NULL,NULL,NULL);
INSERT INTO "tasks" VALUES('fixture-task-edited','remote-task-1','fixture-list-synced',NULL,'00000000000000000001','Fixture task edited on this device',NULL,'needsAction',NULL,NULL,NULL,'2026-01-02T03:04:05Z','2026-01-02T03:04:05Z','dirty','update',NULL,NULL,NULL,NULL,NULL);
INSERT INTO "tasks" VALUES('fixture-task-done','remote-task-2','fixture-list-synced',NULL,'00000000000000000002','Fixture completed task',NULL,'completed',NULL,NULL,NULL,'2026-01-02T03:04:05Z','2026-01-02T03:04:05Z','clean',NULL,NULL,NULL,NULL,NULL,NULL);
CREATE INDEX idx_tasks_tree  ON tasks(list_id, parent_id, position);
CREATE INDEX idx_tasks_dirty ON tasks(sync_state) WHERE sync_state != 'clean';
CREATE INDEX idx_tasks_due   ON tasks(due) WHERE due IS NOT NULL;
DELETE FROM "sqlite_sequence";
COMMIT;
PRAGMA user_version = 1;
PRAGMA application_id = 2066706847;
