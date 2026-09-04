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
import '../model/sync_run.dart';
import '../model/task.dart';
import '../model/task_list.dart';
import 'database.dart' show AppDatabase;
import 'store_error.dart';
import 'stored.dart';

// Column lists kept as constants so the one-shot read and its `watch*` twin run
// byte-identical SQL (drift dedupes identical streamed queries).
const String _listCols =
    'id, remote_id, title, etag, updated, local_updated, sync_state, '
    'pending_op, local_only';
const String _taskCols =
    'id, remote_id, list_id, parent_id, position, title, notes, status, due, '
    'completed_at, etag, updated, local_updated, sync_state, pending_op, '
    'web_view_link';

const String _selectListsSql =
    'SELECT $_listCols FROM task_lists WHERE sync_state != \'deleted\'';
// Top-level rows first (parent IS NULL sorts ahead of a set parent), then by
// position — the caller folds the flat rows into the two-level tree.
const String _selectTasksSql =
    'SELECT $_taskCols FROM tasks WHERE list_id = ? AND sync_state != \'deleted\' '
    'ORDER BY (parent_id IS NOT NULL), parent_id, position';
// All visible tasks across EVERY list (tombstones excluded) — the read behind
// the "All Tasks" smart view, which aggregates every list. Top-level rows first
// so the caller can fold subtasks under their parents; then by position.
const String _selectAllTasksSql =
    "SELECT $_taskCols FROM tasks WHERE sync_state != 'deleted' "
    'ORDER BY (parent_id IS NOT NULL), parent_id, position';
