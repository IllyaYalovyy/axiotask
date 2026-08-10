// Port of `sync/engine.rs`'s in-file tests — the T5.8 "engine IV" partition
// (MIGRATION-PLAN §5): the PULL pass and its edges (Pull, Ghost detection,
// idempotency/transient handling, sync-log), the D7 flatten group (§F/§G
// residual third levels resolved after EVERY sync), RFC-009 §A (completed /
// auto-hidden rows survive the pull), and the mid-run interleave races (the
// fake's on_call hook). The create pass / in-flight recovery / §G belong to T5.5;
// UPDATE/DELETE/412/§B/§C/§D to T5.6; Move / §E/§F / list sync / §I to T5.7.
//
// Plus the phase-boundary kill tests the plan calls for (engine header, §2
// kill-safety): a FATAL fault at the push→pull boundary aborts the run mid-cycle
// — modelling a process death exactly between two phases — and re-running `run()`
// must converge with no duplicate, no lost push, and invariant #1 restored. The
// distinction the last one pins: a TRANSIENT pull skip still runs the post-sync
// D7 flatten (that is a different T5.8 test), but a FATAL abort cannot — yet the
// resume run still repairs the residual third level.
//
// Every test drives `run()` end to end against the fake (which mirrors the
// verified live Google semantics) and asserts the end state on BOTH sides — the
// rows `eng.store` returns AND the tasks the fake holds.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:flutter_test/flutter_test.dart';

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
Future<void> localMove(
  SyncEngine eng,
  String id, {
  String? parent,
  String? previous,
}) async {
  final row = (await eng.store.findTaskAny(id))!;
  final position = previous != null ? 'after-$previous' : '00000000000001';
  // Rebuild the Task explicitly: copyWith cannot clear `parent` to null.
  final task = Task(
    id: row.task.id,
    parent: parent,
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
    ),
  );
  await eng.store.recordMove(id, row.listId, parent, previous);
}

/// Top-level task ids in the order the list view renders them (invariant #1).
Future<List<String>> localOrder(SyncEngine eng, String list) async {
  final rows = await eng.store.listTasks(list);
  return [
    for (final r in rows)
      if (r.task.parent == null) r.task.id,
  ];
}

/// The parent of a task as the server currently holds it.
Future<String?> remoteParent(
  FakeTasksApi client,
  String list,
  String id,
) async => (await client.getTask(list, id)).parent;

/// The local row for [id] within [list], or throw with a helpful message.
Future<StoredTask> localRow(SyncEngine eng, String list, String id) async {
  for (final r in await eng.store.listTasks(list)) {
    if (r.task.id == id) return r;
  }
  fail('no local row $id in $list');
}

/// Invariant #1, asserted over the whole store: no row may have a grandparent.
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

/// The most recent sync_log row's columns (the engine ALWAYS writes one).
Future<({int pulled, int pushed, int conflicts, String? error})> lastSyncLog(
  SyncEngine eng,
) async {
  final row = await eng.store.db
      .customSelect(
        'SELECT pulled, pushed, conflicts, error FROM sync_log '
        'ORDER BY id DESC LIMIT 1',
      )
      .getSingle();
  return (
    pulled: row.read<int>('pulled'),
    pushed: row.read<int>('pushed'),
    conflicts: row.read<int>('conflicts'),
    error: row.readNullable<String>('error'),
  );
}

