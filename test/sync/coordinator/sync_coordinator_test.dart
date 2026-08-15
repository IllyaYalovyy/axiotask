import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/lifecycle.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/connectivity/connectivity.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/sync_settings_repository.dart';
import 'package:axiotask/src/sync/coordinator/sync_coordinator.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_connectivity.dart';
import '../../support/fake_lifecycle.dart';

const _subject = AccountSubject('synthetic-coordinator-subject');

void main() {
  final startedAt = DateTime.utc(2026, 8, 15, 12);

  test(
    'RUN-002 serializes runs and merges one follow-up trigger set',
    () async {
      final lifecycle = FakeLifecycle();
      final connectivity = FakeConnectivity();
      final harness = _Harness(
        startedAt: startedAt,
        lifecycle: lifecycle,
        connectivity: connectivity,
      );
      addTearDown(harness.close);
      addTearDown(lifecycle.close);
      addTearDown(connectivity.close);

      final startup = harness.coordinator.start();
      await harness.runner.waitForRuns(1);
      expect(harness.runner.activeRuns, 1);

      final refresh = harness.coordinator.refresh();
      lifecycle.enterBackground();
      lifecycle.acknowledgeCancellation();
      lifecycle.enterForeground();
      connectivity.emit(ConnectivityHint.provenNoRoute);
      connectivity.emit(ConnectivityHint.mayHaveReturned);
      final localEdit = harness.coordinator.localEditCommitted();

      expect(harness.runner.invocations, hasLength(1));
      harness.runner.complete(0);
      await harness.runner.waitForRuns(2);

      expect(harness.runner.maximumActiveRuns, 1);
      expect(harness.runner.invocations[1].triggers, <SyncTrigger>{
        SyncTrigger.refresh,
        SyncTrigger.foregroundResume,
        SyncTrigger.connectivityRestored,
        SyncTrigger.localEdit,
      });

      harness.runner.complete(1);
      await Future.wait(<Future<void>>[startup, refresh, localEdit]);
      expect(harness.runner.invocations, hasLength(2));
      expect(harness.runner.maximumActiveRuns, 1);
    },
  );

  test(
    'RUN-003 local edit debounce is trailing 5 seconds capped at 10',
    () async {
      final harness = _Harness(startedAt: startedAt, autoComplete: true);
      addTearDown(harness.close);
      await harness.coordinator.start();
      harness.runner.clearCompleted();

      unawaited(harness.coordinator.localEditCommitted());
      harness.clock.advance(const Duration(seconds: 4));
      unawaited(harness.coordinator.localEditCommitted());
      harness.clock.advance(const Duration(seconds: 4));
      unawaited(harness.coordinator.localEditCommitted());

      harness.clock.advance(const Duration(seconds: 1, milliseconds: 999));
      await _flushMicrotasks();
      expect(harness.runner.invocations, isEmpty);

      harness.clock.advance(const Duration(milliseconds: 1));
      await harness.coordinator.whenIdle;
      expect(harness.runner.invocations, hasLength(1));
      expect(harness.runner.invocations.single.triggers, <SyncTrigger>{
        SyncTrigger.localEdit,
      });

      harness.runner.clearCompleted();
      unawaited(harness.coordinator.localEditCommitted());
      harness.clock.advance(const Duration(seconds: 4, milliseconds: 999));
      await _flushMicrotasks();
      expect(harness.runner.invocations, isEmpty);
      harness.clock.advance(const Duration(milliseconds: 1));
      await harness.coordinator.whenIdle;
      expect(harness.runner.invocations, hasLength(1));
    },
  );

  test('RUN-004 cadence fires exactly five minutes after completion', () async {
    final harness = _Harness(startedAt: startedAt, autoComplete: true);
    addTearDown(harness.close);
    await harness.coordinator.start();
    harness.runner.clearCompleted();

    expect(harness.clock.pendingTimerCount, 1);
    harness.clock.advance(
      const Duration(minutes: 4, seconds: 59, milliseconds: 999),
    );
    await _flushMicrotasks();
    expect(harness.runner.invocations, isEmpty);

    harness.clock.advance(const Duration(milliseconds: 1));
    await harness.coordinator.whenIdle;
    expect(harness.runner.invocations, hasLength(1));
    expect(harness.runner.invocations.single.triggers, <SyncTrigger>{
      SyncTrigger.cadence,
    });
    expect(harness.clock.pendingTimerCount, 1);
  });

  test('RUN-004 cadence due during a run becomes one follow-up', () async {
    final harness = _Harness(startedAt: startedAt);
    addTearDown(harness.close);
    final startup = harness.coordinator.start();
    await harness.runner.waitForRuns(1);
    harness.runner.complete(0);
    await startup;

    harness.clock.advance(
      const Duration(minutes: 4, seconds: 59, milliseconds: 999),
    );
    final refresh = harness.coordinator.refresh();
    await harness.runner.waitForRuns(2);
    harness.clock.advance(const Duration(milliseconds: 1));
    await _flushMicrotasks();
    expect(harness.runner.invocations, hasLength(2));

    harness.runner.complete(1);
    await harness.runner.waitForRuns(3);
    expect(harness.runner.invocations[2].triggers, <SyncTrigger>{
      SyncTrigger.cadence,
    });
    expect(harness.runner.maximumActiveRuns, 1);
    harness.runner.complete(2);
    await refresh;
  });

  test('RUN-005 startup waits for usable authorization', () async {
    final authorization = _DelayedAuthorization(_subject);
    final harness = _Harness(
      startedAt: startedAt,
      authorization: authorization,
      autoComplete: true,
    );
    addTearDown(harness.close);

    final startup = harness.coordinator.start();
    await _flushMicrotasks();
    expect(harness.runner.invocations, isEmpty);
    expect(
      harness.coordinator.currentFacts.activity,
      SyncActivity.checkingAuthorization,
    );

    authorization.completeRestore();
    await startup;
    expect(harness.runner.invocations, hasLength(1));
    expect(harness.runner.invocations.single.triggers, <SyncTrigger>{
      SyncTrigger.startup,
    });
  });

  test(
    'RUN-006 connectivity restoration triggers but never proves Good',
    () async {
      final connectivity = FakeConnectivity(
        initialHint: ConnectivityHint.provenNoRoute,
      );
      final authorization = _CountingRestoreAuthorization(_subject);
      final harness = _Harness(
        startedAt: startedAt,
        authorization: authorization,
        connectivity: connectivity,
      );
      addTearDown(harness.close);
      addTearDown(connectivity.close);

      unawaited(harness.coordinator.start());
      await _flushMicrotasks();
      expect(harness.runner.invocations, isEmpty);
      expect(authorization.restoreCalls, 0);
      expect(
        _health(harness.coordinator, startedAt).outcome,
        SyncHealthOutcome.failed,
      );

      connectivity.emit(ConnectivityHint.mayHaveReturned);
      await harness.runner.waitForRuns(1);
      expect(authorization.restoreCalls, 1);
      expect(
        _health(harness.coordinator, startedAt).outcome,
        SyncHealthOutcome.pending,
      );
      expect(connectivity.emit(ConnectivityHint.mayHaveReturned), isFalse);
      expect(harness.runner.invocations, hasLength(1));

      harness.runner.complete(0);
      await harness.coordinator.whenIdle;
      expect(
        _health(harness.coordinator, startedAt).outcome,
        SyncHealthOutcome.good,
      );
    },
  );

  test(
    'RUN-010 quiescence holds only one cadence timer and does no work',
    () async {
      final harness = _Harness(startedAt: startedAt, autoComplete: true);
      addTearDown(harness.close);
      await harness.coordinator.start();
      harness.runner.clearCompleted();

      expect(harness.clock.pendingTimerCount, 1);
      harness.clock.advance(const Duration(minutes: 4));
      await _flushMicrotasks();
      expect(harness.runner.invocations, isEmpty);
      expect(harness.clock.pendingTimerCount, 1);
    },
  );

  test(
    'RUN-014 stale success after deadline cannot overwrite failure',
    () async {
      final harness = _Harness(startedAt: startedAt);
      addTearDown(harness.close);

      unawaited(harness.coordinator.start());
      await harness.runner.waitForRuns(1);
      harness.clock.advance(const Duration(minutes: 2));
      expect(
        harness.coordinator.currentFacts.detectedFailureReason,
        SyncFailureReason.remoteFailure,
      );

      harness.runner.complete(0);
      await harness.coordinator.whenIdle;
      expect(
        harness.coordinator.currentFacts.detectedFailureReason,
        SyncFailureReason.remoteFailure,
      );
      expect(
        harness.coordinator.currentFacts.diagnosticCode,
        'sync.run_timeout',
      );
    },
  );

  test(
    'REL-005 run deadline is exact, monotonic, and requests cancellation',
    () async {
      final harness = _Harness(startedAt: startedAt);
      addTearDown(harness.close);

      unawaited(harness.coordinator.start());
      await harness.runner.waitForRuns(1);
      final invocation = harness.runner.invocations.single;
      expect(invocation.deadline, const Duration(minutes: 2));

      harness.clock.jumpWall(const Duration(days: 3));
      harness.clock.advanceMonotonic(
        const Duration(minutes: 1, seconds: 59, milliseconds: 999),
      );
      expect(invocation.control.isCancellationRequested, isFalse);
      expect(harness.coordinator.currentFacts.detectedFailureReason, isNull);

      harness.clock.advanceMonotonic(const Duration(milliseconds: 1));
      expect(invocation.control.isCancellationRequested, isTrue);
      expect(
        harness.coordinator.currentFacts.detectedFailureReason,
        SyncFailureReason.remoteFailure,
      );

      harness.clock.advanceMonotonic(const Duration(milliseconds: 1));
      expect(invocation.control.isCancellationRequested, isTrue);
      harness.runner.complete(0);
      await harness.coordinator.whenIdle;
    },
  );

  test(
    'RUN-008 Linux focus and minimize facts never suspend cadence',
    () async {
      final lifecycle = FakeLifecycle();
      final harness = _Harness(
        startedAt: startedAt,
        lifecycle: lifecycle,
        autoComplete: true,
      );
      addTearDown(harness.close);
      addTearDown(lifecycle.close);

      await harness.coordinator.start();
      harness.runner.clearCompleted();
      lifecycle.setWindowFocused(false);
      expect(lifecycle.currentEligibility, LifecycleEligibility.foreground);

      harness.clock.advance(syncForegroundCadence);
      await harness.coordinator.whenIdle;

      expect(harness.runner.invocations, hasLength(1));
      expect(harness.runner.invocations.single.triggers, <SyncTrigger>{
        SyncTrigger.cadence,
      });
    },
  );

  test(
    'RUN-009 Stop blocks idle triggers and Resume requests catch-up',
    () async {
      final settings = _MemorySyncSettingsRepository();
      final harness = _Harness(
        startedAt: startedAt,
        settings: settings,
        autoComplete: true,
      );
      addTearDown(harness.close);

      await harness.coordinator.start();
      harness.runner.clearCompleted();
      await harness.coordinator.stop();

      expect(settings.syncEnabled, isFalse);
      await harness.coordinator.refresh();
      await harness.coordinator.localEditCommitted();
      harness.clock.advance(syncForegroundCadence);
      await _flushMicrotasks();
      expect(harness.runner.invocations, isEmpty);

      await harness.coordinator.resume();
      expect(settings.syncEnabled, isTrue);
      expect(harness.runner.invocations, hasLength(1));
      expect(harness.runner.invocations.single.triggers, <SyncTrigger>{
        SyncTrigger.resumeSync,
      });
    },
  );

  test(
    'RUN-009 and REL-006 Stop cancels an active run at its safe boundary',
    () async {
      final settings = _MemorySyncSettingsRepository();
      final harness = _Harness(startedAt: startedAt, settings: settings);
      addTearDown(harness.close);

      unawaited(harness.coordinator.start());
      await harness.runner.waitForRuns(1);
      final active = harness.runner.invocations.single;

      final stop = harness.coordinator.stop();
      await _flushMicrotasks();
      expect(settings.syncEnabled, isFalse);
      expect(active.control.isCancellationRequested, isTrue);
      harness.runner.interrupt(0);
      await stop;

      expect(harness.clock.pendingTimerCount, 0);
      expect(harness.runner.maximumActiveRuns, 1);
    },
  );

  test(
    'Stop persistence failure preserves enabled state and fails closed',
    () async {
      final settings = _MemorySyncSettingsRepository(failWrites: true);
      final harness = _Harness(
        startedAt: startedAt,
        settings: settings,
        autoComplete: true,
      );
      addTearDown(harness.close);
      await harness.coordinator.start();
      harness.runner.clearCompleted();

      await expectLater(harness.coordinator.stop(), throwsStateError);

      expect(settings.syncEnabled, isTrue);
      expect(
        harness.coordinator.currentFacts.detectedFailureReason,
        SyncFailureReason.applicationFailure,
      );
      await harness.coordinator.refresh();
      expect(harness.runner.invocations, isEmpty);
    },
  );

  test(
    'REL-006 exit is best effort and missing exit callback is harmless',
    () async {
      final lifecycle = FakeLifecycle();
      final harness = _Harness(startedAt: startedAt, lifecycle: lifecycle);
      addTearDown(harness.close);
      addTearDown(lifecycle.close);

      unawaited(harness.coordinator.start());
      await harness.runner.waitForRuns(1);
      lifecycle.requestProcessExit();
      expect(
        harness.runner.invocations.single.control.isCancellationRequested,
        isTrue,
      );
      harness.runner.interrupt(0);
      lifecycle.acknowledgeCancellation();
      await harness.coordinator.whenIdle;

      final abrupt = FakeLifecycle();
      abrupt.terminateWithoutExitFact();
      expect(abrupt.exitRequested, isFalse);
    },
  );
}

