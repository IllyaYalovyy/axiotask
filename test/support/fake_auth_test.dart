import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_auth.dart';

const _subject = AccountSubject('synthetic-auth-subject');

void main() {
  group('FakeAuthorization qualification', () {
    test('restore emits refreshing and usable typed states', () async {
      final fake = FakeAuthorization()
        ..enqueue(FakeAuthorizationAttempt.restoreSuccess(_subject));
      final AuthorizationPort authorization = fake;
      addTearDown(fake.close);
      final emitted = <AuthorizationState>[];
      final subscription = authorization.states.listen(emitted.add);
      addTearDown(subscription.cancel);

      expect(
        await authorization.restoreTasksAuthorization(),
        const Outcome<AccountSubject>.success(_subject),
      );

      expect(emitted, <Matcher>[
        isA<AuthorizationRefreshPending>(),
        isA<TasksAuthorized>(),
      ]);
      expect(authorization.currentState, isA<TasksAuthorized>());
      expect(fake.operationLedger, <FakeAuthorizationOperation>[
        FakeAuthorizationOperation.restore,
      ]);
    });

    test('expired authorization can refresh exactly once', () async {
      final fake =
          FakeAuthorization(initialState: const TasksAuthorized(_subject))
            ..expire()
            ..enqueue(FakeAuthorizationAttempt.refreshSuccess(_subject));
      final AuthorizationPort authorization = fake;
      addTearDown(fake.close);
      final emitted = <AuthorizationState>[];
      final subscription = authorization.states.listen(emitted.add);
      addTearDown(subscription.cancel);

      expect(authorization.currentState, isA<AuthorizationExpired>());
      expect(
        await authorization.refreshTasksAuthorization(),
        const Outcome<AccountSubject>.success(_subject),
      );
      expect(emitted, <Matcher>[
        isA<AuthorizationRefreshPending>(),
        isA<TasksAuthorized>(),
      ]);
    });

    test(
      'terminal refresh emits rejection and preserves typed failure',
      () async {
        const failure = Failure(
          code: 'auth.refresh_rejected',
          category: FailureCategory.authorization,
          operation: FailureOperation.authorize,
          retry: RetryClassification.permanent,
          impact: 'Synthetic authorization requires repair.',
          action: FailureAction.connect,
          safeSummary: 'Synthetic refresh was terminally rejected.',
        );
        final fake = FakeAuthorization(
          initialState: const AuthorizationExpired(_subject),
        )..enqueue(FakeAuthorizationAttempt.refreshTerminal(_subject, failure));
        addTearDown(fake.close);

        expect(
          await fake.refreshTasksAuthorization(),
          const Outcome<AccountSubject>.failure(failure),
        );
        final state = fake.currentState;
        expect(state, isA<AuthorizationRejected>());
        expect((state as AuthorizationRejected).failure, failure);
      },
    );

    test('request rejection after dispatch remains an auth fact', () {
      const refreshable = Failure(
        code: 'auth.access_expired',
        category: FailureCategory.authorization,
        operation: FailureOperation.read,
        retry: RetryClassification.transient,
        impact: 'Synthetic authorization needs refresh.',
        action: FailureAction.retry,
        safeSummary: 'Synthetic access authorization expired.',
      );
      const terminal = Failure(
        code: 'auth.tasks_scope_absent',
        category: FailureCategory.authorization,
        operation: FailureOperation.read,
        retry: RetryClassification.permanent,
        impact: 'Synthetic authorization requires repair.',
        action: FailureAction.connect,
        safeSummary: 'Synthetic Tasks scope is absent.',
      );
      final refreshableFake = FakeAuthorization(
        initialState: const TasksAuthorized(_subject),
      );
      addTearDown(refreshableFake.close);
      refreshableFake.rejectDispatchedRequest(refreshable, terminal: false);
      final expired = refreshableFake.currentState as AuthorizationExpired;
      expect(expired.subject, _subject);
      expect(expired.failure, refreshable);

      final terminalFake = FakeAuthorization(
        initialState: const TasksAuthorized(_subject),
      );
      addTearDown(terminalFake.close);
      terminalFake.rejectDispatchedRequest(terminal, terminal: true);
      final rejected = terminalFake.currentState as AuthorizationRejected;
      expect(rejected.failure, terminal);
    });

    test(
      'interactive cancellation returns to the prior stable state',
      () async {
        const failure = Failure(
          code: 'auth.cancelled',
          category: FailureCategory.authorization,
          operation: FailureOperation.authorize,
          retry: RetryClassification.permanent,
          impact: 'Synthetic authorization was cancelled.',
          action: FailureAction.connect,
          safeSummary: 'Synthetic authorization was cancelled.',
        );
        final fake = FakeAuthorization()
          ..enqueue(FakeAuthorizationAttempt.interactiveCancelled(failure));
        addTearDown(fake.close);
        final emitted = <AuthorizationState>[];
        final subscription = fake.states.listen(emitted.add);
        addTearDown(subscription.cancel);

        expect(
          await fake.requestTasksAuthorization(),
          const Outcome<AccountSubject>.failure(failure),
        );
        expect(emitted, <Matcher>[
          isA<AuthorizationConnecting>(),
          isA<NoTasksAuthorization>(),
        ]);
        expect(fake.currentState, isA<NoTasksAuthorization>());
      },
    );

    test('interactive success emits a matching usable subject', () async {
      final fake = FakeAuthorization()
        ..enqueue(FakeAuthorizationAttempt.interactiveSuccess(_subject));
      addTearDown(fake.close);

      expect(
        await fake.requestTasksAuthorization(),
        const Outcome<AccountSubject>.success(_subject),
      );
      final state = fake.currentState as TasksAuthorized;
      expect(state.subject, _subject);
    });

    test('subject mismatch fails closed as a terminal typed fact', () async {
      const failure = Failure(
        code: 'account.subject_mismatch',
        category: FailureCategory.authorization,
        operation: FailureOperation.authorize,
        retry: RetryClassification.permanent,
        impact: 'Synthetic account data was not accessed.',
        action: FailureAction.connect,
        safeSummary: 'Synthetic authenticated subject did not match.',
      );
      final fake = FakeAuthorization()
        ..enqueue(FakeAuthorizationAttempt.restoreMismatch(_subject, failure));
      addTearDown(fake.close);

      final outcome = await fake.restoreTasksAuthorization();
      expect(outcome, const Outcome<AccountSubject>.failure(failure));
      expect(fake.currentState, isA<AuthorizationRejected>());
    });

    test(
      'fails itself on an invalid transition or wrong scripted operation',
      () {
        final invalid = FakeAuthorization();
        addTearDown(invalid.close);
        expect(invalid.expire, throwsStateError);

        final wrongOperation = FakeAuthorization()
          ..enqueue(FakeAuthorizationAttempt.restoreSuccess(_subject));
        addTearDown(wrongOperation.close);
        expect(wrongOperation.refreshTasksAuthorization, throwsStateError);
        expect(wrongOperation.operationLedger, isEmpty);
      },
    );
  });
}
