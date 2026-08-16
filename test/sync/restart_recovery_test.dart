import 'dart:io';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/retry/retry_episode.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_clock.dart';

void main() {
  final startedAt = DateTime.utc(2026, 8, 15, 12);

  test(
    'CRS-001/002 committed local work reopens without an exit callback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-recovery-local-commit-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/synthetic.sqlite');
      final clock = FakeClock(startedAt);
      var database = await AppDatabase.openFile(file);
      final account = AccountId(
        await database.createAccount('synthetic-local'),
      );

      final failedRepository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
        transactionControl: (boundary) {
          if (boundary == DesiredStateTransactionBoundary.beforeLocalCommit) {
            throw const DesiredStatePersistenceException('synthetic_rollback');
          }
        },
      );
      expect(
        await failedRepository.createTaskList(
          CreateTaskListCommand(accountId: account, title: 'Not committed'),
        ),
        isA<Failed<TaskListId>>(),
      );
      expect(await _count(database, 'task_lists', account), 0);
      expect(await _count(database, 'desired_states', account), 0);

      final committed =
          await DatabaseTaskListsRepository(
            database: database,
            clock: clock,
          ).createTaskList(
            CreateTaskListCommand(accountId: account, title: 'Committed'),
          );
      expect(committed, isA<Success<TaskListId>>());
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      final desired = await DesiredStateDao(
        database,
      ).readTaskList(account, (committed as Success<TaskListId>).value);
      expect(desired?.state, DesiredStateLifecycle.pending);
      expect(
        (await SyncHealthDao(
          database,
        ).watchFacts(account).first).counts.pending,
        1,
      );
    },
  );

  test(
    'CRS-003/008-011 startup interrupts a partial run exactly once',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-recovery-partial-run-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/synthetic.sqlite');
      var database = await AppDatabase.openFile(file);
      final account = AccountId(await database.createAccount('synthetic-run'));
      var store = DatabaseReadSyncStore(database);
      const abandoned = SyncRunId('synthetic-abandoned-run');
      await store.beginReadRun(
        accountId: account,
        runId: abandoned,
        triggers: const <String>{'startup'},
        startedAt: startedAt,
      );
      await store.publishTaskListPage(
        accountId: account,
        runId: abandoned,
        items: const [],
        nextPageToken: const PageToken('unreached-page'),
        collectionEtag: 'synthetic-etag',
      );
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      store = DatabaseReadSyncStore(database);
      final first = await store.recoverStartup(
        accountId: account,
        recoveredAt: startedAt.add(const Duration(minutes: 1)),
      );
      final second = await store.recoverStartup(
        accountId: account,
        recoveredAt: startedAt.add(const Duration(minutes: 2)),
      );

      expect(first.interruptedRuns, 1);
      expect(first.recoveredAttempts, 0);
      expect(second.interruptedRuns, 0);
      expect(second.recoveredAttempts, 0);
      expect(await _runState(database, account, abandoned), 'interrupted');
      final facts = await SyncHealthDao(database).watchFacts(account).first;
      expect(facts.lastSuccessfulSyncAt, isNull);
      expect(facts.requiredScopeIncomplete, isTrue);
      expect(facts.followUpRequired, isTrue);
      expect(await _scopeToken(database, account, abandoned), 'unreached-page');
    },
  );

  test(
    'CRS-004-007/011 recovery is atomic and preserves generations and latches',
    () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final account = AccountId(
        await database.createAccount('synthetic-attempt-recovery'),
      );
      final clock = FakeClock(startedAt);
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final desired = DesiredStateDao(database);

      final createList =
          (await repository.createTaskList(
                    CreateTaskListCommand(
                      accountId: account,
                      title: 'Create generation 1',
                    ),
                  )
                  as Success<TaskListId>)
              .value;
      final createAttempt = await desired.claimTaskList(
        accountId: account,
        taskListId: createList,
        claimedAt: clock.now(),
      );
      clock.advance(const Duration(seconds: 1));
      await repository.renameTaskList(
        RenameTaskListCommand(
          accountId: account,
          taskListId: createList,
          title: 'Create generation 2',
        ),
      );

      final updateList = await _putRemoteList(database, account, 'update-list');
      await repository.renameTaskList(
        RenameTaskListCommand(
          accountId: account,
          taskListId: updateList,
          title: 'Update generation',
        ),
      );
      final updateAttempt = await desired.claimTaskList(
        accountId: account,
        taskListId: updateList,
        claimedAt: clock.now(),
      );

      final deleteList = await _putRemoteList(database, account, 'delete-list');
      await repository.deleteTaskList(
        DeleteTaskListCommand(accountId: account, taskListId: deleteList),
      );
      final deleteAttempt = await desired.claimTaskList(
        accountId: account,
        taskListId: deleteList,
        claimedAt: clock.now(),
      );

      var store = DatabaseReadSyncStore(database);
      await store.requireReauthorization(account);
      final episode = RetryEpisode(
        startedAt: startedAt,
        deadlineAt: startedAt.add(const Duration(minutes: 5)),
        lastObservedAt: startedAt.add(const Duration(minutes: 5)),
        attemptCount: 9,
        automaticRetryExhausted: true,
      );
      await store.writeRetryEpisode(account, episode);

      store = DatabaseReadSyncStore(
        database,
        recoveryTransactionControl: (boundary) {
          if (boundary == SyncRecoveryTransactionBoundary.beforeCommit) {
            throw const SyncRecoveryPersistenceException(
              'synthetic_recovery_rollback',
            );
          }
        },
      );
      await expectLater(
        store.recoverStartup(
          accountId: account,
          recoveredAt: startedAt.add(const Duration(minutes: 1)),
        ),
        throwsA(isA<SyncRecoveryPersistenceException>()),
      );
      expect(
        (await desired.readAttempt(account, createAttempt.id))?.state,
        DesiredStateLifecycle.inFlight,
      );
      expect(
        (await desired.readAttempt(account, updateAttempt.id))?.state,
        DesiredStateLifecycle.inFlight,
      );
      expect(
        (await desired.readAttempt(account, deleteAttempt.id))?.state,
        DesiredStateLifecycle.inFlight,
      );

      final recoveredAt = startedAt.add(const Duration(minutes: 2));
      final recovered = await DatabaseReadSyncStore(
        database,
      ).recoverStartup(accountId: account, recoveredAt: recoveredAt);
      expect(recovered.recoveredAttempts, 3);
      expect(recovered.recoverableCreateAttemptIds, <int>[createAttempt.id]);
      expect(await _attemptEvidence(database, account), <int, List<Object?>>{
        createAttempt.id: <Object?>['uncertain', 'sync.create_interrupted'],
        updateAttempt.id: <Object?>['uncertain', 'sync.update_interrupted'],
        deleteAttempt.id: <Object?>['uncertain', 'sync.delete_interrupted'],
      });
      final newestCreate = await desired.readTaskList(account, createList);
      expect(newestCreate?.generation, 2);
      expect(newestCreate?.state, DesiredStateLifecycle.pending);
      expect(newestCreate?.title, 'Create generation 2');
      expect(await store.readReauthorizationRequired(account), isTrue);
      final restoredEpisode = await store.readRetryEpisode(account);
      expect(restoredEpisode?.startedAt, episode.startedAt);
      expect(restoredEpisode?.deadlineAt, episode.deadlineAt);
      expect(restoredEpisode?.attemptCount, episode.attemptCount);
      expect(restoredEpisode?.automaticRetryExhausted, isTrue);

      final repeated = await DatabaseReadSyncStore(database).recoverStartup(
        accountId: account,
        recoveredAt: startedAt.add(const Duration(minutes: 3)),
      );
      expect(repeated.recoveredAttempts, 0);
      expect(
        (await desired.readAttempt(
          account,
          createAttempt.id,
        ))?.lastTransitionAt,
        recoveredAt,
      );
    },
  );

  test('RUN-014 stale finalizers cannot overwrite the active run', () async {
    final database = AppDatabase.inMemory();
    addTearDown(database.close);
    final account = AccountId(await database.createAccount('synthetic-stale'));
    final store = DatabaseReadSyncStore(database);
    const older = SyncRunId('synthetic-older-run');
    const newer = SyncRunId('synthetic-newer-run');
    await _beginCompleteEmptyRun(store, account, older, startedAt);
    await _beginCompleteEmptyRun(
      store,
      account,
      newer,
      startedAt.add(const Duration(minutes: 1)),
    );

    expect(
      await store.finalizeReadSuccess(
        accountId: account,
        runId: older,
        completedAt: startedAt.add(const Duration(minutes: 2)),
      ),
      isFalse,
    );
    expect(
      (await SyncHealthDao(
        database,
      ).watchFacts(account).first).lastSuccessfulSyncAt,
      isNull,
    );
    expect(await _runState(database, account, older), 'interrupted');
    expect(await _runState(database, account, newer), 'in_progress');

    expect(
      await store.finalizeReadSuccess(
        accountId: account,
        runId: newer,
        completedAt: startedAt.add(const Duration(minutes: 3)),
      ),
      isTrue,
    );
    expect(
      (await SyncHealthDao(
        database,
      ).watchFacts(account).first).lastSuccessfulSyncAt,
      startedAt.add(const Duration(minutes: 3)),
    );
    expect(
      await store.finalizeReadFailure(
        accountId: account,
        runId: older,
        failedAt: startedAt.add(const Duration(minutes: 4)),
        failure: const Failure(
          code: 'synthetic.stale_failure',
          category: FailureCategory.internal,
          retry: RetryClassification.permanent,
          operation: FailureOperation.synchronize,
          impact: 'Synthetic only.',
          safeSummary: 'Synthetic only.',
        ),
      ),
      isFalse,
    );
    expect(
      (await SyncHealthDao(database).watchFacts(account).first).latestFailure,
      isNull,
    );
  });
}

