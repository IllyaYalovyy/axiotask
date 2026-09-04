// The SyncOutcome counters (#278). Every field of `SyncOutcome` is what the
// Sync activity screen (#218) reports and what the footer's "something changed"
// check-mark (#255) is derived from, so a counter that under- or over-reports
// is a user-visible lie about what the sync just did.
//
// The rest of the sync suites assert a counter as a by-product of the behaviour
// they are really about, and almost always with ONE event in the run — which
// makes `+= 1` and `= 1` indistinguishable, and a dropped increment invisible
// on any path no test happens to count. These tests exist for the counters
// themselves: each drives ONE increment site, TWICE, in ONE run, and asserts
// the exact total alongside the end state on both sides. Two is the smallest
// number that tells "counted every event" apart from "noticed that something
// happened", and one path per test is what makes a missing increment point at
// the code that lost it.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_fixture.dart';

const _t0 = '2026-01-01T00:00:00Z';
const _t1 = '2026-01-02T00:00:00Z';

/// A fresh engine over an in-memory store and fake API, torn down with the test.
Future<(FakeTasksApi, SyncEngine)> engine({bool push = true}) async {
  final client = FakeTasksApi();
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  final store = Store(db);
  final eng = push
      ? SyncEngine.withPush(client, store, true)
      : SyncEngine(client, store);
  return (client, eng);
}

/// A local list the server has never seen: a pending `create` (no remote id).
StoredTaskList localList(String id, String title, {String op = 'create'}) =>
    StoredTaskList(
      list: TaskList(id: id, title: title, updated: _t0),
      syncState: op == 'delete' ? SyncState.deleted : SyncState.dirty,
      localUpdated: _t0,
      pendingOp: op,
    );

/// A dirty local task row for [op], with no remote id of its own.
StoredTask dirtyTask(String id, String listId, String op, {String? parent}) =>
    StoredTask(
      task: Task(
        id: id,
        parent: parent,
        position: id,
        title: 'task $id',
        status: TaskStatus.needsAction,
        updated: _t0,
      ),
      listId: listId,
      syncState: op == 'delete' ? SyncState.deleted : SyncState.dirty,
      localUpdated: _t0,
      pendingOp: op,
    );

/// Re-stage the list the server calls [id] as a local [op] (rename or delete),
/// keeping the `remote_id` that is the only thing the push can name it by.
Future<void> stageList(
  Store store,
  String id,
  String op, {
  String? title,
}) async {
  final l = (await store.allLists()).firstWhere(
    (l) => l.remoteId == id || l.list.id == id,
  );
  await store.upsertList(
    StoredTaskList(
      list: TaskList(
        id: l.list.id,
        title: title ?? l.list.title,
        etag: l.list.etag,
        updated: l.list.updated,
      ),
      syncState: op == 'delete' ? SyncState.deleted : SyncState.dirty,
      localUpdated: l.localUpdated,
      pendingOp: op,
      remoteId: l.remoteId,
    ),
  );
}

/// Stage a pending local edit on the row the server calls [id].
Future<void> stageEdit(Store store, String id, String title) async {
  final r = (await findByAnyId(store, id))!;
  await store.upsertTask(
    StoredTask(
      task: r.task.copyWith(title: title),
      listId: r.listId,
      syncState: SyncState.dirty,
      localUpdated: _t1,
      pendingOp: 'update',
      remoteId: r.remoteId,
    ),
  );
}

/// Tombstone the row the server calls [id] the way a local delete does.
Future<void> stageDelete(Store store, String id) async {
  final r = (await findByAnyId(store, id))!;
  await store.upsertTask(
    StoredTask(
      task: r.task,
      listId: r.listId,
      syncState: SyncState.deleted,
      localUpdated: r.localUpdated,
      pendingOp: 'delete',
      remoteId: r.remoteId,
    ),
  );
}

/// Titles the fake server holds in [listId], undeleted rows only.
Future<List<String>> serverTitles(FakeTasksApi client, String listId) async {
  final page = await client.listTasks(listId);
  return [for (final t in page.items) t.title]..sort();
}

/// Local titles in [listId] (any nesting), sorted.
Future<List<String>> localTitles(Store store, String listId) async =>
    [for (final r in await store.listTasks(listId)) r.task.title]..sort();

