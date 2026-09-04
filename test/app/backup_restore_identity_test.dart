// Restore adopts rows by `remote_id`, not by local id (#272).
//
// The failure these protect: local ids are minted per device and per pull
// (#224), so the SAME Google task carries a different local id after a
// wipe-and-repull. A restore that matches on the local id therefore sees every
// row as missing and inserts a second copy of the user's whole account as
// pending CREATEs — the next sync then duplicates every task on Google. Google
// is the source of truth and `remote_id` is the identity that survives a
// device reset, so that is what a restore matches on.
//
// These drive the real sync engine against the fake Google (which mirrors the
// verified live semantics) and assert the STATE both sides end in: the rows the
// store holds, the push queue depth, and what the fake server holds.

import 'dart:io';

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/backup_service.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fresh engine over an in-memory store and fake API, with a DETERMINISTIC id
/// generator so a second pull demonstrably mints DIFFERENT local ids than the
/// first — exactly what happens on a real device after a reset.
Future<(FakeTasksApi, SyncEngine)> engineWith(
  FakeTasksApi client,
  String idPrefix, {
  Store? store,
}) async {
  final Store s;
  if (store != null) {
    s = store;
  } else {
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    s = Store(db);
  }
  var n = 0;
  return (
    client,
    SyncEngine.withPush(client, s, true, newId: () => '$idPrefix-${++n}'),
  );
}

