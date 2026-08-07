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
import '../model/dates.dart' show nowUtcString;
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

  // ── skip-set + ghost-detection reads ──────────────────────────────────────

  /// Ids of every locally dirty or deleted task — the pull skip-set (a pull
  /// must never clobber a row with unpushed local changes).
  Future<Set<String>> dirtyIds() async {
    final rows = await _db
        .customSelect(
          "SELECT id FROM tasks WHERE sync_state = 'dirty' OR sync_state = 'deleted'",
        )
        .get();
    return {for (final r in rows) r.read<String>('id')};
  }

  /// Ids of all clean tasks in [listId] — the per-list ghost-detection set
  /// (a clean row absent from the server's pull is a ghost to remove).
  Future<Set<String>> cleanTaskIdsForList(String listId) async {
    final rows = await _db
        .customSelect(
          "SELECT id FROM tasks WHERE list_id = ? AND sync_state = 'clean'",
          variables: [Variable<String>(listId)],
        )
        .get();
    return {for (final r in rows) r.read<String>('id')};
  }

  // ── move drain (list deletion / cross-list) ───────────────────────────────

  /// Move every row the server has NEVER seen out of [fromList] into [toList],
  /// returning how many rows moved. D2: a list holding unpushed rows may not be
  /// dropped until they have somewhere to go.
  ///
  /// A row moves only when it is top-level OR its parent is itself an unpushed
  /// row in the same dying list — so an unpushed subtree travels together. The
  /// `id IN (SELECT ...)` materializes the set against the pre-update state, so
  /// "my parent is re-homing too" is judged while every row is still in
  /// [fromList]. A subtask of a row that STAYS behind (e.g. a synced parent) is
  /// NOT promoted or re-homed — it stays put to die in the list cascade (D3
  /// REJECTED; invariant #3). Synced rows and tombstones never move.
  ///
  /// An in-flight-create marker is list-scoped, so it follows its row: without
  /// this the list's FK cascade would drop the marker and a committed-but-
  /// unacked insert could be re-inserted as a duplicate (P8).
  Future<int> rehomeUnpushedTasks(String fromList, String toList) async {
    var moved = 0;
    await _db.transaction(() async {
      moved = await _db.customUpdate(
        'UPDATE tasks SET list_id = ?2 '
        'WHERE id IN ('
        '  SELECT id FROM tasks '
        "  WHERE list_id = ?1 AND etag IS NULL AND sync_state != 'deleted' "
        '    AND (parent_id IS NULL OR parent_id IN ('
        '        SELECT id FROM tasks '
        "        WHERE list_id = ?1 AND etag IS NULL AND sync_state != 'deleted')))",
        variables: [Variable<String>(fromList), Variable<String>(toList)],
        updates: {_db.tasks},
      );
      await _db.customUpdate(
        'UPDATE inflight_creates SET list_id = ?2 '
        'WHERE list_id = ?1 AND local_id IN '
        '(SELECT id FROM tasks WHERE list_id = ?2)',
        variables: [Variable<String>(fromList), Variable<String>(toList)],
        updates: {_db.inflightCreates},
      );
    });
    return moved;
  }

  /// Whether [listId] still holds any row the server has never seen (D2: such a
  /// list may not be dropped until those rows have somewhere to go).
  Future<bool> hasUnpushedTasks(String listId) async {
    final rows = await _db
        .customSelect(
          'SELECT 1 FROM tasks WHERE list_id = ? AND etag IS NULL '
          "AND sync_state != 'deleted' LIMIT 1",
          variables: [Variable<String>(listId)],
        )
        .get();
    return rows.isNotEmpty;
  }

  // ── confirm / tombstone task paths ────────────────────────────────────────

  /// Adopt a fresh etag/updated from the server WITHOUT touching sync_state or
  /// pending_op. Used after a move push: the move endpoint returns a new etag,
  /// but the row may carry an unrelated pending content edit whose dirty flag
  /// must survive.
  Future<void> refreshTaskMeta(
    String id,
    String? newEtag,
    String serverUpdated,
  ) async {
    await _db.customUpdate(
      'UPDATE tasks SET etag = COALESCE(?, etag), updated = ? WHERE id = ?',
      variables: [
        Variable<String>(newEtag),
        Variable<String>(serverUpdated),
        Variable<String>(id),
      ],
      updates: {_db.tasks},
    );
  }

  /// Tombstone [rootId] and its whole subtree in ONE transaction (RFC-009 §D:
  /// "deleting a parent tombstones the whole subtree"; D3 REJECTED — children
  /// die with the parent, never promoted; invariant #3).
  ///
  /// The root keeps `pending_op = 'delete'` so its delete pushes; Google's own
  /// DELETE cascade takes the children remotely (verified live, #106), so each
  /// descendant becomes a LOCAL-ONLY tombstone with `pending_op = NULL` — never
  /// pushed, kept out of every view and out of the pull (a `deleted` row is in
  /// the skip-set, so it cannot be resurrected as an orphan). The FK `ON DELETE
  /// CASCADE` clears the child tombstones when the confirmed root delete hard-
  /// deletes the root row.
  ///
  /// [descendantIds] are the subtree the caller already walked (top-level + its
  /// one legal level of subtasks, invariant #1); the caller owns the walk so
  /// the same snapshot backs the undo token.
  Future<void> tombstoneSubtree(
    String rootId,
    List<String> descendantIds,
    String now,
  ) async {
    await _db.transaction(() async {
      await _db.customUpdate(
        "UPDATE tasks SET sync_state = 'deleted', pending_op = 'delete', "
        'local_updated = ?2 WHERE id = ?1',
        variables: [Variable<String>(rootId), Variable<String>(now)],
        updates: {_db.tasks},
      );
      for (final id in descendantIds) {
        await _db.customUpdate(
          "UPDATE tasks SET sync_state = 'deleted', pending_op = NULL, "
          'local_updated = ?2 WHERE id = ?1',
          variables: [Variable<String>(id), Variable<String>(now)],
          updates: {_db.tasks},
        );
      }
    });
  }

  // ── list confirm / remap ──────────────────────────────────────────────────

  /// Mark a list in-sync after a successful push.
  Future<void> markListClean(
    String id,
    String? newEtag,
    String serverUpdated,
  ) async {
    await _db.customUpdate(
      "UPDATE task_lists SET sync_state = 'clean', pending_op = NULL, "
      'etag = COALESCE(?, etag), updated = ? WHERE id = ?',
      variables: [
        Variable<String>(newEtag),
        Variable<String>(serverUpdated),
        Variable<String>(id),
      ],
      updates: {_db.taskLists},
    );
  }

  /// Remap a local list UUID to its server id, rewriting the list row and every
  /// task's `list_id` (plus pending_moves and inflight_creates) in one
  /// transaction, then landing the list clean. `defer_foreign_keys` lets the PK
  /// rewrite precede the child `list_id` updates within the transaction; the FK
  /// is consistent again at commit.
  Future<void> remapListId(
    String localId,
    String remoteId,
    String? etag,
    String serverUpdated,
  ) async {
    await _db.transaction(() async {
      await _db.customStatement('PRAGMA defer_foreign_keys = ON');
      final l = Variable<String>(localId);
      final r = Variable<String>(remoteId);
      await _db.customUpdate(
        'UPDATE task_lists SET id = ? WHERE id = ?',
        variables: [r, l],
        updates: {_db.taskLists},
      );
      await _db.customUpdate(
        'UPDATE tasks SET list_id = ? WHERE list_id = ?',
        variables: [r, l],
        updates: {_db.tasks},
      );
      await _db.customUpdate(
        'UPDATE pending_moves SET list_id = ? WHERE list_id = ?',
        variables: [r, l],
        updates: {_db.pendingMoves},
      );
      await _db.customUpdate(
        'UPDATE inflight_creates SET list_id = ? WHERE list_id = ?',
        variables: [r, l],
        updates: {_db.inflightCreates},
      );
      await _db.customUpdate(
        "UPDATE task_lists SET sync_state = 'clean', pending_op = NULL, "
        'etag = COALESCE(?, etag), updated = ? WHERE id = ?',
        variables: [Variable<String>(etag), Variable<String>(serverUpdated), r],
        updates: {_db.taskLists},
      );
    });
  }

  // ── pending moves (structural reorder/reparent axis) ──────────────────────

  /// Record (or replace) a pending position/parent move for a task.
  Future<void> recordMove(
    String taskId,
    String listId,
    String? parentId,
    String? previousId,
  ) async {
    await _db.customInsert(
      'INSERT INTO pending_moves (task_id, list_id, parent_id, previous_id) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(task_id) DO UPDATE SET '
      'list_id = excluded.list_id, parent_id = excluded.parent_id, '
      'previous_id = excluded.previous_id',
      variables: [
        Variable<String>(taskId),
        Variable<String>(listId),
        Variable<String>(parentId),
        Variable<String>(previousId),
      ],
      updates: {_db.pendingMoves},
    );
  }

  /// All pending moves awaiting push.
  Future<List<PendingMove>> pendingMoves() async {
    final rows = await _db
        .customSelect(
          'SELECT task_id, list_id, parent_id, previous_id FROM pending_moves',
        )
        .get();
    return [
      for (final r in rows)
        PendingMove(
          taskId: r.read<String>('task_id'),
          listId: r.read<String>('list_id'),
          parentId: r.readNullable<String>('parent_id'),
          previousId: r.readNullable<String>('previous_id'),
        ),
    ];
  }

  /// Clear a pending move after it has been pushed (or remapped away).
  Future<void> clearMove(String taskId) async {
    await _db.customUpdate(
      'DELETE FROM pending_moves WHERE task_id = ?',
      variables: [Variable<String>(taskId)],
      updates: {_db.pendingMoves},
      updateKind: UpdateKind.delete,
    );
  }

  /// Number of local changes awaiting push: dirty/deleted tasks and lists plus
  /// recorded position moves, excluding local-only lists (which never sync).
  /// Read-only — unlike `drain*`, it does not consume the queue, so the UI can
  /// show "N changes pending" without disturbing sync state.
  Future<int> pendingPushCount() async {
    final tasks = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM tasks t JOIN task_lists l ON l.id = t.list_id '
          "WHERE (t.sync_state = 'dirty' OR t.sync_state = 'deleted') "
          'AND l.local_only = 0',
        )
        .getSingle();
    final lists = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM task_lists '
          "WHERE (sync_state = 'dirty' OR sync_state = 'deleted') "
          'AND local_only = 0',
        )
        .getSingle();
    final moves = await _db
        .customSelect('SELECT COUNT(*) AS c FROM pending_moves')
        .getSingle();
    return tasks.read<int>('c') + lists.read<int>('c') + moves.read<int>('c');
  }

  // ── fresh-sync clears ─────────────────────────────────────────────────────

  /// Drop ALL local tasks, lists, moves and in-flight markers (fresh sync from
  /// an empty cache).
  Future<void> clearAll() async {
    await _db.transaction(() async {
      await _db.customUpdate(
        'DELETE FROM tasks',
        updates: {_db.tasks},
        updateKind: UpdateKind.delete,
      );
      await _db.customUpdate(
        'DELETE FROM task_lists',
        updates: {_db.taskLists},
        updateKind: UpdateKind.delete,
      );
      await _db.customUpdate(
        'DELETE FROM pending_moves',
        updates: {_db.pendingMoves},
        updateKind: UpdateKind.delete,
      );
      await _db.customUpdate(
        'DELETE FROM inflight_creates',
        updates: {_db.inflightCreates},
        updateKind: UpdateKind.delete,
      );
    });
  }

  /// Drop all *synced* lists and their tasks, preserving local-only lists.
  ///
  /// Fresh sync rebuilds the cache from Google (the source of truth for synced
  /// data). Local-only lists exist nowhere but this device, so they survive.
  /// `ON DELETE CASCADE` clears each removed list's tasks, pending moves and
  /// in-flight markers.
  Future<void> clearSynced() async {
    await _db.customUpdate(
      'DELETE FROM task_lists WHERE local_only = 0',
      updates: {
        _db.taskLists,
        _db.tasks,
        _db.pendingMoves,
        _db.inflightCreates,
      },
      updateKind: UpdateKind.delete,
    );
  }

  /// Record a sync-run outcome, keeping only the most recent 500 entries.
  Future<void> writeSyncLog({
    required int pulled,
    required int pushed,
    required int conflicts,
    required int durationMs,
    String? error,
  }) async {
    await _db.customInsert(
      'INSERT INTO sync_log (ran_at, duration_ms, pulled, pushed, conflicts, error) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<String>(nowUtcString()),
        Variable<int>(durationMs),
        Variable<int>(pulled),
        Variable<int>(pushed),
        Variable<int>(conflicts),
        Variable<String>(error),
      ],
      updates: {_db.syncLog},
    );
    // Bound growth: keep only the most recent 500 rows.
    await _db.customUpdate(
      'DELETE FROM sync_log WHERE id NOT IN '
      '(SELECT id FROM sync_log ORDER BY id DESC LIMIT 500)',
      updates: {_db.syncLog},
      updateKind: UpdateKind.delete,
    );
  }

  // ── create finalize + in-flight markers ───────────────────────────────────

  /// Atomically finalize a pushed create: rewrite the local id to the server id
  /// (self + children + move intents), adopt the server metadata, and clear the
  /// in-flight marker — all in ONE transaction. This removes the half-applied
  /// window where a crash between remap and mark-clean would leave a remapped
  /// row still flagged `pending_op = 'create'` (which would re-insert →
  /// duplicate).
  ///
  /// The final mark-clean is guarded like [markTaskClean]:
  ///  * A re-edited row (its `local_updated` moved past [expectedLocalUpdated])
  ///    keeps its dirty flag but flips `create` → `update`: the task now exists
  ///    remotely under [remoteId], so re-running it as a create would duplicate.
  ///    Its base snapshot survives (the payload as sent, which a later 412
  ///    compares against, #118).
  ///  * A row the user DELETED mid-flight is a tombstone: it keeps its pending
  ///    `delete` and only LEARNS the server id — exactly what its delete push
  ///    was missing — never flipping back to a live row.
  ///  * A clean landing clears the base (#134) and adopts the server-assigned
  ///    [serverPosition] (unless a pending move will supersede it); without the
  ///    position the row would keep its local placeholder forever, since the
  ///    adopted etag makes every future pull skip it.
  Future<void> finishCreate(
    String localId,
    String remoteId,
    String? etag,
    String serverUpdated,
    String expectedLocalUpdated,
    String? serverPosition,
  ) async {
    await _db.transaction(() async {
      await _db.customStatement('PRAGMA defer_foreign_keys = ON');
      final l = Variable<String>(localId);
      final r = Variable<String>(remoteId);
      await _db.customUpdate(
        'UPDATE tasks SET id = ? WHERE id = ?',
        variables: [r, l],
        updates: {_db.tasks},
      );
      await _db.customUpdate(
        'UPDATE tasks SET parent_id = ? WHERE parent_id = ?',
        variables: [r, l],
        updates: {_db.tasks},
      );
      await _db.customUpdate(
        'UPDATE pending_moves SET task_id = ? WHERE task_id = ?',
        variables: [r, l],
        updates: {_db.pendingMoves},
      );
      await _db.customUpdate(
        'UPDATE pending_moves SET parent_id = ? WHERE parent_id = ?',
        variables: [r, l],
        updates: {_db.pendingMoves},
      );
      await _db.customUpdate(
        'UPDATE pending_moves SET previous_id = ? WHERE previous_id = ?',
        variables: [r, l],
        updates: {_db.pendingMoves},
      );
      await _db.customUpdate(
        'UPDATE tasks SET '
        'etag = COALESCE(?1, etag), '
        'updated = ?2, '
        'position = CASE WHEN local_updated = ?3 AND ?4 IS NOT NULL AND NOT EXISTS '
        '             (SELECT 1 FROM pending_moves pm WHERE pm.task_id = tasks.id) '
        '           THEN ?4 ELSE position END, '
        // Base snapshot (#134): a clean create landing clears it (base_* is NULL
        // while clean, RFC-009 §B); a re-edited or deleted row keeps its base.
        "base_title  = CASE WHEN sync_state != 'deleted' AND local_updated = ?3 THEN NULL ELSE base_title  END, "
        "base_notes  = CASE WHEN sync_state != 'deleted' AND local_updated = ?3 THEN NULL ELSE base_notes  END, "
        "base_due    = CASE WHEN sync_state != 'deleted' AND local_updated = ?3 THEN NULL ELSE base_due    END, "
        "base_status = CASE WHEN sync_state != 'deleted' AND local_updated = ?3 THEN NULL ELSE base_status END, "
        "sync_state = CASE WHEN sync_state = 'deleted' THEN 'deleted' "
        "                  WHEN local_updated = ?3 THEN 'clean' "
        '                  ELSE sync_state END, '
        "pending_op = CASE WHEN sync_state = 'deleted' THEN 'delete' "
        '                  WHEN local_updated = ?3 THEN NULL '
        "                  ELSE 'update' END "
        'WHERE id = ?5',
        variables: [
          Variable<String>(etag),
          Variable<String>(serverUpdated),
          Variable<String>(expectedLocalUpdated),
          Variable<String>(serverPosition),
          r,
        ],
        updates: {_db.tasks},
      );
      await _db.customUpdate(
        'DELETE FROM inflight_creates WHERE local_id = ?',
        variables: [l],
        updates: {_db.inflightCreates},
        updateKind: UpdateKind.delete,
      );
    });
  }

  /// Durably mark a create as in-flight before calling the (non-idempotent)
  /// server insert; cleared by [finishCreate] on success.
  ///
  /// Also captures the base snapshot for the row (#124): [baseLocalUpdated] is
  /// the drain-time `local_updated`, so crash recovery can pass it to
  /// [finishCreate] and an edit during the in-flight window keeps its dirty
  /// flag; and `tasks.base_*` is set to the current content — the payload as
  /// sent — so orphan adoption matches on it, not on drifted local content
  /// (#122). Both writes commit before the insert, so they survive a crash.
  Future<void> recordInflightCreate(
    String localId,
    String listId,
    String baseLocalUpdated,
  ) async {
    await _db.transaction(() async {
      await _db.customInsert(
        'INSERT OR REPLACE INTO inflight_creates '
        '(local_id, list_id, base_local_updated) VALUES (?, ?, ?)',
        variables: [
          Variable<String>(localId),
          Variable<String>(listId),
          Variable<String>(baseLocalUpdated),
        ],
        updates: {_db.inflightCreates},
      );
      await _db.customUpdate(
        'UPDATE tasks SET base_title = title, base_notes = notes, '
        'base_due = due, base_status = status WHERE id = ?',
        variables: [Variable<String>(localId)],
        updates: {_db.tasks},
      );
    });
  }

  /// All in-flight create markers as `(localId, listId)` pairs (non-empty only
  /// after a crash mid-create).
  Future<List<(String, String)>> inflightCreates() async {
    final rows = await _db
        .customSelect('SELECT local_id, list_id FROM inflight_creates')
        .get();
    return [
      for (final r in rows)
        (r.read<String>('local_id'), r.read<String>('list_id')),
    ];
  }

  /// The drain-time `local_updated` recorded for an in-flight create (#124);
  /// `null` when there is no marker (or a legacy marker without one).
  Future<String?> inflightBaseLocalUpdated(String localId) async {
    final rows = await _db
        .customSelect(
          'SELECT base_local_updated FROM inflight_creates WHERE local_id = ?',
          variables: [Variable<String>(localId)],
        )
        .get();
    return rows.isEmpty
        ? null
        : rows.first.readNullable<String>('base_local_updated');
  }

  /// Clear an in-flight marker without finalizing (e.g. the insert never
  /// reached the server, so the create will be retried normally).
  Future<void> clearInflightCreate(String localId) async {
    await _db.customUpdate(
      'DELETE FROM inflight_creates WHERE local_id = ?',
      variables: [Variable<String>(localId)],
      updates: {_db.inflightCreates},
      updateKind: UpdateKind.delete,
    );
  }

  /// Whether the server may already hold this row — the predicate every delete
  /// path needs before choosing between a hard delete and a tombstone.
  ///
  /// An etag is the obvious yes. The subtle one is an open in-flight create
  /// marker: an insert was issued and its answer never arrived, so the task MAY
  /// exist on Google under an id we never recorded. Hard-deleting such a row
  /// throws that marker away with it (FK-cascaded), stranding the committed
  /// insert — the next pull then resurrects the deleted task, or leaves a
  /// second copy behind a cross-list move. Tombstoning keeps the marker alive
  /// so crash recovery adopts the orphan and the delete reaches it.
  Future<bool> serverMayHold(String id) async {
    final rows = await _db
        .customSelect(
          'SELECT 1 FROM tasks WHERE id = ?1 AND (etag IS NOT NULL '
          'OR EXISTS (SELECT 1 FROM inflight_creates WHERE local_id = ?1))',
          variables: [Variable<String>(id)],
        )
        .get();
    return rows.isNotEmpty;
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
