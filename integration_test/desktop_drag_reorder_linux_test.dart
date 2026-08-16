import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'PAR-DESKTOP-003 Linux pointer reorder, cancel, and list move persist',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s26b-desktop-drag-',
      );
      addTearDown(() => root.delete(recursive: true));
      final database = await AppDatabase.openFile(
        File('${root.path}/isolated.sqlite'),
      );
      addTearDown(database.close);
      final cache = CacheDao(database);
      final account = AccountId(
        await database.createAccount('synthetic-desktop-drag'),
      );
      final inbox = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-drag-inbox'),
        title: 'Synthetic drag inbox',
      );
      final archive = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-drag-archive'),
        title: 'Synthetic drag archive',
      );
      final first = await _putTask(cache, account, inbox, 1);
      final second = await _putTask(cache, account, inbox, 2);
      final third = await _putTask(cache, account, inbox, 3);
      final repository = DatabaseTasksRepository(
        database,
        clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
      );
      final viewModel = TasksViewModel(
        accountId: account,
        tasksRepository: repository,
        syncHealthRepository: const _HealthRepository(),
      );
      addTearDown(viewModel.dispose);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
      );
      await tester.pumpAndSettle();

      await _drag(
        tester,
        from: find.byKey(Key('desktop-task-row-${third.value}')),
        to:
            tester.getTopLeft(
              find.byKey(Key('desktop-task-row-${first.value}')),
            ) +
            const Offset(80, 8),
      );
      var snapshot = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(
        snapshot.tasks
            .where((task) => task.taskListId == inbox)
            .map((task) => task.id),
        <TaskId>[third, first, second],
      );

      await _drag(
        tester,
        from: find.byKey(Key('desktop-task-row-${second.value}')),
        to: tester.getCenter(find.text('Focus').first),
      );
      snapshot = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(
        snapshot.tasks
            .where((task) => task.taskListId == inbox)
            .map((task) => task.id),
        <TaskId>[third, first, second],
      );

      final archiveTarget = find.descendant(
        of: find.byKey(const Key('desktop-navigation-pane')),
        matching: find.text('Synthetic drag archive'),
      );
      await _drag(
        tester,
        from: find.byKey(Key('desktop-task-row-${first.value}')),
        to: tester.getCenter(archiveTarget),
      );
      snapshot = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      final moved = snapshot.tasks.singleWhere((task) => task.id == first);
      expect(moved.taskListId, archive);
      expect(moved.parentTaskId, isNull);
      expect(find.text('Synthetic task 1'), findsNothing);
    },
  );
}

Future<void> _drag(
  WidgetTester tester, {
  required Finder from,
  required Offset to,
}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(from),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<TaskId> _putTask(
  CacheDao cache,
  AccountId account,
  TaskListId list,
  int order,
) async {
  final remoteId = TaskRemoteId('synthetic-drag-task-$order');
  final task = await cache.putTask(
    accountId: account,
    taskListId: list,
    remoteId: remoteId,
    title: 'Synthetic task $order',
    position: '$order',
  );
  await cache.putTaskRemoteBase(
    accountId: account,
    taskId: task,
    taskListId: list,
    remoteId: remoteId,
    observedPublicationId: 'synthetic-base-$order',
    deleted: false,
    title: 'Synthetic task $order',
    status: TaskStatus.needsAction,
    position: '$order',
    etag: 'synthetic-etag-$order',
  );
  return task;
}

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 16, 12),
    ),
  );
}
