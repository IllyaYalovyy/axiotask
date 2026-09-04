// Every multi-row command is ONE transaction (#271). These tests inject a fault
// part-way through each such command and assert the store is EXACTLY as it was
// before — no half-applied state.
//
// Why it matters: on Android the process can be killed at any await. Written
// row-by-row (N autocommits), a kill mid-`deleteList` hard-deletes some tasks
// and never tombstones the list — never-pushed tasks are lost while the list
// stays visible; a kill mid-`undoDelete` revives the root and loses its
// subtasks; a kill mid-`setDue` leaves the child dated before its parent,
// violating the #164 invariant locally. The assertions read the ROWS the store
// holds after the fault, never which method ran.

import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

const _t0 = '2026-01-01T00:00:00Z';

Future<FaultingStore> faultingStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return FaultingStore(db);
}

/// A synced (server-backed) list — Google acknowledged it, so it carries a
/// `remote_id` and its rows are pushable.
Future<void> seedList(Store store, String id, {String? remoteId = 'same'}) =>
    store.upsertList(
      StoredTaskList(
        list: TaskList(id: id, title: 'Inbox', etag: 'e1', updated: _t0),
        syncState: SyncState.clean,
        localUpdated: _t0,
        remoteId: remoteId == 'same' ? id : remoteId,
      ),
    );

/// An already-pushed (clean, server-backed) task.
Future<void> seedTask(
  Store store,
  String id,
  String listId,
  String title, {
  String? parent,
  String? due,
  String position = '1',
  TaskStatus status = TaskStatus.needsAction,
}) => store.upsertTask(
  StoredTask(
    task: Task(
      id: id,
      parent: parent,
      position: position,
      title: title,
      status: status,
      due: due,
      completed: status == TaskStatus.completed ? _t0 : null,
      etag: 'e1',
      updated: _t0,
    ),
    listId: listId,
    syncState: SyncState.clean,
    localUpdated: _t0,
    remoteId: id,
  ),
);

Future<StoredTask> taskRow(Store store, String id) async {
  final t = await store.findTaskAny(id);
  expect(t, isNotNull, reason: 'row $id must still exist');
  return t!;
}

