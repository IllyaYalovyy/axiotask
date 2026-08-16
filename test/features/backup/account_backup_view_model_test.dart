import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/account_backup_repository.dart';
import 'package:axiotask/src/features/backup/account_backup_view_model.dart';
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
