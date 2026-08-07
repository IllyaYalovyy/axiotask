// High-level operations on the local SQLite cache — the CRUD, read-query and
// watch-stream surface of the Dart port of `store/repo.rs` (the T1.3 partition).
//
// The store mirrors what's on Google plus per-row sync metadata. The UI reads
// `clean` + `dirty` rows together and skips `deleted` ones; the sync engine
// (ported in T1.4a/T1.4b: drains, mark-clean, apply-pushed, finish-create,
// tombstone, rehome, counts, clears) drains `dirty` rows. This file owns the
// non-sync surface: upserts, hard deletes, ghost removal, the list/task reads,
// and the drift `watch*` streams the UI subscribes to.
//
// Writes go through drift's `customInsert`/`customUpdate` with an explicit
// `updates:` table set so drift's stream-query engine re-runs the matching
// `watch*` queries (a raw `customStatement` would not notify them). Reads use
// `customSelect(...).get()`; the streaming variants use `.watch()` with the same
// SQL and a `readsFrom:` table set.

import 'package:drift/drift.dart';

import '../model/base_snapshot.dart';
import '../model/task.dart';
import '../model/task_list.dart';
import 'database.dart' show AppDatabase;
import 'store_error.dart';
import 'stored.dart';

// Column lists kept as constants so the one-shot read and its `watch*` twin run
// byte-identical SQL (drift dedupes identical streamed queries).
const String _listCols =
    'id, title, etag, updated, local_updated, sync_state, pending_op, local_only';
const String _taskCols =
    'id, list_id, parent_id, position, title, notes, status, due, '
    'completed_at, etag, updated, local_updated, sync_state, pending_op, '
    'web_view_link';

const String _selectListsSql =
    'SELECT $_listCols FROM task_lists WHERE sync_state != \'deleted\'';
// Top-level rows first (parent IS NULL sorts ahead of a set parent), then by
// position — the caller folds the flat rows into the two-level tree.
const String _selectTasksSql =
    'SELECT $_taskCols FROM tasks WHERE list_id = ? AND sync_state != \'deleted\' '
    'ORDER BY (parent_id IS NOT NULL), parent_id, position';
// find_task_any: any row, tombstones included.
const String _selectTaskAnySql = 'SELECT $_taskCols FROM tasks WHERE id = ?';
// watchTask: the VISIBLE task by id (a tombstone reads as absent, so a delete
// pushes null onto the detail stream).
const String _selectVisibleTaskSql =
    'SELECT $_taskCols FROM tasks WHERE id = ? AND sync_state != \'deleted\'';
// drain_dirty: all locally-dirty/deleted tasks awaiting push, joined to their
// list so local-only lists' tasks are excluded (never pushed). Ordered by
// pending_op priority (create→update→delete), then top-level-before-subtask,
// then oldest edit first. The `t.` alias prefixes _taskCols since the join
// brings a second `id`/`list_id` into scope.
const String _drainTasksSql =
    'SELECT t.id, t.list_id, t.parent_id, t.position, t.title, t.notes, '
    't.status, t.due, t.completed_at, t.etag, t.updated, t.local_updated, '
    't.sync_state, t.pending_op, t.web_view_link '
    'FROM tasks t JOIN task_lists l ON l.id = t.list_id '
    "WHERE (t.sync_state = 'dirty' OR t.sync_state = 'deleted') AND l.local_only = 0 "
    'ORDER BY CASE t.pending_op '
    "WHEN 'create' THEN 0 WHEN 'update' THEN 1 WHEN 'delete' THEN 2 ELSE 3 END, "
    '(t.parent_id IS NOT NULL), t.local_updated ASC';
// drain_dirty_lists: dirty/deleted lists awaiting push, local-only excluded,
// creates before updates before deletes, oldest edit first.
const String _drainListsSql =
    'SELECT $_listCols FROM task_lists '
    "WHERE (sync_state = 'dirty' OR sync_state = 'deleted') AND local_only = 0 "
    'ORDER BY CASE pending_op '
    "WHEN 'create' THEN 0 WHEN 'update' THEN 1 WHEN 'delete' THEN 2 ELSE 3 END, "
    'local_updated ASC';

