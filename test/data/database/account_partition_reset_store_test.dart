import 'package:axiotask/src/data/database/account_partition_reset_store.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;

  setUp(() => database = AppDatabase.inMemory());
  tearDown(() => database.close());

  test(
    'PAR-DATA-003 resets every selected partition class and preserves another account',
    () async {
      final selected = AccountId(
        await database.createAccount('selected-subject'),
      );
      final other = AccountId(await database.createAccount('other-subject'));
      await _seedPartition(database, selected, 'selected');
      await _seedPartition(database, other, 'other');
      final store = DatabaseAccountPartitionResetStore(database);

      final preview = await store.preview(selected);
      expect(preview.cachedListCount, 1);
      expect(preview.cachedTaskCount, 1);
      expect(preview.pendingChangeCount, 1);
      expect(preview.uncertainChangeCount, 1);
      expect(preview.undoRecordCount, greaterThanOrEqualTo(1));
      expect(preview.accountPreferenceCount, 3);
      expect(preview.syncHistoryCount, greaterThanOrEqualTo(2));
      expect(preview.importManifestCount, 1);

      await store.resetPartition(selected);

      final accounts = await database.allAccounts();
      expect(
        accounts.singleWhere((row) => row.id == selected.value).googleSubject,
        'selected-subject',
      );
      for (final table in _partitionTables) {
        expect(
          await _count(database, table, selected),
          0,
          reason: '$table must be discarded for the selected account',
        );
        expect(
          await _count(database, table, other),
          greaterThan(0),
          reason: '$table must remain for the other account',
        );
      }

      final emptyFacts = await SyncHealthDao(
        database,
      ).watchFacts(selected).first;
      final emptyHealth = projectSyncHealth(
        facts: emptyFacts,
        runtime: const SyncRuntimeFacts(
          authorization: SyncAuthorization.usable,
          connectivity: SyncConnectivity.unknown,
          activity: SyncActivity.idle,
          verificationRequired: false,
        ),
        now: DateTime.utc(2026, 8, 16, 12),
      );
      expect(emptyHealth.outcome, isNot(SyncHealthOutcome.good));

      await store.resetPartition(selected);
      expect((await database.allAccounts()).length, 2);
    },
  );

  test('transaction failure rolls the complete partition back', () async {
    final account = AccountId(await database.createAccount('rollback-subject'));
    await _seedPartition(database, account, 'rollback');
    final before = <String, int>{
      for (final table in _partitionTables)
        table: await _count(database, table, account),
    };
    final store = DatabaseAccountPartitionResetStore(
      database,
      transactionControl: (boundary) {
        if (boundary == AccountPartitionResetBoundary.beforeCommit) {
          throw StateError('synthetic before-commit failure');
        }
      },
    );

    await expectLater(
      store.resetPartition(account),
      throwsA(isA<StateError>()),
    );

    for (final table in _partitionTables) {
      expect(await _count(database, table, account), before[table]);
    }
    expect(
      (await database.allAccounts()).single.googleSubject,
      'rollback-subject',
    );
  });

  test('device-only preferences are outside reset storage', () async {
    final backend = InMemoryDevicePreferencesBackend(
      initialValues: <String, Object>{
        'isolated.theme': 'dark',
        'isolated.onboarding_dismissed': true,
      },
    );
    final account = AccountId(await database.createAccount('device-subject'));
    await _seedPartition(database, account, 'device');

    await DatabaseAccountPartitionResetStore(database).resetPartition(account);

    expect(backend.values['isolated.theme'], 'dark');
    expect(backend.values['isolated.onboarding_dismissed'], isTrue);
  });
}

const _partitionTables = <String>[
  'task_lists',
  'tasks',
  'task_list_remote_bases',
  'task_remote_bases',
  'scope_completeness',
  'account_preferences',
  'desired_states',
  'desired_state_dependencies',
  'desired_state_attempts',
  'sync_runs',
  'task_delete_groups',
  'task_delete_tombstones',
  'task_delete_snapshots',
  'task_due_change_groups',
  'task_due_change_snapshots',
  'bulk_operations',
  'bulk_operation_members',
  'sync_facts',
  'task_list_preferences',
  'view_preferences',
  'account_backup_import_manifests',
];