void main() {
  // ─── Pull tests ────────────────────────────────────────────────────────────

  test('pull seeds store', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'first', '1');
    client.seedTask('L1', 'T2', 'second', '2');

    final out = await eng.run();
    expect(out.pulled, 2);
    expect((await eng.store.listTasks('L1')).length, 2);
  });

  test('pull backfills missing web_view_link without etag change', () async {
    // A task stored before web_view_link existed (NULL) must be re-pulled and
    // backfilled on the next sync, even though its etag is unchanged.
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'task', '1');
    await eng.run();

    // Simulate the pre-migration state: clear the stored link, keep etag.
    final row = (await eng.store.findTaskAny('T1'))!;
    expect(row.task.webViewLink, isNotNull, reason: 'first pull stored a link');
    final etagBefore = row.task.etag;
    await eng.store.upsertTask(
      StoredTask(
        task: Task(
          id: row.task.id,
          parent: row.task.parent,
          position: row.task.position,
          title: row.task.title,
          notes: row.task.notes,
          status: row.task.status,
          due: row.task.due,
          completed: row.task.completed,
          etag: row.task.etag,
          updated: row.task.updated,
          deleted: row.task.deleted,
        ),
        listId: row.listId,
        syncState: row.syncState,
        localUpdated: row.localUpdated,
      ),
    );

    // A normal sync (no server change) must re-populate the link.
    await eng.run();
    final healed = (await eng.store.findTaskAny('T1'))!;
    expect(healed.task.webViewLink, isNotNull, reason: 'link backfilled');
    expect(healed.task.etag, etagBefore, reason: 'etag unchanged');
  });

  test('pull upserts lists', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedList('L2', 'Work');

    await eng.run();
    expect((await eng.store.allLists()).length, 2);
  });

  test('pull multiple lists land in their own lists', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Work');
    client.seedList('L2', 'Personal');
    client.seedTask('L1', 'T1', 'work', '1');
    client.seedTask('L2', 'T2', 'personal', '1');

    await eng.run();
    expect((await eng.store.listTasks('L1'))[0].task.title, 'work');
    expect((await eng.store.listTasks('L2'))[0].task.title, 'personal');
  });

  test('pull orders parents before children (FK-safe)', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P1', 'parent', '1');
    client.seedTaskWithParent('L1', 'C1', 'child', '2', 'P1');

    final out = await eng.run();
    expect(out.pulled, 2);
    final child = await localRow(eng, 'L1', 'C1');
    expect(child.task.parent, 'P1');
  });

  test('pull skips dirty rows', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'remote', '1');
    client.seedTask('L1', 'T2', 'clean', '2');
    await eng.run();

    // Locally edit T1.
    final t1 = await localRow(eng, 'L1', 'T1');
    await eng.store.upsertTask(
      StoredTask(
        task: t1.task.copyWith(title: 'local edit'),
        listId: t1.listId,
        syncState: SyncState.dirty,
        localUpdated: t1.localUpdated,
        pendingOp: 'update',
      ),
    );

    final out = await eng.run();
    // Neither T1 (dirty, skipped) nor T2 (etag unchanged) should count.
    expect(out.pulled, 0);
    expect((await localRow(eng, 'L1', 'T1')).task.title, 'local edit');
  });

  test('pull updates when remote etag differs', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'v1', '1');
    await eng.run();

    await client.patchTask('L1', 'T1', const TaskPatch(title: 'v2'));

    final out = await eng.run();
    expect(out.pulled, 1);
    expect((await eng.store.listTasks('L1'))[0].task.title, 'v2');
  });

  test('pull handles pagination', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    for (var i = 0; i < 10; i++) {
      client.seedTask('L1', 'T$i', 'task $i', i.toString().padLeft(14, '0'));
    }
    // 10 tasks at 3 per page = 4 pages.
    client.setPageSize(3);
    final out = await eng.run();
    expect(out.pulled, 10);
    expect(
      client.callCount(Method.listTasks) >= 4,
      isTrue,
      reason: 'must iterate every page, not just the first',
    );
    expect((await eng.store.listTasks('L1')).length, 10);
  });

  test('pull incomplete pagination never ghosts real rows', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    for (var i = 0; i < 6; i++) {
      client.seedTask('L1', 'T$i', 'task $i', i.toString().padLeft(14, '0'));
    }
    // 6 tasks at 2 per page = 3 pages. First full sync stores every row.
    client.setPageSize(2);
    final out = await eng.run();
    expect(out.pulled, 6);
    expect((await eng.store.listTasks('L1')).length, 6);

    // Second sync: page 0 returns real rows, page 1 drops mid-scroll. The
    // un-fetched pages' tasks must NOT be mistaken for server-side deletions.
    client.failListTasksPage(1, () => const ServerError(503));
    final out2 = await eng.run();
    expect(
      out2.deleted,
      0,
      reason: 'incomplete page fetch must not ghost rows',
    );
    expect(
      (await eng.store.listTasks('L1')).length,
      6,
      reason: 'every synced row survives an interrupted paginated pull',
    );
  });

  test('pull first page failure is empty but incomplete, not a wipe', () async {
    // The catastrophic partial-pull edge: the VERY FIRST page drops, so the
    // fetch returns zero rows AND complete=false. An empty remote set is exactly
    // what a total wipe looks like — the `complete` guard must read
    // empty-but-incomplete as "learned nothing", never "everything is gone".
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    for (var i = 0; i < 6; i++) {
      client.seedTask('L1', 'T$i', 'task $i', i.toString().padLeft(14, '0'));
    }
    client.setPageSize(2);
    final out = await eng.run();
    expect(out.pulled, 6);
    expect((await eng.store.listTasks('L1')).length, 6);

    // Second sync: the first page itself drops, so nothing is fetched.
    client.failListTasksPage(0, () => const ServerError(503));
    final out2 = await eng.run();
    expect(out2.pulled, 0, reason: 'a dropped first page fetches nothing');
    expect(
      out2.deleted,
      0,
      reason: 'empty-but-incomplete must never be read as a server-side wipe',
    );
    expect(
      (await eng.store.listTasks('L1')).length,
      6,
      reason: 'every row survives a first-page failure that returned zero rows',
    );

    // Heal: a complete pull is a no-op — nothing was actually deleted (P7).
    final out3 = await eng.run();
    expect(out3.deleted, 0);
    expect(out3.pulled, 0);
    expect((await eng.store.listTasks('L1')).length, 6);
  });

  test('pull multilevel nesting is FK-safe and D7 flattens the third '
      'level', () async {
    // The API allows >1 level of nesting; the pull batch can arrive in any
    // order. Seed the hostile order (grandchild first, root last). engine() has
    // push DISABLED — a read-only sync.
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTaskWithParent('L1', 'leaf', 'leaf', '1', 'mid');
    client.seedTaskWithParent('L1', 'mid', 'mid', '2', 'root');
    client.seedTask('L1', 'root', 'root', '3');

    final out = await eng.run();
    expect(
      out.pulled,
      3,
      reason:
          'all three levels pulled despite hostile '
          'order (FK-safe)',
    );
    // `mid` is a legal one-level subtask (parent `root` is top-level).
    expect((await localRow(eng, 'L1', 'mid')).task.parent, 'root');
    // `leaf` would be a third level (root > mid > leaf). D7 flattens it to
    // top-level LOCALLY even though push is off (#137).
    expect(
      (await localRow(eng, 'L1', 'leaf')).task.parent,
      isNull,
      reason: 'the pulled third level is flattened locally on a read-only sync',
    );
    expect(out.conflicts, 1, reason: 'the flattened third level counts');
    await assertAtMostOneLevel(eng, 'L1');
  });

  test('pull detaches a task whose parent is unknown instead of '
      'failing', () async {
    // The reachable FK hazard: a create crashed mid-push (orphan on the server,
    // local row still carries the local UUID + an in-flight marker), and a CHILD
    // of that orphan exists remotely. Pull filters the orphan out of the batch
    // (in-flight dedup), so the child references a parent in neither the batch
    // nor the store. In READ-ONLY mode crash recovery never runs, so without the
    // detach guard every pull FK-fails — forever.
    final (client, eng) = await engine(); // push DISABLED
    client.seedList('L1', 'Inbox');
    await eng.run();

    // Crashed create: local row under a local UUID + in-flight marker…
    await eng.store.upsertTask(
      StoredTask(
        task: dirtyTask(
          'local-p',
          'L1',
          'create',
        ).task.copyWith(title: 'buy milk'),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'create',
      ),
    );
    await eng.store.recordInflightCreate('local-p', 'L1', _t0);
    // …its committed orphan on the server, plus a child under the orphan.
    client.seedTask('L1', 'remote-orphan', 'buy milk', '1');
    client.seedTaskWithParent(
      'L1',
      'C',
      'child of orphan',
      '2',
      'remote-orphan',
    );

    await eng.run(); // must not throw on the unknown parent
    final child = await localRow(eng, 'L1', 'C');
    expect(
      child.task.parent,
      isNull,
      reason:
          'detached until the parent '
          'id resolves',
    );

    // Once recovery runs (push re-enabled), the orphan is adopted and the next
    // pull re-links the child (its etag was dropped, so it re-pulls).
    final engPush = SyncEngine.withPush(client, eng.store, true);
    await engPush.run();
    final relinked = await localRow(eng, 'L1', 'C');
    expect(relinked.task.parent, 'remote-orphan', reason: 're-linked');
  });

  // ─── Ghost detection ───────────────────────────────────────────────────────

  test('ghost rows deleted', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'stays', '1');
    client.seedTask('L1', 'T2', 'vanishes', '2');
    await eng.run();

    client.deleteTaskFromState('L1', 'T2');

    final out = await eng.run();
    expect(out.deleted, 1);
    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 1);
    expect(tasks[0].task.id, 'T1');
  });

  test('ghost detection preserves dirty rows', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'remote', '1');
    await eng.run();

    // Local-only task (not on the server).
    await eng.store.upsertTask(dirtyTask('local-only', 'L1', 'create'));

    await eng.run();
    expect(
      (await eng.store.listTasks('L1')).any((t) => t.task.id == 'local-only'),
      isTrue,
    );
  });

  test('ghost detection skipped on transient', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'task1', '1');
    client.seedTask('L1', 'T2', 'task2', '2');
    await eng.run();

    client.failNext(Method.listTasks, () => const ServerError(503));

    final out = await eng.run();
    expect(out.deleted, 0);
    expect((await eng.store.listTasks('L1')).length, 2);
  });

  test('ghost detection per list', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Work');
    client.seedList('L2', 'Personal');
    client.seedTask('L1', 'T1', 'work', '1');
    client.seedTask('L2', 'T2', 'personal', '1');
    await eng.run();

    client.deleteTaskFromState('L1', 'T1');

    final out = await eng.run();
    expect(out.deleted, 1);
    expect((await eng.store.listTasks('L1')), isEmpty);
    expect((await eng.store.listTasks('L2')).length, 1);
  });

  test('ghost removal completeness is isolated per list', () async {
    // Completeness is decided per list, never once for the whole run. In one
    // sync, list A's pull drops (incomplete) while list B's succeeds. BOTH rows
    // are really gone server-side, but only the list we scanned to the end may
    // act on that: A's row is kept (absence unconfirmed), B's ghost is removed.
    final (client, eng) = await engine();
    client.seedList('L-A', 'Work');
    client.seedList('L-B', 'Personal');
    client.seedTask('L-A', 'A1', 'work', '1');
    client.seedTask('L-B', 'B1', 'personal', '1');
    await eng.run();

    // Both tasks vanish server-side (deleted by another client).
    client.deleteTaskFromState('L-A', 'A1');
    client.deleteTaskFromState('L-B', 'B1');

    // L-A is pulled first (seed order); its first page drops, so its pull is
    // incomplete. The fault is consumed on that first match, so L-B completes.
    client.failListTasksPage(0, () => const ServerError(503));
    final out = await eng.run();

    expect(
      out.deleted,
      1,
      reason:
          'only the completely-pulled list may '
          'ghost-remove',
    );
    expect(
      (await eng.store.listTasks('L-A')).length,
      1,
      reason: 'an incomplete list keeps its row even though it is really gone',
    );
    expect(
      (await eng.store.listTasks('L-B')),
      isEmpty,
      reason: 'a completely-pulled list still ghost-removes',
    );

    // Heal: once L-A's pull completes, its vanished row is ghost-removed (P7).
    final out2 = await eng.run();
    expect(out2.deleted, 1);
    expect((await eng.store.listTasks('L-A')), isEmpty);
  });

  // ─── Idempotency & transient handling ──────────────────────────────────────

  test('second sync is a no-op', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'task', '1');

    await eng.run();
    final out2 = await eng.run();
    expect(out2.pulled, 0);
    expect(out2.pushed, 0);
    expect(out2.deleted, 0);
  });

  test('transient list_tasklists error is not fatal', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.failNext(Method.listTasklists, () => const ServerError(503));

    final out = await eng.run();
    expect(out.pulled, 0);
  });

  // ─── Sync log ──────────────────────────────────────────────────────────────

  test('sync log written on success', () async {
    final (client, eng) = await engine();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'T1', 'task', '1');
    await eng.run();

    final log = await lastSyncLog(eng);
    expect(log.pulled, 1);
    expect(log.error, isNull);
  });

  test('sync log written on error', () async {
    final (client, eng) = await engine();
    client.failNext(Method.listTasklists, () => const OtherApiError('fatal'));
    await expectLater(eng.run(), throwsA(isA<Object>()));

    final log = await lastSyncLog(eng);
    expect(log.error, contains('fatal'));
  });

  // ─── D7 flatten (RFC-009 §F/§G residual third levels) ──────────────────────

  test('d7 repairs a remote-born third level after our demote landed', () async {
    // §F residual (D7 ratified). Our demote of T under P LANDS while T is
    // childless (server: P > T). Only THEN does another device add C under T —
    // the server now has a third level (P > T > C) we never asked for. The pull
    // is the one place with the full picture: D7 promotes C to top-level AND
    // pushes the corrective move so the server converges too, as a conflict.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'to be demoted', '00000000000002');
    await eng.run();

    // Our demote lands: T becomes a subtask of P on the server.
    await localMove(eng, 'T', parent: 'P');
    await eng.run();
    expect(
      await remoteParent(client, 'L1', 'T'),
      'P',
      reason:
          'our demote '
          'landed — T is a subtask of P server-side',
    );

    // Another device now hangs C under the (already-demoted) T.
    client.seedTaskWithParent(
      'L1',
      'C',
      'remote grandchild',
      '00000000000003',
      'T',
    );
    final movesBefore = client.callCount(Method.moveTask);

    final out = await eng.run();

    expect(
      out.conflicts,
      1,
      reason:
          'the third level is resolved as a '
          'conflict',
    );
    expect(out.errors, 0, reason: 'repairing is not an error');
    expect(
      client.callCount(Method.moveTask),
      movesBefore + 1,
      reason: 'exactly one corrective move — C promoted to top-level',
    );
    final c = (await eng.store.findTaskAny('C'))!;
    expect(c.task.parent, isNull, reason: 'C is promoted to top-level locally');
    expect(c.syncState, SyncState.clean);
    expect(
      (await eng.store.findTaskAny('T'))!.task.parent,
      'P',
      reason: "the user's demote of T survives — nothing is discarded",
    );
    expect(
      (await localOrder(eng, 'L1')),
      contains('C'),
      reason:
          'C now '
          'renders as a top-level list row',
    );
    await assertAtMostOneLevel(eng, 'L1');
    expect(
      await remoteParent(client, 'L1', 'C'),
      isNull,
      reason:
          'the '
          'corrective move reached the server',
    );
    expect(
      c.task.etag,
      (await client.getTask('L1', 'C')).etag,
      reason: 'etag stays coherent with content (P6) — no frozen row',
    );

    // P7: a second run against the quiescent server is a no-op.
    final out2 = await eng.run();
    expect(out2.conflicts, 0, reason: 'no repair re-fires once converged');
    expect(out2.pushed, 0);
    expect(client.callCount(Method.moveTask), movesBefore + 1);
    await assertAtMostOneLevel(eng, 'L1');
  });

  test('d7 flattens a pulled third level locally even with push '
      'disabled', () async {
    // #137: invariant #1 is ABSOLUTE — it does not depend on whether this sync
    // may write to the server. A read-only sync that pulls a server-side third
    // level must still flatten it LOCALLY; only the corrective move is gated on
    // push. Two engines over the SAME store: a pusher establishes P > T, then a
    // reader (push off) performs the reconciling sync.
    final client = FakeTasksApi();
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final store = Store(db);

    final pusher = SyncEngine.withPush(client, store, true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'to be demoted', '00000000000002');
    await pusher.run();
    await localMove(pusher, 'T', parent: 'P');
    await pusher.run();
    expect(
      await remoteParent(client, 'L1', 'T'),
      'P',
      reason:
          'precondition: '
          'T is a subtask of P on the server',
    );

    // Another device hangs C under the already-demoted T — server P > T > C.
    client.seedTaskWithParent(
      'L1',
      'C',
      'remote grandchild',
      '00000000000003',
      'T',
    );

    final reader = SyncEngine.withPush(client, store, false);
    final movesBefore = client.callCount(Method.moveTask);
    final out = await reader.run();

    // No server write of any kind — push is disabled.
    expect(
      client.callCount(Method.moveTask),
      movesBefore,
      reason:
          'read-only '
          'sync issues no corrective move',
    );
    expect(out.pushed, 0, reason: 'read-only sync pushes nothing');
    expect(
      await remoteParent(client, 'L1', 'C'),
      'T',
      reason: 'the server still nests C — the corrective move is deferred',
    );

    // …yet the LOCAL view is one level: C was flattened.
    expect(
      out.conflicts,
      1,
      reason:
          'the third level is resolved as a '
          'conflict',
    );
    expect(out.errors, 0, reason: 'flattening locally is not an error');
    final c = (await store.findTaskAny('C'))!;
    expect(
      c.task.parent,
      isNull,
      reason:
          'C is promoted to top-level locally '
          'despite push being off',
    );
    expect(
      c.task.etag,
      isNull,
      reason:
          "the clean grandchild's etag is dropped so the next pull "
          're-examines it (P6)',
    );
    expect(
      (await store.findTaskAny('T'))!.task.parent,
      'P',
      reason:
          'the '
          'demote of T survives',
    );
    await assertAtMostOneLevel(reader, 'L1');
    expect((await localOrder(reader, 'L1')), contains('C'));

    // The local view stays one level across further read-only pulls.
    final out2 = await reader.run();
    expect(out2.pushed, 0);
    await assertAtMostOneLevel(reader, 'L1');

    // Enabling push finally converges the server too.
    await pusher.run();
    expect(
      await remoteParent(client, 'L1', 'C'),
      isNull,
      reason: 'a push-enabled run sends the deferred corrective move',
    );
    await assertAtMostOneLevel(pusher, 'L1');
    final out4 = await pusher.run();
    expect(out4.conflicts, 0, reason: 'no repair re-fires once converged');
    await assertAtMostOneLevel(pusher, 'L1');
  });

  test('d7 repairs our queued subtask create under a remotely demoted '
      'parent', () async {
    // §G (D7 ratified). An offline device has a queued subtask create under T;
    // another device demotes T under P. Push runs before pull, so the queued
    // insert cannot know its parent is now a subtask — the server accepts it and
    // WE create the third level. The following pull's D7 repair catches it
    // within one round-trip.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'target parent', '00000000000002');
    await eng.run();

    // Another device demotes T under P on the server (unseen until the pull).
    await client.moveTask('L1', 'T', parent: 'P');

    // Our still-queued subtask create under T (legal locally, T is top-level).
    await eng.store.upsertTask(
      StoredTask(
        task: Task(
          id: 'local-c',
          parent: 'T',
          position: '1',
          title: 'queued grandchild',
          status: TaskStatus.needsAction,
          updated: _t0,
        ),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'create',
      ),
    );

    final out = await eng.run();
    expect(out.conflicts, 1, reason: 'the third level we created is repaired');
    expect(out.errors, 0);

    // C's local id was remapped by the insert; find it by its unique title.
    final rows = await eng.store.listTasks('L1');
    final c = rows.firstWhere((r) => r.task.title == 'queued grandchild');
    expect(
      c.task.parent,
      isNull,
      reason:
          'our queued subtask ends up '
          'top-level',
    );
    expect(c.syncState, SyncState.clean);
    await assertAtMostOneLevel(eng, 'L1');
    expect(
      await remoteParent(client, 'L1', c.task.id),
      isNull,
      reason:
          'the '
          'server converged to the promotion too',
    );

    final out2 = await eng.run();
    expect(out2.conflicts, 0, reason: 'converged in one round-trip');
    expect(out2.pushed, 0);
    await assertAtMostOneLevel(eng, 'L1');
  });

  test('d7 promotes a still-unpushed subtask create locally', () async {
    // §G before the create pushes: the subtask create is HELD (editor open), so
    // it stays queued while the pull lands its parent's remote demote. There is
    // no server id to move — D7 must promote the create LOCALLY so the tree is
    // one level immediately; it then pushes as a top-level create.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'target parent', '00000000000002');
    await eng.run();
    await client.moveTask('L1', 'T', parent: 'P');

    // A queued subtask create under T, held so its create push is deferred.
    await eng.store.upsertTask(
      StoredTask(
        task: Task(
          id: 'held-c',
          parent: 'T',
          position: '1',
          title: 'held grandchild',
          status: TaskStatus.needsAction,
          updated: _t0,
        ),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'create',
      ),
    );

    final held = SyncEngine.withPush(
      client,
      eng.store,
      true,
    ).holdCreateId('held-c');
    final movesBefore = client.callCount(Method.moveTask);
    final out = await held.run();

    expect(
      client.callCount(Method.moveTask),
      movesBefore,
      reason:
          'no corrective move: an un-pushed create has no server id to move',
    );
    expect(out.conflicts, 1, reason: 'promoting the queued third level counts');
    final c = (await eng.store.findTaskAny('held-c'))!;
    expect(
      c.task.parent,
      isNull,
      reason: 'the held create is promoted locally',
    );
    expect(c.syncState, SyncState.dirty, reason: 'still a queued create');
    expect(c.pendingOp, 'create');
    await assertAtMostOneLevel(eng, 'L1');

    // Release the hold: the create pushes as a TOP-LEVEL task and converges.
    await eng.run();
    final rows = await eng.store.listTasks('L1');
    final landed = rows.firstWhere((r) => r.task.title == 'held grandchild');
    expect(
      landed.task.parent,
      isNull,
      reason:
          'it landed top-level on the '
          'server too',
    );
    expect(landed.syncState, SyncState.clean);
    expect(await remoteParent(client, 'L1', landed.task.id), isNull);
    await assertAtMostOneLevel(eng, 'L1');
  });

  test('d7 third-level repair defers to a racing promotion pulled '
      'first', () async {
    // Idempotency, path 1 (D7): another device sees the same third level and
    // promotes C first. Its promotion changed C's etag, so our pull ADOPTS the
    // top-level C before D7 even inspects the row — D7 then finds no grandchild
    // and issues no redundant move.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'subtask', '00000000000002');
    await eng.run();
    await localMove(eng, 'T', parent: 'P');
    await eng.run();
    client.seedTaskWithParent('L1', 'C', 'grandchild', '00000000000003', 'T');

    // The other device wins the race: it promotes C on the server first.
    await client.moveTask('L1', 'C');
    final movesBefore = client.callCount(Method.moveTask);

    final out = await eng.run();
    expect(out.errors, 0, reason: 'a racing repair is not an error');
    expect(
      client.callCount(Method.moveTask),
      movesBefore,
      reason: 'no redundant corrective move — the pull already adopted it',
    );
    final c = (await eng.store.findTaskAny('C'))!;
    expect(c.task.parent, isNull, reason: 'C is top-level, exactly once');
    await assertAtMostOneLevel(eng, 'L1');
    expect(await remoteParent(client, 'L1', 'C'), isNull);
    expect(
      c.task.etag,
      (await client.getTask('L1', 'C')).etag,
      reason: 'etag/content stay coherent even through the racing promotion',
    );

    final out2 = await eng.run();
    expect(out2.conflicts, 0, reason: 'quiescent afterwards');
    expect(out2.pushed, 0);
    await assertAtMostOneLevel(eng, 'L1');
  });

  test('d7 corrective move on an already-top-level row is an accepted '
      'no-op', () async {
    // Idempotency, path 2 (D7): the API contract the repair leans on when two
    // devices race. A corrective move(parent=None) on an already top-level C is
    // accepted (no depth cap; a fresh etag, no placement change), so a second
    // repair can never corrupt the row or wedge.
    final client = FakeTasksApi();
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'C', 'already top-level', '00000000000001');

    final first = await client.moveTask('L1', 'C');
    expect(first.parent, isNull, reason: 'C stays top-level');
    final second = await client.moveTask('L1', 'C');
    expect(second.parent, isNull, reason: 'a redundant promotion is a no-op');
    expect((await client.getTask('L1', 'C')).parent, isNull);
  });

  test('d7 transient move failure still flattens locally then '
      'converges', () async {
    // D7 failure path: the corrective move is rate-limited. The LOCAL third level
    // must NOT linger (invariant #1 is absolute even mid-flight) — the grandchild
    // is promoted locally now and its etag dropped; the server, still nesting it,
    // is caught by the next pull's re-detect + retry (P7).
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'to be demoted', '00000000000002');
    await eng.run();
    await localMove(eng, 'T', parent: 'P');
    await eng.run();
    client.seedTaskWithParent('L1', 'C', 'grandchild', '00000000000003', 'T');

    client.failNextForId(Method.moveTask, 'C', () => const RateLimited());
    final out = await eng.run();

    expect(out.conflicts, 1, reason: 'resolving the third level counts');
    final c = (await eng.store.findTaskAny('C'))!;
    expect(c.task.parent, isNull, reason: 'C is promoted to top-level locally');
    expect(
      c.task.etag,
      isNull,
      reason:
          'etag dropped so the next pull '
          're-examines it',
    );
    await assertAtMostOneLevel(eng, 'L1');
    expect(
      await remoteParent(client, 'L1', 'C'),
      'T',
      reason: 'the server is still nested; it must be caught next run (P7)',
    );

    // Next run: the fault is gone, the retry lands — server and local converge.
    final out2 = await eng.run();
    expect(
      out2.conflicts,
      1,
      reason: 'the retry resolves it on the server too',
    );
    expect(
      await remoteParent(client, 'L1', 'C'),
      isNull,
      reason:
          'server '
          'converged',
    );
    expect((await eng.store.findTaskAny('C'))!.task.parent, isNull);
    await assertAtMostOneLevel(eng, 'L1');

    // Fixpoint afterwards.
    final out3 = await eng.run();
    expect(out3.conflicts, 0, reason: 'no repair re-fires once converged');
    await assertAtMostOneLevel(eng, 'L1');
  });

  test('d7 permanent move failure flattens locally on a partial '
      'pull', () async {
    // The exact soak failure. A grandchild C, nested under a clean subtask T,
    // was DELETED on the server, so the corrective move is rejected permanently
    // (400 — unknown id). On a PARTIAL pull ghost removal is skipped, so without
    // the fix the stale nested row lingers — a third level in the store right
    // after the pull. D7 must promote it locally regardless; the next COMPLETE
    // pull ghost-removes the vanished row.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'to be demoted', '00000000000002');
    await eng.run();
    await localMove(eng, 'T', parent: 'P');
    await eng.run();

    // A clean local grandchild under T that the server does NOT hold. Its move
    // will be a permanent 400 (unknown id).
    await eng.store.upsertTask(
      StoredTask(
        task: Task(
          id: 'C',
          parent: 'T',
          position: '1',
          title: 'vanished grandchild',
          status: TaskStatus.needsAction,
          etag: 'e-c',
          updated: _t0,
          webViewLink: 'https://tasks.google.com/task/C',
        ),
        listId: 'L1',
        syncState: SyncState.clean,
        localUpdated: _t0,
      ),
    );

    // Partial pull: page the list and fail the last page so ghost removal (which
    // would otherwise mask the fix) is skipped this run.
    client.setPageSize(1);
    client.failListTasksPage(1, () => const ServerError(503));
    final out = await eng.run();

    expect(out.conflicts, 1, reason: 'the third level is resolved locally');
    expect(
      (await eng.store.findTaskAny('C'))!.task.parent,
      isNull,
      reason: 'C is flat locally despite the rejection',
    );
    await assertAtMostOneLevel(eng, 'L1');

    // Heal: a complete pull ghost-removes the vanished row and converges.
    client.clearFaults();
    client.setPageSize(100);
    await eng.run();
    expect(
      await eng.store.findTaskAny('C'),
      isNull,
      reason:
          'the vanished grandchild is ghost-removed on the next '
          'complete pull',
    );
    await assertAtMostOneLevel(eng, 'L1');
  });

  test('d7 flattens a third level when the pull is skipped by a list-fetch '
      'fault', () async {
    // The oracle counterexample (#150). A residual third level P > T > C sits in
    // the local store, and the SAME run's pull is skipped entirely because
    // list_tasklists faults transiently. D7 used to run only inside pull_list, so
    // a skipped pull left the third level in the store: invariant #1 violated
    // immediately after a partial pull. The flatten is a LOCAL structural repair
    // and must run after EVERY sync regardless of what the pull did.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'to be demoted', '00000000000002');
    await eng.run();
    await localMove(eng, 'T', parent: 'P');
    await eng.run();
    // T is now a clean subtask of P, both locally and on the server.

    // A synced grandchild C under the clean subtask T (§F residual).
    final seeded = client.seedTaskWithParent(
      'L1',
      'C',
      'grandchild',
      '00000000000003',
      'T',
    );
    await eng.store.upsertTask(
      StoredTask(
        task: Task(
          id: 'C',
          parent: 'T',
          position: '1',
          title: 'grandchild',
          status: TaskStatus.needsAction,
          etag: seeded.etag,
          updated: _t0,
          webViewLink: 'https://tasks.google.com/task/C',
        ),
        listId: 'L1',
        syncState: SyncState.clean,
        localUpdated: _t0,
      ),
    );

    // This sync's PULL is skipped whole: list_tasklists faults transiently.
    client.failNext(Method.listTasklists, () => const ServerError(502));
    final out = await eng.run();

    // The local third level is flattened anyway (invariant #1 is absolute).
    expect(out.conflicts, 1, reason: 'resolving the third level counts');
    expect(
      (await eng.store.findTaskAny('C'))!.task.parent,
      isNull,
      reason: 'C is promoted to top-level even though the pull never ran',
    );
    await assertAtMostOneLevel(eng, 'L1');

    // Converges: the corrective move reached the server.
    client.clearFaults();
    await eng.run();
    expect(
      (await eng.store.findTaskAny('C'))!.task.parent,
      isNull,
      reason:
          'C '
          'stays top-level after a healthy sync',
    );
    await assertAtMostOneLevel(eng, 'L1');
  });

  test('d7 dirty grandchild keeps its etag so the retry push stays '
      'guarded', () async {
    // D7 failure path × a DIRTY grandchild (invariant P6). When the corrective
    // move is refused, the LOCAL third level must still flatten immediately — but
    // a grandchild carrying a pending edit KEEPS its etag, because its own
    // content push governs the etag. Dropping it (as a clean row does) would turn
    // the retry patch's guarded If-Match into an unconditional overwrite.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'to be demoted', '00000000000002');
    await eng.run();
    await localMove(eng, 'T', parent: 'P');
    await eng.run();

    // A synced grandchild C under T that ALSO carries a pending local edit.
    final seeded = client.seedTaskWithParent(
      'L1',
      'C',
      'grandchild',
      '00000000000003',
      'T',
    );
    final cEtag = seeded.etag!;
    await eng.store.upsertTask(
      StoredTask(
        task: Task(
          id: 'C',
          parent: 'T',
          position: '1',
          title: 'my local edit',
          status: TaskStatus.needsAction,
          etag: cEtag,
          updated: _t0,
          webViewLink: 'https://tasks.google.com/task/C',
        ),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'update',
      ),
    );

    // Both the content push AND the corrective move are refused this run.
    client.failNextForId(Method.patchTask, 'C', () => const RateLimited());
    client.failNextForId(Method.moveTask, 'C', () => const RateLimited());
    final out = await eng.run();
    expect(out.conflicts, 1, reason: 'resolving the third level counts');

    final c = (await eng.store.findTaskAny('C'))!;
    expect(
      c.task.parent,
      isNull,
      reason: 'C is flattened to top-level locally',
    );
    expect(
      c.syncState,
      SyncState.dirty,
      reason:
          'the pending edit survives the '
          'repair',
    );
    expect(
      c.task.etag,
      cEtag,
      reason:
          'a dirty grandchild keeps its etag so its retry push stays '
          'If-Match-guarded',
    );
    await assertAtMostOneLevel(eng, 'L1');

    // The behavioral consequence: a concurrent remote edit bumps C's server
    // etag. The retained etag makes the retry push If-Match-guarded, so that
    // push 412s and BOTH edits survive — the remote is not clobbered.
    await client.patchTask(
      'L1',
      'C',
      const TaskPatch(title: 'their remote edit'),
      etag: cEtag,
    );

    final out2 = await eng.run();
    expect(
      out2.conflicts >= 1,
      isTrue,
      reason:
          'the guarded retry hits a 412 and resolves it, never a silent '
          'clobber',
    );
    final rows = await eng.store.listTasks('L1');
    expect(
      rows.any((t) => t.task.title == 'their remote edit'),
      isTrue,
      reason: 'the concurrent remote edit survives as the canonical row',
    );
    expect(
      rows.any((t) => t.task.title == 'my local edit (conflicted copy)'),
      isTrue,
      reason: 'the local edit is preserved as a conflicted copy',
    );
    await assertAtMostOneLevel(eng, 'L1');
  });

  // ─── RFC-009 §A: completed / auto-hidden rows survive the pull ─────────────

  test('a task completed remotely is pulled, not ghost-deleted', () async {
    // §A × completed (and, live, auto-hidden by Google later). The pull asks for
    // showCompleted=true&showHidden=true, so such a row stays in the remote view
    // and ghost detection leaves it alone. If it ever dropped out, the local row
    // would be DELETED — silently eating completed history rather than showing it
    // ticked.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Work');
    client.seedTask('L1', 'T1', 'file taxes', '1');
    await eng.run();

    // Another device ticks it off.
    await client.patchTask(
      'L1',
      'T1',
      const TaskPatch(status: TaskStatus.completed),
    );

    final out = await eng.run();
    expect(out.deleted, 0, reason: 'a completed row is not a ghost');
    final rows = await eng.store.listTasks('L1');
    expect(rows.length, 1, reason: 'the row is still there');
    expect(rows[0].task.title, 'file taxes');
    expect(
      rows[0].task.status,
      TaskStatus.completed,
      reason:
          'and it shows as '
          'done',
    );
    expect(rows[0].syncState, SyncState.clean);

    final out2 = await eng.run();
    expect(out2.pulled, 0);
    expect(out2.deleted, 0);
    expect(out2.errors, 0);
  });

  test('a completed subtask survives the pull, still attached', () async {
    // §A × completed, non-happy variant: the hidden row is a SUBTASK of an open
    // parent. Ghost-deleting it would empty the detail panel of a completed task,
    // and detaching it would promote a subtask into a list row (invariant #1). It
    // must stay exactly where it was, done.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Work');
    client.seedTask('L1', 'P', 'trip', '1');
    client.seedTaskWithParent('L1', 'C', 'pack', '2', 'P');
    await eng.run();

    await client.patchTask(
      'L1',
      'C',
      const TaskPatch(status: TaskStatus.completed),
    );

    final out = await eng.run();
    expect(out.deleted, 0);
    final rows = await eng.store.listTasks('L1');
    final child = rows.firstWhere((r) => r.task.id == 'C');
    expect(child.task.status, TaskStatus.completed);
    expect(
      child.task.parent,
      'P',
      reason: 'still a subtask — never promoted to a list row (invariant #1)',
    );
    expect(
      rows.firstWhere((r) => r.task.id == 'P').task.status,
      TaskStatus.needsAction,
      reason: 'completing a child does not touch the parent',
    );
  });

  // ─── Mid-run interleave (on_call hook) ─────────────────────────────────────
  // Another device mutating the SERVER *between two of the engine's own calls in
  // ONE run* — a race the op-boundary helpers (mutate before/after a whole run)
  // cannot express. The pull lists in insertion order (L1 then L2), so a hook
  // keyed on the Nth list_tasks fires at a known point mid-pull.

  test('remote delete between two pull lists is invisible this run, then '
      'reconciles', () async {
    // S1 (in L1) is listed and reconciled clean on the pull's FIRST list_tasks.
    // A remote delete of S1 then lands on the SECOND list_tasks (L2's) — after L1
    // was already snapshotted. This run cannot see it, so S1 must still be
    // present; the NEXT healthy run ghost-detects and removes it.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'One');
    client.seedList('L2', 'Two');
    client.seedTask('L1', 'S1', 'alpha', '1');
    client.seedTask('L2', 'S2', 'beta', '1');
    await eng.run();

    // Fire on the SECOND list_tasks (L2's): delete S1, which L1's earlier
    // list_tasks already snapshotted this run.
    var listCalls = 0;
    client.setOnCall((c, m) {
      if (m == Method.listTasks) {
        listCalls += 1;
        if (listCalls == 2) c.deleteTaskFromState('L1', 'S1');
      }
    });

    final out = await eng.run();
    client.clearOnCall();
    expect(out.deleted, 0, reason: 'the mid-run delete is invisible this run');
    expect(
      (await eng.store.listTasks('L1')).any((t) => t.task.id == 'S1'),
      isTrue,
      reason: 'S1 still present locally this run — the race window is real',
    );

    // The next healthy run sees S1 gone from L1 and reconciles it away.
    final out2 = await eng.run();
    expect(
      out2.deleted,
      1,
      reason: 'S1 is ghost-detected and removed next run',
    );
    expect(
      (await eng.store.listTasks('L1')).any((t) => t.task.id == 'S1'),
      isFalse,
      reason: 'S1 removed locally after convergence',
    );
    expect(
      (await eng.store.listTasks('L2')).any((t) => t.task.id == 'S2'),
      isTrue,
      reason: 'the untouched other list is unaffected',
    );
    // Fixpoint reached.
    expect((await eng.run()).deleted, 0, reason: 'idempotent once converged');
  });

  test('remote create landing mid-pull is pulled in the same run', () async {
    // Another device inserts into L2 on the pull's FIRST list_tasks (L1's) —
    // before L2 is itself listed. Because it exists by the time L2's list_tasks
    // reads, the SAME run pulls it.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'One');
    client.seedList('L2', 'Two');
    client.seedTask('L1', 'S1', 'alpha', '1');
    await eng.run();
    expect(
      (await eng.store.listTasks('L2')),
      isEmpty,
      reason:
          'L2 starts empty '
          'locally',
    );

    var listCalls = 0;
    client.setOnCall((c, m) {
      if (m == Method.listTasks) {
        listCalls += 1;
        // Fires before L2's own list_tasks, so the new row is visible when L2 is
        // scrolled — pulled this very run.
        if (listCalls == 1) c.seedTask('L2', 'NEW', 'gamma', '1');
      }
    });

    await eng.run();
    client.clearOnCall();
    final l2 = await eng.store.listTasks('L2');
    final created = l2.firstWhere(
      (t) => t.task.id == 'NEW',
      orElse: () => fail('the mid-run remote create is pulled in the same run'),
    );
    expect(created.task.title, 'gamma');
    expect(
      created.syncState,
      SyncState.clean,
      reason:
          'landed clean, nothing '
          'to push',
    );
  });

  // ─── Phase-boundary kill tests (engine header, §2 kill-safety) ─────────────
  // A FATAL fault at the push→pull boundary aborts the run mid-cycle — modelling
  // a process death exactly between two phases. Re-running run() must converge:
  // no duplicate, no lost push, invariant #1 restored. The final one pins the
  // distinction from the transient-skip D7 test: a fatal abort cannot run the
  // post-sync flatten this run, yet the resume run still repairs it.

  test('crash at the push→pull boundary does not duplicate a pushed '
      'create', () async {
    // The create's push (finish_create) commits atomically; then, at the very
    // first call of the PULL phase, a fatal error aborts the run. Re-running must
    // NOT re-insert the row — the push phase's work is durable across the crash.
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(dirtyTask('local-1', 'L1', 'create'));

    // The pull phase's list_tasklists dies fatally, right after push finished.
    client.failNext(Method.listTasklists, () => const OtherApiError('crash'));
    await expectLater(eng.run(), throwsA(isA<Object>()));

    // The create landed on the server exactly once and its local row is clean —
    // the push phase committed before the crash.
    final serverRows = (await client.listTasks('L1')).items;
    expect(
      serverRows.length,
      1,
      reason: 'the create landed on the server once',
    );
    expect(
      (await eng.store.listTasks('L1'))
          .where(
            (r) =>
                r.task.title ==
                'task '
                    'local-1',
          )
          .length,
      1,
      reason: 'exactly one local row — no duplicate from the crash',
    );
    expect(
      (await eng.store.inflightCreates()),
      isEmpty,
      reason:
          'the in-flight '
          'marker was cleared by finish_create',
    );
    // Its local row is clean (finish_create ran) — nothing pending.
    expect(
      (await eng.store.listTasks(
        'L1',
      )).firstWhere((r) => r.task.title == 'task local-1').syncState,
      SyncState.clean,
    );

    // Resume: a healthy run converges — the row is neither re-pushed nor
    // duplicated, and the server still holds exactly one.
    final out = await eng.run();
    expect(out.pushed, 0, reason: 'the clean row is not re-pushed on resume');
    expect((await client.listTasks('L1')).items.length, 1);
    expect((await eng.store.listTasks('L1')).length, 1);
  });

  test('a fatal crash defers the D7 flatten; the resume run repairs the '
      'third level', () async {
    // The boundary that separates a transient pull SKIP (which still runs the
    // post-sync flatten) from a fatal ABORT (which cannot). A residual third
    // level P > T > C sits in the store; the pull's list_tasklists dies FATALLY,
    // so the run throws before _execute reaches the flatten loop — the third
    // level is still nested right after the crashed run. The resume run flattens
    // it and converges (invariant #1 holds once a run completes).
    final (client, eng) = await engine(push: true);
    client.seedList('L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '00000000000001');
    client.seedTask('L1', 'T', 'to be demoted', '00000000000002');
    await eng.run();
    await localMove(eng, 'T', parent: 'P');
    await eng.run();

    // A synced grandchild C under the clean subtask T — a real third level.
    final seeded = client.seedTaskWithParent(
      'L1',
      'C',
      'grandchild',
      '00000000000003',
      'T',
    );
    await eng.store.upsertTask(
      StoredTask(
        task: Task(
          id: 'C',
          parent: 'T',
          position: '1',
          title: 'grandchild',
          status: TaskStatus.needsAction,
          etag: seeded.etag,
          updated: _t0,
          webViewLink: 'https://tasks.google.com/task/C',
        ),
        listId: 'L1',
        syncState: SyncState.clean,
        localUpdated: _t0,
      ),
    );

    // FATAL abort at the push→pull boundary: the flatten loop never runs.
    client.failNext(Method.listTasklists, () => const OtherApiError('crash'));
    await expectLater(eng.run(), throwsA(isA<Object>()));

    // The crash left the third level in the store (the flatten was deferred).
    expect(
      (await eng.store.findTaskAny('C'))!.task.parent,
      'T',
      reason: 'the fatal abort could not run the post-sync flatten this run',
    );

    // Resume: a healthy run flattens C and converges on both sides.
    final out = await eng.run();
    expect(
      out.conflicts,
      1,
      reason:
          'the resume run repairs the residual '
          'third level',
    );
    expect((await eng.store.findTaskAny('C'))!.task.parent, isNull);
    expect(
      await remoteParent(client, 'L1', 'C'),
      isNull,
      reason:
          'the '
          'corrective move reached the server on resume',
    );
    await assertAtMostOneLevel(eng, 'L1');

    // Fixpoint: a further run changes nothing.
    final out2 = await eng.run();
    expect(out2.conflicts, 0, reason: 'converged (P7)');
    await assertAtMostOneLevel(eng, 'L1');
  });
}