/// Repository handle over the local cache. Cheap to hold; wraps the database.
class Store {
  /// Wrap an already-open database.
  Store(this._db);

  final AppDatabase _db;

  /// Underlying database, exposed for advanced callers (mirrors `pool()`).
  AppDatabase get db => _db;

  // ── list CRUD ─────────────────────────────────────────────────────────────

  /// Replace (or insert) a task-list row.
  Future<void> upsertList(StoredTaskList list) async {
    await _db.customInsert(
      'INSERT INTO task_lists ($_listCols) VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'title = excluded.title, etag = excluded.etag, updated = excluded.updated, '
      'local_updated = excluded.local_updated, sync_state = excluded.sync_state, '
      'pending_op = excluded.pending_op, local_only = excluded.local_only',
      variables: _listVars(list),
      updates: {_db.taskLists},
    );
  }

  /// Upsert a list pulled from the server WITHOUT clobbering a locally
  /// dirty/deleted one — the `WHERE sync_state = 'clean'` makes skip-if-dirty
  /// atomic with the update, so a concurrent local rename (and its dirty flag)
  /// survives (mirrors [upsertRemoteTask]).
  Future<void> upsertRemoteList(StoredTaskList list) async {
    await _db.customInsert(
      'INSERT INTO task_lists ($_listCols) VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'title = excluded.title, etag = excluded.etag, updated = excluded.updated, '
      'local_updated = excluded.local_updated, sync_state = excluded.sync_state, '
      'pending_op = excluded.pending_op '
      'WHERE task_lists.sync_state = \'clean\'',
      variables: _listVars(list),
      updates: {_db.taskLists},
    );
  }

  /// Hard-delete a list only if still clean — ghost detection must not remove a
  /// list a live rename/delete just dirtied.
  Future<void> deleteListHardIfClean(String id) async {
    await _db.customUpdate(
      'DELETE FROM task_lists WHERE id = ? AND sync_state = \'clean\'',
      variables: [Variable<String>(id)],
      updates: {_db.taskLists},
      updateKind: UpdateKind.delete,
    );
  }

  /// Hard-delete a list unconditionally. `ON DELETE CASCADE` takes its tasks.
  Future<void> deleteListHard(String id) async {
    await _db.customUpdate(
      'DELETE FROM task_lists WHERE id = ?',
      variables: [Variable<String>(id)],
      updates: {_db.taskLists},
      updateKind: UpdateKind.delete,
    );
  }

  /// All known lists (excluding tombstones), in arbitrary order.
  Future<List<StoredTaskList>> allLists() async {
    final rows = await _db.customSelect(_selectListsSql).get();
    return rows.map(_listFromRow).toList();
  }

  /// Ids of clean, server-backed lists — the ghost-detection set. Local-only
  /// lists are excluded: they never exist on the server, so they must never be
  /// treated as a ghost the moment they are absent from a pull (which is
  /// always).
  Future<Set<String>> cleanListIds() async {
    final rows = await _db
        .customSelect(
          'SELECT id FROM task_lists WHERE sync_state = \'clean\' AND local_only = 0',
        )
        .get();
    return {for (final r in rows) r.read<String>('id')};
  }

  /// Live stream of [allLists], re-emitting on every task-list write.
  Stream<List<StoredTaskList>> watchLists() => _db
      .customSelect(_selectListsSql, readsFrom: {_db.taskLists})
      .watch()
      .map((rows) => rows.map(_listFromRow).toList());

  // ── task CRUD ─────────────────────────────────────────────────────────────