SyncHealth _health(SyncCoordinator coordinator, DateTime now) =>
    projectSyncHealth(
      facts: PersistedSyncFacts(
        lastSuccessfulSyncAt: now.subtract(const Duration(minutes: 1)),
      ),
      runtime: coordinator.currentFacts,
      now: now,
    );

Future<void> _flushMicrotasks() async {
  await Future<void>.value();
  await Future<void>.value();
}

final class _Harness {
  _Harness({
    required DateTime startedAt,
    AuthorizationPort? authorization,
    FakeLifecycle? lifecycle,
    FakeConnectivity? connectivity,
    SyncSettingsRepository? settings,
    bool autoComplete = false,
  }) : clock = FakeClock(startedAt),
       runner = _ControlledRunner(autoComplete: autoComplete) {
    coordinator = SyncCoordinator(
      accountId: const AccountId(1),
      authorization: authorization ?? const SyntheticAuthorization(_subject),
      clock: clock,
      scheduler: clock,
      lifecycle: lifecycle,
      connectivity: connectivity,
      settings: settings ?? _MemorySyncSettingsRepository(),
      run: runner.call,
    );
  }

  final FakeClock clock;
  final _ControlledRunner runner;
  late final SyncCoordinator coordinator;

  Future<void> close() => coordinator.close();
}

