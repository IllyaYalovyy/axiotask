import 'dart:io';

import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:drift/native.dart' show SqliteException;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late CacheDao cache;
  late DatabaseTasksRepository repository;

  setUp(() {
    database = AppDatabase.inMemory();
    cache = CacheDao(database);
    repository = DatabaseTasksRepository(database);
  });

  tearDown(() => database.close());

  test('queries and remote-id uniqueness stay inside an account', () async {
    final accountA = AccountId(await database.createAccount('synthetic-a'));
    final accountB = AccountId(await database.createAccount('synthetic-b'));
    final listA = await cache.putTaskList(
      accountId: accountA,
      remoteId: const TaskListRemoteId('remote-list'),
      title: 'Account A',
    );
    final listB = await cache.putTaskList(
      accountId: accountB,
      remoteId: const TaskListRemoteId('remote-list'),
      title: 'Account B',
    );
    await cache.putTask(
      accountId: accountA,
      taskListId: listA,
      remoteId: const TaskRemoteId('remote-task'),
      title: 'Only A',
      position: '0001',
    );
    await cache.putTask(
      accountId: accountB,
      taskListId: listB,
      remoteId: const TaskRemoteId('remote-task'),
      title: 'Only B',
      position: '0001',
    );

    final snapshot = await repository
        .watchTasks(TasksQuery(accountId: accountA))
        .first;
    expect(snapshot.taskLists.map((value) => value.title), <String>[
      'Account A',
    ]);
    expect(snapshot.tasks.map((value) => value.title), <String>['Only A']);

    expect(
      cache.putTask(
        accountId: accountA,
        taskListId: listA,
        remoteId: const TaskRemoteId('remote-task'),
        title: 'Duplicate',
        position: '0002',
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test(
    'nullable remote IDs are preserved but never projected as local-only',
    () async {
      final account = AccountId(await database.createAccount('synthetic-null'));
      final provisional = await cache.putTaskList(
        accountId: account,
        remoteId: null,
        title: 'Provisional',
      );
      final visible = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('visible-list'),
        title: 'Visible',
      );
      await cache.putTask(
        accountId: account,
        taskListId: visible,
        remoteId: null,
        title: 'Provisional task',
        position: '0001',
      );

      final before = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(before.taskLists.map((value) => value.id), <TaskListId>[visible]);
      expect(before.tasks, isEmpty);
      expect(await cache.countStoredTaskLists(account), 2);

      await cache.bindTaskListRemoteId(
        accountId: account,
        taskListId: provisional,
        remoteId: const TaskListRemoteId('bound-list'),
      );
      final after = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(after.taskLists.map((value) => value.id), contains(provisional));
    },
  );

  test(
    'foreign keys enforce account, list, and one-level parent scope',
    () async {
      final accountA = AccountId(
        await database.createAccount('synthetic-fk-a'),
      );
      final accountB = AccountId(
        await database.createAccount('synthetic-fk-b'),
      );
      final listA = await cache.putTaskList(
        accountId: accountA,
        remoteId: const TaskListRemoteId('list-a'),
        title: 'A',
      );
      final listB = await cache.putTaskList(
        accountId: accountB,
        remoteId: const TaskListRemoteId('list-b'),
        title: 'B',
      );
      final parent = await cache.putTask(
        accountId: accountA,
        taskListId: listA,
        remoteId: const TaskRemoteId('parent'),
        title: 'Parent',
        position: '0001',
      );
      final child = await cache.putTask(
        accountId: accountA,
        taskListId: listA,
        parentTaskId: parent,
        remoteId: const TaskRemoteId('child'),
        title: 'Child',
        position: '0002',
      );

      expect(
        cache.putTask(
          accountId: accountB,
          taskListId: listB,
          parentTaskId: parent,
          remoteId: const TaskRemoteId('cross-account'),
          title: 'Invalid',
          position: '0002',
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(
        cache.putTask(
          accountId: accountA,
          taskListId: listA,
          parentTaskId: child,
          remoteId: const TaskRemoteId('third-level'),
          title: 'Invalid',
          position: '0003',
        ),
        throwsA(isA<CacheInvariantException>()),
      );
    },
  );

  test('a failed cache transaction publishes and retains nothing', () async {
    final account = AccountId(
      await database.createAccount('synthetic-rollback'),
    );
    final emissions = <CachedTasksSnapshot>[];
    final subscription = repository
        .watchTasks(TasksQuery(accountId: account))
        .listen(emissions.add);
    addTearDown(subscription.cancel);
    await pumpEventQueue();

    await expectLater(
      cache.transaction(() async {
        await cache.putTaskList(
          accountId: account,
          remoteId: const TaskListRemoteId('rolled-back'),
          title: 'Rolled back',
        );
        throw const _RollbackProbe();
      }),
      throwsA(isA<_RollbackProbe>()),
    );
    await pumpEventQueue();

    expect(emissions, isNotEmpty);
    expect(emissions.every((snapshot) => snapshot.taskLists.isEmpty), isTrue);
    expect(await cache.countStoredTaskLists(account), 0);
  });

  test(
    'streams publish committed supported rows and preserve unsupported rows',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-stream'),
      );
      final emissions = <CachedTasksSnapshot>[];
      final subscription = repository
          .watchTasks(TasksQuery(accountId: account))
          .listen(emissions.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      final supportedList = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('supported-list'),
        title: 'Supported',
      );
      await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('unsupported-list'),
        title: 'Protected',
        projection: CacheProjection.unsupported,
      );
      final unsupportedParent = await cache.putTask(
        accountId: account,
        taskListId: supportedList,
        remoteId: const TaskRemoteId('unsupported-parent'),
        title: 'Protected parent',
        position: '0001',
        projection: CacheProjection.unsupported,
      );
      await cache.putTask(
        accountId: account,
        taskListId: supportedList,
        parentTaskId: unsupportedParent,
        remoteId: const TaskRemoteId('protected-child'),
        title: 'Child of protected parent',
        position: '0002',
      );
      await pumpEventQueue();

      expect(emissions.last.taskLists.map((value) => value.title), <String>[
        'Supported',
      ]);
      expect(emissions.last.tasks, isEmpty);
      expect(await cache.countStoredTaskLists(account), 2);
    },
  );

  test('page scope completion is separate from cache verification', () async {
    final account = AccountId(await database.createAccount('synthetic-pages'));
    final list = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('page-list'),
      title: 'Paged',
    );
    await cache.putScopeCompleteness(
      accountId: account,
      scope: const CacheScope.taskLists(),
      publicationId: 'publication-a',
      isComplete: true,
    );
    await cache.putScopeCompleteness(
      accountId: account,
      scope: CacheScope.tasks(list),
      publicationId: 'publication-a',
      nextPageToken: 'redacted-page-token',
      isComplete: false,
    );

    final incomplete = await repository
        .watchTasks(TasksQuery(accountId: account))
        .first;
    expect(incomplete.completeness, CacheCompleteness.incomplete);
    expect(incomplete.verification, CacheVerification.unverifiedCache);

    await cache.putScopeCompleteness(
      accountId: account,
      scope: CacheScope.tasks(list),
      publicationId: 'publication-a',
      isComplete: true,
    );
    final complete = await repository
        .watchTasks(TasksQuery(accountId: account))
        .firstWhere(
          (snapshot) => snapshot.completeness == CacheCompleteness.complete,
        );
    expect(complete.verification, CacheVerification.unverifiedCache);

    await cache.putScopeCompleteness(
      accountId: account,
      scope: const CacheScope.taskLists(),
      publicationId: 'publication-b',
      isComplete: true,
    );
    final newerListWalk = await repository
        .watchTasks(TasksQuery(accountId: account))
        .first;
    expect(newerListWalk.completeness, CacheCompleteness.incomplete);
  });

  test(
    'remote base remains distinct from projection (DUR-003 boundary)',
    () async {
      final account = AccountId(await database.createAccount('synthetic-base'));
      final list = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('base-list'),
        title: 'Projected v3',
      );
      await cache.putTaskListRemoteBase(
        accountId: account,
        taskListId: list,
        remoteId: const TaskListRemoteId('base-list'),
        title: 'Remote v0',
        observedPublicationId: 'publication-v0',
      );

      final base = await cache.readTaskListRemoteBase(account, list);
      final projected = await repository
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(base!.title, 'Remote v0');
      expect(projected.taskLists.single.title, 'Projected v3');
    },
  );

  test(
    'relational preferences cannot reference another account list',
    () async {
      final accountA = AccountId(
        await database.createAccount('synthetic-pref-a'),
      );
      final accountB = AccountId(
        await database.createAccount('synthetic-pref-b'),
      );
      final listB = await cache.putTaskList(
        accountId: accountB,
        remoteId: const TaskListRemoteId('pref-list-b'),
        title: 'B',
      );

      expect(
        cache.putListPreference(
          accountId: accountA,
          taskListId: listB,
          sidebarOrder: 0,
          excludedFromSmartViews: false,
        ),
        throwsA(isA<SqliteException>()),
      );
    },
  );

  test(
    'task remote base round-trips complete supported Google state',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-task-base'),
      );
      final list = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('task-base-list'),
        title: 'Confirmed source list',
      );
      final projectedList = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('projected-list'),
        title: 'Projected destination list',
      );
      final task = await cache.putTask(
        accountId: account,
        taskListId: projectedList,
        remoteId: const TaskRemoteId('task-base-task'),
        title: 'Projected',
        position: '0001',
      );
      final updated = DateTime.utc(2026, 8, 15, 12, 30);
      await cache.putTaskRemoteBase(
        accountId: account,
        taskId: task,
        taskListId: list,
        remoteId: const TaskRemoteId('task-base-task'),
        observedPublicationId: 'publication-task-base',
        deleted: false,
        title: 'Confirmed',
        notes: 'Synthetic notes',
        status: TaskStatus.completed,
        due: TaskDate(2026, 8, 20),
        position: '0001',
        completedAt: updated,
        hidden: true,
        etag: 'synthetic-etag',
        remoteUpdatedAt: updated,
        selfLink: Uri.parse('https://example.invalid/tasks/task-base-task'),
        links: <TaskRemoteLinkRecord>[
          TaskRemoteLinkRecord(
            type: 'email',
            description: 'Synthetic link',
            link: Uri.parse('https://example.invalid/link'),
          ),
        ],
        webViewLink: Uri.parse('https://example.invalid/view'),
      );

      final base = await cache.readTaskRemoteBase(account, task);
      expect(base!.remoteId, const TaskRemoteId('task-base-task'));
      expect(base.taskListId, list);
      expect(base.title, 'Confirmed');
      expect(base.status, TaskStatus.completed);
      expect(base.due, TaskDate(2026, 8, 20));
      expect(base.completedAt, updated);
      expect(base.remoteUpdatedAt, updated);
      expect(base.links, <TaskRemoteLinkRecord>[
        TaskRemoteLinkRecord(
          type: 'email',
          description: 'Synthetic link',
          link: Uri.parse('https://example.invalid/link'),
        ),
      ]);
    },
  );

  test(
    'stable local and separate remote IDs survive close and reopen',
    () async {
      final root = await Directory.systemTemp.createTemp('axiotask-s10-cache-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/cache.sqlite');
      await database.close();

      final first = await AppDatabase.openFile(file);
      final firstCache = CacheDao(first);
      final account = AccountId(await first.createAccount('synthetic-restart'));
      final list = await firstCache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('restart-list'),
        title: 'Restart list',
      );
      final task = await firstCache.putTask(
        accountId: account,
        taskListId: list,
        remoteId: const TaskRemoteId('restart-task'),
        title: 'Restart task',
        position: '0001',
      );
      await first.close();

      final reopened = await AppDatabase.openFile(file);
      addTearDown(reopened.close);
      final snapshot = await DatabaseTasksRepository(
        reopened,
      ).watchTasks(TasksQuery(accountId: account)).first;
      expect(snapshot.taskLists.single.id, list);
      expect(
        snapshot.taskLists.single.remoteId,
        const TaskListRemoteId('restart-list'),
      );
      expect(snapshot.tasks.single.id, task);
      expect(
        snapshot.tasks.single.remoteId,
        const TaskRemoteId('restart-task'),
      );
    },
  );
}

final class _RollbackProbe implements Exception {
  const _RollbackProbe();
}
