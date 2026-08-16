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

  testWidgets('detail notes and subtask commands survive Linux restart', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp(
      'axiotask-s23a-linux-integration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/isolated.sqlite');
    final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
    var database = await AppDatabase.openFile(file);
    final account = AccountId(
      await database.createAccount('synthetic-linux-task-details'),
    );
    await DatabaseSyncSettingsRepository(
      database,
    ).setSyncEnabled(account, false);
    final cache = CacheDao(database);
    final list = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('synthetic-detail-list'),
      title: 'Synthetic details',
    );
    final parent = await _putTask(
      cache,
      account,
      list,
      remoteId: 'synthetic-detail-parent',
      title: 'Linux detail parent',
      position: '1',
      notes: 'Original synthetic notes',
    );
    final firstChild = await _putTask(
      cache,
      account,
      list,
      remoteId: 'synthetic-detail-child-a',
      title: 'Linux child A',
      position: '2',
    );
    final secondChild = await _putTask(
      cache,
      account,
      list,
      remoteId: 'synthetic-detail-child-b',
      title: 'Linux child B',
      position: '3',
      status: TaskStatus.completed,
    );
    var repository = DatabaseTasksRepository(database, clock: clock);
    for (final child in <TaskId>[firstChild, secondChild]) {
      expect(
        await repository.apply(
          DemoteTaskCommand(
            accountId: account,
            taskId: child,
            parentTaskId: parent,
          ),
        ),
        isA<Success<void>>(),
      );
    }

    var viewModel = _viewModel(database, repository, account, clock);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Linux child A'), findsNothing);
    expect(find.text('1 of 2 subtasks complete'), findsOneWidget);
    await tester.tap(find.text('Linux detail parent'));
    await tester.pump();
    expect(find.text('Linux child A'), findsOneWidget);
    expect(find.text('Linux child B'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit task content'));
    await tester.pumpAndSettle();
    final notes = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Notes',
    );
    await tester.enterText(notes, '離線ノート 🌍\nsecond exact line');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add subtask'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Created Linux child');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.text('Created Linux child'), findsOneWidget);
    expect(find.text('1 of 3 subtasks complete'), findsNWidgets(2));

    viewModel.dispose();
    await database.close();
    database = await AppDatabase.openFile(file);
    repository = DatabaseTasksRepository(database, clock: clock);
    viewModel = _viewModel(database, repository, account, clock);
    addTearDown(() async {
      viewModel.dispose();
      await database.close();
    });
    await tester.pumpWidget(
      MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Linux detail parent'));
    await tester.pump();

    expect(find.text('離線ノート 🌍\nsecond exact line'), findsOneWidget);
    expect(find.text('Created Linux child'), findsOneWidget);
    expect(find.text('1 of 3 subtasks complete'), findsNWidgets(2));
  });
}

TasksViewModel _viewModel(
  AppDatabase database,
  DatabaseTasksRepository repository,
  AccountId account,
  ManualClock clock,
) => TasksViewModel(
  accountId: account,
  tasksRepository: repository,
  syncHealthRepository: DatabaseSyncHealthRepository(
    dao: SyncHealthDao(database),
    clock: clock,
    runtime: const StaticSyncRuntimeFactsSource(
      SyncRuntimeFacts(authorization: SyncAuthorization.usable),
    ),
  ),
  clock: clock,
);

Future<TaskId> _putTask(
  CacheDao cache,
  AccountId account,
  TaskListId list, {
  required String remoteId,
  required String title,
  required String position,
  String? notes,
  TaskStatus status = TaskStatus.needsAction,
}) async {
  final task = await cache.putTask(
    accountId: account,
    taskListId: list,
    remoteId: TaskRemoteId(remoteId),
    title: title,
    notes: notes,
    status: status,
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
    notes: notes,
    status: status,
    position: position,
    etag: 'etag-$remoteId',
  );
  return task;
}
