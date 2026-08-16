import '../../core/outcome.dart';
import '../model/preferences.dart';
import '../model/tasks.dart';

abstract interface class PreferencesRepository {
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  );

  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
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
}
