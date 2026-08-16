import 'dart:io';

import 'package:axiotask/src/app/axiotask_app.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
import 'package:axiotask/src/data/database/account_backup_repository.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/backup/account_backup_view.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'PAR-DATA-001 exports acknowledged projected state through the app route',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s30a-linux-integration-',
      );
      addTearDown(() => root.delete(recursive: true));
      final database = await AppDatabase.openFile(
        File('${root.path}/isolated.sqlite'),
      );
      addTearDown(database.close);
      final clock = ManualClock(DateTime.utc(2026, 8, 16, 12));
      final account = AccountId(
        await database.createAccount('synthetic-backup-linux-subject'),
      );
      final lists = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final tasks = DatabaseTasksRepository(database, clock: clock);
      final list =
          (await lists.createTaskList(
                    CreateTaskListCommand(
                      accountId: account,
                      title: 'Offline Linux list',
                    ),
                  )
                  as Success<TaskListId>)
              .value;
      await tasks.createTask(
        CreateTaskCommand(
          accountId: account,
          taskListId: list,
          title: 'Acknowledged offline Linux task',
          notes: 'Synthetic private task note',
          due: TaskDate(2026, 8, 20),
        ),
      );
      await database
          .into(database.syncRunRows)
          .insert(
            SyncRunRowsCompanion.insert(
              accountId: account.value,
              runId: 'excluded-sync-run',
              triggersJson: '["sync-attempt-private-canary"]',
              state: 'failed',
              startedAt: clock.now(),
              finishedAt: Value<DateTime>(clock.now()),
              failureCode: const Value<String>('excluded-authorization-canary'),
            ),
          );

      final target = File('${root.path}/selected-backup.json');
      final exporter = LocalAccountBackupExporter(_Picker(target.path));
      final viewModel = TasksViewModel(
        accountId: account,
        tasksRepository: tasks,
        syncHealthRepository: const _PendingHealthRepository(),
        clock: clock,
      );
      addTearDown(viewModel.dispose);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        AxiotaskApp(
          viewModel: viewModel,
          accountBackupBuilder: (_) => AccountBackupHost(
            accountId: account,
            repository: DatabaseAccountBackupRepository(database),
            exporter: exporter,
            clock: clock,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Export account backup'));
      await tester.pumpAndSettle();
      expect(find.textContaining('private Google Tasks data'), findsOneWidget);
      await tester.tap(find.text('Choose file and export'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export backup'));
      await tester.pumpAndSettle();

      expect(find.text('Backup exported'), findsOneWidget);
      final encoded = await target.readAsString();
      final decoded = const AccountBackupCodec().decode(encoded);
      expect(decoded.sourceGoogleSubject, 'synthetic-backup-linux-subject');
      expect(decoded.lists.single.title, 'Offline Linux list');
      expect(decoded.tasks.single.title, 'Acknowledged offline Linux task');
      expect(decoded.tasks.single.notes, 'Synthetic private task note');
      expect(encoded, isNot(contains('sync-attempt-private-canary')));
      expect(encoded, isNot(contains('excluded-authorization-canary')));
    },
  );
}

final class _Picker implements AccountBackupSaveLocationPicker {
  const _Picker(this.path);

  final String path;

  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async =>
      path;
}

final class _PendingHealthRepository implements SyncHealthRepository {
  const _PendingHealthRepository();

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
