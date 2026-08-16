import '../backup/account_backup.dart';
import '../model/tasks.dart';

abstract interface class AccountBackupRepository {
  Future<AccountBackupSnapshot> readProjectedAccount(AccountId accountId);
}

abstract interface class AccountBackupRestoreRepository {
  Future<AccountBackupImportPreview> previewImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  });

  Future<AccountBackupImportResult> restoreImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  });
}