  /// Insert or replace a task row.
  ///
  /// Captures the base snapshot (#124) as a side effect: the first edit that
  /// turns a `clean` row `dirty` records the pre-edit content as its base
  /// (`tasks.*` on the RHS is the OLD row in an `ON CONFLICT DO UPDATE`), and
  /// every later edit preserves it — so the base always holds the content as of
  /// the last server agreement until the row goes clean again. Any write that
  /// lands the row `clean` clears the base (#139): a clean row carries no base
  /// (schema invariant §B), so the 412 `ConflictedCopy` resolver overwriting a
  /// dirty id with the canonical remote row must not leave a stale base behind.
  ///
  /// `base_*` are absent from the INSERT column list, so a first insert leaves
  /// them at their NULL default — a freshly inserted row has no base.
  Future<void> upsertTask(StoredTask t) async {
    await _db.customInsert(
      'INSERT INTO tasks ($_taskCols) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'list_id = excluded.list_id, parent_id = excluded.parent_id, '
      'position = excluded.position, '
      "base_title  = CASE WHEN excluded.sync_state = 'clean' THEN NULL "
      "                   WHEN tasks.sync_state = 'clean' AND excluded.sync_state = 'dirty' "
      '                   THEN tasks.title  ELSE tasks.base_title  END, '
      "base_notes  = CASE WHEN excluded.sync_state = 'clean' THEN NULL "
      "                   WHEN tasks.sync_state = 'clean' AND excluded.sync_state = 'dirty' "
      '                   THEN tasks.notes  ELSE tasks.base_notes  END, '
      "base_due    = CASE WHEN excluded.sync_state = 'clean' THEN NULL "
      "                   WHEN tasks.sync_state = 'clean' AND excluded.sync_state = 'dirty' "
      '                   THEN tasks.due    ELSE tasks.base_due    END, '
      "base_status = CASE WHEN excluded.sync_state = 'clean' THEN NULL "
      "                   WHEN tasks.sync_state = 'clean' AND excluded.sync_state = 'dirty' "
      '                   THEN tasks.status ELSE tasks.base_status END, '
      'title = excluded.title, notes = excluded.notes, '
      'status = excluded.status, due = excluded.due, '
      'completed_at = excluded.completed_at, etag = excluded.etag, '
      'updated = excluded.updated, local_updated = excluded.local_updated, '
      'sync_state = excluded.sync_state, pending_op = excluded.pending_op, '
      'web_view_link = excluded.web_view_link',
      variables: _taskVars(t),
      updates: {_db.tasks},
    );
  }

  /// Upsert a row pulled from the server, but NEVER clobber a locally
  /// dirty/deleted row. The `WHERE sync_state = 'clean'` closes the pull-vs-edit
  /// race: a live edit that dirties the row after pull's skip-set snapshot but
  /// before this write survives, dirty flag and all.
  Future<void> upsertRemoteTask(StoredTask t) async {
    await _db.customInsert(
      'INSERT INTO tasks ($_taskCols) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'list_id = excluded.list_id, parent_id = excluded.parent_id, '
      'position = excluded.position, title = excluded.title, notes = excluded.notes, '
      'status = excluded.status, due = excluded.due, '
      'completed_at = excluded.completed_at, etag = excluded.etag, '
      'updated = excluded.updated, local_updated = excluded.local_updated, '
      'sync_state = excluded.sync_state, pending_op = excluded.pending_op, '
      'web_view_link = excluded.web_view_link '
      'WHERE tasks.sync_state = \'clean\'',
      variables: _taskVars(t),
      updates: {_db.tasks},
    );
  }

  /// Remove a row the server no longer has (ghost detection), only if it is
  /// still clean — a live edit that re-dirtied it cancels the removal. Returns
  /// whether the row was removed.
  ///
  /// `ON DELETE CASCADE` takes the whole subtree with it, including the unpushed
  /// subtasks the server never saw: a subtask shares its parent's fate (RFC-009
  /// D3 REJECTED — no auto-promotion; invariant #3).
  Future<bool> removeGhostTask(String id) async {
    final affected = await _db.customUpdate(
      'DELETE FROM tasks WHERE id = ? AND sync_state = \'clean\'',
      variables: [Variable<String>(id)],
      updates: {_db.tasks},
      updateKind: UpdateKind.delete,
    );
    return affected > 0;
  }

