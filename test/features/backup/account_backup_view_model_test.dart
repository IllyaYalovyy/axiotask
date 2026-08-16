import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/account_backup_repository.dart';
import 'package:axiotask/src/features/backup/account_backup_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Repository repository;
  late _Exporter exporter;
  late AccountBackupViewModel viewModel;

  setUp(() {
    repository = _Repository();
    exporter = _Exporter();
    viewModel = AccountBackupViewModel(
      accountId: const AccountId(7),
      repository: repository,
      exporter: exporter,
      clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
    );
  });

  test('exports the selected account and reports bounded v1 result', () async {
    await viewModel.export();

    expect(repository.selected, const AccountId(7));
    expect(exporter.contents, contains('"version":1'));
    expect(exporter.suggestedName, startsWith('axiotask-account-backup-v1-'));
    expect(viewModel.state.isWorking, isFalse);
    expect(viewModel.state.result?.fileName, 'synthetic-backup.json');
    expect(viewModel.state.result?.listCount, 1);
    expect(viewModel.state.result?.taskCount, 1);
  });

  test('cancel and failures are explicit and never claim export', () async {
    exporter.result = const AccountBackupSaveResult.cancelled();
    await viewModel.export();
    expect(
      viewModel.state.notice,
      'Export canceled. No backup file was written.',
    );
    expect(viewModel.state.result, isNull);

    exporter.error = StateError('synthetic file failure');
    await viewModel.export();
    expect(viewModel.state.error, 'Could not export this account backup.');
    expect(viewModel.state.result, isNull);
  });

  test(
    'PAR-DATA-002 validates and previews before restore confirmation',
    () async {
      final restore = _RestoreRepository();
      final importer = _Importer(_encodedDocument());
      var scheduled = 0;
      final model = AccountBackupViewModel(
        accountId: const AccountId(7),
        repository: repository,
        exporter: exporter,
        clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
        restoreRepository: restore,
        importer: importer,
        syncHealthRepository: const _HealthRepository(SyncHealthOutcome.good),
        importCommitted: () async => scheduled += 1,
      );

      await model.chooseImport();
      expect(model.state.importPreview?.listsToCreate, 1);
      expect(restore.restoreCalls, 0);

      await model.restore();
      expect(restore.restoreCalls, 1);
      expect(scheduled, 1);
      expect(model.state.importResult?.createdTaskCount, 1);
    },
  );

  test('stale health refuses before repository mutation', () async {
    final restore = _RestoreRepository();
    final model = AccountBackupViewModel(
      accountId: const AccountId(7),
      repository: repository,
      exporter: exporter,
      clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
      restoreRepository: restore,
      importer: _Importer(_encodedDocument()),
      syncHealthRepository: const _HealthRepository(SyncHealthOutcome.failed),
    );

    await model.chooseImport();
    expect(model.state.error, contains('fresh successful sync'));
    expect(restore.restoreCalls, 0);
  });

  test(
    'committed restore remains truthful when sync scheduling fails',
    () async {
      final model = AccountBackupViewModel(
        accountId: const AccountId(7),
        repository: repository,
        exporter: exporter,
        clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
        restoreRepository: _RestoreRepository(),
        importer: _Importer(_encodedDocument()),
        syncHealthRepository: const _HealthRepository(SyncHealthOutcome.good),
        importCommitted: () async => throw StateError('synthetic scheduling'),
      );

      await model.chooseImport();
      await model.restore();

      expect(model.state.importResult?.createdTaskCount, 1);
      expect(model.state.error, contains('accepted locally'));
      expect(model.state.error, contains('Refresh'));
    },
  );
}

String _encodedDocument() => const AccountBackupCodec().encode(
  AccountBackupSnapshot(
    sourceGoogleSubject: 'synthetic-subject',
    lists: const <AccountBackupList>[
      AccountBackupList(
        key: 'list-000001',
        googleId: 'list-a',
        title: 'List',
        order: 0,
      ),
    ],
    tasks: const <AccountBackupTask>[
      AccountBackupTask(
        key: 'task-000001',
        googleId: 'task-a',
        listKey: 'list-000001',
        parentKey: null,
        title: 'Task',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
        order: 0,
      ),
    ],
  ),
  exportedAt: DateTime.utc(2026, 8, 16, 11),
);

final class _Importer implements AccountBackupImporter {
  const _Importer(this.contents);

  final String contents;

  @override
  Future<AccountBackupOpenResult> open() async =>
      AccountBackupOpenResult.opened(
        fileName: 'synthetic.json',
        contents: contents,
      );
}

final class _RestoreRepository implements AccountBackupRestoreRepository {
  int restoreCalls = 0;

  @override
  Future<AccountBackupImportPreview> previewImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  }) async {
    if (readiness != AccountBackupImportReadiness.ready) {
      throw AccountBackupImportException('not_fresh_${readiness.name}');
    }
    return const AccountBackupImportPreview(
      documentDigest: 'digest',
      sourceAccountMatches: true,
      listCount: 1,
      taskCount: 1,
      listsToCreate: 1,
      tasksToCreate: 1,
      existingListCount: 0,
      existingTaskCount: 0,
      alreadyImported: false,
    );
  }

  @override
  Future<AccountBackupImportResult> restoreImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  }) async {
    restoreCalls += 1;
    return const AccountBackupImportResult(
      createdListCount: 1,
      existingListCount: 0,
      createdTaskCount: 1,
      existingTaskCount: 0,
      alreadyImported: false,
    );
  }
}

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository(this.outcome);

  final SyncHealthOutcome outcome;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: outcome,
      failureReason: outcome == SyncHealthOutcome.failed
          ? SyncFailureReason.stale
          : null,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: DateTime.utc(2026, 8, 16, 12),
      evaluatedAt: DateTime.utc(2026, 8, 16, 12),
    ),
  );
}

final class _Repository implements AccountBackupRepository {
  AccountId? selected;

  @override
  Future<AccountBackupSnapshot> readProjectedAccount(
    AccountId accountId,
  ) async {
    selected = accountId;
    return AccountBackupSnapshot(
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
}

final class _Exporter implements AccountBackupExporter {
  String? suggestedName;
  String? contents;
  AccountBackupSaveResult result = const AccountBackupSaveResult.saved(
    'synthetic-backup.json',
  );
  Object? error;

  @override
  Future<AccountBackupSaveResult> save({
    required String suggestedName,
    required String contents,
  }) async {
    if (error case final value?) throw value;
    this.suggestedName = suggestedName;
    this.contents = contents;
    return result;
  }
}
