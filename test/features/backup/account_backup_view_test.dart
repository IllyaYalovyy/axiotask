import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/account_backup_repository.dart';
import 'package:axiotask/src/features/backup/account_backup_view.dart';
import 'package:axiotask/src/features/backup/account_backup_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'warning precedes export and result remains private-data marked',
    (tester) async {
      final exporter = _Exporter();
      final model = AccountBackupViewModel(
        accountId: const AccountId(1),
        repository: const _Repository(),
        exporter: exporter,
        clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
      );
      await tester.pumpWidget(
        MaterialApp(home: AccountBackupView(viewModel: model)),
      );

      expect(find.textContaining('private Google Tasks data'), findsOneWidget);
      expect(find.text('Version 1 JSON'), findsOneWidget);
      expect(find.text('Current Google account'), findsOneWidget);

      await tester.tap(find.text('Choose file and export'));
      await tester.pumpAndSettle();
      expect(find.text('Export private task data?'), findsOneWidget);
      expect(exporter.calls, 0);

      await tester.tap(find.text('Export backup'));
      await tester.pumpAndSettle();
      expect(exporter.calls, 1);
      expect(find.text('Backup exported'), findsOneWidget);
      expect(find.textContaining('1 list and 1 task'), findsOneWidget);
      expect(find.textContaining('private Google Tasks data'), findsOneWidget);
    },
  );

  testWidgets('confirmation cancel never opens the file adapter', (
    tester,
  ) async {
    final exporter = _Exporter();
    final model = AccountBackupViewModel(
      accountId: const AccountId(1),
      repository: const _Repository(),
      exporter: exporter,
      clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
    );
    await tester.pumpWidget(
      MaterialApp(home: AccountBackupView(viewModel: model)),
    );

    await tester.tap(find.text('Choose file and export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(exporter.calls, 0);
    expect(find.text('Backup exported'), findsNothing);
  });

  testWidgets(
    'restore shows preview, limitations, and result before publication',
    (tester) async {
      final restore = _Restore();
      final model = AccountBackupViewModel(
        accountId: const AccountId(1),
        repository: const _Repository(),
        exporter: _Exporter(),
        clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
        restoreRepository: restore,
        importer: _Importer(),
        syncHealthRepository: const _Health(),
      );
      await tester.pumpWidget(
        MaterialApp(home: AccountBackupView(viewModel: model)),
      );

      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose backup to restore'));
      await tester.pumpAndSettle();
      expect(find.text('Restore preview'), findsOneWidget);
      expect(
        find.textContaining('never overwritten or deleted'),
        findsOneWidget,
      );
      expect(find.textContaining('cross-account duplicates'), findsOneWidget);
      expect(restore.calls, 0);

      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore absent records'));
      await tester.pumpAndSettle();
      expect(restore.calls, 1);
      expect(find.text('Restore accepted locally'), findsOneWidget);
      expect(
        find.textContaining('Synchronization will publish'),
        findsOneWidget,
      );
    },
  );
}

final class _Importer implements AccountBackupImporter {
  @override
  Future<AccountBackupOpenResult> open() async =>
      AccountBackupOpenResult.opened(
        fileName: 'synthetic.json',
        contents: const AccountBackupCodec().encode(
          AccountBackupSnapshot(
            sourceGoogleSubject: 'synthetic-subject',
            lists: const <AccountBackupList>[
              AccountBackupList(
                key: 'list-000001',
                googleId: null,
                title: 'Restored',
                order: 0,
              ),
            ],
            tasks: const <AccountBackupTask>[],
          ),
          exportedAt: DateTime.utc(2026, 8, 16, 11),
        ),
      );
}

final class _Restore implements AccountBackupRestoreRepository {
  int calls = 0;

  @override
  Future<AccountBackupImportPreview> previewImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  }) async => const AccountBackupImportPreview(
    documentDigest: 'digest',
    sourceAccountMatches: false,
    listCount: 1,
    taskCount: 0,
    listsToCreate: 1,
    tasksToCreate: 0,
    existingListCount: 0,
    existingTaskCount: 0,
    alreadyImported: false,
  );

  @override
  Future<AccountBackupImportResult> restoreImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  }) async {
    calls += 1;
    return const AccountBackupImportResult(
      createdListCount: 1,
      existingListCount: 0,
      createdTaskCount: 0,
      existingTaskCount: 0,
      alreadyImported: false,
    );
  }
}

final class _Health implements SyncHealthRepository {
  const _Health();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.good,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: DateTime.utc(2026, 8, 16, 12),
      evaluatedAt: DateTime.utc(2026, 8, 16, 12),
    ),
  );
}

final class _Repository implements AccountBackupRepository {
  const _Repository();

  @override
  Future<AccountBackupSnapshot> readProjectedAccount(
    AccountId accountId,
  ) async => AccountBackupSnapshot(
    sourceGoogleSubject: 'synthetic-subject',
    lists: const <AccountBackupList>[
      AccountBackupList(
        key: 'list-000001',
        googleId: 'remote-list',
        title: 'Synthetic list',
        order: 0,
      ),
    ],
    tasks: const <AccountBackupTask>[
      AccountBackupTask(
        key: 'task-000001',
        googleId: null,
        listKey: 'list-000001',
        parentKey: null,
        title: 'Offline task',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
        order: 0,
      ),
    ],
  );
}

final class _Exporter implements AccountBackupExporter {
  int calls = 0;

  @override
  Future<AccountBackupSaveResult> save({
    required String suggestedName,
    required String contents,
  }) async {
    calls += 1;
    return const AccountBackupSaveResult.saved('synthetic-backup.json');
  }
}
