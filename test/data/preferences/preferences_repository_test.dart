import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/sync_settings_repository.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/data/preferences/preferences_repository.dart';
import 'package:axiotask/src/data/preferences/relational_preferences.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'repository hides storage selection and isolates device failure',
    () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final account = AccountId(
        await database.createAccount('synthetic-routing-account'),
      );
      final list = await CacheDao(database).putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-routing-list'),
        title: 'Routing list',
      );
      final backend = InMemoryDevicePreferencesBackend()..failWrites = true;
      final device = DevicePreferencesAdapter(
        backend: backend,
        namespace: 'synthetic-routing',
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
      );
      addTearDown(device.close);
      final repository = StoredPreferencesRepository(
        relational: DriftRelationalPreferences(database),
        device: device,
      );

      expect(
        await repository.setTheme(ThemePreference.dark),
        isA<Failed<void>>(),
      );
      expect(
        await repository.setListPreferences(
          account,
          list,
          const ListPreferences(sidebarOrder: 2, excludedFromSmartViews: true),
        ),
        isA<Success<void>>(),
      );
      expect(
        await repository.setViewPreferences(
          account,
          const ViewKey('upcoming'),
          const ViewPreferences(sort: ViewSort.created, showCompleted: true),
        ),
        isA<Success<void>>(),
      );

      expect(
        await repository.watchListPreferences(account, list).first,
        const ListPreferences(sidebarOrder: 2, excludedFromSmartViews: true),
      );
      expect(
        await repository
            .watchViewPreferences(account, const ViewKey('upcoming'))
            .first,
        const ViewPreferences(sort: ViewSort.created, showCompleted: true),
      );
      expect(
        await DatabaseSyncSettingsRepository(database).readSyncEnabled(account),
        isTrue,
      );
      expect(backend.writeAttempts, 1);
    },
  );
}
