import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/connectivity/connectivity.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/sync_settings_repository.dart';
import 'package:axiotask/src/sync/coordinator/sync_coordinator.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/retry/retry_episode.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_connectivity.dart';
import '../../support/fake_random.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 15, 12);

  test('REL-009 automatic episode exhausts at exactly five minutes', () async {
    final store = _MemoryRetryStore();
    final runner = _Runner()..defaultFailure = _transient;
    final harness = _Harness(
      t0,
      store: store,
      runner: runner,
      jitter: List<Duration>.generate(
        12,
        (index) => Duration(seconds: index < 6 ? 1 << index : 60),
      ),
    );
    addTearDown(harness.close);

    await harness.coordinator.start();
    expect(runner.calls, 1);
    expect(store.value?.nextAttemptAt, t0.add(const Duration(seconds: 1)));
    expect(harness.health.outcome, SyncHealthOutcome.failed);

    while (harness.clock.now().isBefore(t0.add(const Duration(seconds: 243)))) {
      final next = store.value!.nextAttemptAt!;
      harness.clock.advance(next.difference(harness.clock.now()));
      await pumpEventQueue();
      await harness.coordinator.whenIdle;
    }
    expect(runner.calls, 10); // startup plus nine bounded automatic retries
    expect(store.value?.automaticRetryExhausted, isFalse);

    harness.clock.advance(
      t0.add(const Duration(minutes: 5)).difference(harness.clock.now()) -
          const Duration(milliseconds: 1),
    );
    await pumpEventQueue();
    expect(store.value?.automaticRetryExhausted, isFalse);
    harness.clock.advance(const Duration(milliseconds: 1));
    await pumpEventQueue();

    expect(store.value?.automaticRetryExhausted, isTrue);
    expect(store.value?.nextAttemptAt, isNull);
    expect(runner.calls, 10);
    expect(harness.health.outcome, SyncHealthOutcome.failed);
    expect(harness.health.action, SyncHealthAction.retry);
  });

  test(
    'REL-009 restart restores the same wait without an early call',
    () async {
      final store = _MemoryRetryStore(
        RetryEpisode(
          startedAt: t0,
          deadlineAt: t0.add(const Duration(minutes: 5)),
          nextAttemptAt: t0.add(const Duration(seconds: 30)),
          lastObservedAt: t0,
          attemptCount: 2,
        ),
      );
      final harness = _Harness(t0, store: store, runner: _Runner());
      addTearDown(harness.close);

      unawaited(harness.coordinator.start());
      await pumpEventQueue();
      expect(harness.runner.calls, 0);
      expect(harness.health.outcome, SyncHealthOutcome.failed);
      harness.clock.advance(const Duration(seconds: 29, milliseconds: 999));
      await pumpEventQueue();
      expect(harness.runner.calls, 0);
      harness.clock.advance(const Duration(milliseconds: 1));
      await pumpEventQueue();
      await harness.coordinator.whenIdle;

      expect(harness.runner.calls, 1);
      expect(harness.runner.triggers.single, <SyncTrigger>{SyncTrigger.retry});
    },
  );

  test(
    'REL-010 explicit Retry clears latch but preserves server not-before',
    () async {
      final serverBoundary = t0.add(const Duration(seconds: 30));
      final store = _MemoryRetryStore(
        RetryEpisode(
          startedAt: t0.subtract(const Duration(minutes: 5)),
          deadlineAt: t0,
          serverNotBeforeAt: serverBoundary,
          lastObservedAt: t0,
          attemptCount: 7,
          automaticRetryExhausted: true,
        ),
      );
      final harness = _Harness(t0, store: store, runner: _Runner());
      addTearDown(harness.close);
      await harness.coordinator.start();

      unawaited(harness.coordinator.retry());
      unawaited(harness.coordinator.retry());
      await pumpEventQueue();
      expect(store.value?.automaticRetryExhausted, isFalse);
      expect(store.value?.startedAt, t0);
      expect(store.value?.serverNotBeforeAt, serverBoundary);
      expect(harness.runner.calls, 0);
      expect(harness.health.outcome, SyncHealthOutcome.failed);

      harness.clock.advance(const Duration(seconds: 30));
      await pumpEventQueue();
      await harness.coordinator.whenIdle;
      expect(harness.runner.calls, 1);
      expect(harness.runner.triggers.single, <SyncTrigger>{SyncTrigger.retry});
    },
  );

  test(
    'REL-010 explicit Retry replaces an ordinary wait immediately',
    () async {
      final store = _MemoryRetryStore();
      final runner = _Runner()..defaultFailure = _transient;
      final harness = _Harness(
        t0,
        store: store,
        runner: runner,
        jitter: const <Duration>[Duration(seconds: 1)],
      );
      addTearDown(harness.close);

      await harness.coordinator.start();
      expect(store.value?.nextAttemptAt, t0.add(const Duration(seconds: 1)));
      runner.defaultFailure = null;

      await harness.coordinator.retry();
      await harness.coordinator.whenIdle;

      expect(runner.calls, 2);
      expect(runner.triggers.last, <SyncTrigger>{SyncTrigger.retry});
      expect(store.value, isNull);
      expect(harness.coordinator.currentFacts.detectedFailureReason, isNull);
      expect(harness.coordinator.currentFacts.activity, SyncActivity.idle);
    },
  );

  test('REL-010 no-route Retry keeps the episode deadline active', () async {
    final connectivity = FakeConnectivity(
      initialHint: ConnectivityHint.provenNoRoute,
    );
    addTearDown(connectivity.close);
    final store = _MemoryRetryStore(
      RetryEpisode(
        startedAt: t0.subtract(const Duration(minutes: 5)),
        deadlineAt: t0,
        lastObservedAt: t0,
        attemptCount: 7,
        automaticRetryExhausted: true,
      ),
    );
    final harness = _Harness(
      t0,
      store: store,
      runner: _Runner(),
      connectivity: connectivity,
    );
    addTearDown(harness.close);
    await harness.coordinator.start();

    await harness.coordinator.retry();
    expect(harness.runner.calls, 0);
    expect(store.value?.automaticRetryExhausted, isFalse);

    harness.clock.advance(
      const Duration(minutes: 5) - const Duration(milliseconds: 1),
    );
    await pumpEventQueue();
    expect(store.value?.automaticRetryExhausted, isFalse);
    harness.clock.advance(const Duration(milliseconds: 1));
    await pumpEventQueue();

    expect(store.value?.automaticRetryExhausted, isTrue);
    expect(harness.runner.calls, 0);
  });

  test(
    'REL-010 restored connectivity executes within the same episode',
    () async {
      final connectivity = FakeConnectivity(
        initialHint: ConnectivityHint.provenNoRoute,
      );
      addTearDown(connectivity.close);
      final store = _MemoryRetryStore(
        RetryEpisode(
          startedAt: t0.subtract(const Duration(minutes: 5)),
          deadlineAt: t0,
          lastObservedAt: t0,
          attemptCount: 7,
          automaticRetryExhausted: true,
        ),
      );
      final harness = _Harness(
        t0,
        store: store,
        runner: _Runner(),
        connectivity: connectivity,
      );
      addTearDown(harness.close);
      await harness.coordinator.start();
      await harness.coordinator.retry();
      final episodeStart = store.value?.startedAt;

      connectivity.emit(ConnectivityHint.mayHaveReturned);
      await pumpEventQueue();
      await harness.coordinator.whenIdle;

      expect(episodeStart, t0);
      expect(harness.runner.calls, 1);
      expect(harness.runner.triggers.single, <SyncTrigger>{SyncTrigger.retry});
      expect(store.value, isNull);
    },
  );

  test('REL-011 unknown failure never starts an automatic episode', () async {
    final store = _MemoryRetryStore();
    final runner = _Runner()..defaultFailure = _unknown;
    final harness = _Harness(t0, store: store, runner: runner);
    addTearDown(harness.close);

    await harness.coordinator.start();
    harness.clock.advance(const Duration(minutes: 5));
    await pumpEventQueue();

    expect(store.value, isNull);
    expect(runner.calls, 2); // ordinary foreground cadence remains available
    expect(harness.health.outcome, SyncHealthOutcome.failed);
  });

  test(
    'REL-019 backward wall clock latches instead of extending episode',
    () async {
      final store = _MemoryRetryStore(
        RetryEpisode(
          startedAt: t0,
          deadlineAt: t0.add(const Duration(minutes: 5)),
          nextAttemptAt: t0.add(const Duration(seconds: 30)),
          lastObservedAt: t0.add(const Duration(seconds: 10)),
          attemptCount: 1,
        ),
      );
      final harness = _Harness(
        t0.subtract(const Duration(seconds: 1)),
        store: store,
        runner: _Runner(),
      );
      addTearDown(harness.close);

      await harness.coordinator.start();

      expect(store.value?.automaticRetryExhausted, isTrue);
      expect(harness.runner.calls, 0);
      expect(harness.health.outcome, SyncHealthOutcome.failed);
    },
  );
}

