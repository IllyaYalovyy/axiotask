import 'dart:async';

import '../../core/clock.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../core/failure.dart';
import '../../core/lifecycle.dart';
import '../../core/outcome.dart';
import '../../core/randomness.dart';
import '../../data/auth/authorization.dart';
import '../../data/connectivity/connectivity.dart';
import '../../domain/model/tasks.dart';
import '../../domain/recovery/local_data_recovery.dart';
import '../../domain/repository/sync_settings_repository.dart';
import '../health/sync_health.dart';
import '../health/sync_health_repository.dart';
import '../retry/retry_episode.dart';
import '../retry/retry_policy.dart';
import '../run.dart';

const Duration syncLocalEditDebounce = Duration(seconds: 5);
const Duration syncLocalEditDebounceCap = Duration(seconds: 10);
const Duration syncForegroundCadence = Duration(minutes: 5);
const Duration syncRunDeadline = Duration(minutes: 2);

enum SyncTrigger {
  startup,
  foregroundResume,
  connectivityRestored,
  refresh,
  resumeSync,
  localEdit,
  deleteEligible,
  reauthorization,
  retry,
  cadence,
  localDataReset,
}

extension SyncTriggerValue on SyncTrigger {
  String get value => switch (this) {
    SyncTrigger.startup => 'startup',
    SyncTrigger.foregroundResume => 'resume',
    SyncTrigger.connectivityRestored => 'connectivity_restored',
    SyncTrigger.refresh => 'refresh',
    SyncTrigger.resumeSync => 'resume_sync',
    SyncTrigger.localEdit => 'local_edit',
    SyncTrigger.deleteEligible => 'delete_eligible',
    SyncTrigger.reauthorization => 'reauthorization',
    SyncTrigger.retry => 'retry',
    SyncTrigger.cadence => 'cadence',
    SyncTrigger.localDataReset => 'local_data_reset',
  };
}

final class SyncCoordinatorRunControl
    implements
        SyncRunControl,
        SyncRunInterruptionFailure,
        SyncRunCancellationSignal {
  var _cancellationRequested = false;
  final Completer<void> _cancellation = Completer<void>();
  Failure? _interruptionFailure;

  @override
  bool get isCancellationRequested => _cancellationRequested;

  @override
  Future<void> get whenCancellationRequested => _cancellation.future;

  @override
  Failure? get interruptionFailure => _interruptionFailure;

  bool requestCancellation({Failure? failure}) {
    if (_cancellationRequested) return false;
    _cancellationRequested = true;
    _interruptionFailure = failure;
    _cancellation.complete();
    return true;
  }

  @override
  Future<SyncRunControlDecision> reach(SyncRunBoundary boundary) async =>
      _cancellationRequested
      ? SyncRunControlDecision.interrupt
      : SyncRunControlDecision.proceed;
}

final class SyncCoordinatorRun {
  SyncCoordinatorRun({
    required Set<SyncTrigger> triggers,
    required this.deadline,
    required this.control,
    required this.retryObserver,
  }) : triggers = Set<SyncTrigger>.unmodifiable(triggers);

  final Set<SyncTrigger> triggers;
  final Duration deadline;
  final SyncCoordinatorRunControl control;
  final SyncRequestRetryObserver retryObserver;
}

typedef CoordinatedSyncRun =
    Future<SyncRunReport> Function(SyncCoordinatorRun request);

abstract interface class TaskDeleteEligibilityStore {
  Future<int> cleanupExpiredTaskDeletes({
    required AccountId accountId,
    required DateTime now,
  });

  Future<DateTime?> nextTaskDeleteExpiry(AccountId accountId);
}

