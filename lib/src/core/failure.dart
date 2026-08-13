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
  });

  final String code;
  final FailureCategory category;
  final FailureOperation operation;
  final RetryClassification retry;
  final String impact;
  final FailureAction? action;
  final String safeSummary;
  final String? sensitiveContext;

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
          sensitiveContext == other.sensitiveContext;

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
  );

  @override
  String toString() =>
      'Failure(code: $code, category: $category, operation: $operation, '
      'retry: $retry)';
}