final class _Harness {
  _Harness(
    DateTime startedAt, {
    required this.store,
    required this.runner,
    List<Duration> jitter = const <Duration>[],
    FakeConnectivity? connectivity,
  }) : clock = FakeClock(startedAt) {
    coordinator = SyncCoordinator(
      accountId: const AccountId(1),
      authorization: const SyntheticAuthorization(
        AccountSubject('synthetic-retry-coordinator'),
      ),
      clock: clock,
      scheduler: clock,
      random: jitter.isEmpty
          ? FakeRandom.seeded(7)
          : FakeRandom.scriptedJitter(jitter),
      settings: _Settings(),
      retryStore: store,
      connectivity: connectivity,
      run: runner.call,
    );
  }

  final FakeClock clock;
  final _MemoryRetryStore store;
  final _Runner runner;
  late final SyncCoordinator coordinator;

  SyncHealth get health => projectSyncHealth(
    facts: PersistedSyncFacts(
      lastSuccessfulSyncAt: clock.now().subtract(const Duration(minutes: 1)),
      retryWaiting: store.value?.retryWaiting ?? false,
      automaticRetryExhausted: store.value?.automaticRetryExhausted ?? false,
      latestFailure: runner.calls == 0
          ? null
          : SyncFailureFact(
              reason: SyncFailureReason.remoteFailure,
              occurredAt: clock.now(),
              diagnosticCode: 'synthetic.retry',
              action: SyncHealthAction.retry,
            ),
    ),
    runtime: coordinator.currentFacts,
    now: clock.now(),
  );

