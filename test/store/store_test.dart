// Port of `store/repo.rs`'s in-file repo tests — the T1.3 partition: CRUD
// (upserts, hard deletes, ghost removal), read queries (all_lists, list_tasks,
// find_task_any, clean_list_ids), the sync_state / web_view_link / local_only
// round-trips, and the new drift `watch*` stream variants. Each test names the
// invariant it protects; the drain / mark-clean / apply-pushed / finish-create
// / tombstone / rehome paths belong to T1.4a/T1.4b and are ported there.
//
// Assertions read STATE the store persists (rows returned by list_tasks /
// all_lists / find_task_any, and values pushed onto the watch streams), never
// which SQL ran — a stubbed no-op Store fails every one of these.

import 'package:async/async.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
// database.dart re-exports drift-generated `Task`/`TaskList` row classes (named
// after the tables); hide them so the domain model types win unambiguously.
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/store_error.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fresh in-memory store, torn down with the test.
Future<Store> freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return Store(db);
}

const _t0 = '2026-01-01T00:00:00Z';

/// A synced (server-backed) list. Mirrors the reference `list()` helper.
StoredTaskList listOf(String id) => StoredTaskList(
  list: TaskList(id: id, title: 'Inbox', etag: 'e1', updated: _t0),
  syncState: SyncState.clean,
  localUpdated: _t0,
  // Clean and server-backed ⇒ Google acknowledged it, so it carries a remote
  // id; pinned equal to the (opaque) local id in these suites (#224).
  remoteId: id,
);

/// A local-only list (never pushed/pulled). Mirrors `local_list()`.
StoredTaskList localListOf(String id) => StoredTaskList(
  list: TaskList(id: id, title: 'Scratch', updated: _t0),
  syncState: SyncState.clean,
  localUpdated: _t0,
  localOnly: true,
);

/// A clean task. Mirrors the reference `task()` helper.
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

