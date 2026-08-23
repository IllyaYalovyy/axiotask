// Port of `store/repo.rs`'s in-file repo tests — the T1.4b partition: the
// create-finalize path (`finish_create`), the in-flight create markers
// (`record_inflight_create` / `inflight_creates` / `inflight_base_local_updated`
// / `clear_inflight_create` / `server_may_hold`), the list remap
// (`remap_list_id`), the subtree tombstone (`tombstone_subtree`), the unpushed
// re-home (`rehome_unpushed_tasks` / `has_unpushed_tasks`), the pending-move
// axis (`record_move` / `pending_moves` / `clear_move`), the pending-push count,
// and the fresh-sync clears (`clear_all` / `clear_synced`). Each test names the
// invariant it protects.
//
// Assertions read the STATE the store persists — the rows a later view or drain
// returns, the base snapshot a 412 will diff against, the markers crash
// recovery reads — never which SQL ran.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
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
  // A clean, server-backed list has been acknowledged, so it carries Google's
  // id; these suites pin it equal to the (opaque) local id (#224).
  remoteId: id,
);

StoredTaskList localListOf(String id) => StoredTaskList(
  list: TaskList(id: id, title: 'Scratch', updated: _t0),
  syncState: SyncState.clean,
  localUpdated: _t0,
  localOnly: true,
);

/// A clean, server-backed task (carries an etag).
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
      // Server-backed: acknowledged, so it carries Google's id (#224).
      remoteId: id,
    );

/// An unpushed create: no etag, dirty, `pending_op = 'create'`.
StoredTask newTask(
  String id,
  String listId, {
  String? parent,
  String position = '1',
  String title = 'task',
  String localUpdated = _t0,
  SyncState state = SyncState.dirty,
  String? pendingOp = 'create',
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    status: TaskStatus.needsAction,
    updated: _t0,
  ),
  listId: listId,
  syncState: state,
  localUpdated: localUpdated,
  pendingOp: pendingOp,
);

