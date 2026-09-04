// Port of `sync/engine.rs`'s in-file tests — the T5.5 partition (MIGRATION-PLAN
// §5): the CREATE pass, in-flight recovery (crash-adoption), and the §G matrix
// (local `create` × remote). These are the kill-here-and-resume tests the
// migration plan calls for (§2 kill-safety): each simulates a crash by leaving
// an in-flight marker / partial push and then re-runs `run()`, asserting the
// server and the store converge to exactly one copy with no duplicate and no
// wedge.
//
// Assertions read the STATE the run leaves behind — the rows the store returns,
// the tasks the fake server holds, the markers recovery reads, the insert call
// count — never which method the engine called. The update/delete/412 matrices,
// the move drain, and the pull/ghost/D7 groups belong to T5.6–T5.8.

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

/// A dirty (or tombstoned) local row, matching the reference's `dirty_task`.
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

/// Where the row lives now, as the user would see it: `(listId, parent)`.
Future<(String, String?)?> placement(Store store, String id) async {
  final r = await findByAnyId(store, id);
  return r == null ? null : (r.listId, r.task.parent);
}

/// Stage a pending content edit on an existing row (the reference's
/// `stage_edit`, non-stale variant).
Future<void> stageEdit(Store store, String id, Task Function(Task) edit) async {
  final row = (await findByAnyId(store, id))!;
  await store.upsertTask(
    StoredTask(
      task: edit(row.task),
      listId: row.listId,
      syncState: SyncState.dirty,
      localUpdated: '2026-06-02T00:00:00Z',
      pendingOp: 'update',
    ),
  );
}

/// Count tasks the fake server currently holds in [listId] with [title].
Future<int> serverCount(
  FakeTasksApi client,
  String listId,
  String title,
) async {
  final page = await client.listTasks(listId);
  return page.items.where((t) => t.title == title).length;
}

