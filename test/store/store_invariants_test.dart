// The store's structural invariants, codified (#269).
//
// Two things are tested here. First, the ONE invariant the store now enforces
// in SQL rather than by convention: a row Google already knows (`remote_id`
// set) can never be queued as a `create` again. `Commands` writes whole rows
// built from a snapshot read a round-trip earlier, so a `finishCreate` that
// lands in between would otherwise write `remote_id` + `pending_op='create'` —
// and the push would INSERT the task a second time.
//
// Second, [Store.checkInvariants]: the assertion the property and dual-device
// suites run after every sync, so a violation is caught in the run that CAUSED
// it instead of surfacing runs later as a duplicate or an orphan.
//
// Assertions read the state the store persists (what `findTaskAny` /
// `listTasks` answer, what `checkInvariants` reports), never which SQL ran.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

const _t0 = '2026-01-01T00:00:00Z';
const _t1 = '2026-01-01T00:00:01Z';

Future<Store> freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return Store(db);
}

StoredTaskList listOf(String id, {String? remoteId, String? pendingOp}) =>
    StoredTaskList(
      list: TaskList(id: id, title: 'Inbox', updated: _t0),
      syncState: pendingOp == null ? SyncState.clean : SyncState.dirty,
      localUpdated: _t0,
      pendingOp: pendingOp,
      remoteId: remoteId,
    );

StoredTask taskOf(
  String id,
  String listId, {
  String? parent,
  String? remoteId,
  String? pendingOp,
  SyncState syncState = SyncState.clean,
  String title = 'Buy milk',
  String position = '0001',
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    status: TaskStatus.needsAction,
    etag: remoteId == null ? null : 'e1',
    updated: _t0,
  ),
  listId: listId,
  syncState: syncState,
  localUpdated: _t0,
  pendingOp: pendingOp,
  remoteId: remoteId,
);

