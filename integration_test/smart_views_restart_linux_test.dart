import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/data/preferences/preferences_repository.dart';
import 'package:axiotask/src/data/preferences/relational_preferences.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('smart-view relational projection survives Linux restart', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'axiotask-synthetic-smart-view-restart-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/smart-views.sqlite');
    var database = await AppDatabase.openFile(file);
    final account = AccountId(
      await database.createAccount('synthetic-smart-view-restart'),
    );
    final cache = CacheDao(database);
    final first = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('synthetic-restart-first'),
      title: 'First',
    );
    final second = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('synthetic-restart-second'),
      title: 'Second',
    );
    final parent = await cache.putTask(
      accountId: account,
      taskListId: first,
      remoteId: const TaskRemoteId('synthetic-restart-parent'),
      title: 'Parent from child date',
      position: '00001',
    );
    await cache.putTask(
      accountId: account,
      taskListId: first,
      parentTaskId: parent,
      remoteId: const TaskRemoteId('synthetic-restart-child'),
      title: 'Child tomorrow',
      due: TaskDate(2026, 8, 16),
      position: '00001',
    );
    await cache.putTask(
      accountId: account,
      taskListId: second,
      remoteId: const TaskRemoteId('synthetic-restart-excluded'),
      title: 'Excluded today',
      due: TaskDate(2026, 8, 15),
      position: '00001',
    );

    var preferences = DriftRelationalPreferences(database);
    expect(
      await preferences.setViewPreferences(
        account,
        SmartView.focus.key,
        const ViewPreferences(sort: ViewSort.title, showCompleted: true),
      ),
      isA<Success<void>>(),
    );
    expect(
      await preferences.setListPreferences(
        account,
        second,
        const ListPreferences(sidebarOrder: 0, excludedFromSmartViews: true),
      ),
      isA<Success<void>>(),
    );
    expect(
      await preferences.setSidebarOrder(account, <TaskListId>[second, first]),
      isA<Success<void>>(),
    );
    await database.close();

    database = await AppDatabase.openFile(file);
    addTearDown(database.close);
    preferences = DriftRelationalPreferences(database);
    final device = DevicePreferencesAdapter(
      backend: InMemoryDevicePreferencesBackend(),
      namespace: 'synthetic-smart-view-restart',
      diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
    );
    addTearDown(device.close);
    final viewModel = TasksViewModel(
      accountId: account,
      tasksRepository: DatabaseTasksRepository(database),
      preferencesRepository: StoredPreferencesRepository(
        relational: preferences,
        device: device,
      ),
      syncHealthRepository: const _HealthRepository(),
      clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();

    expect(find.text('Parent from child date'), findsOneWidget);
    expect(find.text('Child tomorrow'), findsNothing);
    expect(find.text('Excluded today'), findsNothing);
    expect(find.text('1 cached task'), findsOneWidget);
    expect(viewModel.state.orderedTaskLists.map((list) => list.title), <String>[
      'Second',
      'First',
    ]);
    expect(viewModel.state.selectedViewPreferences.sort, ViewSort.title);
    expect(viewModel.state.selectedViewPreferences.showCompleted, isTrue);
  });
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
      evaluatedAt: DateTime.utc(2026, 8, 15, 12),
    ),
  );
}
