enum FailureCategory {
  network,
  authorization,
  rateLimit,
  remote,
  persistence,
  configuration,
  unsupportedRemoteState,
  internal,
}

enum FailureOperation {
  initialize,
  authorize,
  read,
  write,
  synchronize,
  diagnose,
}

enum RetryClassification { transient, permanent, unknown }

enum FailureAction { retry, connect, reviewConfiguration }

/// Policy admitted for a conclusively classified Google authorization failure.
///
/// Most authorization-looking HTTP responses remain [none]. Only an adapter
/// contract backed by accepted endpoint evidence may opt a response into the
/// single refresh-and-repeat path.
enum AuthorizationRecovery { none, refreshOnce }

sealed class RetryAfter {
  const RetryAfter();
}

final class RetryAfterDelay extends RetryAfter {
  const RetryAfterDelay(this.delay);

  final Duration delay;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RetryAfterDelay && delay == other.delay;

  @override
  int get hashCode => delay.hashCode;
}

final class RetryAfterDate extends RetryAfter {
  const RetryAfterDate(this.date);

  final DateTime date;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RetryAfterDate && date == other.date;

  @override
  int get hashCode => date.hashCode;
}

final class RemoteFailureContext {
  const RemoteFailureContext({
    required this.statusCode,
    required this.retryAfter,
  });

  final int statusCode;
  final RetryAfter? retryAfter;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteFailureContext &&
          statusCode == other.statusCode &&
          retryAfter == other.retryAfter;

  @override
  int get hashCode => Object.hash(statusCode, retryAfter);
}

final class Failure {
  const Failure({
    required this.code,
    required this.category,
    required this.operation,
    required this.retry,
    required this.impact,
    required this.safeSummary,
    this.action,
    this.sensitiveContext,
    this.remoteContext,
    this.authorizationRecovery = AuthorizationRecovery.none,
  });

  final String code;
  final FailureCategory category;
  final FailureOperation operation;
  final RetryClassification retry;
  final String impact;
  final FailureAction? action;
  final String safeSummary;
  final String? sensitiveContext;
  final RemoteFailureContext? remoteContext;
  final AuthorizationRecovery authorizationRecovery;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Failure &&
          code == other.code &&
          category == other.category &&
          operation == other.operation &&
          retry == other.retry &&
          impact == other.impact &&
          action == other.action &&
          safeSummary == other.safeSummary &&
          sensitiveContext == other.sensitiveContext &&
          remoteContext == other.remoteContext &&
          authorizationRecovery == other.authorizationRecovery;

  @override
  int get hashCode => Object.hash(
    code,
    category,
    operation,
    retry,
    impact,
    action,
    safeSummary,
    sensitiveContext,
    remoteContext,
    authorizationRecovery,
  );

  @override
  String toString() =>
      'Failure(code: $code, category: $category, operation: $operation, '
      'retry: $retry)';
}
