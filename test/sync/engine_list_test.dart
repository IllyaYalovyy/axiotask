// Port of `sync/engine.rs`'s in-file tests — the T5.7 partition (MIGRATION-PLAN
// §5): the LIST SYNC group (list create/rename/delete push paths, their
// not-found / transient / auth-abort variants, and the pull's adopt/preserve/
// ghost behaviours) and the RFC-009 §I matrix (local list ops × remote). The
// §G group (local `create` × remote) belongs to T5.5 (engine_create_test.dart);
// the update/delete/§B/§C/§D matrices to T5.6 (engine_update_test.dart); the
// §A / mid-run groups to a later task.
//
// Lists have no conflict machinery: `patch_tasklist` IGNORES `If-Match` (probe
// 8 / #106), so a rename can never 412 and there is nothing to fork a
// "(conflicted copy)" from. D6 (remote wins, no copy) is what that server
// design forces, and these tests pin the convergence it has to produce in both
// serializations. As everywhere, they drive `run()` end to end against the fake
// server and assert the STATE both sides converge to — the rows the store
// returns and the lists the fake holds — never which method the engine called.

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

const _t0 = '2026-01-01T00:00:00Z';

/// A fresh engine over an in-memory store and fake API, torn down with the test.
Future<(FakeTasksApi, SyncEngine)> engine({bool push = false}) async {
  final client = FakeTasksApi();
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  final store = Store(db);
  final eng = push
      ? SyncEngine.withPush(client, store, true)
      : SyncEngine(client, store);
  return (client, eng);
}

/// A dirty local list row, matching the reference's `dirty_list`: `create` →
/// no etag, no remote id, dirty + pending `create`; `update` → etag `e1` +
/// dirty + `update`; `delete` → etag `e1` + deleted + `delete`.
///
/// A row the server has already acknowledged also carries a `remote_id` — the
/// only thing a rename or delete push can name it by (#224). These suites pin
/// it equal to the local id, which local ids being opaque strings allows.
StoredTaskList dirtyList(String id, String title, String op) => StoredTaskList(
  list: TaskList(
    id: id,
    title: title,
    etag: op == 'create' ? null : 'e1',
    updated: _t0,
  ),
  syncState: op == 'delete' ? SyncState.deleted : SyncState.dirty,
  localUpdated: _t0,
  pendingOp: op,
  remoteId: op == 'create' ? null : id,
);

/// A dirty (or tombstoned) local task row, matching the reference's
/// `dirty_task`.
StoredTask dirtyTask(
  String id,
  String listId,
  String op, {
  String? title,
  String? parent,
  String? due,
  String position = '1',
  String localUpdated = _t0,
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title ?? 'task $id',
    status: TaskStatus.needsAction,
    due: due,
    updated: _t0,
  ),
  listId: listId,
  syncState: op == 'delete' ? SyncState.deleted : SyncState.dirty,
  localUpdated: localUpdated,
  pendingOp: op,
);

/// The list row with [id] (fails if there is none), the way the reference
/// re-reads a list to mutate it. [TaskList] is immutable, so callers rebuild.
Future<StoredTaskList> listById(Store store, String id) async =>
    (await store.allLists()).firstWhere(
      (l) => l.list.id == id || l.remoteId == id,
    );

/// A copy of [l] renamed to [title], staged as a dirty `update` — the way the
/// reference mutates `l.list.title` / `sync_state` / `pending_op` in place.
StoredTaskList renamedList(StoredTaskList l, String title) => StoredTaskList(
  list: TaskList(
    id: l.list.id,
    title: title,
    etag: l.list.etag,
    updated: l.list.updated,
  ),
  syncState: SyncState.dirty,
  localUpdated: l.localUpdated,
  pendingOp: 'update',
  remoteId: l.remoteId,
);

/// A copy of [l] marked deleted, staged as a pending `delete` tombstone.
StoredTaskList deletedList(StoredTaskList l) => StoredTaskList(
  list: l.list,
  syncState: SyncState.deleted,
  localUpdated: l.localUpdated,
  pendingOp: 'delete',
  remoteId: l.remoteId,
);