  /// Hard-delete a task row (and, via cascade, its subtree).
  Future<void> deleteTaskHard(String id) async {
    await _db.customUpdate(
      'DELETE FROM tasks WHERE id = ?',
      variables: [Variable<String>(id)],
      updates: {_db.tasks},
      updateKind: UpdateKind.delete,
    );
  }

  /// All visible tasks in [listId] (tombstones excluded), ordered
  /// top-level-first then by position. The caller folds them into a tree.
  Future<List<StoredTask>> listTasks(String listId) async {
    final rows = await _db
        .customSelect(_selectTasksSql, variables: [Variable<String>(listId)])
        .get();
    return rows.map(_taskFromRow).toList();
  }

  /// Fetch a single task by id regardless of sync_state (tombstones included);
  /// `null` when absent.
  Future<StoredTask?> findTaskAny(String id) async {
    final rows = await _db
        .customSelect(_selectTaskAnySql, variables: [Variable<String>(id)])
        .get();
    return rows.isEmpty ? null : _taskFromRow(rows.first);
  }

  /// Live stream of [listTasks] for [listId], re-emitting on every task write.
  Stream<List<StoredTask>> watchTasks(String listId) => _db
      .customSelect(
        _selectTasksSql,
        variables: [Variable<String>(listId)],
        readsFrom: {_db.tasks},
      )
      .watch()
      .map((rows) => rows.map(_taskFromRow).toList());

  /// Live stream of the VISIBLE task with [id], emitting `null` once the row is
  /// deleted/tombstoned (the detail panel reacts instead of stranding a stale
  /// row).
  Stream<StoredTask?> watchTask(String id) => _db
      .customSelect(
        _selectVisibleTaskSql,
        variables: [Variable<String>(id)],
        readsFrom: {_db.tasks},
      )
      .watch()
      .map((rows) => rows.isEmpty ? null : _taskFromRow(rows.first));

  // ── push-side write paths (drains + mark-clean + apply-pushed) ────────────

  /// All locally-dirty/deleted tasks awaiting push, ordered by pending_op
  /// priority (creates → updates → deletes). Tasks in local-only lists are
  /// excluded: their list does not exist on the server, so they are never
  /// pushed.
  Future<List<StoredTask>> drainDirty() async {
    final rows = await _db.customSelect(_drainTasksSql).get();
    return rows.map(_taskFromRow).toList();
  }

  /// All locally-dirty/deleted lists awaiting push, creates before updates
  /// before deletes. Local-only lists are excluded — they are never pushed.
  Future<List<StoredTaskList>> drainDirtyLists() async {
    final rows = await _db.customSelect(_drainListsSql).get();
    return rows.map(_listFromRow).toList();
  }

  /// Mark a task as in-sync after a successful push — but only if the row's
  /// `local_updated` still equals the snapshot taken when the push drained it.
  ///
  /// Without the guard, an edit made while the push's HTTP request is in flight
  /// would have its dirty flag wiped by the push completing, and that newer
  /// edit would silently never sync (a lost update). When the guard misses, the
  /// row stays dirty — but the fresh etag is adopted either way, so the re-push
  /// of the newer content succeeds instead of 412ing.
  Future<void> markTaskClean(
    String id,
    String? newEtag,
    String serverUpdated,
    String expectedLocalUpdated,
  ) async {
    await _db.customUpdate(
      'UPDATE tasks SET etag = COALESCE(?1, etag), updated = ?2, '
      "sync_state = CASE WHEN local_updated = ?3 THEN 'clean' ELSE sync_state END, "
      'pending_op = CASE WHEN local_updated = ?3 THEN NULL ELSE pending_op END '
      'WHERE id = ?4',
      variables: [
        Variable<String>(newEtag),
        Variable<String>(serverUpdated),
        Variable<String>(expectedLocalUpdated),
        Variable<String>(id),
      ],
      updates: {_db.tasks},
    );
  }

