import 'dart:convert';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/account_backup_repository.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/preferences/relational_preferences.dart';
import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late ManualClock clock;
  late DatabaseAccountBackupRepository backups;

  setUp(() {
    database = AppDatabase.inMemory();
    clock = ManualClock(DateTime.utc(2026, 8, 16, 12));
    backups = DatabaseAccountBackupRepository(database);
  });

  tearDown(() => database.close());

  test(
    'PAR-DATA-001 selects one account and includes acknowledged offline edits',
    () async {
      final accountA = AccountId(await database.createAccount('subject-a'));
      final accountB = AccountId(await database.createAccount('subject-b'));
      final lists = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final tasks = DatabaseTasksRepository(database, clock: clock);

      final listA =
          (await lists.createTaskList(
                    CreateTaskListCommand(
                      accountId: accountA,
                      title: 'Offline list A',
                    ),
                  )
                  as Success<TaskListId>)
              .value;
      final parent =
          (await tasks.createTask(
                    CreateTaskCommand(
                      accountId: accountA,
                      taskListId: listA,
                      title: 'Offline parent edited',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      final child =
          (await tasks.createTask(
                    CreateTaskCommand(
                      accountId: accountA,
                      taskListId: listA,
                      parentTaskId: parent,
                      title: 'Offline child',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      expect(
        await tasks.apply(
          SetTaskNotesCommand(
            accountId: accountA,
            taskId: parent,
            notes: 'Acknowledged while disconnected',
          ),
        ),
        isA<Success<void>>(),
      );
      expect(
        await tasks.apply(
          MoveTaskCommand(
            accountId: accountA,
            taskId: child,
            destinationTaskListId: listA,
            parentTaskId: parent,
            previousTaskId: null,
          ),
        ),
        isA<Success<void>>(),
      );
      await lists.createTaskList(
        CreateTaskListCommand(accountId: accountB, title: 'Other account'),
      );

      final snapshot = await backups.readProjectedAccount(accountA);

      expect(snapshot.sourceGoogleSubject, 'subject-a');
      expect(snapshot.lists.map((list) => list.title), <String>[
        'Offline list A',
      ]);
      expect(snapshot.tasks.map((task) => task.title), <String>[
        'Offline parent edited',
        'Offline child',
      ]);
      expect(snapshot.tasks.first.notes, 'Acknowledged while disconnected');
      expect(snapshot.tasks.last.parentKey, snapshot.tasks.first.key);
    },
  );

  test('list and sibling ordering is exported without raw local IDs', () async {
    final account = AccountId(await database.createAccount('order-subject'));
    final cache = CacheDao(database);
    final first = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('remote-first'),
      title: 'First created',
    );
    final second = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('remote-second'),
      title: 'Second created',
    );
    await cache.putTask(
      accountId: account,
      taskListId: second,
      remoteId: const TaskRemoteId('remote-later'),
      title: 'Later sibling',
      position: '2000',
    );
    await cache.putTask(
      accountId: account,
      taskListId: second,
      remoteId: const TaskRemoteId('remote-earlier'),
      title: 'Earlier sibling',
      position: '1000',
    );
    await DriftRelationalPreferences(
      database,
    ).setSidebarOrder(account, <TaskListId>[second, first]);

    final snapshot = await backups.readProjectedAccount(account);
    final encoded = const AccountBackupCodec().encode(
      snapshot,
      exportedAt: DateTime.utc(2026, 8, 16, 12),
    );
    final document = jsonDecode(encoded) as Map<String, Object?>;

    expect(snapshot.lists.map((list) => list.title), <String>[
      'Second created',
      'First created',
    ]);
    expect(snapshot.tasks.map((task) => task.title), <String>[
      'Earlier sibling',
      'Later sibling',
    ]);
    expect(encoded, isNot(contains('"accountId"')));
    expect(encoded, isNot(contains('"taskListId"')));
    expect(document.keys, <String>[
      'format',
      'version',
      'privateDataWarning',
      'exportedAt',
      'sourceAccount',
      'lists',
      'tasks',
    ]);
  });
}
