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
    clock = ManualClock(DateTime.utc(2026, 8, 15, 18));
  });
  tearDown(() => database.close());

  test(
    'REC-011 cross-list MOVE intent preserves root and child identity',
    () async {
      final fixture = await _seed(database);
      final repository = DatabaseTasksRepository(database, clock: clock);

      expect(
        await repository.apply(
          MoveTaskCommand(
            accountId: fixture.account,
            taskId: fixture.parent,
            destinationTaskListId: fixture.secondList,
          ),
        ),
        isA<Success<void>>(),
      );

      final snapshot = await repository
          .watchTasks(TasksQuery(accountId: fixture.account))
          .first;
      final parent = snapshot.tasks.singleWhere(
        (task) => task.id == fixture.parent,
      );
      final child = snapshot.tasks.singleWhere(
        (task) => task.id == fixture.child,
      );
      expect(parent.taskListId, fixture.secondList);
      expect(parent.parentTaskId, isNull);
      expect(child.taskListId, fixture.secondList);
      expect(child.parentTaskId, fixture.parent);
      expect(parent.remoteId, const TaskRemoteId('parent'));
      expect(child.remoteId, const TaskRemoteId('child'));

      final desired = await DesiredStateDao(
        database,
      ).readTask(fixture.account, fixture.parent);
      expect(desired?.taskListId, fixture.secondList);
      expect(desired?.structureDirty, isTrue);
      expect(desired?.contentDirty, isFalse);
    },
  );

  test(
    'REC-013 projected order uses previous anchor without fake position',
    () async {
      final fixture = await _seed(database);
      final repository = DatabaseTasksRepository(database, clock: clock);

      expect(
        await repository.apply(
          MoveTaskCommand(
            accountId: fixture.account,
            taskId: fixture.last,
            destinationTaskListId: fixture.firstList,
            previousTaskId: fixture.parent,
          ),
        ),
        isA<Success<void>>(),
      );
      final snapshot = await repository
          .watchTasks(TasksQuery(accountId: fixture.account))
          .first;
      expect(
        snapshot.tasks
            .where(
              (task) =>
                  task.parentTaskId == null &&
                  task.taskListId == fixture.firstList,
            )
            .map((task) => task.id),
        <TaskId>[fixture.parent, fixture.last, fixture.middle],
      );
      final cached = await (database.select(
        database.taskCacheRows,
      )..where((row) => row.id.equals(fixture.last.value))).getSingle();
      expect(cached.position, '3000');
    },
  );

  test('REC-012 direct reparent keeps one supported level', () async {
    final fixture = await _seed(database);
    final repository = DatabaseTasksRepository(database, clock: clock);

    expect(
      await repository.apply(
        MoveTaskCommand(
          accountId: fixture.account,
          taskId: fixture.child,
          destinationTaskListId: fixture.firstList,
          parentTaskId: fixture.middle,
        ),
      ),
      isA<Success<void>>(),
    );
    final snapshot = await repository
        .watchTasks(TasksQuery(accountId: fixture.account))
        .first;
    expect(
      snapshot.tasks
          .singleWhere((task) => task.id == fixture.child)
          .parentTaskId,
      fixture.middle,
    );
  });

  test('REC-022 invalid anchors and boundaries commit nothing', () async {
    final fixture = await _seed(database);
    final repository = DatabaseTasksRepository(database, clock: clock);

    Future<String> reject(MoveTaskCommand command) async =>
        ((await repository.apply(command)) as Failed<void>).failure.code;

    expect(
      await reject(
        MoveTaskCommand(
          accountId: fixture.account,
          taskId: fixture.middle,
          destinationTaskListId: fixture.firstList,
          previousTaskId: fixture.child,
        ),
      ),
      'task.previous_wrong_scope',
    );
    expect(
      await reject(
        MoveTaskCommand(
          accountId: fixture.account,
          taskId: fixture.middle,
          destinationTaskListId: fixture.firstList,
          previousTaskId: const TaskId(999999),
        ),
      ),
      'task.previous_not_found',
    );
    expect(
      await reject(
        MoveTaskCommand(
          accountId: fixture.account,
          taskId: fixture.middle,
          destinationTaskListId: fixture.secondList,
          parentTaskId: fixture.child,
        ),
      ),
      'task.parent_cross_list',
    );
    final otherAccount = AccountId(
      await database.createAccount('synthetic-structure-other'),
    );
    expect(
      await reject(
        MoveTaskCommand(
          accountId: otherAccount,
          taskId: fixture.middle,
          destinationTaskListId: fixture.firstList,
        ),
      ),
      'task.cross_account',
    );
    expect(await DesiredStateDao(database).countForAccount(fixture.account), 0);
  });
}

Future<
  ({
    AccountId account,
    TaskListId firstList,
    TaskListId secondList,
    TaskId parent,
    TaskId child,
    TaskId middle,
    TaskId last,
  })
>
_seed(AppDatabase database) async {
  final account = AccountId(
    await database.createAccount('synthetic-structure'),
  );
  final cache = CacheDao(database);
  final firstList = await cache.putTaskList(
    accountId: account,
    remoteId: const TaskListRemoteId('list-a'),
    title: 'List A',
  );
  final secondList = await cache.putTaskList(
    accountId: account,
    remoteId: const TaskListRemoteId('list-b'),
    title: 'List B',
  );
  final parent = await _putTask(cache, account, firstList, 'parent', '1000');
  final child = await _putTask(
    cache,
    account,
    firstList,
    'child',
    '1000',
    parentTaskId: parent,
  );
  final middle = await _putTask(cache, account, firstList, 'middle', '2000');
  final last = await _putTask(cache, account, firstList, 'last', '3000');
  return (
    account: account,
    firstList: firstList,
    secondList: secondList,
    parent: parent,
    child: child,
    middle: middle,
    last: last,
  );
}

Future<TaskId> _putTask(
  CacheDao cache,
  AccountId account,
  TaskListId list,
  String remoteId,
  String position, {
  TaskId? parentTaskId,
}) async {
  final id = await cache.putTask(
    accountId: account,
    taskListId: list,
    parentTaskId: parentTaskId,
    remoteId: TaskRemoteId(remoteId),
    title: remoteId,
    position: position,
  );
  await cache.putTaskRemoteBase(
    accountId: account,
    taskId: id,
    taskListId: list,
    parentTaskId: parentTaskId,
    remoteId: TaskRemoteId(remoteId),
    observedPublicationId: 'seed',
    deleted: false,
    title: remoteId,
    status: TaskStatus.needsAction,
    position: position,
    etag: 'etag-$remoteId',
  );
  return id;
}
