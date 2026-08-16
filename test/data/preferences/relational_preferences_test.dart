import 'dart:async';
import 'dart:io';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/preferences/relational_preferences.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'relational defaults and updates are account isolated and reactive',
    () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final cache = CacheDao(database);
      final accountA = AccountId(
        await database.createAccount('synthetic-pref-a'),
      );
      final accountB = AccountId(
        await database.createAccount('synthetic-pref-b'),
      );
      final listA = await cache.putTaskList(
        accountId: accountA,
        remoteId: const TaskListRemoteId('synthetic-list-a'),
        title: 'List A',
      );
      final listB = await cache.putTaskList(
        accountId: accountB,
        remoteId: const TaskListRemoteId('synthetic-list-b'),
        title: 'List B',
      );
      final preferences = DriftRelationalPreferences(database);

      final listAValues = StreamIterator<ListPreferences>(
        preferences.watchListPreferences(accountA, listA),
      );
      final viewAValues = StreamIterator<ViewPreferences>(
        preferences.watchViewPreferences(accountA, const ViewKey('all')),
      );
      addTearDown(listAValues.cancel);
      addTearDown(viewAValues.cancel);

      expect(await listAValues.moveNext(), isTrue);
      expect(listAValues.current, const ListPreferences.defaults());
      expect(await viewAValues.moveNext(), isTrue);
      expect(viewAValues.current, const ViewPreferences.defaults());

      expect(
        await preferences.setListPreferences(
          accountA,
          listA,
          const ListPreferences(sidebarOrder: 3, excludedFromSmartViews: true),
        ),
        isA<Success<void>>(),
      );
      expect(
        await preferences.setViewPreferences(
          accountA,
          const ViewKey('all'),
          const ViewPreferences(
            sort: ViewSort.effectiveDue,
            showCompleted: true,
          ),
        ),
        isA<Success<void>>(),
      );

      expect(await listAValues.moveNext(), isTrue);
      expect(
        listAValues.current,
        const ListPreferences(sidebarOrder: 3, excludedFromSmartViews: true),
      );
      expect(await viewAValues.moveNext(), isTrue);
      expect(
        viewAValues.current,
        const ViewPreferences(sort: ViewSort.effectiveDue, showCompleted: true),
      );
      expect(
        await preferences.watchListPreferences(accountB, listB).first,
        const ListPreferences.defaults(),
      );
      expect(
        await preferences
            .watchViewPreferences(accountB, const ViewKey('all'))
            .first,
        const ViewPreferences.defaults(),
      );
    },
  );

  test('list preferences enforce account-owned foreign keys', () async {
    final database = AppDatabase.inMemory();
    addTearDown(database.close);
    final cache = CacheDao(database);
    final accountA = AccountId(await database.createAccount('synthetic-fk-a'));
    final accountB = AccountId(await database.createAccount('synthetic-fk-b'));
    final listB = await cache.putTaskList(
      accountId: accountB,
      remoteId: const TaskListRemoteId('synthetic-fk-list-b'),
      title: 'List B',
    );
    final preferences = DriftRelationalPreferences(database);

    final result = await preferences.setListPreferences(
      accountA,
      listB,
      const ListPreferences(sidebarOrder: 0, excludedFromSmartViews: true),
    );

    expect(result, isA<Failed<void>>());
    expect(
      await database.select(database.taskListPreferenceRows).get(),
      isEmpty,
    );
  });

  test('relational list and view preferences survive file restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'axiotask-synthetic-preferences-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/preferences.sqlite');

    var database = await AppDatabase.openFile(file);
    final account = AccountId(
      await database.createAccount('synthetic-restart-account'),
    );
    final list = await CacheDao(database).putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('synthetic-restart-list'),
      title: 'Restart list',
    );
    var preferences = DriftRelationalPreferences(database);
    expect(
      await preferences.setListPreferences(
        account,
        list,
        const ListPreferences(sidebarOrder: 7, excludedFromSmartViews: true),
      ),
      isA<Success<void>>(),
    );
    expect(
      await preferences.setViewPreferences(
        account,
        const ViewKey('focus'),
        const ViewPreferences(sort: ViewSort.title, showCompleted: true),
      ),
      isA<Success<void>>(),
    );
    await database.close();

    database = await AppDatabase.openFile(file);
    addTearDown(database.close);
    preferences = DriftRelationalPreferences(database);

    expect(
      await preferences.watchListPreferences(account, list).first,
      const ListPreferences(sidebarOrder: 7, excludedFromSmartViews: true),
    );
    expect(
      await preferences
          .watchViewPreferences(account, const ViewKey('focus'))
          .first,
      const ViewPreferences(sort: ViewSort.title, showCompleted: true),
    );
  });

  test(
    'aggregate projections react to new and deleted supported lists',
    () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final cache = CacheDao(database);
      final account = AccountId(
        await database.createAccount('synthetic-list-projection'),
      );
      final first = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-first'),
        title: 'First',
      );
      final preferences = DriftRelationalPreferences(database);
      final values = StreamIterator<Map<TaskListId, ListPreferences>>(
        preferences.watchAllListPreferences(account),
      );
      addTearDown(values.cancel);

      expect(await values.moveNext(), isTrue);
      expect(values.current, <TaskListId, ListPreferences>{
        first: const ListPreferences.defaults(),
      });
      final second = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-second'),
        title: 'Second',
      );
      expect(await values.moveNext(), isTrue);
      expect(values.current.keys, <TaskListId>{first, second});

      await (database.update(
        database.taskListCacheRows,
      )..where((row) => row.id.equals(first.value))).write(
        const TaskListCacheRowsCompanion(projection: Value<String>('deleted')),
      );
      expect(await values.moveNext(), isTrue);
      expect(values.current.keys, <TaskListId>{second});
    },
  );

  test(
    'sidebar order is atomic, restart-safe, and preserves exclusions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-synthetic-sidebar-order-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/preferences.sqlite');
      var database = await AppDatabase.openFile(file);
      final account = AccountId(
        await database.createAccount('synthetic-sidebar-account'),
      );
      final cache = CacheDao(database);
      final first = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-sidebar-first'),
        title: 'First',
      );
      final second = await cache.putTaskList(
        accountId: account,
        remoteId: const TaskListRemoteId('synthetic-sidebar-second'),
        title: 'Second',
      );
      var preferences = DriftRelationalPreferences(database);
      expect(
        await preferences.setListPreferences(
          account,
          first,
          const ListPreferences(
            sidebarOrder: null,
            excludedFromSmartViews: true,
          ),
        ),
        isA<Success<void>>(),
      );
      expect(
        await preferences.setSidebarOrder(account, <TaskListId>[second, first]),
        isA<Success<void>>(),
      );
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      preferences = DriftRelationalPreferences(database);
      final restored = await preferences.watchAllListPreferences(account).first;
      expect(restored[second]!.sidebarOrder, 0);
      expect(restored[first]!.sidebarOrder, 1);
      expect(restored[first]!.excludedFromSmartViews, isTrue);
    },
  );

  test('all view preferences react without inventing missing rows', () async {
    final database = AppDatabase.inMemory();
    addTearDown(database.close);
    final account = AccountId(
      await database.createAccount('synthetic-view-projection'),
    );
    final preferences = DriftRelationalPreferences(database);
    final values = StreamIterator<Map<ViewKey, ViewPreferences>>(
      preferences.watchAllViewPreferences(account),
    );
    addTearDown(values.cancel);

    expect(await values.moveNext(), isTrue);
    expect(values.current, isEmpty);
    await preferences.setViewPreferences(
      account,
      const ViewKey('focus'),
      const ViewPreferences(sort: ViewSort.title, showCompleted: true),
    );
    expect(await values.moveNext(), isTrue);
    expect(
      values.current[const ViewKey('focus')],
      const ViewPreferences(sort: ViewSort.title, showCompleted: true),
    );
  });
}
