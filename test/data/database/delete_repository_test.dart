import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/delete_state_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late ManualClock clock;

  setUp(() {
    database = AppDatabase.inMemory();
    clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
  });

  tearDown(() => database.close());

  test(
    'RUN-016 delete hides a subtree and Undo restores exact identities',
    () async {
      final fixture = await _seedGraph(database);
      final repository = DatabaseTasksRepository(database, clock: clock);

      final deleted = await repository.deleteTask(
        DeleteTaskCommand(accountId: fixture.accountA, taskId: fixture.parent),
      );
      final receipt = (deleted as Success<TaskDeleteReceipt>).value;

      expect(receipt.taskId, fixture.parent);
      expect(receipt.notBefore, clock.now().add(const Duration(seconds: 30)));
      var snapshot = await repository
          .watchTasks(TasksQuery(accountId: fixture.accountA))
          .first;
      expect(snapshot.tasks.map((task) => task.id), <TaskId>[fixture.sibling]);
      expect(
        (await DeleteStateDao(
          database,
        ).readTaskDelete(fixture.accountA, fixture.parent))?.snapshotTaskIds,
        <TaskId>[fixture.parent, fixture.child],
      );

      clock.advance(const Duration(seconds: 29, milliseconds: 999));
      expect(
        await repository.undoTaskDelete(
          UndoTaskDeleteCommand(
            accountId: fixture.accountA,
            taskId: fixture.parent,
          ),
        ),
        isA<Success<void>>(),
      );

      snapshot = await repository
          .watchTasks(TasksQuery(accountId: fixture.accountA))
          .first;
      final restoredParent = snapshot.tasks.singleWhere(
        (task) => task.id == fixture.parent,
      );
      final restoredChild = snapshot.tasks.singleWhere(
        (task) => task.id == fixture.child,
      );
      expect(restoredParent.remoteId, const TaskRemoteId('remote-parent'));
      expect(restoredChild.remoteId, const TaskRemoteId('remote-child'));
      expect(restoredChild.parentTaskId, fixture.parent);
      expect(snapshot.tasks.map((task) => task.id), contains(fixture.sibling));
      expect(
        await repository
            .watchTasks(TasksQuery(accountId: fixture.accountB))
            .first
            .then((value) => value.tasks.single.id),
        fixture.otherAccountTask,
      );
    },
  );

  test(
    'RUN-016 expiry strips content and makes delete eligible exactly at boundary',
    () async {
      final fixture = await _seedGraph(database);
      final repository = DatabaseTasksRepository(database, clock: clock);
      final receipt =
          (await repository.deleteTask(
                    DeleteTaskCommand(
                      accountId: fixture.accountA,
                      taskId: fixture.parent,
                    ),
                  )
                  as Success<TaskDeleteReceipt>)
              .value;

      clock.advance(const Duration(seconds: 29, milliseconds: 999));
      expect(
        await DeleteStateDao(database).cleanupExpiredTaskDeletes(
          accountId: fixture.accountA,
          now: clock.now(),
        ),
        0,
      );
      expect(
        (await DeleteStateDao(
          database,
        ).readTaskDelete(fixture.accountA, fixture.parent))?.snapshotAvailable,
        isTrue,
      );

      clock.advance(const Duration(milliseconds: 1));
      expect(clock.now(), receipt.notBefore);
      expect(
        await DeleteStateDao(database).cleanupExpiredTaskDeletes(
          accountId: fixture.accountA,
          now: clock.now(),
        ),
        1,
      );
      final tombstone = await DeleteStateDao(
        database,
      ).readTaskDelete(fixture.accountA, fixture.parent);
      expect(tombstone?.snapshotAvailable, isFalse);
      expect(tombstone?.snapshotTaskIds, isEmpty);
      final undo = await repository.undoTaskDelete(
        UndoTaskDeleteCommand(
          accountId: fixture.accountA,
          taskId: fixture.parent,
        ),
      );
      expect((undo as Failed<void>).failure.code, 'task.delete_undo_expired');
      expect(
        await DeleteStateDao(
          database,
        ).readNextEligibleDelete(accountId: fixture.accountA, now: clock.now()),
        isNotNull,
      );
    },
  );

  test(
    'RUN-016 restart cleanup preserves target and unrelated scope',
    () async {
      final root = await Directory.systemTemp.createTemp('axiotask-delete-');
      addTearDown(() => root.delete(recursive: true));
      await database.close();
      final file = File('${root.path}/delete.sqlite');
      var reopened = await AppDatabase.openFile(file);
      final fixture = await _seedGraph(reopened);
      await DatabaseTasksRepository(reopened, clock: clock).deleteTask(
        DeleteTaskCommand(accountId: fixture.accountA, taskId: fixture.parent),
      );
      await reopened.close();

      clock.advance(const Duration(seconds: 30));
      reopened = await AppDatabase.openFile(file);
      addTearDown(reopened.close);
      expect(
        await DeleteStateDao(reopened).cleanupExpiredTaskDeletes(
          accountId: fixture.accountA,
          now: clock.now(),
        ),
        1,
      );
      expect(
        await DeleteStateDao(
          reopened,
        ).readNextEligibleDelete(accountId: fixture.accountA, now: clock.now()),
        isNotNull,
      );
      final unrelated = await DatabaseTasksRepository(
        reopened,
        clock: clock,
      ).watchTasks(TasksQuery(accountId: fixture.accountB)).first;
      expect(unrelated.tasks.single.id, fixture.otherAccountTask);
    },
  );

  test('RUN-016 restart after delete claim recovers uncertainty', () async {
    final root = await Directory.systemTemp.createTemp(
      'axiotask-delete-claim-',
    );
    addTearDown(() => root.delete(recursive: true));
    await database.close();
    final file = File('${root.path}/delete.sqlite');
    var reopened = await AppDatabase.openFile(file);
    final fixture = await _seedGraph(reopened);
    await DatabaseTasksRepository(reopened, clock: clock).deleteTask(
      DeleteTaskCommand(accountId: fixture.accountA, taskId: fixture.parent),
    );
    clock.advance(const Duration(seconds: 30));
    await DeleteStateDao(
      reopened,
    ).cleanupExpiredTaskDeletes(accountId: fixture.accountA, now: clock.now());
    await DesiredStateDao(reopened).claimTask(
      accountId: fixture.accountA,
      taskId: fixture.parent,
      claimedAt: clock.now(),
    );
    expect(
      await DeleteStateDao(
        reopened,
      ).readTaskDeleteState(fixture.accountA, fixture.parent),
      DesiredStateLifecycle.inFlight,
    );
    await reopened.close();

    reopened = await AppDatabase.openFile(file);
    addTearDown(reopened.close);
    await DatabaseReadSyncStore(
      reopened,
    ).recoverDeletes(accountId: fixture.accountA, recoveredAt: clock.now());

    expect(
      await DeleteStateDao(
        reopened,
      ).readTaskDeleteState(fixture.accountA, fixture.parent),
      DesiredStateLifecycle.uncertain,
    );
    expect(
      await DatabaseTasksRepository(reopened, clock: clock)
          .watchTasks(TasksQuery(accountId: fixture.accountB))
          .first
          .then((value) => value.tasks.single.id),
      fixture.otherAccountTask,
    );
  });

  test(
    'REL-020 list delete has no Undo snapshot and hides only its list',
    () async {
      final fixture = await _seedGraph(database);
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );

      expect(
        await repository.deleteTaskList(
          DeleteTaskListCommand(
            accountId: fixture.accountA,
            taskListId: fixture.listA,
          ),
        ),
        isA<Success<void>>(),
      );

      final accountA = await DatabaseTasksRepository(
        database,
        clock: clock,
      ).watchTasks(TasksQuery(accountId: fixture.accountA)).first;
      expect(accountA.taskLists.map((list) => list.id), <TaskListId>[
        fixture.listB,
      ]);
      expect(accountA.tasks.map((task) => task.id), <TaskId>[fixture.sibling]);
      expect(
        await DeleteStateDao(
          database,
        ).watchAvailableTaskUndos(fixture.accountA).first,
        isEmpty,
      );
      expect(
        (await DesiredStateDao(
          database,
        ).readTaskList(fixture.accountA, fixture.listA))?.desiredLifecycle,
        DesiredLifecycle.deleted,
      );
    },
  );

  test(
    'provisional task delete cancels locally after grace without DELETE',
    () async {
      final fixture = await _seedGraph(database);
      final tasks = DatabaseTasksRepository(database, clock: clock);
      final provisional =
          (await tasks.createTask(
                    CreateTaskCommand(
                      accountId: fixture.accountA,
                      taskListId: fixture.listB,
                      title: 'Never published',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      await tasks.deleteTask(
        DeleteTaskCommand(accountId: fixture.accountA, taskId: provisional),
      );

      clock.advance(const Duration(seconds: 30));
      await DeleteStateDao(database).cleanupExpiredTaskDeletes(
        accountId: fixture.accountA,
        now: clock.now(),
      );

      expect(
        await DeleteStateDao(
          database,
        ).readTaskDeleteState(fixture.accountA, provisional),
        DesiredStateLifecycle.confirmed,
      );
      expect(
        await DeleteStateDao(
          database,
        ).readNextEligibleDelete(accountId: fixture.accountA, now: clock.now()),
        isNull,
      );
    },
  );

  test(
    'provisional list delete cancels locally with no Undo or DELETE',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-local'),
      );
      final lists = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final provisional =
          (await lists.createTaskList(
                    CreateTaskListCommand(
                      accountId: account,
                      title: 'Never published',
                    ),
                  )
                  as Success<TaskListId>)
              .value;

      await lists.deleteTaskList(
        DeleteTaskListCommand(accountId: account, taskListId: provisional),
      );

      expect(
        (await DesiredStateDao(
          database,
        ).readTaskList(account, provisional))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(
        await DeleteStateDao(
          database,
        ).readNextEligibleDelete(accountId: account, now: clock.now()),
        isNull,
      );
      expect(
        await DeleteStateDao(database).watchAvailableTaskUndos(account).first,
        isEmpty,
      );
    },
  );
}

Future<
  ({
    AccountId accountA,
    AccountId accountB,
    TaskListId listA,
    TaskListId listB,
    TaskId parent,
    TaskId child,
    TaskId sibling,
    TaskId otherAccountTask,
  })
>
_seedGraph(AppDatabase database) async {
  final cache = CacheDao(database);
  final accountA = AccountId(
    await database.createAccount('synthetic-delete-a'),
  );
  final accountB = AccountId(
    await database.createAccount('synthetic-delete-b'),
  );
  final listA = await cache.putTaskList(
    accountId: accountA,
    remoteId: const TaskListRemoteId('remote-list-a'),
    title: 'Delete target',
  );
  final listB = await cache.putTaskList(
    accountId: accountA,
    remoteId: const TaskListRemoteId('remote-list-b'),
    title: 'Unrelated list',
  );
  final otherList = await cache.putTaskList(
    accountId: accountB,
    remoteId: const TaskListRemoteId('remote-list-other'),
    title: 'Other account',
  );
  await cache.putTaskListRemoteBase(
    accountId: accountA,
    taskListId: listA,
    remoteId: const TaskListRemoteId('remote-list-a'),
    title: 'Delete target',
    etag: 'list-etag-a',
    observedPublicationId: 'seed',
  );
  await cache.putTaskListRemoteBase(
    accountId: accountA,
    taskListId: listB,
    remoteId: const TaskListRemoteId('remote-list-b'),
    title: 'Unrelated list',
    etag: 'list-etag-b',
    observedPublicationId: 'seed',
  );
  final parent = await _putTask(
    cache,
    accountA,
    listA,
    const TaskRemoteId('remote-parent'),
    'Parent',
  );
  final child = await _putTask(
    cache,
    accountA,
    listA,
    const TaskRemoteId('remote-child'),
    'Child',
    parent: parent,
  );
  final sibling = await _putTask(
    cache,
    accountA,
    listB,
    const TaskRemoteId('remote-sibling'),
    'Sibling',
  );
  final otherAccountTask = await _putTask(
    cache,
    accountB,
    otherList,
    const TaskRemoteId('remote-other'),
    'Other',
  );
  return (
    accountA: accountA,
    accountB: accountB,
    listA: listA,
    listB: listB,
    parent: parent,
    child: child,
    sibling: sibling,
    otherAccountTask: otherAccountTask,
  );
}

Future<TaskId> _putTask(
  CacheDao cache,
  AccountId account,
  TaskListId list,
  TaskRemoteId remoteId,
  String title, {
  TaskId? parent,
}) async {
  final task = await cache.putTask(
    accountId: account,
    taskListId: list,
    parentTaskId: parent,
    remoteId: remoteId,
    title: title,
    position: title,
  );
  await cache.putTaskRemoteBase(
    accountId: account,
    taskId: task,
    taskListId: list,
    parentTaskId: parent,
    remoteId: remoteId,
    observedPublicationId: 'seed',
    deleted: false,
    title: title,
    status: TaskStatus.needsAction,
    position: title,
    etag: 'etag-${remoteId.value}',
    remoteUpdatedAt: DateTime.utc(2026, 8, 15, 11),
  );
  return task;
}
