import '../../core/failure.dart';
import '../../core/outcome.dart';

final class AccountSubject {
  const AccountSubject(this.value);

  final String value;

  bool get isEmpty => value.trim().isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AccountSubject && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AccountSubject(<redacted>)';
}

sealed class AuthorizationState {
  const AuthorizationState();
}

final class NoTasksAuthorization extends AuthorizationState {
  const NoTasksAuthorization();
}

final class AuthorizationConnecting extends AuthorizationState {
  const AuthorizationConnecting();
}

final class TasksAuthorized extends AuthorizationState {
  const TasksAuthorized(this.subject);

  final AccountSubject subject;
}

final class AuthorizationRefreshPending extends AuthorizationState {
  const AuthorizationRefreshPending(this.subject);

  final AccountSubject subject;
}

final class AuthorizationRejected extends AuthorizationState {
  const AuthorizationRejected(this.failure);

  final Failure failure;
}

final class AuthorizationRequestFailed extends AuthorizationState {
  const AuthorizationRequestFailed(this.failure);

  final Failure failure;
}

abstract interface class AuthorizationPort {
  AuthorizationState get currentState;

  Stream<AuthorizationState> get states;

  Future<Outcome<AccountSubject>> requestTasksAuthorization();
}

final class UnavailableAuthorization implements AuthorizationPort {
  const UnavailableAuthorization();

  @override
  AuthorizationState get currentState => const NoTasksAuthorization();

  @override
  Stream<AuthorizationState> get states =>
      Stream<AuthorizationState>.value(currentState);

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() async =>
      const Outcome<AccountSubject>.failure(
        Failure(
          code: 'auth.adapter_not_available',
          category: FailureCategory.configuration,
          operation: FailureOperation.authorize,
          retry: RetryClassification.permanent,
          impact: 'Google Tasks cannot be connected yet.',
          action: FailureAction.reviewConfiguration,
          safeSummary: 'No platform authorization adapter is configured.',
        ),
      );
}

final class SyntheticAuthorization implements AuthorizationPort {
  const SyntheticAuthorization(this.subject);

  final AccountSubject subject;

  @override
  AuthorizationState get currentState => TasksAuthorized(subject);

  @override
  Stream<AuthorizationState> get states =>
      Stream<AuthorizationState>.value(currentState);

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() async =>
      Outcome<AccountSubject>.success(subject);
}

enum AuthorizationAdapterFailureKind {
  noCredentials,
  missingScope,
  rejected,
  network,
  configuration,
  internal,
}

final class AuthorizationAdapterFailure {
  const AuthorizationAdapterFailure({
    required this.kind,
    this.sensitiveDetails,
  });

  final AuthorizationAdapterFailureKind kind;
  final String? sensitiveDetails;
}

Failure mapAuthorizationFailure(AuthorizationAdapterFailure source) {
  final sensitiveContext = source.sensitiveDetails;
  return switch (source.kind) {
    AuthorizationAdapterFailureKind.noCredentials => Failure(
      code: 'auth.credentials_absent',
      category: FailureCategory.authorization,
      operation: FailureOperation.authorize,
      retry: RetryClassification.permanent,
      impact: 'Google Tasks cannot be synchronized.',
      action: FailureAction.connect,
      safeSummary: 'Tasks authorization is unavailable.',
      sensitiveContext: sensitiveContext,
    ),
    AuthorizationAdapterFailureKind.missingScope => Failure(
      code: 'auth.tasks_scope_absent',
      category: FailureCategory.authorization,
      operation: FailureOperation.authorize,
      retry: RetryClassification.permanent,
      impact: 'Google Tasks cannot be synchronized.',
      action: FailureAction.connect,
      safeSummary: 'Google Tasks access was not granted.',
      sensitiveContext: sensitiveContext,
    ),
    AuthorizationAdapterFailureKind.rejected => Failure(
      code: 'auth.rejected',
      category: FailureCategory.authorization,
      operation: FailureOperation.authorize,
      retry: RetryClassification.permanent,
      impact: 'Google Tasks cannot be synchronized.',
      action: FailureAction.connect,
      safeSummary: 'Google rejected Tasks authorization.',
      sensitiveContext: sensitiveContext,
    ),
    AuthorizationAdapterFailureKind.network => Failure(
      code: 'auth.network',
      category: FailureCategory.network,
      operation: FailureOperation.authorize,
      retry: RetryClassification.transient,
      impact: 'The authorization request did not complete.',
      action: FailureAction.retry,
      safeSummary: 'The authorization service could not be reached.',
      sensitiveContext: sensitiveContext,
    ),
    AuthorizationAdapterFailureKind.configuration => Failure(
      code: 'auth.configuration',
      category: FailureCategory.configuration,
      operation: FailureOperation.initialize,
      retry: RetryClassification.permanent,
      impact: 'Google Tasks connection is unavailable.',
      action: FailureAction.reviewConfiguration,
      safeSummary: 'Authorization configuration is invalid.',
      sensitiveContext: sensitiveContext,
    ),
    AuthorizationAdapterFailureKind.internal => Failure(
      code: 'auth.internal',
      category: FailureCategory.internal,
      operation: FailureOperation.authorize,
      retry: RetryClassification.unknown,
      impact: 'The authorization request did not complete.',
      action: FailureAction.retry,
      safeSummary: 'The authorization adapter failed.',
      sensitiveContext: sensitiveContext,
    ),
  };
}

abstract interface class AccountGuard {
  Outcome<void> verify(AccountSubject authenticatedSubject);
}

final class NormalAccountGuard implements AccountGuard {
  const NormalAccountGuard();

  @override
  Outcome<void> verify(AccountSubject authenticatedSubject) {
    if (authenticatedSubject.isEmpty) {
      return const Outcome<void>.failure(
        Failure(
          code: 'account.subject_absent',
          category: FailureCategory.authorization,
          operation: FailureOperation.authorize,
          retry: RetryClassification.permanent,
          impact: 'Google Tasks cannot be accessed.',
          action: FailureAction.connect,
          safeSummary: 'The authenticated account identity is missing.',
        ),
      );
    }
    return const Outcome<void>.success(null);
  }
}

final class DedicatedAccountGuard implements AccountGuard {
  const DedicatedAccountGuard(this.expectedSubject);

  final AccountSubject? expectedSubject;

  @override
  Outcome<void> verify(AccountSubject authenticatedSubject) {
    final expected = expectedSubject;
    if (expected == null || expected.isEmpty) {
      return const Outcome<void>.failure(
        Failure(
          code: 'account.dedicated_subject_not_configured',
          category: FailureCategory.configuration,
          operation: FailureOperation.authorize,
          retry: RetryClassification.permanent,
          impact: 'Development Google Tasks access is disabled.',
          action: FailureAction.reviewConfiguration,
          safeSummary: 'A dedicated test-account subject is required.',
        ),
      );
    }
    if (authenticatedSubject != expected) {
      return const Outcome<void>.failure(
        Failure(
          code: 'account.dedicated_subject_mismatch',
          category: FailureCategory.authorization,
          operation: FailureOperation.authorize,
          retry: RetryClassification.permanent,
          impact: 'No Google Tasks data was read or changed.',
          action: FailureAction.reviewConfiguration,
          safeSummary:
              'The authenticated account is not the dedicated account.',
        ),
      );
    }
    return const Outcome<void>.success(null);
  }
}
