// The engine's half of the store invariants (#269).
//
// Two states the store now refuses to write, and what the engine does if it
// meets one anyway (a crash between two writes, a future caller):
//
//  * a dirty row that already carries a `remote_id` is PATCHED, never inserted
//    a second time — an insert would put a duplicate on the user's account;
//  * a list the server says is gone, revived as an unpushed create, really
//    forgets the dead remote id instead of pushing into it forever.
//
// Assertions read what the run leaves behind: the rows the store holds, the
// tasks and lists the fake server holds, the insert call count.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/sync_error.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_fixture.dart';

const _t0 = '2026-06-01T00:00:00Z';

Future<(FakeTasksApi, SyncEngine)> engine() async {
  final client = FakeTasksApi();
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return (client, SyncEngine.withPush(client, Store(db), true));
}

StoredTask dirtyTask(
  String id,
  String listId,
  String op, {
  required String title,
}) => StoredTask(
  task: Task(
    id: id,
    position: '1',
    title: title,
    status: TaskStatus.needsAction,
    updated: _t0,
  ),
  listId: listId,
  syncState: op == 'delete' ? SyncState.deleted : SyncState.dirty,
  localUpdated: _t0,
  pendingOp: op,
);

/// `(listId, parentId)` of the row [id] holds, or `null` when it is gone.
Future<(String, String?)?> placement(Store store, String id) async {
  final row = await store.findTaskAny(id);
  return row == null ? null : (row.listId, row.task.parent);
}

/// How many tasks titled [title] the server holds in [listId].
Future<int> serverCount(
  FakeTasksApi client,
  String listId,
  String title,
) async {
  final page = await client.listTasks(listId);
  return page.items.where((t) => t.title == title).length;
}