/// Serializes foreground synchronization requests for one configured account.
///
/// Trigger notifications are transient facts. Durable local work remains owned
/// by repositories and is reread by the engine; this coordinator only merges
/// requests, schedules exact monotonic boundaries, and projects runtime facts.
final class SyncCoordinator
    implements SyncRuntimeFactsSource, LocalDataResetSynchronization {
  SyncCoordinator({
    required this.accountId,
    required this.authorization,
    required this.clock,
    required this.scheduler,
    required RandomSource random,
    required this.settings,
    required this.retryStore,
    required this.reauthorizationStore,
    required this.run,
    this.diagnostics,
    this.taskDeleteEligibility,
    LifecyclePort? lifecycle,
    ConnectivityPort? connectivity,
  }) : _connectivity = connectivity,
       _retryPolicy = SyncRetryPolicy(random),
       _currentFacts = SyncRuntimeFacts(
         authorization: _authorizationFact(authorization.currentState),
         connectivity: _connectivityFact(
           connectivity?.currentHint ?? ConnectivityHint.unknown,
         ),
         activity: SyncActivity.checkingAuthorization,
         verificationRequired: true,
       ) {
    _authorizationSubscription = authorization.states.listen(
      _acceptAuthorizationState,
    );
    _lifecycleSubscription = lifecycle?.facts.listen(_acceptLifecycleFact);
    _connectivitySubscription = connectivity?.hints.listen(
      _acceptConnectivityHint,
    );
  }

  final AccountId accountId;
  final AuthorizationPort authorization;
  final Clock clock;
  final MonotonicScheduler scheduler;
  final SyncSettingsRepository settings;
  final SyncRetryEpisodeStore retryStore;
  final SyncReauthorizationStore reauthorizationStore;
  final CoordinatedSyncRun run;
  final DiagnosticSink? diagnostics;
  final TaskDeleteEligibilityStore? taskDeleteEligibility;
  final ConnectivityPort? _connectivity;
  final SyncRetryPolicy _retryPolicy;
  final StreamController<SyncRuntimeFacts> _facts =
      StreamController<SyncRuntimeFacts>.broadcast(sync: true);
  final Set<SyncTrigger> _pendingTriggers = <SyncTrigger>{};
  final Set<SyncTrigger> _followUpTriggers = <SyncTrigger>{};
  late final StreamSubscription<AuthorizationState> _authorizationSubscription;
  StreamSubscription<LifecycleFact>? _lifecycleSubscription;
  StreamSubscription<ConnectivityHint>? _connectivitySubscription;
  SyncRuntimeFacts _currentFacts;
  Future<void>? _drain;
  Future<void>? _lifecycleOperation;
  ScheduledTimer? _localEditTimer;
  ScheduledTimer? _cadenceTimer;
  ScheduledTimer? _deleteEligibilityTimer;
  ScheduledTimer? _retryTimer;
  ScheduledTimer? _retryExhaustionTimer;
  Duration? _localEditBurstStartedAt;
  SyncCoordinatorRunControl? _activeControl;
  var _activeGeneration = 0;
  var _activeTimedOut = false;
  bool? _syncEnabled;
  bool _stopRequested = false;
  bool _shutdownRequested = false;
  bool _localDataResetRequested = false;
  Future<void>? _settingsOperation;
  Future<void>? _manualRetryOperation;
  Future<void>? _reauthorizationOperation;
  Future<void>? _localDataResetOperation;
  RetryEpisode? _retryEpisode;
  bool _reauthorizationRequired = false;
  bool _started = false;
  bool _closed = false;

  @override
  SyncRuntimeFacts get currentFacts => _currentFacts;

  @override
  Stream<SyncRuntimeFacts> get facts => _facts.stream;

  /// Completes when immediate and active work is drained. Future cadence and
  /// debounce timers deliberately do not keep this future pending.
  Future<void> get whenIdle => _waitForIdle();

  Future<void> _waitForIdle() async {
    while (true) {
      final lifecycleOperation = _lifecycleOperation;
      if (lifecycleOperation != null) await lifecycleOperation;
      final drain = _drain;
      if (drain != null) await drain;
      if (_lifecycleOperation == null && _drain == null) return;
    }
  }

  Future<void> start() async {
    if (_started) return whenIdle;
    _started = true;
    try {
      final eligibility = await Future.wait<Object>(<Future<Object>>[
        settings.readSyncEnabled(accountId),
        reauthorizationStore.readReauthorizationRequired(accountId),
      ]);
      _syncEnabled = eligibility[0] as bool;
      _reauthorizationRequired = eligibility[1] as bool;
    } on Object {
      _emit(
        _with(
          activity: SyncActivity.idle,
          verificationRequired: false,
          detectedFailureReason: SyncFailureReason.applicationFailure,
          diagnosticCode: 'sync.settings_read_failed',
        ),
      );
      rethrow;
    }
    await _refreshTaskDeleteEligibility();
    _retryEpisode = await retryStore.readRetryEpisode(accountId);
    if (_syncEnabled != true) {
      _emit(_with(activity: SyncActivity.idle, verificationRequired: false));
      return;
    }
    if (_reauthorizationRequired) {
      _emit(_inactiveAuthorization());
      return;
    }
    if (_retryEpisode != null) {
      await _restoreRetryEpisode();
      return;
    }
    await _requestImmediate(SyncTrigger.startup);
  }

  Future<void> refresh() async {
    await _refreshTaskDeleteEligibility();
    await _requestImmediate(SyncTrigger.refresh);
  }

  @override
  Future<void> serializeResetAndRebuild(Future<void> Function() reset) {
    _requireOpen();
    final existing = _localDataResetOperation;
    if (existing != null) return existing;
    final operation = _serializeResetAndRebuild(reset);
    _localDataResetOperation = operation;
    void clearOperation() {
      if (identical(_localDataResetOperation, operation)) {
        _localDataResetOperation = null;
      }
    }

    unawaited(
      operation.then<void>(
        (_) => clearOperation(),
        onError: (Object _, StackTrace _) {
          clearOperation();
        },
      ),
    );
    return operation;
  }

  Future<void> _serializeResetAndRebuild(Future<void> Function() reset) async {
    _localDataResetRequested = true;
    _activeGeneration += 1;
    _pendingTriggers.clear();
    _followUpTriggers.clear();
    _cancelScheduledWork();
    _activeControl?.requestCancellation(
      failure: const Failure(
        code: 'sync.local_data_reset_requested',
        category: FailureCategory.persistence,
        operation: FailureOperation.synchronize,
        retry: RetryClassification.permanent,
        impact: 'The active synchronization run was stopped for local reset.',
        safeSummary: 'Synchronization stopped before local data reset.',
      ),
    );
    try {
      await _settleConcurrentControlOperations();
      final activeDrain = _drain;
      if (activeDrain != null) await activeDrain;
      await reset();
      _syncEnabled = true;
      _stopRequested = false;
      _shutdownRequested = false;
      _reauthorizationRequired = false;
      _retryEpisode = null;
      _emit(
        _with(
          authorization: _authorizationFact(authorization.currentState),
          activity: SyncActivity.verifying,
          verificationRequired: true,
          clearFailure: true,
        ),
      );
    } on Object {
      _emit(
        _with(
          activity: SyncActivity.idle,
          verificationRequired: false,
          detectedFailureReason: SyncFailureReason.applicationFailure,
          diagnosticCode: 'sync.local_data_reset_failed',
          failureAction: SyncHealthAction.retry,
        ),
      );
      rethrow;
    } finally {
      _localDataResetRequested = false;
    }
    await _requestImmediate(SyncTrigger.localDataReset);
  }

  Future<void> _settleConcurrentControlOperations() async {
    final operations = <Future<void>>[
      ?_lifecycleOperation,
      ?_settingsOperation,
      ?_manualRetryOperation,
      ?_reauthorizationOperation,
    ];
    for (final operation in operations) {
      try {
        await operation;
      } on Object {
        // Its durable/safe failure state remains until the reset commits.
      }
    }
  }

  void _cancelScheduledWork() {
    _localEditTimer?.cancel();
    _localEditTimer = null;
    _localEditBurstStartedAt = null;
    _cadenceTimer?.cancel();
    _cadenceTimer = null;
    _deleteEligibilityTimer?.cancel();
    _deleteEligibilityTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryExhaustionTimer?.cancel();
    _retryExhaustionTimer = null;
  }

  Future<void> retry() {
    _requireOpen();
    final existing = _manualRetryOperation;
    if (existing != null) return existing;
    final operation = _retryExplicitly();
    _manualRetryOperation = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_manualRetryOperation, operation)) {
          _manualRetryOperation = null;
        }
      }),
    );
    return operation;
  }

  Future<void> reauthorize() {
    _requireOpen();
    final existing = _reauthorizationOperation;
    if (existing != null) return existing;
    final operation = _reauthorize();
    _reauthorizationOperation = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_reauthorizationOperation, operation)) {
          _reauthorizationOperation = null;
        }
      }),
    );
    return operation;
  }

  Future<void> _reauthorize() async {
    _reauthorizationRequired = await reauthorizationStore
        .readReauthorizationRequired(accountId);
    if (!_reauthorizationRequired) return;
    _emit(
      _with(
        authorization: SyncAuthorization.refreshing,
        activity: SyncActivity.checkingAuthorization,
        verificationRequired: true,
      ),
    );
    final outcome = await authorization.requestTasksAuthorization();
    switch (outcome) {
      case Success<AccountSubject>(:final value):
        final expected = await reauthorizationStore.readAuthorizationSubject(
          accountId,
        );
        if (expected == null || value.value != expected) {
          await reauthorizationStore.requireReauthorization(accountId);
          _reauthorizationRequired = true;
          _emit(_inactiveAuthorization());
          return;
        }
        await reauthorizationStore.completeReauthorization(accountId);
        _reauthorizationRequired = false;
        await _clearRetryEpisode();
        if (_syncEnabled == true && !_stopRequested && !_shutdownRequested) {
          await _requestImmediate(SyncTrigger.reauthorization);
        } else {
          _emit(
            _with(
              authorization: SyncAuthorization.usable,
              activity: SyncActivity.idle,
              verificationRequired: false,
              clearFailure: true,
            ),
          );
        }
      case Failed<AccountSubject>():
        _reauthorizationRequired = true;
        _emit(_inactiveAuthorization());
    }
  }

  Future<void> stop() => _changeSyncEnabled(false);

  Future<void> resume() => _changeSyncEnabled(true);

  Future<void> localEditCommitted() {
    _requireOpen();
    if (_syncEnabled != true || _stopRequested || _shutdownRequested) {
      return whenIdle;
    }
    if (_activeControl != null) {
      _followUpTriggers.add(SyncTrigger.localEdit);
      _emit(
        _with(activity: SyncActivity.verifying, verificationRequired: true),
      );
      return whenIdle;
    }

    final now = clock.monotonicElapsed;
    _localEditBurstStartedAt ??= now;
    final trailingDeadline = now + syncLocalEditDebounce;
    final cappedDeadline = _localEditBurstStartedAt! + syncLocalEditDebounceCap;
    final deadline = trailingDeadline < cappedDeadline
        ? trailingDeadline
        : cappedDeadline;
    _localEditTimer?.cancel();
    _localEditTimer = scheduler.schedule(deadline - now, () {
      _localEditTimer = null;
      _localEditBurstStartedAt = null;
      unawaited(_requestImmediate(SyncTrigger.localEdit));
    });
    _emit(
      _with(activity: SyncActivity.debouncing, verificationRequired: false),
    );
    return whenIdle;
  }

  Future<void> taskDeleteCommitted(DateTime notBefore) async {
    _requireOpen();
    if (taskDeleteEligibility != null) {
      await _refreshTaskDeleteEligibility();
    } else {
      _scheduleTaskDeleteEligibility(notBefore.toUtc());
    }
  }

  Future<void> _refreshTaskDeleteEligibility() async {
    final store = taskDeleteEligibility;
    if (store == null || _closed) return;
    await store.cleanupExpiredTaskDeletes(
      accountId: accountId,
      now: clock.now().toUtc(),
    );
    _scheduleTaskDeleteEligibility(await store.nextTaskDeleteExpiry(accountId));
  }

  void _scheduleTaskDeleteEligibility(DateTime? notBefore) {
    _deleteEligibilityTimer?.cancel();
    _deleteEligibilityTimer = null;
    if (notBefore == null || _shutdownRequested || _closed) {
      return;
    }
    final delay = notBefore.toUtc().difference(clock.now().toUtc());
    _deleteEligibilityTimer = scheduler.schedule(
      delay.isNegative ? Duration.zero : delay,
      () {
        _deleteEligibilityTimer = null;
        unawaited(_onTaskDeleteEligible());
      },
    );
  }

  Future<void> _onTaskDeleteEligible() async {
    await _refreshTaskDeleteEligibility();
    await _requestImmediate(SyncTrigger.deleteEligible);
  }

  Future<void> _requestImmediate(SyncTrigger trigger) {
    _requireOpen();
    if (_syncEnabled != true ||
        _reauthorizationRequired ||
        _stopRequested ||
        _shutdownRequested ||
        _localDataResetRequested) {
      return whenIdle;
    }
    if (_activeControl != null) {
      _followUpTriggers.add(trigger);
      _emit(
        _with(activity: SyncActivity.verifying, verificationRequired: true),
      );
      return _drain ?? Future<void>.value();
    }

    if (_localEditTimer?.isActive ?? false) {
      _localEditTimer?.cancel();
      _localEditTimer = null;
      _localEditBurstStartedAt = null;
      _pendingTriggers.add(SyncTrigger.localEdit);
    }
    _pendingTriggers.add(trigger);
    final isRetry = trigger == SyncTrigger.retry;
    _emit(
      _with(
        authorization: _authorizationFact(authorization.currentState),
        activity: _checkingAuthorization(authorization.currentState)
            ? SyncActivity.checkingAuthorization
            : isRetry
            ? SyncActivity.retrying
            : SyncActivity.verifying,
        verificationRequired: true,
        clearFailure: isRetry || trigger == SyncTrigger.resumeSync,
      ),
    );
    return _ensureDrain();
  }

  Future<void> _ensureDrain() {
    final existing = _drain;
    if (existing != null) return existing;
    final completer = Completer<void>();
    _drain = completer.future;
    unawaited(_drainRuns(completer));
    return completer.future;
  }

  Future<void> _drainRuns(Completer<void> completer) async {
    try {
      while (_pendingTriggers.isNotEmpty && !_closed) {
        if (_syncEnabled != true ||
            _stopRequested ||
            _shutdownRequested ||
            _localDataResetRequested) {
          _pendingTriggers.clear();
          break;
        }
        if (_connectivity?.currentHint == ConnectivityHint.provenNoRoute) {
          break;
        }
        if (!await _ensureAuthorization()) {
          _pendingTriggers.clear();
          break;
        }

        final triggers = Set<SyncTrigger>.unmodifiable(_pendingTriggers);
        _pendingTriggers.clear();
        final generation = ++_activeGeneration;
        final control = SyncCoordinatorRunControl();
        _activeControl = control;
        _activeTimedOut = false;
        final deadline = clock.monotonicElapsed + syncRunDeadline;
        _emit(
          _with(
            authorization: SyncAuthorization.usable,
            activity: triggers.contains(SyncTrigger.retry)
                ? SyncActivity.retrying
                : SyncActivity.verifying,
            verificationRequired: true,
            clearFailure: triggers.contains(SyncTrigger.retry),
          ),
        );
        final deadlineTimer = scheduler.schedule(syncRunDeadline, () {
          if (_closed ||
              _activeGeneration != generation ||
              _activeControl != control) {
            return;
          }
          _activeTimedOut = true;
          control.requestCancellation(failure: _runTimeoutFailure);
          _emit(
            _with(
              detectedFailureReason: SyncFailureReason.remoteFailure,
              diagnosticCode: 'sync.run_timeout',
              failureAction: SyncHealthAction.retry,
            ),
          );
        });

        final SyncRunReport report;
        try {
          report = await run(
            SyncCoordinatorRun(
              triggers: triggers,
              deadline: deadline,
              control: control,
              retryObserver: _CoordinatorRequestRetryObserver(this),
            ),
          );
        } finally {
          deadlineTimer.cancel();
        }
        final stale = _closed || _activeGeneration != generation;
        final timedOut = _activeTimedOut;
        _activeControl = null;
        _activeTimedOut = false;

        var retryScheduled = false;
        if (!stale) {
          retryScheduled = timedOut
              ? await _acceptFailure(_runTimeoutFailure)
              : await _acceptReport(
                  report,
                  keepPending: _followUpTriggers.isNotEmpty,
                );
        }
        if (retryScheduled) {
          _followUpTriggers.clear();
          _pendingTriggers.clear();
          continue;
        }
        if (_followUpTriggers.isNotEmpty) {
          _pendingTriggers.addAll(_followUpTriggers);
          _followUpTriggers.clear();
          continue;
        }
        _scheduleCadence();
      }
      if (!completer.isCompleted) completer.complete();
    } catch (error, stackTrace) {
      _activeControl = null;
      _emit(
        _with(
          activity: SyncActivity.idle,
          verificationRequired: false,
          detectedFailureReason: SyncFailureReason.applicationFailure,
          diagnosticCode: 'sync.coordinator_run_failed',
          failureAction: SyncHealthAction.retry,
        ),
      );
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    } finally {
      _drain = null;
    }
  }

  void _scheduleCadence() {
    _cadenceTimer?.cancel();
    if (_syncEnabled != true ||
        _reauthorizationRequired ||
        _stopRequested ||
        _shutdownRequested ||
        (_retryEpisode?.automaticRetryExhausted ?? false) ||
        (_retryEpisode?.retryWaiting ?? false)) {
      _cadenceTimer = null;
      return;
    }
    _cadenceTimer = scheduler.schedule(syncForegroundCadence, () {
      _cadenceTimer = null;
      unawaited(_requestImmediate(SyncTrigger.cadence));
    });
  }

  Future<bool> _ensureAuthorization() async {
    final state = authorization.currentState;
    if (state is TasksAuthorized || state is AuthorizationExpired) return true;
    if (state is AuthorizationRejected) {
      await reauthorizationStore.requireReauthorization(accountId);
      _reauthorizationRequired = true;
      _emit(_inactiveAuthorization());
      return false;
    }
    _emit(
      _with(
        authorization: SyncAuthorization.refreshing,
        activity: SyncActivity.checkingAuthorization,
        verificationRequired: true,
      ),
    );
    final outcome = await authorization.restoreTasksAuthorization();
    return switch (outcome) {
      Success<AccountSubject>() => true,
      Failed<AccountSubject>(:final failure) =>
        await _acceptAuthorizationFailure(failure),
    };
  }

  Future<bool> _acceptAuthorizationFailure(Failure failure) async {
    if (authorization.currentState is AuthorizationRejected) {
      await reauthorizationStore.requireReauthorization(accountId);
      _reauthorizationRequired = true;
    }
    if (failure.category == FailureCategory.authorization ||
        failure.category == FailureCategory.configuration ||
        authorization.currentState is NoTasksAuthorization ||
        authorization.currentState is AuthorizationRejected) {
      _emit(_inactiveAuthorization());
      return false;
    }
    _emit(
      _with(
        authorization: SyncAuthorization.unknown,
        activity: SyncActivity.idle,
        verificationRequired: false,
        detectedFailureReason: _failureReason(failure),
        diagnosticCode: failure.code,
        failureAction: failure.action == FailureAction.retry
            ? SyncHealthAction.retry
            : SyncHealthAction.none,
      ),
    );
    return false;
  }

  Future<bool> _acceptReport(
    SyncRunReport report, {
    required bool keepPending,
  }) async {
    _reauthorizationRequired = await reauthorizationStore
        .readReauthorizationRequired(accountId);
    if (_reauthorizationRequired) {
      await _clearRetryEpisode();
      _emit(_inactiveAuthorization());
      return false;
    }
    switch (report.outcome) {
      case SyncRunOutcome.succeeded:
        await _clearRetryEpisode();
        _emit(
          _with(
            authorization: SyncAuthorization.usable,
            activity: keepPending ? SyncActivity.verifying : SyncActivity.idle,
            verificationRequired: keepPending,
            clearFailure: true,
          ),
        );
        return false;
      case SyncRunOutcome.failed:
        final failure = report.failure;
        if (failure == null) {
          _emit(
            _with(
              activity: SyncActivity.idle,
              verificationRequired: false,
              detectedFailureReason: SyncFailureReason.applicationFailure,
              diagnosticCode: 'sync.failed_without_reason',
            ),
          );
          return false;
        }
        return _acceptFailure(failure);
      case SyncRunOutcome.ineligible:
        switch (report.ineligibleReason) {
          case SyncRunIneligibleReason.noAuthorization:
            _emit(_inactiveAuthorization());
          case SyncRunIneligibleReason.syncStopped:
            _emit(
              _with(
                activity: SyncActivity.idle,
                verificationRequired: false,
                clearFailure: true,
              ),
            );
          case SyncRunIneligibleReason.accountMissing ||
              SyncRunIneligibleReason.accountMismatch ||
              SyncRunIneligibleReason.automaticRetryExhausted ||
              null:
            _emit(
              _with(
                activity: SyncActivity.idle,
                verificationRequired: false,
                detectedFailureReason: SyncFailureReason.applicationFailure,
                diagnosticCode: 'sync.configured_account_unavailable',
              ),
            );
        }
        return false;
      case SyncRunOutcome.interrupted:
        _emit(
          _with(
            activity: SyncActivity.idle,
            verificationRequired: false,
            detectedFailureReason: SyncFailureReason.applicationFailure,
            diagnosticCode: 'sync.run_interrupted',
            failureAction: SyncHealthAction.retry,
          ),
        );
        return false;
    }
  }

  Future<bool> _acceptFailure(Failure failure) async {
    _emit(
      _with(
        activity: SyncActivity.idle,
        verificationRequired: false,
        detectedFailureReason: _failureReason(failure),
        diagnosticCode: failure.code,
        failureAction: _retryPolicy.isAutomaticallyRetryable(failure)
            ? SyncHealthAction.retry
            : SyncHealthAction.none,
      ),
    );
    if (!_retryPolicy.isAutomaticallyRetryable(failure)) {
      await _clearRetryEpisode();
      return false;
    }
    final now = clock.now().toUtc();
    var episode = _retryEpisode;
    if (episode == null || episode.automaticRetryExhausted) {
      episode = RetryEpisode(
        startedAt: now,
        deadlineAt: now.add(syncRetryEpisodeBudget),
        lastObservedAt: now,
        attemptCount: 0,
      );
    }
    if (!now.isBefore(episode.deadlineAt) ||
        now.isBefore(episode.lastObservedAt)) {
      await _latchRetryExhaustion(episode);
      return true;
    }
    final serverBoundary = _later(
      episode.serverNotBeforeAt,
      _retryPolicy.serverNotBefore(failure, now),
    );
    final delay = _retryPolicy.betweenRunDelay(
      episode.attemptCount,
      failure,
      now,
    );
    final nextAttempt = _later(now.add(delay), serverBoundary)!;
    episode = episode.copyWith(
      lastObservedAt: now,
      nextAttemptAt: nextAttempt,
      serverNotBeforeAt: serverBoundary,
      automaticRetryExhausted: false,
    );
    _retryEpisode = episode;
    await retryStore.writeRetryEpisode(accountId, episode);
    _scheduleRetryEpisode();
    return true;
  }

  Future<void> _restoreRetryEpisode() async {
    final episode = _retryEpisode!;
    final now = clock.now().toUtc();
    if (episode.automaticRetryExhausted ||
        !now.isBefore(episode.deadlineAt) ||
        now.isBefore(episode.lastObservedAt)) {
      await _latchRetryExhaustion(episode);
      return;
    }
    _emit(_with(activity: SyncActivity.idle, verificationRequired: false));
    if (episode.nextAttemptAt == null ||
        !now.isBefore(episode.nextAttemptAt!)) {
      await _beginRetryRun();
      return;
    }
    _scheduleRetryEpisode();
  }

  void _scheduleRetryEpisode() {
    _retryTimer?.cancel();
    _retryExhaustionTimer?.cancel();
    _retryTimer = null;
    _retryExhaustionTimer = null;
    final episode = _retryEpisode;
    if (episode == null || episode.automaticRetryExhausted || _closed) return;
    final now = clock.now().toUtc();
    final exhaustionDelay = episode.deadlineAt.difference(now);
    _retryExhaustionTimer = scheduler.schedule(
      exhaustionDelay.isNegative ? Duration.zero : exhaustionDelay,
      () => unawaited(_latchRetryExhaustion(episode)),
    );
    final next = episode.nextAttemptAt;
    if (next == null || !next.isBefore(episode.deadlineAt)) return;
    final delay = next.difference(now);
    _retryTimer = scheduler.schedule(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_beginRetryRun()),
    );
  }

  Future<void> _beginRetryRun() async {
    if (_closed ||
        _syncEnabled != true ||
        _stopRequested ||
        _shutdownRequested) {
      return;
    }
    final episode = _retryEpisode;
    if (episode == null || episode.automaticRetryExhausted) return;
    final now = clock.now().toUtc();
    if (!now.isBefore(episode.deadlineAt) ||
        now.isBefore(episode.lastObservedAt)) {
      await _latchRetryExhaustion(episode);
      return;
    }
    final serverBoundary = episode.serverNotBeforeAt;
    if (serverBoundary != null && now.isBefore(serverBoundary)) {
      _retryEpisode = episode.copyWith(nextAttemptAt: serverBoundary);
      await retryStore.writeRetryEpisode(accountId, _retryEpisode!);
      _scheduleRetryEpisode();
      return;
    }
    if (_connectivity?.currentHint == ConnectivityHint.provenNoRoute) {
      final parked = episode.copyWith(
        lastObservedAt: now,
        clearNextAttempt: true,
      );
      _retryEpisode = parked;
      await retryStore.writeRetryEpisode(accountId, parked);
      _scheduleRetryEpisode();
      return;
    }
    _retryTimer?.cancel();
    final executing = episode.copyWith(
      lastObservedAt: now,
      clearNextAttempt: true,
      attemptCount: episode.attemptCount + 1,
    );
    _retryEpisode = executing;
    await retryStore.writeRetryEpisode(accountId, executing);
    await _requestImmediate(SyncTrigger.retry);
  }

  Future<void> _retryExplicitly() async {
    if (_syncEnabled != true || _stopRequested || _shutdownRequested) return;
    final now = clock.now().toUtc();
    final existing =
        _retryEpisode ?? await retryStore.readRetryEpisode(accountId);
    _retryTimer?.cancel();
    _retryExhaustionTimer?.cancel();
    final serverBoundary = existing?.serverNotBeforeAt;
    final episode = RetryEpisode(
      startedAt: now,
      deadlineAt: now.add(syncRetryEpisodeBudget),
      lastObservedAt: now,
      nextAttemptAt: serverBoundary != null && now.isBefore(serverBoundary)
          ? serverBoundary
          : null,
      serverNotBeforeAt: serverBoundary,
      attemptCount: 0,
    );
    _retryEpisode = episode;
    await retryStore.writeRetryEpisode(accountId, episode);
    if (episode.nextAttemptAt != null) {
      _emit(_with(activity: SyncActivity.idle, verificationRequired: false));
      _scheduleRetryEpisode();
      return;
    }
    await _beginRetryRun();
  }

  Future<void> _latchRetryExhaustion(RetryEpisode episode) async {
    if (_retryEpisode != episode && _retryEpisode != null) return;
    _retryTimer?.cancel();
    _retryExhaustionTimer?.cancel();
    final now = clock.now().toUtc();
    final exhausted = episode.copyWith(
      lastObservedAt: now,
      clearNextAttempt: true,
      automaticRetryExhausted: true,
    );
    _retryEpisode = exhausted;
    await retryStore.writeRetryEpisode(accountId, exhausted);
    _emit(
      _with(
        activity: SyncActivity.idle,
        verificationRequired: false,
        failureAction: SyncHealthAction.retry,
      ),
    );
  }

  Future<void> _clearRetryEpisode() async {
    _retryTimer?.cancel();
    _retryExhaustionTimer?.cancel();
    _retryTimer = null;
    _retryExhaustionTimer = null;
    if (_retryEpisode != null) await retryStore.clearRetryEpisode(accountId);
    _retryEpisode = null;
  }

  void _acceptAuthorizationState(AuthorizationState state) {
    if (_closed) return;
    switch (state) {
      case AuthorizationConnecting() || AuthorizationRefreshPending():
        _emit(
          _with(
            authorization: SyncAuthorization.refreshing,
            activity: SyncActivity.checkingAuthorization,
            verificationRequired: true,
          ),
        );
      case TasksAuthorized() || AuthorizationExpired():
        _emit(
          _with(
            authorization: SyncAuthorization.usable,
            verificationRequired: true,
          ),
        );
      case NoTasksAuthorization() || AuthorizationRejected():
        if (_started) _emit(_inactiveAuthorization());
      case AuthorizationRequestFailed(:final failure):
        unawaited(_acceptAuthorizationFailure(failure));
    }
  }

  void _acceptConnectivityHint(ConnectivityHint hint) {
    if (_closed) return;
    _emit(_with(connectivity: _connectivityFact(hint)));
    if (hint == ConnectivityHint.mayHaveReturned) {
      if (_retryEpisode != null &&
          !(_retryEpisode?.automaticRetryExhausted ?? true)) {
        unawaited(_beginRetryRun());
      } else {
        unawaited(_requestImmediate(SyncTrigger.connectivityRestored));
      }
    }
  }

  void _acceptLifecycleFact(LifecycleFact fact) {
    if (_closed) return;
    switch (fact) {
      case LifecycleForegrounded():
        final operation = _resumeForeground();
        _lifecycleOperation = operation;
        unawaited(
          operation.then<void>(
            (_) => _clearLifecycleOperation(operation),
            onError: (Object _, StackTrace _) {
              _clearLifecycleOperation(operation);
              _emit(
                _with(
                  activity: SyncActivity.idle,
                  verificationRequired: false,
                  detectedFailureReason: SyncFailureReason.applicationFailure,
                  diagnosticCode: 'sync.resume_cleanup_failed',
                ),
              );
            },
          ),
        );
      case ProcessExitRequested():
        _shutdownRequested = true;
        _activeGeneration += 1;
        _pendingTriggers.clear();
        _followUpTriggers.clear();
        _localEditTimer?.cancel();
        _localEditTimer = null;
        _localEditBurstStartedAt = null;
        _cadenceTimer?.cancel();
        _cadenceTimer = null;
        _deleteEligibilityTimer?.cancel();
        _deleteEligibilityTimer = null;
        _retryTimer?.cancel();
        _retryExhaustionTimer?.cancel();
        _activeControl?.requestCancellation();
      case LifecycleBackgrounded() || WindowFocusChanged():
        // Android background eligibility is deliberately owned by S27B.
        // Linux window visibility and focus never suspend synchronization.
        break;
    }
  }

  Future<void> _resumeForeground() async {
    await _refreshTaskDeleteEligibility();
    await _requestImmediate(SyncTrigger.foregroundResume);
  }

  void _clearLifecycleOperation(Future<void> operation) {
    if (identical(_lifecycleOperation, operation)) {
      _lifecycleOperation = null;
    }
  }

  Future<void> _changeSyncEnabled(bool enabled) {
    _requireOpen();
    final existing = _settingsOperation;
    if (existing != null) return existing;
    final operation = enabled
        ? _resumeSynchronization()
        : _stopSynchronization();
    _settingsOperation = operation;
    void clearOperation() {
      if (identical(_settingsOperation, operation)) {
        _settingsOperation = null;
      }
    }

    unawaited(
      operation.then<void>(
        (_) => clearOperation(),
        onError: (Object _, StackTrace _) => clearOperation(),
      ),
    );
    return operation;
  }

  Future<void> _stopSynchronization() async {
    _stopRequested = true;
    _activeGeneration += 1;
    _pendingTriggers.clear();
    _followUpTriggers.clear();
    _localEditTimer?.cancel();
    _localEditTimer = null;
    _localEditBurstStartedAt = null;
    _cadenceTimer?.cancel();
    _cadenceTimer = null;
    _retryTimer?.cancel();
    _retryExhaustionTimer?.cancel();
    _activeControl?.requestCancellation();
    try {
      await settings.setSyncEnabled(accountId, false);
      _syncEnabled = false;
      final activeDrain = _drain;
      if (activeDrain != null) await activeDrain;
      _emit(_with(activity: SyncActivity.idle, verificationRequired: false));
    } on Object {
      _stopRequested = false;
      _shutdownRequested = true;
      _emit(
        _with(
          activity: SyncActivity.idle,
          verificationRequired: false,
          detectedFailureReason: SyncFailureReason.applicationFailure,
          diagnosticCode: 'sync.settings_write_failed',
        ),
      );
      rethrow;
    }
  }

  Future<void> _resumeSynchronization() async {
    await settings.setSyncEnabled(accountId, true);
    _syncEnabled = true;
    _stopRequested = false;
    _shutdownRequested = false;
    await _refreshTaskDeleteEligibility();
    final existing =
        _retryEpisode ?? await retryStore.readRetryEpisode(accountId);
    if (existing != null) {
      final now = clock.now().toUtc();
      final serverBoundary = existing.serverNotBeforeAt;
      final restarted = RetryEpisode(
        startedAt: now,
        deadlineAt: now.add(syncRetryEpisodeBudget),
        lastObservedAt: now,
        nextAttemptAt: serverBoundary != null && now.isBefore(serverBoundary)
            ? serverBoundary
            : null,
        serverNotBeforeAt: serverBoundary,
        attemptCount: 0,
      );
      _retryEpisode = restarted;
      await retryStore.writeRetryEpisode(accountId, restarted);
      if (restarted.nextAttemptAt != null) {
        _emit(_with(activity: SyncActivity.idle, verificationRequired: false));
        _scheduleRetryEpisode();
        return;
      }
    }
    await _requestImmediate(SyncTrigger.resumeSync);
  }

  SyncRuntimeFacts _inactiveAuthorization() => SyncRuntimeFacts(
    authorization: SyncAuthorization.absent,
    connectivity: _currentFacts.connectivity,
    activity: SyncActivity.idle,
    verificationRequired: false,
  );

  SyncRuntimeFacts _with({
    SyncAuthorization? authorization,
    SyncConnectivity? connectivity,
    SyncActivity? activity,
    bool? verificationRequired,
    SyncFailureReason? detectedFailureReason,
    String? diagnosticCode,
    SyncHealthAction? failureAction,
    bool clearFailure = false,
  }) => SyncRuntimeFacts(
    authorization: authorization ?? _currentFacts.authorization,
    connectivity: connectivity ?? _currentFacts.connectivity,
    activity: activity ?? _currentFacts.activity,
    verificationRequired:
        verificationRequired ?? _currentFacts.verificationRequired,
    detectedFailureReason: clearFailure
        ? null
        : detectedFailureReason ?? _currentFacts.detectedFailureReason,
    diagnosticCode: clearFailure
        ? null
        : diagnosticCode ?? _currentFacts.diagnosticCode,
    failureAction: clearFailure
        ? SyncHealthAction.none
        : failureAction ?? _currentFacts.failureAction,
  );

  void _emit(SyncRuntimeFacts value) {
    _currentFacts = value;
    diagnostics?.record(
      DiagnosticEvent(
        subsystem: DiagnosticSubsystem.sync,
        kind: value.detectedFailureReason == null
            ? DiagnosticEventKind.transition
            : DiagnosticEventKind.failure,
        code: value.diagnosticCode ?? 'sync.runtime_transition',
        operation: 'coordinate_sync',
        fields: <DiagnosticField>[
          DiagnosticField.safe('authorization', value.authorization.name),
          DiagnosticField.safe('connectivity', value.connectivity.name),
          DiagnosticField.safe('activity', value.activity.name),
          DiagnosticField.safe(
            'verification_required',
            value.verificationRequired,
          ),
          if (value.detectedFailureReason case final reason?)
            DiagnosticField.safe('failure_reason', reason.name),
        ],
      ),
    );
    if (!_facts.isClosed) _facts.add(value);
  }

  void _requireOpen() {
    if (_closed) throw StateError('Coordinator is closed.');
  }

  Future<void> close() async {
    if (_closed) return;
    _shutdownRequested = true;
    _activeGeneration += 1;
    _activeControl?.requestCancellation();
    _localEditTimer?.cancel();
    _cadenceTimer?.cancel();
    _deleteEligibilityTimer?.cancel();
    _retryTimer?.cancel();
    _retryExhaustionTimer?.cancel();
    await _authorizationSubscription.cancel();
    await _lifecycleSubscription?.cancel();
    await _connectivitySubscription?.cancel();
    try {
      await _lifecycleOperation;
    } on Object {
      // The safe failure projection was emitted by the lifecycle listener.
    }
    try {
      await _reauthorizationOperation;
    } on Object {
      // The durable latch remains authoritative after a failed action.
    }
    _closed = true;
    await _facts.close();
  }
}

