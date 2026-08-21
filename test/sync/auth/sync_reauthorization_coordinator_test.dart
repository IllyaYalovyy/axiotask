import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/sync_settings_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/coordinator/sync_coordinator.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_auth.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_random.dart';

void main() {
  final now = DateTime.utc(2026, 8, 15, 12);
  const subject = AccountSubject('synthetic-reauthorization-subject');

  test('AUTH-002 restart restores latch and suppresses remote work', () async {
    final fixture = await _Fixture.create(now, subject, latched: true);
    addTearDown(fixture.close);

    await fixture.coordinator.start();

    expect(fixture.runner.calls, 0);
    expect(
      fixture.coordinator.currentFacts.authorization,
      SyncAuthorization.absent,
    );
    expect((await fixture.health()).action, SyncHealthAction.reauthorize);
  });

  test('AUTH-002 adapter-declared terminal state persists the latch', () async {
    final fixture = await _Fixture.create(
      now,
      subject,
      latched: false,
      initialAuthorization: const AuthorizationRejected(_terminal),
    );
    addTearDown(fixture.close);

    await fixture.coordinator.start();

    expect(
      (await fixture.store.readEligibility(
        fixture.accountId,
      )).reauthorizationRequired,
      isTrue,
    );
    expect(fixture.runner.calls, 0);
    expect((await fixture.health()).action, SyncHealthAction.reauthorize);
  });

  test(
    'missing saved credentials latch Reauthorize instead of dead Connect',
    () async {
      final fixture = await _Fixture.create(now, subject, latched: false);
      addTearDown(fixture.close);
      fixture.authorization.enqueue(
        FakeAuthorizationAttempt.restoreRejected(subject, _missingCredentials),
      );

      await fixture.coordinator.start();

      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isTrue,
      );
      expect((await fixture.health()).action, SyncHealthAction.reauthorize);
      expect(fixture.runner.calls, 0);
    },
  );

  test(
    'retryable authorization infrastructure failure stays Failed with Retry',
    () async {
      final fixture = await _Fixture.create(now, subject, latched: false);
      addTearDown(fixture.close);
      fixture.authorization.enqueue(
        FakeAuthorizationAttempt.restoreRequestFailed(
          subject,
          _authorizationNetworkFailure,
        ),
      );

      await fixture.coordinator.start();

      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isFalse,
      );
      final health = await fixture.health();
      expect(health.outcome, SyncHealthOutcome.failed);
      expect(health.failureReason, SyncFailureReason.noConnection);
      expect(health.action, SyncHealthAction.retry);
      expect(health.diagnosticCode, _authorizationNetworkFailure.code);
      expect(fixture.runner.calls, 0);
    },
  );

  test(
    'missing configuration stays Failed without an unwired Connect action',
    () async {
      final fixture = await _Fixture.create(now, subject, latched: false);
      addTearDown(fixture.close);
      fixture.authorization.enqueue(
        FakeAuthorizationAttempt.restoreRequestFailed(
          subject,
          _authorizationConfigurationFailure,
        ),
      );

      await fixture.coordinator.start();

      final health = await fixture.health();
      expect(health.outcome, SyncHealthOutcome.failed);
      expect(health.failureReason, SyncFailureReason.applicationFailure);
      expect(health.action, SyncHealthAction.none);
      expect(health.diagnosticCode, _authorizationConfigurationFailure.code);
      expect(fixture.runner.calls, 0);
    },
  );

  test('AUTH-003 cancel preserves latch, cache, and intent', () async {
    final fixture = await _Fixture.create(now, subject, latched: true);
    addTearDown(fixture.close);
    fixture.authorization.enqueue(
      FakeAuthorizationAttempt.interactiveCancelled(_cancelled),
    );
    await fixture.coordinator.start();

    await fixture.coordinator.reauthorize();

    expect(
      (await fixture.store.readEligibility(
        fixture.accountId,
      )).reauthorizationRequired,
      isTrue,
    );
    expect(fixture.runner.calls, 0);
    expect((await fixture.health()).action, SyncHealthAction.reauthorize);
  });

  test('AUTH-003 wrong scope preserves latch and does not run', () async {
    final fixture = await _Fixture.create(now, subject, latched: true);
    addTearDown(fixture.close);
    fixture.authorization.enqueue(
      FakeAuthorizationAttempt.interactiveRejected(_missingScope),
    );
    await fixture.coordinator.start();

    await fixture.coordinator.reauthorize();

    expect(
      (await fixture.store.readEligibility(
        fixture.accountId,
      )).reauthorizationRequired,
      isTrue,
    );
    expect(fixture.runner.calls, 0);
  });

  test(
    'AUTH-003 matching login clears latch but remains Pending for full run',
    () async {
      final fixture = await _Fixture.create(
        now,
        subject,
        latched: true,
        holdRun: true,
      );
      addTearDown(fixture.close);
      fixture.authorization.enqueue(
        FakeAuthorizationAttempt.interactiveSuccess(subject),
      );
      await fixture.coordinator.start();

      final action = fixture.coordinator.reauthorize();
      await fixture.runner.whenCalled;

      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isFalse,
      );
      expect(fixture.runner.calls, 1);
      expect((await fixture.health()).outcome, SyncHealthOutcome.pending);
      expect(
        (await fixture.health()).pendingReason,
        SyncPendingReason.verifying,
      );
      fixture.runner.complete();
      await action;
    },
  );

  test('AUTH-004 interactive subject mismatch preserves latch', () async {
    final fixture = await _Fixture.create(now, subject, latched: true);
    addTearDown(fixture.close);
    fixture.authorization.enqueue(
      FakeAuthorizationAttempt.interactiveSuccess(
        const AccountSubject('different-synthetic-subject'),
      ),
    );
    await fixture.coordinator.start();

    await fixture.coordinator.reauthorize();

    expect(
      (await fixture.store.readEligibility(
        fixture.accountId,
      )).reauthorizationRequired,
      isTrue,
    );
    expect(fixture.runner.calls, 0);
  });

  test(
    'HLT-001 stopped sync remains stopped after valid reauthorization',
    () async {
      final fixture = await _Fixture.create(
        now,
        subject,
        latched: true,
        syncEnabled: false,
      );
      addTearDown(fixture.close);
      fixture.authorization.enqueue(
        FakeAuthorizationAttempt.interactiveSuccess(subject),
      );
      await fixture.coordinator.start();

      await fixture.coordinator.reauthorize();

      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isFalse,
      );
      expect(fixture.runner.calls, 0);
      expect(
        (await fixture.health()).inactiveReason,
        SyncInactiveReason.syncStopped,
      );
      expect((await fixture.health()).action, SyncHealthAction.resume);
    },
  );
}

