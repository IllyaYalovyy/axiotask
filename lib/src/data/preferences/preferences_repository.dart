import '../../core/outcome.dart';
import '../../domain/model/preferences.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/preferences_repository.dart';
import 'device_preferences.dart';
import 'relational_preferences.dart';

final class StoredPreferencesRepository implements PreferencesRepository {
  factory StoredPreferencesRepository({
    required RelationalPreferences relational,
    required DevicePreferencesStore device,
  }) => StoredPreferencesRepository._(relational, device);

  const StoredPreferencesRepository._(this._relational, this._device);

  final RelationalPreferences _relational;
  final DevicePreferencesStore _device;

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) => _relational.watchAllListPreferences(accountId);

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => _relational.watchListPreferences(accountId, taskListId);

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) => _relational.setListPreferences(accountId, taskListId, preferences);

  @override
  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  ) => _relational.setSidebarOrder(accountId, orderedTaskListIds);

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) => _relational.watchAllViewPreferences(accountId);

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) => _relational.watchViewPreferences(accountId, viewKey);

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) => _relational.setViewPreferences(accountId, viewKey, preferences);

  @override
  Stream<DevicePreferences> watchDevicePreferences() => _device.watch();

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) =>
      _device.setTheme(theme);

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) =>
      _device.setDensity(density);

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) =>
      _device.setOnboardingDismissed(dismissed);
}
