import 'dart:async';

import '../../core/clock.dart';
import '../../core/failure.dart';
import '../../core/lifecycle.dart';
import '../../core/outcome.dart';
import '../../data/auth/authorization.dart';
import '../../data/connectivity/connectivity.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/sync_settings_repository.dart';
import '../health/sync_health.dart';
import '../health/sync_health_repository.dart';
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
  cadence,
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
    SyncTrigger.cadence => 'cadence',
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
  }) : triggers = Set<SyncTrigger>.unmodifiable(triggers);

  final Set<SyncTrigger> triggers;
  final Duration deadline;
  final SyncCoordinatorRunControl control;
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
final class SyncCoordinator implements SyncRuntimeFactsSource {
  SyncCoordinator({
    required this.accountId,
    required this.authorization,
    required this.clock,
    required this.scheduler,
    required this.settings,
    required this.run,
    this.taskDeleteEligibility,
    LifecyclePort? lifecycle,
    ConnectivityPort? connectivity,
  }) : _connectivity = connectivity,
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
  final CoordinatedSyncRun run;
  final TaskDeleteEligibilityStore? taskDeleteEligibility;
  final ConnectivityPort? _connectivity;
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
  Duration? _localEditBurstStartedAt;
  SyncCoordinatorRunControl? _activeControl;
  var _activeGeneration = 0;
  var _activeTimedOut = false;
  bool? _syncEnabled;
  bool _stopRequested = false;
  bool _shutdownRequested = false;
  Future<void>? _settingsOperation;
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
      _syncEnabled = await settings.readSyncEnabled(accountId);
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
    if (_syncEnabled != true) {
      _emit(_with(activity: SyncActivity.idle, verificationRequired: false));
      return;
    }
    await _requestImmediate(SyncTrigger.startup);
  }

  Future<void> refresh() async {
    await _refreshTaskDeleteEligibility();
    await _requestImmediate(SyncTrigger.refresh);
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
    if (_syncEnabled != true || _stopRequested || _shutdownRequested) {
      return whenIdle;
    }
    if (_activeControl != null) {
      _followUpTriggers.add(trigger);
      _emit(
        _with(activity: SyncActivity.verifying, verificationRequired: true),
      );
      return whenIdle;
    }

    if (_localEditTimer?.isActive ?? false) {
      _localEditTimer?.cancel();
      _localEditTimer = null;
      _localEditBurstStartedAt = null;
      _pendingTriggers.add(SyncTrigger.localEdit);
    }
    _pendingTriggers.add(trigger);
    _emit(
      _with(
        authorization: _authorizationFact(authorization.currentState),
        activity: _checkingAuthorization(authorization.currentState)
            ? SyncActivity.checkingAuthorization
            : SyncActivity.verifying,
        verificationRequired: true,
        clearFailure: trigger == SyncTrigger.resumeSync,
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
        if (_syncEnabled != true || _stopRequested || _shutdownRequested) {
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
            activity: SyncActivity.verifying,
            verificationRequired: true,
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
            ),
          );
        } finally {
          deadlineTimer.cancel();
        }
        final stale = _closed || _activeGeneration != generation;
        final timedOut = _activeTimedOut;
        _activeControl = null;
        _activeTimedOut = false;

        if (!stale && !timedOut && _followUpTriggers.isEmpty) {
          _acceptReport(report);
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
    if (_syncEnabled != true || _stopRequested || _shutdownRequested) {
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
      Failed<AccountSubject>(:final failure) => _acceptAuthorizationFailure(
        failure,
      ),
    };
  }

  bool _acceptAuthorizationFailure(Failure failure) {
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

  void _acceptReport(SyncRunReport report) {
    switch (report.outcome) {
      case SyncRunOutcome.succeeded || SyncRunOutcome.failed:
        _emit(
          _with(
            authorization: SyncAuthorization.usable,
            activity: SyncActivity.idle,
            verificationRequired: false,
            clearFailure: true,
          ),
        );
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
    }
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
        _acceptAuthorizationFailure(failure);
    }
  }

  void _acceptConnectivityHint(ConnectivityHint hint) {
    if (_closed) return;
    _emit(_with(connectivity: _connectivityFact(hint)));
    if (hint == ConnectivityHint.mayHaveReturned) {
      unawaited(_requestImmediate(SyncTrigger.connectivityRestored));
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
    await _authorizationSubscription.cancel();
    await _lifecycleSubscription?.cancel();
    await _connectivitySubscription?.cancel();
    try {
      await _lifecycleOperation;
    } on Object {
      // The safe failure projection was emitted by the lifecycle listener.
    }
    _closed = true;
    await _facts.close();
  }
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