final class _CoordinatorRequestRetryObserver
    implements SyncRequestRetryObserver {
  const _CoordinatorRequestRetryObserver(this.coordinator);

  final SyncCoordinator coordinator;

  @override
  void retryStateChanged(
    SyncRequestRetryState state, {
    required Failure failure,
    required int attempt,
    required Duration? delay,
  }) {
    if (coordinator._closed) return;
    switch (state) {
      case SyncRequestRetryState.waiting:
        coordinator._emit(
          coordinator._with(
            activity: SyncActivity.idle,
            verificationRequired: false,
            detectedFailureReason: _failureReason(failure),
            diagnosticCode: failure.code,
            failureAction: SyncHealthAction.retry,
          ),
        );
      case SyncRequestRetryState.executing:
        coordinator._emit(
          coordinator._with(
            activity: SyncActivity.retrying,
            verificationRequired: true,
            clearFailure: true,
          ),
        );
    }
  }
}

DateTime? _later(DateTime? first, DateTime? second) {
  if (first == null) return second?.toUtc();
  if (second == null) return first.toUtc();
  return first.toUtc().isAfter(second.toUtc()) ? first.toUtc() : second.toUtc();
}

SyncAuthorization _authorizationFact(AuthorizationState state) =>
    switch (state) {
      TasksAuthorized() || AuthorizationExpired() => SyncAuthorization.usable,
      AuthorizationConnecting() ||
      AuthorizationRefreshPending() => SyncAuthorization.refreshing,
      NoTasksAuthorization() ||
      AuthorizationRejected() => SyncAuthorization.absent,
      AuthorizationRequestFailed() => SyncAuthorization.unknown,
    };

SyncConnectivity _connectivityFact(ConnectivityHint hint) => switch (hint) {
  ConnectivityHint.unknown => SyncConnectivity.unknown,
  ConnectivityHint.provenNoRoute => SyncConnectivity.provenNoRoute,
  ConnectivityHint.mayHaveReturned => SyncConnectivity.mayHaveReturned,
};

bool _checkingAuthorization(AuthorizationState state) =>
    state is AuthorizationConnecting ||
    state is AuthorizationRefreshPending ||
    state is NoTasksAuthorization ||
    state is AuthorizationRequestFailed;

SyncFailureReason _failureReason(Failure failure) => switch (failure.category) {
  FailureCategory.network => SyncFailureReason.noConnection,
  FailureCategory.rateLimit ||
  FailureCategory.remote => SyncFailureReason.remoteFailure,
  _ => SyncFailureReason.applicationFailure,
};

const Failure _runTimeoutFailure = Failure(
  code: 'sync.run_timeout',
  category: FailureCategory.remote,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.transient,
  impact: 'Synchronization did not complete within its run deadline.',
  action: FailureAction.retry,
  safeSummary: 'The synchronization run reached its two-minute deadline.',
);