final class _ControlledRunner {
  _ControlledRunner({required this.autoComplete});

  final bool autoComplete;
  final List<SyncCoordinatorRun> invocations = <SyncCoordinatorRun>[];
  final List<Completer<SyncRunReport>> _reports = <Completer<SyncRunReport>>[];
  final List<Completer<void>> _runWaiters = <Completer<void>>[];
  var activeRuns = 0;
  var maximumActiveRuns = 0;

  Future<SyncRunReport> call(SyncCoordinatorRun invocation) async {
    invocations.add(invocation);
    activeRuns += 1;
    if (activeRuns > maximumActiveRuns) maximumActiveRuns = activeRuns;
    for (final waiter in _runWaiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _runWaiters.clear();
    final report = Completer<SyncRunReport>();
    _reports.add(report);
    if (autoComplete) complete(_reports.length - 1);
    final value = await report.future;
    activeRuns -= 1;
    return value;
  }

  Future<void> waitForRuns(int count) async {
    while (invocations.length < count) {
      final waiter = Completer<void>();
      _runWaiters.add(waiter);
      await waiter.future;
    }
  }

  void complete(int index) {
    final report = _reports[index];
    if (report.isCompleted) return;
    report.complete(_successReport(index));
  }

  void interrupt(int index) {
    final report = _reports[index];
    if (report.isCompleted) return;
    report.complete(
      SyncRunReport(
        outcome: SyncRunOutcome.interrupted,
        runId: SyncRunId('synthetic-run-$index'),
        complete: false,
        taskListPages: 0,
        taskPages: 0,
        remoteTaskLists: 0,
        remoteTasks: 0,
        resourceProjectionWrites: 0,
      ),
    );
  }

  void clearCompleted() {
    if (activeRuns != 0) throw StateError('Cannot clear an active run.');
    invocations.clear();
    _reports.clear();
  }
}

final class _MemorySyncSettingsRepository implements SyncSettingsRepository {
  _MemorySyncSettingsRepository({this.failWrites = false});