/// Every list title the local store would show in the sidebar. Tombstoned
/// lists are excluded by `all_lists`, exactly as the UI sees them.
Future<List<String>> sidebar(SyncEngine eng) async {
  final titles = (await eng.store.allLists()).map((l) => l.list.title).toList();
  titles.sort();
  return titles;
}

/// Mark a synced list deleted the way `AppState::delete_list` does: local task
/// rows go immediately, the list becomes a tombstone to push.
Future<void> tombstoneList(SyncEngine eng, String id) async {
  for (final t in await eng.store.listTasks(id)) {
    await eng.store.deleteTaskHard(t.task.id);
  }
  final l = (await eng.store.allLists()).firstWhere((l) => l.list.id == id);
  await eng.store.upsertList(deletedList(l));
}

void main() {
  // ─── List sync ─────────────────────────────────────────────────────────────

  test('push_list_create_learns_the_remote_id_and_keeps_its_own', () async {
    final (_, eng) = await engine(push: true);
    // Local list create + a task in it.
    await eng.store.upsertList(dirtyList('local-list', 'Work', 'create'));
    await eng.store.upsertTask(
      dirtyTask('local-task', 'local-list', 'create', title: 'do work'),
    );

    final out = await eng.run();
    expect(out.pushed >= 2, isTrue);
    // The list LEARNS a remote id and keeps its own; the task never moved, so
    // its `list_id` needed no rewriting at all (#224).
    final lists = await eng.store.allLists();
    final work = lists.firstWhere((l) => l.list.title == 'Work');
    expect(work.list.id, 'local-list');
    expect(work.remoteId, startsWith('remote-list-'));
    expect(work.syncState, SyncState.clean);
    final tasks = await eng.store.listTasks('local-list');
    expect(tasks.length, 1);
    expect(tasks[0].task.id, 'local-task');
    expect(tasks[0].remoteId, startsWith('remote-'));
  });

  test('held_edit_holds_list_create_then_pushes_on_release', () async {
    // A held edit (the UI is actively holding a row) freezes ALL list creates
    // for that run. The pending list create must WAIT — not push, not get
    // ghosted by the pull — and then push on the next unheld run.
    final (client, eng0) = await engine(push: true);
    await eng0.store.upsertList(dirtyList('local-list', 'Work', 'create'));

    // Run 1: an edit is held. The list create must be deferred.
    final engHold = SyncEngine.withPush(
      client,
      eng0.store,
      true,
    ).holdCreateId('held-task');
    var out = await engHold.run();
    expect(out.pushed, 0, reason: 'nothing pushed while the edit is held');
    var lists = await eng0.store.allLists();
    final workHeld = lists.where((l) => l.list.title == 'Work').toList();
    expect(
      workHeld,
      isNotEmpty,
      reason: 'pending list survives the held run, not ghosted',
    );
    expect(
      workHeld.first.remoteId,
      isNull,
      reason: 'no remote id learned while the edit is held',
    );
    expect(
      workHeld.first.syncState,
      SyncState.dirty,
      reason: 'create still queued',
    );
    expect(
      (await client.listTasklists()).every((l) => l.title != 'Work'),
      isTrue,
      reason: 'server has no such list yet',
    );

    // Run 2: the edit is released. The deferred create now pushes and remaps.
    out = await eng0.run();
    expect(out.pushed, 1, reason: 'the deferred list create pushes on release');
    lists = await eng0.store.allLists();
    final work = lists.firstWhere((l) => l.list.title == 'Work');
    expect(
      work.remoteId,
      startsWith('remote-list-'),
      reason: 'the remote id is learned on release',
    );
    expect(work.list.id, 'local-list', reason: 'and the local id never moves');
    expect(work.syncState, SyncState.clean);
    expect(
      (await client.listTasklists()).any((l) => l.title == 'Work'),
      isTrue,
      reason: 'list now exists on the server',
    );
  });

  test('push_list_rename', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Old Name');
    await eng.run();

    await eng.store.upsertList(
      renamedList(await listById(eng.store, 'L1'), 'New Name'),
    );

    final out = await eng.run();
    expect(out.pushed >= 1, isTrue);
    final page = await client.listTasklists();
    expect(page.any((l) => l.id == 'L1' && l.title == 'New Name'), isTrue);
    final l = await listById(eng.store, 'L1');
    expect(l.syncState, SyncState.clean);
  });

  test('push_list_delete', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Doomed');
    await eng.run();

    await eng.store.upsertList(deletedList(await listById(eng.store, 'L1')));

    final out = await eng.run();
    expect(out.deleted, 1);
    // Gone from server and local.
    expect((await client.listTasklists()).every((l) => l.id != 'L1'), isTrue);
    expect(
      (await eng.store.allLists()).every((l) => l.list.id != 'L1'),
      isTrue,
    );
  });

  test('push_list_rename_not_found_hard_deletes_local', () async {
    // Renaming a list the server no longer has (deleted elsewhere) 404s. The
    // rename is meaningless against a gone list, so the local row is
    // hard-deleted to converge with the server — not left dirty to 404 forever.
    // No error is surfaced.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Old Name');
    await eng.run();

    await eng.store.upsertList(
      renamedList(await listById(eng.store, 'L1'), 'New Name'),
    );

    // The list is gone on the server (deleted by another client), so the rename
    // naturally 404s — and a pull won't resurrect it.
    client.deleteListFromState('L1');

    final out = await eng.run();
    expect(out.errors, 0, reason: 'a 404 rename is not a server rejection');
    expect(
      (await eng.store.allLists()).every((l) => l.list.id != 'L1'),
      isTrue,
      reason: 'the gone list is hard-deleted locally, not left dirty forever',
    );
  });

  test('push_list_rename_not_found_rehomes_the_rows_the_server_never_saw', () async {
    // §I × P2. The 404 says the list is gone on the server, so it goes locally
    // too (P4) — but an unpushed create in it is work the server has NEVER SEEN,
    // and a remote event must not destroy that. It re-homes to the default list,
    // exactly as the pull's ghost path does (D2).
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Work');
    await seedSyncedList(client, eng.store, 'L2', 'My Tasks');
    await eng.run();

    await eng.store.upsertList(
      renamedList(await listById(eng.store, 'L1'), 'Work stuff'),
    );
    await eng.store.upsertTask(dirtyTask('local-1', 'L1', 'create'));

    client.deleteListFromState('L1');
    await eng.run();

    expect(
      (await eng.store.allLists()).every((l) => l.list.id != 'L1'),
      isTrue,
      reason: 'the gone list is still dropped locally (P4)',
    );
    expect(
      (await eng.store.listTasks('L2')).map((t) => t.task.title).toList(),
      ['task local-1'],
      reason: 'and the unpushed row survived in the default list (P2/D2)',
    );
  });

  test(
    'push_list_rename_not_found_keeps_the_list_when_there_is_nowhere_to_rehome',
    () async {
      // The same 404 with no surviving list to take the rows: dropping the list
      // would destroy them, so it is kept as an unpushed list create and
      // re-created on the server instead (P2 holds even with one list left).
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Work');
      await eng.run();

      await eng.store.upsertList(
        renamedList(await listById(eng.store, 'L1'), 'Work stuff'),
      );
      await eng.store.upsertTask(dirtyTask('local-1', 'L1', 'create'));

      client.deleteListFromState('L1');
      await eng.run();
      await eng.run();

      final lists = await eng.store.allLists();
      final kept = lists.firstWhere(
        (l) => l.list.title == 'Work stuff',
        orElse: () => throw StateError(
          'the list was kept rather than taking the row down',
        ),
      );
      expect(
        (await eng.store.listTasks(
          kept.list.id,
        )).map((t) => t.task.title).toList(),
        ['task local-1'],
      );
      expect((await client.listTasklists()).map((l) => l.title).toList(), [
        'Work stuff',
      ], reason: 'and it was re-created on the server so the row can push');
    },
  );

  test('push_list_rename_transient_stays_dirty_then_converges', () async {
    // A transient (503) on a list rename must leave the row dirty and the server
    // untouched — no error surfaced — then succeed on the next run.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Old Name');
    await eng.run();

    await eng.store.upsertList(
      renamedList(await listById(eng.store, 'L1'), 'New Name'),
    );

    client.failNext(Method.patchTasklist, () => const ServerError(503));

    var out = await eng.run();
    expect(out.errors, 0, reason: 'transient is not counted as an error');
    var l = await listById(eng.store, 'L1');
    expect(l.syncState, SyncState.dirty, reason: 'stays dirty for retry');
    expect(l.list.title, 'New Name', reason: 'local rename intent preserved');
    expect(
      (await client.listTasklists()).any(
        (r) => r.id == 'L1' && r.title == 'Old Name',
      ),
      isTrue,
      reason: 'server unchanged while the retry is pending',
    );

    // Next run (no fault): the rename lands and the row goes clean.
    out = await eng.run();
    expect(out.pushed >= 1, isTrue);
    expect(
      (await client.listTasklists()).any(
        (r) => r.id == 'L1' && r.title == 'New Name',
      ),
      isTrue,
    );
    l = await listById(eng.store, 'L1');
    expect(l.syncState, SyncState.clean);
  });

  test('push_list_delete_transient_leaves_tombstone', () async {
    // A transient on a list delete must NOT hard-delete locally (that would
    // strand the list on the server) — it stays a tombstone and retries.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Doomed');
    await eng.run();

    await eng.store.upsertList(deletedList(await listById(eng.store, 'L1')));

    client.failNext(Method.deleteTasklist, () => const ServerError(503));

    final out = await eng.run();
    expect(out.deleted, 0, reason: 'nothing deleted on a transient');
    expect(out.errors, 0, reason: 'transient is not counted as an error');
    // Deleted tombstones are excluded from all_lists; they live in the
    // dirty-list queue awaiting push.
    final pending = await eng.store.drainDirtyLists();
    expect(
      pending.any((l) => l.list.id == 'L1' && l.syncState == SyncState.deleted),
      isTrue,
      reason: 'tombstone survives for the next run\'s retry',
    );
    expect(
      (await client.listTasklists()).any((r) => r.id == 'L1'),
      isTrue,
      reason: 'server list untouched while delete retries',
    );
  });

  test('push_list_delete_auth_abort_leaves_tombstone', () async {
    // A 401 on a list delete aborts the run (every call would fail the same way)
    // instead of being swallowed. The tombstone survives so the delete pushes
    // after re-auth, and the server list is untouched.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Doomed');
    await eng.run();

    await eng.store.upsertList(deletedList(await listById(eng.store, 'L1')));

    client.failNext(Method.deleteTasklist, () => const Unauthorized());

    await expectLater(
      eng.run(),
      throwsA(
        isA<SyncApiError>().having(
          (e) => e.error,
          'error',
          isA<Unauthorized>(),
        ),
      ),
      reason: 'auth failure aborts the run',
    );
    final pending = await eng.store.drainDirtyLists();
    expect(
      pending.any((l) => l.list.id == 'L1' && l.syncState == SyncState.deleted),
      isTrue,
      reason: 'tombstone survives for retry after re-auth',
    );
    expect(
      (await client.listTasklists()).any((r) => r.id == 'L1'),
      isTrue,
      reason: 'server list untouched by the aborted delete',
    );
  });

  test('pull_adopts_local_create_by_title', () async {
    // Offline default "My Tasks" (local create) must adopt Google's existing
    // "My Tasks" on pull instead of duplicating.
    final (client, eng) = await engine(push: true);
    await eng.store.upsertList(dirtyList('local-uuid', 'My Tasks', 'create'));
    // Deliberately untracked locally: adoption by title is what is under test.
    client.seedList('remote-mytasks', 'My Tasks');

    await eng.run();

    final lists = await eng.store.allLists();
    final mt = lists.where((l) => l.list.title == 'My Tasks').toList();
    expect(mt.length, 1, reason: 'no duplicate My Tasks');
    expect(
      mt[0].list.id,
      'local-uuid',
      reason: 'the adopting row keeps its own id (#224)',
    );
    expect(mt[0].remoteId, 'remote-mytasks', reason: 'and learns Google\'s');
    expect(mt[0].syncState, SyncState.clean);
  });

  test('pull_preserves_locally_renamed_list', () async {
    final (client, eng) = await engine();
    await seedSyncedList(client, eng.store, 'L1', 'Server Title');
    await eng.run();

    await eng.store.upsertList(
      renamedList(await listById(eng.store, 'L1'), 'Local Rename'),
    );

    await eng.run(); // pull must not clobber the local rename (push disabled)
    final l = await listById(eng.store, 'L1');
    expect(l.list.title, 'Local Rename');
    expect(l.syncState, SyncState.dirty);
  });

  test('pull_removes_ghost_list_and_its_tasks', () async {
    final (client, eng) = await engine();
    await seedSyncedList(client, eng.store, 'L1', 'Keep');
    await seedSyncedList(client, eng.store, 'L2', 'Vanish');
    client.seedTask('L2', 'T2', 'doomed', '1');
    await eng.run();
    expect((await eng.store.allLists()).length, 2);

    // L2 deleted on the server.
    await client.deleteTasklist('L2');

    final out = await eng.run();
    expect(out.deleted >= 1, isTrue);
    final lists = await eng.store.allLists();
    expect(lists.length, 1);
    expect(lists[0].list.id, 'L1');
    // Cascade removed the ghost list's tasks.
    expect(await eng.store.listTasks('L2'), isEmpty);
  });

  test('ghost_detection_spares_local_only_list', () async {
    // A local-only list is absent from the server by design. Ghost detection
    // must never remove it, even though no remote list matches.
    final (client, eng) = await engine();
    await seedSyncedList(client, eng.store, 'L1', 'Synced');
    await eng.run();

    await eng.store.upsertList(
      StoredTaskList(
        list: TaskList(id: 'local-1', title: 'Scratch', updated: _t0),
        syncState: SyncState.clean,
        localUpdated: _t0,
        localOnly: true,
      ),
    );
    await eng.store.upsertTask(
      StoredTask(
        task: Task(
          id: 'local-task',
          position: '1',
          title: 'scratch task',
          status: TaskStatus.needsAction,
          updated: _t0,
        ),
        listId: 'local-1',
        syncState: SyncState.clean,
        localUpdated: _t0,
      ),
    );

    await eng.run();

    final lists = await eng.store.allLists();
    expect(
      lists.any((l) => l.list.id == 'local-1'),
      isTrue,
      reason: 'local-only list survives ghost detection',
    );
    expect(
      (await eng.store.listTasks('local-1')).length,
      1,
      reason: 'its tasks survive too',
    );
  });

  test('push_skips_local_only_list_and_its_tasks', () async {
    // With push enabled, neither a local-only list nor its tasks may be sent to
    // the server.
    final (client, eng) = await engine(push: true);
    await eng.store.upsertList(
      StoredTaskList(
        list: TaskList(id: 'local-1', title: 'Scratch', updated: _t0),
        syncState: SyncState.clean,
        localUpdated: _t0,
        localOnly: true,
      ),
    );
    await eng.store.upsertTask(dirtyTask('local-task', 'local-1', 'create'));

    final out = await eng.run();
    expect(out.pushed, 0, reason: 'nothing from a local-only list is pushed');
    // The list never appears on the server.
    expect(
      (await client.listTasklists()).every((l) => l.title != 'Scratch'),
      isTrue,
    );
    // The task stays local and dirty (still awaiting nothing — it's local-only).
    final tasks = await eng.store.listTasks('local-1');
    expect(tasks.length, 1);
    expect(tasks[0].task.id, 'local-task');
  });

  // ─── RFC-009 §I matrix: local list ops × remote ────────────────────────────

  test(
    'a_list_rename_race_lands_last_writer_wins_with_no_conflicted_copy',
    () async {
      // §I × remote rename, D6 (RATIFIED). Two devices rename the same list in the
      // same window. The tasklists endpoint has no precondition, so our PATCH
      // lands over theirs (last writer wins) — and, crucially, the outcome is ONE
      // list, not a forked copy: the sidebar never grows a second entry out of a
      // rename race, and the run converges (P7).
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Work');
      client.seedTask('L1', 'T1', 'ship it', '1');
      await eng.run();

      // Local rename, still unpushed.
      await eng.store.upsertList(
        renamedList(await listById(eng.store, 'L1'), 'Job'),
      );
      // The other device renames it too, bumping the list's etag.
      await client.patchTasklist('L1', 'Career');

      var out = await eng.run();
      expect(out.errors, 0, reason: 'no 412 is possible on a tasklist');
      expect(out.conflicts, 0, reason: 'and no conflicted copy is ever forked');

      expect(await sidebar(eng), [
        'Job',
      ], reason: 'one list, carrying the last write');
      final remote = await client.listTasklists();
      expect(
        remote.length,
        1,
        reason: 'no duplicate list on the server either',
      );
      expect(remote[0].title, 'Job');
      // The list's tasks are untouched by the rename race.
      expect(
        (await eng.store.listTasks('L1')).map((t) => t.task.title).toList(),
        ['ship it'],
      );

      out = await eng.run();
      expect((out.pushed, out.errors), (0, 0), reason: 'converged (P7)');
    },
  );

  test('a_remote_rename_after_ours_landed_wins_on_the_next_pull', () async {
    // §I × remote rename, the other serialization — the remote write is the last
    // one. D6: remote wins, silently. The local title is replaced with no copy,
    // no error and no "your rename was overwritten" state to clean up, and the
    // row stays clean so nothing re-pushes the old title.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Work');
    await eng.run();

    await eng.store.upsertList(
      renamedList(await listById(eng.store, 'L1'), 'Job'),
    );
    await eng.run();
    expect(await sidebar(eng), ['Job'], reason: 'our rename landed');

    // Only now does the other device rename it.
    await client.patchTasklist('L1', 'Career');
    var out = await eng.run();

    expect(await sidebar(eng), ['Career'], reason: 'remote wins (D6)');
    expect(out.conflicts, 0);
    expect(out.errors, 0);
    expect(out.listsChanged, isTrue, reason: 'the sidebar is told to refresh');
    final stored = await listById(eng.store, 'L1');
    expect(stored.syncState, SyncState.clean, reason: 'nothing left to push');

    out = await eng.run();
    expect((out.pushed, out.errors), (0, 0), reason: 'converged (P7)');
  });

  test('a_locally_deleted_list_takes_remotely_added_tasks_with_it', () async {
    // §I × remote added tasks to the list meanwhile. Google's list delete
    // cascades server-side (P4), so a task another device dropped into the list
    // in our delete window dies with it. Accepted: the user asked for the list
    // to go. What must NOT happen is a local orphan — a row in a list that no
    // longer exists, invisible in every view and undeletable.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
    await seedSyncedList(client, eng.store, 'L2', 'Doomed');
    client.seedTask('L2', 'T1', 'old row', '1');
    await eng.run();

    await tombstoneList(eng, 'L2');
    // Another device adds a task to the list we are deleting.
    client.seedTask('L2', 'T2', 'added elsewhere', '2');

    var out = await eng.run();
    expect(out.errors, 0);
    expect(await sidebar(eng), ['My Tasks'], reason: 'the list is gone');
    expect(
      (await client.listTasklists()).every((l) => l.id != 'L2'),
      isTrue,
      reason: 'and gone on the server',
    );
    await expectLater(
      client.listTasks('L2'),
      throwsA(isA<NotFound>()),
      reason:
          'the list itself is gone server-side, so its tasks — including the '
          'one added late — went with it in the cascade',
    );
    expect(
      await eng.store.findTaskAny('T2'),
      isNull,
      reason: 'the remote-born row never lands as a local orphan',
    );
    expect(await eng.store.findTaskAny('T1'), isNull);

    out = await eng.run();
    expect((out.pushed, out.deleted, out.errors), (0, 0, 0), reason: 'P7');
  });

  test('a_pending_list_delete_hides_the_list_while_the_push_retries', () async {
    // §I × remote added tasks, non-happy path: the delete push hits a transient,
    // so the tombstone survives a whole run in which the pull still sees the list
    // AND the task added to it remotely. Neither may come back: `all_lists`
    // (what the sidebar and every smart view iterate over) must not show the
    // list, so nothing it holds is reachable.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
    await seedSyncedList(client, eng.store, 'L2', 'Doomed');
    await eng.run();

    await tombstoneList(eng, 'L2');
    client.seedTask('L2', 'T2', 'added elsewhere', '1');
    client.failNext(Method.deleteTasklist, () => const ServerError(503));

    var out = await eng.run();
    expect(out.errors, 0, reason: 'a transient is not an error');
    expect(await sidebar(eng), [
      'My Tasks',
    ], reason: 'the deleted list stays hidden while its delete retries');
    // Every task the UI can reach = the tasks of the lists it renders.
    final visible = <String>[];
    for (final l in await eng.store.allLists()) {
      for (final t in await eng.store.listTasks(l.list.id)) {
        visible.add(t.task.title);
      }
    }
    expect(
      visible,
      isEmpty,
      reason: 'nothing from the dying list is reachable: $visible',
    );

    // Next run: the retry lands and both sides converge.
    out = await eng.run();
    expect(out.errors, 0);
    expect(
      (await client.listTasklists()).every((l) => l.id != 'L2'),
      isTrue,
      reason: 'the delete finally lands',
    );
    expect(await eng.store.findTaskAny('T2'), isNull);
    out = await eng.run();
    expect((out.pushed, out.deleted, out.errors), (0, 0, 0), reason: 'P7');
  });

  test('a_list_delete_that_already_happened_remotely_is_a_success', () async {
    // §I × already deleted remotely. The 404 is the outcome we wanted, so it
    // clears the tombstone instead of counting an error or nagging on every
    // future run.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
    await seedSyncedList(client, eng.store, 'L2', 'Doomed');
    await eng.run();

    await tombstoneList(eng, 'L2');
    client.deleteListFromState('L2');

    var out = await eng.run();
    expect(out.errors, 0, reason: 'a 404 on a delete is success, not failure');
    expect(await sidebar(eng), ['My Tasks']);
    expect(
      (await eng.store.drainDirtyLists()).every((l) => l.list.id != 'L2'),
      isTrue,
      reason: 'no tombstone left to retry forever',
    );
    out = await eng.run();
    expect((out.pushed, out.deleted, out.errors), (0, 0, 0), reason: 'P7');
  });

  test('a_local_list_create_adopts_a_same_title_list_created_remotely', () async {
    // §I × remote created a list with the same title (the two-device "Groceries"
    // race, and the offline "My Tasks" bootstrap). The create adopts the remote
    // list instead of inserting a duplicate — and the tasks queued in the local
    // list follow it onto the adopted id, which is the part a plain id remap
    // could silently drop.
    final (client, eng) = await engine(push: true);
    // Deliberately untracked locally: adoption by title is what is under test.
    client.seedList('L-remote', 'Groceries');
    await eng.store.upsertList(dirtyList('local-list', 'Groceries', 'create'));
    await eng.store.upsertTask(
      dirtyTask('local-task', 'local-list', 'create', title: 'milk'),
    );

    var out = await eng.run();
    expect(out.errors, 0);
    expect(await sidebar(eng), ['Groceries'], reason: 'exactly one list');
    expect(
      (await client.listTasklists()).length,
      1,
      reason: 'no duplicate list was created on the server',
    );
    expect(
      (await eng.store.listTasks(
        'local-list',
      )).map((t) => t.task.title).toList(),
      ['milk'],
      reason: 'the queued task never moved — the list id it names is immutable',
    );
    expect(
      (await client.listTasks('L-remote')).items.any((t) => t.title == 'milk'),
      isTrue,
      reason: 'and it pushed into the adopted list, not a dead local id',
    );
    out = await eng.run();
    expect((out.pushed, out.errors), (0, 0), reason: 'converged (P7)');
  });
}