// find_task_any: any row, tombstones included.
const String _selectTaskAnySql = 'SELECT $_taskCols FROM tasks WHERE id = ?';
// pending_push_count: the size of the push queue — dirty/deleted tasks in
// syncable lists, dirty/deleted lists, and queued position moves. ONE query so
// the one-shot read and its `watch*` twin cannot answer differently.
const String _pendingPushCountSql =
    'SELECT ('
    'SELECT COUNT(*) FROM tasks t JOIN task_lists l ON l.id = t.list_id '
    "WHERE (t.sync_state = 'dirty' OR t.sync_state = 'deleted') "
    'AND l.local_only = 0'
    ') + ('
    'SELECT COUNT(*) FROM task_lists '
    "WHERE (sync_state = 'dirty' OR sync_state = 'deleted') "
    'AND local_only = 0'
    ') + ('
    'SELECT COUNT(*) FROM pending_moves'
    ') AS c';

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
    'SELECT t.id, t.remote_id, t.list_id, t.parent_id, t.position, t.title, '
    't.notes, t.status, t.due, t.completed_at, t.etag, t.updated, '
    't.local_updated, t.sync_state, t.pending_op, t.web_view_link '
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
      'INSERT INTO task_lists ($_listCols) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'remote_id = COALESCE(excluded.remote_id, task_lists.remote_id), '
      'title = excluded.title, etag = excluded.etag, updated = excluded.updated, '
      'local_updated = excluded.local_updated, sync_state = excluded.sync_state, '
      // Same invariant as [upsertTask]: a list Google has acknowledged is
      // patched, never inserted again (#269). `renameList` carries the pending
      // op forward from a snapshot read a round-trip earlier, so a
      // `finishListCreate` landing in between would otherwise re-queue an
      // acknowledged list as a create — a second list on the user's account.
      // The one path that deliberately UNLEARNS a remote id (the ghost-list
      // revive) goes through [resetListToUnpushedCreate], not through here.
      'pending_op = CASE WHEN task_lists.remote_id IS NOT NULL '
      "                  AND excluded.pending_op = 'create' THEN 'update' "
      '                  ELSE excluded.pending_op END, '
      'local_only = excluded.local_only',
      variables: _listVars(list),
      updates: {_db.taskLists},
    );
  }

  /// Re-queue [list] as a create the server has NEVER seen: its `remote_id` and
  /// `etag` are cleared outright, not COALESCE-preserved (#269).
  ///
  /// The one legitimate un-learning of a remote id. The server said the list is
  /// gone (a 404 on rename, or ghost detection on the pull) while the list still
  /// holds rows Google has never seen, so the list is re-created rather than
  /// dropped (P2/D2). Keeping the dead `remote_id` would leave a row that both
  /// names a list Google does not have and is queued as a create — the create
  /// would push into the tombstone's id and 404 forever.
  Future<void> resetListToUnpushedCreate(StoredTaskList list) async {
    await _db.customInsert(
      'INSERT INTO task_lists ($_listCols) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'remote_id = NULL, title = excluded.title, etag = NULL, '
      'updated = excluded.updated, local_updated = excluded.local_updated, '
      "sync_state = 'dirty', pending_op = 'create', "
      'local_only = excluded.local_only',
      variables: _listVars(
        StoredTaskList(
          // No etag and no remote id, on the INSERT path as much as the
          // conflict path: this row is one the server has never seen.
          list: TaskList(
            id: list.list.id,
            title: list.list.title,
            updated: list.list.updated,
          ),
          syncState: SyncState.dirty,
          localUpdated: list.localUpdated,
          pendingOp: 'create',
          localOnly: list.localOnly,
        ),
      ),
      updates: {_db.taskLists},
    );
  }

  /// Upsert a list pulled from the server WITHOUT clobbering a locally
  /// dirty/deleted one — the `WHERE sync_state = 'clean'` makes skip-if-dirty
  /// atomic with the update, so a concurrent local rename (and its dirty flag)
  /// survives (mirrors [upsertRemoteTask]).
  Future<void> upsertRemoteList(StoredTaskList list) async {
    await _db.customInsert(
      'INSERT INTO task_lists ($_listCols) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'remote_id = COALESCE(excluded.remote_id, task_lists.remote_id), '
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

  /// Delete list [list] and every task row it holds in ONE transaction.
  ///
  /// [tombstone] true (the server has seen the list) leaves a `deleted` list row
  /// whose `delete` pushes — Google cascades its tasks server-side, so the local
  /// rows go now and nothing is stranded. False (a never-synced list) drops the
  /// list row outright; `ON DELETE CASCADE` would take the tasks anyway.
  ///
  /// Kill-window: split into a per-task delete loop plus the list write (as this
  /// was before #271), a process death in between hard-deletes tasks the server
  /// never saw AND leaves the list visible and undeleted — unpushed work lost
  /// with no sign of it. Wrapped here, a kill rolls the whole thing back and the
  /// list is still there to delete again. Writes only, no API call (§2).
  Future<void> deleteListWithTasks(
    StoredTaskList list, {
    required bool tombstone,
    required String now,
  }) async {
    await _db.transaction(() async {
      await _db.customUpdate(
        'DELETE FROM tasks WHERE list_id = ?',
        variables: [Variable<String>(list.list.id)],
        updates: {_db.tasks},
        updateKind: UpdateKind.delete,
      );
      if (tombstone) {
        await upsertList(
          StoredTaskList(
            list: list.list,
            syncState: SyncState.deleted,
            localUpdated: now,
            pendingOp: 'delete',
            localOnly: list.localOnly,
            remoteId: list.remoteId,
          ),
        );
      } else {
        await deleteListHard(list.list.id);
      }
    });
  }

  /// All known lists (excluding tombstones), in arbitrary order.
  Future<List<StoredTaskList>> allLists() async {
    final rows = await _db.customSelect(_selectListsSql).get();
    return rows.map(_listFromRow).toList();
  }

  /// Clean, server-backed lists as `(localId, remoteId)` — the ghost-detection
  /// set. Local-only lists are excluded: they never exist on the server, so
  /// they must never be treated as a ghost the moment they are absent from a
  /// pull (which is always). So is a list with no `remote_id`: the server has
  /// never acknowledged it, so its absence from a pull proves nothing.
  Future<List<(String, String)>> cleanServerBackedLists() async {
    final rows = await _db
        .customSelect(
          "SELECT id, remote_id FROM task_lists WHERE sync_state = 'clean' "
          'AND local_only = 0 AND remote_id IS NOT NULL',
        )
        .get();
    return [
      for (final r in rows) (r.read<String>('id'), r.read<String>('remote_id')),
    ];
  }

  /// Every list's `remote_id → local id`, tombstoned lists INCLUDED. The pull
  /// resolves each remote list through this map; missing the tombstone of a
  /// list the server still has would mint a second local row for the same
  /// remote id and trip the `remote_id` uniqueness constraint.
  Future<Map<String, String>> listIdsByRemoteId() async {
    final rows = await _db
        .customSelect(
          'SELECT id, remote_id FROM task_lists WHERE remote_id IS NOT NULL',
        )
        .get();
    return {
      for (final r in rows) r.read<String>('remote_id'): r.read<String>('id'),
    };
  }

  /// Every task's `remote_id → local id`, tombstones INCLUDED (a tombstone is
  /// exactly the row a pull must recognize rather than re-adopt as new). Global
  /// rather than per-list: a remote id is unique across the account, and a task
  /// the server moved between lists must still resolve to its own local row.
  Future<Map<String, String>> taskIdsByRemoteId() async {
    final rows = await _db
        .customSelect(
          'SELECT id, remote_id FROM tasks WHERE remote_id IS NOT NULL',
        )
        .get();
    return {
      for (final r in rows) r.read<String>('remote_id'): r.read<String>('id'),
    };
  }

  /// The LOCAL id of the task whose `remote_id` is [remoteId]; `null` when no
  /// row carries it. The single-row form of [taskIdsByRemoteId], for the API
  /// responses that name exactly one id (a pushed row's parent) — a phone
  /// syncing a few hundred tasks should not build the whole map for that.
  Future<String?> taskIdForRemote(String remoteId) async {
    final rows = await _db
        .customSelect(
          'SELECT id FROM tasks WHERE remote_id = ?',
          variables: [Variable<String>(remoteId)],
        )
        .get();
    return rows.isEmpty ? null : rows.first.read<String>('id');
  }

  /// Google's id for the list with local id [localId]; `null` when the server
  /// has never seen it (or there is no such list).
  Future<String?> listRemoteId(String localId) async {
    final rows = await _db
        .customSelect(
          'SELECT remote_id FROM task_lists WHERE id = ?',
          variables: [Variable<String>(localId)],
        )
        .get();
    return rows.isEmpty ? null : rows.first.readNullable<String>('remote_id');
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
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'remote_id = COALESCE(excluded.remote_id, tasks.remote_id), '
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
      'sync_state = excluded.sync_state, '
      // INVARIANT: `remote_id IS NOT NULL ⇒ pending_op != 'create'` (#269).
      // Callers write WHOLE rows built from a snapshot read a round-trip
      // earlier, and `pending_op` comes from that snapshot. A `finishCreate`
      // landing in between would otherwise restore `create` onto a row Google
      // has already acknowledged — and the next push would INSERT the task a
      // second time (a duplicate on the user's account), then patch it. What
      // the caller means is "this row has unpushed content"; against an
      // acknowledged row that is a PATCH, so the op is rewritten here rather
      // than trusted from the stale read.
      'pending_op = CASE WHEN tasks.remote_id IS NOT NULL '
      "                  AND excluded.pending_op = 'create' THEN 'update' "
      '                  ELSE excluded.pending_op END, '
      'web_view_link = excluded.web_view_link',
      variables: _taskVars(t),
      updates: {_db.tasks},
    );
  }

  /// Run [action] as ONE database transaction: every write inside it lands, or
  /// none does. Reads inside see the transaction's own uncommitted writes.
  ///
  /// [writeTasks] covers the common case — a set of rows decided up front. This
  /// seam is for a multi-row operation whose writes INTERLEAVE with reads, which
  /// a prepared row list cannot express: the backup restore resolves each task's
  /// parent against rows written earlier in the same restore. Writes only — the
  /// decision (and any API call) belongs outside the transaction (§2).
  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);

  /// Persist [rows] — and then hard-delete [hardDeletes] — as ONE atomic unit:
  /// every write lands or none does. The single write path for a command that
  /// touches more than one row.
  ///
  /// Kill-window: a multi-row command written as N autocommits (as the cascades,
  /// undos and clears were before #271) leaves half its rows applied when the
  /// process dies mid-way — a parent completed above an open subtask, a subtask
  /// dated before its parent (#164), a revived root with its subtree still
  /// tombstoned. Wrapped here, a kill rolls the command back whole.
  ///
  /// [rows] are applied IN ORDER, so a caller restoring a subtree lists parents
  /// before children (the FK is checked per statement). [hardDeletes] run last,
  /// so a row removed here is removed after every upsert above it. Writes only —
  /// the decision already happened in the command, never an API call inside the
  /// transaction (§2).
  Future<void> writeTasks(
    List<StoredTask> rows, {
    List<String> hardDeletes = const [],
  }) async {
    await _db.transaction(() async {
      for (final row in rows) {
        await upsertTask(row);
      }
      for (final id in hardDeletes) {
        await deleteTaskHard(id);
      }
    });
  }

  /// Upsert a row pulled from the server, but NEVER clobber a locally
  /// dirty/deleted row. The `WHERE sync_state = 'clean'` closes the pull-vs-edit
  /// race: a live edit that dirties the row after pull's skip-set snapshot but
  /// before this write survives, dirty flag and all.
  Future<void> upsertRemoteTask(StoredTask t) async {
    await _db.customInsert(
      'INSERT INTO tasks ($_taskCols) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'remote_id = COALESCE(excluded.remote_id, tasks.remote_id), '
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

  /// Hard-delete a tombstone whose confirmed delete push drained it — but only
  /// if the row's `local_updated` still equals that drain snapshot. Returns
  /// whether the row was removed.
  ///
  /// Without the guard, an undo that revived the row while the DELETE was in
  /// flight would be erased by the push completing: Google has already dropped
  /// the task, so the row the user just got back would vanish LOCALLY TOO, with
  /// no tombstone and no remote copy left to recover it from (#267). When the
  /// guard misses, the row stays and the caller decides what it now means — see
  /// [demoteSubtreeToCreate].
  Future<bool> deleteTaskIfUnchanged(
    String id,
    String expectedLocalUpdated,
  ) async {
    final affected = await _db.customUpdate(
      'DELETE FROM tasks WHERE id = ?1 AND local_updated = ?2',
      variables: [Variable<String>(id), Variable<String>(expectedLocalUpdated)],
      updates: {_db.tasks},
      updateKind: UpdateKind.delete,
    );
    return affected > 0;
  }

  /// Strip the remote identity from [rootId] and its subtree and re-queue them
  /// as fresh creates. Returns how many rows changed.
  ///
  /// Used when a DELETE that Google already carried out can no longer be
  /// applied locally (#267): the remote ids are dead — the server cascade took
  /// the subtree with the root — so the surviving rows have to go back as new
  /// inserts, not as updates against ids that would 404. Their local ids do NOT
  /// move (#224), so an undo token, an open detail panel or a captured callback
  /// still resolves.
  ///
  /// A row that is a TOMBSTONE again is left alone: its `local_updated` moved
  /// because the user re-deleted it, and resurrecting it as a create would undo
  /// the delete they just asked for. That tombstone's own push completes on the
  /// server's 404.
  Future<int> demoteSubtreeToCreate(String rootId) async {
    return _db.customUpdate(
      'WITH RECURSIVE subtree(id) AS ('
      '  SELECT ?1 '
      '  UNION ALL '
      '  SELECT t.id FROM tasks t JOIN subtree s ON t.parent_id = s.id'
      ') '
      'UPDATE tasks SET remote_id = NULL, etag = NULL, '
      "  sync_state = 'dirty', pending_op = 'create', "
      '  base_title = NULL, base_notes = NULL, base_due = NULL, '
      '  base_status = NULL '
      "WHERE id IN (SELECT id FROM subtree) AND sync_state != 'deleted'",
      variables: [Variable<String>(rootId)],
      updates: {_db.tasks},
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

  /// All visible tasks across every list, ordered top-level-first then by
  /// position — the one-shot read behind the "All Tasks" view.
  Future<List<StoredTask>> allTasks() async {
    final rows = await _db.customSelect(_selectAllTasksSql).get();
    return rows.map(_taskFromRow).toList();
  }

  /// Live stream of [allTasks], re-emitting on every task write — the "All
  /// Tasks" view subscribes to this so a create/rename/toggle in any list shows
  /// up immediately.
  ///
  /// [distinct] collapses consecutive byte-identical results: drift invalidation
  /// is table-granular, so every write to `tasks` re-runs the query and would
  /// otherwise push a fresh (but equal) list — a sync pull that rewrites many
  /// rows to the same content (mark-clean sweeps, no-op re-pulls, subtask-only
  /// writes) would storm the view with one redundant rebuild per write. Only a
  /// change in the visible set reaches the UI (T10.1 pull-storm guard).
  Stream<List<StoredTask>> watchAllTasks() => _db
      .customSelect(_selectAllTasksSql, readsFrom: {_db.tasks})
      .watch()
      .map((rows) => rows.map(_taskFromRow).toList())
      .distinct(_sameTaskList);

  // ── Invariants ────────────────────────────────────────────────────────────

  /// Remote ids this store has already seen for a task id — the history half of
  /// the write-once check, which a single state cannot see. Only ever grows, and
  /// only [checkInvariants] touches it, so it costs a production run nothing.
  final Map<String, String> _seenTaskRemoteIds = {};

  /// Assert the store's structural invariants and throw a [StateError] naming
  /// EVERY violation found (#269). A test/diagnostic entry point: the property
  /// and dual-device suites call it after every sync run, so a corrupt write is
  /// caught in the run that caused it rather than surfacing runs later as a
  /// duplicate task or an orphaned subtree.
  ///
  /// The invariants, all of them previously carried only in comments:
  ///
  /// 1. **A row the server acknowledged is never queued as a create.**
  ///    `remote_id IS NOT NULL ⇒ pending_op != 'create'`, for tasks and lists.
  ///    Violated, the push inserts a SECOND copy on the user's account.
  /// 2. **A clean row carries no base snapshot.** The base is the content as of
  ///    the last server agreement, captured when a clean row goes dirty; a clean
  ///    row that kept one would have a 412 diffed against stale content.
  /// 3. **Subtasks are strictly one level, in their parent's list.** A third
  ///    level is a shape Google's forest model does not have (invariant #1), and
  ///    a subtask parked in a different list from its parent is unaddressable on
  ///    the wire — the insert names a `(listId, parent)` pair the server rejects.
  /// 4. **A task's `remote_id` is write-once.** Once Google has named a row, that
  ///    name never changes and is never forgotten: unlearning it strands the
  ///    server's copy and re-creates the task. (Lists are exempt by design —
  ///    [resetListToUnpushedCreate] unlearns one deliberately when the server
  ///    says the list is gone.)
  Future<void> checkInvariants() async {
    final bad = <String>[];

    final ackedCreates = await _db
        .customSelect(
          "SELECT 'task' AS kind, id, remote_id FROM tasks "
          "WHERE remote_id IS NOT NULL AND pending_op = 'create' "
          'UNION ALL '
          "SELECT 'list' AS kind, id, remote_id FROM task_lists "
          "WHERE remote_id IS NOT NULL AND pending_op = 'create'",
        )
        .get();
    for (final r in ackedCreates) {
      bad.add(
        '${r.read<String>('kind')} ${r.read<String>('id')} has remote_id '
        "${r.read<String>('remote_id')} but is queued as a 'create'",
      );
    }

    final cleanWithBase = await _db
        .customSelect(
          'SELECT id FROM tasks '
          "WHERE sync_state = 'clean' AND (base_title IS NOT NULL "
          'OR base_notes IS NOT NULL OR base_due IS NOT NULL '
          'OR base_status IS NOT NULL)',
        )
        .get();
    for (final r in cleanWithBase) {
      bad.add('task ${r.read<String>('id')} is clean but kept a base snapshot');
    }

    final thirdLevel = await _db
        .customSelect(
          'SELECT c.id AS id FROM tasks c JOIN tasks p ON p.id = c.parent_id '
          'WHERE p.parent_id IS NOT NULL',
        )
        .get();
    for (final r in thirdLevel) {
      bad.add('task ${r.read<String>('id')} is a third level of nesting');
    }

    final splitParents = await _db
        .customSelect(
          'SELECT c.id AS id, c.list_id AS child_list, p.list_id AS parent_list '
          'FROM tasks c JOIN tasks p ON p.id = c.parent_id '
          'WHERE c.list_id != p.list_id',
        )
        .get();
    for (final r in splitParents) {
      bad.add(
        'task ${r.read<String>('id')} is in list '
        '${r.read<String>('child_list')} but its parent is in list '
        '${r.read<String>('parent_list')}',
      );
    }

    final tasks = await _db
        .customSelect('SELECT id, remote_id FROM tasks')
        .get();
    for (final r in tasks) {
      final id = r.read<String>('id');
      final remoteId = r.readNullable<String>('remote_id');
      final seen = _seenTaskRemoteIds[id];
      if (seen == null) {
        if (remoteId != null) _seenTaskRemoteIds[id] = remoteId;
      } else if (remoteId == null) {
        bad.add('task $id unlearned its remote_id $seen');
      } else if (remoteId != seen) {
        bad.add('task $id changed remote_id from $seen to $remoteId');
      }
    }

    if (bad.isNotEmpty) {
      throw StateError('store invariants violated:\n  ${bad.join('\n  ')}');
    }
  }

  /// Fetch a single task by id regardless of sync_state (tombstones included);
  /// `null` when absent.
  Future<StoredTask?> findTaskAny(String id) async {
    final rows = await _db
        .customSelect(_selectTaskAnySql, variables: [Variable<String>(id)])
        .get();
    return rows.isEmpty ? null : _taskFromRow(rows.first);
  }

  /// Fetch a single task list by id regardless of sync_state (tombstoned lists
  /// included); `null` when absent. The list twin of [findTaskAny] — the
  /// backup restore needs to know whether a local id is TAKEN, and a tombstone
  /// takes it just as firmly as a live row.
  Future<StoredTaskList?> findListAny(String id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_listCols FROM task_lists WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .get();
    return rows.isEmpty ? null : _listFromRow(rows.first);
  }

  /// Live stream of [listTasks] for [listId], re-emitting on every task write.
  /// [distinct] applies the same pull-storm guard as [watchAllTasks].
  Stream<List<StoredTask>> watchTasks(String listId) => _db
      .customSelect(
        _selectTasksSql,
        variables: [Variable<String>(listId)],
        readsFrom: {_db.tasks},
      )
      .watch()
      .map((rows) => rows.map(_taskFromRow).toList())
      .distinct(_sameTaskList);

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
      .map((rows) => rows.isEmpty ? null : _taskFromRow(rows.first))
      // The pull-storm guard for the detail panel's single-task stream: a no-op
      // rewrite of the same row must not re-notify (StoredTask has value ==).
      .distinct();

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

  /// Resolve a 412 `ConflictedCopy` as ONE atomic pair (MIGRATION-PLAN §5): land
  /// the canonical remote row over the dirty id AND insert the local edit's
  /// preserved copy in a SINGLE transaction.
  ///
  /// Kill-window: split across two writes (as the reference is), a crash in the
  /// gap loses the local edit for good — the canonical [remote] has already
  /// overwritten the dirty id, so the next run finds nothing left to fork the
  /// copy from (P3 data loss). Wrapped here, a kill rolls BOTH back: the row
  /// stays dirty on its stale etag and the next run re-resolves the 412,
  /// preserving the edit. Writes only — the refetch that produced [remote]
  /// already happened, never an API call inside the transaction (§2).
  ///
  /// The canonical landing reuses [applyPushedTask] (not a raw [upsertTask]) so a
  /// refetch naming a parent this device never pulled DETACHES that unknown
  /// parent instead of aborting on the FK (#155).
  Future<void> resolveConflictedCopy(
    Task remote,
    String expectedLocalUpdated,
    StoredTask copy,
  ) async {
    await _db.transaction(() async {
      await applyPushedTask(remote, expectedLocalUpdated);
      await upsertTask(copy);
    });
  }

  // ── post-network guarded writes (#268) ────────────────────────────────────
  //
  // Every engine write that lands AFTER an `await` on the network is a write
  // against a snapshot the user may have edited in the meantime. The push paths
  // above ([markTaskClean], [applyPushedTask], [finishCreate]) arbitrate that
  // race with the drained `local_updated`; the three primitives below are the
  // same guard for the repair paths that used to write a raw [upsertTask]. Each
  // returns how many rows it changed, so the engine can tell "applied" from
  // "the row moved under me" and leave a moved row dirty for the next run
  // instead of overwriting the newer edit.

  /// Land the 412 base-merge result on [id] — but only while the row still
  /// carries [expectedLocalUpdated]. Returns the number of rows changed.
  ///
  /// The merge is computed from a row drained at the START of the update pass:
  /// by the time the 412 and its refetch have come back, dozens of other
  /// requests may have gone by and the user may have typed into this very row.
  /// Writing the older merge then reset both the content AND `local_updated`,
  /// so the newer edit was neither kept nor ever pushed. On a miss (0 rows) the
  /// row keeps its own content, its dirty flag and its stale etag; the next run
  /// 412s again and re-merges against the content the user actually has.
  ///
  /// Only the fields the merge can change are written — `sync_state`,
  /// `pending_op` and `base_*` stay exactly as the guard found them, because a
  /// merged row stays dirty on the base it was captured with.
  Future<int> mergeConflictIfUnchanged(
    String id,
    String expectedLocalUpdated,
    Task merged,
  ) => _db.customUpdate(
    'UPDATE tasks SET title = ?1, notes = ?2, status = ?3, due = ?4, '
    'completed_at = ?5, etag = ?6, updated = ?7 '
    'WHERE id = ?8 AND local_updated = ?9',
    variables: [
      Variable<String>(merged.title),
      Variable<String>(merged.notes),
      Variable<String>(merged.status.apiStr),
      Variable<String>(merged.due),
      Variable<String>(merged.completed),
      Variable<String>(merged.etag),
      Variable<String>(merged.updated),
      Variable<String>(id),
      Variable<String>(expectedLocalUpdated),
    ],
    updates: {_db.tasks},
  );

  /// Undo the optimistic half of a move that will never reach the server, but
  /// only while [id] is still the CLEAN row carrying [expectedLocalUpdated].
  /// Returns the number of rows changed.
  ///
  /// The revert is exactly "drop the etag": the local placement stays, and the
  /// missing etag is what makes the next pull re-link the row to the server's
  /// truth (P6). Under the guard the rest of the pre-call snapshot is
  /// byte-identical to the row, so there is nothing else to write back — and
  /// writing it back anyway is precisely the bug: a move ladder can spend four
  /// backoff retries in the air, and an edit made in that window was reverted
  /// to old, CLEAN content that never synced.
  Future<int> revertMoveIfUnchanged(String id, String expectedLocalUpdated) =>
      _db.customUpdate(
        'UPDATE tasks SET etag = NULL '
        "WHERE id = ?1 AND local_updated = ?2 AND sync_state = 'clean'",
        variables: [
          Variable<String>(id),
          Variable<String>(expectedLocalUpdated),
        ],
        updates: {_db.tasks},
      );

  /// Flatten a third-level row to top-level (invariant #1), but only while [id]
  /// still carries [expectedLocalUpdated] and is still nested. [dropEtag] also
  /// clears the etag so the next pull re-examines the row. Returns the number of
  /// rows changed.
  ///
  /// A miss leaves the row nested — the next run's D7 sweep re-detects it and
  /// promotes the content the user now has, rather than this pass restoring the
  /// content it read before the corrective move went out.
  Future<int> promoteIfUnchanged(
    String id,
    String expectedLocalUpdated, {
    required bool dropEtag,
  }) => _db.customUpdate(
    'UPDATE tasks SET parent_id = NULL, '
    'etag = CASE WHEN ?3 = 1 THEN NULL ELSE etag END '
    'WHERE id = ?1 AND local_updated = ?2 AND parent_id IS NOT NULL',
    variables: [
      Variable<String>(id),
      Variable<String>(expectedLocalUpdated),
      Variable<int>(dropEtag ? 1 : 0),
    ],
    updates: {_db.tasks},
  );

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

  /// Every row's base snapshot, keyed by task id — the bulk form of
  /// [baseSnapshot] for the backup export, which would otherwise issue one
  /// query per task. Rows with no base captured (every clean row, §B) are
  /// absent from the map.
  Future<Map<String, BaseSnapshot>> allBaseSnapshots() async {
    final rows = await _db
        .customSelect(
          'SELECT id, base_title, base_notes, base_due, base_status '
          'FROM tasks WHERE base_title IS NOT NULL',
        )
        .get();
    return {
      for (final r in rows)
        r.read<String>('id'): BaseSnapshot(
          title: r.read<String>('base_title'),
          notes: r.readNullable<String>('base_notes'),
          due: r.readNullable<String>('base_due'),
          status:
              TaskStatus.parseApi(
                r.readNullable<String>('base_status') ?? '',
              ) ??
              TaskStatus.needsAction,
        ),
    };
  }

  /// Write a base snapshot onto a row directly (#272). Only the backup RESTORE
  /// uses this: every other path captures the base as a side effect of the edit
  /// that dirties the row ([upsertTask]), which a restore cannot reproduce —
  /// the row is inserted already dirty, so there is no clean predecessor to
  /// snapshot. Writing a base onto a CLEAN row would violate schema invariant
  /// §B, so callers must only use it for a dirty/deleted row.
  Future<void> setBaseSnapshot(String taskId, BaseSnapshot base) async {
    await _db.customUpdate(
      'UPDATE tasks SET base_title = ?2, base_notes = ?3, base_due = ?4, '
      'base_status = ?5 WHERE id = ?1',
      variables: [
        Variable<String>(taskId),
        Variable<String>(base.title),
        Variable<String>(base.notes),
        Variable<String>(base.due),
        Variable<String>(base.status.apiStr),
      ],
      updates: {_db.tasks},
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

  /// Ids of the clean, server-backed tasks in [listId] — the per-list
  /// ghost-detection set (a clean row absent from the server's pull is a ghost
  /// to remove). A row with no `remote_id` is excluded: the server never
  /// acknowledged it, so it cannot be missing from a pull.
  Future<Set<String>> cleanTaskIdsForList(String listId) async {
    final rows = await _db
        .customSelect(
          "SELECT id FROM tasks WHERE list_id = ? AND sync_state = 'clean' "
          'AND remote_id IS NOT NULL',
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
        "  WHERE list_id = ?1 AND remote_id IS NULL AND sync_state != 'deleted' "
        '    AND (parent_id IS NULL OR parent_id IN ('
        '        SELECT id FROM tasks '
        "        WHERE list_id = ?1 AND remote_id IS NULL AND sync_state != 'deleted')))",
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
          'SELECT 1 FROM tasks WHERE list_id = ? AND remote_id IS NULL '
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

  /// Apply a cross-list move's clone+removal window as ONE atomic unit
  /// (kill-safety, #182): upsert every recreated [clones] row (parent before
  /// child), then remove each original — TOMBSTONE the ones the server may hold
  /// ([tombstones], upserted as `deleted`) and hard-delete the ones it never saw
  /// ([hardDeletes]) — all in a SINGLE transaction.
  ///
  /// Kill-window: split across many separate writes (as `move_task_to_list` /
  /// `remove_moved_original` are in the reference), a crash after the clones land
  /// but before the originals are removed leaves BOTH the originals and their
  /// clones live — the moved subtree is silently duplicated (P8). Wrapped here, a
  /// kill rolls the whole window back: neither clone nor removal persists and the
  /// next run re-attempts the move from a clean starting point.
  ///
  /// Writes only — Google has no native cross-list move, so this is purely local
  /// bookkeeping; the clone's `create` and the original's `delete` push later,
  /// never an API call inside the transaction (§2). The caller owns the subtree
  /// walk and the [serverMayHold] classification, so the ordered lists arrive
  /// ready to apply (descendants before their root in [tombstones]/[hardDeletes],
  /// matching the reference's removal order).
  Future<void> finishCrossListMove({
    required List<StoredTask> clones,
    required List<StoredTask> tombstones,
    required List<String> hardDeletes,
  }) async {
    await _db.transaction(() async {
      for (final clone in clones) {
        await upsertTask(clone);
      }
      for (final tombstone in tombstones) {
        await upsertTask(tombstone);
      }
      for (final id in hardDeletes) {
        await deleteTaskHard(id);
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

  /// Finalize a pushed (or adopted) list create: LEARN the server id into
  /// `remote_id` and land the list clean, in one write. The list's primary key
  /// is IMMUTABLE (#224), so nothing that references it — its tasks' `list_id`,
  /// queued moves, in-flight markers, the sidebar selection, the router URL —
  /// has to be rewritten.
  Future<void> finishListCreate(
    String localId,
    String remoteId,
    String? etag,
    String serverUpdated,
  ) async {
    await _db.customUpdate(
      "UPDATE task_lists SET remote_id = ?1, sync_state = 'clean', "
      'pending_op = NULL, etag = COALESCE(?2, etag), updated = ?3 '
      'WHERE id = ?4',
      variables: [
        Variable<String>(remoteId),
        Variable<String>(etag),
        Variable<String>(serverUpdated),
        Variable<String>(localId),
      ],
      updates: {_db.taskLists},
    );
  }

  // ── pending moves (structural reorder/reparent axis) ──────────────────────

  /// Apply a reorder atomically: reassign the [repositioned] rows' `position`
  /// strings AND record the pending move in ONE transaction (G1 #202,
  /// kill-window class F6 closed). Split into separate writes, a crash between
  /// the position rewrites and the move record would leave the stored order and
  /// the queued move disagreeing — the local order says one thing, the pending
  /// push another. Wrapped here, a kill rolls BOTH back and the next drag starts
  /// clean. Writes only — the reorder decision already happened in the command,
  /// never an API call inside the transaction (§2).
  Future<void> reorderSiblings(
    List<StoredTask> repositioned, {
    required String taskId,
    required String listId,
    String? parentId,
    String? previousId,
  }) async {
    await _db.transaction(() async {
      for (final t in repositioned) {
        await upsertTask(t);
      }
      await recordMove(taskId, listId, parentId, previousId);
    });
  }

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

  /// Land a pushed move as ONE atomic pair (MIGRATION-PLAN §5): clear the
  /// pending move intent AND adopt the server's response in a SINGLE
  /// transaction. [adoptBody] adopts the whole response body via
  /// [applyPushedTask] (a CLEAN row — a move can complete the task server-side,
  /// P6); otherwise only the meta (etag/updated) is refreshed via
  /// [refreshTaskMeta], sparing an unrelated pending content edit.
  ///
  /// Kill-window: split across two writes (as the reference is —
  /// `clear_move` then `apply_move_response`), a crash in the gap leaves the
  /// intent gone with the server's parent/position/etag never adopted, so the
  /// row keeps its optimistic pre-move etag with no move queued to correct it —
  /// the drift only self-heals if a later pull happens to notice the mismatch.
  /// Wrapped here, a kill rolls BOTH back: the move survives and the next run
  /// re-pushes it. Writes only — the move call that produced [remote] already
  /// happened, never an API call inside the transaction (§2).
  ///
  /// [clearMove] MUST run first inside the txn: [applyPushedTask] refuses to
  /// touch parent/position while a pending move exists (its guard), so the
  /// server body can only land once the intent is gone.
  Future<void> finishMove(
    String taskId,
    Task remote, {
    required bool adoptBody,
    required String expectedLocalUpdated,
  }) async {
    await _db.transaction(() async {
      await clearMove(taskId);
      if (adoptBody) {
        await applyPushedTask(remote, expectedLocalUpdated);
      } else {
        await refreshTaskMeta(remote.id, remote.etag, remote.updated);
      }
    });
  }

  /// Number of local changes awaiting push: dirty/deleted tasks and lists plus
  /// recorded position moves, excluding local-only lists (which never sync).
  /// Read-only — unlike `drain*`, it does not consume the queue, so the UI can
  /// show "N changes pending" without disturbing sync state.
  Future<int> pendingPushCount() async {
    final row = await _db.customSelect(_pendingPushCountSql).getSingle();
    return row.read<int>('c');
  }

  /// Live stream of [pendingPushCount], re-emitting whenever the push queue
  /// changes — a local edit fills it, a completed push or an erase drains it.
  ///
  /// The UI keeps this number on screen for a whole session (Properties, Sync
  /// activity, the reset confirm), and a one-shot read went stale the moment
  /// the next edit or push landed — it reported changes pending with no dirty
  /// row left (#232). [distinct] is the pull-storm guard the task streams use:
  /// drift invalidation is table-granular, so a sync sweep re-runs the query
  /// per write, and only a change in the NUMBER may reach the UI.
  Stream<int> watchPendingPushCount() => _db
      .customSelect(
        _pendingPushCountSql,
        readsFrom: {_db.tasks, _db.taskLists, _db.pendingMoves},
      )
      .watch()
      .map((rows) => rows.single.read<int>('c'))
      .distinct();

  // ── fresh-sync clears ─────────────────────────────────────────────────────

  /// Drop ALL local tasks, lists, moves and in-flight markers (fresh sync from
  /// an empty cache). The sync log — a record of THIS install's runs, not of
  /// any account's content — survives; see [resetLocalData] for the switch-
  /// accounts nuke that clears it too.
  Future<void> clearAll() => _clearRows(includeSyncLog: false);

  /// The account-switch nuke (#215): erase EVERY local row — the synced cache
  /// and the local-only lists/tasks that exist nowhere else — plus every push
  /// drain (dirty rows, tombstones, queued moves, in-flight create markers) and
  /// the sync log of the account being left behind.
  ///
  /// Stricter than [clearSynced] on purpose. Fresh sync spares local-only lists
  /// because Google cannot recreate them; an account switch must not, or the
  /// previous account's private lists would surface under the next one. Once
  /// this has run, a push carrying the old account's data is impossible —
  /// nothing is left to drain.
  ///
  /// Destructive and irreversible: the caller is responsible for the durable
  /// recovery dump and the user's explicit confirmation (see `LocalDataReset`).
  /// `config.json` / `prefs.json` live outside the database and are untouched.
  Future<void> resetLocalData() => _clearRows(includeSyncLog: true);

  Future<void> _clearRows({required bool includeSyncLog}) async {
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
      if (includeSyncLog) {
        await _db.customUpdate(
          'DELETE FROM sync_log',
          updates: {_db.syncLog},
          updateKind: UpdateKind.delete,
        );
      }
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
  ///
  /// A failure is persisted as its [SyncFailureKind] name and NOTHING else
  /// (#131/#187, #218). The raw typed detail can embed a request URL with query
  /// params, a refresh-denial string, raw SQL, or a captive portal's HTML login
  /// page — it belongs in the log, never in a table the UI reads.
  Future<void> writeSyncLog({
    required int pulled,
    required int pushed,
    required int conflicts,
    required int durationMs,
    SyncFailureKind? failure,
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
        Variable<String>(failure?.name),
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

  /// The most recent sync runs, NEWEST FIRST, capped at [limit] (#218).
  ///
  /// The cap lives in the query, not the caller: the table retains up to 500
  /// rows, and the Sync activity screen renders a bounded window of them. A row
  /// whose stored values are malformed still comes back — an unrecognized
  /// failure code degrades to [SyncFailureKind.unknown] and an unparseable stamp
  /// to a null [SyncRun.ranAt] — because a run that happened is worth showing.
  Future<List<SyncRun>> recentSyncRuns({int limit = 50}) async {
    final rows = await _db
        .customSelect(
          'SELECT id, ran_at, duration_ms, pulled, pushed, conflicts, error '
          'FROM sync_log ORDER BY id DESC LIMIT ?',
          variables: [Variable<int>(limit)],
          readsFrom: {_db.syncLog},
        )
        .get();
    return [
      for (final r in rows)
        SyncRun(
          id: r.read<int>('id'),
          ranAt: DateTime.tryParse(r.read<String>('ran_at'))?.toUtc(),
          durationMs: r.readNullable<int>('duration_ms') ?? 0,
          pulled: r.read<int>('pulled'),
          pushed: r.read<int>('pushed'),
          conflicts: r.read<int>('conflicts'),
          failure: SyncFailureKind.parse(r.readNullable<String>('error')),
        ),
    ];
  }

  // ── create finalize + in-flight markers ───────────────────────────────────

  /// Atomically finalize a pushed create: LEARN the server id into `remote_id`,
  /// adopt the server metadata, and clear the in-flight marker — all in ONE
  /// transaction. This removes the half-applied window where a crash between
  /// the two would leave a row that the server holds still flagged
  /// `pending_op = 'create'` (which would re-insert → duplicate).
  ///
  /// [localId] is and stays the row's primary key: the id is IMMUTABLE for the
  /// row's lifetime (#224), so every reference held outside the store — the
  /// router's open-detail id, an undo token, the pending-edits registry — keeps
  /// resolving across a landing create push. `remote_id` is write-once; nothing
  /// unlearns it.
  ///
  /// The mark-clean is guarded like [markTaskClean]:
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
      await _db.customUpdate(
        'UPDATE tasks SET '
        'remote_id = ?6, '
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
          Variable<String>(localId),
          Variable<String>(remoteId),
        ],
        updates: {_db.tasks},
      );
      await _db.customUpdate(
        'DELETE FROM inflight_creates WHERE local_id = ?',
        variables: [Variable<String>(localId)],
        updates: {_db.inflightCreates},
        updateKind: UpdateKind.delete,
      );
    });
  }

  /// Durably mark a create as in-flight before calling the (non-idempotent)
  /// server insert; cleared by [finishCreate] on success. Returns the row the
  /// marker was based on, or `null` when there is no such row (nothing is
  /// written then — a marker with no row to adopt for is worse than none).
  ///
  /// Also captures the base snapshot for the row (#124): `base_*` is set to the
  /// row's content as read INSIDE this transaction and `base_local_updated` to
  /// that same row's `local_updated`, so crash recovery can pass it to
  /// [finishCreate] and an edit during the in-flight window keeps its dirty
  /// flag. Both writes commit before the insert, so they survive a crash.
  ///
  /// The returned snapshot is the ONE the caller must build its insert payload
  /// from (#268). The base is what orphan adoption matches the committed server
  /// row against ([findOrphanByBase]); a payload built from an older drained
  /// row would put DIFFERENT content on the server than the base describes, and
  /// a lost insert response would then fail to recognize its own orphan and
  /// insert the task a second time.
  Future<StoredTask?> recordInflightCreate(String localId, String listId) =>
      _db.transaction(() async {
        final row = await findTaskAny(localId);
        if (row == null) return null;
        await writeInflightCreate(localId, listId, row.localUpdated);
        await _db.customUpdate(
          'UPDATE tasks SET base_title = title, base_notes = notes, '
          'base_due = due, base_status = status WHERE id = ?',
          variables: [Variable<String>(localId)],
          updates: {_db.tasks},
        );
        return row;
      });

  /// Write an in-flight create marker verbatim, WITHOUT capturing a base from
  /// the row. [recordInflightCreate] is the one the sync engine wants (it
  /// snapshots the row it is about to send); this raw form exists for the
  /// backup restore (#272), which brings both the marker and the base it was
  /// taken with back from the file and must not re-derive either.
  Future<void> writeInflightCreate(
    String localId,
    String listId,
    String? baseLocalUpdated,
  ) async {
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
  }

  /// All in-flight create markers with the drain snapshot each was taken at,
  /// keyed by local id — the bulk form of [inflightCreates] +
  /// [inflightBaseLocalUpdated] that the backup export needs.
  Future<Map<String, String?>> allInflightCreateBases() async {
    final rows = await _db
        .customSelect(
          'SELECT local_id, base_local_updated FROM inflight_creates',
        )
        .get();
    return {
      for (final r in rows)
        r.read<String>('local_id'): r.readNullable<String>(
          'base_local_updated',
        ),
    };
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
  /// A learned `remote_id` is the obvious yes. The subtle one is an open
  /// in-flight create marker: an insert was issued and its answer never
  /// arrived, so the task MAY exist on Google under an id we never recorded.
  /// Hard-deleting such a row throws that marker away with it (FK-cascaded),
  /// stranding the committed insert — the next pull then resurrects the deleted
  /// task, or leaves a second copy behind a cross-list move. Tombstoning keeps
  /// the marker alive so crash recovery adopts the orphan and the delete
  /// reaches it.
  Future<bool> serverMayHold(String id) async {
    final rows = await _db
        .customSelect(
          'SELECT 1 FROM tasks WHERE id = ?1 AND (remote_id IS NOT NULL '
          'OR EXISTS (SELECT 1 FROM inflight_creates WHERE local_id = ?1))',
          variables: [Variable<String>(id)],
        )
        .get();
    return rows.isNotEmpty;
  }

  // ── binding + decoding ──────────────────────────────────────────────────

  static List<Variable> _listVars(StoredTaskList l) => [
    Variable<String>(l.list.id),
    Variable<String>(l.remoteId),
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
    Variable<String>(t.remoteId),
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
      remoteId: row.readNullable<String>('remote_id'),
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
      remoteId: row.readNullable<String>('remote_id'),
    );
  }
}

/// Element-wise equality for the task-watch streams' `distinct` guard. `List`
/// has only identity `==`, so two equal-content results from consecutive query
/// runs never compare equal on their own; [StoredTask] carries value equality,
/// so a positional element compare is the content check the pull-storm guard
/// needs. Returns true (suppress) only when the visible set is unchanged.
bool _sameTaskList(List<StoredTask> a, List<StoredTask> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
