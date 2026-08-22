import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/preferences_repository.dart';

final class MemorySettingsPreferences implements PreferencesRepository {
  MemorySettingsPreferences({
    this.current = const DevicePreferences.defaults(),
  });

  final StreamController<DevicePreferences> _changes =
      StreamController<DevicePreferences>.broadcast(sync: true);
  DevicePreferences current;
  final List<ThemePreference> themeWrites = <ThemePreference>[];
  final List<DensityPreference> densityWrites = <DensityPreference>[];
  bool failNextThemeWrite = false;
  bool failNextDensityWrite = false;

  Future<void> close() => _changes.close();

  @override
  Stream<DevicePreferences> watchDevicePreferences() async* {
    yield current;
    yield* _changes.stream;
  }

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async {
    themeWrites.add(theme);
    if (failNextThemeWrite) {
      failNextThemeWrite = false;
      return const Outcome<void>.failure(settingsWriteFailure);
    }
    current = current.copyWith(theme: theme);
    _changes.add(current);
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async {
    densityWrites.add(density);
    if (failNextDensityWrite) {
      failNextDensityWrite = false;
      return const Outcome<void>.failure(settingsWriteFailure);
    }
    current = current.copyWith(density: density);
    _changes.add(current);
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setWorkspacePreferences(
    DesktopWorkspacePreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async {
    current = current.copyWith(onboardingDismissed: dismissed);
    _changes.add(current);
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) => const Stream<Map<TaskListId, ListPreferences>>.empty();

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) => const Stream<Map<ViewKey, ViewPreferences>>.empty();

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => const Stream<ListPreferences>.empty();

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) => const Stream<ViewPreferences>.empty();
}

const Failure settingsWriteFailure = Failure(
  code: 'synthetic.settings_write_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'Synthetic settings persistence failure.',
  safeSummary: 'Synthetic settings persistence failure.',
);
