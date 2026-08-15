import 'package:drift/drift.dart';

import '../../domain/model/tasks.dart';
import '../../domain/repository/sync_settings_repository.dart';
import 'app_database.dart';

final class DatabaseSyncSettingsRepository implements SyncSettingsRepository {
  const DatabaseSyncSettingsRepository(this._database);

  final AppDatabase _database;

  @override
  Future<bool> readSyncEnabled(AccountId accountId) async {
    final row = await _database
        .customSelect(
          '''
          SELECT COALESCE(p.sync_enabled, 1) AS sync_enabled
          FROM accounts a
          LEFT JOIN account_preferences p ON p.account_id = a.id
          WHERE a.id = ?1
          ''',
          variables: <Variable<Object>>[Variable<int>(accountId.value)],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.accounts,
            _database.accountPreferenceRows,
          },
        )
        .getSingleOrNull();
    if (row == null) {
      throw StateError('The synchronization account does not exist.');
    }
    return row.read<bool>('sync_enabled');
  }

  @override
  Future<void> setSyncEnabled(AccountId accountId, bool enabled) {
    return _database.transaction(() async {
      final account = await (_database.select(
        _database.accounts,
      )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
      if (account == null) {
        throw StateError('The synchronization account does not exist.');
      }
      await _database
          .into(_database.accountPreferenceRows)
          .insertOnConflictUpdate(
            AccountPreferenceRowsCompanion.insert(
              accountId: Value<int>(accountId.value),
              syncEnabled: Value<bool>(enabled),
            ),
          );
    });
  }
}
