import 'dart:async';

import 'package:flutter/widgets.dart';

enum LifecycleEligibility { foreground, background }

sealed class LifecycleFact {
  const LifecycleFact();
}

final class LifecycleForegrounded extends LifecycleFact {
  const LifecycleForegrounded();
}

final class LifecycleBackgrounded extends LifecycleFact {
  const LifecycleBackgrounded();
}

/// Window focus is observable on Linux but does not change sync eligibility.
final class WindowFocusChanged extends LifecycleFact {
  const WindowFocusChanged({required this.isFocused});

  final bool isFocused;

  @override
  bool operator ==(Object other) =>
      other is WindowFocusChanged && isFocused == other.isFocused;

  @override
  int get hashCode => isFocused.hashCode;
}

/// A best-effort exit notification, never a durability or flush guarantee.
final class ProcessExitRequested extends LifecycleFact {
  const ProcessExitRequested();
}

abstract interface class LifecyclePort {
  LifecycleEligibility get currentEligibility;

  bool get isWindowFocused;

  bool get exitRequested;

  Stream<LifecycleFact> get facts;
}

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
