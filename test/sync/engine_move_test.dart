// Port of `sync/engine.rs`'s in-file tests — the T5.7 Move partition
// (MIGRATION-PLAN §5): the pending-move drain (push_move_*) and the RFC-009
// §E/§F matrix (local reorder / demote / promote × remote). The create pass,
// in-flight recovery and §G belong to T5.5; the UPDATE/DELETE/412/§B/§C/§D
// group to T5.6; list sync / §I to T5.7 (engine_list_test.dart); the D7
// residual-third-level group and pull/ghost/§A to T5.8.
//
// Moves are last-writer-wins by construction — the move endpoint takes no etag,
// so there is nothing to 412 on — and every §E/§F row's expected outcome is P5:
// degrade, never wedge. No row may end with a retry that never stops, a deleted
// task, an aborted run, or a local view that has silently drifted from the
// server. These drive `run()` end to end against the fake (which mirrors the
// verified live Google semantics) and assert the end state on BOTH sides — the
// rows `eng.store` returns AND the tasks the fake holds — and, where ordering is
// the point, that the two agree row for row.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_fixture.dart';

const _t0 = '2026-06-01T00:00:00Z';
const _tMove = '2026-06-02T00:00:00Z';

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

/// A dirty row for a given pending op, mirroring the reference's `dirty_task`.
StoredTask dirtyTask(String id, String listId, String op) => StoredTask(
  task: Task(
    id: id,
    position: '1',
    title: 'task $id',
    status: TaskStatus.needsAction,
    updated: _t0,
  ),
  listId: listId,
  syncState: op == 'delete' ? SyncState.deleted : SyncState.dirty,
  localUpdated: _t0,
  pendingOp: op,
);

/// Apply a move the way `move_task` (the command) does: the local row takes the
/// new parent/position immediately AND a pending move is recorded for the push.
/// Tests that skip the optimistic half would never see the drift a dropped
/// intent leaves behind. The row's sync_state and pending_op are preserved (a
/// move is orthogonal to any content edit already staged on the row).
Future<void> localMove(
  SyncEngine eng,
  String id, {
  String? parent,
  String? previous,
}) async {
  final row = (await findByAnyId(eng.store, id))!;
  // The store's own links are LOCAL ids (#224); the tests name server ids.
  final localParent = parent == null
      ? null
      : await localIdOf(eng.store, parent);
  final localPrevious = previous == null
      ? null
      : await localIdOf(eng.store, previous);
  final position = previous != null ? 'after-$previous' : '00000000000001';
  // Rebuild the Task explicitly: copyWith cannot clear `parent` to null, which
  // the promote/detach cases need.
  final task = Task(
    id: row.task.id,
    parent: localParent,
    position: position,
    title: row.task.title,
    notes: row.task.notes,
    status: row.task.status,
    due: row.task.due,
    completed: row.task.completed,
    etag: row.task.etag,
    updated: row.task.updated,
    webViewLink: row.task.webViewLink,
    deleted: row.task.deleted,
  );
  await eng.store.upsertTask(
    StoredTask(
      task: task,
      listId: row.listId,
      syncState: row.syncState,
      localUpdated: _tMove,
      pendingOp: row.pendingOp,
      remoteId: row.remoteId,
    ),
  );
  await eng.store.recordMove(
    row.task.id,
    row.listId,
    localParent,
    localPrevious,
  );
}

/// Top-level task ids in the order the server would render them.
Future<List<String>> remoteOrder(FakeTasksApi client, String list) async {
  final page = await client.listTasks(list);
  return [
    for (final t in page.items)
      if (t.parent == null) t.id,
  ];
}

/// Top-level task ids in the order the list view renders them (invariant #1:
/// only top-level rows are ever rendered as list rows).
Future<List<String>> localOrder(SyncEngine eng, String list) async {
  final rows = await eng.store.listTasks(list);
  return [
    for (final r in rows)
      if (r.task.parent == null) serverId(r),
  ];
}

/// The parent of a task as the server currently holds it.
Future<String?> remoteParent(
  FakeTasksApi client,
  String list,
  String id,
) async => (await client.getTask(list, id)).parent;