  /// Adopt the full task the server returned from a successful push.
  ///
  /// The response is what the server ACTUALLY stored, and it can differ from
  /// what we sent: it assigns `position` on insert, sets the `completed`
  /// timestamp, normalizes `due`, and can silently coerce fields. Discarding
  /// the body creates permanent drift no later pull corrects.
  ///
  /// Three race guards, all arbitrated by [expectedLocalUpdated] (the drained
  /// snapshot):
  ///  * A mid-flight re-edit (`local_updated` moved) keeps its own content and
  ///    dirty flag, adopting just the fresh etag, and re-bases `base_*` to the
  ///    body the server now holds (#124) so a later 412 diffs against reality.
  ///  * A pending move (a `pending_moves` row) freezes `parent_id`/`position`
  ///    so the queued structural move is not clobbered by the content response.
  ///  * A response naming a `parent` this device no longer holds detaches the
  ///    row and drops its etag (RFC-009 §A) rather than violating the FK, so a
  ///    later pull re-links it (P6).
  Future<void> applyPushedTask(Task remote, String expectedLocalUpdated) async {
    await _db.customUpdate(
      'UPDATE tasks SET '
      'etag = CASE WHEN ?4 IS NOT NULL AND local_updated = ?3 AND NOT EXISTS '
      '              (SELECT 1 FROM pending_moves pm WHERE pm.task_id = tasks.id) '
      '              AND NOT EXISTS (SELECT 1 FROM tasks p WHERE p.id = ?4) '
      '            THEN NULL ELSE COALESCE(?1, etag) END, '
      'updated = ?2, '
      'parent_id = CASE WHEN local_updated = ?3 AND NOT EXISTS '
      '              (SELECT 1 FROM pending_moves pm WHERE pm.task_id = tasks.id) '
      '            THEN CASE WHEN ?4 IS NULL OR EXISTS '
      '                   (SELECT 1 FROM tasks p WHERE p.id = ?4) '
      '                 THEN ?4 ELSE NULL END '
      '            ELSE parent_id END, '
      'position = CASE WHEN local_updated = ?3 AND NOT EXISTS '
      '              (SELECT 1 FROM pending_moves pm WHERE pm.task_id = tasks.id) '
      '            THEN ?5 ELSE position END, '
      'title        = CASE WHEN local_updated = ?3 THEN ?6  ELSE title        END, '
      'notes        = CASE WHEN local_updated = ?3 THEN ?7  ELSE notes        END, '
      'status       = CASE WHEN local_updated = ?3 THEN ?8  ELSE status       END, '
      'due          = CASE WHEN local_updated = ?3 THEN ?9  ELSE due          END, '
      'completed_at = CASE WHEN local_updated = ?3 THEN ?10 ELSE completed_at END, '
      'web_view_link = COALESCE(?11, web_view_link), '
      // A clean landing clears the base; a mid-flight re-edit that keeps the row
      // dirty re-bases to the pushed body so a later 412 compares right (#124).
      'base_title  = CASE WHEN local_updated = ?3 THEN NULL ELSE ?6 END, '
      'base_notes  = CASE WHEN local_updated = ?3 THEN NULL ELSE ?7 END, '
      'base_due    = CASE WHEN local_updated = ?3 THEN NULL ELSE ?9 END, '
      'base_status = CASE WHEN local_updated = ?3 THEN NULL ELSE ?8 END, '
      "sync_state = CASE WHEN local_updated = ?3 THEN 'clean' ELSE sync_state END, "
      'pending_op = CASE WHEN local_updated = ?3 THEN NULL ELSE pending_op END '
      'WHERE id = ?12',
      variables: [
        Variable<String>(remote.etag), // ?1
        Variable<String>(remote.updated), // ?2
        Variable<String>(expectedLocalUpdated), // ?3
        Variable<String>(remote.parent), // ?4
        Variable<String>(remote.position), // ?5
        Variable<String>(remote.title), // ?6
        Variable<String>(remote.notes), // ?7
        Variable<String>(remote.status.apiStr), // ?8
        Variable<String>(remote.due), // ?9
        Variable<String>(remote.completed), // ?10
        Variable<String>(remote.webViewLink), // ?11
        Variable<String>(remote.id), // ?12
      ],
      updates: {_db.tasks},
    );
  }