Future<void> _beginCompleteEmptyRun(
  DatabaseReadSyncStore store,
  AccountId account,
  SyncRunId runId,
  DateTime startedAt,
) async {
  await store.beginReadRun(
    accountId: account,
    runId: runId,
    triggers: const <String>{'synthetic'},
    startedAt: startedAt,
  );
  await store.publishTaskListPage(
    accountId: account,
    runId: runId,
    items: const [],
    nextPageToken: null,
    collectionEtag: null,
  );
}

Future<TaskListId> _putRemoteList(
  AppDatabase database,
  AccountId account,
  String remoteValue,
) async {
  final cache = CacheDao(database);
  final remoteId = TaskListRemoteId(remoteValue);
  final id = await cache.putTaskList(
    accountId: account,
    remoteId: remoteId,
    title: '$remoteValue base',
  );
  await cache.putTaskListRemoteBase(
    accountId: account,
    taskListId: id,
    remoteId: remoteId,
    title: '$remoteValue base',
    etag: 'etag-$remoteValue',
    remoteUpdatedAt: DateTime.utc(2026, 8, 15, 11),
    observedPublicationId: 'seed-$remoteValue',
  );
  return id;
}

Future<int> _count(
  AppDatabase database,
  String table,
  AccountId account,
) async {
  final row = await database
      .customSelect(
        'SELECT COUNT(*) AS count FROM $table WHERE account_id = ?',
        variables: <Variable<Object>>[Variable<int>(account.value)],
      )
      .getSingle();
  return row.read<int>('count');
}

