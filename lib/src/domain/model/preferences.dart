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

final class DevicePreferences {
  const DevicePreferences({
    required this.theme,
    required this.density,
    required this.onboardingDismissed,
  });

  const DevicePreferences.defaults()
    : theme = ThemePreference.system,
      density = DensityPreference.standard,
      onboardingDismissed = false;

  final ThemePreference theme;
  final DensityPreference density;
  final bool onboardingDismissed;

  DevicePreferences copyWith({
    ThemePreference? theme,
    DensityPreference? density,
    bool? onboardingDismissed,
  }) => DevicePreferences(
    theme: theme ?? this.theme,
    density: density ?? this.density,
    onboardingDismissed: onboardingDismissed ?? this.onboardingDismissed,
  );

  @override
  bool operator ==(Object other) =>
      other is DevicePreferences &&
      theme == other.theme &&
      density == other.density &&
      onboardingDismissed == other.onboardingDismissed;

  @override
  int get hashCode => Object.hash(theme, density, onboardingDismissed);
}
