import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
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
      final account = AccountId(await database.createAccount('synthetic-task'));
      final list = await _putRemoteList(database, account, 'list');
      final repository = DatabaseTasksRepository(database, clock: clock);
      final snapshots = <CachedTasksSnapshot>[];
      final subscription = repository
          .watchTasks(TasksQuery(accountId: account))
          .listen(snapshots.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      final result = await repository.createTask(
        CreateTaskCommand(
          accountId: account,
          taskListId: list,
          title: '',
          notes: '保存された 🌍\n',
          due: TaskDate(2026, 8, 20),
        ),
      );
      await pumpEventQueue();

      final taskId = (result as Success<TaskId>).value;
      expect(snapshots.last.tasks.single.id, taskId);
      expect(snapshots.last.tasks.single.remoteId, isNull);
      expect(snapshots.last.tasks.single.notes, '保存された 🌍\n');
      final desired = await DesiredStateDao(database).readTask(account, taskId);
      expect(desired?.generation, 1);
      expect(desired?.taskListId, list);
      expect(desired?.due, TaskDate(2026, 8, 20));
      expect(desired?.state, DesiredStateLifecycle.pending);
      expect((await _workCounts(database, account)).pending, 1);
    },
  );

  test(
    'injected failures roll back task projection, intent, and stream',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-rollback'),
      );
      final list = await _putRemoteList(database, account, 'rollback-list');
      for (final failureBoundary in <DesiredStateTransactionBoundary>[
        DesiredStateTransactionBoundary.afterProjectionWrite,
        DesiredStateTransactionBoundary.afterDesiredStateWrite,
        DesiredStateTransactionBoundary.beforeLocalCommit,
      ]) {
        final repository = DatabaseTasksRepository(
          database,
          clock: clock,
          transactionControl: (boundary) {
            if (boundary == failureBoundary) {
              throw const DesiredStatePersistenceException('synthetic_failure');
            }
          },
        );
        final result = await repository.createTask(
          CreateTaskCommand(
            accountId: account,
            taskListId: list,
            title: 'Must roll back',
          ),
        );
        expect(
          (result as Failed<TaskId>).failure.code,
          'task.persistence_failed',
        );
        expect(
          (await repository.watchTasks(TasksQuery(accountId: account)).first)
              .tasks,
          isEmpty,
        );
        expect(await DesiredStateDao(database).countForAccount(account), 0);
      }
    },
  );

  test(
    'content edits coalesce as one whole desired record (DUR-003)',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-coalesce'),
      );
      final seeded = await _putRemoteTask(database, account);
      final repository = DatabaseTasksRepository(database, clock: clock);

      await repository.apply(
        SetTaskTitleCommand(
          accountId: account,
          taskId: seeded.task,
          title: 'Local title',
        ),
      );
      clock.advance(const Duration(seconds: 1));
      await repository.apply(
        SetTaskNotesCommand(accountId: account, taskId: seeded.task, notes: ''),
      );
      clock.advance(const Duration(seconds: 1));
      await repository.apply(
        SetTaskDueCommand(
          accountId: account,
          taskId: seeded.task,
          due: TaskDate(2026, 8, 25),
        ),
      );
      clock.advance(const Duration(seconds: 1));
      await repository.apply(
        SetTaskCompletionCommand(
          accountId: account,
          taskId: seeded.task,
          status: TaskStatus.completed,
        ),
      );

      final desired = await DesiredStateDao(
        database,
      ).readTask(account, seeded.task);
      expect(desired?.generation, 4);
      expect(desired?.title, 'Local title');
      expect(desired?.notes, '');
      expect(desired?.due, TaskDate(2026, 8, 25));
      expect(desired?.status, TaskStatus.completed);
      expect(desired?.baseTitle, 'Remote title');
      expect(await DesiredStateDao(database).countForAccount(account), 1);
      expect((await _workCounts(database, account)).pending, 1);
    },
  );

  test(
    'remote read advances base without erasing pending task content',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-pending-read'),
      );
      final seeded = await _putRemoteTask(database, account);
      final repository = DatabaseTasksRepository(database, clock: clock);
      await repository.apply(
        SetTaskTitleCommand(
          accountId: account,
          taskId: seeded.task,
          title: 'Local pending',
        ),
      );

      await DatabaseReadSyncStore(database).publishTaskPage(
        accountId: account,
        runId: const SyncRunId('read-after-task-edit'),
        taskList: PublishedTaskList(
          localId: seeded.list,
          remoteId: const RemoteTaskListId('remote-list'),
        ),
        items: <RemoteTask>[
          RemoteLiveTask(
            id: const RemoteTaskId('remote-task'),
            etag: 'etag-after',
            updated: DateTime.utc(2026, 8, 15, 11, 30),
            selfLink: null,
            title: 'Remote after',
            parentId: null,
            position: '0002',
            notes: 'Remote changed notes',
            status: RemoteTaskStatus.completed,
            due: const RemoteDate(2026, 8, 21),
            completed: DateTime.utc(2026, 8, 15, 11, 30),
            hidden: false,
            links: const <RemoteTaskLink>[],
            webViewLink: null,
          ),
        ],
        nextPageToken: null,
        collectionEtag: null,
      );

      final snapshot = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      final base = await CacheDao(
        database,
      ).readTaskRemoteBase(account, seeded.task);
      expect(snapshot.tasks.single.title, 'Local pending');
      expect(snapshot.tasks.single.notes, 'Remote notes');
      expect(snapshot.tasks.single.status, TaskStatus.needsAction);
      expect(base?.title, 'Remote after');
      expect(base?.notes, 'Remote changed notes');
      expect(base?.status, TaskStatus.completed);
    },
  );

  test(
    'claim snapshots a task generation and older acknowledgement is safe',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-claim'),
      );
      final list = await _putRemoteList(database, account, 'claim-list');
      final repository = DatabaseTasksRepository(database, clock: clock);
      final created = await repository.createTask(
        CreateTaskCommand(
          accountId: account,
          taskListId: list,
          title: 'Generation one',
        ),
      );
      final task = (created as Success<TaskId>).value;
      final dao = DesiredStateDao(database);
      final attempt = await dao.claimTask(
        accountId: account,
        taskId: task,
        claimedAt: clock.now(),
      );
      await repository.apply(
        SetTaskTitleCommand(
          accountId: account,
          taskId: task,
          title: 'Generation two',
        ),
      );
      await dao.acknowledgeTask(
        accountId: account,
        attemptId: attempt.id,
        remoteId: const TaskRemoteId('bound-task'),
        taskListId: list,
        parentTaskId: null,
        title: 'Generation one',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
        position: '0001',
        etag: 'etag-one',
        remoteUpdatedAt: clock.now(),
        observedPublicationId: 'ack-one',
        acknowledgedAt: clock.now(),
      );

      final current = await dao.readTask(account, task);
      expect(current?.generation, 2);
      expect(current?.title, 'Generation two');
      expect(current?.state, DesiredStateLifecycle.pending);
      expect(
        (await dao.readAttempt(account, attempt.id))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(
        (await CacheDao(database).readTaskRemoteBase(account, task))?.title,
        'Generation one',
      );
      final snapshot = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(snapshot.tasks.single.id, task);
      expect(snapshot.tasks.single.remoteId, const TaskRemoteId('bound-task'));
      expect(snapshot.tasks.single.title, 'Generation two');
    },
  );

  test(
    'remote task acknowledgement is atomic at every boundary (DUR-005/009)',
    () async {
      final account = AccountId(await database.createAccount('synthetic-ack'));
      final list = await _putRemoteList(database, account, 'ack-list');
      final repository = DatabaseTasksRepository(database, clock: clock);
      final task =
          (await repository.createTask(
                    CreateTaskCommand(
                      accountId: account,
                      taskListId: list,
                      title: 'Offline',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      final attempt = await DesiredStateDao(
        database,
      ).claimTask(accountId: account, taskId: task, claimedAt: clock.now());
      for (final boundary in <DesiredStateTransactionBoundary>[
        DesiredStateTransactionBoundary.afterRemoteIdentityWrite,
        DesiredStateTransactionBoundary.afterRemoteBaseWrite,
        DesiredStateTransactionBoundary.beforeRemoteCommit,
      ]) {
        final dao = DesiredStateDao(
          database,
          transactionControl: (value) {
            if (value == boundary) {
              throw const DesiredStatePersistenceException('ack_rollback');
            }
          },
        );
        await expectLater(
          dao.acknowledgeTask(
            accountId: account,
            attemptId: attempt.id,
            remoteId: const TaskRemoteId('atomic-task'),
            taskListId: list,
            parentTaskId: null,
            title: 'Canonical',
            notes: null,
            status: TaskStatus.needsAction,
            due: null,
            position: '0001',
            etag: 'etag-atomic',
            remoteUpdatedAt: clock.now(),
            observedPublicationId: 'atomic-publication',
            acknowledgedAt: clock.now(),
          ),
          throwsA(isA<DesiredStatePersistenceException>()),
        );
        expect(
          await CacheDao(database).readTaskRemoteBase(account, task),
          isNull,
        );
        expect(
          (await DesiredStateDao(database).readTask(account, task))?.state,
          DesiredStateLifecycle.inFlight,
        );
      }
    },
  );

  test('account and one-level hierarchy validation fail closed', () async {
    final accountA = AccountId(await database.createAccount('synthetic-a'));
    final accountB = AccountId(await database.createAccount('synthetic-b'));
    final seeded = await _putRemoteTask(database, accountA);
    final listB = await _putRemoteList(database, accountB, 'list-b');
    final repository = DatabaseTasksRepository(database, clock: clock);
    final child =
        (await repository.createTask(
                  CreateTaskCommand(
                    accountId: accountA,
                    taskListId: seeded.list,
                    parentTaskId: seeded.task,
                    title: 'Child',
                  ),
                )
                as Success<TaskId>)
            .value;

    final crossAccount = await repository.createTask(
      CreateTaskCommand(
        accountId: accountA,
        taskListId: listB,
        title: 'Wrong account',
      ),
    );
    final thirdLevel = await repository.createTask(
      CreateTaskCommand(
        accountId: accountA,
        taskListId: seeded.list,
        parentTaskId: child,
        title: 'Too deep',
      ),
    );
    expect(
      (crossAccount as Failed<TaskId>).failure.code,
      'task.task_list_not_found',
    );
    expect(
      (thirdLevel as Failed<TaskId>).failure.code,
      'task.unsupported_depth',
    );
  });

  test(
    'task attempt lifecycle compacts without losing newer work (DUR-006/007/011)',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-task-compact'),
      );
      final list = await _putRemoteList(database, account, 'compact-list');
      final repository = DatabaseTasksRepository(database, clock: clock);
      final task =
          (await repository.createTask(
                    CreateTaskCommand(
                      accountId: account,
                      taskListId: list,
                      title: 'First',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      final dao = DesiredStateDao(database);
      final attempt = await dao.claimTask(
        accountId: account,
        taskId: task,
        claimedAt: clock.now(),
      );
      expect(
        await repository.apply(
          SetTaskTitleCommand(
            accountId: account,
            taskId: task,
            title: 'While the request boundary is idle',
          ),
        ),
        isA<Success<void>>(),
      );
      await dao.transitionAttempt(
        accountId: account,
        attemptId: attempt.id,
        state: DesiredStateLifecycle.superseded,
        transitionedAt: clock.now(),
      );
      await expectLater(
        dao.transitionAttempt(
          accountId: account,
          attemptId: attempt.id,
          state: DesiredStateLifecycle.inFlight,
          transitionedAt: clock.now(),
        ),
        throwsA(isA<DesiredStateInvariantException>()),
      );

      expect(
        await dao.compactResolvedAttempts(
          accountId: account,
          resolvedBeforeOrAt: clock.now(),
        ),
        1,
      );
      expect(await dao.readAttempt(account, attempt.id), isNull);
      expect(
        (await dao.readTask(account, task))?.title,
        'While the request boundary is idle',
      );
      expect(
        (await dao.readTask(account, task))?.state,
        DesiredStateLifecycle.pending,
      );
      expect((await _workCounts(database, account)).pending, 1);
    },
  );

  test(
    'restart preserves provisional identity and pending whole content',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s14b-restart-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/offline.sqlite');
      await database.close();

      var reopened = await AppDatabase.openFile(file);
      final account = AccountId(
        await reopened.createAccount('synthetic-restart'),
      );
      final list = await _putRemoteList(reopened, account, 'restart-list');
      var repository = DatabaseTasksRepository(reopened, clock: clock);
      final task =
          (await repository.createTask(
                    CreateTaskCommand(
                      accountId: account,
                      taskListId: list,
                      title: 'First',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      await repository.apply(
        SetTaskNotesCommand(
          accountId: account,
          taskId: task,
          notes: 'After create',
        ),
      );
      await reopened.close();

      reopened = await AppDatabase.openFile(file);
      addTearDown(reopened.close);
      repository = DatabaseTasksRepository(reopened, clock: clock);
      final snapshot = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(snapshot.tasks.single.id, task);
      expect(snapshot.tasks.single.remoteId, isNull);
      expect(snapshot.tasks.single.notes, 'After create');
      expect(
        (await DesiredStateDao(reopened).readTask(account, task))?.generation,
        2,
      );
    },
  );
}

Future<TaskListId> _putRemoteList(
  AppDatabase database,
  AccountId account,
  String remoteId,
) => CacheDao(database).putTaskList(
  accountId: account,
  remoteId: TaskListRemoteId(remoteId),
  title: 'Synthetic list',
);

Future<({TaskListId list, TaskId task})> _putRemoteTask(
  AppDatabase database,
  AccountId account,
) async {
  final cache = CacheDao(database);
  final list = await _putRemoteList(database, account, 'remote-list');
  final task = await cache.putTask(
    accountId: account,
    taskListId: list,
    remoteId: const TaskRemoteId('remote-task'),
    title: 'Remote title',
    notes: 'Remote notes',
    position: '0001',
  );
  await cache.putTaskRemoteBase(
    accountId: account,
    taskId: task,
    taskListId: list,
    remoteId: const TaskRemoteId('remote-task'),
    observedPublicationId: 'remote-base',
    deleted: false,
    title: 'Remote title',
    notes: 'Remote notes',
    status: TaskStatus.needsAction,
    position: '0001',
    etag: 'etag-base',
    remoteUpdatedAt: DateTime.utc(2026, 8, 15, 11),
  );
  return (list: list, task: task);
}

Future<SyncWorkCounts> _workCounts(
  AppDatabase database,
  AccountId account,
) async => (await SyncHealthDao(database).watchFacts(account).first).counts;