/// Invariant #1, asserted over the whole store: no row may have a grandparent.
/// Google stores a third level happily (probe 3) — this is the check that proves
/// we never asked it to.
Future<void> assertAtMostOneLevel(SyncEngine eng, String list) async {
  final rows = await eng.store.listTasks(list);
  for (final r in rows) {
    final p = r.task.parent;
    if (p == null) continue;
    StoredTask? parent;
    for (final x in rows) {
      if (x.task.id == p) {
        parent = x;
        break;
      }
    }
    expect(
      parent == null || parent.task.parent == null,
      isTrue,
      reason: '${r.task.id} is nested a third level under $p',
    );
  }
}

void main() {
  // ─── Move (reorder / reparent) ─────────────────────────────────────────────

  test('push move calls move api and clears', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'first', '1');
    client.seedTask('L1', 'T2', 'second', '2');
    await eng.run();

    // Record a move: T1 should follow T2.
    await recordServerMove(eng.store, 'T1', 'L1', null, 'T2');

    final out = await eng.run();
    expect(out.pushed >= 1, isTrue);
    expect(client.callCount(Method.moveTask), 1);
    // Pending move cleared after successful push.
    expect(await eng.store.pendingMoves(), isEmpty);
  });

  test('push move disabled when push off', () async {
    final (client, eng) = await engine(); // push disabled
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'task', '1');
    await eng.run();

    await recordServerMove(eng.store, 'T1', 'L1', null, 'X');
    await eng.run();

    expect(client.callCount(Method.moveTask), 0);
    // Move intent preserved for when push is enabled.
    expect((await eng.store.pendingMoves()).length, 1);
  });

  test('push move not found drops intent', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run(); // list now exists locally

    // A clean task that exists locally but the server doesn't know.
    final local = dirtyTask('ghost', 'L1', 'update');
    await eng.store.upsertTask(
      StoredTask(
        task: local.task.copyWith(etag: 'e1'),
        listId: 'L1',
        syncState: SyncState.clean,
        localUpdated: local.localUpdated,
        // The server acknowledged it once and no longer has it — that is what
        // makes the move go out and 404 (#224).
        remoteId: 'ghost',
      ),
    );
    await recordServerMove(eng.store, 'ghost', 'L1', null, null);

    final out = await eng.run();
    expect(out.pushed, 0);
    // Stale move dropped, not retried forever.
    expect(await eng.store.pendingMoves(), isEmpty);
  });

  test('push move transient retries', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'task', '1');
    client.seedTask('L1', 'T2', 'other', '2');
    await eng.run();

    await recordServerMove(eng.store, 'T1', 'L1', null, 'T2');
    client.failNext(Method.moveTask, () => const ServerError(503));

    await eng.run();
    // Move intent preserved for retry.
    expect((await eng.store.pendingMoves()).length, 1);
  });

  // ─── RFC-009 §E/§F matrix: local reorder / demote / promote × remote ───────

  test('reorder vs remote reorder last writer wins and converges', () async {
    // §E × remote reordered the same list. The move endpoint carries no etag,
    // so there is nothing to 412 on: whoever writes last wins the position, and
    // the pull leaves both sides showing the same order.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'A', 'a', '00000000000001');
    client.seedTask('L1', 'B', 'b', '00000000000002');
    client.seedTask('L1', 'C', 'c', '00000000000003');
    await eng.run();

    // Another device drags C to the top of the list.
    await client.moveTask('L1', 'C');
    // We drag A to sit right after B. Ours is written last.
    await localMove(eng, 'A', previous: 'B');

    final out = await eng.run();
    expect(out.errors, 0, reason: 'a concurrent reorder is not an error');
    expect(
      client.callCount(Method.moveTask),
      2,
      reason: "the other device's drag, then ours — one call each, no retry",
    );
    expect(await remoteOrder(client, 'L1'), [
      'C',
      'B',
      'A',
    ], reason: 'both reorders landed: theirs first, ours after it');
    expect(
      await localOrder(eng, 'L1'),
      await remoteOrder(client, 'L1'),
      reason: 'the list view shows exactly what the server holds',
    );

    // P7: quiescent remote → the next run is a no-op.
    final out2 = await eng.run();
    expect(out2.pushed, 0);
    expect(client.callCount(Method.moveTask), 2);
    expect(await eng.store.pendingMoves(), isEmpty);
  });

  test('reorder vs remote content edit keeps both', () async {
    // §E × remote edited the same row's content. A move is orthogonal to
    // content: the rename arrives (via the move response body, adopted because
    // the row is clean — P6) and our ordering still lands. No conflict, no copy.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'A', 'a', '00000000000001');
    client.seedTask('L1', 'B', 'b', '00000000000002');
    await eng.run();

    await client.patchTask(
      'L1',
      'A',
      const TaskPatch(title: 'renamed elsewhere'),
    );
    await localMove(eng, 'A', previous: 'B');

    final out = await eng.run();
    expect(out.conflicts, 0, reason: 'a move cannot fork a conflicted copy');
    expect(out.errors, 0);

    final rows = await eng.store.listTasks('L1');
    expect(rows.length, 2, reason: 'no conflicted copy was created');
    final a = rows.firstWhere((t) => serverId(t) == 'A');
    expect(
      a.task.title,
      'renamed elsewhere',
      reason: 'the remote content is canonical',
    );
    expect(a.syncState, SyncState.clean);
    expect(await localOrder(eng, 'L1'), [
      'B',
      'A',
    ], reason: 'and our reorder still landed');
    expect(await remoteOrder(client, 'L1'), ['B', 'A']);
  });

  test('move whose previous died remotely keeps the reparent', () async {
    // §E gap — the ambiguous 404. The user dropped T under P, after P's existing
    // subtask B; another device deleted B in the meantime. B is still in OUR
    // store, so the local guard passes and the move goes out naming a `previous`
    // the server no longer has → 404 "Previous task id not found" (probe 2,
    // verified live).
    //
    // Reading that 404 as "the subject is gone" throws the whole intent away:
    // the server keeps T top-level, the local row keeps the parent the user
    // already sees, and the etags still match — so the pull reverts the demote
    // (or, worse, never notices). Degrade instead: drop the ordering half and
    // send the reparent alone (P5's ladder).
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTaskWithParent('L1', 'B', 'sibling', '00000000000002', 'P');
    client.seedTask('L1', 'T', 'dragged under P after B', '00000000000003');
    await eng.run();

    await client.deleteTask('L1', 'B');
    await localMove(eng, 'T', parent: 'P', previous: 'B');

    final out = await eng.run();
    expect(out.errors, 0, reason: 'a vanished sibling is not a run error');
    expect(
      client.callCount(Method.moveTask),
      2,
      reason: 'the move as asked, then the reparent alone — and no third try',
    );
    expect(
      await remoteParent(client, 'L1', 'T'),
      'P',
      reason: 'the reparent the user asked for reached the server',
    );
    final t = (await findByAnyId(eng.store, 'T'))!;
    expect(
      await parentServerId(eng.store, t),
      'P',
      reason: 'and the local view still agrees with it',
    );
    expect(
      await findByAnyId(eng.store, 'B'),
      isNull,
      reason: 'the deleted sibling is gone locally too',
    );
    expect(await eng.store.pendingMoves(), isEmpty);

    // P7 + no wedge: nothing left to push.
    final out2 = await eng.run();
    expect(out2.pushed, 0);
    expect(out2.errors, 0);
    expect(client.callCount(Method.moveTask), 2);
  });

  test('move 404 without a previous drops the intent and the run goes on', () async {
    // §E — the other half of the ambiguity. With no `previous` in the request
    // there is nothing left to degrade to, so a 404 can only mean the subject is
    // gone: drop the intent, do NOT retry, and let the rest of the queue
    // through.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'T', 'vanishing', '00000000000001');
    client.seedTask('L1', 'A', 'a', '00000000000002');
    client.seedTask('L1', 'B', 'b', '00000000000003');
    await eng.run();

    client.failNextForId(Method.moveTask, 'T', () => const NotFound());
    await localMove(eng, 'T');
    await localMove(eng, 'A', previous: 'B');

    final out = await eng.run();
    expect(
      client.callCount(Method.moveTask),
      2,
      reason:
          'one call for the 404\'d move (no pointless retry) and one for the other',
    );
    expect(out.errors, 0, reason: 'a 404 move is not counted as a failure');
    expect(
      await eng.store.pendingMoves(),
      isEmpty,
      reason: 'neither intent is left to grind forever',
    );
    expect(
      await remoteOrder(client, 'L1'),
      ['T', 'B', 'A'],
      reason:
          'the second move still landed — one bad row cannot starve the queue',
    );
  });

  test('reorder vs remote delete of the moved task drops the intent', () async {
    // §E × task deleted remotely. The fake models the live asymmetry: an unknown
    // SUBJECT id is a permanent 400 "Invalid task ID" (probe 2), not a 404. It
    // is counted and dropped, never retried, and the pull removes the row the
    // user can no longer act on.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'A', 'a', '00000000000001');
    client.seedTask('L1', 'B', 'b', '00000000000002');
    await eng.run();

    await client.deleteTask('L1', 'A');
    await localMove(eng, 'A', previous: 'B');

    await eng.run();
    expect(
      await eng.store.pendingMoves(),
      isEmpty,
      reason: 'the intent is dropped, not retried forever',
    );
    expect(await localOrder(eng, 'L1'), [
      'B',
    ], reason: 'the deleted row is gone from the list view');

    final out2 = await eng.run();
    expect(out2.errors, 0, reason: 'and the failure does not repeat');
  });

  test('demote under a parent deleted remotely converges in both orders', () async {
    // §F × P deleted remotely. Two legal serializations; the invariant is
    // convergence, not which one won.
    //
    // (a) The server processed the delete first, so our move names a dead parent
    // id. The exact status for that is NOT probed (an insert naming an
    // unresolved parent is a permanent 400 "Invalid task ID"; a move naming an
    // unknown subject is the same 400, an unknown previous a 404), so the test
    // injects BOTH permanent statuses and demands the same outcome from each:
    // the intent is dropped, the run continues, and the task survives top-level
    // on both sides.
    for (final reject in <ApiError Function()>[
      () => const OtherApiError('400: Invalid task ID'),
      () => const NotFound(),
    ]) {
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'P', 'parent', '00000000000001');
      client.seedTask('L1', 'T', 'dragged under P', '00000000000002');
      await eng.run();

      // P dies remotely; we have not pulled that yet, so the local guard still
      // sees a live parent and the move goes out.
      await client.deleteTask('L1', 'P');
      await localMove(eng, 'T', parent: 'P');
      client.failNextForId(Method.moveTask, 'T', reject);

      await eng.run();
      expect(
        await eng.store.pendingMoves(),
        isEmpty,
        reason: 'no wedge: the intent is dropped either way',
      );
      expect(await localOrder(eng, 'L1'), [
        'T',
      ], reason: 'the task survives, top-level, and P is gone from the view');
      expect(await remoteParent(client, 'L1', 'T'), isNull);
      await assertAtMostOneLevel(eng, 'L1');

      final out2 = await eng.run();
      expect(out2.errors, 0);
      expect(out2.pushed, 0);
    }

    // (b) The move landed first, and P's delete cascaded T away on the server
    // afterwards. Ghost detection converges the local view.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'dragged under P', '00000000000002');
    await eng.run();

    await localMove(eng, 'T', parent: 'P');
    await eng.run();
    expect(await remoteParent(client, 'L1', 'T'), 'P');

    await client.deleteTask('L1', 'P');
    final out = await eng.run();
    expect(out.errors, 0);
    expect(
      await eng.store.listTasks('L1'),
      isEmpty,
      reason: 'the cascade took the demoted task; local mirrors it',
    );
  });

  test('demote under a remotely completed parent arrives completed', () async {
    // §F × P completed remotely. Google accepts the move (200) and its cascade
    // completes the moved-in task — the move RESPONSE already says so (probe 4).
    // Response-body adoption (P6) converges it: the user sees their open task
    // become done rather than the row freezing with a fresh etag and stale
    // content.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'still open', '00000000000002');
    await eng.run();

    await client.patchTask(
      'L1',
      'P',
      const TaskPatch(status: TaskStatus.completed),
    );
    await localMove(eng, 'T', parent: 'P');

    final out = await eng.run();
    expect(out.errors, 0);
    final t = (await findByAnyId(eng.store, 'T'))!;
    expect(
      await parentServerId(eng.store, t),
      'P',
      reason: 'the demote landed',
    );
    expect(
      t.task.status,
      TaskStatus.completed,
      reason: "the server's cascade completed it and we adopted the body",
    );
    expect(t.syncState, SyncState.clean);
    expect(
      t.task.etag,
      (await client.getTask('L1', 'T')).etag,
      reason: 'etag and content stay coherent (P6) — no frozen row',
    );

    final out2 = await eng.run();
    expect(out2.pushed, 0, reason: 'converged in one run');
  });

  test('demote of a task that gained a remote subtask is refused', () async {
    // §F gap — the third level. The demote was recorded while T was childless; a
    // pull then handed T a remote-born subtask. Pushing the move now would nest
    // C three deep, and Google would ACCEPT it (probe 3: no depth cap, 200) —
    // the server cannot save us here, so the move must be refused client-side.
    // Invariant #1 is ours to keep.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'about to be demoted', '00000000000002');
    await eng.run();

    // Another device adds a subtask under T; we pull it.
    client.seedTaskWithParent(
      'L1',
      'C',
      'remote-born child',
      '00000000000003',
      'T',
    );
    await eng.run();
    expect(
      await parentServerId(eng.store, (await findByAnyId(eng.store, 'C'))!),
      'T',
    );

    await localMove(eng, 'T', parent: 'P');
    final out = await eng.run();

    expect(
      client.callCount(Method.moveTask),
      0,
      reason: 'the move is never sent: the server would say yes',
    );
    expect(out.errors, 0, reason: 'refusing is not an error');
    expect(await eng.store.pendingMoves(), isEmpty);
    expect(
      await remoteParent(client, 'L1', 'T'),
      isNull,
      reason: 'T is still top-level on the server',
    );
    // And the local row was reverted to the server's truth — otherwise the
    // matching etag would freeze the third level into the local view.
    expect(await localOrder(eng, 'L1'), [
      'P',
      'T',
    ], reason: 'T renders as a top-level row again');
    await assertAtMostOneLevel(eng, 'L1');
    expect(
      await parentServerId(eng.store, (await findByAnyId(eng.store, 'C'))!),
      'T',
      reason: 'and its subtask is still its subtask',
    );

    final out2 = await eng.run();
    expect(out2.pushed, 0);
    expect(client.callCount(Method.moveTask), 0);
    await assertAtMostOneLevel(eng, 'L1');
  });

  test('a refused move leaves a pending content edit alone', () async {
    // The refusal reverts the optimistic placement by dropping the row's etag —
    // but only for a CLEAN row. A row that also carries a pending edit owns its
    // etag: clearing it would downgrade the guarded `If-Match` patch to an
    // unconditional one. The edit must land, and the row must still converge to
    // the server's parent afterwards.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'about to be demoted', '00000000000002');
    await eng.run();
    client.seedTaskWithParent(
      'L1',
      'C',
      'remote-born child',
      '00000000000003',
      'T',
    );
    await eng.run();

    await localMove(eng, 'T', parent: 'P');
    final t0 = (await findByAnyId(eng.store, 'T'))!;
    await eng.store.upsertTask(
      StoredTask(
        task: t0.task.copyWith(title: 'renamed locally'),
        listId: t0.listId,
        syncState: SyncState.dirty,
        localUpdated: t0.localUpdated,
        pendingOp: 'update',
      ),
    );

    // The edit's push drops on the network, so the row is STILL dirty when the
    // move is refused — the case the clean-only filter exists for.
    client.failNext(Method.patchTask, () => const ServerError(503));
    await eng.run();
    expect(client.callCount(Method.moveTask), 0, reason: 'the move is refused');
    final t1 = (await findByAnyId(eng.store, 'T'))!;
    expect(t1.syncState, SyncState.dirty, reason: 'the edit is still pending');
    expect(t1.task.etag, isNotNull, reason: 'and it kept its etag guard');

    // Another device edits the same row. The retried patch must still be guarded
    // by If-Match, or that edit is silently overwritten.
    await client.patchTask(
      'L1',
      'T',
      const TaskPatch(title: 'renamed remotely'),
    );

    final out = await eng.run();
    expect(out.conflicts, 1, reason: '412 → the remote edit was not clobbered');
    final rows = await eng.store.listTasks('L1');
    final t = rows.firstWhere((r) => serverId(r) == 'T');
    expect(
      t.task.title,
      'renamed remotely',
      reason: 'remote is canonical (P3)',
    );
    expect(t.task.parent, isNull, reason: 'and T is top-level again');
    expect(
      rows.any((r) => r.task.title.contains('(conflicted copy)')),
      isTrue,
      reason: 'the local edit survives as a copy',
    );
    await assertAtMostOneLevel(eng, 'L1');
  });

  test(
    'demote under a task that became a subtask remotely is refused',
    () async {
      // §F gap, mirror case: the target parent P was itself demoted under Q by
      // another device. Same third level, same refusal.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'Q', 'grandparent-to-be', '00000000000001');
      client.seedTask('L1', 'P', 'target parent', '00000000000002');
      client.seedTask('L1', 'T', 'dragged under P', '00000000000003');
      await eng.run();

      await client.moveTask('L1', 'P', parent: 'Q');
      await eng.run(); // pull: P is now a subtask of Q locally too
      final callsBefore = client.callCount(Method.moveTask); // the remote drag

      await localMove(eng, 'T', parent: 'P');
      await eng.run();

      expect(
        client.callCount(Method.moveTask),
        callsBefore,
        reason: 'the move is never sent',
      );
      expect(await eng.store.pendingMoves(), isEmpty);
      expect(await remoteParent(client, 'L1', 'T'), isNull);
      await assertAtMostOneLevel(eng, 'L1');
      expect(
        (await localOrder(eng, 'L1')).contains('T'),
        isTrue,
        reason: 'T is back to being a top-level row, not a hidden grandchild',
      );
    },
  );

  test(
    'promote vs remote delete drops the intent and the row disappears',
    () async {
      // §F — promote/detach × the row deleted remotely. Delete wins (P4): the
      // intent is dropped and ghost detection removes the row. The parent it was
      // detaching from is untouched.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'P', 'parent', '00000000000001');
      client.seedTaskWithParent('L1', 'S', 'subtask', '00000000000002', 'P');
      await eng.run();

      await client.deleteTask('L1', 'S');
      await localMove(eng, 'S');

      await eng.run();
      expect(await eng.store.pendingMoves(), isEmpty);
      expect(
        await findByAnyId(eng.store, 'S'),
        isNull,
        reason: 'the promoted row is gone, not resurrected top-level',
      );
      final p = (await findByAnyId(eng.store, 'P'))!;
      expect(p.syncState, SyncState.clean, reason: 'the parent is untouched');

      final out2 = await eng.run();
      expect(out2.errors, 0);
    },
  );

  test('promote vs remote reparent last writer wins', () async {
    // §F — promote × the remote reparented the same row elsewhere. No etag on
    // the move endpoint, so the last write wins and the pull converges both
    // sides on it. Ours is written last: the task ends up top-level.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'old parent', '00000000000001');
    client.seedTask('L1', 'Q', 'other parent', '00000000000002');
    client.seedTaskWithParent('L1', 'S', 'subtask', '00000000000003', 'P');
    await eng.run();

    await client.moveTask('L1', 'S', parent: 'Q');
    await localMove(eng, 'S');

    final out = await eng.run();
    expect(out.errors, 0);
    expect(
      await remoteParent(client, 'L1', 'S'),
      isNull,
      reason: 'our promote was written last',
    );
    expect(await localOrder(eng, 'L1'), [
      'S',
      'P',
      'Q',
    ], reason: 'and the row renders as a top-level task');
    await assertAtMostOneLevel(eng, 'L1');

    final out2 = await eng.run();
    expect(out2.pushed, 0, reason: 'converged');
  });

  test(
    'a content edit and a move on the same row both land in one run',
    () async {
      // §F last row: push order is updates-then-moves, so the final state is the
      // new content at the new position. The move response must NOT clobber the
      // pending edit (meta-only adoption for a dirty row).
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      client.seedTask('L1', 'A', 'a', '00000000000001');
      client.seedTask('L1', 'B', 'b', '00000000000002');
      await eng.run();

      final a0 = (await findByAnyId(eng.store, 'A'))!;
      await eng.store.upsertTask(
        StoredTask(
          task: a0.task.copyWith(title: 'renamed by me'),
          listId: a0.listId,
          syncState: SyncState.dirty,
          localUpdated: _tMove,
          pendingOp: 'update',
        ),
      );
      await localMove(eng, 'A', previous: 'B');

      final out = await eng.run();
      expect(out.conflicts, 0);
      expect(out.errors, 0);
      final a = (await findByAnyId(eng.store, 'A'))!;
      expect(a.task.title, 'renamed by me');
      expect(a.syncState, SyncState.clean, reason: 'nothing left pending');
      expect((await client.getTask('L1', 'A')).title, 'renamed by me');
      expect(await remoteOrder(client, 'L1'), ['B', 'A']);
      expect(await localOrder(eng, 'L1'), ['B', 'A']);
      expect(
        a.task.etag,
        (await client.getTask('L1', 'A')).etag,
        reason: 'etag/content coherence (P6) survives update-then-move',
      );
    },
  );
}
