import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/account_backup_repository.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/preferences/relational_preferences.dart';
import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  var databaseClosed = false;
  late ManualClock clock;
  late DatabaseAccountBackupRepository backups;

  setUp(() {
    database = AppDatabase.inMemory();
    databaseClosed = false;
    clock = ManualClock(DateTime.utc(2026, 8, 16, 12));
    backups = DatabaseAccountBackupRepository(database);
  });

  tearDown(() async {
    if (!databaseClosed) {
      await database.close();
    }
  });

  test(
    'PAR-DATA-001 selects one account and includes acknowledged offline edits',
    () async {
      final accountA = AccountId(await database.createAccount('subject-a'));
      final accountB = AccountId(await database.createAccount('subject-b'));
      final lists = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final tasks = DatabaseTasksRepository(database, clock: clock);

      final listA =
          (await lists.createTaskList(
                    CreateTaskListCommand(
                      accountId: accountA,
                      title: 'Offline list A',
                    ),
                  )
                  as Success<TaskListId>)
              .value;
      final parent =
          (await tasks.createTask(
                    CreateTaskCommand(
                      accountId: accountA,
                      taskListId: listA,
                      title: 'Offline parent edited',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      final child =
          (await tasks.createTask(
                    CreateTaskCommand(
                      accountId: accountA,
                      taskListId: listA,
                      parentTaskId: parent,
                      title: 'Offline child',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      expect(
        await tasks.apply(
          SetTaskNotesCommand(
            accountId: accountA,
            taskId: parent,
            notes: 'Acknowledged while disconnected',
          ),
        ),
        isA<Success<void>>(),
      );
      expect(
        await tasks.apply(
          MoveTaskCommand(
            accountId: accountA,
            taskId: child,
            destinationTaskListId: listA,
            parentTaskId: parent,
            previousTaskId: null,
          ),
        ),
        isA<Success<void>>(),
      );
      await lists.createTaskList(
        CreateTaskListCommand(accountId: accountB, title: 'Other account'),
      );

      final snapshot = await backups.readProjectedAccount(accountA);

      expect(snapshot.sourceGoogleSubject, 'subject-a');
      expect(snapshot.lists.map((list) => list.title), <String>[
        'Offline list A',
      ]);
      expect(snapshot.tasks.map((task) => task.title), <String>[
        'Offline parent edited',
        'Offline child',
      ]);
      expect(snapshot.tasks.first.notes, 'Acknowledged while disconnected');
      expect(snapshot.tasks.last.parentKey, snapshot.tasks.first.key);
    },
  );

  test('list and sibling ordering is exported without raw local IDs', () async {
    final account = AccountId(await database.createAccount('order-subject'));
    final cache = CacheDao(database);
    final first = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('remote-first'),
      title: 'First created',
    );
    final second = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('remote-second'),
      title: 'Second created',
    );
    await cache.putTask(
      accountId: account,
      taskListId: second,
      remoteId: const TaskRemoteId('remote-later'),
      title: 'Later sibling',
      position: '2000',
    );
    await cache.putTask(
      accountId: account,
      taskListId: second,
      remoteId: const TaskRemoteId('remote-earlier'),
      title: 'Earlier sibling',
      position: '1000',
    );
    await DriftRelationalPreferences(
      database,
    ).setSidebarOrder(account, <TaskListId>[second, first]);

    final snapshot = await backups.readProjectedAccount(account);
    final encoded = const AccountBackupCodec().encode(
      snapshot,
      exportedAt: DateTime.utc(2026, 8, 16, 12),
    );
    final document = jsonDecode(encoded) as Map<String, Object?>;

    expect(snapshot.lists.map((list) => list.title), <String>[
      'Second created',
      'First created',
    ]);
    expect(snapshot.tasks.map((task) => task.title), <String>[
      'Earlier sibling',
      'Later sibling',
    ]);
    expect(encoded, isNot(contains('"accountId"')));
    expect(encoded, isNot(contains('"taskListId"')));
    expect(document.keys, <String>[
      'format',
      'version',
      'privateDataWarning',
      'exportedAt',
      'sourceAccount',
      'lists',
      'tasks',
    ]);
  });

  test(
    'PAR-DATA-002 empty restore is atomic, ordered, and retry-idempotent',
    () async {
      final account = AccountId(
        await database.createAccount('restore-subject'),
      );
      await _markFresh(database, account, clock.now());
      final document = _restoreDocument('restore-subject');

      final result = await backups.restoreImport(
        accountId: account,
        document: document,
        readiness: AccountBackupImportReadiness.ready,
        lastSuccessfulSyncAt: clock.now(),
      );

      expect(result.createdListCount, 1);
      expect(result.createdTaskCount, 2);
      final snapshot = await DatabaseTasksRepository(
        database,
      ).watchTasks(TasksQuery(accountId: account)).first;
      expect(snapshot.taskLists.map((list) => list.title), <String>[
        'Restored list',
      ]);
      expect(snapshot.tasks.map((task) => task.title), <String>[
        'Restored parent',
        'Restored child',
      ]);
      expect(snapshot.tasks.last.parentTaskId, snapshot.tasks.first.id);
      expect(
        await database.select(database.desiredStateRows).get(),
        hasLength(3),
      );
      expect(
        await database.select(database.desiredStateDependencyRows).get(),
        hasLength(3),
      );
      expect(
        await database.select(database.accountBackupImportManifestRows).get(),
        hasLength(1),
      );

      final repeated = await backups.restoreImport(
        accountId: account,
        document: document,
        readiness: AccountBackupImportReadiness.pending,
        lastSuccessfulSyncAt: clock.now(),
      );
      expect(repeated.alreadyImported, isTrue);
      expect(
        await database.select(database.taskListCacheRows).get(),
        hasLength(1),
      );
      expect(await database.select(database.taskCacheRows).get(), hasLength(2));
    },
  );

  test('matching same-account identities remain unchanged', () async {
    final account = AccountId(await database.createAccount('restore-subject'));
    await _markFresh(database, account, clock.now());
    final cache = CacheDao(database);
    final list = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('google-list'),
      title: 'Newer existing list',
    );
    await cache.putTask(
      accountId: account,
      taskListId: list,
      remoteId: const TaskRemoteId('google-parent'),
      title: 'Newer existing task',
      position: '1000',
    );

    final preview = await backups.previewImport(
      accountId: account,
      document: _restoreDocument('restore-subject'),
      readiness: AccountBackupImportReadiness.ready,
      lastSuccessfulSyncAt: clock.now(),
    );
    expect(preview.existingListCount, 1);
    expect(preview.existingTaskCount, 1);
    expect(preview.tasksToCreate, 1);

    await backups.restoreImport(
      accountId: account,
      document: _restoreDocument('restore-subject'),
      readiness: AccountBackupImportReadiness.ready,
      lastSuccessfulSyncAt: clock.now(),
    );
    final snapshot = await DatabaseTasksRepository(
      database,
    ).watchTasks(TasksQuery(accountId: account)).first;
    expect(snapshot.taskLists.single.title, 'Newer existing list');
    expect(snapshot.tasks.first.title, 'Newer existing task');
    expect(snapshot.tasks.last.parentTaskId, snapshot.tasks.first.id);
  });

  test('stale refusal and injected failure mutate nothing', () async {
    final account = AccountId(await database.createAccount('restore-subject'));
    await _markFresh(database, account, clock.now());
    final document = _restoreDocument('restore-subject');
    for (final readiness in const <AccountBackupImportReadiness>[
      AccountBackupImportReadiness.stale,
      AccountBackupImportReadiness.offline,
      AccountBackupImportReadiness.syncStopped,
      AccountBackupImportReadiness.noAuthorization,
      AccountBackupImportReadiness.pending,
    ]) {
      await expectLater(
        backups.previewImport(
          accountId: account,
          document: document,
          readiness: readiness,
          lastSuccessfulSyncAt: clock.now(),
        ),
        throwsA(isA<AccountBackupImportException>()),
      );
      await expectLater(
        backups.restoreImport(
          accountId: account,
          document: document,
          readiness: readiness,
          lastSuccessfulSyncAt: clock.now(),
        ),
        throwsA(isA<AccountBackupImportException>()),
      );
    }
    expect(await database.select(database.taskListCacheRows).get(), isEmpty);

    final failing = DatabaseAccountBackupRepository(
      database,
      clock: clock,
      transactionControl: (boundary) async {
        if (boundary == AccountBackupImportTransactionBoundary.beforeManifest) {
          throw StateError('synthetic rollback');
        }
      },
    );
    await expectLater(
      failing.restoreImport(
        accountId: account,
        document: document,
        readiness: AccountBackupImportReadiness.ready,
        lastSuccessfulSyncAt: clock.now(),
      ),
      throwsStateError,
    );
    expect(await database.select(database.taskListCacheRows).get(), isEmpty);
    expect(await database.select(database.taskCacheRows).get(), isEmpty);
    expect(await database.select(database.desiredStateRows).get(), isEmpty);
    expect(
      await database.select(database.accountBackupImportManifestRows).get(),
      isEmpty,
    );
  });

  test('manifest makes repeat restore idempotent after file restart', () async {
    await database.close();
    databaseClosed = true;
    final root = Directory.systemTemp.createTempSync(
      'axiotask-restore-restart-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/restore.sqlite');
    final first = await AppDatabase.openFile(file);
    final account = AccountId(
      await first.createAccount('restore-restart-subject'),
    );
    await _markFresh(first, account, clock.now());
    final document = _restoreDocument('restore-restart-subject');
    await DatabaseAccountBackupRepository(first, clock: clock).restoreImport(
      accountId: account,
      document: document,
      readiness: AccountBackupImportReadiness.ready,
      lastSuccessfulSyncAt: clock.now(),
    );
    await first.close();

    final reopened = await AppDatabase.openFile(file);
    addTearDown(reopened.close);
    final repeated =
        await DatabaseAccountBackupRepository(
          reopened,
          clock: clock,
        ).restoreImport(
          accountId: account,
          document: document,
          readiness: AccountBackupImportReadiness.pending,
          lastSuccessfulSyncAt: clock.now(),
        );

    expect(repeated.alreadyImported, isTrue);
    expect(
      await reopened.select(reopened.taskListCacheRows).get(),
      hasLength(1),
    );
    expect(await reopened.select(reopened.taskCacheRows).get(), hasLength(2));
    expect(
      await reopened.select(reopened.accountBackupImportManifestRows).get(),
      hasLength(1),
    );
  });
}

Future<void> _markFresh(
  AppDatabase database,
  AccountId account,
  DateTime at,
) async {
  await database
      .into(database.accountPreferenceRows)
      .insert(
        AccountPreferenceRowsCompanion.insert(
          accountId: Value<int>(account.value),
        ),
      );
  await database
      .into(database.syncFactRows)
      .insert(
        SyncFactRowsCompanion.insert(
          accountId: Value<int>(account.value),
          lastSuccessfulSyncAt: Value<DateTime>(at.toUtc()),
        ),
      );
}

AccountBackupDocument _restoreDocument(String subject) => AccountBackupDocument(
  format: accountBackupFormat,
  version: accountBackupVersion,
  privateDataWarning: accountBackupPrivateDataWarning,
  exportedAt: DateTime.utc(2026, 8, 16, 11),
  sourceGoogleSubject: subject,
  lists: const <AccountBackupList>[
    AccountBackupList(
      key: 'list-000001',
      googleId: 'google-list',
      title: 'Restored list',
      order: 0,
    ),
  ],
  tasks: const <AccountBackupTask>[
    AccountBackupTask(
      key: 'task-000001',
      googleId: 'google-parent',
      listKey: 'list-000001',
      parentKey: null,
      title: 'Restored parent',
      notes: 'Synthetic private task content',
      status: TaskStatus.needsAction,
      due: null,
      order: 0,
    ),
    AccountBackupTask(
      key: 'task-000002',
      googleId: 'google-child',
      listKey: 'list-000001',
      parentKey: 'task-000001',
      title: 'Restored child',
      notes: null,
      status: TaskStatus.completed,
      due: null,
      order: 0,
    ),
  ],
);