  final bool failWrites;
  bool syncEnabled = true;

  @override
  Future<bool> readSyncEnabled(AccountId accountId) async => syncEnabled;

  @override
  Future<void> setSyncEnabled(AccountId accountId, bool enabled) async {
    if (failWrites) throw StateError('Synthetic settings write failed.');
    syncEnabled = enabled;
  }
}

SyncRunReport _successReport(int index) => SyncRunReport(
  outcome: SyncRunOutcome.succeeded,
  runId: SyncRunId('synthetic-run-$index'),
  complete: true,
  taskListPages: 1,
  taskPages: 0,
  remoteTaskLists: 0,
  remoteTasks: 0,
  resourceProjectionWrites: 0,
);

final class _DelayedAuthorization implements AuthorizationPort {
  _DelayedAuthorization(this.subject);

  final AccountSubject subject;
  final StreamController<AuthorizationState> _states =
      StreamController<AuthorizationState>.broadcast(sync: true);
  final Completer<Outcome<AccountSubject>> _restore = Completer();
  AuthorizationState _state = const NoTasksAuthorization();

  @override
  AuthorizationState get currentState => _state;

  @override
  Stream<AuthorizationState> get states => _states.stream;

  void completeRestore() {
    _state = TasksAuthorized(subject);
    _states.add(_state);
    _restore.complete(Outcome<AccountSubject>.success(subject));
  }

