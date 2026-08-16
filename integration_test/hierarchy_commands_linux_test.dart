import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/sync_health_repository.dart';
import 'package:axiotask/src/data/database/sync_settings_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('task detail hierarchy and ordering survive Linux restart', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp(
      'axiotask-s18a-linux-integration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/isolated.sqlite');
    final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
    var database = await AppDatabase.openFile(file);
    final account = AccountId(
      await database.createAccount('synthetic-linux-hierarchy'),
    );
    await DatabaseSyncSettingsRepository(
      database,
    ).setSyncEnabled(account, false);
    final cache = CacheDao(database);
    final list = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('hierarchy-list'),
      title: 'Hierarchy list',
    );
    final archive = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('hierarchy-archive'),
      title: 'Hierarchy archive',
    );
    final parent = await _putTask(
      cache,
      account,
      list,
      'hierarchy-parent',
      'Hierarchy parent',
      '1',
    );
    final leaf = await _putTask(
      cache,
      account,
      list,
      'hierarchy-leaf',
      'Restarted subtask',
      '2',
    );
    var tasks = DatabaseTasksRepository(database, clock: clock);
    expect(
      await tasks.apply(
        DemoteTaskCommand(
          accountId: account,
          taskId: leaf,
          parentTaskId: parent,
        ),
      ),
      isA<Success<void>>(),
    );
    await database.close();

    database = await AppDatabase.openFile(file);
    tasks = DatabaseTasksRepository(database, clock: clock);
    final viewModel = TasksViewModel(
      accountId: account,
      tasksRepository: tasks,
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
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Restarted subtask'), findsNothing);
    await tester.tap(find.text('Hierarchy parent'));
    await tester.pump();
    expect(find.text('Restarted subtask'), findsOneWidget);
    await tester.tap(find.text('Restarted subtask'));
    await tester.pump();
    expect(find.widgetWithText(OutlinedButton, 'Promote'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Promote'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, 'Move down'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Move down'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Move to list'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(ListTile, 'Hierarchy archive'),
      ),
    );
    await tester.pumpAndSettle();

    final snapshot = await tasks
        .watchTasks(TasksQuery(accountId: account))
        .first;
    final moved = snapshot.tasks.singleWhere((task) => task.id == leaf);
    expect(moved.parentTaskId, isNull);
    expect(moved.taskListId, archive);
    expect(find.text('Restarted subtask'), findsWidgets);
  });
}

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
