import 'dart:io';

import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/sync_settings_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'syncEnabled is account-scoped, durable, and preserves sync facts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-synthetic-sync-settings-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/settings.sqlite');
      final recordedAt = DateTime.utc(2026, 8, 15, 12);

      var database = await AppDatabase.openFile(file);
      final accountA = AccountId(await database.createAccount('synthetic-a'));
      final accountB = AccountId(await database.createAccount('synthetic-b'));
      await SyncHealthDao(database).writeFacts(
        accountA,
        PersistedSyncFacts(
          lastSuccessfulSyncAt: recordedAt,
          counts: const SyncWorkCounts(pending: 2, uncertain: 1),
        ),
      );
      var repository = DatabaseSyncSettingsRepository(database);

      await repository.setSyncEnabled(accountA, false);
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      repository = DatabaseSyncSettingsRepository(database);
      final facts = await SyncHealthDao(database).watchFacts(accountA).first;

      expect(await repository.readSyncEnabled(accountA), isFalse);
      expect(await repository.readSyncEnabled(accountB), isTrue);
      expect(facts.lastSuccessfulSyncAt, recordedAt);
      expect(facts.counts, const SyncWorkCounts(pending: 2, uncertain: 1));
    },
  );
}