  @override
  Future<Outcome<AccountSubject>> restoreTasksAuthorization() {
    _state = AuthorizationRefreshPending(subject);
    _states.add(_state);
    return _restore.future;
  }

  @override
  Future<Outcome<AccountSubject>> refreshTasksAuthorization() async =>
      Outcome<AccountSubject>.success(subject);

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() async =>
      Outcome<AccountSubject>.success(subject);
}

final class _CountingRestoreAuthorization implements AuthorizationPort {
  _CountingRestoreAuthorization(this.subject);

  final AccountSubject subject;
  var restoreCalls = 0;
  AuthorizationState _state = const AuthorizationRequestFailed(
    Failure(
      code: 'auth.synthetic_unknown',
      category: FailureCategory.network,
      operation: FailureOperation.authorize,
      retry: RetryClassification.transient,
      impact: 'Synthetic authorization has not been restored.',
      action: FailureAction.retry,
      safeSummary: 'Synthetic authorization is unresolved.',
    ),
  );

  @override
  AuthorizationState get currentState => _state;

  @override
  Stream<AuthorizationState> get states =>
      const Stream<AuthorizationState>.empty();

  @override
  Future<Outcome<AccountSubject>> restoreTasksAuthorization() async {
    restoreCalls += 1;
    _state = TasksAuthorized(subject);
    return Outcome<AccountSubject>.success(subject);
  }

  @override
  Future<Outcome<AccountSubject>> refreshTasksAuthorization() async =>
      Outcome<AccountSubject>.success(subject);

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() async =>
      Outcome<AccountSubject>.success(subject);
}