  /// The base snapshot for a row (#124), or `null` when the row is clean / has
  /// no base recorded. `base_title` is the presence sentinel: a `NOT NULL`
  /// title column can only be absent when no base was captured.
  Future<BaseSnapshot?> baseSnapshot(String id) async {
    final rows = await _db
        .customSelect(
          'SELECT base_title, base_notes, base_due, base_status '
          'FROM tasks WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    final row = rows.first;
    final title = row.readNullable<String>('base_title');
    if (title == null) return null; // no base captured
    final statusStr = row.readNullable<String>('base_status');
    return BaseSnapshot(
      title: title,
      notes: row.readNullable<String>('base_notes'),
      due: row.readNullable<String>('base_due'),
      // A NULL/unparseable base_status falls back to needsAction (mirrors ref).
      status:
          (statusStr == null ? null : TaskStatus.parseApi(statusStr)) ??
          TaskStatus.needsAction,
    );
  }

  // ── binding + decoding ──────────────────────────────────────────────────

  static List<Variable> _listVars(StoredTaskList l) => [
    Variable<String>(l.list.id),
    Variable<String>(l.list.title),
    Variable<String>(l.list.etag),
    Variable<String>(l.list.updated),
    Variable<String>(l.localUpdated),
    Variable<String>(l.syncState.asStr),
    Variable<String>(l.pendingOp),
    Variable<bool>(l.localOnly),
  ];

  static List<Variable> _taskVars(StoredTask t) => [
    Variable<String>(t.task.id),
    Variable<String>(t.listId),
    Variable<String>(t.task.parent),
    Variable<String>(t.task.position),
    Variable<String>(t.task.title),
    Variable<String>(t.task.notes),
    Variable<String>(t.task.status.apiStr),
    Variable<String>(t.task.due),
    Variable<String>(t.task.completed),
    Variable<String>(t.task.etag),
    Variable<String>(t.task.updated),
    Variable<String>(t.localUpdated),
    Variable<String>(t.syncState.asStr),
    Variable<String>(t.pendingOp),
    Variable<String>(t.task.webViewLink),
  ];

  static StoredTaskList _listFromRow(QueryRow row) {
    final syncStr = row.read<String>('sync_state');
    final sync = SyncState.parse(syncStr);
    if (sync == null) throw StoreSqlError('bad sync_state $syncStr');
    return StoredTaskList(
      list: TaskList(
        id: row.read<String>('id'),
        title: row.read<String>('title'),
        etag: row.readNullable<String>('etag'),
        updated: row.read<String>('updated'),
      ),
      syncState: sync,
      localUpdated: row.read<String>('local_updated'),
      pendingOp: row.readNullable<String>('pending_op'),
      localOnly: row.read<bool>('local_only'),
    );
  }

  static StoredTask _taskFromRow(QueryRow row) {
    final statusStr = row.read<String>('status');
    final status = TaskStatus.parseApi(statusStr);
    if (status == null) throw StoreSqlError('bad status $statusStr');
    final syncStr = row.read<String>('sync_state');
    final sync = SyncState.parse(syncStr);
    if (sync == null) throw StoreSqlError('bad sync_state $syncStr');
    return StoredTask(
      task: Task(
        id: row.read<String>('id'),
        parent: row.readNullable<String>('parent_id'),
        position: row.read<String>('position'),
        title: row.read<String>('title'),
        notes: row.readNullable<String>('notes'),
        status: status,
        due: row.readNullable<String>('due'),
        completed: row.readNullable<String>('completed_at'),
        etag: row.readNullable<String>('etag'),
        updated: row.read<String>('updated'),
        webViewLink: row.readNullable<String>('web_view_link'),
        // A stored row is never a tombstone flag — a deleted row is hard-removed.
      ),
      listId: row.read<String>('list_id'),
      syncState: sync,
      localUpdated: row.read<String>('local_updated'),
      pendingOp: row.readNullable<String>('pending_op'),
    );
  }
}
