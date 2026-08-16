import 'dart:async';
import 'dart:io';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/preferences/relational_preferences.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
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
}