final class _Fixture {
  _Fixture._({
    required this.database,
    required this.store,
    required this.accountId,
    required this.authorization,
    required this.clock,
    required this.runner,
    required this.coordinator,
  });

  static Future<_Fixture> create(
    DateTime now,
    AccountSubject subject, {
    required bool latched,
    bool syncEnabled = true,
    bool holdRun = false,
    AuthorizationState initialAuthorization = const NoTasksAuthorization(),
  }) async {
    final database = AppDatabase.inMemory();
    final accountId = AccountId(await database.createAccount(subject.value));
    final store = DatabaseReadSyncStore(database);
    if (latched) await store.requireReauthorization(accountId);
    final settings = DatabaseSyncSettingsRepository(database);
    if (!syncEnabled) await settings.setSyncEnabled(accountId, false);
    final authorization = FakeAuthorization(initialState: initialAuthorization);
    final clock = FakeClock(now);
    final runner = _Runner(hold: holdRun);
    final coordinator = SyncCoordinator(
      accountId: accountId,
      authorization: authorization,
      clock: clock,
      scheduler: clock,
      random: FakeRandom.seeded(41),
      settings: settings,
      retryStore: store,
      reauthorizationStore: store,
      run: runner.call,
    );
    return _Fixture._(
      database: database,
      store: store,
      accountId: accountId,
      authorization: authorization,
      clock: clock,
      runner: runner,
      coordinator: coordinator,
    );
  }

  final AppDatabase database;
  final DatabaseReadSyncStore store;
  final AccountId accountId;
  final FakeAuthorization authorization;
  final FakeClock clock;
  final _Runner runner;
  final SyncCoordinator coordinator;

  Future<SyncHealth> health() async => projectSyncHealth(
    facts: await SyncHealthDao(database).watchFacts(accountId).first,
    runtime: coordinator.currentFacts,
    now: clock.now(),
  );

  Future<void> close() async {
    await coordinator.close();
    await authorization.close();
    await database.close();
  }
}

final class _Runner {
  _Runner({required this.hold});

  final bool hold;
  final Completer<void> _called = Completer<void>();
  final Completer<void> _release = Completer<void>();
  int calls = 0;

  Future<void> get whenCalled => _called.future;

  Future<SyncRunReport> call(SyncCoordinatorRun request) async {
    calls += 1;
    if (!_called.isCompleted) _called.complete();
    if (hold) await _release.future;
    return SyncRunReport(
      outcome: SyncRunOutcome.succeeded,
      runId: SyncRunId('synthetic-reauthorization-run-$calls'),
      complete: true,
      taskListPages: 1,
      taskPages: 0,
      remoteTaskLists: 0,
      remoteTasks: 0,
      resourceProjectionWrites: 0,
    );
  }

  void complete() {
    if (!_release.isCompleted) _release.complete();
  }
}

const _cancelled = Failure(
  code: 'auth.cancelled',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Synthetic authorization was cancelled.',
  safeSummary: 'Synthetic cancellation.',
);

const _missingScope = Failure(
  code: 'auth.tasks_scope_absent',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Synthetic Tasks scope was not granted.',
  safeSummary: 'Synthetic Tasks scope is absent.',
);

const _terminal = Failure(
  code: 'auth.refresh_rejected',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Synthetic authorization requires renewal.',
  safeSummary: 'Synthetic terminal authorization rejection.',
  authorizationRecovery: AuthorizationRecovery.reauthorize,
);

const _missingCredentials = Failure(
  code: 'auth.credentials_absent',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Synthetic authorization is absent.',
  action: FailureAction.connect,
  safeSummary: 'Synthetic saved authorization is absent.',
  authorizationRecovery: AuthorizationRecovery.reauthorize,
);

const _authorizationNetworkFailure = Failure(
  code: 'auth.network_timeout',
  category: FailureCategory.network,
  operation: FailureOperation.authorize,
  retry: RetryClassification.transient,
  impact: 'Synthetic authorization request timed out.',
  action: FailureAction.retry,
  safeSummary: 'Synthetic authorization service timeout.',
);

const _authorizationConfigurationFailure = Failure(
  code: 'auth.configuration',
  category: FailureCategory.configuration,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Synthetic authorization configuration is missing.',
  action: FailureAction.reviewConfiguration,
  safeSummary: 'Synthetic authorization configuration failure.',
);
