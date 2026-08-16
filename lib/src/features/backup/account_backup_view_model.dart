import 'package:flutter/foundation.dart';

import '../../core/clock.dart';
import '../../data/backup/local_account_backup_exporter.dart';
import '../../domain/backup/account_backup.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/account_backup_repository.dart';

final class AccountBackupResult {
  const AccountBackupResult({
    required this.fileName,
    required this.listCount,
    required this.taskCount,
  });

  final String fileName;
  final int listCount;
  final int taskCount;
}

final class AccountBackupViewState {
  const AccountBackupViewState({
    this.isWorking = false,
    this.result,
    this.notice,
    this.error,
  });

  final bool isWorking;
  final AccountBackupResult? result;
  final String? notice;
  final String? error;
}

final class AccountBackupViewModel extends ChangeNotifier {
  AccountBackupViewModel({
    required this.accountId,
    required this.repository,
    required this.exporter,
    required this.clock,
    this.codec = const AccountBackupCodec(),
  });

  final AccountId accountId;
  final AccountBackupRepository repository;
  final AccountBackupExporter exporter;
  final Clock clock;
  final AccountBackupCodec codec;
  AccountBackupViewState _state = const AccountBackupViewState();

  AccountBackupViewState get state => _state;

  Future<void> export() async {
    if (_state.isWorking) return;
    _state = const AccountBackupViewState(isWorking: true);
    notifyListeners();
    try {
      final snapshot = await repository.readProjectedAccount(accountId);
      final now = clock.now().toUtc();
      final contents = codec.encode(snapshot, exportedAt: now);
      final result = await exporter.save(
        suggestedName: _suggestedName(now),
        contents: contents,
      );
      _state = switch (result) {
        AccountBackupSaveCancelled() => const AccountBackupViewState(
          notice: 'Export canceled. No backup file was written.',
        ),
        AccountBackupSaved(:final fileName) => AccountBackupViewState(
          result: AccountBackupResult(
            fileName: fileName,
            listCount: snapshot.lists.length,
            taskCount: snapshot.tasks.length,
          ),
        ),
      };
    } on Object {
      _state = const AccountBackupViewState(
        error: 'Could not export this account backup.',
      );
    }
    notifyListeners();
  }
}

String _suggestedName(DateTime value) {
  final date =
      '${value.year.toString().padLeft(4, '0')}'
      '${value.month.toString().padLeft(2, '0')}'
      '${value.day.toString().padLeft(2, '0')}';
  return 'axiotask-account-backup-v1-$date.json';
}
