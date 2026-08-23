// Port of the list-CRUD command group from `state.rs` (`create_list` /
// `rename_list` / `delete_list`). These are the user-facing list mutations the
// property suite drives (MIGRATION-PLAN §3, §I list ops); the sync engine's
// list-push side is already covered by engine_list_test. Assertions read the
// STATE the store persists — the list rows, their sync markers, the task rows a
// list delete removes — never which method ran.

import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

const _t0 = '2026-01-01T00:00:00Z';

Future<Store> freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return Store(db);
}

/// A pushed (server-backed) list — has an etag, so a delete tombstones it.
Future<void> seedSyncedList(Store store, String id) => store.upsertList(
  StoredTaskList(
    list: TaskList(id: id, title: 'Inbox', etag: 'e1', updated: _t0),
    syncState: SyncState.clean,
    localUpdated: _t0,
    // Acknowledged by Google ⇒ it carries a remote id, which is what makes a
    // delete a tombstone rather than a local drop (#224).
    remoteId: id,
  ),
);

Future<StoredTaskList?> listById(Store store, String id) async {
  final lists = await store.allLists();
  final match = lists.where((l) => l.list.id == id);
  return match.isEmpty ? null : match.first;
}

void main() {
  test('createList writes a dirty create ready to push', () async {
    final store = await freshStore();
    final commands = Commands(store);

    final created = await commands.createList('Work');

    final row = await listById(store, created.list.id);
    expect(row, isNotNull);
    expect(row!.list.title, 'Work');
    expect(row.list.etag, isNull);
    expect(row.syncState, SyncState.dirty);
    expect(row.pendingOp, 'create');
    expect(row.localOnly, isFalse);
  });

  test('createList localOnly is a clean, never-pushed list', () async {
    final store = await freshStore();
    final commands = Commands(store);

    final created = await commands.createList('Scratch', localOnly: true);

    final row = (await listById(store, created.list.id))!;
    expect(row.localOnly, isTrue);
    expect(row.syncState, SyncState.clean);
    expect(row.pendingOp, isNull);
    // A local-only list never contributes pending push work.
    expect(await store.pendingPushCount(), 0);
  });

  test(
    'renameList on a synced list marks update, preserving the etag',
    () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedSyncedList(store, 'L1');

      await commands.renameList('L1', 'Renamed');

      final row = (await listById(store, 'L1'))!;
      expect(row.list.title, 'Renamed');
      expect(row.list.etag, 'e1');
      expect(row.syncState, SyncState.dirty);
      expect(row.pendingOp, 'update');
    },
  );

  test('renameList on an unpushed list keeps its pending create', () async {
    final store = await freshStore();
    final commands = Commands(store);
    final created = await commands.createList('Work');

    await commands.renameList(created.list.id, 'Work 2');

    final row = (await listById(store, created.list.id))!;
    expect(row.list.title, 'Work 2');
    // A rename must never flip a never-synced create to update (its push would
    // then patch a non-existent remote list).
    expect(row.pendingOp, 'create');
  });

  test(
    'deleteList tombstones a synced list and hard-deletes its tasks',
    () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedSyncedList(store, 'L1');
      await store.upsertTask(
        StoredTask(
          task: Task(
            id: 't1',
            position: '1',
            title: 'a',
            status: TaskStatus.needsAction,
            etag: 'te1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.clean,
          localUpdated: _t0,
          remoteId: 't1',
        ),
      );

      await commands.deleteList('L1');

      // The tombstone is invisible to allLists but drains as a pending delete, so
      // the deletion reaches Google (which cascades its tasks server-side).
      expect(await listById(store, 'L1'), isNull);
      final drained = await store.drainDirtyLists();
      final tomb = drained.firstWhere((l) => l.list.id == 'L1');
      expect(tomb.syncState, SyncState.deleted);
      expect(tomb.pendingOp, 'delete');
      // The local task rows are gone immediately — nothing stranded.
      expect(await store.listTasks('L1'), isEmpty);
    },
  );

  test('deleteList hard-deletes an unpushed list outright', () async {
    final store = await freshStore();
    final commands = Commands(store);
    final created = await commands.createList('Work');

    await commands.deleteList(created.list.id);

    // Never synced, so no tombstone is needed — the row is gone entirely.
    expect(await listById(store, created.list.id), isNull);
    expect(await store.pendingPushCount(), 0);
  });

  test('deleteList on a missing list is a no-op', () async {
    final store = await freshStore();
    final commands = Commands(store);
    await commands.deleteList('ghost'); // must not throw
    expect(await store.allLists(), isEmpty);
  });
}
