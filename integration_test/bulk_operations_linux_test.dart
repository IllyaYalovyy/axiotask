import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/model/bulk_operations.dart';
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
    'atomic bulk completion and exact pending result survive Linux restart',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s28a-linux-integration-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      final clock = ManualClock(DateTime.utc(2026, 8, 16, 14));
      var database = await AppDatabase.openFile(file);
      final account = AccountId(
        await database.createAccount('synthetic-s28a-linux'),
      );
      final cache = CacheDao(database);
      final list = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-bulk-list'),
        title: 'Synthetic bulk list',
      );
      await _putTask(cache, account, list, 11, 'Bulk Linux first');
      await _putTask(cache, account, list, 13, 'Bulk Linux second');

      var repository = DatabaseTasksRepository(database, clock: clock);
      var viewModel = _viewModel(repository, account, clock);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('bulk-select-open')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('bulk-select-task-2')));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bulk-complete-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bulk-complete-confirm')));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Bulk complete: 0 confirmed • 2 pending • 0 failed '
          '(2 Google updates from 2 selected)',
        ),
        findsOneWidget,
      );
      final firstSummary = await repository
          .watchLatestBulkOperation(account)
          .first;
      expect(firstSummary?.pendingCount, 2);

      viewModel.dispose();
      await database.close();
      database = await AppDatabase.openFile(file);
      repository = DatabaseTasksRepository(database, clock: clock);
      viewModel = _viewModel(repository, account, clock);
      addTearDown(() async {
        viewModel.dispose();
        await database.close();
      });
      await tester.pumpWidget(
        MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
      );
      await tester.pumpAndSettle();

      final restartedSummary = await repository
          .watchLatestBulkOperation(account)
          .first;
      expect(restartedSummary?.kind, BulkOperationKind.complete);
      expect(restartedSummary?.selectedCount, 2);
      expect(restartedSummary?.affectedCount, 2);
      expect(restartedSummary?.confirmedCount, 0);
      expect(restartedSummary?.pendingCount, 2);
      expect(restartedSummary?.failedCount, 0);
      expect(
        find.textContaining('0 confirmed • 2 pending • 0 failed'),
        findsOneWidget,
      );
    },
  );
}

TasksViewModel _viewModel(
  DatabaseTasksRepository repository,
  AccountId account,
  ManualClock clock,
) => TasksViewModel(
  accountId: account,
  tasksRepository: repository,
  syncHealthRepository: const _PendingHealthRepository(),
  clock: clock,
);

Future<void> _putTask(
  CacheDao cache,
  AccountId account,
  TaskListId list,
  int suffix,
  String title,
) async {
  final remoteId = TaskRemoteId('synthetic-bulk-task-$suffix');
  final task = await cache.putTask(
    accountId: account,
    taskListId: list,
    remoteId: remoteId,
    title: title,
    position: suffix.toString(),
  );
  await cache.putTaskRemoteBase(
    accountId: account,
    taskId: task,
    taskListId: list,
    remoteId: remoteId,
    title: title,
    notes: null,
    status: TaskStatus.needsAction,
    due: null,
    position: suffix.toString(),
    etag: 'synthetic-etag-$suffix',
    remoteUpdatedAt: DateTime.utc(2026, 8, 16, 13),
    observedPublicationId: 'synthetic-seed',
    deleted: false,
  );
}

final class _PendingHealthRepository implements SyncHealthRepository {
  const _PendingHealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 2),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 16, 14),
    ),
  );
}
