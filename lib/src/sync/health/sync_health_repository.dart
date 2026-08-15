import '../../core/failure.dart';
import '../../data/auth/authorization.dart';
import '../../domain/model/tasks.dart';
import 'sync_health.dart';

abstract interface class SyncHealthRepository {
  Stream<SyncHealth> watchHealth(AccountId accountId);
}

abstract interface class SyncRuntimeFactsSource {
  SyncRuntimeFacts get currentFacts;

  Stream<SyncRuntimeFacts> get facts;
}

final class StaticSyncRuntimeFactsSource implements SyncRuntimeFactsSource {
  const StaticSyncRuntimeFactsSource(this.currentFacts);

  @override
  final SyncRuntimeFacts currentFacts;

  @override
  Stream<SyncRuntimeFacts> get facts => Stream<SyncRuntimeFacts>.empty();
}

final class AuthorizationRuntimeFactsSource implements SyncRuntimeFactsSource {
  const AuthorizationRuntimeFactsSource(this._authorization);

  final AuthorizationPort _authorization;

  @override
  SyncRuntimeFacts get currentFacts =>
      _mapAuthorization(_authorization.currentState);

  @override
  Stream<SyncRuntimeFacts> get facts =>
      _authorization.states.map(_mapAuthorization);
}

SyncRuntimeFacts _mapAuthorization(AuthorizationState state) => switch (state) {
  NoTasksAuthorization() || AuthorizationRejected() => const SyncRuntimeFacts(
    authorization: SyncAuthorization.absent,
  ),
  AuthorizationConnecting() ||
  AuthorizationRefreshPending() => const SyncRuntimeFacts(
    authorization: SyncAuthorization.refreshing,
    activity: SyncActivity.checkingAuthorization,
  ),
  TasksAuthorized() || AuthorizationExpired() => const SyncRuntimeFacts(
    authorization: SyncAuthorization.usable,
    verificationRequired: true,
  ),
  AuthorizationRequestFailed(:final failure) => SyncRuntimeFacts(
    authorization: SyncAuthorization.unknown,
    detectedFailureReason: switch (failure.category) {
      FailureCategory.network => SyncFailureReason.noConnection,
      FailureCategory.rateLimit ||
      FailureCategory.remote => SyncFailureReason.remoteFailure,
      _ => SyncFailureReason.applicationFailure,
    },
    diagnosticCode: failure.code,
    failureAction: failure.action == FailureAction.retry
        ? SyncHealthAction.retry
        : SyncHealthAction.none,
  ),
};