void main() {
  // ─── pushed ────────────────────────────────────────────────────────────────

  group('pushed counts every event on its path', () {
    test('two list creates', () async {
      final (client, eng) = await engine();
      await eng.store.upsertList(localList('a', 'Work'));
      await eng.store.upsertList(localList('b', 'Home'));

      final out = await eng.run();

      expect(out.pushed, 2, reason: 'both list creates reached the server');
      expect([for (final l in await client.listTasklists()) l.title]..sort(), [
        'Home',
        'Work',
      ]);
    });

    test('two list renames', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Work');
      await seedSyncedList(client, eng.store, 'L2', 'Home');
      await eng.run();
      await stageList(eng.store, 'L1', 'update', title: 'Work v2');
      await stageList(eng.store, 'L2', 'update', title: 'Home v2');

      final out = await eng.run();

      expect(out.pushed, 2, reason: 'both renames reached the server');
      expect([for (final l in await client.listTasklists()) l.title]..sort(), [
        'Home v2',
        'Work v2',
      ]);
    });

    test('two task creates', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      await eng.run();
      await eng.store.upsertTask(dirtyTask('a', 'L1', 'create'));
      await eng.store.upsertTask(dirtyTask('b', 'L1', 'create'));

      final out = await eng.run();

      expect(out.pushed, 2, reason: 'both creates reached the server');
      expect(await serverTitles(client, 'L1'), ['task a', 'task b']);
    });

    test('two task updates', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'first', '00000000000001');
      client.seedTask('L1', 'T2', 'second', '00000000000002');
      await eng.run();
      await stageEdit(eng.store, 'T1', 'first edited');
      await stageEdit(eng.store, 'T2', 'second edited');

      final out = await eng.run();

      expect(out.pushed, 2, reason: 'both edits reached the server');
      expect(await serverTitles(client, 'L1'), [
        'first edited',
        'second edited',
      ]);
    });

    test('two moves', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'first', '00000000000001');
      client.seedTask('L1', 'T2', 'second', '00000000000002');
      client.seedTask('L1', 'A', 'anchor', '00000000000003');
      await eng.run();
      await recordServerMove(eng.store, 'T1', 'L1', 'A', null);
      await recordServerMove(eng.store, 'T2', 'L1', 'A', null);

      final out = await eng.run();

      expect(out.pushed, 2, reason: 'both moves reached the server');
      expect(client.callCount(Method.moveTask), 2);
      expect(
        (await client.getTask('L1', 'T1')).parent,
        'A',
        reason: 'the first demote landed',
      );
      expect(
        (await client.getTask('L1', 'T2')).parent,
        'A',
        reason: 'and so did the second',
      );
    });
  });

  // ─── pulled ────────────────────────────────────────────────────────────────

  test('pulled counts every row the pull lands', () async {
    final (client, eng) = await engine();
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'first', '00000000000001');
    client.seedTask('L1', 'T2', 'second', '00000000000002');

    final out = await eng.run();

    expect(out.pulled, 2, reason: 'both remote rows landed locally');
    expect(await localTitles(eng.store, 'L1'), ['first', 'second']);
  });

  // ─── deleted ───────────────────────────────────────────────────────────────

  group('deleted counts every event on its path', () {
    test('two lists the server never saw', () async {
      final (client, eng) = await engine();
      await eng.store.upsertList(localList('a', 'Work', op: 'delete'));
      await eng.store.upsertList(localList('b', 'Home', op: 'delete'));

      final out = await eng.run();

      expect(out.deleted, 2, reason: 'both local-only lists are gone');
      expect(await eng.store.allLists(), isEmpty);
      expect(client.callCount(Method.deleteTasklist), 0);
    });

    test('two list deletes the server confirms', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Work');
      await seedSyncedList(client, eng.store, 'L2', 'Home');
      await eng.run();
      await stageList(eng.store, 'L1', 'delete');
      await stageList(eng.store, 'L2', 'delete');

      final out = await eng.run();

      expect(out.deleted, 2, reason: 'both lists are gone on both sides');
      expect(await eng.store.allLists(), isEmpty);
      expect(await client.listTasklists(), isEmpty);
    });

    test('two tombstones the server never saw', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      await eng.run();
      await eng.store.upsertTask(dirtyTask('a', 'L1', 'delete'));
      await eng.store.upsertTask(dirtyTask('b', 'L1', 'delete'));

      final out = await eng.run();

      expect(out.deleted, 2, reason: 'both un-pushed tombstones are gone');
      expect(await eng.store.listTasks('L1'), isEmpty);
      expect(client.callCount(Method.deleteTask), 0);
    });

    test('two task deletes the server confirms', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'first', '00000000000001');
      client.seedTask('L1', 'T2', 'second', '00000000000002');
      await eng.run();
      await stageDelete(eng.store, 'T1');
      await stageDelete(eng.store, 'T2');

      final out = await eng.run();

      expect(out.deleted, 2, reason: 'both deletes were confirmed');
      expect(await eng.store.listTasks('L1'), isEmpty);
      expect(await serverTitles(client, 'L1'), isEmpty);
    });

    test('two ghost rows the server no longer has', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'first', '00000000000001');
      client.seedTask('L1', 'T2', 'second', '00000000000002');
      client.seedTask('L1', 'T3', 'survivor', '00000000000003');
      await eng.run();
      // Another device deleted them: they are simply absent from the next pull.
      client.deleteTaskFromState('L1', 'T1');
      client.deleteTaskFromState('L1', 'T2');

      final out = await eng.run();

      expect(out.deleted, 2, reason: 'both ghosts were removed');
      expect(await localTitles(eng.store, 'L1'), ['survivor']);
    });

    test('two ghost lists the server no longer has', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Work');
      await seedSyncedList(client, eng.store, 'L2', 'Home');
      await seedSyncedList(client, eng.store, 'L3', 'Inbox');
      await eng.run();
      client.deleteListFromState('L1');
      client.deleteListFromState('L2');

      final out = await eng.run();

      expect(out.deleted, 2, reason: 'both ghost lists were removed');
      expect(
        [for (final l in await eng.store.allLists()) l.list.title],
        ['Inbox'],
      );
    });
  });

  // ─── conflicts ─────────────────────────────────────────────────────────────

  group('conflicts counts every event on its path', () {
    test('two 412 conflicts each keep the local edit as a copy', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'first', '00000000000001');
      client.seedTask('L1', 'T2', 'second', '00000000000002');
      await eng.run();
      await stageEdit(eng.store, 'T1', 'first mine');
      await stageEdit(eng.store, 'T2', 'second mine');
      // Another device edits both rows: our etags are now stale.
      await client.patchTask('L1', 'T1', const TaskPatch(title: 'first ours'));
      await client.patchTask('L1', 'T2', const TaskPatch(title: 'second ours'));

      final out = await eng.run();

      expect(out.conflicts, 2, reason: 'both 412s were resolved');
      final titles = await localTitles(eng.store, 'L1');
      expect(
        titles.where((t) => t.contains('(conflicted copy)')).length,
        2,
        reason: 'neither local edit was thrown away',
      );
      expect(
        titles.where((t) => t.startsWith('first ours')).length,
        1,
        reason: 'remote is canonical for the first row (P3)',
      );
      expect(
        titles.where((t) => t.startsWith('second ours')).length,
        1,
        reason: 'and for the second',
      );
    });

    test('two third levels flattened by a read-only sync', () async {
      final (client, eng) = await engine(push: false);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'P', 'parent', '00000000000001');
      client.seedTaskWithParent('L1', 'T', 'subtask', '00000000000002', 'P');
      client.seedTaskWithParent('L1', 'C1', 'grandchild 1', '01', 'T');
      client.seedTaskWithParent('L1', 'C2', 'grandchild 2', '02', 'T');

      final out = await eng.run();

      expect(out.conflicts, 2, reason: 'both third levels were repaired');
      for (final id in ['C1', 'C2']) {
        expect(
          (await findByAnyId(eng.store, id))!.task.parent,
          isNull,
          reason: '$id renders as a top-level row (invariant #1)',
        );
      }
      expect(
        client.callCount(Method.moveTask),
        0,
        reason: 'a read-only sync sends no corrective move',
      );
    });

    test('two third levels repaired with a corrective move', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'P', 'parent', '00000000000001');
      client.seedTaskWithParent('L1', 'T', 'subtask', '00000000000002', 'P');
      client.seedTaskWithParent('L1', 'C1', 'grandchild 1', '01', 'T');
      client.seedTaskWithParent('L1', 'C2', 'grandchild 2', '02', 'T');

      final out = await eng.run();

      expect(out.conflicts, 2, reason: 'both third levels were repaired');
      for (final id in ['C1', 'C2']) {
        expect(
          (await client.getTask('L1', id)).parent,
          isNull,
          reason: 'the corrective move for $id reached the server',
        );
        expect((await findByAnyId(eng.store, id))!.task.parent, isNull);
      }
    });

    test('two third levels whose corrective move never lands', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'P', 'parent', '00000000000001');
      client.seedTaskWithParent('L1', 'T', 'subtask', '00000000000002', 'P');
      client.seedTaskWithParent('L1', 'C1', 'grandchild 1', '01', 'T');
      client.seedTaskWithParent('L1', 'C2', 'grandchild 2', '02', 'T');
      client.failNext(Method.moveTask, () => const RateLimited());
      client.failNext(Method.moveTask, () => const RateLimited());

      final out = await eng.run();

      expect(
        out.conflicts,
        2,
        reason: 'a repair that could not be pushed is still a repair',
      );
      for (final id in ['C1', 'C2']) {
        expect(
          (await findByAnyId(eng.store, id))!.task.parent,
          isNull,
          reason: '$id is flattened locally regardless (invariant #1)',
        );
        expect(
          (await client.getTask('L1', id)).parent,
          'T',
          reason: 'the server keeps the nesting until a move lands',
        );
      }
    });

    test('two un-acknowledged subtask creates under a nested parent', () async {
      // §G: the creates were queued while T was top-level; the pull then landed
      // T's remote demote under P, so OUR two queued rows are the third level.
      final (client, eng) = await engine(push: false);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'P', 'parent', '00000000000001');
      client.seedTaskWithParent('L1', 'T', 'subtask', '00000000000002', 'P');
      await eng.run();
      final t = await localIdOf(eng.store, 'T');
      await eng.store.upsertTask(dirtyTask('c1', 'L1', 'create', parent: t));
      await eng.store.upsertTask(dirtyTask('c2', 'L1', 'create', parent: t));

      final out = await eng.run();

      expect(out.conflicts, 2, reason: 'both queued rows were promoted');
      for (final id in ['c1', 'c2']) {
        final row = (await eng.store.findTaskAny(id))!;
        expect(
          row.task.parent,
          isNull,
          reason: '$id pushes as a TOP-LEVEL create, not a third level',
        );
        expect(row.pendingOp, 'create', reason: 'and it is still queued');
      }
    });
  });

  // ─── errors ────────────────────────────────────────────────────────────────

  group('errors counts every event on its path', () {
    test('two rejected pushes', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'first', '00000000000001');
      client.seedTask('L1', 'T2', 'second', '00000000000002');
      await eng.run();
      await stageEdit(eng.store, 'T1', 'first mine');
      await stageEdit(eng.store, 'T2', 'second mine');
      client.failNext(Method.patchTask, () => const OtherApiError('400: no'));
      client.failNext(Method.patchTask, () => const OtherApiError('400: no'));

      final out = await eng.run();

      expect(out.errors, 2, reason: 'both rejections were reported');
      expect(await localTitles(eng.store, 'L1'), [
        'first mine',
        'second mine',
      ], reason: 'a rejected row keeps the edit and stays dirty to retry');
      expect(await serverTitles(client, 'L1'), ['first', 'second']);
    });

    test('two rejected moves', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'first', '00000000000001');
      client.seedTask('L1', 'T2', 'second', '00000000000002');
      client.seedTask('L1', 'A', 'anchor', '00000000000003');
      await eng.run();
      await recordServerMove(eng.store, 'T1', 'L1', 'A', null);
      await recordServerMove(eng.store, 'T2', 'L1', 'A', null);
      client.failNext(Method.moveTask, () => const OtherApiError('400: no'));
      client.failNext(Method.moveTask, () => const OtherApiError('400: no'));

      final out = await eng.run();

      expect(out.errors, 2, reason: 'both refusals were reported');
      expect(
        await eng.store.pendingMoves(),
        isEmpty,
        reason: 'a rejected move is dropped, not retried forever',
      );
      for (final id in ['T1', 'T2']) {
        expect(
          (await findByAnyId(eng.store, id))!.task.parent,
          isNull,
          reason: '$id is back where the server has it',
        );
      }
    });

    test('two list deletes the server permanently refuses', () async {
      final (client, eng) = await engine();
      await seedSyncedList(client, eng.store, 'L1', 'Work');
      await seedSyncedList(client, eng.store, 'L2', 'Home');
      await eng.run();
      client.setUndeletableList('L1');
      client.setUndeletableList('L2');
      await stageList(eng.store, 'L1', 'delete');
      await stageList(eng.store, 'L2', 'delete');

      final out = await eng.run();

      expect(out.errors, 2, reason: 'both refusals were reported');
      expect(out.deleted, 0);
      expect(
        [for (final l in await eng.store.allLists()) l.list.title]..sort(),
        ['Home', 'Work'],
        reason: 'a list Google refuses to delete comes back',
      );
    });
  });
}