Future<int> _count(
  AppDatabase database,
  String table,
  AccountId account,
) async {
  final row = await database
      .customSelect(
        'SELECT COUNT(*) AS amount FROM $table WHERE account_id = ?1',
        variables: <Variable<Object>>[Variable<int>(account.value)],
      )
      .getSingle();
  return row.read<int>('amount');
}

Future<void> _seedPartition(
  AppDatabase database,
  AccountId account,
  String label,
) async {
  final cache = CacheDao(database);
  final list = await cache.putTaskList(
    accountId: account,
    remoteId: TaskListRemoteId('remote-list-$label'),
    title: '$label list',
  );
  final task = await cache.putTask(
    accountId: account,
    taskListId: list,
    remoteId: TaskRemoteId('remote-task-$label'),
    title: '$label task',
    position: '1000',
  );
  await DatabaseTasksRepository(database).apply(
    SetTaskNotesCommand(
      accountId: account,
      taskId: task,
      notes: '$label pending',
    ),
  );
  final desired = await (database.select(
    database.desiredStateRows,
  )..where((row) => row.accountId.equals(account.value))).getSingle();
  await database
      .into(database.desiredStateAttemptRows)
      .insert(
        DesiredStateAttemptRowsCompanion.insert(
          accountId: account.value,
          desiredStateId: desired.id,
          generation: desired.generation,
          desiredLifecycle: desired.desiredLifecycle,
          title: Value(desired.title),
          notes: Value(desired.notes),
          status: Value(desired.status),
          dueEpochDay: Value(desired.dueEpochDay),
          desiredTaskListId: Value(desired.desiredTaskListId),
          desiredParentTaskId: Value(desired.desiredParentTaskId),
          desiredPreviousTaskId: Value(desired.desiredPreviousTaskId),
          baseRemoteId: Value(desired.baseRemoteId),
          baseEtag: Value(desired.baseEtag),
          baseRemoteUpdatedAt: Value(desired.baseRemoteUpdatedAt),
          baseObservedPublicationId: Value(desired.baseObservedPublicationId),
          baseTitle: Value(desired.baseTitle),
          baseTaskListId: Value(desired.baseTaskListId),
          baseParentTaskId: Value(desired.baseParentTaskId),
          basePreviousTaskId: Value(desired.basePreviousTaskId),
          basePosition: Value(desired.basePosition),
          baseSiblingOrder: Value(desired.baseSiblingOrder),
          notBefore: Value(desired.notBefore),
          state: 'uncertain',
          failureCode: const Value('synthetic_response_lost'),
          claimedAt: DateTime.utc(2026, 8, 16, 10),
          lastTransitionAt: DateTime.utc(2026, 8, 16, 10),
        ),
      );
  await database
      .into(database.syncRunRows)
      .insert(
        SyncRunRowsCompanion.insert(
          accountId: account.value,
          runId: 'run-$label',
          triggersJson: '[]',
          state: 'succeeded',
          startedAt: DateTime.utc(2026, 8, 16, 9),
          finishedAt: Value(DateTime.utc(2026, 8, 16, 9, 1)),
        ),
      );
  await SyncHealthDao(database).writeFacts(
    account,
    PersistedSyncFacts(
      syncEnabled: true,
      lastSuccessfulSyncAt: DateTime.utc(2026, 8, 16, 9, 1),
      counts: const SyncWorkCounts(pending: 1, uncertain: 1),
    ),
  );
  await database
      .into(database.taskDeleteGroupRows)
      .insert(
        TaskDeleteGroupRowsCompanion.insert(
          accountId: account.value,
          selectedCount: 1,
          rootCount: 1,
          snapshotCount: 1,
          notBefore: DateTime.utc(2026, 8, 16, 11),
          snapshotAvailable: true,
          createdAt: DateTime.utc(2026, 8, 16, 10),
        ),
      );
  await database
      .into(database.taskDueChangeGroupRows)
      .insert(
        TaskDueChangeGroupRowsCompanion.insert(
          accountId: account.value,
          editedTaskId: task.value,
          snapshotCount: 2,
          cascadedParent: true,
          createdAt: DateTime.utc(2026, 8, 16, 10),
        ),
      );
  await database
      .into(database.bulkOperationRows)
      .insert(
        BulkOperationRowsCompanion.insert(
          accountId: account.value,
          kind: 'complete',
          selectedCount: 1,
          affectedCount: 1,
          createdAt: DateTime.utc(2026, 8, 16, 10),
        ),
      );
  await database
      .into(database.taskListPreferenceRows)
      .insert(
        TaskListPreferenceRowsCompanion.insert(
          accountId: account.value,
          taskListId: list.value,
          sidebarOrder: const Value(0),
        ),
      );
  await database
      .into(database.viewPreferenceRows)
      .insert(
        ViewPreferenceRowsCompanion.insert(
          accountId: account.value,
          viewKey: 'focus',
          sortMode: 'manual',
        ),
      );
  await database
      .into(database.accountBackupImportManifestRows)
      .insert(
        AccountBackupImportManifestRowsCompanion.insert(
          accountId: account.value,
          documentDigest: label.padRight(64, '0'),
          sourceGoogleSubject: '$label-subject',
          sourceAccountMatches: true,
          exportedAt: DateTime.utc(2026, 8, 15),
          createdListCount: 1,
          existingListCount: 0,
          createdTaskCount: 1,
          existingTaskCount: 0,
          importedAt: DateTime.utc(2026, 8, 16),
        ),
      );

  // Seed rows that are normally created by the full sync/undo pipelines while
  // keeping this reset test focused on the account-partition transaction.
  await database.customStatement(
    'INSERT INTO task_list_remote_bases '
    '(account_id, task_list_id, remote_id, title, deleted, observed_publication_id) '
    'VALUES (?, ?, ?, ?, 0, ?)',
    <Object?>[
      account.value,
      list.value,
      'remote-list-$label',
      '$label list',
      'p-$label',
    ],
  );
  await database.customStatement(
    'INSERT INTO task_remote_bases '
    '(account_id, task_id, task_list_id, remote_id, title, status, position, hidden, deleted, links_json, observed_publication_id) '
    "VALUES (?, ?, ?, ?, ?, 'needs_action', '1000', 0, 0, '[]', ?)",
    <Object?>[
      account.value,
      task.value,
      list.value,
      'remote-task-$label',
      '$label task',
      'p-$label',
    ],
  );
  await database.customStatement(
    'INSERT INTO scope_completeness '
    '(account_id, scope_kind, scope_key, publication_id, is_complete) '
    "VALUES (?, 'task_lists', 'task_lists', ?, 1)",
    <Object?>[account.value, 'p-$label'],
  );
  final deleteGroup = await (database.select(
    database.taskDeleteGroupRows,
  )..where((row) => row.accountId.equals(account.value))).getSingle();
  await database.customStatement(
    'INSERT INTO task_delete_tombstones '
    '(account_id, root_task_id, group_id, desired_state_id, delete_generation, not_before, snapshot_available, created_at) '
    'VALUES (?, ?, ?, ?, 1, ?, 1, ?)',
    <Object?>[
      account.value,
      task.value,
      deleteGroup.id,
      desired.id,
      DateTime.utc(2026, 8, 16, 11).millisecondsSinceEpoch,
      DateTime.utc(2026, 8, 16, 10).millisecondsSinceEpoch,
    ],
  );
  final tombstone = await (database.select(
    database.taskDeleteTombstoneRows,
  )..where((row) => row.accountId.equals(account.value))).getSingle();
  await database.customStatement(
    'INSERT INTO task_delete_snapshots '
    '(account_id, tombstone_id, task_id, task_list_id, title, status, position) '
    "VALUES (?, ?, ?, ?, ?, 'needs_action', '1000')",
    <Object?>[
      account.value,
      tombstone.id,
      task.value,
      list.value,
      '$label task',
    ],
  );
  final dueGroup = await (database.select(
    database.taskDueChangeGroupRows,
  )..where((row) => row.accountId.equals(account.value))).getSingle();
  await database.customStatement(
    'INSERT INTO task_due_change_snapshots '
    '(account_id, group_id, task_id) VALUES (?, ?, ?)',
    <Object?>[account.value, dueGroup.id, task.value],
  );
  final operation = await (database.select(
    database.bulkOperationRows,
  )..where((row) => row.accountId.equals(account.value))).getSingle();
  await database.customStatement(
    'INSERT INTO bulk_operation_members '
    '(account_id, operation_id, task_id, desired_state_id, generation, outcome) '
    "VALUES (?, ?, ?, ?, 1, 'pending')",
    <Object?>[account.value, operation.id, task.value, desired.id],
  );
}
