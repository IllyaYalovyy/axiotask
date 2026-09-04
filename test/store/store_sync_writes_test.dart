// Port of `store/repo.rs`'s in-file repo tests — the T1.4a partition: the
// push-side write paths (`drain_dirty` / `drain_dirty_lists`), the in-flight
// race guards (`mark_task_clean` / `apply_pushed_task`), and the base-snapshot
// CASE capture/clear that `upsert_task` drives (#124/#139). Each test names the
// invariant it protects; the finish_create / tombstone / rehome / counts /
// clear paths belong to T1.4b and are ported there.
//
// Assertions read STATE the store persists — the rows drained for push, the
// values `list_tasks` / `find_task_any` return after a landing, and the base
// snapshot the reconciler will later diff a 412 against — never which SQL ran.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

/// A fresh in-memory store, torn down with the test.
Future<Store> freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return Store(db);
}

const _t0 = '2026-01-01T00:00:00Z';

StoredTaskList listOf(String id) => StoredTaskList(
  list: TaskList(id: id, title: 'Inbox', etag: 'e1', updated: _t0),
  syncState: SyncState.clean,
  localUpdated: _t0,
);

StoredTaskList localListOf(String id) => StoredTaskList(
  list: TaskList(id: id, title: 'Scratch', updated: _t0),
  syncState: SyncState.clean,
  localUpdated: _t0,
  localOnly: true,
);

StoredTask taskOf(String id, String listId, String? parent, String position) =>
    StoredTask(
      task: Task(
        id: id,
        parent: parent,
        position: position,
        title: 'task $id',
        status: TaskStatus.needsAction,
        etag: 'e1',
        updated: _t0,
      ),
      listId: listId,
      syncState: SyncState.clean,
      localUpdated: _t0,
    );

/// [taskOf] but dirtied with a pending op — the drain/push starting state.
StoredTask dirtyTask(
  String id,
  String listId,
  String op, {
  String? parent,
  String position = '1',
  String localUpdated = _t0,
  SyncState state = SyncState.dirty,
}) {
  final base = taskOf(id, listId, parent, position);
  return StoredTask(
    task: base.task,
    listId: listId,
    syncState: state,
    localUpdated: localUpdated,
    pendingOp: op,
  );
}