  Future<void> close() => coordinator.close();
}

final class _MemoryRetryStore implements SyncRetryEpisodeStore {
  _MemoryRetryStore([this.value]);

  RetryEpisode? value;

  @override
  Future<RetryEpisode?> readRetryEpisode(AccountId accountId) async => value;

  @override
  Future<void> writeRetryEpisode(
    AccountId accountId,
    RetryEpisode episode,
  ) async {
    value = episode;
  }

  @override
  Future<void> clearRetryEpisode(AccountId accountId) async {
    value = null;
  }
}

final class _Runner {
  Failure? defaultFailure;
  final List<Set<SyncTrigger>> triggers = <Set<SyncTrigger>>[];
  int calls = 0;

  Future<SyncRunReport> call(SyncCoordinatorRun request) async {
    calls += 1;
    triggers.add(request.triggers);
    final failure = defaultFailure;
    return SyncRunReport(
      outcome: failure == null
          ? SyncRunOutcome.succeeded
          : SyncRunOutcome.failed,
      runId: SyncRunId('synthetic-retry-run-$calls'),
      complete: failure == null,
      taskListPages: failure == null ? 1 : 0,
      taskPages: 0,
      remoteTaskLists: 0,
      remoteTasks: 0,
      resourceProjectionWrites: 0,
      failure: failure,
    );
  }
}

final class _Settings implements SyncSettingsRepository {
  @override
  Future<bool> readSyncEnabled(AccountId accountId) async => true;

  @override
  Future<void> setSyncEnabled(AccountId accountId, bool enabled) async {}
}

const Failure _transient = Failure(
  code: 'synthetic.retryable',
  category: FailureCategory.remote,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.transient,
  impact: 'Synthetic retryable failure.',
  action: FailureAction.retry,
  safeSummary: 'Synthetic retryable failure.',
);

const Failure _unknown = Failure(
  code: 'synthetic.unknown',
  category: FailureCategory.remote,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.unknown,
  impact: 'Synthetic unknown failure.',
  safeSummary: 'Synthetic unknown failure.',
);