void main() {
  // ─── Push (create pass) ────────────────────────────────────────────────────

  test('push disabled does not push', () async {
    final (client, eng) = await engine();
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();
    await eng.store.upsertTask(dirtyTask('local-1', 'L1', 'create'));

    final out = await eng.run();
    expect(out.pushed, 0);
    expect(client.callCount(Method.insertTask), 0);
  });

  test('push create learns the server id and keeps its own', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();
    await eng.store.upsertTask(dirtyTask('local-1', 'L1', 'create'));

    final out = await eng.run();
    expect(out.pushed, 1);
    final tasks = await eng.store.listTasks('L1');
    expect(
      tasks.any((t) => t.remoteId?.startsWith('remote-') ?? false),
      isTrue,
      reason: 'the server id is learned into remote_id',
    );
    expect(tasks.map((t) => t.task.id), [
      'local-1',
    ], reason: 'and the row keeps the id every caller already holds (#224)');
  });

  test('push create parent before child', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(dirtyTask('local-parent', 'L1', 'create'));
    await eng.store.upsertTask(
      dirtyTask('local-child', 'L1', 'create', parent: 'local-parent'),
    );

    final out = await eng.run();
    expect(out.pushed, 2);
    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 2);
    expect(
      tasks.every((t) => t.remoteId?.startsWith('remote-') ?? false),
      isTrue,
    );
  });

  test('push create transient leaves dirty (attempted exactly once)', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();
    await eng.store.upsertTask(dirtyTask('local-1', 'L1', 'create'));

    // A single transient. A parentless create must be attempted EXACTLY once
    // per run (no pass-2 re-attempt that could double-insert).
    client.failNext(Method.insertTask, () => const Network('timeout'));

    final out = await eng.run();
    expect(out.pushed, 0);
    expect(
      client.callCount(Method.insertTask),
      1,
      reason: 'parentless create attempted exactly once per run',
    );
    // Still dirty + in-flight marker for next-run recovery.
    expect((await eng.store.drainDirty()).length, 1);
    expect((await eng.store.inflightCreates()).length, 1);
  });

  test(
    'create push interleaved with re-edit keeps edit as update, no dup',
    () async {
      // The user re-edits the row WHILE its insert is in the air: after the
      // payload and the in-flight marker are committed, before the response
      // lands. finishCreate must learn the remote id AND keep the row dirty as
      // an UPDATE (not clean, not a second create), so the newer edit pushes
      // against the remote id instead of inserting a duplicate.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Inbox');
      await eng.run();

      final snapshot = dirtyTask('local-1', 'L1', 'create', title: 'buy milk');
      await eng.store.upsertTask(snapshot);

      // The edit lands inside the insert await — the on-call hook is awaited,
      // so the interleaving is exact rather than a microtask coin-flip.
      var raced = false;
      client.setOnCall((c, m) async {
        if (m != Method.insertTask || raced) return;
        raced = true;
        await eng.store.upsertTask(
          StoredTask(
            task: snapshot.task.copyWith(title: 'buy oat milk'),
            listId: 'L1',
            syncState: SyncState.dirty,
            localUpdated: '2026-06-01T00:05:00Z',
            pendingOp: 'create',
          ),
        );
      });

      // Drive the create alone: a whole run would go on to push the queued
      // update in the same pass, and the state under test is the one BETWEEN
      // the two — the row the create landing leaves behind.
      final out = SyncOutcome();
      await eng.pushCreate(snapshot, out);
      client.clearOnCall();
      expect(raced, isTrue, reason: 'precondition: the insert really raced');
      expect(out.pushed, 1);

      // No duplicate: exactly one insert, one task on the server.
      expect(client.callCount(Method.insertTask), 1);
      expect((await client.listTasks('L1')).items.length, 1);

      final tasks = await eng.store.listTasks('L1');
      expect(tasks.length, 1);
      final row = tasks.single;
      expect(
        row.remoteId?.startsWith('remote-') ?? false,
        isTrue,
        reason: 'the server id is learned',
      );
      expect(row.task.id, 'local-1', reason: 'the local id never moves');
      expect(
        row.syncState,
        SyncState.dirty,
        reason: 'mid-flight edit stays queued',
      );
      expect(
        row.pendingOp,
        'update',
        reason: 'flipped create→update; re-running as create would duplicate',
      );
      expect(
        row.task.title,
        'buy oat milk',
        reason: 'the re-edit is preserved',
      );
      expect(row.task.etag, isNotNull, reason: 'adopted the server etag');
      expect((await eng.store.inflightCreates()), isEmpty);
    },
  );

  // ─── In-flight recovery (crash-adoption, kill-here-and-resume) ──────────────

  test('crash during create adopts orphan, no duplicate', () async {
    // Insert reached the server (orphan exists) but the app crashed before
    // finishCreate — a dirty create + an in-flight marker. Recovery must adopt
    // the orphan, not re-insert.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask('local-1', 'L1', 'create', title: 'buy milk'),
    );
    // Server already has the task from the interrupted attempt.
    client.seedTask('L1', 'remote-orphan', 'buy milk', '1');
    // In-flight marker persisted before the (crashed) finish.
    await eng.store.recordInflightCreate('local-1', 'L1');

    await eng.run();

    expect(client.callCount(Method.insertTask), 0, reason: 'no re-insert');
    final milk = (await eng.store.listTasks(
      'L1',
    )).where((t) => t.task.title == 'buy milk').toList();
    expect(milk.length, 1, reason: 'no duplicate');
    expect(milk.single.task.id, 'local-1');
    expect(milk.single.remoteId, 'remote-orphan');
    expect(milk.single.syncState, SyncState.clean);
    expect(await eng.store.inflightCreates(), isEmpty);
  });

  test('crash before insert reached server re-inserts', () async {
    // In-flight marker exists but the server never got the task. Recovery clears
    // the marker; normal push inserts.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask('local-1', 'L1', 'create', title: 'orphan-free'),
    );
    await eng.store.recordInflightCreate('local-1', 'L1');

    final out = await eng.run();
    expect(out.pushed, 1, reason: 'normal insert happened');
    expect(client.callCount(Method.insertTask), 1);
    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 1);
    expect(tasks.single.remoteId?.startsWith('remote-') ?? false, isTrue);
    expect(await eng.store.inflightCreates(), isEmpty);
  });

  test('clean create clears in-flight marker', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();
    await eng.store.upsertTask(dirtyTask('local-1', 'L1', 'create'));
    await eng.run();
    expect(await eng.store.inflightCreates(), isEmpty);
  });

  test('create commit then response timeout does not duplicate', () async {
    // The server commits the insert but the response times out. The create must
    // NOT be re-attempted in the same run, and the next run adopts the orphan.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask('local-1', 'L1', 'create', title: 'buy milk'),
    );

    // Run 1: insert commits server-side, then errors (timeout).
    client.commitThenFailNextInsert();
    await eng.run();
    expect(
      client.callCount(Method.insertTask),
      1,
      reason: 'no pass-2 re-insert',
    );
    expect(await serverCount(client, 'L1', 'buy milk'), 1);

    // Run 2: recovery adopts the orphan instead of inserting again.
    await eng.run();
    expect(client.callCount(Method.insertTask), 1, reason: 'no second insert');
    final milk = (await eng.store.listTasks(
      'L1',
    )).where((t) => t.task.title == 'buy milk').toList();
    expect(milk.length, 1, reason: 'no duplicate after recovery');
    expect(milk.single.remoteId?.startsWith('remote-') ?? false, isTrue);
    expect(await eng.store.inflightCreates(), isEmpty);
  });

  test('in-flight create waits when the recovery view is incomplete', () async {
    // The insert committed but the response was lost, so a marker is open. On
    // the NEXT run the recovery fetch fails transiently — the orphan can't be
    // seen. Pushing the create anyway would insert a second copy; an unresolved
    // marker must hold its create back until a complete remote view lets
    // recovery decide.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask('local-1', 'L1', 'create', title: 'buy milk'),
    );

    // Run 1: server commits, response lost → marker stays open.
    client.commitThenFailNextInsert();
    await eng.run();
    expect(client.callCount(Method.insertTask), 1);
    expect((await eng.store.inflightCreates()).length, 1);

    // Run 2: recovery's task fetch dies transiently before it can spot the
    // orphan. The create must wait, not re-insert.
    client.failNext(Method.listTasks, () => const ServerError(503));
    await eng.run();
    expect(
      client.callCount(Method.insertTask),
      1,
      reason: 'create re-pushed while its marker was still unresolved',
    );
    expect(await serverCount(client, 'L1', 'buy milk'), 1, reason: 'no dup');

    // Run 3: a complete view lets recovery adopt the orphan — one task.
    await eng.run();
    expect(client.callCount(Method.insertTask), 1);
    final milk = (await eng.store.listTasks(
      'L1',
    )).where((t) => t.task.title == 'buy milk').toList();
    expect(milk.length, 1, reason: 'no duplicate after recovery');
    expect(milk.single.remoteId?.startsWith('remote-') ?? false, isTrue);
    expect(await eng.store.inflightCreates(), isEmpty);
  });

  test('in-flight recovery leaves the held create id alone', () async {
    // The row the UI is holding had its create crash mid-flight, so an orphan
    // is on the server. Adopting it remaps the local id to the server id —
    // precisely what heldCreateId exists to prevent. Recovery must wait.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask('local-1', 'L1', 'create', title: 'buy milk'),
    );
    client.commitThenFailNextInsert();
    await eng.run();
    expect((await eng.store.inflightCreates()).length, 1);

    // The user opens the panel on that row, then a sync runs.
    final held = SyncEngine.withPush(
      client,
      eng.store,
      true,
    ).holdCreateId('local-1');
    await held.run();
    expect(
      (await eng.store.listTasks('L1')).any((t) => t.task.id == 'local-1'),
      isTrue,
      reason: 'the id the panel holds must not be remapped mid-edit',
    );
    expect(client.callCount(Method.insertTask), 1, reason: 'no re-insert');
    expect(
      (await eng.store.inflightCreates()).length,
      1,
      reason: 'the marker stays open until the hold clears',
    );

    // Panel closed: recovery adopts the orphan, still without duplicating.
    await eng.run();
    expect(client.callCount(Method.insertTask), 1);
    final milk = (await eng.store.listTasks(
      'L1',
    )).where((t) => t.task.title == 'buy milk').toList();
    expect(milk.length, 1);
    expect(milk.single.remoteId?.startsWith('remote-') ?? false, isTrue);
    expect(await eng.store.inflightCreates(), isEmpty);
  });

  test('crash adoption matches across due normalization', () async {
    // Orphan adoption compares content; the server orphan carries the canonical
    // due form while the local row has the short form. They must still match, or
    // the create re-inserts a dup.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask(
        'local-1',
        'L1',
        'create',
        title: 'buy milk',
        due: '2026-08-01T00:00:00Z',
      ),
    );
    client.seedTask('L1', 'remote-orphan', 'buy milk', '1');
    // Write the normalized due into the fake's state.
    await client.patchTask(
      'L1',
      'remote-orphan',
      const TaskPatch(due: '2026-08-01T00:00:00.000Z'),
    );
    await eng.store.recordInflightCreate('local-1', 'L1');

    await eng.run();

    expect(
      client.callCount(Method.insertTask),
      0,
      reason: 'adopted, not re-inserted',
    );
    final milk = (await eng.store.listTasks(
      'L1',
    )).where((t) => t.task.title == 'buy milk').toList();
    expect(milk.length, 1, reason: 'no duplicate');
    expect(milk.single.task.id, 'local-1');
    expect(milk.single.remoteId, 'remote-orphan');
  });

  // ─── Create-pass real-API semantics ────────────────────────────────────────

  test('child create waits for an unresolved parent', () async {
    // The parent's own create failed transiently this run — the child must NOT
    // be pushed with a still-local parent id (permanent 400 on the real API).
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(dirtyTask('local-p', 'L1', 'create'));
    await eng.store.upsertTask(
      dirtyTask('local-c', 'L1', 'create', parent: 'local-p'),
    );

    client.failNext(Method.insertTask, () => const ServerError(503));
    var out = await eng.run();
    expect(out.errors, 0, reason: 'no permanent 400 — the child waited');

    // Next run: parent inserts, then the child (remapped parent id).
    out = await eng.run();
    expect(out.errors, 0);
    final tasks = await eng.store.listTasks('L1');
    expect(tasks.length, 2);
    expect(tasks.every((t) => t.syncState == SyncState.clean), isTrue);
    final child = tasks.firstWhere((t) => t.task.title == 'task local-c');
    expect(
      (await eng.store.findTaskAny(
        child.task.parent!,
      ))!.remoteId!.startsWith('remote-'),
      isTrue,
      reason: 'parent id remapped',
    );
  });

  test('three-level creates resolve in one run', () async {
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(dirtyTask('l-root', 'L1', 'create'));
    await eng.store.upsertTask(
      dirtyTask('l-mid', 'L1', 'create', parent: 'l-root'),
    );
    await eng.store.upsertTask(
      dirtyTask('l-leaf', 'L1', 'create', parent: 'l-mid'),
    );

    final out = await eng.run();
    expect(out.errors, 0);
    expect(out.pushed, 3, reason: 'whole chain lands in one run');
    expect(
      (await eng.store.listTasks(
        'L1',
      )).every((t) => t.syncState == SyncState.clean),
      isTrue,
    );
  });

  test('created task adopts the server-assigned position', () async {
    // The insert response carries the server-assigned position. Discarding it
    // left the local placeholder in place forever (the adopted etag makes every
    // later pull skip the row).
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask('local-1', 'L1', 'create', position: '00000000000000000000'),
    );
    await eng.run();

    final local = (await eng.store.listTasks('L1')).single;
    final remote = (await client.listTasks('L1')).items.single;
    expect(local.task.position, remote.position);
    expect(local.task.position, isNot('00000000000000000000'));
  });

  test('subtask creates land in creation order', () async {
    // Without `previous`, the API inserts each subtask FIRST — a batch lands on
    // Google in reverse creation order. The previous-anchor keeps creation
    // order.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'P', 'parent', '1');
    await eng.run();

    final ids = ['local-a', 'local-b', 'local-c'];
    for (var i = 0; i < ids.length; i++) {
      await eng.store.upsertTask(
        dirtyTask(
          ids[i],
          'L1',
          'create',
          parent: await localIdOf(eng.store, 'P'),
          title: 'sub $i',
          localUpdated: '2026-06-01T00:00:0${i}Z',
        ),
      );
      // Push one at a time — like a user adding subtasks across syncs.
      await eng.run();
    }

    final remote =
        (await client.listTasks(
            'L1',
          )).items.where((t) => t.parent == 'P').toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    expect(remote.map((t) => t.title).toList(), [
      'sub 0',
      'sub 1',
      'sub 2',
    ], reason: 'creation order preserved on the server');
  });

  test('bare due date is normalized on push, not rejected', () async {
    // The calendar picker used to store a bare "YYYY-MM-DD"; Google 400s that
    // form. The push path must canonicalize so a legacy/imported row heals.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask('local-1', 'L1', 'create', due: '2026-08-02'),
    );

    final out = await eng.run();
    expect(out.errors, 0, reason: 'bare date must not draw a 400');
    expect(out.pushed, 1);
    final page = await client.listTasks('L1');
    expect(page.items.first.due, '2026-08-02T00:00:00.000Z');
  });

  test('two same-title local list creates do not collide', () async {
    // Both used to adopt the SAME remote list → primary-key collision on the
    // second remap → the whole run aborted with a store error.
    final (client, eng) = await engine(push: true);
    // Deliberately NOT locally tracked: adoption is the thing under test.
    client.seedList('L-remote', 'Work');

    for (final id in ['local-l1', 'local-l2']) {
      await eng.store.upsertList(
        StoredTaskList(
          list: TaskList(
            id: id,
            title: 'Work',
            updated: '2026-01-01T00:00:00Z',
          ),
          syncState: SyncState.dirty,
          localUpdated: '2026-01-01T00:00:00Z',
          pendingOp: 'create',
        ),
      );
    }

    await eng.run(); // must not throw a PK collision
    // One adopted the remote list, the other created a second remote list.
    final remote = await client.listTasklists();
    expect(remote.where((l) => l.title == 'Work').length, 2);
  });

  // ─── §G — local `create` × remote (RFC-009, P2) ────────────────────────────

  test(
    'create in a remotely-deleted list re-homes to the default list, still dirty',
    () async {
      // §G3 / D2. The user adds a task to "Work" offline; another device deletes
      // "Work" before the create reaches the server. The list goes, but the row
      // the server never saw must NOT go with it (P2): it re-homes to the default
      // list, still queued, and lands next run.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
      await seedSyncedList(client, eng.store, 'L2', 'Work');
      await eng.run();

      await eng.store.upsertTask(
        dirtyTask('local-1', 'L2', 'create', title: 'buy milk'),
      );
      await client.deleteTasklist('L2');

      await eng.run();

      expect(
        (await eng.store.allLists()).every((l) => l.list.id != 'L2'),
        isTrue,
        reason: 'the remotely-deleted list is gone locally',
      );
      expect(await placement(eng.store, 'local-1'), (
        'L1',
        null,
      ), reason: 'the unpushed create re-homed to the default list');
      final row = (await findByAnyId(eng.store, 'local-1'))!;
      expect(row.syncState, SyncState.dirty);
      expect(row.pendingOp, 'create', reason: 'still queued');
      expect(row.task.title, 'buy milk', reason: 'content untouched');

      // Still syncs: the next run pushes it into its new home.
      final out = await eng.run();
      expect(out.pushed, greaterThanOrEqualTo(1));
      expect(await serverCount(client, 'L1', 'buy milk'), 1);

      // And converges: the third run is a no-op (P7).
      final out3 = await eng.run();
      expect(out3.pushed, 0);
      expect(out3.errors, 0);
    },
  );

  test(
    're-home keeps an unpushed subtree together but the orphan dies with its parent',
    () async {
      // D2's non-happy path: the dying list holds a whole unpushed subtree AND an
      // unpushed subtask of a SYNCED parent. The subtree re-homes intact; the
      // orphan dies WITH its parent in the list cascade rather than being promoted
      // (D3 rejected).
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
      await seedSyncedList(client, eng.store, 'L2', 'Work');
      client.seedTask('L2', 'SYNCED', 'server parent', '1');
      await eng.run();

      await eng.store.upsertTask(
        dirtyTask('local-parent', 'L2', 'create', title: 'trip'),
      );
      await eng.store.upsertTask(
        dirtyTask(
          'local-child',
          'L2',
          'create',
          title: 'pack',
          parent: 'local-parent',
        ),
      );
      await eng.store.upsertTask(
        dirtyTask(
          'local-orphan',
          'L2',
          'create',
          title: 'call hotel',
          parent: await localIdOf(eng.store, 'SYNCED'),
        ),
      );

      await client.deleteTasklist('L2');
      await eng.run();

      expect(await placement(eng.store, 'local-parent'), ('L1', null));
      expect(await placement(eng.store, 'local-child'), (
        'L1',
        'local-parent',
      ), reason: 'the unpushed subtree re-homes intact');
      expect(
        await findByAnyId(eng.store, 'local-orphan'),
        isNull,
        reason: 'a subtask whose synced parent died dies with it (D3 rejected)',
      );
      expect(
        await findByAnyId(eng.store, 'SYNCED'),
        isNull,
        reason: 'the row the server knew dies with its list (P1)',
      );

      // Only the subtree survives, still one level deep, and it converges.
      await eng.run();
      final rows = await eng.store.listTasks('L1');
      expect(
        rows.length,
        2,
        reason: 'the orphan is gone; only the subtree remains',
      );
      expect(rows.every((r) => r.syncState == SyncState.clean), isTrue);
      expect(rows.every((r) => r.task.title != 'call hotel'), isTrue);
      final parentId = rows.firstWhere((r) => r.task.title == 'trip').task.id;
      expect(
        rows.firstWhere((r) => r.task.title == 'pack').task.parent,
        parentId,
        reason: 'the child follows its re-homed parent remapped id',
      );
    },
  );

  test(
    're-home with nowhere to go keeps the list as an unpushed create',
    () async {
      // D2's boundary: the ONLY list is deleted remotely while it still holds an
      // unpushed create. There is nowhere to re-home to, so the list is kept as a
      // local list create instead of being dropped — P2 holds even then.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'Work');
      await eng.run();

      await eng.store.upsertTask(
        dirtyTask('local-1', 'L1', 'create', title: 'nowhere to go'),
      );
      await client.deleteTasklist('L1');

      await eng.run();
      final l = (await eng.store.allLists()).firstWhere(
        (l) => l.list.title == 'Work',
      );
      expect(l.syncState, SyncState.dirty);
      expect(l.pendingOp, 'create');
      expect(
        (await placement(eng.store, 'local-1'))?.$2,
        null,
        reason: 'the unpushed row is still there',
      );

      // Next run: the list is re-created on the server and the row lands.
      await eng.run();
      final lists = await client.listTasklists();
      final work = lists.firstWhere((l) => l.title == 'Work');
      expect(await serverCount(client, work.id, 'nowhere to go'), 1);
      final out = await eng.run();
      expect(out.pushed, 0, reason: 'converged (P7)');
      expect(out.errors, 0);
    },
  );

  test(
    'edited parent deleted remotely takes its unpushed subtask with it',
    () async {
      // We push an edit to a parent the server already deleted (P4), and its FK
      // cascade takes the unpushed subtask with it. D3 rejected: the child dies
      // with the parent — never promoted.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
      client.seedTask('L1', 'P', 'parent', '1');
      await eng.run();

      await stageEdit(eng.store, 'P', (t) => t.copyWith(title: 'renamed here'));
      await eng.store.upsertTask(
        dirtyTask(
          'local-kid',
          'L1',
          'create',
          title: 'kept',
          parent: await localIdOf(eng.store, 'P'),
        ),
      );
      client.deleteTaskFromState('L1', 'P');

      await eng.run();

      expect(
        await findByAnyId(eng.store, 'P'),
        isNull,
        reason: 'delete wins over our edit (P4)',
      );
      expect(
        await findByAnyId(eng.store, 'local-kid'),
        isNull,
        reason: 'the unpushed subtask dies with its parent (D3 rejected)',
      );
      // No wedge: the converge run pushes nothing and the child never lands.
      final out = await eng.run();
      expect(out.pushed, 0, reason: 'converged (P7)');
      expect(out.errors, 0);
      expect(await serverCount(client, 'L1', 'kept'), 0);
    },
  );

  test('synced row in a remotely-deleted list dies with the list', () async {
    // D2's boundary (P1/P4): a row the server HAS seen dies with its list even
    // with a local edit pending. P2 only shields work the server never saw.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
    await seedSyncedList(client, eng.store, 'L2', 'Work');
    client.seedTask('L2', 'T2', 'server row', '1');
    await eng.run();

    await stageEdit(eng.store, 'T2', (t) => t.copyWith(title: 'edited here'));
    await client.deleteTasklist('L2');

    await eng.run();

    expect(
      await findByAnyId(eng.store, 'T2'),
      isNull,
      reason: 'the synced row dies with its list, edit discarded',
    );
    expect(
      await eng.store.listTasks('L1'),
      isEmpty,
      reason: 'and it is NOT re-homed into the default list',
    );
  });

  test(
    'subtask create whose parent was deleted remotely dies with its parent',
    () async {
      // §G / D3 (rejected). The user adds a subtask; another device deletes its
      // parent before the create lands. The parent's local removal FK-cascades the
      // unpushed child away — no auto-promotion.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
      client.seedTask('L1', 'P', 'parent', '1');
      await eng.run();

      await eng.store.upsertTask(
        dirtyTask(
          'local-kid',
          'L1',
          'create',
          title: 'orphaned subtask',
          parent: await localIdOf(eng.store, 'P'),
        ),
      );

      client.deleteTaskFromState('L1', 'P');
      await eng.run();

      expect(await findByAnyId(eng.store, 'P'), isNull);
      expect(
        await findByAnyId(eng.store, 'local-kid'),
        isNull,
        reason: 'the unpushed child dies with its parent (D3 rejected)',
      );

      // No wedge and nothing lands.
      final out = await eng.run();
      expect(out.pushed, 0, reason: 'converged (P7)');
      expect(out.errors, 0);
      expect(await serverCount(client, 'L1', 'orphaned subtask'), 0);
    },
  );

  test(
    'subtask create under a remotely-completed parent converges, no wedge',
    () async {
      // §G × parent completed remotely (probe 5): the insert is ACCEPTED and the
      // child is created already completed — the cascade is Google's, not ours.
      // The row must converge to `completed` locally in the same run (P6).
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
      client.seedTask('L1', 'P', 'parent', '1');
      await eng.run();

      await client.patchTask(
        'L1',
        'P',
        const TaskPatch(status: TaskStatus.completed),
      );

      await eng.store.upsertTask(
        dirtyTask(
          'local-kid',
          'L1',
          'create',
          title: 'late subtask',
          parent: await localIdOf(eng.store, 'P'),
        ),
      );

      final out = await eng.run();
      expect(out.errors, 0, reason: 'the insert is accepted, not rejected');
      final row = (await eng.store.listTasks(
        'L1',
      )).firstWhere((r) => r.task.title == 'late subtask');
      expect(
        await parentServerId(eng.store, row),
        'P',
        reason: 'still a subtask',
      );
      expect(
        row.task.status,
        TaskStatus.completed,
        reason: "Google's cascade completed it; local mirrors the server (P6)",
      );
      expect(row.syncState, SyncState.clean);

      final out2 = await eng.run();
      expect(out2.pushed, 0, reason: 'converged (P7)');
      expect(out2.errors, 0);
    },
  );

  test(
    'create racing an identical remote create: both live, no content dedup',
    () async {
      // §G. In-flight adoption is scoped to rows behind a marker. A local create
      // that merely LOOKS like a remote task (same title, no marker) must not be
      // swallowed — duplicate titles are legal.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
      await eng.run();

      client.seedTask('L1', 'remote-theirs', 'buy milk', '1');
      await eng.store.upsertTask(
        dirtyTask('local-mine', 'L1', 'create', title: 'buy milk'),
      );

      await eng.run();

      final titles = (await eng.store.listTasks('L1')).map((r) => r.task.title);
      expect(
        titles.where((t) => t == 'buy milk').length,
        2,
        reason: 'both tasks live — adoption is not content dedup',
      );
      expect(await serverCount(client, 'L1', 'buy milk'), 2);
    },
  );

  test(
    'held create survives a remote list delete and pushes after release',
    () async {
      // §G × held create. The held row is not pushed this run — and a remote list
      // delete in the same window must not destroy it either (P2). It re-homes,
      // waits for the hold to clear, then pushes.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
      await seedSyncedList(client, eng.store, 'L2', 'Work');
      await eng.run();

      await eng.store.upsertTask(
        dirtyTask('local-held', 'L2', 'create', title: 'held row'),
      );
      await client.deleteTasklist('L2');

      final engHold = SyncEngine.withPush(
        client,
        eng.store,
        true,
      ).holdCreateId('local-held');
      final out = await engHold.run();
      expect(out.pushed, 0, reason: 'the held create does not push');
      expect(await placement(eng.store, 'local-held'), (
        'L1',
        null,
      ), reason: 'but it survives the list delete, re-homed');
      expect(
        (await findByAnyId(eng.store, 'local-held'))!.task.id,
        'local-held',
        reason: 'id not remapped while held',
      );

      // Released: it pushes.
      final out2 = await eng.run();
      expect(out2.pushed, greaterThanOrEqualTo(1));
      expect(await serverCount(client, 'L1', 'held row'), 1);
    },
  );

  test('crash between re-home and push converges, no duplicate', () async {
    // P8 over the new path: the row re-homes, its insert commits on the server,
    // and the response is lost. The in-flight marker must survive the re-home,
    // so the next run adopts the orphan instead of inserting a second copy.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'My Tasks');
    await seedSyncedList(client, eng.store, 'L2', 'Work');
    await eng.run();

    await eng.store.upsertTask(
      dirtyTask('local-1', 'L2', 'create', title: 'survive me'),
    );
    await client.deleteTasklist('L2');

    // Run 1: insert into the dead list fails; the pull re-homes the row.
    await eng.run();
    expect(await placement(eng.store, 'local-1'), (
      'L1',
      null,
    ), reason: 're-homed');

    // Run 2: the insert commits but the response is lost (crash window).
    client.commitThenFailNextInsert();
    await eng.run();

    // Run 3: recovery adopts the orphan — exactly one copy on each side.
    await eng.run();
    expect(
      await serverCount(client, 'L1', 'survive me'),
      1,
      reason: 'no server dup',
    );
    final local = await eng.store.listTasks('L1');
    expect(local.length, 1);
    expect(local.single.syncState, SyncState.clean);
    expect(local.single.task.etag, isNotNull, reason: 'adopted the server row');
  });

  test('a fatal abort mid-push leaves a partial push the next run heals', () async {
    // The AbortSync crash window (#143). A run dies FATALLY partway through the
    // push: an auth error is classified Abort on every push path, so it
    // propagates out — run() throws, the steps behind it are skipped, the pull
    // never runs. The create ahead of the abort must have committed; the delete
    // that took the error must still be pending; a single healthy run converges.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'Inbox');
    client.seedTask('L1', 'goner', 'delete me', '1');
    await eng.run();

    // A brand-new create (creates push FIRST) plus a delete of the synced row
    // (deletes push AFTER creates) — so the abort lands mid-push with the create
    // already applied.
    await eng.store.upsertTask(
      dirtyTask('local-keeper', 'L1', 'create', title: 'keep me'),
    );
    final goner = (await findByAnyId(eng.store, 'goner'))!;
    await eng.store.upsertTask(
      StoredTask(
        task: goner.task,
        listId: goner.listId,
        syncState: SyncState.deleted,
        localUpdated: goner.localUpdated,
        pendingOp: 'delete',
      ),
    );

    // The delete call is fatal: an auth error aborts the whole run.
    client.failNext(Method.deleteTask, () => const Unauthorized());
    await expectLater(
      eng.run(),
      throwsA(const SyncApiError(Unauthorized())),
      reason: 'the fatal auth error aborts the run',
    );

    // The create COMMITTED before the abort: on the server exactly once, clean
    // locally, etag adopted, no base snapshot.
    expect(await serverCount(client, 'L1', 'keep me'), 1);
    final keeperRow = (await eng.store.listTasks(
      'L1',
    )).firstWhere((r) => r.task.title == 'keep me');
    expect(keeperRow.syncState, SyncState.clean);
    expect(
      keeperRow.task.etag,
      isNotNull,
      reason: 'adopted the server etag (P6)',
    );
    expect(
      await eng.store.baseSnapshot(keeperRow.task.id),
      isNull,
      reason: 'a clean row carries no lingering base snapshot (#134)',
    );
    expect(
      await eng.store.inflightCreates(),
      isEmpty,
      reason: 'the aborted run left no in-flight create marker',
    );

    // The delete did NOT apply — still pending on its row, still on the server.
    final gonerLocal = await findByAnyId(eng.store, 'goner');
    expect(gonerLocal?.pendingOp, 'delete');
    expect(
      (await client.listTasks('L1')).items.any((t) => t.id == 'goner'),
      isTrue,
    );

    // A single healthy run drains the leftover delete and converges both sides.
    final out = await eng.run();
    expect(out.deleted, 1, reason: 'the pending delete finally pushed');
    expect(
      (await eng.store.listTasks('L1')).map((r) => r.task.title).toList(),
      ['keep me'],
    );
    expect((await client.listTasks('L1')).items.map((t) => t.title).toList(), [
      'keep me',
    ]);
  });
}
