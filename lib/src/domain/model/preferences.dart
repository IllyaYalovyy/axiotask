final class ViewKey {
  const ViewKey(this.value) : assert(value.length > 0);

  final String value;

  @override
  bool operator ==(Object other) => other is ViewKey && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ViewKey($value)';
}

enum ViewSort { manual, effectiveDue, title, created }

final class ListPreferences {
  const ListPreferences({
    required this.sidebarOrder,
    required this.excludedFromSmartViews,
  }) : assert(sidebarOrder == null || sidebarOrder >= 0);

  const ListPreferences.defaults()
    : sidebarOrder = null,
      excludedFromSmartViews = false;

  final int? sidebarOrder;
  final bool excludedFromSmartViews;

  @override
  bool operator ==(Object other) =>
      other is ListPreferences &&
      sidebarOrder == other.sidebarOrder &&
      excludedFromSmartViews == other.excludedFromSmartViews;

  @override
  int get hashCode => Object.hash(sidebarOrder, excludedFromSmartViews);
}

final class ViewPreferences {
  const ViewPreferences({required this.sort, required this.showCompleted});

  const ViewPreferences.defaults()
    : sort = ViewSort.manual,
      showCompleted = false;

  final ViewSort sort;
  final bool showCompleted;

  @override
  bool operator ==(Object other) =>
      other is ViewPreferences &&
      sort == other.sort &&
      showCompleted == other.showCompleted;

  @override
  int get hashCode => Object.hash(sort, showCompleted);
}

enum ThemePreference { system, light, dark }

enum DensityPreference { standard, compact }

/// Device-local pane dimensions; never task, account, or synchronization data.
final class DesktopWorkspacePreferences {
  const DesktopWorkspacePreferences({
    required this.navigationWidth,
    required this.detailWidth,
  });

  const DesktopWorkspacePreferences.defaults()
    : navigationWidth = 244,
      detailWidth = 360;

  final double navigationWidth;
  final double detailWidth;

  DesktopWorkspacePreferences copyWith({
    double? navigationWidth,
    double? detailWidth,
  }) => DesktopWorkspacePreferences(
    navigationWidth: navigationWidth ?? this.navigationWidth,
    detailWidth: detailWidth ?? this.detailWidth,
  );

  @override
  bool operator ==(Object other) =>
      other is DesktopWorkspacePreferences &&
      navigationWidth == other.navigationWidth &&
      detailWidth == other.detailWidth;

  @override
  int get hashCode => Object.hash(navigationWidth, detailWidth);
}

/// Device-local on/off settings. Each is stored beside the other device
/// preferences, never in the account database, so a schema-verified database
/// is untouched by adding one.
enum DeviceToggle {
  /// Vibrate briefly on touch actions (complete, select, schedule, drag,
  /// delete, undo). Touch devices only.
  haptics('haptics', true),

  /// Start task details with finished subtasks folded away.
  collapseCompletedSubtasks('collapse_completed_subtasks', true),

  /// Synchronize when the application starts.
  autoSyncOnStartup('auto_sync_on_startup', true);

  const DeviceToggle(this.storageName, this.defaultValue);

  /// Stable storage key suffix; never rename a released value.
  final String storageName;
  final bool defaultValue;
}

final class DevicePreferences {
  const DevicePreferences({
    required this.theme,
    required this.density,
    required this.onboardingDismissed,
    this.workspace = const DesktopWorkspacePreferences.defaults(),
    this.haptics = true,
    this.collapseCompletedSubtasks = true,
    this.autoSyncOnStartup = true,
  });

  const DevicePreferences.defaults()
    : theme = ThemePreference.system,
      density = DensityPreference.standard,
      onboardingDismissed = false,
      workspace = const DesktopWorkspacePreferences.defaults(),
      haptics = true,
      collapseCompletedSubtasks = true,
      autoSyncOnStartup = true;

  final ThemePreference theme;
  final DensityPreference density;
  final bool onboardingDismissed;
  final DesktopWorkspacePreferences workspace;
  final bool haptics;
  final bool collapseCompletedSubtasks;
  final bool autoSyncOnStartup;

  bool toggle(DeviceToggle toggle) => switch (toggle) {
    DeviceToggle.haptics => haptics,
    DeviceToggle.collapseCompletedSubtasks => collapseCompletedSubtasks,
    DeviceToggle.autoSyncOnStartup => autoSyncOnStartup,
  };

  DevicePreferences withToggle(DeviceToggle toggle, bool value) =>
      switch (toggle) {
        DeviceToggle.haptics => copyWith(haptics: value),
        DeviceToggle.collapseCompletedSubtasks => copyWith(
          collapseCompletedSubtasks: value,
        ),
        DeviceToggle.autoSyncOnStartup => copyWith(autoSyncOnStartup: value),
      };

  DevicePreferences copyWith({
    ThemePreference? theme,
    DensityPreference? density,
    bool? onboardingDismissed,
    DesktopWorkspacePreferences? workspace,
    bool? haptics,
    bool? collapseCompletedSubtasks,
    bool? autoSyncOnStartup,
  }) => DevicePreferences(
    theme: theme ?? this.theme,
    density: density ?? this.density,
    onboardingDismissed: onboardingDismissed ?? this.onboardingDismissed,
    workspace: workspace ?? this.workspace,
    haptics: haptics ?? this.haptics,
    collapseCompletedSubtasks:
        collapseCompletedSubtasks ?? this.collapseCompletedSubtasks,
    autoSyncOnStartup: autoSyncOnStartup ?? this.autoSyncOnStartup,
  );

  @override
  bool operator ==(Object other) =>
      other is DevicePreferences &&
      theme == other.theme &&
      density == other.density &&
      onboardingDismissed == other.onboardingDismissed &&
      workspace == other.workspace &&
      haptics == other.haptics &&
      collapseCompletedSubtasks == other.collapseCompletedSubtasks &&
      autoSyncOnStartup == other.autoSyncOnStartup;

  @override
  int get hashCode => Object.hash(
    theme,
    density,
    onboardingDismissed,
    workspace,
    haptics,
    collapseCompletedSubtasks,
    autoSyncOnStartup,
  );
}
