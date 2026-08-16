import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/bulk_operations.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late ManualClock clock;
  late _Fixture fixture;

  setUp(() async {
    database = AppDatabase.inMemory();
    clock = ManualClock(DateTime.utc(2026, 8, 16, 14));
    fixture = await _seed(database);
  });

  tearDown(() => database.close());

  test(
    'PAR-BULK-002 complete acknowledges every row in one transaction',
    () async {
      final repository = DatabaseTasksRepository(database, clock: clock);

      final result = await repository.applyBulk(
        BulkCompleteTasksCommand(
          accountId: fixture.account,
          taskIds: <TaskId>{fixture.parent, fixture.child, fixture.other},
        ),
      );

      final receipt = (result as Success<BulkOperationReceipt>).value;
      expect(receipt.summary.kind, BulkOperationKind.complete);
      expect(receipt.summary.selectedCount, 3);
      expect(receipt.summary.affectedCount, 3);
      expect(receipt.summary.confirmedCount, 0);
      expect(receipt.summary.pendingCount, 3);
      expect(receipt.summary.failedCount, 0);
      final snapshot = await repository
          .watchTasks(TasksQuery(accountId: fixture.account))
          .first;
      expect(
        snapshot.tasks
            .where((task) => receipt.taskIds.contains(task.id))
            .every((task) => task.status == TaskStatus.completed),
        isTrue,
      );
      expect(await _taskDesiredCount(database, fixture.account), 3);
    },
  );

  test(
    'bulk due cascade creates one desired row per affected resource',
    () async {
      final repository = DatabaseTasksRepository(database, clock: clock);

      final result = await repository.applyBulk(
        BulkRescheduleTasksCommand(
          accountId: fixture.account,
          taskIds: <TaskId>{fixture.parent},
          due: TaskDate(2026, 8, 15),
        ),
      );

      final receipt = (result as Success<BulkOperationReceipt>).value;
      expect(receipt.summary.affectedCount, 2);
      expect(receipt.summary.pendingCount, 2);
      final tasks =
          (await repository
                  .watchTasks(TasksQuery(accountId: fixture.account))
                  .first)
              .tasks;
      expect(
        tasks.singleWhere((task) => task.id == fixture.parent).due,
        TaskDate(2026, 8, 15),
      );
      expect(
        tasks.singleWhere((task) => task.id == fixture.child).due,
        TaskDate(2026, 8, 15),
      );
      expect(await _taskDesiredCount(database, fixture.account), 2);
    },
  );

  test(
    'mixed parent-child move records only independent Google roots',
    () async {
      final repository = DatabaseTasksRepository(database, clock: clock);

      final result = await repository.applyBulk(
        BulkMoveTasksCommand(
          accountId: fixture.account,
          taskIds: <TaskId>{fixture.parent, fixture.child},
          destinationTaskListId: fixture.destination,
        ),
      );

      final receipt = (result as Success<BulkOperationReceipt>).value;
      expect(receipt.summary.selectedCount, 2);
      expect(receipt.summary.affectedCount, 1);
      expect(receipt.taskIds, <TaskId>[fixture.parent]);
      final tasks =
          (await repository
                  .watchTasks(TasksQuery(accountId: fixture.account))
                  .first)
              .tasks;
      expect(
        tasks.singleWhere((task) => task.id == fixture.parent).taskListId,
        fixture.destination,
      );
      expect(
        tasks.singleWhere((task) => task.id == fixture.child).taskListId,
        fixture.destination,
      );
      expect(
        tasks.singleWhere((task) => task.id == fixture.child).parentTaskId,
        fixture.parent,
      );
      expect(await _taskDesiredCount(database, fixture.account), 1);
    },
  );

  test('every invalid selection or destination accepts nothing', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);
    final cache = CacheDao(database);
    final unsupported = await cache.putTask(
      accountId: fixture.account,
      taskListId: fixture.source,
      remoteId: const TaskRemoteId('unsupported-selection'),
      title: 'Unsupported selection',
      position: 'unsupported-selection',
      projection: CacheProjection.unsupported,
    );
    final deleted = await cache.putTask(
      accountId: fixture.account,
      taskListId: fixture.source,
      remoteId: const TaskRemoteId('deleted-selection'),
      title: 'Deleted selection',
      position: 'deleted-selection',
      projection: CacheProjection.deleted,
    );
    final unsynchronizable = await cache.putTask(
      accountId: fixture.account,
      taskListId: fixture.source,
      remoteId: null,
      title: 'Unpublished selection',
      position: 'unpublished-selection',
    );
    final unsupportedDestination = await cache.putTaskList(
      accountId: fixture.account,
      remoteId: const TaskListRemoteId('unsupported-destination'),
      title: 'Unsupported destination',
      projection: CacheProjection.unsupported,
    );
    final unsynchronizableDestination = await cache.putTaskList(
      accountId: fixture.account,
      remoteId: null,
      title: 'Unpublished destination',
    );
    final otherAccount = AccountId(
      await database.createAccount('synthetic-bulk-other'),
    );
    final otherTask = await _putTask(
      CacheDao(database),
      otherAccount,
      await CacheDao(database).putTaskList(
        accountId: otherAccount,
        remoteId: const TaskListRemoteId('other-list'),
        title: 'Other list',
      ),
      'other-task',
    );

    for (final command in <BulkExistingTaskCommand>[
      const BulkCompleteTasksCommand(
        accountId: AccountId(1),
        taskIds: <TaskId>{},
      ),
      BulkCompleteTasksCommand(
        accountId: const AccountId(999),
        taskIds: <TaskId>{const TaskId(1)},
      ),
      BulkCompleteTasksCommand(
        accountId: fixture.account,
        taskIds: <TaskId>{const TaskId(999999)},
      ),
      BulkCompleteTasksCommand(
        accountId: fixture.account,
        taskIds: <TaskId>{fixture.parent, otherTask},
      ),
      BulkCompleteTasksCommand(
        accountId: fixture.account,
        taskIds: <TaskId>{fixture.parent, unsupported},
      ),
      BulkCompleteTasksCommand(
        accountId: fixture.account,
        taskIds: <TaskId>{fixture.parent, deleted},
      ),
      BulkCompleteTasksCommand(
        accountId: fixture.account,
        taskIds: <TaskId>{fixture.parent, unsynchronizable},
      ),
      BulkMoveTasksCommand(
        accountId: fixture.account,
        taskIds: <TaskId>{fixture.parent},
        destinationTaskListId: const TaskListId(999999),
      ),
      BulkMoveTasksCommand(
        accountId: fixture.account,
        taskIds: <TaskId>{fixture.parent},
        destinationTaskListId: unsupportedDestination,
      ),
      BulkMoveTasksCommand(
        accountId: fixture.account,
        taskIds: <TaskId>{fixture.parent},
        destinationTaskListId: unsynchronizableDestination,
      ),
    ]) {
      expect(
        await repository.applyBulk(command),
        isA<Failed<BulkOperationReceipt>>(),
      );
    }
    expect(await _taskDesiredCount(database, fixture.account), 0);
    expect(
      await repository.watchLatestBulkOperation(fixture.account).first,
      isNull,
    );
  });

  test(
    'failure after a later desired write rolls back the complete operation',
    () async {
      var writes = 0;
      final repository = DatabaseTasksRepository(
        database,
        clock: clock,
        transactionControl: (boundary) {
          if (boundary ==
                  DesiredStateTransactionBoundary.afterDesiredStateWrite &&
              ++writes == 2) {
            throw const DesiredStatePersistenceException(
              'synthetic_bulk_update_failure',
            );
          }
        },
      );

      final result = await repository.applyBulk(
        BulkCompleteTasksCommand(
          accountId: fixture.account,
          taskIds: <TaskId>{fixture.parent, fixture.child, fixture.other},
        ),
      );

      expect(result, isA<Failed<BulkOperationReceipt>>());
      final snapshot = await repository
          .watchTasks(TasksQuery(accountId: fixture.account))
          .first;
      expect(
        snapshot.tasks.every((task) => task.status == TaskStatus.needsAction),
        isTrue,
      );
      expect(await _taskDesiredCount(database, fixture.account), 0);
      expect(
        await repository.watchLatestBulkOperation(fixture.account).first,
        isNull,
      );
    },
  );

  for (final boundary in <DesiredStateTransactionBoundary>[
    DesiredStateTransactionBoundary.afterProjectionWrite,
    DesiredStateTransactionBoundary.beforeLocalCommit,
  ]) {
    test(
      'failure at ${boundary.name} rolls back rows, intent, and result',
      () async {
        final repository = DatabaseTasksRepository(
          database,
          clock: clock,
          transactionControl: (reached) {
            if (reached == boundary) {
              throw const DesiredStatePersistenceException(
                'synthetic_bulk_boundary_failure',
              );
            }
          },
        );

        expect(
          await repository.applyBulk(
            BulkCompleteTasksCommand(
              accountId: fixture.account,
              taskIds: <TaskId>{fixture.parent, fixture.other},
            ),
          ),
          isA<Failed<BulkOperationReceipt>>(),
        );
        final snapshot = await repository
            .watchTasks(TasksQuery(accountId: fixture.account))
            .first;
        expect(
          snapshot.tasks.every((task) => task.status == TaskStatus.needsAction),
          isTrue,
        );
        expect(await _taskDesiredCount(database, fixture.account), 0);
        expect(
          await repository.watchLatestBulkOperation(fixture.account).first,
          isNull,
        );
      },
    );
  }

  test('exact pending summary survives file restart', () async {
    await database.close();
    final directory = await Directory.systemTemp.createTemp(
      'axiotask-bulk-update-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/isolated.sqlite');
    database = await AppDatabase.openFile(file);
    fixture = await _seed(database);
    final repository = DatabaseTasksRepository(database, clock: clock);
    await repository.applyBulk(
      BulkCompleteTasksCommand(
        accountId: fixture.account,
        taskIds: <TaskId>{fixture.parent, fixture.other},
      ),
    );
    await database.close();

    database = await AppDatabase.openFile(file);
    final summary = await DatabaseTasksRepository(
      database,
      clock: clock,
    ).watchLatestBulkOperation(fixture.account).first;

    expect(summary?.selectedCount, 2);
    expect(summary?.affectedCount, 2);
    expect(summary?.confirmedCount, 0);
    expect(summary?.pendingCount, 2);
    expect(summary?.failedCount, 0);
  });
}

