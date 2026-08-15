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
