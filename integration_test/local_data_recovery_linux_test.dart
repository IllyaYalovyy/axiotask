import 'dart:io';

import 'package:axiotask/src/app/axiotask_app.dart';
import 'package:axiotask/src/data/database/account_partition_reset_store.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/recovery/local_data_recovery.dart';
import 'package:axiotask/src/features/recovery/local_data_recovery_view.dart';
import 'package:axiotask/src/features/recovery/local_data_recovery_view_model.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'PAR-DATA-003 selected partition resets and rebuilds from Google',
    (tester) async {
      final fixture = await _Fixture.open(rebuildAvailable: true);
      addTearDown(fixture.close);
      await _render(tester, fixture);

      await tester.tap(find.byTooltip('Local data recovery'));
      await tester.pumpAndSettle();
      expect(find.text('Local data recovery'), findsOneWidget);
      expect(
        find.textContaining('1 cached lists, 1 cached tasks'),
        findsOneWidget,
      );

      await tester.tap(find.text('Reset Local Data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset and rebuild'));
      await tester.pumpAndSettle();

      expect(find.text('Rebuilt from Google'), findsOneWidget);
      final selected = await DatabaseTasksRepository(
        fixture.database,
      ).watchTasks(TasksQuery(accountId: fixture.selected)).first;
      expect(selected.taskLists.single.title, 'Rebuilt Google list');
      expect(selected.tasks.single.title, 'Rebuilt Google task');
      final other = await DatabaseTasksRepository(
        fixture.database,
      ).watchTasks(TasksQuery(accountId: fixture.other)).first;
      expect(other.tasks.single.title, 'Other account task');
    },
  );

  testWidgets('unavailable Google leaves reset cache failed and empty', (
    tester,
  ) async {
    final fixture = await _Fixture.open(rebuildAvailable: false);
    addTearDown(fixture.close);
    await _render(tester, fixture);

    await tester.tap(find.byTooltip('Local data recovery'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset Local Data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset and rebuild'));
    await tester.pumpAndSettle();

    expect(find.text('Local data reset; rebuild unavailable'), findsOneWidget);
    final selected = await DatabaseTasksRepository(
      fixture.database,
    ).watchTasks(TasksQuery(accountId: fixture.selected)).first;
    expect(selected.taskLists, isEmpty);
    expect(selected.tasks, isEmpty);
    expect(fixture.health.outcome, SyncHealthOutcome.failed);
  });
}

Future<void> _render(WidgetTester tester, _Fixture fixture) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final tasks = TasksViewModel(
    accountId: fixture.selected,
    tasksRepository: DatabaseTasksRepository(fixture.database),
    syncHealthRepository: fixture.health,
  );
  addTearDown(tasks.dispose);
  await tester.pumpWidget(
    AxiotaskApp(
      viewModel: tasks,
      localDataRecoveryBuilder: (_) => LocalDataRecoveryHost(
        viewModel: LocalDataRecoveryViewModel(
          accountId: fixture.selected,
          recovery: fixture.recovery,
          healthRepository: fixture.health,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _Fixture {
  _Fixture({
    required this.root,
    required this.database,
    required this.selected,
    required this.other,
    required this.health,
    required this.recovery,
  });

  final Directory root;
  final AppDatabase database;
  final AccountId selected;
  final AccountId other;
  final _Health health;
  final LocalDataRecoveryService recovery;

  static Future<_Fixture> open({required bool rebuildAvailable}) async {
    final root = await Directory.systemTemp.createTemp(
      'axiotask-local-reset-linux-',
    );
    final database = await AppDatabase.openFile(
      File('${root.path}/isolated-reset.sqlite'),
    );
    final selected = AccountId(
      await database.createAccount('synthetic-reset-subject'),
    );
    final other = AccountId(
      await database.createAccount('synthetic-other-subject'),
    );
    await _seed(
      database,
      selected,
      'Selected local list',
      'Pending local task',
    );
    await _seed(database, other, 'Other account list', 'Other account task');
    final health = _Health(
      rebuildAvailable ? SyncHealthOutcome.good : SyncHealthOutcome.failed,
    );
    final synchronization = _Rebuild(
      database: database,
      accountId: selected,
      available: rebuildAvailable,
    );
    return _Fixture(
      root: root,
      database: database,
      selected: selected,
      other: other,
      health: health,
      recovery: LocalDataRecoveryService(
        store: DatabaseAccountPartitionResetStore(database),
        synchronization: synchronization,
      ),
    );
  }

  Future<void> close() async {
    await database.close();
    await root.delete(recursive: true);
  }
}

Future<void> _seed(
  AppDatabase database,
  AccountId accountId,
  String listTitle,
  String taskTitle,
) async {
  final cache = CacheDao(database);
  final list = await cache.putTaskList(
    accountId: accountId,
    remoteId: TaskListRemoteId('remote-list-${accountId.value}'),
    title: listTitle,
  );
  await cache.putTask(
    accountId: accountId,
    taskListId: list,
    remoteId: TaskRemoteId('remote-task-${accountId.value}'),
    title: taskTitle,
    position: '1000',
  );
}

final class _Rebuild implements LocalDataResetSynchronization {
  const _Rebuild({
    required this.database,
    required this.accountId,
    required this.available,
  });

  final AppDatabase database;
  final AccountId accountId;
  final bool available;

  @override
  Future<void> serializeResetAndRebuild(Future<void> Function() reset) async {
    await reset();
    if (available) {
      await _seed(
        database,
        accountId,
        'Rebuilt Google list',
        'Rebuilt Google task',
      );
    }
  }
}

final class _Health implements SyncHealthRepository {
  const _Health(this.outcome);

  final SyncHealthOutcome outcome;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: outcome,
      failureReason: outcome == SyncHealthOutcome.failed
          ? SyncFailureReason.noConnection
          : null,
      action: outcome == SyncHealthOutcome.failed
          ? SyncHealthAction.retry
          : SyncHealthAction.none,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: outcome == SyncHealthOutcome.good
          ? DateTime.utc(2026, 8, 16, 12)
          : null,
      evaluatedAt: DateTime.utc(2026, 8, 16, 12),
    ),
  );
}
