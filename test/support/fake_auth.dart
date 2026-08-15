import 'dart:async';
import 'dart:collection';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';

enum FakeAuthorizationOperation { restore, refresh, interactive }

final class FakeAuthorizationAttempt {
  FakeAuthorizationAttempt._(
    this.operation,
    Iterable<AuthorizationState> transitions,
    this.outcome,
  ) : transitions = List<AuthorizationState>.unmodifiable(transitions);

  factory FakeAuthorizationAttempt.restoreSuccess(AccountSubject subject) =>
      FakeAuthorizationAttempt._(
        FakeAuthorizationOperation.restore,
        <AuthorizationState>[
          AuthorizationRefreshPending(subject),
          TasksAuthorized(subject),
        ],
        Outcome<AccountSubject>.success(subject),
      );

  factory FakeAuthorizationAttempt.refreshSuccess(AccountSubject subject) =>
      FakeAuthorizationAttempt._(
        FakeAuthorizationOperation.refresh,
        <AuthorizationState>[
          AuthorizationRefreshPending(subject),
          TasksAuthorized(subject),
        ],
        Outcome<AccountSubject>.success(subject),
      );

  factory FakeAuthorizationAttempt.refreshTerminal(
    AccountSubject subject,
    Failure failure,
  ) => FakeAuthorizationAttempt._(
    FakeAuthorizationOperation.refresh,
    <AuthorizationState>[
      AuthorizationRefreshPending(subject),
      AuthorizationRejected(failure),
    ],
    Outcome<AccountSubject>.failure(failure),
  );

  factory FakeAuthorizationAttempt.interactiveCancelled(Failure failure) =>
      FakeAuthorizationAttempt._(
        FakeAuthorizationOperation.interactive,
        const <AuthorizationState>[
          AuthorizationConnecting(),
          NoTasksAuthorization(),
        ],
        Outcome<AccountSubject>.failure(failure),
      );

  factory FakeAuthorizationAttempt.interactiveSuccess(AccountSubject subject) =>
      FakeAuthorizationAttempt._(
        FakeAuthorizationOperation.interactive,
        <AuthorizationState>[
          const AuthorizationConnecting(),
          TasksAuthorized(subject),
        ],
        Outcome<AccountSubject>.success(subject),
      );

  factory FakeAuthorizationAttempt.restoreMismatch(
    AccountSubject returnedSubject,
    Failure failure,
  ) => FakeAuthorizationAttempt._(
    FakeAuthorizationOperation.restore,
    <AuthorizationState>[
      AuthorizationRefreshPending(returnedSubject),
      AuthorizationRejected(failure),
    ],
    Outcome<AccountSubject>.failure(failure),
  );

  final FakeAuthorizationOperation operation;
  final List<AuthorizationState> transitions;
  final Outcome<AccountSubject> outcome;
}

/// A stateful, fail-closed authorization adapter for deterministic tests.
final class FakeAuthorization implements AuthorizationPort {
  FakeAuthorization({
    AuthorizationState initialState = const NoTasksAuthorization(),
  }) : _currentState = initialState;

  final StreamController<AuthorizationState> _states =
      StreamController<AuthorizationState>.broadcast(sync: true);
  final Queue<FakeAuthorizationAttempt> _attempts =
      Queue<FakeAuthorizationAttempt>();
  final List<FakeAuthorizationOperation> _operationLedger =
      <FakeAuthorizationOperation>[];
  AuthorizationState _currentState;
  var _closed = false;

  @override
  AuthorizationState get currentState => _currentState;

  @override
  Stream<AuthorizationState> get states => _states.stream;

  List<FakeAuthorizationOperation> get operationLedger =>
      List<FakeAuthorizationOperation>.unmodifiable(_operationLedger);

  void enqueue(FakeAuthorizationAttempt attempt) {
    _requireOpen();
    if (attempt.transitions.isEmpty) {
      throw ArgumentError.value(attempt, 'attempt', 'must emit typed states');
    }
    _attempts.add(attempt);
  }