void main() {
  late Directory tmp;
  setUp(
    () => tmp = Directory.systemTemp.createTempSync('axiotask_backup_identity'),
  );
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('export → reset → pull → restore inserts NOTHING', () async {
    final client = FakeTasksApi();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'first', '00000000000001');
    client.seedTask('L1', 'T2', 'second', '00000000000002');

    final (_, eng) = await engineWith(client, 'a');
    await eng.run();
    final store = eng.store;
    final firstIds = {for (final t in await store.allTasks()) t.task.id};
    expect(firstIds.length, 2, reason: 'the first pull minted two local ids');

    final backup = File('${tmp.path}/snap.json');
    final service = BackupService(store: store, backupsDir: tmp);
    await service.export(to: backup);

    // The device is reset (account switch / schema wipe) and pulls again: the
    // same Google rows come back under BRAND NEW local ids.
    await store.resetLocalData();
    final (_, eng2) = await engineWith(client, 'b', store: store);
    await eng2.run();
    final secondIds = {for (final t in await store.allTasks()) t.task.id};
    expect(
      secondIds.intersection(firstIds),
      isEmpty,
      reason: 'the re-pull minted different local ids for the same tasks',
    );

    final result = await service.importFrom(from: backup);

    expect(result.tasks, 0, reason: 'every task is already here, by remote_id');
    expect(result.lists, 0, reason: 'the list is already here, by remote_id');
    expect((await store.allTasks()).length, 2, reason: 'no duplicate rows');
    expect((await store.allLists()).length, 1);
    expect(
      await store.pendingPushCount(),
      0,
      reason: 'a restore of what Google already holds queues no push',
    );

    // And a sync after the restore leaves Google exactly as it was.
    await eng2.run();
    expect((await client.listTasks('L1')).items.map((t) => t.title), [
      'first',
      'second',
    ]);
    await store.checkInvariants();
  });

  test('a task edited after the export survives a NEWER backup', () async {
    // The sharp case for the adopt rule: the local row is only findable by
    // remote_id (the ids moved with the reset), the backup IS newer than it,
    // and the local row is DIRTY — an unpushed edit the user made after the
    // export. Local wins: a restore never throws away unpushed work.
    final client = FakeTasksApi();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'first', '00000000000001');

    final (_, eng) = await engineWith(client, 'a');
    await eng.run();
    final store = eng.store;

    final backup = File('${tmp.path}/snap.json');
    final service = BackupService(store: store, backupsDir: tmp);
    await service.export(to: backup);

    await store.resetLocalData();
    final (_, eng2) = await engineWith(client, 'b', store: store);
    await eng2.run();

    // The user renames the task — dirty, and deliberately stamped OLDER than
    // the backup so only the dirty flag can save it.
    final row = (await store.allTasks()).single;
    await store.upsertTask(
      StoredTask(
        task: Task(
          id: row.task.id,
          position: row.task.position,
          title: 'renamed after export',
          status: TaskStatus.needsAction,
          etag: row.task.etag,
          updated: row.task.updated,
        ),
        listId: row.listId,
        syncState: SyncState.dirty,
        localUpdated: '2000-01-01T00:00:00Z',
        pendingOp: 'update',
        remoteId: row.remoteId,
      ),
    );

    final result = await service.importFrom(from: backup);
    expect(result.tasks, 0, reason: 'nothing inserted — the row is here');

    final after = (await store.allTasks()).single;
    expect(
      after.task.title,
      'renamed after export',
      reason: 'a restore never clobbers an unpushed local edit',
    );
    expect(after.syncState, SyncState.dirty);
    expect(after.pendingOp, 'update');
  });

  test(
    'a newer backup wins over a CLEAN local row, as a pending update',
    () async {
      final client = FakeTasksApi();
      client.seedList('L1', 'Inbox');
      client.seedTask('L1', 'T1', 'first', '00000000000001');

      final (_, eng) = await engineWith(client, 'a');
      await eng.run();
      final store = eng.store;

      // An unpushed local rename is what the backup captured...
      final row = (await store.allTasks()).single;
      await store.upsertTask(
        StoredTask(
          task: row.task.copyWith(title: 'the title the user wants back'),
          listId: row.listId,
          syncState: SyncState.dirty,
          localUpdated: '2099-01-01T00:00:00Z',
          pendingOp: 'update',
          remoteId: row.remoteId,
        ),
      );
      final backup = File('${tmp.path}/snap.json');
      final service = BackupService(store: store, backupsDir: tmp);
      await service.export(to: backup);

      // ...and then the device was reset and re-pulled, so the local row is the
      // server's older content, CLEAN.
      await store.resetLocalData();
      final (_, eng2) = await engineWith(client, 'b', store: store);
      await eng2.run();
      expect((await store.allTasks()).single.task.title, 'first');

      final result = await service.importFrom(from: backup);
      expect(result.tasks, 0, reason: 'adopted in place, not inserted');

      final after = (await store.allTasks()).single;
      expect(after.task.title, 'the title the user wants back');
      expect(after.task.id, isNot('T1'), reason: 'the LOCAL id never moves');
      expect(after.remoteId, 'T1', reason: 'still the same Google task');
      expect(after.syncState, SyncState.dirty);
      expect(
        after.pendingOp,
        'update',
        reason: 'the restored content is pushed to Google, never re-created',
      );

      await eng2.run();
      expect(
        (await client.listTasks('L1')).items.single.title,
        'the title the user wants back',
      );
      await store.checkInvariants();
    },
  );

  test(
    'a server-backed backup restores into an EMPTY store as clean rows',
    () async {
      // Restoring onto a device that has never seen the account: the rows exist
      // on Google (they carry a remote_id), so they come back CLEAN with their
      // remote id and etag — NOT as pending creates, which would insert the whole
      // account a second time on the next sync.
      final client = FakeTasksApi();
      client.seedList('L1', 'Inbox');
      client.seedTask('L1', 'T1', 'first', '00000000000001');
      client.seedTask('L1', 'T2', 'second', '00000000000002');

      final (_, eng) = await engineWith(client, 'a');
      await eng.run();
      final backup = File('${tmp.path}/snap.json');
      await BackupService(store: eng.store, backupsDir: tmp).export(to: backup);

      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      final fresh = Store(db);
      final result = await BackupService(
        store: fresh,
        backupsDir: tmp,
      ).importFrom(from: backup);

      expect(result.lists, 1);
      expect(result.tasks, 2);
      final list = (await fresh.allLists()).single;
      expect(list.syncState, SyncState.clean);
      expect(list.remoteId, 'L1');
      expect(list.list.etag, isNotNull, reason: 'the etag comes back too');
      for (final t in await fresh.allTasks()) {
        expect(t.syncState, SyncState.clean, reason: 'Google already holds it');
        expect(t.pendingOp, isNull);
        expect(t.remoteId, isNotNull);
        expect(t.task.etag, isNotNull);
      }
      expect(
        await fresh.pendingPushCount(),
        0,
        reason: 'restoring what Google holds queues no push',
      );

      // A sync against the same account converges with no duplicate.
      final (_, eng2) = await engineWith(client, 'c', store: fresh);
      await eng2.run();
      expect((await client.listTasks('L1')).items.length, 2);
      expect((await fresh.allTasks()).length, 2);
      await fresh.checkInvariants();
    },
  );
}
