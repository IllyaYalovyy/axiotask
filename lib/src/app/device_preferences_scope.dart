import 'package:material_ui/material_ui.dart';

import '../domain/model/preferences.dart';

/// Makes the current device preferences readable by presentation widgets
/// that are far from the application root, such as task details.
final class DevicePreferencesScope extends InheritedWidget {
  const DevicePreferencesScope({
    required this.preferences,
    required super.child,
    super.key,
  });

  final DevicePreferences preferences;

  /// The preferences in effect; defaults when no scope is installed.
  static DevicePreferences of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DevicePreferencesScope>()
          ?.preferences ??
      const DevicePreferences.defaults();

  @override
  bool updateShouldNotify(DevicePreferencesScope oldWidget) =>
      preferences != oldWidget.preferences;
}