void main() {
  group('list CRUD + reads', () {
    test('upsert then all_lists round-trips the row', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      final all = await s.allLists();
      expect(all.map((l) => l.list.id), ['L1']);
    });

    test('local_only flag round-trips and never enters the ghost set', () async {
      final s = await freshStore();
      await s.upsertList(localListOf('LOCAL'));
      await s.upsertList(listOf('SYNCED'));
      final all = await s.allLists();
      expect(all.firstWhere((l) => l.list.id == 'LOCAL').localOnly, isTrue);
      expect(all.firstWhere((l) => l.list.id == 'SYNCED').localOnly, isFalse);
      // Ghost detection must never see a local-only list, or it would delete it
      // the moment it's absent from the server (which is always).
      final ids = {
        for (final (localId, _) in await s.cleanServerBackedLists()) localId,
      };
      expect(ids, contains('SYNCED'));
      expect(ids, isNot(contains('LOCAL')));
    });

    test('upsert_remote_list does not clobber a locally dirty row', () async {
      final s = await freshStore();
      final local = StoredTaskList(
        list: TaskList(id: 'L1', title: 'My Rename', etag: 'e1', updated: _t0),
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'update',
      );
      await s.upsertList(local);
      final remote = StoredTaskList(
        list: TaskList(
          id: 'L1',
          title: 'Server Name',
          etag: 'e1',
          updated: _t0,
        ),
        syncState: SyncState.clean,
        localUpdated: _t0,
      );
      await s.upsertRemoteList(remote);
      final l = (await s.allLists()).firstWhere((l) => l.list.id == 'L1');
      expect(l.list.title, 'My Rename', reason: 'local rename preserved');
      expect(l.syncState, SyncState.dirty);
    });

    test('delete_list_hard_if_clean spares a dirty list', () async {
      final s = await freshStore();
      final l = StoredTaskList(
        list: TaskList(id: 'L1', title: 'Inbox', etag: 'e1', updated: _t0),
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'update',
      );
      await s.upsertList(l);
      await s.deleteListHardIfClean('L1');
      expect((await s.allLists()).length, 1, reason: 'dirty list spared');
    });

    test('delete_list_hard removes the row', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      expect((await s.allLists()).length, 1);
      await s.deleteListHard('L1');
      expect(await s.allLists(), isEmpty);
    });

    test('all_lists excludes a deleted (tombstoned) list', () async {
      final s = await freshStore();
      await s.upsertList(
        StoredTaskList(
          list: TaskList(id: 'L1', title: 'Inbox', etag: 'e1', updated: _t0),
          syncState: SyncState.deleted,
          localUpdated: _t0,
        ),
      );
      expect(await s.allLists(), isEmpty);
    });
  });

  group('task CRUD + reads', () {
    test(
      'list_tasks orders top-level rows before subtasks by position',
      () async {
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        await s.upsertTask(taskOf('T1', 'L1', null, '00000000000001'));
        await s.upsertTask(taskOf('T2', 'L1', null, '00000000000002'));
        await s.upsertTask(taskOf('T1a', 'L1', 'T1', '00000000000001'));
        final rows = await s.listTasks('L1');
        // Top-level first (parent IS NULL sorts ahead), then the subtask.
        expect(rows.map((r) => r.task.id), ['T1', 'T2', 'T1a']);
        expect(rows[2].task.parent, 'T1');
      },
    );

    test('upsert overwrites an existing task in place', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      final updated = StoredTask(
        task: Task(
          id: 'T1',
          position: '1',
          title: 'renamed',
          status: TaskStatus.needsAction,
          etag: 'e1',
          updated: _t0,
        ),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'update',
      );
      await s.upsertTask(updated);
      final rows = await s.listTasks('L1');
      expect(rows.length, 1);
      expect(rows.single.task.title, 'renamed');
      expect(rows.single.syncState, SyncState.dirty);
    });

    test('web_view_link round-trips through both read paths', () async {
      const link = 'https://tasks.google.com/task/abc123';
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(
        StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'task T1',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
            webViewLink: link,
          ),
          listId: 'L1',
          syncState: SyncState.clean,
          localUpdated: _t0,
        ),
      );
      expect((await s.listTasks('L1')).single.task.webViewLink, link);
      expect((await s.findTaskAny('T1'))!.task.webViewLink, link);
    });

    test('delete_task_hard removes the row', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '1'));
      expect((await s.listTasks('L1')).length, 1);
      await s.deleteTaskHard('T1');
      expect(await s.listTasks('L1'), isEmpty);
    });

    test(
      'list_tasks excludes a tombstone that find_task_any still sees',
      () async {
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        await s.upsertTask(
          StoredTask(
            task: Task(
              id: 'T1',
              position: '1',
              title: 'task T1',
              status: TaskStatus.needsAction,
              updated: _t0,
            ),
            listId: 'L1',
            syncState: SyncState.deleted,
            localUpdated: _t0,
            pendingOp: 'delete',
          ),
        );
        expect(await s.listTasks('L1'), isEmpty);
        final found = await s.findTaskAny('T1');
        expect(found!.syncState, SyncState.deleted);
        expect(await s.findTaskAny('nope'), isNull);
      },
    );

    test('upsert_remote_task does not clobber a locally dirty edit', () async {
      final s = await freshStore();
      await s.upsertList(listOf('L1'));
      final local = StoredTask(
        task: Task(
          id: 'T1',
          position: '1',
          title: 'my edit',
          status: TaskStatus.needsAction,
          etag: 'e1',
          updated: _t0,
        ),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'update',
      );
      await s.upsertTask(local);
      final remote = StoredTask(
        task: Task(
          id: 'T1',
          position: '1',
          title: 'server version',
          status: TaskStatus.needsAction,
          etag: 'e1',
          updated: _t0,
        ),
        listId: 'L1',
        syncState: SyncState.clean,
        localUpdated: _t0,
      );
      await s.upsertRemoteTask(remote);
      final row = (await s.listTasks('L1')).single;
      expect(row.task.title, 'my edit');
      expect(row.syncState, SyncState.dirty);
    });

    test(
      'upsert_remote_task updates a clean row and inserts a new one',
      () async {
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        await s.upsertRemoteTask(taskOf('T1', 'L1', null, '1'));
        expect((await s.listTasks('L1')).length, 1);
        final updated = StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'updated',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.clean,
          localUpdated: _t0,
        );
        await s.upsertRemoteTask(updated);
        expect((await s.listTasks('L1')).single.task.title, 'updated');
      },
    );

    test(
      'remove_ghost_task spares a dirty row and removes a clean one',
      () async {
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        final dirty = StoredTask(
          task: Task(
            id: 'T1',
            position: '1',
            title: 'task T1',
            status: TaskStatus.needsAction,
            etag: 'e1',
            updated: _t0,
          ),
          listId: 'L1',
          syncState: SyncState.dirty,
          localUpdated: _t0,
          pendingOp: 'update',
        );
        await s.upsertTask(dirty);
        expect(await s.removeGhostTask('T1'), isFalse);
        expect((await s.listTasks('L1')).length, 1, reason: 'dirty row spared');

        await s.upsertTask(taskOf('T2', 'L1', null, '2'));
        expect(await s.removeGhostTask('T2'), isTrue);
        expect((await s.listTasks('L1')).map((r) => r.task.id), ['T1']);
      },
    );

    test(
      'remove_ghost_task cascades its whole subtree (D3 rejected)',
      () async {
        // A remotely-deleted parent takes its ENTIRE subtree with it — synced
        // rows, tombstones, AND the unpushed subtask the server never saw. No
        // auto-promotion: a subtask shares its parent's fate (invariant #3).
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        await s.upsertTask(taskOf('P', 'L1', null, '1'));
        await s.upsertTask(taskOf('C-synced', 'L1', 'P', '2'));
        // Non-happy path: an unpushed subtask the server has never seen.
        await s.upsertTask(
          StoredTask(
            task: Task(
              id: 'C-new',
              parent: 'P',
              position: '3',
              title: 'task C-new',
              status: TaskStatus.needsAction,
              updated: _t0,
            ),
            listId: 'L1',
            syncState: SyncState.dirty,
            localUpdated: _t0,
            pendingOp: 'create',
          ),
        );
        await s.upsertTask(
          StoredTask(
            task: Task(
              id: 'C-doomed',
              parent: 'P',
              position: '4',
              title: 'task C-doomed',
              status: TaskStatus.needsAction,
              updated: _t0,
            ),
            listId: 'L1',
            syncState: SyncState.deleted,
            localUpdated: _t0,
            pendingOp: 'delete',
          ),
        );

        expect(await s.removeGhostTask('P'), isTrue);
        expect(await s.findTaskAny('C-synced'), isNull);
        expect(await s.findTaskAny('C-doomed'), isNull);
        expect(
          await s.findTaskAny('C-new'),
          isNull,
          reason: 'the unpushed subtask dies with its parent — never promoted',
        );
      },
    );
  });

  group('sync_state round-trip', () {
    test('every SyncState round-trips through its SQLite string form', () {
      for (final st in SyncState.values) {
        expect(SyncState.parse(st.asStr), st);
      }
      expect(SyncState.parse('unknown'), isNull);
    });
  });

  group('rows this app could not have written', () {
    // Every read maps a row through a parse of its `sync_state` / `status`
    // text. The columns carry CHECK constraints, so the app itself can never
    // store an unknown value — the guards exist for a database it did not
    // write (hand-edited, restored from elsewhere, or left by a build that
    // knew a state this one does not). What a user must never get in that case
    // is a silently mis-read row: the read fails loudly instead, and the sync
    // layer reports it as a non-transient store error. The CHECK is suspended
    // for one statement here to stand in for that database; no product code
    // ever does this.
    Future<(Store, AppDatabase)> corruptible() async {
      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      await db.customStatement('PRAGMA ignore_check_constraints = ON');
      return (Store(db), db);
    }

    test('an unknown list sync_state fails the read', () async {
      final (s, db) = await corruptible();
      await s.upsertList(listOf('L1'));
      await db.customStatement(
        "UPDATE task_lists SET sync_state = 'archived' WHERE id = 'L1'",
      );
      await expectLater(
        s.allLists(),
        throwsA(
          isA<StoreSqlError>().having(
            (e) => e.message,
            'message',
            contains('archived'),
          ),
        ),
      );
    });

    test('an unknown task status fails the read', () async {
      final (s, db) = await corruptible();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '0001'));
      await db.customStatement(
        "UPDATE tasks SET status = 'inProgress' WHERE id = 'T1'",
      );
      await expectLater(
        s.findTaskAny('T1'),
        throwsA(
          isA<StoreSqlError>().having(
            (e) => e.message,
            'message',
            contains('inProgress'),
          ),
        ),
      );
    });

    test('an unknown task sync_state fails the read', () async {
      final (s, db) = await corruptible();
      await s.upsertList(listOf('L1'));
      await s.upsertTask(taskOf('T1', 'L1', null, '0001'));
      await db.customStatement(
        "UPDATE tasks SET sync_state = 'archived' WHERE id = 'T1'",
      );
      await expectLater(
        s.listTasks('L1'),
        throwsA(
          isA<StoreSqlError>().having(
            (e) => e.message,
            'message',
            contains('archived'),
          ),
        ),
      );
    });
  });

  group('watch streams', () {
    test(
      'watchLists emits the current lists and re-emits after an upsert',
      () async {
        final s = await freshStore();
        final q = StreamQueue(s.watchLists());
        expect(await q.next, isEmpty, reason: 'no lists yet');
        await s.upsertList(listOf('L1'));
        expect((await q.next).map((l) => l.list.id), ['L1']);
        await q.cancel();
      },
    );

    test(
      'watchTasks re-emits the ordered task list after each write',
      () async {
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        final q = StreamQueue(s.watchTasks('L1'));
        expect(await q.next, isEmpty);
        await s.upsertTask(taskOf('T1', 'L1', null, '0001'));
        expect((await q.next).map((r) => r.task.id), ['T1']);
        await s.upsertTask(taskOf('T1a', 'L1', 'T1', '0001'));
        expect((await q.next).map((r) => r.task.id), ['T1', 'T1a']);
        await q.cancel();
      },
    );

    // Pull-storm rebuild-count guard (T10.1): drift's table-granular
    // invalidation re-delivers an identical result on every no-op write; the
    // watch streams must collapse consecutive identical results so a sync pull
    // that rewrites rows to the same content does not storm open views. See the
    // fuller note in store_all_tasks_test.dart. `pumpEventQueue` between writes
    // forces each re-query to deliver (drift otherwise coalesces awaited writes).
    test(
      'watchTasks suppresses identical re-emissions (pull-storm dedup)',
      () async {
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        await s.upsertTask(taskOf('T1', 'L1', null, '0001'));
        final events = <List<String>>[];
        final sub = s
            .watchTasks('L1')
            .listen((e) => events.add([for (final r in e) r.task.id]));
        await pumpEventQueue();
        expect(events, [
          ['T1'],
        ]);
        for (var i = 0; i < 5; i++) {
          await s.upsertTask(taskOf('T1', 'L1', null, '0001'));
          await pumpEventQueue();
        }
        await s.upsertTask(taskOf('T2', 'L1', null, '0002'));
        await pumpEventQueue();
        expect(events, [
          ['T1'],
          ['T1', 'T2'],
        ]);
        await sub.cancel();
      },
    );

    test(
      'watchTask suppresses identical re-emissions (pull-storm dedup)',
      () async {
        // The detail panel's single-task stream is open during a pull storm too;
        // a no-op rewrite of the same row must not re-notify it.
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        await s.upsertTask(taskOf('T1', 'L1', null, '0001'));
        final titles = <String?>[];
        final sub = s.watchTask('T1').listen((e) => titles.add(e?.task.title));
        await pumpEventQueue();
        expect(titles, ['task T1']); // initial
        for (var i = 0; i < 5; i++) {
          await s.upsertTask(taskOf('T1', 'L1', null, '0001'));
          await pumpEventQueue();
        }
        // A genuine field change re-emits (title differs).
        final base = taskOf('T1', 'L1', null, '0001');
        await s.upsertTask(
          StoredTask(
            task: base.task.copyWith(title: 'edited'),
            listId: base.listId,
            syncState: base.syncState,
            localUpdated: base.localUpdated,
          ),
        );
        await pumpEventQueue();
        expect(titles, ['task T1', 'edited']);
        await sub.cancel();
      },
    );

    test(
      'watchTask streams the visible task and emits null once deleted',
      () async {
        // Non-happy path: a hard delete must push a null onto the detail stream
        // so the panel can react, not silently strand a stale row.
        final s = await freshStore();
        await s.upsertList(listOf('L1'));
        await s.upsertTask(taskOf('T1', 'L1', null, '1'));
        final q = StreamQueue(s.watchTask('T1'));
        expect((await q.next)?.task.id, 'T1');
        await s.deleteTaskHard('T1');
        expect(await q.next, isNull);
        await q.cancel();
      },
    );
  });
}