void main() {
  group('drains', () {
    test('drain_dirty_lists excludes a local-only list', () async {
      // A local-only list can never be push-pending, but even if marked dirty
      // it must never be drained for push — its list does not exist on Google.
      final s = await freshStore();
      final l = StoredTaskList(
        list: localListOf('LOCAL').list,
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'create',
        localOnly: true,
      );
      await s.upsertList(l);
      expect(await s.drainDirtyLists(), isEmpty);
    });

    test('drain_dirty excludes tasks in a local-only list', () async {
      final s = await freshStore();
      await s.upsertList(localListOf('LOCAL'));
      await s.upsertList(listOf('SYNCED'));
      await s.upsertTask(dirtyTask('LT', 'LOCAL', 'create'));
      await s.upsertTask(dirtyTask('ST', 'SYNCED', 'create'));
      final drained = await s.drainDirty();
      expect(drained.map((t) => t.task.id), [
        'ST',
      ], reason: 'only the synced list\'s task is pushed');
    });

    test('drain_dirty orders create before update before delete', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(dirtyTask('a', 'L1', 'update', position: '1'));
      await s.upsertTask(dirtyTask('b', 'L1', 'create', position: '2'));
      await s.upsertTask(
        dirtyTask('c', 'L1', 'delete', position: '3', state: SyncState.deleted),
      );
      final drained = await s.drainDirty();
      expect(drained.map((t) => t.pendingOp), ['create', 'update', 'delete']);
    });
  });

  group('mark_task_clean race guard', () {
    test('fresh snapshot adopts the etag and clears the dirty flags', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(dirtyTask('T1', 'L1', 'update'));
      await s.markTaskClean('T1', 'e-new', '2026-02-01T00:00:00Z', _t0);
      final row = (await s.listTasks('L1')).single;
      expect(row.syncState, SyncState.clean);
      expect(row.task.etag, 'e-new');
      expect(row.task.updated, '2026-02-01T00:00:00Z');
      expect(row.pendingOp, isNull);
    });

    test('stale snapshot keeps the row dirty but adopts the etag', () async {
      // The lost-update race: the row was re-edited while its push was in
      // flight, so the drained local_updated no longer matches. The dirty flag
      // must survive (the newer edit still needs to push), but the fresh etag
      // is adopted so the re-push won't 412.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(
        dirtyTask('T1', 'L1', 'update', localUpdated: '2026-01-01T00:00:05Z'),
      );
      await s.markTaskClean('T1', 'e-new', '2026-02-01T00:00:00Z', _t0);
      final row = (await s.listTasks('L1')).single;
      expect(row.syncState, SyncState.dirty, reason: 'newer edit stays queued');
      expect(row.pendingOp, 'update');
      expect(row.task.etag, 'e-new', reason: 'fresh etag adopted anyway');
    });
  });

  group('delete_task_if_unchanged / demote_subtree_to_create (#267)', () {
    /// A synced tombstone plus one synced child tombstone, as `deleteTask`
    /// writes them: both rows carry Google's id, only the root is pushable.
    Future<Store> tombstonedPair({String localUpdated = _t0}) async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      for (final (id, parent, op) in [
        ('P', null, 'delete'),
        ('C', 'P', null),
      ]) {
        final base = taskOf(id, 'L1', parent, '1');
        await s.upsertTask(
          StoredTask(
            task: base.task,
            listId: 'L1',
            syncState: SyncState.deleted,
            localUpdated: localUpdated,
            pendingOp: op,
            remoteId: 'r-$id',
          ),
        );
      }
      return s;
    }

    test('a matching snapshot removes the row and its subtree', () async {
      final s = await tombstonedPair();
      expect(await s.deleteTaskIfUnchanged('P', _t0), isTrue);
      expect(await s.findTaskAny('P'), isNull);
      expect(await s.findTaskAny('C'), isNull, reason: 'FK cascade');
    });

    test('a stale snapshot keeps the row — an undo revived it', () async {
      // The row was revived while the DELETE was in flight, so its
      // local_updated moved. Deleting it now would lose it on both sides.
      final s = await tombstonedPair(localUpdated: '2026-01-01T00:00:05Z');
      expect(await s.deleteTaskIfUnchanged('P', _t0), isFalse);
      expect(await s.findTaskAny('P'), isNotNull);
    });

    test('demote strips the dead remote identity across the subtree', () async {
      final s = await tombstonedPair(localUpdated: '2026-01-01T00:00:05Z');
      // What undo does to the pair: revive both in place as dirty updates.
      for (final id in ['P', 'C']) {
        final row = (await s.findTaskAny(id))!;
        await s.upsertTask(
          StoredTask(
            task: row.task,
            listId: row.listId,
            syncState: SyncState.dirty,
            localUpdated: '2026-01-01T00:00:05Z',
            pendingOp: 'update',
            remoteId: row.remoteId,
          ),
        );
      }

      expect(await s.demoteSubtreeToCreate('P'), 2);
      for (final id in ['P', 'C']) {
        final row = (await s.findTaskAny(id))!;
        expect(row.remoteId, isNull, reason: '$id: Google no longer has it');
        expect(row.task.etag, isNull, reason: '$id: nothing to If-Match');
        expect(row.syncState, SyncState.dirty);
        expect(row.pendingOp, 'create');
      }
      expect((await s.listTasks('L1')).map((r) => r.task.id), [
        'P',
        'C',
      ], reason: 'both rows are visible again');
    });

    test('demote leaves a re-deleted tombstone alone', () async {
      // The user undid the delete and then deleted again inside the same
      // in-flight window: the row must NOT come back as a create.
      final s = await tombstonedPair(localUpdated: '2026-01-01T00:00:05Z');
      expect(await s.demoteSubtreeToCreate('P'), 0);
      final row = (await s.findTaskAny('P'))!;
      expect(row.syncState, SyncState.deleted);
      expect(row.pendingOp, 'delete');
      expect(row.remoteId, 'r-P', reason: 'the pending DELETE still needs it');
    });
  });

  group('apply_pushed_task', () {
    test('detaches when the adopted parent is absent', () async {
      // A push/refetch response can name a parent this device no longer holds.
      // Adopting that parent_id blindly would violate the FK; instead the row
      // detaches and drops its etag so a later pull re-links it (RFC-009 §A/P6).
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(dirtyTask('T1', 'L1', 'update'));
      final server = Task(
        id: 'T1',
        parent: 'ghost', // not in the local store at all
        position: '1',
        title: 'task T1',
        status: TaskStatus.needsAction,
        etag: 'e2',
        updated: _t0,
      );
      await s.applyPushedTask(server, _t0);
      final got = (await s.findTaskAny('T1'))!;
      expect(got.task.parent, isNull, reason: 'detached, not pointed at ghost');
      expect(
        got.task.etag,
        isNull,
        reason: 'etag dropped so the pull re-links',
      );
      expect(got.syncState, SyncState.clean, reason: 'the push still landed');
    });

    test('keeps a parent that is present', () async {
      // The guard is confined to the missing-parent case: an existing parent is
      // adopted exactly as before, etag and all.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('P', 'L1', null, '1'));
      await s.upsertTask(dirtyTask('T1', 'L1', 'update', position: '2'));
      final server = Task(
        id: 'T1',
        parent: 'P',
        position: '2',
        title: 'task T1',
        status: TaskStatus.needsAction,
        etag: 'e2',
        updated: _t0,
      );
      await s.applyPushedTask(server, _t0);
      final got = (await s.findTaskAny('T1'))!;
      expect(got.task.parent, 'P', reason: 'real parent adopted');
      expect(got.task.etag, 'e2', reason: 'etag adopted normally');
    });

    test('re-edited row stays dirty and re-bases to the server body', () async {
      // Guard 1 — stale snapshot re-base. The user typed more while the PATCH
      // was in flight, so local_updated no longer equals the drained snapshot.
      // The landing must NOT mark the row clean: it keeps its dirty flag and its
      // own content, and re-bases base_* to the body the server now holds (#124)
      // so a later 412 diffs against reality, not the pre-push base.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'typed more while pushing',
            notes: 'local note',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.dirty,
          localUpdated: '2026-01-01T00:00:09Z', // newer than the drain
          pendingOp: 'update',
        ),
      );
      // The body the earlier push actually stored (pre-re-edit content).
      final server = Task(
        id: 'T1',
        position: '1',
        title: 'buy milk',
        notes: 'server note',
        status: TaskStatus.completed,
        due: '2026-03-01',
        etag: 'e2',
        updated: _t0,
      );
      await s.applyPushedTask(server, _t0); // drained snapshot, now stale

      final got = (await s.findTaskAny('T1'))!;
      expect(got.syncState, SyncState.dirty, reason: 're-edit stays queued');
      expect(got.pendingOp, 'update');
      expect(
        got.task.title,
        'typed more while pushing',
        reason: 'local content preserved, not overwritten by the stale body',
      );
      expect(got.task.notes, 'local note');

      final base = (await s.baseSnapshot('T1'))!;
      expect(
        base.title,
        'buy milk',
        reason: 'base re-based to the server body',
      );
      expect(base.notes, 'server note');
      expect(base.due, '2026-03-01');
      expect(base.status, TaskStatus.completed);
    });

    test('does not resurrect a row deleted mid-push', () async {
      // Guard 2 — delete during push. The push was drained, then the user
      // deleted the task before the response arrived (tombstone bumped
      // local_updated and set deleted/delete). The late landing must leave the
      // tombstone intact — never flip it back to clean — so the delete still
      // pushes and the row cannot reappear (invariant #3).
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      // The tombstoned state as tombstone_subtree would leave it: deleted,
      // pending delete, local_updated bumped PAST the drained snapshot.
      await s.upsertTask(
        dirtyTask(
          'T1',
          'L1',
          'delete',
          localUpdated: '2026-01-01T00:00:05Z',
          state: SyncState.deleted,
        ),
      );
      final server = Task(
        id: 'T1',
        position: '1',
        title: 'task T1',
        status: TaskStatus.needsAction,
        etag: 'e2',
        updated: _t0,
      );
      await s.applyPushedTask(server, _t0); // stale snapshot

      final got = (await s.findTaskAny('T1'))!;
      expect(got.syncState, SyncState.deleted, reason: 'tombstone survives');
      expect(got.pendingOp, 'delete', reason: 'the delete is still queued');
    });

    test('keeps a pending move intact', () async {
      // Guard 3 — move during push. A structural move is queued in
      // pending_moves (the task now sits under A at a new position) but has not
      // been pushed. A content push lands whose response still reflects the
      // pre-move parent/position. Adopting that body would clobber the queued
      // move, so apply_pushed_task refuses to touch parent_id/position while a
      // pending move exists. Content still lands (local_updated matches).
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('A', 'L1', null, '1'));
      await s.upsertTask(taskOf('B', 'L1', null, '2'));
      await s.upsertTask(
        dirtyTask('T1', 'L1', 'update', parent: 'A', position: '9'),
      );
      // Queue the move directly — record_move is a T1.4b path; here we only need
      // a pending_moves row to exist for the guard to fire.
      await s.db.customInsert(
        'INSERT INTO pending_moves (task_id, list_id, parent_id, previous_id) '
        'VALUES (?, ?, ?, ?)',
        variables: [
          Variable<String>('T1'),
          Variable<String>('L1'),
          Variable<String>('A'),
          Variable<String>(null),
        ],
        updates: {s.db.pendingMoves},
      );

      // The push response reflects the parent/position from BEFORE the move.
      final server = Task(
        id: 'T1',
        parent: 'B',
        position: '1',
        title: 'server title',
        status: TaskStatus.needsAction,
        etag: 'e2',
        updated: _t0,
      );
      await s.applyPushedTask(server, _t0);

      final got = (await s.findTaskAny('T1'))!;
      expect(got.task.parent, 'A', reason: 'queued move parent survives');
      expect(got.task.position, '9', reason: 'queued move position survives');
      expect(
        got.task.title,
        'server title',
        reason: 'content still adopted (drain snapshot matched)',
      );
    });
  });

  group('base-snapshot CASE capture/clear (#124/#139)', () {
    test('editing a clean row captures and preserves its base', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      // A clean, synced row has no base.
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'old',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.clean,
          localUpdated: _t0,
        ),
      );
      expect(await s.baseSnapshot('T1'), isNull, reason: 'clean → no base');

      // The first edit captures the pre-edit content as the base.
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'new',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'update',
        ),
      );
      expect(
        (await s.baseSnapshot('T1'))?.title,
        'old',
        reason: 'base is the last-synced content',
      );

      // A second edit preserves the ORIGINAL base — the last agreement with the
      // server, not the last keystroke.
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'newer',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'update',
        ),
      );
      expect(
        (await s.baseSnapshot('T1'))?.title,
        'old',
        reason: 'base survives repeated edits',
      );

      // Landing the push clean (local_updated matches) clears the base.
      final server = Task(
        id: 'T1',
        position: '1',
        title: 'newer',
        status: TaskStatus.needsAction,
        etag: 'e2',
        updated: _t0,
      );
      await s.applyPushedTask(server, _t0);
      expect(
        await s.baseSnapshot('T1'),
        isNull,
        reason: 'clean again → base cleared',
      );
    });

    test('landing a dirty row clean via upsert_task clears its base', () async {
      // #139: the 412 ConflictedCopy resolver overwrites the canonical id with
      // the remote row via upsert_task (a dirty→clean transition). That must
      // clear the base — a clean row carries no base (schema invariant §B), or a
      // future 412 would compare the refetched remote against stale content.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'old',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.clean,
          localUpdated: _t0,
        ),
      );
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'mine',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'update',
        ),
      );
      expect(
        await s.baseSnapshot('T1'),
        isNotNull,
        reason: 'the dirty edit captured a base',
      );

      // The 412 resolver overwrites the id with the canonical remote row, clean.
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'theirs',
            status: TaskStatus.needsAction,
            etag: 'e2',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.clean,
          localUpdated: _t0,
        ),
      );
      expect(
        await s.baseSnapshot('T1'),
        isNull,
        reason: 'landing clean via upsert_task clears the base',
      );
    });
  });

  group('resolve_conflicted_copy atomic pair (kill-window)', () {
    // Stage a clean T1 then a dirty edit over it, so the row carries a base and
    // (unless overridden) a stale etag the 412 resolver would land canonical
    // over. Returns nothing — the store holds the state.
    Future<void> stageConflictedEdit(
      Store s, {
      required String editedTitle,
      required String etag,
    }) async {
      await s.upsertList(listOf('L1'));
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'old',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.clean,
          localUpdated: _t0,
        ),
      );
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: editedTitle,
            status: TaskStatus.needsAction,
            etag: etag,
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'update',
        ),
      );
    }

    Task remoteCanonical(String title, String etag) => Task(
      id: 'T1',
      position: '1',
      title: title,
      status: TaskStatus.needsAction,
      etag: etag,
      updated: _t0,
    );

    StoredTask copyOf(String id, String title, {String? parent}) => StoredTask(
      task: Task(
        id: id,
        parent: parent,
        position: '1',
        title: '$title (conflicted copy)',
        status: TaskStatus.needsAction,
        updated: _t0,
      ),
      listId: 'L1',
      syncState: SyncState.dirty,
      localUpdated: _t0,
      pendingOp: 'create',
    );

    test('lands the canonical row AND the copy together', () async {
      final s = await freshStore();
      await stageConflictedEdit(s, editedTitle: 'mine', etag: 'stale');

      await s.resolveConflictedCopy(
        remoteCanonical('theirs', 'e2'),
        _t0,
        copyOf('copy-1', 'mine'),
      );

      final rows = await s.listTasks('L1');
      expect(rows.length, 2, reason: 'canonical remote + conflicted copy');
      final canonical = rows.firstWhere((r) => r.task.id == 'T1');
      expect(canonical.task.title, 'theirs');
      expect(canonical.task.etag, 'e2');
      expect(canonical.syncState, SyncState.clean);
      expect(
        await s.baseSnapshot('T1'),
        isNull,
        reason: 'a clean canonical landing clears the base',
      );
      final copy = rows.firstWhere((r) => r.task.id == 'copy-1');
      expect(copy.task.title, 'mine (conflicted copy)');
      expect(copy.syncState, SyncState.dirty);
      expect(copy.pendingOp, 'create');
    });

    test(
      'a failed copy insert rolls the canonical landing back — the edit survives',
      () async {
        // The kill-window guarantee: if the process dies (or a write faults)
        // AFTER the canonical row lands but BEFORE the copy is inserted, the two
        // separate writes of the reference would leave the dirty id overwritten
        // by the remote and the local edit gone forever (P3 data loss). Forcing
        // the SECOND write to fail — the copy names a parent that does not exist,
        // an immediate FK violation — proves the pair is one transaction: the
        // canonical landing is rolled back and the row is left exactly as it was,
        // dirty on its stale etag with its base intact, so the NEXT run
        // re-resolves the 412 and preserves the edit.
        final s = await freshStore();
        await stageConflictedEdit(s, editedTitle: 'mine', etag: 'stale');
        expect(await s.baseSnapshot('T1'), isNotNull);

        await expectLater(
          s.resolveConflictedCopy(
            remoteCanonical('theirs', 'e2'),
            _t0,
            copyOf('copy-1', 'mine', parent: 'ghost-parent'),
          ),
          throwsA(anything),
          reason: 'the copy insert violates the parent FK',
        );

        final rows = await s.listTasks('L1');
        expect(rows.length, 1, reason: 'no half-applied copy left behind');
        final t1 = rows.single;
        expect(t1.task.id, 'T1');
        expect(
          t1.task.title,
          'mine',
          reason: 'the canonical landing was rolled back — edit intact',
        );
        expect(t1.task.etag, 'stale', reason: 'stale etag preserved to re-412');
        expect(t1.syncState, SyncState.dirty);
        expect(t1.pendingOp, 'update');
        expect(
          await s.baseSnapshot('T1'),
          isNotNull,
          reason: 'the base survives so the retry diffs the 412 correctly',
        );
      },
    );
  });

  group('finish_cross_list_move atomic window (kill-window)', () {
    // Build a fresh-id clone of [orig] under [targetList], as move_task_to_list
    // recreates it: a brand-new remote row (no etag) queued to push as a create.
    StoredTask cloneOf(String newId, StoredTask orig, String targetList) =>
        StoredTask(
          task: Task(
            id: newId,
            position: orig.task.position,
            title: orig.task.title,
            status: orig.task.status,
            updated: _t0,
          ),
          listId: targetList,
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'create',
        );

    // The original tombstoned in place: kept as a row so its own delete pushes.
    StoredTask tombstoneOf(StoredTask orig) => StoredTask(
      task: orig.task,
      listId: orig.listId,
      syncState: SyncState.deleted,
      localUpdated: _t0,
      pendingOp: 'delete',
    );

    test('lands the clone AND removes the original together', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertList(listOf('L2'));
      final orig = taskOf('T1', 'L1', null, '1'); // synced (etag e1)
      await s.upsertTask(orig);

      await s.finishCrossListMove(
        clones: [cloneOf('clone-1', orig, 'L2')],
        tombstones: [tombstoneOf(orig)],
        hardDeletes: const [],
      );

      expect(
        await s.listTasks('L1'),
        isEmpty,
        reason: 'the original is tombstoned out of its old list',
      );
      final l2 = await s.listTasks('L2');
      expect(
        l2.single.task.id,
        'clone-1',
        reason: 'the clone landed in target',
      );
      expect(l2.single.pendingOp, 'create');
      // The original survives as a tombstone whose own delete still pushes.
      final orphan = (await s.findTaskAny('T1'))!;
      expect(orphan.syncState, SyncState.deleted);
      expect(orphan.pendingOp, 'delete');
    });

    test(
      'a crash during removal rolls the clone back — never both originals and clones live',
      () async {
        // The #182 kill-window guarantee: move_task_to_list clones the subtree,
        // then removes each original, as separate writes — so a crash after the
        // clones land but before the removals leaves BOTH the originals and
        // their clones live, silently duplicating the moved subtree (P8).
        // Forcing the removal write to fault (a subclass models the process
        // dying right after the clone) proves the window is one transaction: the
        // clone is rolled back too, so the store holds the original alone and the
        // next run re-moves it from a clean start.
        final s = _CrashDuringMoveRemovalStore(await AppDatabase.openMemory());
        addTearDown(s.db.close);
        await s.upsertList(listOf('L1'));
        await s.upsertList(listOf('L2'));
        final orig = taskOf('T1', 'L1', null, '1');
        await s.upsertTask(orig);

        await expectLater(
          s.finishCrossListMove(
            clones: [cloneOf('clone-1', orig, 'L2')],
            tombstones: const [],
            hardDeletes: const ['T1'],
          ),
          throwsA(anything),
          reason: 'the removal write faults, standing in for a crash',
        );

        expect(
          (await s.listTasks('L1')).single.task.id,
          'T1',
          reason: 'the original survives — its removal was rolled back',
        );
        expect(
          await s.listTasks('L2'),
          isEmpty,
          reason: 'the clone was rolled back too — never both live',
        );
        expect(
          await s.findTaskAny('clone-1'),
          isNull,
          reason: 'no half-applied clone left behind',
        );
      },
    );
  });

  group('finish_move atomic pair (kill-window)', () {
    // Stage a task carrying a pending move, so finish_move has both an intent to
    // clear and a landed response to adopt. Returns the fresh store.
    Future<Store> stageMovedTask({required SyncState state}) async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: state == SyncState.dirty ? 'my edit' : 'moved',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: state,
          localUpdated: _t0,
          pendingOp: state == SyncState.dirty ? 'update' : null,
        ),
      );
      // The move the command layer queued: T1 reordered to position '9'.
      await s.recordMove('T1', 'L1', null, null);
      return s;
    }

    Task landed(String title, String etag, String position) => Task(
      id: 'T1',
      position: position,
      title: title,
      status: TaskStatus.needsAction,
      etag: etag,
      updated: '2026-01-02T00:00:00Z',
    );

    test(
      'adoptBody: clears the intent AND adopts the whole response body',
      () async {
        final s = await stageMovedTask(state: SyncState.clean);

        // A clean row adopts the body: the server-assigned position lands only
        // because the move intent was cleared first inside the same call — the
        // apply_pushed_task guard skips position while a move is pending.
        await s.finishMove(
          'T1',
          landed('moved', 'e2', '9'),
          adoptBody: true,
          expectedLocalUpdated: _t0,
        );

        expect(
          await s.pendingMoves(),
          isEmpty,
          reason: 'the move intent is cleared',
        );
        final t1 = (await s.listTasks('L1')).single;
        expect(t1.task.etag, 'e2', reason: 'the response etag is adopted');
        expect(
          t1.task.position,
          '9',
          reason: 'the server-assigned position lands — move cleared first',
        );
        expect(t1.syncState, SyncState.clean);
      },
    );

    test('meta-only: refreshes the etag but spares the pending edit', () async {
      final s = await stageMovedTask(state: SyncState.dirty);

      await s.finishMove(
        'T1',
        landed('server title', 'e2', '9'),
        adoptBody: false,
        expectedLocalUpdated: _t0,
      );

      expect(await s.pendingMoves(), isEmpty);
      final t1 = (await s.listTasks('L1')).single;
      expect(t1.task.etag, 'e2', reason: 'meta adopts the fresh etag');
      expect(
        t1.task.title,
        'my edit',
        reason: 'a meta-only landing keeps the unrelated pending content edit',
      );
      expect(
        t1.syncState,
        SyncState.dirty,
        reason: 'the edit still needs push',
      );
    });

    test(
      'a crash after clear_move rolls the whole pair back — the move survives',
      () async {
        // The kill-window guarantee: the reference clears the move and adopts
        // the response as two separate writes, so a crash in the gap leaves the
        // intent gone with the server parent/position/etag never adopted — no
        // move queued to correct the drift. Forcing the SECOND write to fault
        // (a subclass models the process dying right after clear_move) proves
        // the pair is one transaction: the clear is rolled back, so the NEXT run
        // re-pushes the move rather than losing it.
        final s = _CrashAfterClearMoveStore(await AppDatabase.openMemory());
        addTearDown(s.db.close);
        await s.upsertList(listOf('L1'));
        await s.upsertTask(taskOf('T1', 'L1', null, '1'));
        await s.recordMove('T1', 'L1', null, null);

        await expectLater(
          s.finishMove(
            'T1',
            landed('moved', 'e2', '9'),
            adoptBody: false,
            expectedLocalUpdated: _t0,
          ),
          throwsA(anything),
          reason: 'the second write faults, standing in for a crash',
        );

        final moves = await s.pendingMoves();
        expect(
          moves.length,
          1,
          reason: 'the clear_move was rolled back — the intent survives',
        );
        expect(moves.single.taskId, 'T1');
      },
    );
  });
}

/// A store whose [refreshTaskMeta] always faults — stands in for the process
/// dying (or a write erroring) immediately after `clear_move`, exercising the
/// finish_move transaction's rollback.
class _CrashAfterClearMoveStore extends Store {
  _CrashAfterClearMoveStore(super.db);

  @override
  Future<void> refreshTaskMeta(
    String id,
    String? newEtag,
    String serverUpdated,
  ) async {
    throw StateError('simulated crash after clear_move');
  }
}

/// A store whose [deleteTaskHard] always faults — stands in for the process
/// dying (or a write erroring) during a cross-list move's removal phase, right
/// after the clones were upserted, exercising the finish_cross_list_move
/// transaction's rollback.
class _CrashDuringMoveRemovalStore extends Store {
  _CrashDuringMoveRemovalStore(super.db);

  @override
  Future<void> deleteTaskHard(String id) async {
    throw StateError('simulated crash during cross-list move removal');
  }
}
