// Protects the cross-list "All Tasks" read (allTasks / watchAllTasks): it
// aggregates every list, excludes tombstones, keeps top-level rows sortable
// ahead of subtasks, and its stream re-emits on a write in ANY list. This is
// the read the All-Tasks view subscribes to; a per-list-only store would fail
// the cross-list aggregation assertion.

import 'package:async/async.dart';
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

StoredTaskList listOf(String id) => StoredTaskList(
  list: TaskList(id: id, title: 'L$id', etag: 'e1', updated: _t0),
  syncState: SyncState.clean,
  localUpdated: _t0,
);

StoredTask taskOf(
  String id,
  String listId,
  String position, {
  String? parent,
  SyncState sync = SyncState.clean,
  String? pendingOp,
}) => StoredTask(
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
  syncState: sync,
  localUpdated: _t0,
  pendingOp: pendingOp,
);

void main() {
  test('allTasks aggregates visible tasks across every list', () async {
    final store = await freshStore();
    await store.upsertList(listOf('A'));
    await store.upsertList(listOf('B'));
    await store.upsertTask(taskOf('a1', 'A', '1'));
    await store.upsertTask(taskOf('b1', 'B', '1'));

    final ids = (await store.allTasks()).map((t) => t.task.id).toSet();
    expect(ids, {'a1', 'b1'});
  });

  test('allTasks excludes tombstones', () async {
    final store = await freshStore();
    await store.upsertList(listOf('A'));
    await store.upsertTask(taskOf('a1', 'A', '1'));
    await store.upsertTask(
      taskOf('a2', 'A', '2', sync: SyncState.deleted, pendingOp: 'delete'),
    );

    final ids = (await store.allTasks()).map((t) => t.task.id).toList();
    expect(ids, ['a1']);
  });

  test('allTasks orders top-level rows before subtasks', () async {
    final store = await freshStore();
    await store.upsertList(listOf('A'));
    await store.upsertTask(taskOf('p', 'A', '1'));
    await store.upsertTask(taskOf('c', 'A', '1', parent: 'p'));

    final rows = await store.allTasks();
    expect(rows.first.task.id, 'p'); // parent (top-level) sorts ahead
    expect(rows.map((t) => t.task.id), containsAll(['p', 'c']));
  });

  test('watchAllTasks re-emits when a task is written in any list', () async {
    final store = await freshStore();
    await store.upsertList(listOf('A'));
    await store.upsertList(listOf('B'));

    final q = StreamQueue(store.watchAllTasks());
    expect(await q.next, isEmpty); // initial

    await store.upsertTask(taskOf('a1', 'A', '1'));
    expect((await q.next).map((t) => t.task.id), ['a1']);

    // A write in a DIFFERENT list still fires the same stream.
    await store.upsertTask(taskOf('b1', 'B', '1'));
    expect((await q.next).map((t) => t.task.id).toSet(), {'a1', 'b1'});

    await q.cancel();
  });

  // ── Pull-storm rebuild-count guard (T10.1 / MIGRATION-PLAN §4) ──────────────
  // drift invalidation is table-granular: EVERY write to `tasks` re-runs the
  // watch query and, unguarded, delivers a fresh List even when the visible set
  // is byte-for-byte identical (probed: five no-op upserts deliver five
  // redundant `[a1]` events once the event loop is drained between them). A sync
  // pull that rewrites many rows to the SAME content (mark-clean sweeps, no-op
  // re-pulls, subtask-only writes) would then storm the All-Tasks view with
  // redundant emissions — one full rebuild each. watchAllTasks must collapse
  // consecutive identical results so a storm of no-op writes costs ZERO extra
  // emissions; a genuine change still emits.
  //
  // `pumpEventQueue` between writes forces drift's re-query to actually deliver
  // (without it, drift coalesces the awaited writes into a single re-query and
  // the storm never materialises — the guard would look effective when it is
  // not). We assert on the full delivered sequence: exactly the initial state
  // and the one genuine change, nothing in between.
  test(
    'watchAllTasks suppresses identical re-emissions (pull-storm dedup)',
    () async {
      final store = await freshStore();
      await store.upsertList(listOf('A'));
      await store.upsertTask(taskOf('a1', 'A', '1'));

      final events = <List<String>>[];
      final sub = store.watchAllTasks().listen(
        (e) => events.add([for (final t in e) t.task.id]),
      );
      await pumpEventQueue();
      expect(events, [
        ['a1'],
      ]); // initial

      // Pull storm: rewrite a1 with byte-identical content, draining between each
      // so every no-op re-query is delivered (or, once guarded, suppressed).
      for (var i = 0; i < 5; i++) {
        await store.upsertTask(taskOf('a1', 'A', '1'));
        await pumpEventQueue();
      }
      // Then one write that actually changes the visible set.
      await store.upsertTask(taskOf('a2', 'A', '2'));
      await pumpEventQueue();

      // The five no-op rewrites produced NO emission; only the initial state and
      // the genuine change were delivered. Unguarded, this list holds seven
      // events (six `[a1]` + one `[a1, a2]`).
      expect(events, [
        ['a1'],
        ['a1', 'a2'],
      ]);
      await sub.cancel();
    },
  );
}
