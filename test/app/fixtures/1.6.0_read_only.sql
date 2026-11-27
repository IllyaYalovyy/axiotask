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
INSERT INTO "pending_moves" VALUES('a39e793d-d82f-4db9-90cd-5e1c7d9ef26f','38f1d6c9-8935-41bf-baa4-ad9151a20305',NULL,NULL);
CREATE TABLE sync_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ran_at      TEXT NOT NULL,
  duration_ms INTEGER,
  pulled      INTEGER NOT NULL DEFAULT 0,
  pushed      INTEGER NOT NULL DEFAULT 0,
  conflicts   INTEGER NOT NULL DEFAULT 0,
  error       TEXT
);
INSERT INTO "sync_log" VALUES(1,'2026-11-20T12:00:00.000000Z',118,6,0,0,NULL);
INSERT INTO "sync_log" VALUES(2,'2026-11-20T12:00:00.000000Z',35,1,0,0,NULL);
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
INSERT INTO "task_lists" VALUES('38f1d6c9-8935-41bf-baa4-ad9151a20305','inbox','My Tasks','etag-1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','clean',NULL,0);
INSERT INTO "task_lists" VALUES('a8890c76-33a6-447d-b59c-e7f37f4e7747','work','Office','etag-2','2026-11-20T12:00:00.000000Z','2026-11-20T12:00:00.000000Z','dirty','update',0);
INSERT INTO "task_lists" VALUES('da52b55b-fe05-4766-91a5-e8d141f70e57','old','Old projects','etag-3','2026-01-01T00:00:00Z','2026-11-20T12:00:00.000000Z','deleted','delete',0);
INSERT INTO "task_lists" VALUES('5fdc2a2f-8f91-4eee-9968-37c955c700b2',NULL,'Errands',NULL,'2026-11-20T12:00:00.000000Z','2026-11-20T12:00:00.000000Z','dirty','create',0);
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
INSERT INTO "tasks" VALUES('753a1834-a45c-4143-9ff4-c591443064d7','rename-me','38f1d6c9-8935-41bf-baa4-ad9151a20305',NULL,'00000000000002','Call the electrician','Ask about the fuse box','needsAction',NULL,NULL,'etag-4','2026-01-01T00:00:00Z','2026-11-20T12:00:00.000000Z','dirty','update','Call the plumber',NULL,NULL,'needsAction','https://tasks.google.com/task/rename-me');
INSERT INTO "tasks" VALUES('86c18f75-0c90-4dd7-85a8-3617eb80b409','finish-me','38f1d6c9-8935-41bf-baa4-ad9151a20305',NULL,'00000000000004','Pay rent',NULL,'completed',NULL,'2026-11-20T12:00:00.000000Z','etag-5','2026-01-01T00:00:00Z','2026-11-20T12:00:00.000000Z','dirty','update','Pay rent',NULL,NULL,'needsAction','https://tasks.google.com/task/finish-me');
INSERT INTO "tasks" VALUES('f4a92e7d-b35a-49b9-af84-388781d53df0','delete-me','38f1d6c9-8935-41bf-baa4-ad9151a20305',NULL,'00000000000003','Cancel gym',NULL,'needsAction',NULL,NULL,'etag-6','2026-01-01T00:00:00Z','2026-11-20T12:00:00.000000Z','deleted','delete',NULL,NULL,NULL,NULL,'https://tasks.google.com/task/delete-me');
INSERT INTO "tasks" VALUES('a39e793d-d82f-4db9-90cd-5e1c7d9ef26f','move-me','38f1d6c9-8935-41bf-baa4-ad9151a20305',NULL,'00000000000001','Book flights',NULL,'needsAction',NULL,NULL,'etag-7','2026-01-01T00:00:00Z','2026-11-20T12:00:00.000000Z','clean',NULL,NULL,NULL,NULL,NULL,'https://tasks.google.com/task/move-me');
INSERT INTO "tasks" VALUES('babff29c-dadc-428e-a5d8-ce26933ecadf','both-edit','38f1d6c9-8935-41bf-baa4-ad9151a20305',NULL,'00000000000005','Draft report (mine)',NULL,'needsAction',NULL,NULL,'etag-8','2026-01-01T00:00:00Z','2026-11-20T12:00:00.000000Z','dirty','update','Draft report',NULL,NULL,'needsAction','https://tasks.google.com/task/both-edit');
INSERT INTO "tasks" VALUES('4f25ec88-adf0-4e99-b674-d5fb0edd8f9d',NULL,'38f1d6c9-8935-41bf-baa4-ad9151a20305',NULL,'!16651568073709551615','Plan party',NULL,'needsAction','2026-12-01T00:00:00.000Z',NULL,NULL,'2026-11-20T12:00:00.000000Z','2026-11-20T12:00:00.000000Z','dirty','create',NULL,NULL,NULL,NULL,NULL);
INSERT INTO "tasks" VALUES('3099c5fc-b263-4dc5-ad83-350d737fff15',NULL,'38f1d6c9-8935-41bf-baa4-ad9151a20305','4f25ec88-adf0-4e99-b674-d5fb0edd8f9d','!16651568073709551614','Buy candles',NULL,'needsAction',NULL,NULL,NULL,'2026-11-20T12:00:00.000000Z','2026-11-20T12:00:00.000000Z','dirty','create',NULL,NULL,NULL,NULL,NULL);
INSERT INTO "tasks" VALUES('656d2acc-5e7e-4835-abb8-29530e119c15',NULL,'5fdc2a2f-8f91-4eee-9968-37c955c700b2',NULL,'!16651568073709551613','Post parcel',NULL,'needsAction',NULL,NULL,NULL,'2026-11-20T12:00:00.000000Z','2026-11-20T12:00:00.000000Z','dirty','create',NULL,NULL,NULL,NULL,NULL);
INSERT INTO "tasks" VALUES('f6be64ac-0f8d-484e-8125-3254d02814f5','old-task','da52b55b-fe05-4766-91a5-e8d141f70e57',NULL,'00000000000001','Archive photos',NULL,'needsAction',NULL,NULL,'etag-9','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','clean',NULL,NULL,NULL,NULL,NULL,'https://tasks.google.com/task/old-task');
CREATE INDEX idx_tasks_tree  ON tasks(list_id, parent_id, position);
CREATE INDEX idx_tasks_dirty ON tasks(sync_state) WHERE sync_state != 'clean';
CREATE INDEX idx_tasks_due   ON tasks(due) WHERE due IS NOT NULL;
DELETE FROM "sqlite_sequence";
INSERT INTO "sqlite_sequence" VALUES('sync_log',2);
COMMIT;
PRAGMA user_version = 1;
PRAGMA application_id = 2066706847;