Future<String?> _runState(
  AppDatabase database,
  AccountId account,
  SyncRunId runId,
) async =>
    (await database
            .customSelect(
              'SELECT state FROM sync_runs WHERE account_id = ? AND run_id = ?',
              variables: <Variable<Object>>[
                Variable<int>(account.value),
                Variable<String>(runId.value),
              ],
            )
            .getSingleOrNull())
        ?.read<String>('state');

Future<String?> _scopeToken(
  AppDatabase database,
  AccountId account,
  SyncRunId runId,
) async =>
    (await database
            .customSelect(
              'SELECT next_page_token FROM scope_completeness '
              'WHERE account_id = ? AND publication_id = ?',
              variables: <Variable<Object>>[
                Variable<int>(account.value),
                Variable<String>(runId.value),
              ],
            )
            .getSingle())
        .readNullable<String>('next_page_token');

Future<Map<int, List<Object?>>> _attemptEvidence(
  AppDatabase database,
  AccountId account,
) async {
  final rows = await database
      .customSelect(
        'SELECT id, state, failure_code FROM desired_state_attempts '
        'WHERE account_id = ? ORDER BY id',
        variables: <Variable<Object>>[Variable<int>(account.value)],
      )
      .get();
  return <int, List<Object?>>{
    for (final row in rows)
      row.read<int>('id'): <Object?>[
        row.read<String>('state'),
        row.readNullable<String>('failure_code'),
      ],
  };
}
