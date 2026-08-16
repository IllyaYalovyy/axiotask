import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/search/supported_task_search_repository.dart';
import 'package:axiotask/src/domain/model/search.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late CacheDao cache;

  setUp(() {
    database = AppDatabase.inMemory();
    cache = CacheDao(database);
  });

  tearDown(() => database.close());

  test(
    'PAR-SEARCH-001 searches title and notes and gives child parent context',
    () async {
      final account = AccountId(
        await database.createAccount('synthetic-search'),
      );
      final list = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-search-list'),
        title: 'Synthetic inbox',
      );
      final parent = await cache.putTask(
        accountId: account,
        taskListId: list,
        remoteId: const TaskRemoteId('synthetic-parent'),
        title: 'Parent context',
        notes: 'Contains résumé details',
        position: '1',
      );
      final child = await cache.putTask(
        accountId: account,
        taskListId: list,
        parentTaskId: parent,
        remoteId: const TaskRemoteId('synthetic-child'),
        title: 'Review Δοκιμή',
        notes: 'Needle is in child notes',
        position: '2',
      );
      final repository = SupportedTaskSearchRepository(
        DatabaseTasksRepository(database),
      );

      final title = await repository
          .watchSearch(TaskSearchQuery(accountId: account, text: 'ΔΟΚΙΜΉ'))
          .first;
      expect(title, hasLength(1));
      expect(title.single.match.id, child);
      expect(title.single.parent.id, parent);
      expect(title.single.matchedFields, <TaskSearchField>{
        TaskSearchField.title,
      });

      final notes = await repository
          .watchSearch(TaskSearchQuery(accountId: account, text: 'résumé'))
          .first;
      expect(notes.single.match.id, parent);
      expect(notes.single.parent.id, parent);
      expect(notes.single.matchedFields, <TaskSearchField>{
        TaskSearchField.notes,
      });
    },
  );

  test('search is account scoped and never exposes unsupported rows', () async {
    final accountA = AccountId(await database.createAccount('synthetic-a'));
    final accountB = AccountId(await database.createAccount('synthetic-b'));
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
    await cache.putTask(
      accountId: accountA,
      taskListId: listA,
      remoteId: const TaskRemoteId('visible-a'),
      title: 'Shared needle visible',
      position: '1',
    );
    await cache.putTask(
      accountId: accountA,
      taskListId: listA,
      remoteId: const TaskRemoteId('protected-a'),
      title: 'Shared needle protected',
      position: '2',
      projection: CacheProjection.unsupported,
    );
    await cache.putTask(
      accountId: accountB,
      taskListId: listB,
      remoteId: const TaskRemoteId('visible-b'),
      title: 'Shared needle other account',
      position: '1',
    );
    final repository = SupportedTaskSearchRepository(
      DatabaseTasksRepository(database),
    );

    final results = await repository
        .watchSearch(TaskSearchQuery(accountId: accountA, text: 'needle'))
        .first;
    expect(results.map((result) => result.match.title), <String>[
      'Shared needle visible',
    ]);
  });

  test(
    'empty, Unicode, long, and live-updating queries are deterministic',
    () async {
      final account = AccountId(await database.createAccount('synthetic-live'));
      final list = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('live-list'),
        title: 'Live',
      );
      final tasks = DatabaseTasksRepository(database);
      final repository = SupportedTaskSearchRepository(tasks);

      expect(
        await repository
            .watchSearch(TaskSearchQuery(accountId: account, text: '  '))
            .first,
        isEmpty,
      );
      expect(
        await repository
            .watchSearch(TaskSearchQuery(accountId: account, text: 'x' * 5000))
            .first,
        isEmpty,
      );

      final emissions = <List<TaskSearchResult>>[];
      final subscription = repository
          .watchSearch(TaskSearchQuery(accountId: account, text: '世界'))
          .listen(emissions.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();
      expect(emissions.last, isEmpty);

      await cache.putTask(
        accountId: account,
        taskListId: list,
        remoteId: const TaskRemoteId('live-result'),
        title: 'こんにちは世界',
        position: '1',
      );
      await pumpEventQueue();
      expect(emissions.last.single.match.title, 'こんにちは世界');
    },
  );
}
