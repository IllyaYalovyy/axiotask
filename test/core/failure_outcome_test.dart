import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Failure', () {
    test('uses value equality for complete typed failure context', () {
      const first = Failure(
        code: 'auth.scope_missing',
        category: FailureCategory.authorization,
        operation: FailureOperation.authorize,
        retry: RetryClassification.permanent,
        impact: 'Google Tasks cannot be synchronized.',
        action: FailureAction.connect,
        safeSummary: 'Tasks authorization is unavailable.',
        sensitiveContext: 'synthetic adapter detail',
      );
      const same = Failure(
        code: 'auth.scope_missing',
        category: FailureCategory.authorization,
        operation: FailureOperation.authorize,
        retry: RetryClassification.permanent,
        impact: 'Google Tasks cannot be synchronized.',
        action: FailureAction.connect,
        safeSummary: 'Tasks authorization is unavailable.',
        sensitiveContext: 'synthetic adapter detail',
      );
      const changedRetry = Failure(
        code: 'auth.scope_missing',
        category: FailureCategory.authorization,
        operation: FailureOperation.authorize,
        retry: RetryClassification.transient,
        impact: 'Google Tasks cannot be synchronized.',
        action: FailureAction.connect,
        safeSummary: 'Tasks authorization is unavailable.',
        sensitiveContext: 'synthetic adapter detail',
      );

      expect(first, same);
      expect(first.hashCode, same.hashCode);
      expect(first, isNot(changedRetry));
    });

    test('maps adapter failures without exposing sensitive exception text', () {
      const source = AuthorizationAdapterFailure(
        kind: AuthorizationAdapterFailureKind.network,
        sensitiveDetails: 'callback included credential-canary',
      );

      final failure = mapAuthorizationFailure(source);

      expect(failure.category, FailureCategory.network);
      expect(failure.operation, FailureOperation.authorize);
      expect(failure.retry, RetryClassification.transient);
      expect(failure.action, FailureAction.retry);
      expect(failure.safeSummary, isNot(contains('credential-canary')));
      expect(failure.sensitiveContext, contains('credential-canary'));
    });
  });

  test('Outcome equality distinguishes success and typed failure', () {
    const failure = Failure(
      code: 'configuration.missing',
      category: FailureCategory.configuration,
      operation: FailureOperation.initialize,
      retry: RetryClassification.permanent,
      impact: 'Connection is unavailable.',
      action: FailureAction.reviewConfiguration,
      safeSummary: 'Required configuration is missing.',
    );

    expect(const Outcome<String>.success('value'), const Success('value'));
    expect(
      const Outcome<String>.failure(failure),
      const Failed<String>(failure),
    );
    expect(
      const Outcome<String>.success('value'),
      isNot(const Outcome<String>.failure(failure)),
    );
  });
}
