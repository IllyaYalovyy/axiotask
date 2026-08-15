import 'dart:async';

import '../core/failure.dart';
import '../core/outcome.dart';
import '../data/auth/authorization.dart';
import '../domain/model/tasks.dart';
import '../sync/health/sync_health.dart';
import '../sync/health/sync_health_repository.dart';
import '../sync/run.dart';
import 'lifecycle.dart';

typedef ForegroundReadRun =
    Future<SyncRunReport> Function(Set<String> triggers);

/// The deliberately small foreground trigger bridge for the first read slice.
///
/// Cadence, retry/backoff, connectivity triggers, and mutation scheduling belong
/// to the later full coordinator. This bridge only serializes startup, Linux
/// resume, and explicit Refresh so none of them can overlap or flash Good while
/// a follow-up verification is owed.
final class ForegroundReadCoordinator implements SyncRuntimeFactsSource {
  ForegroundReadCoordinator({
    required this.accountId,
    required this.authorization,
    required this.run,
    LifecyclePort? lifecycle,
  }) : _currentFacts = const SyncRuntimeFacts(
         authorization: SyncAuthorization.unknown,
         activity: SyncActivity.checkingAuthorization,
         verificationRequired: true,
       ) {
    _authorizationSubscription = authorization.states.listen(
      _acceptAuthorizationState,
    );
    _lifecycleSubscription = lifecycle?.facts.listen((fact) {
      if (fact is LifecycleForegrounded) unawaited(_request('resume'));
    });
  }

  final AccountId accountId;
  final AuthorizationPort authorization;
  final ForegroundReadRun run;
  final StreamController<SyncRuntimeFacts> _facts =
      StreamController<SyncRuntimeFacts>.broadcast(sync: true);
  final Set<String> _pendingTriggers = <String>{};
  late final StreamSubscription<AuthorizationState> _authorizationSubscription;
  StreamSubscription<LifecycleFact>? _lifecycleSubscription;
  SyncRuntimeFacts _currentFacts;
  Future<void>? _drain;
  bool _started = false;
  bool _closed = false;

  @override
  SyncRuntimeFacts get currentFacts => _currentFacts;

  @override
  Stream<SyncRuntimeFacts> get facts => _facts.stream;

  Future<void> get whenIdle => _drain ?? Future<void>.value();

  Future<void> start() {
    if (_started) return whenIdle;
    _started = true;
    return _request('startup');
  }

  Future<void> refresh() => _request('refresh');

  Future<void> _request(String trigger) {
    if (_closed) {
      return Future<void>.error(StateError('Coordinator is closed.'));
    }
    _pendingTriggers.add(trigger);
    _emit(
      _with(
        authorization: _authorizationFact(authorization.currentState),
        activity: _checkingAuthorization(authorization.currentState)
            ? SyncActivity.checkingAuthorization
            : SyncActivity.verifying,
        verificationRequired: true,
        clearFailure: true,
      ),
    );
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
        final triggers = Set<String>.unmodifiable(_pendingTriggers);
        _pendingTriggers.clear();
        if (!await _ensureAuthorization()) {
          _pendingTriggers.clear();
          break;
        }
        _emit(
          _with(
            authorization: SyncAuthorization.usable,
            activity: SyncActivity.verifying,
            verificationRequired: true,
            clearFailure: true,
          ),
        );
        final report = await run(triggers);
        if (_pendingTriggers.isNotEmpty) {
          // Keep verification active across durable finalization so the old
          // run's success cannot emit Good before its queued follow-up starts.
          continue;
        }
        _acceptReport(report);
      }
      completer.complete();
    } catch (error, stackTrace) {
      _emit(
        _with(
          authorization: _authorizationFact(authorization.currentState),
          activity: SyncActivity.idle,
          verificationRequired: false,
          detectedFailureReason: SyncFailureReason.applicationFailure,
          diagnosticCode: 'sync.foreground_run_failed',
          failureAction: SyncHealthAction.retry,
        ),
      );
      completer.completeError(error, stackTrace);
    } finally {
      _drain = null;
    }
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
        clearFailure: true,
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
                authorization: _authorizationFact(authorization.currentState),
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
            diagnosticCode: 'sync.foreground_run_interrupted',
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
            clearFailure: true,
          ),
        );
      case TasksAuthorized() || AuthorizationExpired():
        _emit(
          _with(
            authorization: SyncAuthorization.usable,
            verificationRequired: true,
            clearFailure: true,
          ),
        );
      case NoTasksAuthorization() || AuthorizationRejected():
        if (_started) _emit(_inactiveAuthorization());
      case AuthorizationRequestFailed(:final failure):
        _acceptAuthorizationFailure(failure);
    }
  }

  SyncRuntimeFacts _inactiveAuthorization() => const SyncRuntimeFacts(
    authorization: SyncAuthorization.absent,
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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _authorizationSubscription.cancel();
    await _lifecycleSubscription?.cancel();
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
