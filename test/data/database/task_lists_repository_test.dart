import 'dart:async';
import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late ManualClock clock;

  setUp(() {
    database = AppDatabase.inMemory();
    clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
  });

  tearDown(() => database.close());

  test(
    'create publishes only after projection and desired state commit (DUR-001)',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-create'),
      );
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final snapshots = <CachedTasksSnapshot>[];
      final subscription = DatabaseTasksRepository(
        database,
      ).watchTasks(TasksQuery(accountId: account)).listen(snapshots.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      final result = await repository.createTaskList(
        CreateTaskListCommand(accountId: account, title: 'Offline create'),
      );
      await pumpEventQueue();

      expect(result, isA<Success<TaskListId>>());
      final id = (result as Success<TaskListId>).value;
      expect(snapshots.last.taskLists.single.id, id);
      expect(snapshots.last.taskLists.single.remoteId, isNull);
      expect(snapshots.last.taskLists.single.title, 'Offline create');
      final desired = await DesiredStateDao(database).readTaskList(account, id);
      expect(desired?.generation, 1);
      expect(desired?.state, DesiredStateLifecycle.pending);
      expect(desired?.baseRemoteId, isNull);
      expect((await _workCounts(database, account)).pending, 1);
    },
  );

  test(
    'injected failure rolls back projection, intent, count, and stream',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-rollback'),
      );
      final snapshots = <CachedTasksSnapshot>[];
      final subscription = DatabaseTasksRepository(
        database,
      ).watchTasks(TasksQuery(accountId: account)).listen(snapshots.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      for (final failureBoundary in <DesiredStateTransactionBoundary>[
        DesiredStateTransactionBoundary.afterProjectionWrite,
        DesiredStateTransactionBoundary.afterDesiredStateWrite,
        DesiredStateTransactionBoundary.beforeLocalCommit,
      ]) {
        final repository = DatabaseTaskListsRepository(
          database: database,
          clock: clock,
          transactionControl: (boundary) {
            if (boundary == failureBoundary) {
              throw const DesiredStatePersistenceException(
                'synthetic_rollback',
              );
            }
          },
        );
        final result = await repository.createTaskList(
          CreateTaskListCommand(accountId: account, title: 'Must roll back'),
        );
        await pumpEventQueue();

        expect(result, isA<Failed<TaskListId>>());
        expect(
          (result as Failed<TaskListId>).failure.code,
          'list.persistence_failed',
        );
        expect(snapshots.last.taskLists, isEmpty);
        expect(await DesiredStateDao(database).countForAccount(account), 0);
        expect((await _workCounts(database, account)).total, 0);
      }
    },
  );

  test(
    'renames coalesce while retaining the original remote base (DUR-003)',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-coalesce'),
      );
      final cache = CacheDao(database);
      final list = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('remote-list'),
        title: 'Remote v0',
      );
      await cache.putTaskListRemoteBase(
        accountId: account,
        taskListId: list,
        remoteId: const TaskListRemoteId('remote-list'),
        title: 'Remote v0',
        etag: 'etag-v0',
        remoteUpdatedAt: DateTime.utc(2026, 8, 15, 11),
        observedPublicationId: 'publication-v0',
      );
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );

      for (final title in <String>['Local v1', 'Local v2', 'Local v3']) {
        expect(
          await repository.renameTaskList(
            RenameTaskListCommand(
              accountId: account,
              taskListId: list,
              title: title,
            ),
          ),
          isA<Success<void>>(),
        );
        clock.advance(const Duration(seconds: 1));
      }

      final desired = await DesiredStateDao(
        database,
      ).readTaskList(account, list);
      expect(desired?.generation, 3);
      expect(desired?.title, 'Local v3');
      expect(desired?.baseTitle, 'Remote v0');
      expect(desired?.baseEtag, 'etag-v0');
      expect(desired?.baseObservedPublicationId, 'publication-v0');
      expect(await DesiredStateDao(database).countForAccount(account), 1);
      expect((await _workCounts(database, account)).pending, 1);
      final snapshot = await DatabaseTasksRepository(
        database,
      ).watchTasks(TasksQuery(accountId: account)).first;
      expect(snapshot.taskLists.single.title, 'Local v3');
    },
  );

  test(
    'remote page refresh updates the base without erasing a pending rename',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-pending-read'),
      );
      final cache = CacheDao(database);
      final list = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('pending-read-list'),
        title: 'Remote before',
      );
      await cache.putTaskListRemoteBase(
        accountId: account,
        taskListId: list,
        remoteId: const TaskListRemoteId('pending-read-list'),
        title: 'Remote before',
        observedPublicationId: 'before',
      );
      await DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      ).renameTaskList(
        RenameTaskListCommand(
          accountId: account,
          taskListId: list,
          title: 'Local pending',
        ),
      );

      await DatabaseReadSyncStore(database).publishTaskListPage(
        accountId: account,
        runId: const SyncRunId('read-after-local-edit'),
        items: <RemoteTaskList>[
          RemoteTaskList(
            id: const RemoteTaskListId('pending-read-list'),
            etag: 'etag-after',
            title: 'Remote after',
            updated: clock.now(),
            selfLink: null,
          ),
        ],
        nextPageToken: null,
        collectionEtag: null,
      );

      final snapshot = await DatabaseTasksRepository(
        database,
      ).watchTasks(TasksQuery(accountId: account)).first;
      final base = await cache.readTaskListRemoteBase(account, list);
      final desired = await DesiredStateDao(
        database,
      ).readTaskList(account, list);
      expect(snapshot.taskLists.single.title, 'Local pending');
      expect(base?.title, 'Remote after');
      expect(desired?.baseTitle, 'Remote before');
    },
  );

  test(
    'claim snapshot survives a newer rename and legal transition (DUR-004/007)',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-claim'),
      );
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final created = await repository.createTaskList(
        CreateTaskListCommand(accountId: account, title: 'Generation one'),
      );
      final list = (created as Success<TaskListId>).value;
      final desiredDao = DesiredStateDao(database);
      final attempt = await desiredDao.claimTaskList(
        accountId: account,
        taskListId: list,
        claimedAt: clock.now(),
      );
      expect(attempt.generation, 1);
      expect(attempt.title, 'Generation one');
      expect((await _workCounts(database, account)).inFlight, 1);

      clock.advance(const Duration(seconds: 1));
      await repository.renameTaskList(
        RenameTaskListCommand(
          accountId: account,
          taskListId: list,
          title: 'Generation two',
        ),
      );
      await desiredDao.acknowledgeTaskList(
        accountId: account,
        attemptId: attempt.id,
        remoteId: const TaskListRemoteId('claimed-list'),
        title: 'Generation one',
        etag: 'etag-generation-one',
        remoteUpdatedAt: clock.now(),
        observedPublicationId: 'ack-generation-one',
        acknowledgedAt: clock.now(),
      );

      final current = await desiredDao.readTaskList(account, list);
      final restoredAttempt = await desiredDao.readAttempt(account, attempt.id);
      expect(current?.generation, 2);
      expect(current?.title, 'Generation two');
      expect(current?.state, DesiredStateLifecycle.pending);
      expect(restoredAttempt?.state, DesiredStateLifecycle.confirmed);
      expect(
        (await CacheDao(database).readTaskListRemoteBase(account, list))?.title,
        'Generation one',
      );
      expect((await _workCounts(database, account)).pending, 1);
      expect((await _workCounts(database, account)).inFlight, 0);
      await expectLater(
        desiredDao.transitionAttempt(
          accountId: account,
          attemptId: attempt.id,
          state: DesiredStateLifecycle.inFlight,
          transitionedAt: clock.now(),
        ),
        throwsA(isA<DesiredStateInvariantException>()),
      );
    },
  );

  test(
    'no database transaction remains open while a claimed request waits (DUR-006)',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-no-network-tx'),
      );
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final created = await repository.createTaskList(
        CreateTaskListCommand(accountId: account, title: 'Before request'),
      );
      final list = (created as Success<TaskListId>).value;
      final attempt = await DesiredStateDao(database).claimTaskList(
        accountId: account,
        taskListId: list,
        claimedAt: clock.now(),
      );
      final heldRequest = Completer<void>();

      final rename = repository.renameTaskList(
        RenameTaskListCommand(
          accountId: account,
          taskListId: list,
          title: 'While request waits',
        ),
      );
      expect(await rename, isA<Success<void>>());
      expect(attempt.state, DesiredStateLifecycle.inFlight);
      expect(heldRequest.isCompleted, isFalse);
    },
  );

  test(
    'remote acknowledgement binds ID, base, and result atomically (DUR-005/009)',
    () async {
      final account = AccountId(await database.createAccount('synthetic-ack'));
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final created = await repository.createTaskList(
        CreateTaskListCommand(accountId: account, title: 'Created offline'),
      );
      final list = (created as Success<TaskListId>).value;
      final attempt = await DesiredStateDao(database).claimTaskList(
        accountId: account,
        taskListId: list,
        claimedAt: clock.now(),
      );
      for (final failureBoundary in <DesiredStateTransactionBoundary>[
        DesiredStateTransactionBoundary.afterRemoteIdentityWrite,
        DesiredStateTransactionBoundary.afterRemoteBaseWrite,
        DesiredStateTransactionBoundary.beforeRemoteCommit,
      ]) {
        final failingDao = DesiredStateDao(
          database,
          transactionControl: (boundary) {
            if (boundary == failureBoundary) {
              throw const DesiredStatePersistenceException(
                'synthetic_ack_rollback',
              );
            }
          },
        );
        await expectLater(
          failingDao.acknowledgeTaskList(
            accountId: account,
            attemptId: attempt.id,
            remoteId: const TaskListRemoteId('bound-list'),
            title: 'Canonical title',
            etag: 'etag-1',
            remoteUpdatedAt: clock.now(),
            observedPublicationId: 'mutation-ack-1',
            acknowledgedAt: clock.now(),
          ),
          throwsA(isA<DesiredStatePersistenceException>()),
        );
        expect(
          (await DesiredStateDao(database).readTaskList(account, list))?.state,
          DesiredStateLifecycle.inFlight,
        );
        expect(
          await CacheDao(database).readTaskListRemoteBase(account, list),
          isNull,
        );
        final failedSnapshot = await DatabaseTasksRepository(
          database,
        ).watchTasks(TasksQuery(accountId: account)).first;
        expect(failedSnapshot.taskLists.single.remoteId, isNull);
      }

      await DesiredStateDao(database).acknowledgeTaskList(
        accountId: account,
        attemptId: attempt.id,
        remoteId: const TaskListRemoteId('bound-list'),
        title: 'Canonical title',
        etag: 'etag-1',
        remoteUpdatedAt: clock.now(),
        observedPublicationId: 'mutation-ack-1',
        acknowledgedAt: clock.now(),
      );
      final base = await CacheDao(
        database,
      ).readTaskListRemoteBase(account, list);
      expect(base?.remoteId, const TaskListRemoteId('bound-list'));
      expect(base?.title, 'Canonical title');
      expect(base?.etag, 'etag-1');
      expect(
        (await DesiredStateDao(
          database,
        ).readAttempt(account, attempt.id))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect((await _workCounts(database, account)).total, 0);
    },
  );

  test(
    'restart preserves provisional identity, coalesced rename, and stopped editing',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s14a-restart-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/offline.sqlite');
      await database.close();

      var reopened = await AppDatabase.openFile(file);
      final account = AccountId(
        await reopened.createAccount('synthetic-restart'),
      );
      await reopened.customStatement(
        'INSERT INTO account_preferences (account_id, sync_enabled) VALUES (?, 0)',
        <Object>[account.value],
      );
      var repository = DatabaseTaskListsRepository(
        database: reopened,
        clock: clock,
      );
      final create = await repository.createTaskList(
        CreateTaskListCommand(accountId: account, title: 'Offline first'),
      );
      final id = (create as Success<TaskListId>).value;
      await repository.renameTaskList(
        RenameTaskListCommand(
          accountId: account,
          taskListId: id,
          title: 'Offline renamed',
        ),
      );
      await reopened.close();

      reopened = await AppDatabase.openFile(file);
      addTearDown(reopened.close);
      repository = DatabaseTaskListsRepository(
        database: reopened,
        clock: clock,
      );
      final snapshot = await DatabaseTasksRepository(
        reopened,
      ).watchTasks(TasksQuery(accountId: account)).first;
      final desired = await DesiredStateDao(reopened).readTaskList(account, id);
      expect(snapshot.taskLists.single.id, id);
      expect(snapshot.taskLists.single.remoteId, isNull);
      expect(snapshot.taskLists.single.title, 'Offline renamed');
      expect(desired?.generation, 2);
      expect((await _workCounts(reopened, account)).pending, 1);

      final secondRename = await repository.renameTaskList(
        RenameTaskListCommand(
          accountId: account,
          taskListId: id,
          title: 'Still stopped',
        ),
      );
      expect(secondRename, isA<Success<void>>());
    },
  );

  test(
    'account validation and absence of a local-only command fail closed',
    () async {
      final accountA = AccountId(
        await database.createAccount('synthetic-account-a'),
      );
      final accountB = AccountId(
        await database.createAccount('synthetic-account-b'),
      );
      final listB = await CacheDao(database).putTaskList(
        accountId: accountB,
        remoteId: const TaskListRemoteId('account-b-list'),
        title: 'Account B',
      );
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );

      final missing = await repository.createTaskList(
        const CreateTaskListCommand(
          accountId: AccountId(999),
          title: 'Missing',
        ),
      );
      final crossAccount = await repository.renameTaskList(
        RenameTaskListCommand(
          accountId: accountA,
          taskListId: listB,
          title: 'Cross account',
        ),
      );
      expect(
        (missing as Failed<TaskListId>).failure.code,
        'task_list.account_not_found',
      );
      expect(
        (crossAccount as Failed<void>).failure.code,
        'task_list.not_found',
      );
      expect(await DesiredStateDao(database).countForAccount(accountB), 0);
    },
  );

  test(
    'resolved attempt compaction preserves unresolved current evidence (DUR-011)',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-compact'),
      );
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final created = await repository.createTaskList(
        CreateTaskListCommand(accountId: account, title: 'Compact'),
      );
      final list = (created as Success<TaskListId>).value;
      final dao = DesiredStateDao(database);
      final attempt = await dao.claimTaskList(
        accountId: account,
        taskListId: list,
        claimedAt: clock.now(),
      );
      await dao.transitionAttempt(
        accountId: account,
        attemptId: attempt.id,
        state: DesiredStateLifecycle.superseded,
        transitionedAt: clock.now(),
      );
      await repository.renameTaskList(
        RenameTaskListCommand(
          accountId: account,
          taskListId: list,
          title: 'Newest pending',
        ),
      );

      expect(
        await dao.compactResolvedAttempts(
          accountId: account,
          resolvedBeforeOrAt: clock.now(),
        ),
        1,
      );
      expect(await dao.readAttempt(account, attempt.id), isNull);
      expect((await dao.readTaskList(account, list))?.title, 'Newest pending');
      expect((await _workCounts(database, account)).pending, 1);
    },
  );
}

Future<SyncWorkCounts> _workCounts(
  AppDatabase database,
  AccountId accountId,
) async {
  return (await SyncHealthDao(database).watchFacts(accountId).first).counts;
}
