// The account-switch nuke at the STORE layer (#215).
//
// `resetLocalData` is the one irreversible local operation the product offers:
// it erases the synced cache AND the local-only lists/tasks that exist nowhere
// else, plus every push drain — dirty rows, tombstones, queued moves, in-flight
// create markers — and the sync log. The invariant it protects is the one the
// account switch depends on: once it has run, a push carrying the PREVIOUS
// account's data is impossible, because nothing is left to push.
//
// These assert what the store HOLDS afterwards (rows, drains, counts), never
// which SQL ran. `clearSynced` (fresh sync) is deliberately contrasted: it
// spares local-only lists, and a reset that behaved like it would silently
// leave the old account's local-only tasks behind for the new one.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

const _t0 = '2026-01-01T00:00:00Z';

typedef Env = ({AppDatabase db, Store store});

Future<Env> freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return (db: db, store: Store(db));
}

Future<int> syncLogRows(AppDatabase db) async =>
    (await db.customSelect('SELECT COUNT(*) AS c FROM sync_log').getSingle())
        .read<int>('c');

StoredTaskList syncedList(String id) => StoredTaskList(
  list: TaskList(id: id, title: 'Server', etag: 'e1', updated: _t0),
  syncState: SyncState.clean,
  localUpdated: _t0,
);

StoredTaskList localOnlyList(String id) => StoredTaskList(
  list: TaskList(id: id, title: 'Scratch', updated: _t0),
  syncState: SyncState.clean,
  localUpdated: _t0,
  localOnly: true,
);

StoredTask taskIn(
  String id,
  String listId, {
  SyncState syncState = SyncState.clean,
  String? pendingOp,
}) => StoredTask(
  task: Task(
    id: id,
    position: '1',
    title: 'task $id',
    status: TaskStatus.needsAction,
    etag: 'e1',
    updated: _t0,
  ),
  listId: listId,
  syncState: syncState,
  localUpdated: _t0,
  pendingOp: pendingOp,
);

/// A store loaded with everything an account switch must leave behind: a synced
/// list with a clean, a dirty and a tombstoned task, a local-only list with its
/// own task, a queued move, an in-flight create marker, and a sync-log entry.
Future<Env> loadedStore() async {
  final env = await freshStore();
  final s = env.store;
  await s.upsertList(syncedList('S1'));
  await s.upsertList(localOnlyList('LOCAL'));
  await s.upsertTask(taskIn('T-clean', 'S1'));
  await s.upsertTask(
    taskIn('T-dirty', 'S1', syncState: SyncState.dirty, pendingOp: 'update'),
  );
  await s.upsertTask(
    taskIn('T-gone', 'S1', syncState: SyncState.deleted, pendingOp: 'delete'),
  );
  await s.upsertTask(taskIn('T-local', 'LOCAL'));
  await s.upsertList(
    StoredTaskList(
      list: TaskList(id: 'S2', title: 'Renamed', etag: 'e1', updated: _t0),
      syncState: SyncState.dirty,
      localUpdated: _t0,
      pendingOp: 'update',
    ),
  );
  await s.recordMove('T-clean', 'S1', null, null);
  await s.recordInflightCreate('T-dirty', 'S1', _t0);
  await s.writeSyncLog(pulled: 3, pushed: 1, conflicts: 0, durationMs: 12);
  return env;
}

void main() {
  group('resetLocalData — the account-switch nuke', () {
    test('erases every list and task, synced and local-only alike', () async {
      final s = (await loadedStore()).store;

      await s.resetLocalData();

      expect(await s.allLists(), isEmpty, reason: 'no list may survive');
      expect(await s.allTasks(), isEmpty);
      // The tombstone is gone too — findTaskAny sees rows a visible read hides.
      expect(await s.findTaskAny('T-gone'), isNull);
      expect(await s.findTaskAny('T-local'), isNull);
    });

    test('leaves nothing that could push the old account\'s data', () async {
      final s = (await loadedStore()).store;

      await s.resetLocalData();

      expect(await s.drainDirty(), isEmpty, reason: 'no task push may remain');
      expect(await s.drainDirtyLists(), isEmpty);
      expect(await s.pendingMoves(), isEmpty);
      expect(await s.inflightCreates(), isEmpty);
      expect(await s.pendingPushCount(), 0);
    });

    test('clears the previous account\'s sync history', () async {
      final env = await loadedStore();
      expect(await syncLogRows(env.db), 1, reason: 'seeded a run to erase');

      await env.store.resetLocalData();

      expect(
        await syncLogRows(env.db),
        0,
        reason: 'the old account\'s sync runs are local data too',
      );
    });

    test(
      'is stricter than a fresh sync: local-only lists do NOT survive',
      () async {
        final s = (await loadedStore()).store;

        // Fresh sync spares local-only lists — that is its contract.
        await s.clearSynced();
        expect(
          (await s.allLists()).map((l) => l.list.id),
          contains('LOCAL'),
          reason: 'clearSynced must keep local-only (guards the contrast)',
        );

        await s.resetLocalData();
        expect(await s.allLists(), isEmpty);
      },
    );

    test('a reset store accepts fresh writes (schema intact)', () async {
      final s = (await loadedStore()).store;
      await s.resetLocalData();

      // The nuke empties the tables; it must not drop them.
      await s.upsertList(syncedList('NEW'));
      await s.upsertTask(taskIn('N1', 'NEW'));

      expect((await s.allLists()).map((l) => l.list.id), ['NEW']);
      expect((await s.allTasks()).map((t) => t.task.id), ['N1']);
    });

    test('an already-empty store resets cleanly (non-happy path)', () async {
      final s = (await freshStore()).store;

      await s.resetLocalData();

      expect(await s.allLists(), isEmpty);
      expect(await s.pendingPushCount(), 0);
    });
  });
}
