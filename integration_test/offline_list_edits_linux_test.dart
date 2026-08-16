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

  testWidgets('stopped offline list create and rename survive Linux restart', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp(
      'axiotask-s14a-linux-integration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/isolated.sqlite');
    final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));

    var database = await AppDatabase.openFile(file);
    final account = AccountId(
      await database.createAccount('synthetic-linux-offline'),
    );
    await DatabaseSyncSettingsRepository(
      database,
    ).setSyncEnabled(account, false);
    var lists = DatabaseTaskListsRepository(database: database, clock: clock);
    final created = await lists.createTaskList(
      CreateTaskListCommand(accountId: account, title: 'Created offline'),
    );
    final listId = (created as Success<TaskListId>).value;
    await lists.renameTaskList(
      RenameTaskListCommand(
        accountId: account,
        taskListId: listId,
        title: 'Renamed before restart',
      ),
    );
    await database.close();

    database = await AppDatabase.openFile(file);
    lists = DatabaseTaskListsRepository(database: database, clock: clock);
    final viewModel = TasksViewModel(
      accountId: account,
      tasksRepository: DatabaseTasksRepository(database),
      taskListsRepository: lists,
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

    expect(find.text('Renamed before restart'), findsWidgets);
    expect(find.text('Sync stopped'), findsWidgets);
    expect(find.text('1 unresolved'), findsOneWidget);
    expect(
      (await DesiredStateDao(
        database,
      ).readTaskList(account, listId))?.generation,
      2,
    );

    await tester.tap(find.byTooltip('Rename selected task list'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Renamed while stopped',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(find.text('Renamed while stopped'), findsWidgets);
    expect(
      (await DesiredStateDao(
        database,
      ).readTaskList(account, listId))?.generation,
      3,
    );
    expect(
      (await SyncHealthDao(database).watchFacts(account).first).counts.pending,
      1,
    );
  });
}
