import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/app/navigation_state.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'isolated Linux search preserves parent context and back routes',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s25-search-linux-',
      );
      addTearDown(() => root.delete(recursive: true));
      final database = await AppDatabase.openFile(
        File('${root.path}/isolated.sqlite'),
      );
      addTearDown(database.close);
      final cache = CacheDao(database);
      final account = AccountId(
        await database.createAccount('synthetic-search-linux'),
      );
      final otherAccount = AccountId(
        await database.createAccount('synthetic-search-linux-other'),
      );
      final list = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-search-list'),
        title: 'Synthetic search inbox',
      );
      final otherList = await cache.putTaskList(
        accountId: otherAccount,
        remoteId: const TaskListRemoteId('synthetic-other-list'),
        title: 'Other account',
      );
      final parent = await cache.putTask(
        accountId: account,
        taskListId: list,
        remoteId: const TaskRemoteId('synthetic-search-parent'),
        title: 'Linux parent context',
        notes: 'Safe synthetic parent notes',
        position: '1',
      );
      await cache.putTask(
        accountId: account,
        taskListId: list,
        parentTaskId: parent,
        remoteId: const TaskRemoteId('synthetic-search-child'),
        title: 'Unicode child 世界 needle',
        position: '2',
      );
      await cache.putTask(
        accountId: account,
        taskListId: list,
        remoteId: const TaskRemoteId('synthetic-protected'),
        title: 'Protected needle row',
        position: '3',
        projection: CacheProjection.unsupported,
      );
      await cache.putTask(
        accountId: otherAccount,
        taskListId: otherList,
        remoteId: const TaskRemoteId('synthetic-other'),
        title: 'Other needle row',
        position: '1',
      );

      final navigation = AppNavigationController();
      final viewModel = TasksViewModel(
        accountId: account,
        tasksRepository: DatabaseTasksRepository(database),
        syncHealthRepository: const _HealthRepository(),
        clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
      );
      addTearDown(navigation.dispose);
      addTearDown(viewModel.dispose);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(viewModel: viewModel, navigation: navigation),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search tasks'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('search-input')),
        '世界 needle',
      );
      await tester.pumpAndSettle();
      expect(find.text('Linux parent context'), findsOneWidget);
      expect(
        find.textContaining('Matched subtask: Unicode child 世界 needle'),
        findsOneWidget,
      );
      expect(find.text('Protected needle row'), findsNothing);
      expect(find.text('Other needle row'), findsNothing);

      await tester.tap(find.byKey(const Key('search-result-0')));
      await tester.pumpAndSettle();
      expect(viewModel.state.selectedTaskId, parent);
      expect(find.text('Safe synthetic parent notes'), findsOneWidget);
      expect(navigation.state.predictiveBackRoute, TaskDetailRoute(parent));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(viewModel.state.selectedTaskId, isNull);
      expect(navigation.state.canHandlePredictiveBack, isFalse);
    },
  );
}

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 16, 12),
    ),
  );
}
