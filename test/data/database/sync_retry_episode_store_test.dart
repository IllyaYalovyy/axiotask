import 'dart:io';

import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/retry/retry_episode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'REL-009 retry episode and exhaustion survive restart per account',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-synthetic-retry-episode-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/synthetic.sqlite');
      final startedAt = DateTime.utc(2026, 8, 15, 12);

      var database = await AppDatabase.openFile(file);
      final accountA = AccountId(await database.createAccount('synthetic-a'));
      final accountB = AccountId(await database.createAccount('synthetic-b'));
      var store = DatabaseReadSyncStore(database);
      final episode = RetryEpisode(
        startedAt: startedAt,
        deadlineAt: startedAt.add(const Duration(minutes: 5)),
        nextAttemptAt: startedAt.add(const Duration(seconds: 32)),
        serverNotBeforeAt: startedAt.add(const Duration(seconds: 30)),
        lastObservedAt: startedAt.add(const Duration(seconds: 8)),
        attemptCount: 5,
        automaticRetryExhausted: false,
      );
      await store.writeRetryEpisode(accountA, episode);
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      store = DatabaseReadSyncStore(database);

      final restored = await store.readRetryEpisode(accountA);
      expect(restored?.startedAt, episode.startedAt);
      expect(restored?.deadlineAt, episode.deadlineAt);
      expect(restored?.nextAttemptAt, episode.nextAttemptAt);
      expect(restored?.serverNotBeforeAt, episode.serverNotBeforeAt);
      expect(restored?.lastObservedAt, episode.lastObservedAt);
      expect(restored?.attemptCount, 5);
      expect(await store.readRetryEpisode(accountB), isNull);

      await store.clearRetryEpisode(accountA);
      expect(await store.readRetryEpisode(accountA), isNull);
    },
  );
}
