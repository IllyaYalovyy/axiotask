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
  /// Base-snapshot capture/clear (the `base_*` CASE columns, #124/#139) is added
  /// with its dedicated tests in the sync-write partition (T1.4a); this CRUD
  /// form manages only the domain and sync columns, so `base_*` stay at their
  /// insert default (NULL) until that path lands.
  Future<void> upsertTask(StoredTask t) async {
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