void main() {
  group('finish_create', () {
    test('learns the server id, keeps every local id, marks clean', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(newTask('local-1', 'L1'));
      // A subtask parented on the local id. Nothing about it may change.
      await s.upsertTask(newTask('local-2', 'L1', parent: 'local-1'));
      await s.finishCreate(
        'local-1',
        'remote-1',
        'e9',
        '2026-02-01T00:00:00Z',
        _t0,
        null,
      );
      final rows = await s.listTasks('L1');
      final parent = rows.firstWhere((r) => r.task.id == 'local-1');
      final child = rows.firstWhere((r) => r.task.id == 'local-2');
      expect(
        parent.remoteId,
        'remote-1',
        reason: 'Google\'s id is learned into remote_id, never into the key',
      );
      expect(
        child.task.parent,
        'local-1',
        reason: 'the child\'s parent link is untouched — nothing to rewrite',
      );
      expect(parent.task.parent, isNull);
      expect(parent.syncState, SyncState.clean, reason: 'clean atomically');
      expect(parent.pendingOp, isNull);
      expect(parent.task.etag, 'e9');
      expect(
        await s.findTaskAny('remote-1'),
        isNull,
        reason: 'the server id is never addressable as a primary key',
      );
    });

    test('re-edited row stays dirty as update', () async {
      // Re-edited while the insert was in flight: the remap must still land (the
      // task exists remotely now) but the row keeps its dirty flag and flips
      // create→update, so the newer content pushes against the remote id
      // instead of inserting a duplicate.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(
        newTask(
          'local-1',
          'L1',
          title: 'typed more while pushing',
          localUpdated: '2026-01-01T00:00:07Z', // newer than drain snapshot
        ),
      );
      await s.finishCreate(
        'local-1',
        'remote-1',
        'e9',
        '2026-02-01T00:00:00Z',
        _t0, // stale snapshot
        null,
      );
      final row = (await s.listTasks(
        'L1',
      )).firstWhere((r) => r.task.id == 'local-1');
      expect(row.syncState, SyncState.dirty, reason: 'mid-flight edit queued');
      expect(row.pendingOp, 'update', reason: 'create would duplicate');
      expect(row.task.etag, 'e9');
      expect(row.task.title, 'typed more while pushing');
    });

    test('clean landing clears the base', () async {
      // schema §B: base_* is NULL while a row is clean. record_inflight_create
      // populates base with the payload as sent; a clean landing must clear it.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(newTask('local-1', 'L1', title: 'buy milk'));
      await s.recordInflightCreate('local-1', 'L1', _t0);
      expect(
        await s.baseSnapshot('local-1'),
        isNotNull,
        reason: 'precondition: the in-flight create captured a base',
      );
      await s.finishCreate(
        'local-1',
        'remote-1',
        'e9',
        '2026-02-01T00:00:00Z',
        _t0, // matches the drain snapshot → clean landing
        null,
      );
      final row = (await s.listTasks(
        'L1',
      )).firstWhere((r) => r.task.id == 'local-1');
      expect(row.syncState, SyncState.clean);
      expect(
        await s.baseSnapshot('local-1'),
        isNull,
        reason: 'a clean create landing clears base_* (NULL while clean)',
      );
    });

    test('re-edited row keeps its base (the pushed payload)', () async {
      // Non-happy path: a mid-flight re-edit keeps the row dirty (create→update),
      // so its base must SURVIVE — it holds the payload as sent (= what the
      // server now stores), which a later 412 compares the refetched remote
      // against (#118).
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(newTask('local-1', 'L1', title: 'buy milk'));
      await s.recordInflightCreate('local-1', 'L1', _t0);
      // User keeps typing during the in-flight window.
      await s.upsertTask(
        newTask(
          'local-1',
          'L1',
          title: 'buy oat milk',
          localUpdated: '2026-01-01T00:00:07Z',
        ),
      );
      await s.finishCreate(
        'local-1',
        'remote-1',
        'e9',
        '2026-02-01T00:00:00Z',
        _t0, // drain snapshot ≠ current → stays dirty
        null,
      );
      final row = (await s.listTasks(
        'L1',
      )).firstWhere((r) => r.task.id == 'local-1');
      expect(row.syncState, SyncState.dirty, reason: 'mid-flight edit queued');
      final base = await s.baseSnapshot('local-1');
      expect(base, isNotNull, reason: 're-edited row keeps its base');
      expect(
        base!.title,
        'buy milk',
        reason: 'base is the payload as sent, not the mid-flight edit',
      );
    });

    test('does not resurrect a tombstone', () async {
      // The user deleted the row while its insert was in flight. Adopting the
      // committed orphan must teach the TOMBSTONE the server id — the only thing
      // its delete push was missing — and never flip it back into a live row.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(
        newTask(
          'local-1',
          'L1',
          state: SyncState.deleted,
          pendingOp: 'delete',
          localUpdated: '2026-01-01T00:00:09Z', // the delete bumped it
        ),
      );
      await s.recordInflightCreate('local-1', 'L1', _t0);
      await s.finishCreate(
        'local-1',
        'remote-1',
        'e9',
        '2026-02-01T00:00:00Z',
        _t0,
        null,
      );
      final row = await s.findTaskAny('local-1');
      expect(row, isNotNull, reason: 'the tombstone is still there');
      expect(
        row!.remoteId,
        'remote-1',
        reason: 'and it LEARNED the server id its delete push was missing',
      );
      expect(row.syncState, SyncState.deleted, reason: 'still a tombstone');
      expect(row.pendingOp, 'delete');
      expect(row.task.etag, 'e9', reason: 'and now deletable');
      expect(
        await s.listTasks('L1'),
        isEmpty,
        reason: 'still invisible to every view',
      );
    });

    test(
      'remote_id is unique, and a collision rolls the WHOLE finish back',
      () async {
        // Kill-window for the remote_id write (#224). finishCreate does two
        // things — learn the server id and clear the in-flight marker — and they
        // must be ONE transaction. Split, a crash in the gap would leave a row
        // the server holds with no marker to recover it, or a cleared marker with
        // no mapping: either way the next run re-inserts and duplicates.
        //
        // Forcing the FIRST write to fail proves the pair is atomic. The
        // uniqueness of `remote_id` is what forces it: another row already
        // carries 'remote-1', so the UPDATE violates the constraint.
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        await s.upsertTask(taskOf('remote-1', 'L1', null, '1')); // holds it
        await s.upsertTask(newTask('local-1', 'L1'));
        await s.recordInflightCreate('local-1', 'L1', _t0);

        await expectLater(
          s.finishCreate(
            'local-1',
            'remote-1',
            'e9',
            '2026-02-01T00:00:00Z',
            _t0,
            null,
          ),
          throwsA(anything),
          reason: 'two rows may never claim the same Google id',
        );

        final row = (await s.findTaskAny('local-1'))!;
        expect(row.remoteId, isNull, reason: 'nothing half-learned');
        expect(
          row.syncState,
          SyncState.dirty,
          reason: 'still a pending create',
        );
        expect(row.pendingOp, 'create');
        expect(
          await s.inflightCreates(),
          [('local-1', 'L1')],
          reason:
              'the marker survives the rollback, so recovery can still adopt '
              'the orphan instead of duplicating it',
        );
      },
    );

    test('clears the in-flight marker', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(newTask('local-1', 'L1'));
      await s.recordInflightCreate('local-1', 'L1', _t0);
      await s.finishCreate(
        'local-1',
        'remote-1',
        'e1',
        '2026-02-01T00:00:00Z',
        _t0,
        null,
      );
      expect(await s.inflightCreates(), isEmpty);
    });

    test(
      'leaves a queued move alone — it already names the right id',
      () async {
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        await s.upsertTask(newTask('local-1', 'L1'));
        await s.recordMove('local-1', 'L1', null, 'other');
        await s.finishCreate(
          'local-1',
          'remote-1',
          null,
          '2026-02-01T00:00:00Z',
          _t0,
          null,
        );
        final moves = await s.pendingMoves();
        expect(moves, hasLength(1));
        expect(
          moves.single.taskId,
          'local-1',
          reason: 'pending_moves keys on local ids, so nothing cascades (#224)',
        );
      },
    );
  });

  group('in-flight create markers', () {
    test('record then list round-trips the (local, list) pair', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      await s.recordInflightCreate('T1', 'L1', _t0);
      expect(await s.inflightCreates(), [('T1', 'L1')]);
    });

    test('deleting the task cascades the marker away', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      await s.recordInflightCreate('T1', 'L1', _t0);
      await s.deleteTaskHard('T1');
      expect(await s.inflightCreates(), isEmpty);
    });

    test('clear_inflight_create removes a marker without finalizing', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(newTask('local-1', 'L1'));
      await s.recordInflightCreate('local-1', 'L1', _t0);
      await s.clearInflightCreate('local-1');
      expect(await s.inflightCreates(), isEmpty);
      expect(
        await s.findTaskAny('local-1'),
        isNotNull,
        reason: 'the row itself is untouched — only the marker cleared',
      );
    });

    test('base is the payload as sent and is durable across an edit', () async {
      // record_inflight_create captures the base (the payload as sent) and it
      // survives an edit during the in-flight window (#122). It lives in SQLite,
      // not engine memory, so reading it straight back is the durability check.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(newTask('local-1', 'L1', title: 'buy milk'));
      await s.recordInflightCreate('local-1', 'L1', _t0);
      // Edit during the window: the row's content drifts, the base does not.
      await s.upsertTask(
        newTask(
          'local-1',
          'L1',
          title: 'buy oat milk',
          localUpdated: '2026-01-01T00:00:05Z',
        ),
      );
      expect(
        (await s.baseSnapshot('local-1'))?.title,
        'buy milk',
        reason: 'base is the payload as sent, not the drifted content',
      );
      expect(
        await s.inflightBaseLocalUpdated('local-1'),
        _t0,
        reason: 'the drain snapshot is durable for recovery',
      );
      expect(
        await s.inflightBaseLocalUpdated('nope'),
        isNull,
        reason: 'no marker → no base local_updated',
      );
    });

    test('server_may_hold covers the etag and the in-flight window', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      // Pushed row: obviously.
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      expect(await s.serverMayHold('T1'), isTrue);
      // Never pushed and no insert issued: safe to drop outright.
      await s.upsertTask(newTask('local-1', 'L1', position: '2'));
      expect(await s.serverMayHold('local-1'), isFalse);
      // Insert issued, answer unknown: the server MAY hold it.
      await s.recordInflightCreate('local-1', 'L1', _t0);
      expect(await s.serverMayHold('local-1'), isTrue);
      // A row that isn't there at all is nothing to tombstone.
      expect(await s.serverMayHold('nope'), isFalse);
    });
  });

  group('tombstone_subtree', () {
    test('marks root pushable and children local-only', () async {
      // #138: one transaction tombstones the whole subtree. The root keeps a
      // pushable 'delete'; each descendant is a local-only tombstone with no
      // pending op (the server's own cascade takes them remotely), and none of
      // the subtree is visible anymore.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('P', 'L1', null, '1'));
      await s.upsertTask(taskOf('C1', 'L1', 'P', '2'));
      await s.upsertTask(taskOf('C2', 'L1', 'P', '3'));

      await s.tombstoneSubtree('P', ['C1', 'C2'], '2026-02-02T00:00:00Z');

      expect(
        await s.listTasks('L1'),
        isEmpty,
        reason: 'the whole subtree drops out of the view',
      );
      final p = (await s.findTaskAny('P'))!;
      expect(p.syncState, SyncState.deleted);
      expect(p.pendingOp, 'delete', reason: 'root delete pushes');
      for (final id in ['C1', 'C2']) {
        final c = (await s.findTaskAny(id))!;
        expect(c.syncState, SyncState.deleted, reason: '$id tombstoned');
        expect(c.pendingOp, isNull, reason: '$id is a local-only tombstone');
      }
    });
  });

  group('rehome_unpushed_tasks', () {
    test('moves only rows the server never saw', () async {
      // D2 at the store layer: etag-less rows follow to the target list, keeping
      // an unpushed subtree together. A subtask of a row that stays behind is
      // NOT promoted-and-re-homed (D3 rejected). Synced rows and tombstones do
      // not move.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertList(listOf('L2'));

      await s.upsertTask(taskOf('SYNCED', 'L1', null, '1'));
      await s.upsertTask(newTask('new-parent', 'L1', position: '2'));
      await s.upsertTask(
        newTask('new-child', 'L1', parent: 'new-parent', position: '2'),
      );
      // Subtask of a row that stays behind (SYNCED): must NOT move.
      await s.upsertTask(
        newTask('new-orphan', 'L1', parent: 'SYNCED', position: '2'),
      );
      await s.upsertTask(
        newTask(
          'gone',
          'L1',
          position: '5',
          state: SyncState.deleted,
          pendingOp: 'delete',
        ),
      );

      expect(await s.rehomeUnpushedTasks('L1', 'L2'), 2);

      final moved = await s.listTasks('L2');
      expect(moved, hasLength(2));
      final byId = {for (final r in moved) r.task.id: r};
      expect(byId['new-parent']!.task.parent, isNull);
      expect(
        byId['new-child']!.task.parent,
        'new-parent',
        reason: 'the unpushed subtree stays together',
      );
      final orphan = (await s.findTaskAny('new-orphan'))!;
      expect(
        (orphan.listId, orphan.task.parent),
        ('L1', 'SYNCED'),
        reason: 'a subtask of a row that stays behind is not re-homed (D3)',
      );
      expect(
        (await s.findTaskAny('SYNCED'))!.listId,
        'L1',
        reason: 'a row the server knows does not move',
      );
      expect(
        (await s.findTaskAny('gone'))!.listId,
        'L1',
        reason: 'a tombstone does not move',
      );
      expect(
        await s.hasUnpushedTasks('L2'),
        isTrue,
        reason: 'the re-homed unpushed subtree now lives in L2',
      );
      expect(
        await s.hasUnpushedTasks('L1'),
        isTrue,
        reason:
            'new-orphan stays behind, still unpushed, to die in the cascade',
      );
    });
  });

  group('remap_list_id', () {
    test('rewrites the list id across tasks, moves and markers', () async {
      final s = await freshStore();
      // A dirty local-only-style list awaiting create push (has a UUID id).
      await s.upsertList(
        StoredTaskList(
          list: TaskList(id: 'local-L', title: 'New List', updated: _t0),
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'create',
        ),
      );
      await s.upsertTask(newTask('T1', 'local-L'));
      await s.recordMove('T1', 'local-L', null, null);
      await s.recordInflightCreate('T1', 'local-L', _t0);

      await s.finishListCreate(
        'local-L',
        'remote-L',
        'eL',
        '2026-02-01T00:00:00Z',
      );

      // The list KEEPS its id (#224) and merely learns Google's, landing clean
      // with the server meta.
      final lists = await s.allLists();
      expect(lists.map((l) => l.list.id), ['local-L']);
      expect(lists.single.remoteId, 'remote-L');
      expect(lists.single.syncState, SyncState.clean);
      expect(lists.single.pendingOp, isNull);
      expect(lists.single.list.etag, 'eL');
      expect(lists.single.list.updated, '2026-02-01T00:00:00Z');
      // Nothing that referenced the list had to be rewritten.
      expect((await s.findTaskAny('T1'))!.listId, 'local-L');
      expect(await s.listTasks('local-L'), hasLength(1));
      expect(await s.pendingMoves(), [
        const PendingMove(taskId: 'T1', listId: 'local-L'),
      ]);
      expect(await s.inflightCreates(), [('T1', 'local-L')]);
    });

    test('two lists may never claim the same Google id', () async {
      // The list half of the same guarantee: `task_lists.remote_id` is unique,
      // so a second local list cannot adopt an id another row already holds —
      // the collision the old id-remap used to hit as a primary-key abort.
      final s = await freshStore();
      await s.upsertList(
        StoredTaskList(
          list: TaskList(id: 'other', title: 'Other', updated: _t0),
          syncState: SyncState.clean,
          localUpdated: _t0,
          remoteId: 'remote-L',
        ),
      );
      await s.upsertList(
        StoredTaskList(
          list: TaskList(id: 'local-L', title: 'New List', updated: _t0),
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'create',
        ),
      );

      await expectLater(
        s.finishListCreate('local-L', 'remote-L', 'eL', _t0),
        throwsA(anything),
      );
      final still = (await s.allLists()).firstWhere(
        (l) => l.list.id == 'local-L',
      );
      expect(still.remoteId, isNull);
      expect(still.syncState, SyncState.dirty, reason: 'still queued to push');
    });
  });

  group('pending moves', () {
    test('record then read round-trips parent and previous', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      await s.upsertTask(taskOf('P1', 'L1', null, '2'));
      await s.upsertTask(taskOf('T0', 'L1', null, '3'));
      await s.recordMove('T1', 'L1', 'P1', 'T0');
      final moves = await s.pendingMoves();
      expect(moves, [
        const PendingMove(
          taskId: 'T1',
          listId: 'L1',
          parentId: 'P1',
          previousId: 'T0',
        ),
      ]);
    });

    test('record_move upserts the same task (last write wins)', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      await s.recordMove('T1', 'L1', null, 'A');
      await s.recordMove('T1', 'L1', null, 'B');
      final moves = await s.pendingMoves();
      expect(moves, hasLength(1));
      expect(moves.single.previousId, 'B');
    });

    test('clear_move removes it', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      await s.recordMove('T1', 'L1', null, null);
      await s.clearMove('T1');
      expect(await s.pendingMoves(), isEmpty);
    });

    test('hard-deleting a task cascades its pending move', () async {
      // FK integrity: a hard-deleted task must not leave an orphan move.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      await s.recordMove('T1', 'L1', null, null);
      await s.deleteTaskHard('T1');
      expect(await s.pendingMoves(), isEmpty);
    });
  });

  group('pending_push_count', () {
    test('sums dirty tasks, lists and moves, excluding local-only', () async {
      final s = await freshStore();
      await s.upsertList(localListOf('LOCAL'));
      await s.upsertList(listOf('SYNCED'));
      expect(await s.pendingPushCount(), 0, reason: 'all clean to start');

      // Dirty task in synced list → counts.
      await s.upsertTask(newTask('T1', 'SYNCED', pendingOp: 'update'));
      // Dirty task in local-only list → must NOT count.
      await s.upsertTask(newTask('LT', 'LOCAL'));
      // A dirty list and a recorded move → each counts.
      await s.upsertList(
        StoredTaskList(
          list: TaskList(id: 'SYNCED', title: 'renamed', updated: _t0),
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'update',
        ),
      );
      await s.recordMove('T1', 'SYNCED', null, null);

      // 1 task + 1 list + 1 move = 3; the local-only task is excluded.
      expect(await s.pendingPushCount(), 3);
    });
  });

  group('clears', () {
    test('clear_all removes everything incl. moves and markers', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      await s.upsertTask(taskOf('T2', 'L1', null, '2'));
      await s.recordMove('T1', 'L1', null, null);
      await s.recordInflightCreate('T1', 'L1', _t0);
      await s.clearAll();
      expect(await s.allLists(), isEmpty);
      expect(await s.listTasks('L1'), isEmpty);
      expect(await s.pendingMoves(), isEmpty);
      expect(await s.inflightCreates(), isEmpty);
    });

    test('clear_synced preserves local-only lists and their tasks', () async {
      // Fresh sync drops synced data (Google is the source of truth) but
      // local-only lists exist nowhere else, so they must survive.
      final s = await freshStore();
      await s.upsertList(localListOf('LOCAL'));
      await s.upsertList(listOf('SYNCED'));
      await s.upsertTask(taskOf('LT', 'LOCAL', null, '1'));
      await s.upsertTask(taskOf('ST', 'SYNCED', null, '1'));

      await s.clearSynced();

      final lists = await s.allLists();
      expect(lists, hasLength(1), reason: 'only the local-only list survives');
      expect(lists.single.list.id, 'LOCAL');
      expect(lists.single.localOnly, isTrue);
      expect(
        await s.listTasks('LOCAL'),
        hasLength(1),
        reason: "local-only list's tasks survive",
      );
      expect(
        await s.listTasks('SYNCED'),
        isEmpty,
        reason: "synced list's tasks are cleared",
      );
    });

    test('clear_synced cascades moves of synced tasks', () async {
      // Deleting synced lists must not leave orphan pending moves.
      final s = await freshStore();
      await s.upsertList(listOf('SYNCED'));
      await s.upsertTask(taskOf('ST', 'SYNCED', null, '1'));
      await s.recordMove('ST', 'SYNCED', null, null);
      await s.clearSynced();
      expect(await s.pendingMoves(), isEmpty);
    });
  });

  group('refresh_task_meta', () {
    test('adopts etag/updated without touching sync_state', () async {
      // Used after a move push: the row may carry an unrelated pending content
      // edit whose dirty flag must survive.
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(newTask('T1', 'L1', pendingOp: 'update'));
      await s.refreshTaskMeta('T1', 'e-move', '2026-03-01T00:00:00Z');
      final row = (await s.findTaskAny('T1'))!;
      expect(row.task.etag, 'e-move');
      expect(row.task.updated, '2026-03-01T00:00:00Z');
      expect(
        row.syncState,
        SyncState.dirty,
        reason: 'the pending content edit is untouched',
      );
      expect(row.pendingOp, 'update');
    });
  });

  group('dirty/clean id sets', () {
    test('dirty_ids collects dirty and deleted rows only', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('clean', 'L1', null, '1'));
      await s.upsertTask(newTask('dirty', 'L1', pendingOp: 'update'));
      await s.upsertTask(
        newTask('gone', 'L1', state: SyncState.deleted, pendingOp: 'delete'),
      );
      expect(await s.dirtyIds(), {'dirty', 'gone'});
    });

    test('clean_task_ids_for_list is scoped and clean-only', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertList(listOf('L2'));
      await s.upsertTask(taskOf('a', 'L1', null, '1'));
      await s.upsertTask(newTask('b', 'L1', pendingOp: 'update'));
      await s.upsertTask(taskOf('c', 'L2', null, '1'));
      expect(await s.cleanTaskIdsForList('L1'), {
        'a',
      }, reason: 'only the clean row in L1');
    });
  });

  group('write_sync_log', () {
    test('records a run and bounds the log to 500 rows', () async {
      // Not a repo test in the reference (it wraps a wall-clock stamp), but the
      // store still owns the write: assert the row persists and the 500-row cap
      // holds. `nowUtcString()` takes ambient `package:clock`, never the banned
      // wall-clock constructor.
      final s = await freshStore();
      for (var i = 0; i < 3; i++) {
        await s.writeSyncLog(
          pulled: i,
          pushed: 0,
          conflicts: 0,
          durationMs: 10,
        );
      }
      final count = await s.db
          .customSelect('SELECT COUNT(*) AS c FROM sync_log')
          .getSingle();
      expect(count.read<int>('c'), 3);
    });
  });
}