void main() {
  group('toggleComplete cascade', () {
    // A parent completing its open subtasks is ONE unit: half a cascade leaves
    // the parent done with an open child under it, which the list then renders
    // as "1/2 done" against a row the user saw tick.
    test('a fault mid-cascade leaves nothing completed', () async {
      final store = await faultingStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent');
      await seedTask(store, 'C1', 'L1', 'one', parent: 'P', position: '2');
      await seedTask(store, 'C2', 'L1', 'two', parent: 'P', position: '3');

      store.failOnTaskWrite(2);
      await expectLater(
        commands.toggleComplete('P'),
        throwsA(anything),
        reason: 'the second row write faults',
      );

      for (final id in ['P', 'C1', 'C2']) {
        expect(
          (await taskRow(store, id)).task.status,
          TaskStatus.needsAction,
          reason: '$id must roll back with the failed cascade',
        );
      }
    });
  });

  group('setDue cascade', () {
    // #164: a subtask's date is never before its parent's. Dating the CHILD
    // earlier pulls the parent down — if only the child's write lands, the
    // local store violates the invariant it exists to keep.
    test('a fault pulling the parent down leaves both dates alone', () async {
      final store = await faultingStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(
        store,
        'P',
        'L1',
        'parent',
        due: '2026-06-10T00:00:00.000Z',
      );
      await seedTask(store, 'C', 'L1', 'child', parent: 'P', position: '2');

      store.failOnTaskWrite(2);
      await expectLater(
        commands.setDueRaw('C', '2026-06-05'),
        throwsA(anything),
        reason: 'the parent write (the cascade) faults',
      );

      expect(
        (await taskRow(store, 'C')).task.due,
        isNull,
        reason: 'the edited row rolls back with its cascade',
      );
      expect(
        (await taskRow(store, 'P')).task.due,
        '2026-06-10T00:00:00.000Z',
        reason: 'the parent never moved',
      );
    });
  });

  group('undoToggleComplete', () {
    // Undo of a cascading completion reopens the exact set the completion
    // flipped. A half-applied undo reopens the parent and leaves its subtask
    // completed — the pre-swipe state the user asked for is not restored.
    test('a fault mid-undo reopens nothing', () async {
      final store = await faultingStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent', status: TaskStatus.completed);
      await seedTask(
        store,
        'C',
        'L1',
        'child',
        parent: 'P',
        position: '2',
        status: TaskStatus.completed,
      );

      store.failOnTaskWrite(2);
      await expectLater(
        commands.undoToggleComplete(
          const CompleteToken(
            id: 'P',
            wasCompleting: true,
            cascadedReopenIds: ['C'],
          ),
        ),
        throwsA(anything),
      );

      for (final id in ['P', 'C']) {
        expect(
          (await taskRow(store, id)).task.status,
          TaskStatus.completed,
          reason: '$id must stay completed — the undo did not apply',
        );
      }
    });
  });

  group('undoSetDue', () {
    // The date edit and its cascade revert as ONE unit; a partial revert leaves
    // the same broken pairing the forward edit was careful to avoid.
    test('a fault mid-revert restores no date', () async {
      final store = await faultingStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(
        store,
        'P',
        'L1',
        'parent',
        due: '2026-06-05T00:00:00.000Z',
      );
      await seedTask(
        store,
        'C',
        'L1',
        'child',
        parent: 'P',
        position: '2',
        due: '2026-06-05T00:00:00.000Z',
      );

      store.failOnTaskWrite(2);
      await expectLater(
        commands.undoSetDue(const [
          DueUndoEntry(id: 'C', due: null),
          DueUndoEntry(id: 'P', due: '2026-06-10T00:00:00.000Z'),
        ]),
        throwsA(anything),
      );

      expect(
        (await taskRow(store, 'C')).task.due,
        '2026-06-05T00:00:00.000Z',
        reason: 'the first revert rolled back with the second',
      );
      expect((await taskRow(store, 'P')).task.due, '2026-06-05T00:00:00.000Z');
    });
  });

  group('undoDelete', () {
    // Undoing the delete of a parent must bring the whole subtree back. A
    // half-applied undo revives the root alone and the subtasks stay
    // tombstoned — silent data loss dressed up as a successful undo.
    test('a fault restoring the subtree revives nothing', () async {
      final store = await faultingStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent');
      await seedTask(store, 'C', 'L1', 'child', parent: 'P', position: '2');

      final token = await commands.deleteTask('P');
      expect(await store.listTasks('L1'), isEmpty, reason: 'both tombstoned');

      store.failOnTaskWrite(2);
      await expectLater(commands.undoDelete(token), throwsA(anything));

      expect(
        await store.listTasks('L1'),
        isEmpty,
        reason: 'the root revive rolled back with the failed subtree restore',
      );
    });
  });

  group('clearCompleted', () {
    // Clearing a list is one user gesture; a fault part-way through must not
    // leave half the completed rows deleted with no report of what went.
    test('a fault mid-clear deletes nothing', () async {
      final store = await faultingStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(
        store,
        'T1',
        'L1',
        'done one',
        status: TaskStatus.completed,
      );
      await seedTask(
        store,
        'T2',
        'L1',
        'done two',
        position: '2',
        status: TaskStatus.completed,
      );

      store.failOnTaskWrite(2);
      await expectLater(commands.clearCompleted('L1'), throwsA(anything));

      expect((await store.listTasks('L1')).map((t) => t.task.id).toSet(), {
        'T1',
        'T2',
      }, reason: 'no row is cleared unless every row is');
    });
  });

  group('undoMoveToList', () {
    // A composed command: it deletes the moved CLONE and restores the original
    // subtree. As two separate writes, a fault between them leaves the clone
    // gone and the original still tombstoned — the task exists in NEITHER list,
    // which is the undo button losing the task it was pressed to save.
    test('a fault mid-undo leaves the moved task in the target list', () async {
      final store = await faultingStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedList(store, 'L2');
      await seedTask(store, 'T1', 'L1', 'buy milk');

      final token = await commands.moveTaskToList('T1', 'L2');
      expect(token, isNotNull);
      final clonedId = token!.newRootId;

      // Fault on the restore write, after the clone's removal has been issued.
      store.failOnTaskWrite(2);
      await expectLater(commands.undoMoveToList(token), throwsA(anything));

      final clone = await store.findTaskAny(clonedId);
      expect(
        clone,
        isNotNull,
        reason: 'the clone removal rolled back with the failed restore',
      );
      expect(
        clone!.syncState,
        isNot(SyncState.deleted),
        reason: 'the moved task is still live in the target list',
      );
      expect(
        (await store.listTasks('L2')).map((t) => t.task.id),
        contains(clonedId),
        reason: 'the user can still see — and undo — the moved task',
      );
    });
  });

  group('deleteList', () {
    // The worst of the set: the task rows are removed first and the list
    // tombstone last. A fault in between loses every never-pushed task in the
    // list while the list itself stays visible and undeleted.
    test('a fault tombstoning the list keeps its tasks', () async {
      final store = await faultingStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'one');
      await seedTask(store, 'T2', 'L1', 'two', position: '2');

      store.failOnListWrite();
      await expectLater(commands.deleteList('L1'), throwsA(anything));

      expect((await store.listTasks('L1')).map((t) => t.task.id).toSet(), {
        'T1',
        'T2',
      }, reason: 'the tasks roll back with the failed tombstone');
      expect(
        (await store.allLists()).map((l) => l.list.id),
        contains('L1'),
        reason: 'the list is still there — nothing was deleted',
      );
    });

    // The never-synced branch: no tombstone, the list row is dropped outright.
    test('a fault dropping a never-synced list keeps its tasks', () async {
      final store = await faultingStore();
      final commands = Commands(store);
      await seedList(store, 'L1', remoteId: null);
      await seedTask(store, 'T1', 'L1', 'one');
      await seedTask(store, 'T2', 'L1', 'two', position: '2');

      store.failOnListHardDelete();
      await expectLater(commands.deleteList('L1'), throwsA(anything));

      expect((await store.listTasks('L1')).map((t) => t.task.id).toSet(), {
        'T1',
        'T2',
      }, reason: 'the tasks roll back with the failed list delete');
      expect((await store.allLists()).map((l) => l.list.id), contains('L1'));
    });
  });
}

