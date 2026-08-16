import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'PAR-TASK-006 cascade and Undo are each atomic and survive restart',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-due-cascade-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/due.sqlite');
      final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
      var database = await AppDatabase.openFile(file);
      final fixture = await _seed(database);
      var repository = DatabaseTasksRepository(database, clock: clock);

      final result = await repository.setTaskDue(
        SetTaskDueCommand(
          accountId: fixture.account,
          taskId: fixture.parent,
          due: TaskDate(2026, 8, 15),
        ),
      );
      final undo = (result as Success<TaskDueChangeReceipt>).value.undo!;

      expect(undo.cascadedCount, 2);
      expect(undo.cascadedParent, isFalse);
      expect(await _dates(repository, fixture.account), <TaskId, TaskDate?>{
        fixture.parent: TaskDate(2026, 8, 15),
        fixture.openChild: TaskDate(2026, 8, 15),
        fixture.completedChild: TaskDate(2026, 8, 15),
        fixture.laterChild: TaskDate(2026, 8, 20),
      });
      expect(
        (await DesiredStateDao(
          database,
        ).readTask(fixture.account, fixture.parent))?.due,
        TaskDate(2026, 8, 15),
      );
      expect(
        await repository.watchUndoableTaskDueChanges(fixture.account).first,
        hasLength(1),
      );
      final noOp = await repository.setTaskDue(
        SetTaskDueCommand(
          accountId: fixture.account,
          taskId: fixture.parent,
          due: TaskDate(2026, 8, 15),
        ),
      );
      expect((noOp as Success<TaskDueChangeReceipt>).value.undo, isNull);
      expect(
        (await repository.watchUndoableTaskDueChanges(fixture.account).first)
            .single
            .groupId,
        undo.groupId,
        reason: 'a no-op date selection must not discard the available Undo',
      );

      await database.close();
      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      repository = DatabaseTasksRepository(database, clock: clock);
      final restoredUndo =
          (await repository.watchUndoableTaskDueChanges(fixture.account).first)
              .single;
      expect(restoredUndo.groupId, undo.groupId);

      final undone = await repository.undoTaskDueChange(
        UndoTaskDueChangeCommand(
          accountId: fixture.account,
          groupId: restoredUndo.groupId,
        ),
      );
      expect(undone, isA<Success<void>>());
      expect(await _dates(repository, fixture.account), <TaskId, TaskDate?>{
        fixture.parent: TaskDate(2026, 8, 10),
        fixture.openChild: TaskDate(2026, 8, 5),
        fixture.completedChild: TaskDate(2026, 8, 1),
        fixture.laterChild: TaskDate(2026, 8, 20),
      });
      expect(
        await repository.watchUndoableTaskDueChanges(fixture.account).first,
        isEmpty,
      );
    },
  );

  test('PAR-TASK-006 injected failure accepts no row in the cascade', () async {
    final database = AppDatabase.inMemory();
    addTearDown(database.close);
    final fixture = await _seed(database);
    final repository = DatabaseTasksRepository(
      database,
      clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
      transactionControl: (boundary) {
        if (boundary == DesiredStateTransactionBoundary.afterProjectionWrite) {
          throw const DesiredStatePersistenceException('synthetic_due_fault');
        }
      },
    );

    final result = await repository.setTaskDue(
      SetTaskDueCommand(
        accountId: fixture.account,
        taskId: fixture.parent,
        due: TaskDate(2026, 8, 15),
      ),
    );

    expect(result, isA<Failed<TaskDueChangeReceipt>>());
    expect(await _dates(repository, fixture.account), <TaskId, TaskDate?>{
      fixture.parent: TaskDate(2026, 8, 10),
      fixture.openChild: TaskDate(2026, 8, 5),
      fixture.completedChild: TaskDate(2026, 8, 1),
      fixture.laterChild: TaskDate(2026, 8, 20),
    });
    expect(await DesiredStateDao(database).countForAccount(fixture.account), 0);
    expect(
      await repository.watchUndoableTaskDueChanges(fixture.account).first,
      isEmpty,
    );
  });

  test('PAR-TASK-006 injected Undo failure restores no row', () async {
    final database = AppDatabase.inMemory();
    addTearDown(database.close);
    final fixture = await _seed(database);
    final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
    final repository = DatabaseTasksRepository(database, clock: clock);
    final receipt = await repository.setTaskDue(
      SetTaskDueCommand(
        accountId: fixture.account,
        taskId: fixture.parent,
        due: TaskDate(2026, 8, 15),
      ),
    );
    final undo = (receipt as Success<TaskDueChangeReceipt>).value.undo!;
    final failingRepository = DatabaseTasksRepository(
      database,
      clock: clock,
      transactionControl: (boundary) {
        if (boundary == DesiredStateTransactionBoundary.afterProjectionWrite) {
          throw const DesiredStatePersistenceException(
            'synthetic_due_undo_fault',
          );
        }
      },
    );

    final result = await failingRepository.undoTaskDueChange(
      UndoTaskDueChangeCommand(
        accountId: fixture.account,
        groupId: undo.groupId,
      ),
    );

    expect(result, isA<Failed<void>>());
    expect(await _dates(repository, fixture.account), <TaskId, TaskDate?>{
      fixture.parent: TaskDate(2026, 8, 15),
      fixture.openChild: TaskDate(2026, 8, 15),
      fixture.completedChild: TaskDate(2026, 8, 15),
      fixture.laterChild: TaskDate(2026, 8, 20),
    });
    expect(
      await repository.watchUndoableTaskDueChanges(fixture.account).first,
      hasLength(1),
    );
  });

  test(
    'cascade rejects an orphan provisional related task atomically',
    () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final account = AccountId(
        await database.createAccount('synthetic-orphan-cascade-account'),
      );
      final cache = CacheDao(database);
      final list = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-orphan-list'),
        title: 'Synthetic orphan guard',
      );
      final parent = await _putTask(
        cache,
        account,
        list,
        remote: 'orphan-parent',
        title: 'Remote parent',
        due: TaskDate(2026, 8, 10),
      );
      final orphan = await cache.putTask(
        accountId: account,
        taskListId: list,
        parentTaskId: parent,
        remoteId: null,
        title: 'Orphan provisional child',
        notes: null,
        status: TaskStatus.needsAction,
        due: TaskDate(2026, 8, 5),
        position: 'local-pending',
      );
      final repository = DatabaseTasksRepository(
        database,
        clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
      );

      final result = await repository.setTaskDue(
        SetTaskDueCommand(
          accountId: account,
          taskId: parent,
          due: TaskDate(2026, 8, 15),
        ),
      );

      expect(result, isA<Failed<TaskDueChangeReceipt>>());
      final rows = await database.select(database.taskCacheRows).get();
      expect(
        _due(rows.singleWhere((row) => row.id == parent.value).dueEpochDay),
        TaskDate(2026, 8, 10),
      );
      expect(
        _due(rows.singleWhere((row) => row.id == orphan.value).dueEpochDay),
        TaskDate(2026, 8, 5),
      );
      expect(await DesiredStateDao(database).countForAccount(account), 0);
    },
  );
}

