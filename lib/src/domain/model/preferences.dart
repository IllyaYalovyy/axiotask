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

final class DevicePreferences {
  const DevicePreferences({
    required this.theme,
    required this.density,
    required this.onboardingDismissed,
    this.workspace = const DesktopWorkspacePreferences.defaults(),
  });

  const DevicePreferences.defaults()
    : theme = ThemePreference.system,
      density = DensityPreference.standard,
      onboardingDismissed = false,
      workspace = const DesktopWorkspacePreferences.defaults();

  final ThemePreference theme;
  final DensityPreference density;
  final bool onboardingDismissed;
  final DesktopWorkspacePreferences workspace;

  DevicePreferences copyWith({
    ThemePreference? theme,
    DensityPreference? density,
    bool? onboardingDismissed,
    DesktopWorkspacePreferences? workspace,
  }) => DevicePreferences(
    theme: theme ?? this.theme,
    density: density ?? this.density,
    onboardingDismissed: onboardingDismissed ?? this.onboardingDismissed,
    workspace: workspace ?? this.workspace,
  );

  @override
  bool operator ==(Object other) =>
      other is DevicePreferences &&
      theme == other.theme &&
      density == other.density &&
      onboardingDismissed == other.onboardingDismissed &&
      workspace == other.workspace;

  @override
  int get hashCode =>
      Object.hash(theme, density, onboardingDismissed, workspace);
}