/// A store whose Nth write to the `tasks` table (or whose list write) faults —
/// standing in for the process dying, or the disk erroring, part-way through a
/// multi-row command. Counts EVERY task-row write path a command can take
/// (upsert, tombstone, hard delete) so the ordinal means the same thing however
/// the command spells its writes.
class FaultingStore extends Store {
  FaultingStore(super.db);

  int? _failTaskWrite;
  int _taskWrites = 0;
  bool _failListWrite = false;
  bool _failListHardDelete = false;

  /// Arm: the [nth] task-row write from now on throws.
  void failOnTaskWrite(int nth) {
    _failTaskWrite = nth;
    _taskWrites = 0;
  }

  /// Arm: the next list-row write throws.
  void failOnListWrite() => _failListWrite = true;

  /// Arm: the next hard list delete throws.
  void failOnListHardDelete() => _failListHardDelete = true;

  void _countTaskWrite() {
    if (++_taskWrites == _failTaskWrite) {
      throw StateError('injected fault on task write #$_taskWrites');
    }
  }

  @override
  Future<void> upsertTask(StoredTask t) async {
    _countTaskWrite();
    return super.upsertTask(t);
  }

  @override
  Future<void> tombstoneSubtree(
    String rootId,
    List<String> descendantIds,
    String now,
  ) async {
    _countTaskWrite();
    return super.tombstoneSubtree(rootId, descendantIds, now);
  }

  @override
  Future<void> deleteTaskHard(String id) async {
    _countTaskWrite();
    return super.deleteTaskHard(id);
  }

  @override
  Future<void> upsertList(StoredTaskList list) async {
    if (_failListWrite) throw StateError('injected fault on the list write');
    return super.upsertList(list);
  }

  @override
  Future<void> deleteListHard(String id) async {
    if (_failListHardDelete) {
      throw StateError('injected fault on the list hard delete');
    }
    return super.deleteListHard(id);
  }
}
