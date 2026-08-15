import '../model/tasks.dart';

/// Durable account-scoped controls that affect synchronization eligibility.
abstract interface class SyncSettingsRepository {
  Future<bool> readSyncEnabled(AccountId accountId);

  Future<void> setSyncEnabled(AccountId accountId, bool enabled);
}
