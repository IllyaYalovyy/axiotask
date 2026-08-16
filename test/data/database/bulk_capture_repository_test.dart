import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/bulk_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late ManualClock clock;
  late AccountId account;
  late TaskListId list;

  setUp(() async {
    database = AppDatabase.inMemory();
    clock = ManualClock(DateTime.utc(2026, 8, 16, 12));
    account = AccountId(await database.createAccount('synthetic-bulk-store'));
    list =
        ((await DatabaseTaskListsRepository(
                  database: database,
                  clock: clock,
                ).createTaskList(
                  CreateTaskListCommand(
                    accountId: account,
                    title: 'Bulk target',
                  ),
                ))
                as Success<TaskListId>)
            .value;
  });

  tearDown(() => database.close());

  test(
    'one transaction acknowledges every projection and desired create',
    () async {
      final repository = DatabaseTasksRepository(database, clock: clock);
      final result = await repository.createTasks(
        BulkCreateTasksCommand(
          accountId: account,
          taskListId: list,
          entries: const <BulkCaptureEntry>[
            BulkCaptureEntry(title: 'Alpha'),
            BulkCaptureEntry(title: 'Beta', notes: 'Synthetic details'),
            BulkCaptureEntry(title: 'Gamma'),
          ],
        ),
      );

      expect((result as Success<List<TaskId>>).value, hasLength(3));
      final snapshot = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(snapshot.tasks.map((task) => task.title), [
        'Alpha',
        'Beta',
        'Gamma',
      ]);
      expect(await DesiredStateDao(database).countForAccount(account), 4);
      final dependencies = await database
          .customSelect(
            "SELECT COUNT(*) AS count FROM desired_state_dependencies WHERE dependency_kind = 'task_list'",
          )
          .getSingle();
      expect(dependencies.read<int>('count'), 3);
    },
  );

  test(
    'failure after a later desired write rolls back the entire batch',
    () async {
      var desiredWrites = 0;
      final repository = DatabaseTasksRepository(
        database,
        clock: clock,
        transactionControl: (boundary) {
          if (boundary ==
                  DesiredStateTransactionBoundary.afterDesiredStateWrite &&
              ++desiredWrites == 2) {
            throw const DesiredStatePersistenceException(
              'synthetic_bulk_failure',
            );
          }
        },
      );

      final result = await repository.createTasks(
        BulkCreateTasksCommand(
          accountId: account,
          taskListId: list,
          entries: const <BulkCaptureEntry>[
            BulkCaptureEntry(title: 'Must not survive'),
            BulkCaptureEntry(title: 'Also rolled back'),
            BulkCaptureEntry(title: 'Never partially accepted'),
          ],
        ),
      );

      expect(result, isA<Failed<List<TaskId>>>());
      expect(
        (await repository.watchTasks(TasksQuery(accountId: account)).first)
            .tasks,
        isEmpty,
      );
      expect(await DesiredStateDao(database).countForAccount(account), 1);
    },
  );

  test('invalid target and invalid entry accept nothing', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);
    for (final command in <BulkCreateTasksCommand>[
      BulkCreateTasksCommand(
        accountId: account,
        taskListId: const TaskListId(999),
        entries: const <BulkCaptureEntry>[BulkCaptureEntry(title: 'Valid')],
      ),
      BulkCreateTasksCommand(
        accountId: account,
        taskListId: list,
        entries: const <BulkCaptureEntry>[
          BulkCaptureEntry(title: 'Valid'),
          BulkCaptureEntry(title: ''),
        ],
      ),
    ]) {
      expect(
        await repository.createTasks(command),
        isA<Failed<List<TaskId>>>(),
      );
    }
    expect(
      (await repository.watchTasks(TasksQuery(accountId: account)).first).tasks,
      isEmpty,
    );
  });

  test(
    'atomic acknowledgement and dependencies survive file restart',
    () async {
      await database.close();
      final root = await Directory.systemTemp.createTemp(
        'axiotask-bulk-store-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      database = await AppDatabase.openFile(file);
      account = AccountId(
        await database.createAccount('synthetic-bulk-restart'),
      );
      list =
          ((await DatabaseTaskListsRepository(
                    database: database,
                    clock: clock,
                  ).createTaskList(
                    CreateTaskListCommand(
                      accountId: account,
                      title: 'Pending list',
                    ),
                  ))
                  as Success<TaskListId>)
              .value;
      await DatabaseTasksRepository(database, clock: clock).createTasks(
        BulkCreateTasksCommand(
          accountId: account,
          taskListId: list,
          entries: const <BulkCaptureEntry>[
            BulkCaptureEntry(title: 'Restart one'),
            BulkCaptureEntry(title: 'Restart two'),
          ],
        ),
      );
      await database.close();

      database = await AppDatabase.openFile(file);
      final snapshot = await DatabaseTasksRepository(
        database,
        clock: clock,
      ).watchTasks(TasksQuery(accountId: account)).first;
      expect(snapshot.tasks.map((task) => task.title), [
        'Restart one',
        'Restart two',
      ]);
      expect(await DesiredStateDao(database).countForAccount(account), 3);
    },
  );
}
