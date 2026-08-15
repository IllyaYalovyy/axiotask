import 'dart:async';
import 'dart:ui' show AppExitResponse, ViewFocusEvent, ViewFocusState;

import 'package:flutter/widgets.dart';

import '../core/lifecycle.dart';
export '../core/lifecycle.dart';

/// Linux lifecycle facts for sync scheduling and best-effort cancellation.
///
/// The process remains eligible while hidden, minimized, or unfocused. Exit is
/// merely a cancellation request; durable correctness never waits for it.
final class LinuxLifecycleBridge
    with WidgetsBindingObserver
    implements LifecyclePort {
  LinuxLifecycleBridge() {
    WidgetsBinding.instance.addObserver(this);
  }

  final StreamController<LifecycleFact> _facts =
      StreamController<LifecycleFact>.broadcast(sync: true);
  bool _disposed = false;
  bool _isWindowFocused = true;
  bool _exitRequested = false;

  @override
  LifecycleEligibility get currentEligibility =>
      LifecycleEligibility.foreground;

  @override
  bool get isWindowFocused => _isWindowFocused;

  @override
  bool get exitRequested => _exitRequested;

  @override
  Stream<LifecycleFact> get facts => _facts.stream;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_disposed && state == AppLifecycleState.resumed) {
      _facts.add(const LifecycleForegrounded());
    }
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (_disposed) return;
    final focused = event.state == ViewFocusState.focused;
    if (_isWindowFocused == focused) return;
    _isWindowFocused = focused;
    _facts.add(WindowFocusChanged(isFocused: focused));
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (!_disposed && !_exitRequested) {
      _exitRequested = true;
      _facts.add(const ProcessExitRequested());
    }
    return AppExitResponse.exit;
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    await _facts.close();
  }
}
