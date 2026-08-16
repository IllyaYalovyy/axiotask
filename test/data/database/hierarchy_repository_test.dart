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
  late AppDatabase database;
  late ManualClock clock;

  setUp(() {
    database = AppDatabase.inMemory();
    clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
  });
  tearDown(() => database.close());

  test('REC-022 promote and demote persist only a structure facet', () async {
    final fixture = await _seed(database, 'hierarchy');
    final repository = DatabaseTasksRepository(database, clock: clock);

    expect(
      await repository.apply(
        DemoteTaskCommand(
          accountId: fixture.account,
          taskId: fixture.task,
          parentTaskId: fixture.parent,
        ),
      ),
      isA<Success<void>>(),
    );
    var snapshot = await repository
        .watchTasks(TasksQuery(accountId: fixture.account))
        .first;
    expect(
      snapshot.tasks
          .singleWhere((task) => task.id == fixture.task)
          .parentTaskId,
      fixture.parent,
    );
    var desired = await DesiredStateDao(
      database,
    ).readTask(fixture.account, fixture.task);
    expect(desired?.parentTaskId, fixture.parent);
    expect(desired?.structureDirty, isTrue);
    expect(desired?.contentDirty, isFalse);

    expect(
      await repository.apply(
        PromoteTaskCommand(accountId: fixture.account, taskId: fixture.task),
      ),
      isA<Success<void>>(),
    );
    snapshot = await repository
        .watchTasks(TasksQuery(accountId: fixture.account))
        .first;
    expect(
      snapshot.tasks
          .singleWhere((task) => task.id == fixture.task)
          .parentTaskId,
      isNull,
    );
    desired = await DesiredStateDao(
      database,
    ).readTask(fixture.account, fixture.task);
    expect(desired?.parentTaskId, isNull);
    expect(desired?.generation, 2);
  });

  test('REC-022 invalid parents and depth commit nothing', () async {
    final fixture = await _seed(database, 'validation');
    final cache = CacheDao(database);
    final otherList = await _putList(
      database,
      fixture.account,
      'validation-other',
    );
    final crossList = await cache.putTask(
      accountId: fixture.account,
      taskListId: otherList,
      remoteId: const TaskRemoteId('cross-list'),
      title: 'Cross list',
      position: '1',
    );
    final accountB = AccountId(await database.createAccount('validation-b'));
    final listB = await _putList(database, accountB, 'validation-b-list');
    final crossAccount = await cache.putTask(
      accountId: accountB,
      taskListId: listB,
      remoteId: const TaskRemoteId('cross-account'),
      title: 'Cross account',
      position: '1',
    );
    final deleted = await cache.putTask(
      accountId: fixture.account,
      taskListId: fixture.list,
      remoteId: const TaskRemoteId('deleted-parent'),
      title: 'Deleted',
      position: '3',
      projection: CacheProjection.deleted,
    );
    final child = await cache.putTask(
      accountId: fixture.account,
      taskListId: fixture.list,
      parentTaskId: fixture.parent,
      remoteId: const TaskRemoteId('child-parent'),
      title: 'Child',
      position: '4',
    );
    final repository = DatabaseTasksRepository(database, clock: clock);

    Future<String> reject(TaskId parent) async =>
        ((await repository.apply(
                  DemoteTaskCommand(
                    accountId: fixture.account,
                    taskId: fixture.task,
                    parentTaskId: parent,
                  ),
                ))
                as Failed<void>)
            .failure
            .code;

    expect(await reject(crossList), 'task.parent_cross_list');
    expect(await reject(crossAccount), 'task.parent_cross_account');
    expect(await reject(deleted), 'task.parent_deleted');
    expect(await reject(child), 'task.unsupported_depth');
    expect(await reject(fixture.task), 'task.parent_is_task');

    final parentWithChild = await repository.apply(
      DemoteTaskCommand(
        accountId: fixture.account,
        taskId: fixture.parent,
        parentTaskId: fixture.task,
      ),
    );
    expect(
      (parentWithChild as Failed<void>).failure.code,
      'task.subtree_would_exceed_depth',
    );
    expect(await DesiredStateDao(database).countForAccount(fixture.account), 0);
  });

  test('hierarchy projection and structure intent survive restart', () async {
    final root = await Directory.systemTemp.createTemp('axiotask-s18a-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/hierarchy.sqlite');
    await database.close();
    var reopened = await AppDatabase.openFile(file);
    final fixture = await _seed(reopened, 'restart');
    await DatabaseTasksRepository(reopened, clock: clock).apply(
      DemoteTaskCommand(
        accountId: fixture.account,
        taskId: fixture.task,
        parentTaskId: fixture.parent,
      ),
    );
    await reopened.close();

    reopened = await AppDatabase.openFile(file);
    addTearDown(reopened.close);
    final snapshot = await DatabaseTasksRepository(
      reopened,
      clock: clock,
    ).watchTasks(TasksQuery(accountId: fixture.account)).first;
    expect(
      snapshot.tasks
          .singleWhere((task) => task.id == fixture.task)
          .parentTaskId,
      fixture.parent,
    );
    expect(
      (await DesiredStateDao(
        reopened,
      ).readTask(fixture.account, fixture.task))?.parentTaskId,
      fixture.parent,
    );
  });
}

Future<({AccountId account, TaskListId list, TaskId task, TaskId parent})>
_seed(AppDatabase database, String suffix) async {
  final account = AccountId(await database.createAccount('synthetic-$suffix'));
  final list = await _putList(database, account, '$suffix-list');
  final cache = CacheDao(database);
  final task = await _putTask(
    cache,
    account,
    list,
    '$suffix-task',
    'Task',
    '1',
  );
  final parent = await _putTask(
    cache,
    account,
    list,
    '$suffix-parent',
    'Parent',
    '2',
  );
  return (account: account, list: list, task: task, parent: parent);
}

Future<TaskListId> _putList(
  AppDatabase database,
  AccountId account,
  String remoteId,
) => CacheDao(database).putTaskList(
  accountId: account,
  remoteId: TaskListRemoteId(remoteId),
  title: 'Synthetic list',
);

Future<TaskId> _putTask(
  CacheDao cache,
  AccountId account,
  TaskListId list,
  String remoteId,
  String title,
  String position,
) async {
  final task = await cache.putTask(
    accountId: account,
    taskListId: list,
    remoteId: TaskRemoteId(remoteId),
    title: title,
    position: position,
  );
  await cache.putTaskRemoteBase(
    accountId: account,
    taskId: task,
    taskListId: list,
    remoteId: TaskRemoteId(remoteId),
    observedPublicationId: 'base-$remoteId',
    deleted: false,
    title: title,
    status: TaskStatus.needsAction,
    position: position,
    etag: 'etag-$remoteId',
  );
  return task;
}
