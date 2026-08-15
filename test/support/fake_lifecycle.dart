import 'dart:async';

import 'package:axiotask/src/app/lifecycle.dart';

/// Drives lifecycle facts without relying on Flutter bindings or wall time.
final class FakeLifecycle implements LifecyclePort {
  FakeLifecycle({
    LifecycleEligibility initialEligibility = LifecycleEligibility.foreground,
    bool initialWindowFocused = true,
  }) : _currentEligibility = initialEligibility,
       _isWindowFocused = initialWindowFocused;

  final StreamController<LifecycleFact> _facts =
      StreamController<LifecycleFact>.broadcast(sync: true);
  LifecycleEligibility _currentEligibility;
  bool _isWindowFocused;
  bool _exitRequested = false;
  bool _terminated = false;
  Completer<void>? _cancellationAcknowledgement;

  @override
  LifecycleEligibility get currentEligibility => _currentEligibility;

  @override
  bool get isWindowFocused => _isWindowFocused;

  @override
  bool get exitRequested => _exitRequested;

  @override
  Stream<LifecycleFact> get facts => _facts.stream;

  Future<void> get whenCancellationAcknowledged {
    final acknowledgement = _cancellationAcknowledgement;
    if (acknowledgement == null) {
      throw StateError(
        'No lifecycle cancellation is awaiting acknowledgement.',
      );
    }
    return acknowledgement.future;
  }

  bool enterForeground() => _setEligibility(
    LifecycleEligibility.foreground,
    const LifecycleForegrounded(),
  );

  bool enterBackground() => _setEligibility(
    LifecycleEligibility.background,
    const LifecycleBackgrounded(),
    requiresCancellationAcknowledgement: true,
  );

  bool setWindowFocused(bool focused) {
    _requireRunning();
    if (_isWindowFocused == focused) return false;
    _isWindowFocused = focused;
    _facts.add(WindowFocusChanged(isFocused: focused));
    return true;
  }

  bool requestProcessExit() {
    _requireRunning();
    if (_exitRequested) return false;
    _beginCancellationAcknowledgement();
    _exitRequested = true;
    _facts.add(const ProcessExitRequested());
    return true;
  }

  void acknowledgeCancellation() {
    _requireRunning();
    final acknowledgement = _cancellationAcknowledgement;
    if (acknowledgement == null || acknowledgement.isCompleted) {
      throw StateError('No lifecycle cancellation awaits acknowledgement.');
    }
    acknowledgement.complete();
  }

  void terminateWithoutExitFact() {
    _requireRunning();
    _terminated = true;
    unawaited(_facts.close());
  }

  bool _setEligibility(
    LifecycleEligibility eligibility,
    LifecycleFact fact, {
    bool requiresCancellationAcknowledgement = false,
  }) {
    _requireRunning();
    if (_currentEligibility == eligibility) return false;
    if (requiresCancellationAcknowledgement) {
      _beginCancellationAcknowledgement();
    }
    _currentEligibility = eligibility;
    _facts.add(fact);
    return true;
  }

  void _beginCancellationAcknowledgement() {
    final existing = _cancellationAcknowledgement;
    if (existing != null && !existing.isCompleted) {
      throw StateError('The prior lifecycle cancellation is unacknowledged.');
    }
    _cancellationAcknowledgement = Completer<void>();
  }

  void _requireRunning() {
    if (_terminated) throw StateError('Fake lifecycle process is terminated.');
  }

  Future<void> close() async {
    if (_terminated) return;
    _terminated = true;
    await _facts.close();
  }
}
