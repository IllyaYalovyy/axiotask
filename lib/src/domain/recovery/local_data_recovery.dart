import '../model/tasks.dart';

final class LocalDataResetPreview {
  const LocalDataResetPreview({
    required this.accountId,
    required this.cachedListCount,
    required this.cachedTaskCount,
    required this.pendingChangeCount,
    required this.uncertainChangeCount,
    required this.undoRecordCount,
    required this.accountPreferenceCount,
    required this.syncHistoryCount,
    required this.importManifestCount,
  });

  final AccountId accountId;
  final int cachedListCount;
  final int cachedTaskCount;
  final int pendingChangeCount;
  final int uncertainChangeCount;
  final int undoRecordCount;
  final int accountPreferenceCount;
  final int syncHistoryCount;
  final int importManifestCount;
}

final class LocalDataResetConfirmation {
  const LocalDataResetConfirmation({
    required this.accountId,
    required this.preview,
  });

  final AccountId accountId;
  final LocalDataResetPreview preview;
}

final class LocalDataRecoveryException implements Exception {
  const LocalDataRecoveryException(this.code);

  final String code;

  @override
  String toString() => 'LocalDataRecoveryException($code)';
}

abstract interface class LocalDataResetStore {
  Future<LocalDataResetPreview> preview(AccountId accountId);

  Future<void> resetPartition(AccountId accountId);
}

abstract interface class LocalDataResetSynchronization {
  Future<void> serializeResetAndRebuild(Future<void> Function() reset);
}

/// Coordinates the destructive local transaction with the single sync owner.
///
/// Confirmation is represented by the exact preview the user was shown so a
/// caller cannot accidentally reset an account different from the selected
/// partition.
final class LocalDataRecoveryService {
  const LocalDataRecoveryService({
    required this.store,
    required this.synchronization,
  });

  final LocalDataResetStore store;
  final LocalDataResetSynchronization synchronization;

  Future<LocalDataResetPreview> preview(AccountId accountId) =>
      store.preview(accountId);

  Future<void> reset({required LocalDataResetConfirmation confirmation}) async {
    if (confirmation.preview.accountId != confirmation.accountId) {
      throw const LocalDataRecoveryException('confirmation_account_mismatch');
    }
    await synchronization.serializeResetAndRebuild(
      () => store.resetPartition(confirmation.accountId),
    );
  }
}
