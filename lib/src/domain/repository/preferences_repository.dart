import '../../core/outcome.dart';
import '../model/preferences.dart';
import '../model/tasks.dart';

abstract interface class PreferencesRepository {
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  );

  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  );

  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  );

  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  );

  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  );

  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  );

  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  );

  Stream<DevicePreferences> watchDevicePreferences();

  Future<Outcome<void>> setTheme(ThemePreference theme);

  Future<Outcome<void>> setDensity(DensityPreference density);

  Future<Outcome<void>> setOnboardingDismissed(bool dismissed);

  Future<Outcome<void>> setWorkspacePreferences(
    DesktopWorkspacePreferences preferences,
  );
}
