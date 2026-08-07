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
}
