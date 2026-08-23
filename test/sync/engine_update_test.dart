// Port of `sync/engine.rs`'s in-file tests — the T5.6 partition (MIGRATION-PLAN
// §5): the UPDATE / DELETE push paths, the 412 conflict path, the RFC-009
// §B (local content edit × remote) / §C (local complete × remote) / §D (local
// delete × remote) matrices, and the real-API-semantics group. The create pass,
// in-flight recovery and §G belong to T5.5 (engine_create_test.dart); the move
// drain, list sync and pull/ghost/D7 groups belong to T5.7/T5.8.
//
// These drive `run()` end to end against the fake server (which mirrors the
// verified live Google semantics), then assert the STATE both sides converge to
// — the rows the store returns and the tasks the fake holds — never which method
// the engine called. Each §B/§C/§D test is one row of the conflict matrix and
// asserts P4 (delete wins) / P3 (conflicted copy) / D1 / D8 as ratified in
// RFC-009. At least the transient-fetch, aborted-fetch, delete-race, oversize
// and unauthorized cases exercise the non-happy paths.

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
const _tEdit = '2026-06-02T00:00:00Z';

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

/// A dirty create row, matching the reference's `dirty_task` for the create op.
StoredTask dirtyCreate(
  String id,
  String listId, {
  String? parent,
  String? title,
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
  syncState: SyncState.dirty,
  localUpdated: localUpdated,
  pendingOp: 'create',
);

/// Stage a dirty content edit on an existing row the way the UI does: mutate
/// through [edit], mark dirty/update, advance local_updated; optionally stale
/// the etag so the push draws a 412.
Future<void> stageEdit(
  Store store,
  String id, {
  bool stale = false,
  required Task Function(Task) edit,
}) async {
  final row = (await findByAnyId(store, id))!;
  var task = edit(row.task);
  if (stale) task = task.copyWith(etag: 'stale');
  await store.upsertTask(
    StoredTask(
      task: task,
      listId: row.listId,
      syncState: SyncState.dirty,
      localUpdated: _tEdit,
      pendingOp: 'update',
    ),
  );
}

/// The completion edit — sets the checkbox and a completed stamp.
Task complete(Task t) =>
    t.copyWith(status: TaskStatus.completed, completed: _tEdit);

/// A tombstone as delete writes it: the row stays in the store, marked deleted
/// with a pending `delete`, until the push confirms.
Future<void> tombstone(Store store, String id) async {
  final row = (await findByAnyId(store, id))!;
  await store.upsertTask(
    StoredTask(
      task: row.task,
      listId: row.listId,
      syncState: SyncState.deleted,
      localUpdated: _tEdit,
      pendingOp: 'delete',
    ),
  );
}

/// Whether the row is gone from the server as the pull sees it — absent from
/// `list_tasks` (Google soft-deletes, so a by-id get would still 200).
Future<bool> remoteGone(FakeTasksApi client, String list, String id) async =>
    !(await client.listTasks(list)).items.any((t) => t.id == id);

/// The single visible row in [listId], failing if there isn't exactly one.
Future<StoredTask> soleRow(Store store, String listId) async {
  final rows = await store.listTasks(listId);
  expect(rows.length, 1, reason: 'expected exactly one row in $listId');
  return rows.first;
}

void main() {
  // ─── UPDATE push + 412 conflict path ───────────────────────────────────────

  test('push update clears dirty', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    final remote = client.seedTask('L1', 'T1', 'old', '1');
    await eng.run();

    await stageEdit(eng.store, 'T1', edit: (t) => t.copyWith(title: 'new'));
    // Current etag → the patch succeeds.
    final staged = (await findByAnyId(eng.store, 'T1'))!;
    await eng.store.upsertTask(
      StoredTask(
        task: staged.task.copyWith(etag: remote.etag),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: _tEdit,
        pendingOp: 'update',
      ),
    );

    final out = await eng.run();
    expect(out.pushed, 1);
    final row = await soleRow(eng.store, 'L1');
    expect(row.syncState, SyncState.clean);
    expect(row.task.title, 'new');
  });

  test('push update 412 real conflict preserves both', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'server-version', '1');
    await eng.run();

    // Another device edits the CONTENT to a third value — a genuine divergence
    // from the base, which forks a conflicted copy (P3).
    await client.patchTask('L1', 'T1', const TaskPatch(title: 'their-version'));

    await stageEdit(
      eng.store,
      'T1',
      stale: true,
      edit: (t) => t.copyWith(title: 'local-edit'),
    );

    final out = await eng.run();
    expect(out.conflicts, 1);

    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 2, reason: 'remote + conflicted copy');
    expect(
      tasks.any(
        (t) =>
            t.task.title == 'their-version' && t.syncState == SyncState.clean,
      ),
      isTrue,
    );
    expect(
      tasks.any((t) => t.task.title == 'local-edit (conflicted copy)'),
      isTrue,
    );
  });

  test('conflicted copy resolution is FK-safe when the remote parent is unknown '
      '(#155)', () async {
    // A 412 whose refetched canonical row names a parent this device has never
    // pulled — another device demoted the row under a brand-new parent while
    // we edited it — must NOT abort the run with a foreign-key violation. The
    // canonical landing detaches the unknown parent; the local edit survives
    // as its conflicted copy; every row keeps its parent tree intact. (The
    // reference isolates resolve_conflict to catch the pre-pull detach; driven
    // through the full run here, the follow-on pull re-links the row under the
    // now-pulled parent — the point this pins is that the run never aborts and
    // nothing is lost.)
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'server-version', '1');
    await eng.run();

    await stageEdit(
      eng.store,
      'T1',
      stale: true,
      edit: (t) => t.copyWith(title: 'local-edit'),
    );

    // Another device demotes T1 under a BRAND-NEW parent P2 and changes its
    // content — a real conflict against a parent absent locally.
    client.seedTask('L1', 'P2', 'foreign-parent', '0');
    await client.moveTask('L1', 'T1', parent: 'P2');
    await client.patchTask('L1', 'T1', const TaskPatch(title: 'their-version'));

    final out = await eng.run();
    expect(out.conflicts, 1);

    final tasks = await eng.store.listTasks('L1');
    final canonical = tasks.firstWhere((t) => serverId(t) == 'T1');
    expect(canonical.task.title, 'their-version');
    expect(canonical.syncState, SyncState.clean);
    expect(
      tasks.any((t) => t.task.title == 'local-edit (conflicted copy)'),
      isTrue,
      reason: 'the local edit survives as a conflicted copy',
    );
    // No child points at a parent that isn't in the store (invariant #3/#4).
    final ids = {for (final t in tasks) t.task.id};
    for (final t in tasks) {
      final p = t.task.parent;
      if (p != null) {
        expect(ids.contains(p), isTrue, reason: '${t.task.id} → missing $p');
      }
    }
  });

  test('push update 412 identical edit makes no copy', () async {
    // The server already has the same content we tried to write — adopt the
    // remote etag, create no copy.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'same-title', '1');
    await eng.run();

    // Same content, stale etag → a 412 that resolves without divergence.
    await stageEdit(eng.store, 'T1', stale: true, edit: (t) => t);

    final out = await eng.run();
    expect(out.conflicts, 0, reason: 'identical content is not a conflict');
    final row = await soleRow(eng.store, 'L1');
    expect(row.syncState, SyncState.clean);
  });

  test('lost patch response self-content 412 converges with no copy', () async {
    // The at-least-once PATCH hazard through the REAL lost-response fault: the
    // server APPLIES the patch (new content + etag) then the response is lost.
    // Our row keeps its stale etag and stays dirty, so the retry meets a 412
    // whose remote already carries OUR OWN edit — it converges by adopting the
    // etag, no conflicted copy (#118/#132).
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'old', '1');
    await eng.run();

    await stageEdit(eng.store, 'T1', edit: (t) => t.copyWith(title: 'renamed'));

    client.commitThenFailNext(Method.patchTask);
    final out1 = await eng.run();

    final server = await client.getTask('L1', 'T1');
    expect(
      server.title,
      'renamed',
      reason: 'the server applied the lost patch',
    );
    final mid = (await findByAnyId(eng.store, 'T1'))!;
    expect(out1.pushed, 0, reason: 'a lost response is not a successful push');
    expect(mid.syncState, SyncState.dirty, reason: 'row stays dirty to retry');
    expect(
      await eng.store.baseSnapshot(await localIdOf(eng.store, 'T1')),
      isNotNull,
    );

    final getsBefore = client.callCount(Method.getTask);
    final out2 = await eng.run();
    expect(
      client.callCount(Method.getTask) > getsBefore,
      isTrue,
      reason: 'the 412 forced a conflict refetch',
    );
    expect(out2.conflicts, 0, reason: 'a self-content 412 makes no copy');

    final row = await soleRow(eng.store, 'L1');
    expect(row.task.title, 'renamed', reason: 'the edit survived');
    expect(row.syncState, SyncState.clean);
    expect(row.task.etag, server.etag, reason: 'adopted the remote etag (P6)');
    expect(
      await eng.store.baseSnapshot(await localIdOf(eng.store, 'T1')),
      isNull,
    );
  });

  test('push update 412 transient get stays dirty then resolves', () async {
    // A 412 sends us to fetch the authoritative remote copy; that GET fails
    // transiently. We must NOT lose the edit, NOT fork a copy, NOT count a
    // conflict — the row stays dirty and the next run resolves it.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'server-version', '1');
    await eng.run();

    await client.patchTask('L1', 'T1', const TaskPatch(title: 'their-version'));
    await stageEdit(
      eng.store,
      'T1',
      stale: true,
      edit: (t) => t.copyWith(title: 'local-edit'),
    );

    client.failNext(Method.getTask, () => const ServerError(503));

    final out = await eng.run();
    expect(out.conflicts, 0, reason: 'a failed fetch is not a resolution');
    final row = await soleRow(eng.store, 'L1');
    expect(row.task.title, 'local-edit');
    expect(row.syncState, SyncState.dirty);
    expect(row.pendingOp, 'update');

    final out2 = await eng.run();
    expect(out2.conflicts, 1, reason: 'retry resolves the deferred conflict');
    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 2);
    expect(
      tasks.any(
        (t) =>
            t.task.title == 'their-version' && t.syncState == SyncState.clean,
      ),
      isTrue,
    );
    expect(
      tasks.any((t) => t.task.title == 'local-edit (conflicted copy)'),
      isTrue,
    );
  });

  test(
    'push update 412 non-transient get aborts, preserving the edit',
    () async {
      // A conflict-fetch GET that fails NON-transiently aborts the run — the
      // caller can't decide the conflict without the remote copy. The local edit
      // must survive untouched: no clean, no copy, no lost data.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'server-version', '1');
      await eng.run();

      await stageEdit(
        eng.store,
        'T1',
        stale: true,
        edit: (t) => t.copyWith(title: 'local-edit'),
      );

      client.failNext(Method.getTask, () => const OtherApiError('boom'));

      await expectLater(
        eng.run(),
        throwsA(
          isA<SyncApiError>().having(
            (e) => e.error,
            'error',
            isA<OtherApiError>(),
          ),
        ),
      );

      final row = await soleRow(eng.store, 'L1');
      expect(row.task.title, 'local-edit', reason: 'local edit preserved');
      expect(row.syncState, SyncState.dirty);
      expect(row.pendingOp, 'update');
      expect(
        (await eng.store.listTasks(
          'L1',
        )).any((t) => t.task.title.endsWith('(conflicted copy)')),
        isFalse,
      );
    },
  );

  test('conflicted copy pushes then converges', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'server', '1');
    await eng.run();

    await client.patchTask('L1', 'T1', const TaskPatch(title: 'their-edit'));

    await stageEdit(
      eng.store,
      'T1',
      stale: true,
      edit: (t) => t.copyWith(title: 'conflict'),
    );

    await eng.run(); // resolves: canonical + conflicted copy (dirty create)
    final out2 = await eng.run(); // pushes the conflicted copy
    expect(out2.pushed >= 1, isTrue);
    final out3 = await eng.run(); // converged
    expect(out3.conflicts, 0);
    expect(out3.pushed, 0);

    final tasks = await eng.store.listTasks('L1');
    expect(tasks.every((t) => t.syncState == SyncState.clean), isTrue);
    expect(
      tasks.any((t) => t.task.title == 'conflict (conflicted copy)'),
      isTrue,
    );
  });

  test('push update into a remotely-deleted list deletes local', () async {
    // The one way a task PATCH still 404s now the fake soft-deletes tasks: the
    // row's whole LIST vanished. A real permanent NotFound → delete wins (P4).
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'doomed', '1');
    await eng.run();

    await stageEdit(eng.store, 'T1', edit: (t) => t.copyWith(title: 'edit'));
    client.deleteListFromState('L1');

    final out = await eng.run();
    expect(out.errors, 0, reason: 'a remote delete is not a sync error');
    expect(out.conflicts, 0);
    expect(
      (await eng.store.listTasks('L1')).any((t) => serverId(t) == 'T1'),
      isFalse,
    );
  });

  // ─── RFC-009 §B: local content edit × remote ───────────────────────────────

  test('§B edit vs remote move fabricates no conflicted copy', () async {
    // A remote MOVE bumps the etag so an unrelated push 412s; the content
    // comparison (title/notes/due/status, never position/parent) keeps that
    // from manufacturing a duplicate. Here the same rename landed remotely,
    // which then reordered the task — content matches, only position moved.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'old', '1');
    client.seedTask('L1', 'T2', 'anchor', '2');
    await eng.run();

    await client.patchTask('L1', 'T1', const TaskPatch(title: 'renamed'));
    await client.moveTask('L1', 'T1', previous: 'T2');
    final remote = await client.getTask('L1', 'T1');

    await stageEdit(
      eng.store,
      'T1',
      stale: true,
      edit: (t) => t.copyWith(title: 'renamed'),
    );

    final out = await eng.run();
    expect(out.conflicts, 0, reason: 'a remote MOVE is not a content conflict');

    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 2);
    expect(
      tasks.any((t) => t.task.title.endsWith('(conflicted copy)')),
      isFalse,
    );
    final t1 = tasks.firstWhere((t) => serverId(t) == 'T1');
    expect(t1.syncState, SyncState.clean);
    expect(t1.task.title, 'renamed');
    expect(t1.task.position, remote.position, reason: 'remote order adopted');
    expect(t1.task.etag, remote.etag);
  });

  test(
    '§B edit vs remote delete discards the edit and the row disappears',
    () async {
      // P4: delete wins, no copy. The fake soft-deletes, so the pending edit's
      // PATCH lands 200-but-ignored and ghost detection on the pull removes it —
      // exactly the live path.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'exists', '1');
      await eng.run();

      client.deleteTaskFromState('L1', 'T1');
      await stageEdit(
        eng.store,
        'T1',
        edit: (t) => t.copyWith(title: 'edited'),
      );

      final out = await eng.run();
      expect(out.errors, 0);
      expect(out.conflicts, 0, reason: 'delete/edit never forks a copy');
      expect(await eng.store.listTasks('L1'), isEmpty);
    },
  );

  test(
    '§B edit 412 then refetch tombstone: delete wins, no resurrected copy',
    () async {
      // The 412×delete race (#141): our PATCH 412'd, and before the refetch
      // another client deleted the row. The refetch is a soft-delete tombstone
      // (200, deleted:true) — carried through, it is P4 delete-wins, not a
      // resurrected/forked copy.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'exists', '1');
      await eng.run();

      client.deleteTaskFromState('L1', 'T1');
      await stageEdit(
        eng.store,
        'T1',
        edit: (t) => t.copyWith(title: 'edited'),
      );
      client.failNext(Method.patchTask, () => const PreconditionFailed());

      final out = await eng.run();
      expect(out.errors, 0);
      expect(out.conflicts, 0, reason: 'delete×edit never forks a copy');
      expect(await eng.store.listTasks('L1'), isEmpty);

      final out2 = await eng.run();
      expect(out2.conflicts, 0);
      expect(await eng.store.listTasks('L1'), isEmpty);
    },
  );

  test('§B edit vs remote parent-cascade delete discards the edit', () async {
    // Another client deleted the PARENT, whose delete cascades to the subtask
    // we were editing. Same outcome as a direct delete — the edit dies with the
    // row (P4), nothing stranded behind a dead parent.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '1');
    client.seedTaskWithParent('L1', 'C', 'child', '2', 'P');
    await eng.run();

    await client.deleteTask('L1', 'P');
    await stageEdit(eng.store, 'C', edit: (t) => t.copyWith(title: 'my edit'));

    final out = await eng.run();
    expect(out.errors, 0);
    expect(out.conflicts, 0);
    expect(await eng.store.listTasks('L1'), isEmpty);
  });

  test(
    '§B×due 412 with only a due-format difference is not a conflict',
    () async {
      // Local stores "…T00:00:00Z", the server echoes "…T00:00:00.000Z". Same
      // date — a raw string compare manufactured a phantom copy.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'same', '1');
      await eng.run();

      final patched = await client.patchTask(
        'L1',
        'T1',
        const TaskPatch(due: '2026-08-01T00:00:00.000Z'),
      );

      await stageEdit(
        eng.store,
        'T1',
        edit: (t) => t.copyWith(due: '2026-08-01T00:00:00Z'),
      );

      final out = await eng.run();
      expect(
        out.conflicts,
        0,
        reason: 'identical content must not fork a copy',
      );
      final row = await soleRow(eng.store, 'L1');
      expect(row.syncState, SyncState.clean);
      expect(row.task.etag, patched.etag);
    },
  );

  // ─── RFC-009 §C: local complete / un-complete × remote ─────────────────────

  test('§C complete vs remote edit produces a conflicted copy', () async {
    // Title AND status diverge, so P3 applies — remote canonical, local state
    // survives as a copy. Guards that D1 stayed narrow.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'buy milk', '1');
    await eng.run();

    await client.patchTask('L1', 'T1', const TaskPatch(title: 'buy oat milk'));
    await stageEdit(eng.store, 'T1', stale: true, edit: complete);

    final out = await eng.run();
    expect(out.conflicts, 1);

    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 2);
    final canonical = tasks.firstWhere((t) => serverId(t) == 'T1');
    expect(canonical.task.title, 'buy oat milk');
    expect(canonical.task.status, TaskStatus.needsAction);
    expect(canonical.syncState, SyncState.clean);
    final copy = tasks.firstWhere(
      (t) => t.task.title == 'buy milk (conflicted copy)',
    );
    expect(copy.task.status, TaskStatus.completed);
  });

  test('§C status-only divergence resolves remote-wins, no copy (D1)', () async {
    // Title/notes/due all agree, only the checkbox differs — remote wins
    // outright. Another device completed the task while the user ended back at
    // open; our push 412s on the stale etag.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'buy milk', '1');
    await eng.run();

    await client.patchTask(
      'L1',
      'T1',
      const TaskPatch(status: TaskStatus.completed),
    );
    final remote = await client.getTask('L1', 'T1');
    await stageEdit(
      eng.store,
      'T1',
      stale: true,
      edit: (t) => t.copyWith(status: TaskStatus.needsAction, completed: null),
    );

    final out = await eng.run();
    expect(out.conflicts, 0, reason: 'a status-only difference is not a fork');

    final row = await soleRow(eng.store, 'L1');
    expect(row.task.title, 'buy milk');
    expect(row.task.status, TaskStatus.completed, reason: 'remote wins');
    expect(row.syncState, SyncState.clean);
    expect(row.task.etag, remote.etag);

    final out2 = await eng.run();
    expect(out2.pushed, 0);
    expect(out2.conflicts, 0);
  });

  test('§C D8 status-only toggle survives a bare remote reorder', () async {
    // The user completed a task offline; another device MERELY REORDERED the
    // list (etag bumped, checkbox untouched). The base proves the remote never
    // moved the status, so the local completion WINS: the row stays dirty and
    // re-pushes instead of being reverted (the pre-D8 bug, #132).
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'buy milk', '1');
    client.seedTask('L1', 'T2', 'anchor', '2');
    await eng.run();

    await stageEdit(eng.store, 'T1', stale: true, edit: complete);

    await client.moveTask('L1', 'T1', previous: 'T2');
    final remote = await client.getTask('L1', 'T1');
    expect(remote.status, TaskStatus.needsAction);

    final out = await eng.run();
    expect(
      out.conflicts,
      0,
      reason: 'a bare reorder is not a content conflict',
    );

    final tasks = await eng.store.listTasks('L1');
    expect(
      tasks.any((t) => t.task.title.endsWith('(conflicted copy)')),
      isFalse,
    );
    final t1 = tasks.firstWhere((t) => serverId(t) == 'T1');
    expect(
      t1.task.status,
      TaskStatus.completed,
      reason: 'local completion wins',
    );
    expect(t1.syncState, SyncState.dirty, reason: 'stays dirty to re-push');
    expect(t1.task.etag, remote.etag);

    final out2 = await eng.run();
    expect(out2.conflicts, 0);
    final remote2 = await client.getTask('L1', 'T1');
    expect(remote2.status, TaskStatus.completed);
    final t1b = (await findByAnyId(eng.store, 'T1'))!;
    expect(t1b.syncState, SyncState.clean, reason: 'converged');
  });

  test(
    '§B+§C D8 rename and completion both survive a bare remote reorder',
    () async {
      // The user renamed AND completed offline; another device merely reordered.
      // The base proves the remote changed neither, so BOTH local edits win — the
      // rename (as #118 always did) and the completion (D8).
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'buy milk', '1');
      client.seedTask('L1', 'T2', 'anchor', '2');
      await eng.run();

      await stageEdit(
        eng.store,
        'T1',
        stale: true,
        edit: (t) => complete(t.copyWith(title: 'buy oat milk')),
      );

      await client.moveTask('L1', 'T1', previous: 'T2');
      final remote = await client.getTask('L1', 'T1');

      final out = await eng.run();
      expect(out.conflicts, 0);

      final tasks = await eng.store.listTasks('L1');
      expect(
        tasks.any((t) => t.task.title.endsWith('(conflicted copy)')),
        isFalse,
      );
      final t1 = tasks.firstWhere((t) => serverId(t) == 'T1');
      expect(t1.task.title, 'buy oat milk', reason: 'local rename wins (#118)');
      expect(
        t1.task.status,
        TaskStatus.completed,
        reason: 'local completion (D8)',
      );
      expect(t1.syncState, SyncState.dirty);
      expect(t1.task.etag, remote.etag);

      final out2 = await eng.run();
      expect(out2.conflicts, 0);
      final remote2 = await client.getTask('L1', 'T1');
      expect(remote2.title, 'buy oat milk');
      expect(remote2.status, TaskStatus.completed);
      final t1b = (await findByAnyId(eng.store, 'T1'))!;
      expect(t1b.syncState, SyncState.clean);
    },
  );

  test('§C complete vs remote delete: the row is gone', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'buy milk', '1');
    await eng.run();

    client.deleteTaskFromState('L1', 'T1');
    await stageEdit(eng.store, 'T1', edit: complete);

    final out = await eng.run();
    expect(out.errors, 0);
    expect(out.conflicts, 0);
    expect(await eng.store.listTasks('L1'), isEmpty);
  });

  test(
    '§B×deleted push update of a soft-deleted task converges via ghost',
    () async {
      // The row was soft-deleted remotely, so the edit's PATCH lands 200-ignored
      // (never a 404); the pull's ghost detection removes it. No error, no copy,
      // edit discarded (P4).
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      final remote = client.seedTask('L1', 'T1', 'exists', '1');
      await eng.run();

      client.deleteTaskFromState('L1', 'T1');
      await stageEdit(
        eng.store,
        'T1',
        edit: (t) => t.copyWith(title: 'edited', etag: remote.etag),
      );

      final out = await eng.run();
      expect(out.errors, 0);
      expect(out.conflicts, 0);
      expect(await eng.store.listTasks('L1'), isEmpty);
    },
  );

  // ─── RFC-009 §D: local delete × remote (delete wins, P4, never a copy) ──────

  test('§D delete vs remote edit: delete wins', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'doomed', '1');
    await eng.run();

    await client.patchTask(
      'L1',
      'T1',
      const TaskPatch(title: 'renamed elsewhere', notes: 'and annotated'),
    );
    await tombstone(eng.store, 'T1');

    final out = await eng.run();
    expect(out.deleted, 1);
    expect(out.errors, 0, reason: 'a stale etag cannot block a delete');
    expect(out.conflicts, 0);
    expect(await eng.store.listTasks('L1'), isEmpty);
    expect(await remoteGone(client, 'L1', 'T1'), isTrue);

    final out2 = await eng.run();
    expect(out2.deleted, 0);
    expect(await eng.store.listTasks('L1'), isEmpty);
  });

  test(
    '§D delete vs remote status change: delete wins both directions',
    () async {
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'T1', 'will be completed remotely', '1');
      client.seedTask('L1', 'T2', 'will be reopened remotely', '2');
      await client.patchTask(
        'L1',
        'T2',
        const TaskPatch(status: TaskStatus.completed),
      );
      await eng.run();

      await client.patchTask(
        'L1',
        'T1',
        const TaskPatch(status: TaskStatus.completed),
      );
      await client.patchTask(
        'L1',
        'T2',
        const TaskPatch(status: TaskStatus.needsAction),
      );
      await tombstone(eng.store, 'T1');
      await tombstone(eng.store, 'T2');

      final out = await eng.run();
      expect(out.deleted, 2);
      expect(out.errors, 0);
      expect(out.conflicts, 0);
      expect(await eng.store.listTasks('L1'), isEmpty);
      expect(await remoteGone(client, 'L1', 'T1'), isTrue);
      expect(await remoteGone(client, 'L1', 'T2'), isTrue);
    },
  );

  test('§D delete vs remote move and reparent: delete wins', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'keeper', '1');
    client.seedTask('L1', 'T1', 'doomed', '2');
    client.seedTask('L1', 'T2', 'reordered', '3');
    await eng.run();

    await client.moveTask('L1', 'T1', parent: 'P');
    await client.moveTask('L1', 'T2');
    await tombstone(eng.store, 'T1');
    await tombstone(eng.store, 'T2');

    final out = await eng.run();
    expect(out.deleted, 2);
    expect(out.errors, 0);

    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 1);
    expect(serverId(tasks.single), 'P');
    expect(tasks.single.task.title, 'keeper');
    expect(tasks.single.syncState, SyncState.clean);
    expect(await remoteGone(client, 'L1', 'T1'), isTrue);
    expect(await remoteGone(client, 'L1', 'T2'), isTrue);
  });

  test('§D delete parent takes a remote-born subtask with it', () async {
    // A subtask born on another device that we never pulled: our local cascade
    // can't reach it, but Google's DELETE cascade does. P4 + cascade means the
    // remote-born child dies too and never surfaces locally as an orphan.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '1');
    await eng.run();

    client.seedTaskWithParent('L1', 'C-remote', 'their kid', '2', 'P');
    await tombstone(eng.store, 'P');

    final out = await eng.run();
    expect(out.deleted, 1);
    expect(out.errors, 0);
    expect(await eng.store.listTasks('L1'), isEmpty);
    expect(await remoteGone(client, 'L1', 'P'), isTrue);
    expect(await remoteGone(client, 'L1', 'C-remote'), isTrue);
  });

  test('§D delete subtask vs remote edit leaves the parent intact', () async {
    // Deleting a subtask must never cascade upward or dirty the parent.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '1');
    client.seedTaskWithParent('L1', 'C1', 'kid', '2', 'P');
    client.seedTaskWithParent('L1', 'C2', 'sibling', '3', 'P');
    await eng.run();
    final parentEtag = (await findByAnyId(eng.store, 'P'))!.task.etag;

    await client.patchTask(
      'L1',
      'C1',
      const TaskPatch(title: 'renamed elsewhere'),
    );
    await tombstone(eng.store, 'C1');

    final out = await eng.run();
    expect(out.deleted, 1);
    expect(out.errors, 0);
    expect(out.conflicts, 0);

    final tasks = await eng.store.listTasks('L1');
    expect(tasks.map(serverId).toList(), ['P', 'C2']);
    final parent = tasks.firstWhere((t) => serverId(t) == 'P');
    expect(parent.task.title, 'parent');
    expect(parent.syncState, SyncState.clean, reason: 'parent not dirtied');
    expect(parent.task.etag, parentEtag, reason: 'parent untouched (P6)');
    final sibling = tasks.firstWhere((t) => serverId(t) == 'C2');
    expect(await parentServerId(eng.store, sibling), 'P');
    expect(await remoteGone(client, 'L1', 'C1'), isTrue);
  });

  test('§D delete parent with an unpushed child converges', () async {
    // The user adds a subtask and deletes its parent before either reaches the
    // server. Creates push first: the child is inserted then removed by the
    // parent's cascade. Both sides converge, nothing left dirty, no child
    // stranded under a dead parent id (invariant #3; P2 doesn't shield against
    // the user's own delete).
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '1');
    await eng.run();

    await eng.store.upsertTask(
      dirtyCreate('local-kid', 'L1', parent: await localIdOf(eng.store, 'P')),
    );
    await tombstone(eng.store, 'P');

    final out = await eng.run();
    expect(out.errors, 0);
    expect(await eng.store.listTasks('L1'), isEmpty);
    expect(await remoteGone(client, 'L1', 'P'), isTrue);
    expect((await client.listTasks('L1')).items, isEmpty);
    expect(await eng.store.drainDirty(), isEmpty);

    final out2 = await eng.run();
    expect(out2.errors, 0);
    expect(out2.pushed, 0);
    expect(await eng.store.listTasks('L1'), isEmpty);
  });

  test('push delete removes local', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'doomed', '1');
    await eng.run();

    await tombstone(eng.store, 'T1');
    final out = await eng.run();
    expect(out.deleted, 1);
    expect(await eng.store.listTasks('L1'), isEmpty);
  });

  test('push delete transient leaves the tombstone', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'doomed', '1');
    await eng.run();

    await tombstone(eng.store, 'T1');
    client.failNext(Method.deleteTask, () => const ServerError(503));

    final out = await eng.run();
    expect(out.deleted, 0);
    expect((await eng.store.drainDirty()).length, 1);
  });

  test('push delete 404 hard-deletes local without error', () async {
    // Row already gone on the server: a 404 on delete is a SUCCESS — the local
    // tombstone is hard-deleted, counted, zero errors, and no pull resurrects.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'already gone on server', '1');
    await eng.run();

    await tombstone(eng.store, 'T1');
    client.deleteTaskFromState('L1', 'T1');

    final out = await eng.run();
    expect(
      out.deleted,
      1,
      reason: '404-on-delete counts as a completed delete',
    );
    expect(out.errors, 0);
    expect(await eng.store.listTasks('L1'), isEmpty);
  });

  // ─── Real-API semantics (verified live) ────────────────────────────────────

  test('unauthorized aborts the run, leaving rows dirty', () async {
    // A 401 fails every call the same way this run — abort on first sight
    // instead of grinding row-by-row and mis-counting each as a rejection.
    // Nothing lost: rows stay dirty and push after re-auth.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(
      dirtyCreate('local-a', 'L1', localUpdated: '2026-06-01T00:00:00Z'),
    );
    await eng.store.upsertTask(
      dirtyCreate('local-b', 'L1', localUpdated: '2026-06-01T00:00:01Z'),
    );
    client.failNext(Method.insertTask, () => const Unauthorized());

    await expectLater(
      eng.run(),
      throwsA(
        isA<SyncApiError>().having(
          (e) => e.error,
          'error',
          isA<Unauthorized>(),
        ),
      ),
    );
    expect(
      client.callCount(Method.insertTask),
      1,
      reason: 'aborted after the first failing call, not once per row',
    );
    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 2);
    expect(tasks.every((t) => t.syncState == SyncState.dirty), isTrue);
  });

  test('push to an unknown list is counted, not fatal', () async {
    // A permanently-rejected row must not abort the run — it stays dirty (and
    // keeps being reported) while everything else keeps syncing.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertList(
      StoredTaskList(
        list: TaskList(
          id: 'ghost-list',
          title: 'Local',
          updated: '2026-01-01T00:00:00Z',
        ),
        syncState: SyncState.dirty,
        localUpdated: '2026-01-01T00:00:00Z',
        // The server acknowledged this list once and no longer has it, so the
        // insert really goes out and really 404s (#224: without a remote id
        // there would be nothing to name, and the row would simply wait).
        remoteId: 'ghost-list',
      ),
    );
    await eng.store.upsertTask(dirtyCreate('local-1', 'ghost-list'));
    await eng.store.upsertTask(dirtyCreate('local-2', 'L1'));

    final out = await eng.run();
    expect(out.errors, 1, reason: 'rejected row is counted');
    expect(out.pushed >= 1, isTrue, reason: 'healthy row still pushed');
    expect(
      (await eng.store.drainDirty()).any((t) => serverId(t) == 'local-1'),
      isTrue,
    );
    expect(
      (await eng.store.listTasks(
        'L1',
      )).every((t) => t.syncState == SyncState.clean),
      isTrue,
    );
  });

  test('oversize field push is rejected every run and never wedges', () async {
    // #146: a permanently-rejected push (a note past Google's 8192-char limit)
    // is a 400 → reject: counted, row stays dirty, run continues, re-attempted
    // once per run forever — no give-up state, never a wedge of healthy rows.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    final big = dirtyCreate(
      'local-big',
      'L1',
      localUpdated: '2026-06-01T00:00:00Z',
    );
    await eng.store.upsertTask(
      StoredTask(
        task: big.task.copyWith(notes: 'x' * 8193),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: '2026-06-01T00:00:00Z',
        pendingOp: 'create',
      ),
    );
    await eng.store.upsertTask(
      dirtyCreate('local-ok', 'L1', localUpdated: '2026-06-01T00:00:01Z'),
    );

    final out = await eng.run();
    expect(out.errors, 1, reason: 'oversize create counted as a rejection');
    expect(out.pushed >= 1, isTrue, reason: 'the healthy row still pushed');

    final insertsAfterFirst = client.callCount(Method.insertTask);
    for (var i = 0; i < 3; i++) {
      final o = await eng.run();
      expect(o.errors, 1, reason: 'still rejected, every run');
      expect(o.pushed, 0, reason: 'no healthy work left');
    }
    expect(
      client.callCount(Method.insertTask),
      insertsAfterFirst + 3,
      reason: 'the oversize row is re-attempted once per run',
    );

    final tasks = await eng.store.listTasks('L1');
    final bigRow = tasks.firstWhere((t) => serverId(t) == 'local-big');
    expect(bigRow.syncState, SyncState.dirty);
    expect(
      tasks
          .where((t) => serverId(t) != 'local-big')
          .every((t) => t.syncState == SyncState.clean),
      isTrue,
    );
  });

  test('a poisoned row does not starve other pushes or the pull', () async {
    // One permanently-rejected row: everything else must still push, and the
    // pull must still run.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    // Another device already has a task waiting to be pulled.
    client.seedTask('L1', 'remote-1', 'from server', '9');
    await eng.run();

    await eng.store.upsertList(
      StoredTaskList(
        list: TaskList(
          id: 'ghost-list',
          title: 'Local',
          updated: '2026-01-01T00:00:00Z',
        ),
        syncState: SyncState.dirty,
        localUpdated: '2026-01-01T00:00:00Z',
        // Acknowledged once, gone from the server now — so the insert really
        // goes out and really 404s (#224).
        remoteId: 'ghost-list',
      ),
    );
    await eng.store.upsertTask(
      dirtyCreate('local-poison', 'ghost-list', localUpdated: _t0),
    );
    await eng.store.upsertTask(
      dirtyCreate('local-ok', 'L1', localUpdated: '2026-06-01T00:00:01Z'),
    );

    final out = await eng.run();
    expect(out.errors, 1, reason: 'the poisoned row is counted');
    expect(out.pushed >= 1, isTrue, reason: 'the healthy row still pushed');
    // The pull still ran: the remote task landed locally.
    expect((await findByAnyId(eng.store, 'remote-1')), isNotNull);
  });

  test('push multiple edits coalesce into the last', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    final remote = client.seedTask('L1', 'T1', 'original', '1');
    await eng.run();

    await stageEdit(
      eng.store,
      'T1',
      edit: (t) => t.copyWith(title: 'final-edit', etag: remote.etag),
    );

    final out = await eng.run();
    expect(out.pushed, 1);
    expect((await client.listTasks('L1')).items.first.title, 'final-edit');
  });

  test('a bare due date on update is normalized, not rejected', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    final remote = client.seedTask('L1', 'T1', 'task', '1');
    await eng.run();

    await stageEdit(
      eng.store,
      'T1',
      edit: (t) => t.copyWith(due: '2026-08-05', etag: remote.etag),
    );

    final out = await eng.run();
    expect(out.errors, 0);
    expect(out.pushed, 1);
    expect(
      (await client.listTasks('L1')).items.first.due,
      '2026-08-05T00:00:00.000Z',
    );
  });

  test('clearing a due date pushes successfully', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'dated', '1');
    await eng.run();

    await stageEdit(eng.store, 'T1', edit: (t) => t.copyWith(due: null));

    final out = await eng.run();
    expect(out.errors, 0);
    expect(out.pushed, 1);
    expect((await client.listTasks('L1')).items.first.due, isNull);
    expect((await soleRow(eng.store, 'L1')).syncState, SyncState.clean);
  });
}