  void expire() {
    _requireOpen();
    final state = _currentState;
    if (state is! TasksAuthorized) {
      throw StateError('Only usable authorization can expire.');
    }
    _emit(AuthorizationExpired(state.subject));
  }

  void rejectDispatchedRequest(Failure failure, {required bool terminal}) {
    _requireOpen();
    final state = _currentState;
    if (state is! TasksAuthorized) {
      throw StateError('A dispatched request requires usable authorization.');
    }
    _emit(
      terminal
          ? AuthorizationRejected(failure)
          : AuthorizationExpired(state.subject, failure: failure),
    );
  }

  @override
  Future<Outcome<AccountSubject>> restoreTasksAuthorization() =>
      _execute(FakeAuthorizationOperation.restore);

  @override
  Future<Outcome<AccountSubject>> refreshTasksAuthorization() =>
      _execute(FakeAuthorizationOperation.refresh);

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() =>
      _execute(FakeAuthorizationOperation.interactive);

  Future<Outcome<AccountSubject>> _execute(
    FakeAuthorizationOperation operation,
  ) async {
    _requireOpen();
    if (_attempts.isEmpty) {
      throw StateError('No fake authorization attempt is scripted.');
    }
    final attempt = _attempts.first;
    if (attempt.operation != operation) {
      throw StateError(
        'Expected ${attempt.operation.name}, received ${operation.name}.',
      );
    }
    _attempts.removeFirst();
    var previous = _currentState;
    for (final next in attempt.transitions) {
      if (!_isAllowedTransition(previous, next)) {
        throw StateError(
          'Invalid fake authorization transition: '
          '${previous.runtimeType} -> ${next.runtimeType}.',
        );
      }
      _emit(next);
      previous = next;
    }
    _requireConsistentOutcome(attempt);
    _operationLedger.add(operation);
    return attempt.outcome;
  }

  void _requireConsistentOutcome(FakeAuthorizationAttempt attempt) {
    final state = _currentState;
    switch (attempt.outcome) {
      case Success<AccountSubject>(:final value):
        if (state is! TasksAuthorized || state.subject != value) {
          throw StateError(
            'Successful fake auth must end usable for its subject.',
          );
        }
      case Failed<AccountSubject>(:final failure):
        final stateFailure = switch (state) {
          AuthorizationRejected(:final failure) => failure,
          AuthorizationRequestFailed(:final failure) => failure,
          _ => null,
        };
        if (stateFailure != null && stateFailure != failure) {
          throw StateError('Fake auth failure state and outcome must agree.');
        }
    }
  }

  bool _isAllowedTransition(
    AuthorizationState previous,
    AuthorizationState next,
  ) => switch ((previous, next)) {
    (NoTasksAuthorization(), AuthorizationConnecting()) => true,
    (NoTasksAuthorization(), AuthorizationRefreshPending()) => true,
    (AuthorizationConnecting(), TasksAuthorized()) => true,
    (AuthorizationConnecting(), NoTasksAuthorization()) => true,
    (AuthorizationConnecting(), AuthorizationRejected()) => true,
    (AuthorizationConnecting(), AuthorizationRequestFailed()) => true,
    (TasksAuthorized(), AuthorizationExpired()) => true,
    (TasksAuthorized(), AuthorizationRejected()) => true,
    (TasksAuthorized(), AuthorizationRefreshPending()) => true,
    (AuthorizationExpired(), AuthorizationRefreshPending()) => true,
    (AuthorizationRefreshPending(), TasksAuthorized()) => true,
    (AuthorizationRefreshPending(), AuthorizationRejected()) => true,
    (AuthorizationRefreshPending(), AuthorizationRequestFailed()) => true,
    (AuthorizationRejected(), AuthorizationConnecting()) => true,
    (AuthorizationRequestFailed(), AuthorizationConnecting()) => true,
    (AuthorizationRequestFailed(), AuthorizationRefreshPending()) => true,
    _ => false,
  };

  void _emit(AuthorizationState state) {
    _currentState = state;
    _states.add(state);
  }

  void _requireOpen() {
    if (_closed) throw StateError('Fake authorization is closed.');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _states.close();
  }
}
