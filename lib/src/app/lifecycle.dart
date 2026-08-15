import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/lifecycle.dart';
export '../core/lifecycle.dart';

/// Minimal Linux resume adapter for the foreground-only read slice.
///
/// Linux stays sync-eligible while its window is hidden or unfocused. Full
/// stop/cancel/exit lifecycle behavior remains in its later owning slice.
final class LinuxLifecycleBridge
    with WidgetsBindingObserver
    implements LifecyclePort {
  LinuxLifecycleBridge() {
    WidgetsBinding.instance.addObserver(this);
  }

  final StreamController<LifecycleFact> _facts =
      StreamController<LifecycleFact>.broadcast(sync: true);
  bool _disposed = false;

  @override
  LifecycleEligibility get currentEligibility =>
      LifecycleEligibility.foreground;

  @override
  bool get isWindowFocused => true;

  @override
  bool get exitRequested => false;

  @override
  Stream<LifecycleFact> get facts => _facts.stream;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_disposed && state == AppLifecycleState.resumed) {
      _facts.add(const LifecycleForegrounded());
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    await _facts.close();
  }
}