Future<int> _taskDesiredCount(AppDatabase database, AccountId account) async {
  final row = await database
      .customSelect(
        "SELECT COUNT(*) AS count FROM desired_states WHERE account_id = ?1 AND resource_type = 'task'",
        variables: <Variable<Object>>[Variable<int>(account.value)],
      )
      .getSingle();
  return row.read<int>('count');
}

final class _Fixture {
  const _Fixture({
    required this.account,
    required this.source,
    required this.destination,
    required this.parent,
    required this.child,
    required this.other,
  });

  final AccountId account;
  final TaskListId source;
  final TaskListId destination;
  final TaskId parent;
  final TaskId child;
  final TaskId other;
}

Future<_Fixture> _seed(AppDatabase database) async {
  final account = AccountId(
    await database.createAccount('synthetic-bulk-operations'),
  );
  final cache = CacheDao(database);
  final source = await cache.putTaskList(
    accountId: account,
    remoteId: const TaskListRemoteId('bulk-source'),
    title: 'Bulk source',
  );
  final destination = await cache.putTaskList(
    accountId: account,
    remoteId: const TaskListRemoteId('bulk-destination'),
    title: 'Bulk destination',
  );
  final parent = await _putTask(
    cache,
    account,
    source,
    'bulk-parent',
    due: TaskDate(2026, 8, 10),
  );
  final child = await _putTask(
    cache,
    account,
    source,
    'bulk-child',
    parentTaskId: parent,
    due: TaskDate(2026, 8, 5),
  );
  final other = await _putTask(cache, account, source, 'bulk-other');
  return _Fixture(
    account: account,
    source: source,
    destination: destination,
    parent: parent,
    child: child,
    other: other,
  );
}

Future<TaskId> _putTask(
  CacheDao cache,
  AccountId account,
  TaskListId list,
  String remoteId, {
  TaskId? parentTaskId,
  TaskDate? due,
}) async {
  final id = await cache.putTask(
    accountId: account,
    taskListId: list,
    parentTaskId: parentTaskId,
    remoteId: TaskRemoteId(remoteId),
    title: remoteId,
    due: due,
    position: remoteId,
  );
  await cache.putTaskRemoteBase(
    accountId: account,
    taskId: id,
    taskListId: list,
    parentTaskId: parentTaskId,
    remoteId: TaskRemoteId(remoteId),
    title: remoteId,
    notes: null,
    status: TaskStatus.needsAction,
    due: due,
    position: remoteId,
    etag: 'etag-$remoteId',
    remoteUpdatedAt: DateTime.utc(2026, 8, 16, 13),
    observedPublicationId: 'seed-bulk',
    deleted: false,
  );
  return id;
}
