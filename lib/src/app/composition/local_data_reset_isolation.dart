import '../../core/outcome.dart';
import '../../data/auth/authorization.dart';
import '../../domain/model/tasks.dart';
import '../../domain/recovery/local_data_recovery.dart';
import 'app_composition.dart';

/// Fail-closed adapter for destructive reset in development/test compositions.
///
/// The caller must name the exact injected database boundary and pass the
/// already authenticated dedicated subject. Release reset does not use this
/// adapter; it is scoped by the selected account transaction instead.
final class DevelopmentIsolatedLocalDataResetStore
    implements LocalDataResetStore {
  DevelopmentIsolatedLocalDataResetStore({
    required this.delegate,
    required CompositionBoundary boundary,
    required String explicitDatabaseName,
    required this.accountGuard,
    required this.subject,
  }) {
    if (boundary.profile == CompositionProfile.release ||
        explicitDatabaseName.isEmpty ||
        explicitDatabaseName != boundary.storage.databaseName) {
      throw const LocalDataRecoveryException(
        'development_reset_isolation_failed',
      );
    }
  }

  final LocalDataResetStore delegate;
  final AccountGuard accountGuard;
  final AccountSubject subject;

  @override
  Future<LocalDataResetPreview> preview(AccountId accountId) async {
    _verifyDedicatedAccount();
    return delegate.preview(accountId);
  }

  @override
  Future<void> resetPartition(AccountId accountId) async {
    _verifyDedicatedAccount();
    await delegate.resetPartition(accountId);
  }

  void _verifyDedicatedAccount() {
    if (accountGuard.verify(subject) case Failed<void>()) {
      throw const LocalDataRecoveryException(
        'development_reset_account_guard_failed',
      );
    }
  }
}
