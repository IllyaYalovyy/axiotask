import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/sync_health_repository.dart';
import 'package:axiotask/src/data/database/sync_settings_repository.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('stopped offline task content survives immediate Linux restart', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp(
      'axiotask-s14b-linux-integration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/isolated.sqlite');
    final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));

    var database = await AppDatabase.openFile(file);
    final account = AccountId(
      await database.createAccount('synthetic-linux-task-offline'),
    );
    await DatabaseSyncSettingsRepository(
      database,
    ).setSyncEnabled(account, false);
    final list =
        (await DatabaseTaskListsRepository(
                  database: database,
                  clock: clock,
                ).createTaskList(
                  CreateTaskListCommand(
                    accountId: account,
                    title: 'Offline tasks',
                  ),
                )
                as Success<TaskListId>)
            .value;
    var tasks = DatabaseTasksRepository(database, clock: clock);
    final task =
        (await tasks.createTask(
                  CreateTaskCommand(
                    accountId: account,
                    taskListId: list,
                    title: 'Draft',
                  ),
                )
                as Success<TaskId>)
            .value;
    await tasks.apply(
      UpdateTaskContentCommand(
        accountId: account,
        taskId: task,
        title: 'Durable 🌍',
        notes: '離線ノート\nsecond line',
        status: TaskStatus.completed,
        due: TaskDate(2026, 8, 20),
      ),
    );
    await database.close();

    database = await AppDatabase.openFile(file);
    tasks = DatabaseTasksRepository(database, clock: clock);
    final viewModel = TasksViewModel(
      accountId: account,
      tasksRepository: tasks,
      taskListsRepository: DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      ),
      syncHealthRepository: DatabaseSyncHealthRepository(
        dao: SyncHealthDao(database),
        clock: clock,
        runtime: const StaticSyncRuntimeFactsSource(
          SyncRuntimeFacts(authorization: SyncAuthorization.usable),
        ),
      ),
    );
    addTearDown(() async {
      viewModel.dispose();
      await database.close();
    });
    await tester.pumpWidget(
      MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sync stopped'), findsWidgets);
    expect(find.text('2 unresolved'), findsOneWidget);
    viewModel.selectTask(task);
    await tester.pump();
    expect(find.text('Durable 🌍'), findsOneWidget);
    expect(find.text('離線ノート\nsecond line'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('2026-08-20'), findsOneWidget);
    expect(
      (await DesiredStateDao(database).readTask(account, task))?.generation,
      2,
    );
    expect(
      (await SyncHealthDao(database).watchFacts(account).first).counts.pending,
      2,
    );
  });
}