Future<
  ({
    AccountId account,
    TaskId parent,
    TaskId openChild,
    TaskId completedChild,
    TaskId laterChild,
  })
>
_seed(AppDatabase database) async {
  final account = AccountId(
    await database.createAccount('synthetic-due-cascade-account'),
  );
  final cache = CacheDao(database);
  final list = await cache.putTaskList(
    accountId: account,
    remoteId: const TaskListRemoteId('synthetic-due-list'),
    title: 'Synthetic dates',
  );
  final parent = await _putTask(
    cache,
    account,
    list,
    remote: 'parent',
    title: 'Parent',
    due: TaskDate(2026, 8, 10),
  );
  final openChild = await _putTask(
    cache,
    account,
    list,
    remote: 'open-child',
    title: 'Open child',
    parent: parent,
    due: TaskDate(2026, 8, 5),
  );
  final completedChild = await _putTask(
    cache,
    account,
    list,
    remote: 'completed-child',
    title: 'Completed child',
    parent: parent,
    due: TaskDate(2026, 8, 1),
    status: TaskStatus.completed,
  );
  final laterChild = await _putTask(
    cache,
    account,
    list,
    remote: 'later-child',
    title: 'Later child',
    parent: parent,
    due: TaskDate(2026, 8, 20),
  );
  return (
    account: account,
    parent: parent,
    openChild: openChild,
    completedChild: completedChild,
    laterChild: laterChild,
  );
}

Future<TaskId> _putTask(
  CacheDao cache,
  AccountId account,
  TaskListId list, {
  required String remote,
  required String title,
  TaskId? parent,
  TaskDate? due,
  TaskStatus status = TaskStatus.needsAction,
}) async {
  final id = await cache.putTask(
    accountId: account,
    taskListId: list,
    parentTaskId: parent,
    remoteId: TaskRemoteId('synthetic-due-$remote'),
    title: title,
    notes: null,
    status: status,
    due: due,
    position: 'position-$remote',
  );
  await cache.putTaskRemoteBase(
    accountId: account,
    taskId: id,
    taskListId: list,
    parentTaskId: parent,
    remoteId: TaskRemoteId('synthetic-due-$remote'),
    observedPublicationId: 'synthetic-due-base',
    deleted: false,
    title: title,
    notes: null,
    status: status,
    due: due,
    position: 'position-$remote',
    etag: 'etag-$remote',
    remoteUpdatedAt: DateTime.utc(2026, 8, 15, 11),
  );
  return id;
}

Future<Map<TaskId, TaskDate?>> _dates(
  DatabaseTasksRepository repository,
  AccountId account,
) async => <TaskId, TaskDate?>{
  for (final task
      in (await repository.watchTasks(TasksQuery(accountId: account)).first)
          .tasks)
    task.id: task.due,
};

TaskDate? _due(int? epochDay) {
  if (epochDay == null) return null;
  final value = DateTime.fromMillisecondsSinceEpoch(
    epochDay * Duration.millisecondsPerDay,
    isUtc: true,
  );
  return TaskDate(value.year, value.month, value.day);
}
