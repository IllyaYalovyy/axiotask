import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/sync_health_repository.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sync facts survive close/reopen and remain account scoped', () async {
    final directory = await Directory.systemTemp.createTemp(
      'axiotask-synthetic-health-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/synthetic.sqlite');
    final recordedAt = DateTime.utc(2026, 8, 15, 12);

    var database = await AppDatabase.openFile(file);
    final accountA = AccountId(await database.createAccount('synthetic-a'));
    final accountB = AccountId(await database.createAccount('synthetic-b'));
    var dao = SyncHealthDao(database);
    await dao.writeFacts(
      accountA,
      PersistedSyncFacts(
        lastSuccessfulSyncAt: recordedAt,
        latestFailure: SyncFailureFact(
          reason: SyncFailureReason.remoteFailure,
          occurredAt: recordedAt.add(const Duration(minutes: 1)),
          diagnosticCode: 'sync.remote.synthetic',
          action: SyncHealthAction.retry,
        ),
        counts: const SyncWorkCounts(
          pending: 2,
          inFlight: 1,
          uncertain: 3,
          failed: 4,
        ),
        retryWaiting: true,
        requiredScopeIncomplete: true,
      ),
    );
    await database.close();

    database = await AppDatabase.openFile(file);
    addTearDown(database.close);
    dao = SyncHealthDao(database);

    final restored = await dao.watchFacts(accountA).first;
    final other = await dao.watchFacts(accountB).first;
    expect(restored.lastSuccessfulSyncAt, recordedAt);
    expect(restored.latestFailure?.diagnosticCode, 'sync.remote.synthetic');
    expect(
      restored.counts,
      const SyncWorkCounts(pending: 2, inFlight: 1, uncertain: 3, failed: 4),
    );
    expect(restored.retryWaiting, isTrue);
    expect(restored.requiredScopeIncomplete, isTrue);
    expect(other, const PersistedSyncFacts());
  });

  test(
    'account sync-enabled preference participates in persisted facts',
    () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final account = AccountId(await database.createAccount('synthetic-stop'));
      final dao = SyncHealthDao(database);

      await dao.writeFacts(
        account,
        const PersistedSyncFacts(syncEnabled: false),
      );

      expect((await dao.watchFacts(account).first).syncEnabled, isFalse);
    },
  );

  test(
    'startup verification prevents recent cache from becoming Good',
    () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final account = AccountId(
        await database.createAccount('synthetic-startup'),
      );
      final dao = SyncHealthDao(database);
      final now = DateTime.utc(2026, 8, 15, 12);
      await dao.writeFacts(
        account,
        PersistedSyncFacts(
          lastSuccessfulSyncAt: now.subtract(const Duration(minutes: 1)),
        ),
      );
      final repository = DatabaseSyncHealthRepository(
        dao: dao,
        clock: ManualClock(now),
        runtime: const StaticSyncRuntimeFactsSource(
          SyncRuntimeFacts(
            authorization: SyncAuthorization.usable,
            verificationRequired: true,
          ),
        ),
      );

      final health = await repository.watchHealth(account).first;

      expect(health.outcome, SyncHealthOutcome.pending);
      expect(health.pendingReason, SyncPendingReason.verifying);
    },
  );

  test('a durable local list edit prevents Good immediately', () async {
    final database = AppDatabase.inMemory();
    addTearDown(database.close);
    final account = AccountId(
      await database.createAccount('synthetic-local-health'),
    );
    final now = DateTime.utc(2026, 8, 15, 12);
    final clock = ManualClock(now);
    final dao = SyncHealthDao(database);
    await dao.writeFacts(
      account,
      PersistedSyncFacts(
        lastSuccessfulSyncAt: now.subtract(const Duration(minutes: 1)),
      ),
    );
    final repository = DatabaseSyncHealthRepository(
      dao: dao,
      clock: clock,
      runtime: const StaticSyncRuntimeFactsSource(
        SyncRuntimeFacts(authorization: SyncAuthorization.usable),
      ),
    );
    expect(
      (await repository.watchHealth(account).first).outcome,
      SyncHealthOutcome.good,
    );

    await DatabaseTaskListsRepository(
      database: database,
      clock: clock,
    ).createTaskList(
      CreateTaskListCommand(accountId: account, title: 'Pending locally'),
    );
    final health = await repository.watchHealth(account).first;

    expect(health.outcome, SyncHealthOutcome.pending);
    expect(health.pendingReason, SyncPendingReason.localChanges);
    expect(health.counts.pending, 1);
  });
}