void main() {
  group('upsertTask keeps an acknowledged row off the create queue', () {
    test(
      'a create written over a row that already carries a remote id reads back '
      'as an update, keeping the remote id',
      () async {
        final store = await freshStore();
        await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
        // The row as it is AFTER the create push landed: Google minted an id.
        await store.upsertTask(taskOf('t1', 'l1', remoteId: 'remote-t1'));

        // The stale-snapshot write: Commands read the row BEFORE finishCreate
        // and writes it back with the pending op it saw then.
        await store.upsertTask(
          taskOf(
            't1',
            'l1',
            pendingOp: 'create',
            syncState: SyncState.dirty,
            title: 'Buy oat milk',
          ),
        );

        final row = await store.findTaskAny('t1');
        expect(row!.remoteId, 'remote-t1', reason: 'the remote id survives');
        expect(row.task.title, 'Buy oat milk', reason: 'the edit survives');
        expect(
          row.pendingOp,
          'update',
          reason:
              'a row Google already holds is PATCHED, never inserted a second '
              'time',
        );
        expect(row.syncState, SyncState.dirty);
      },
    );

    test(
      'a create over a row the server has never seen stays a create',
      () async {
        final store = await freshStore();
        await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
        await store.upsertTask(
          taskOf('t1', 'l1', pendingOp: 'create', syncState: SyncState.dirty),
        );
        await store.upsertTask(
          taskOf(
            't1',
            'l1',
            pendingOp: 'create',
            syncState: SyncState.dirty,
            title: 'Buy oat milk',
          ),
        );

        final row = await store.findTaskAny('t1');
        expect(row!.pendingOp, 'create');
        expect(row.remoteId, isNull);
      },
    );
  });

  group('upsertList keeps an acknowledged list off the create queue', () {
    test('a create written over a list Google acknowledged reads back as an '
        'update', () async {
      final store = await freshStore();
      await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
      // renameList carrying the pending op forward from a stale snapshot.
      await store.upsertList(
        StoredTaskList(
          list: TaskList(id: 'l1', title: 'Groceries', updated: _t1),
          syncState: SyncState.dirty,
          localUpdated: _t1,
          pendingOp: 'create',
        ),
      );

      final l = (await store.allLists()).single;
      expect(l.remoteId, 'remote-l1');
      expect(l.list.title, 'Groceries', reason: 'the rename survives');
      expect(l.pendingOp, 'update');
    });
  });

  group('resetListToUnpushedCreate', () {
    test('really forgets the remote id and etag', () async {
      final store = await freshStore();
      await store.upsertList(
        StoredTaskList(
          list: TaskList(id: 'l1', title: 'Inbox', etag: 'e1', updated: _t0),
          syncState: SyncState.clean,
          localUpdated: _t0,
          remoteId: 'remote-l1',
        ),
      );

      await store.resetListToUnpushedCreate((await store.allLists()).single);

      final l = (await store.allLists()).single;
      expect(
        l.remoteId,
        isNull,
        reason: 'a list the server no longer has is not named on the wire',
      );
      expect(l.list.etag, isNull);
      expect(l.pendingOp, 'create');
      expect(l.syncState, SyncState.dirty);
      expect(
        l.list.title,
        'Inbox',
        reason: 'the rows it holds keep their home',
      );
      await store.checkInvariants();
    });
  });

  group('checkInvariants', () {
    test('a healthy store passes', () async {
      final store = await freshStore();
      await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
      await store.upsertTask(taskOf('t1', 'l1', remoteId: 'remote-t1'));
      await store.upsertTask(
        taskOf('t2', 'l1', parent: 't1', remoteId: 'remote-t2'),
      );
      await store.checkInvariants();
    });

    test('an acknowledged LIST queued as a create is reported', () async {
      final store = await freshStore();
      await store.upsertList(
        listOf('l1', remoteId: 'remote-l1', pendingOp: 'create'),
      );
      expect(
        store.checkInvariants(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('remote_id'), contains('create'), contains('l1')),
          ),
        ),
      );
    });

    test('a clean row holding a base snapshot is reported', () async {
      final store = await freshStore();
      await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
      await store.upsertTask(taskOf('t1', 'l1', remoteId: 'remote-t1'));
      // A base written behind the store's back — what a future edit path that
      // forgot to clear the base on the way clean would leave.
      await store.db.customStatement(
        "UPDATE tasks SET base_title = 'old' WHERE id = 't1'",
      );
      expect(
        store.checkInvariants(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('base'), contains('t1')),
          ),
        ),
      );
    });

    test('a third level of nesting is reported', () async {
      final store = await freshStore();
      await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
      await store.upsertTask(taskOf('t1', 'l1', remoteId: 'remote-t1'));
      await store.upsertTask(
        taskOf('t2', 'l1', parent: 't1', remoteId: 'remote-t2'),
      );
      await store.upsertTask(
        taskOf('t3', 'l1', parent: 't2', remoteId: 'remote-t3'),
      );
      expect(
        store.checkInvariants(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('t3'), contains('level')),
          ),
        ),
      );
    });

    test(
      'a subtask parked in a different list from its parent is reported',
      () async {
        final store = await freshStore();
        await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
        await store.upsertList(listOf('l2', remoteId: 'remote-l2'));
        await store.upsertTask(taskOf('t1', 'l1', remoteId: 'remote-t1'));
        await store.upsertTask(
          taskOf('t2', 'l2', parent: 't1', remoteId: 'remote-t2'),
        );
        expect(
          store.checkInvariants(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('t2'), contains('list')),
            ),
          ),
        );
      },
    );

    test('unlearning a task remote id between checks is reported', () async {
      final store = await freshStore();
      await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
      await store.upsertTask(taskOf('t1', 'l1', remoteId: 'remote-t1'));
      await store.checkInvariants();

      await store.db.customStatement(
        "UPDATE tasks SET remote_id = NULL WHERE id = 't1'",
      );
      expect(
        store.checkInvariants(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('t1'), contains('remote-t1')),
          ),
        ),
      );
    });

    test('re-pointing a task at a different remote id is reported', () async {
      final store = await freshStore();
      await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
      await store.upsertTask(taskOf('t1', 'l1', remoteId: 'remote-t1'));
      await store.checkInvariants();

      await store.db.customStatement(
        "UPDATE tasks SET remote_id = 'remote-other' WHERE id = 't1'",
      );
      expect(
        store.checkInvariants(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('t1'), contains('remote-other')),
          ),
        ),
      );
    });

    test('a tombstone still reports its violations', () async {
      final store = await freshStore();
      await store.upsertList(listOf('l1', remoteId: 'remote-l1'));
      await store.upsertTask(
        taskOf(
          't1',
          'l1',
          remoteId: 'remote-t1',
          pendingOp: 'create',
          syncState: SyncState.deleted,
        ),
      );
      // upsertTask rewrote the op, so reach past it to build the state a
      // pre-fix write left behind.
      await store.db.customStatement(
        "UPDATE tasks SET pending_op = 'create' WHERE id = 't1'",
      );
      expect(
        store.checkInvariants(),
        throwsA(
          isA<StateError>().having((e) => e.message, 'm', contains('t1')),
        ),
      );
    });
  });
}