void main() {
  test('a dirty row that already carries a remote id is patched, never inserted '
      'a second time', () async {
    // The state a `finishCreate` landing between Commands' read and its write
    // used to leave behind. `upsertTask` rewrites the op now, so reach past it
    // to reproduce the shape a crash (or a future caller) could still produce
    // and prove the PUSH converges rather than duplicating.
    final (client, eng) = await engine();
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'r1', 'buy milk', '1');
    await eng.run();

    final localId = await localIdOf(eng.store, 'r1');
    await eng.store.db.customStatement(
      "UPDATE tasks SET sync_state = 'dirty', pending_op = 'create', "
      "title = 'buy oat milk', local_updated = '2026-06-02T00:00:00Z' "
      'WHERE id = ?',
      [localId],
    );

    final insertsBefore = client.callCount(Method.insertTask);
    await eng.run();

    expect(
      client.callCount(Method.insertTask) - insertsBefore,
      0,
      reason: 'a row Google already named is never inserted again',
    );
    final remote = (await client.listTasks('L1')).items;
    expect(remote.length, 1, reason: 'exactly one copy on the server');
    expect(remote.single.id, 'r1');
    expect(
      remote.single.title,
      'buy oat milk',
      reason: 'and the local edit reached it as a patch',
    );
    final row = (await findByAnyId(eng.store, 'r1'))!;
    expect(row.syncState, SyncState.clean);
    await eng.store.checkInvariants();
  });

  test('a list revived after a remote delete forgets the dead remote id and is '
      're-created exactly once', () async {
    // §G3 / D2 with nowhere to re-home to: the account's only list is deleted
    // on another device while it still holds a row the server never saw. The
    // list survives as an unpushed create — and it must NOT keep naming the id
    // Google just dropped.
    final (client, eng) = await engine();
    await seedSyncedList(client, eng.store, 'L2', 'Work');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask('local-1', 'L2', 'create', title: 'buy milk'),
    );
    client.deleteListFromState('L2');

    await eng.run();

    final revived = (await eng.store.allLists()).single;
    expect(revived.list.title, 'Work');
    expect(
      revived.remoteId,
      isNull,
      reason: 'the id Google dropped is not carried into the re-create',
    );
    expect(revived.list.etag, isNull);
    expect(revived.pendingOp, 'create');
    expect(revived.syncState, SyncState.dirty);
    await eng.store.checkInvariants();

    // And it converges: the list is re-created ONCE and the row lands in it.
    await eng.run();
    await eng.run();
    final lists = await client.listTasklists();
    expect(lists.map((l) => l.title).toList(), ['Work']);
    final tasks = (await client.listTasks(lists.single.id)).items;
    expect(tasks.map((t) => t.title).toList(), ['buy milk']);
    final row = (await findByAnyId(eng.store, 'local-1'))!;
    expect(row.syncState, SyncState.clean);
    await eng.store.checkInvariants();
  });

  test(
    'an in-flight create marker whose list was deleted remotely does not wedge '
    'the session',
    () async {
      // The permanent wedge (#269). A create fails transiently, so its in-flight
      // marker is kept — "this insert may already have landed". Before the next
      // run the user deletes that list on the web. Recovery runs FIRST in the
      // push, fetches the marker's list to look for the orphan, and meets a 404
      // it used to rethrow: the run failed at the same line every time, forever,
      // showing "needs attention" with nothing the user could do about it.
      //
      // A list the server does not have holds no orphan, and never will. The
      // marker is dropped and the run carries on to the ghost-list path, which
      // is what re-homes the row.
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
      await seedSyncedList(client, eng.store, 'L2', 'Work');
      await eng.run();

      await eng.store.upsertTask(
        dirtyTask('local-1', 'L2', 'create', title: 'buy milk'),
      );
      client.failNext(Method.insertTask, () => const Network('dropped'));
      await eng.run();
      expect(
        await eng.store.inflightCreates(),
        hasLength(1),
        reason: 'precondition: the marker survives the transient',
      );

      // The list is deleted on another device.
      client.deleteListFromState('L2');

      final out = await eng.run(); // must not throw
      expect(
        await eng.store.inflightCreates(),
        isEmpty,
        reason: 'a list the server does not have can hold no orphan',
      );
      expect((await eng.store.allLists()).map((l) => l.list.title).toList(), [
        'My Tasks',
      ], reason: 'the ghost list is removed in the same run');
      expect(await placement(eng.store, 'local-1'), (
        'L1',
        null,
      ), reason: 'and the row the server never saw re-homed (P2/D2)');
      expect(out.errors, lessThanOrEqualTo(1));

      // It converges, and exactly one copy reaches Google.
      await eng.run();
      expect(await serverCount(client, 'L1', 'buy milk'), 1);
      final settled = await eng.run();
      expect((settled.pushed, settled.errors), (0, 0), reason: 'P7');
      await eng.store.checkInvariants();
    },
  );

  test(
    'a TRANSIENT failure fetching the marker list keeps the marker',
    () async {
      // The other half of the same decision: only a PERMANENT answer proves the
      // list is gone. A flaky network must not drop a marker whose insert may
      // have committed — dropping it re-issues the create and duplicates it.
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      await eng.run();

      await eng.store.upsertTask(
        dirtyTask('local-1', 'L1', 'create', title: 'buy milk'),
      );
      client.failNext(Method.insertTask, () => const Network('dropped'));
      await eng.run();
      expect(await eng.store.inflightCreates(), hasLength(1));

      client.failNext(Method.listTasks, () => const ServerError(503));
      await eng.run();
      expect(
        await eng.store.inflightCreates(),
        hasLength(1),
        reason: 'the marker outlives a transient — the insert may have landed',
      );

      // Once the network is healthy the marker resolves and exactly one copy
      // exists.
      await eng.run();
      await eng.run();
      expect(await serverCount(client, 'L1', 'buy milk'), 1);
      await eng.store.checkInvariants();
    },
  );

  test(
    'a DEAD SESSION fetching the marker list keeps the marker and aborts',
    () async {
      // The auth case, which is neither transient nor "the list is gone": a
      // phone that loses its grant mid-session gets a terminal 401 on every
      // call. Reading that as "the list must have been deleted" would drop
      // EVERY in-flight marker, and each create would be re-issued after the
      // user signs back in — duplicates on their account, from a condition that
      // says nothing about the list at all.
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      await eng.run();

      await eng.store.upsertTask(
        dirtyTask('local-1', 'L1', 'create', title: 'buy milk'),
      );
      client.failNext(Method.insertTask, () => const Network('dropped'));
      await eng.run();
      expect(await eng.store.inflightCreates(), hasLength(1));

      client.failNext(
        Method.listTasks,
        () => const AuthExpired('invalid_grant'),
      );
      await expectLater(eng.run(), throwsA(isA<SyncError>()));
      expect(
        await eng.store.inflightCreates(),
        hasLength(1),
        reason: 'the marker outlives a dead session',
      );

      // Signed back in, the marker resolves and exactly one copy exists.
      await eng.run();
      await eng.run();
      expect(await serverCount(client, 'L1', 'buy milk'), 1);
      await eng.store.checkInvariants();
    },
  );

  test(
    'a list 404ing on rename is revived without the dead remote id',
    () async {
      // The push-side twin: the rename push is what learns the list is gone.
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L2', 'Work');
      await eng.run();

      await eng.store.upsertTask(
        dirtyTask('local-1', 'L2', 'create', title: 'buy milk'),
      );
      // The rename queued locally; the list deleted elsewhere before it pushes.
      await eng.store.upsertList(
        StoredTaskList(
          list: TaskList(id: 'L2', title: 'Errands', updated: _t0),
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'update',
          remoteId: 'L2',
        ),
      );
      client.deleteListFromState('L2');

      await eng.run();

      final revived = (await eng.store.allLists()).single;
      expect(revived.list.title, 'Errands', reason: 'the rename survives');
      expect(revived.remoteId, isNull);
      expect(revived.pendingOp, 'create');
      await eng.store.checkInvariants();
    },
  );
}
