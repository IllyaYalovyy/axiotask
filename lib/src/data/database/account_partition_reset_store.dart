import 'dart:async';

import 'package:drift/drift.dart';

import '../../domain/model/tasks.dart';
import '../../domain/recovery/local_data_recovery.dart';
import 'app_database.dart';

enum AccountPartitionResetBoundary { beforeDelete, beforeCommit }

typedef AccountPartitionResetTransactionControl =
    FutureOr<void> Function(AccountPartitionResetBoundary boundary);

/// Deletes one account's complete non-secret partition and recreates only its
/// stable account/subject binding in the same SQLite transaction.
///
/// Deleting the account row deliberately uses the schema's audited cascading
/// foreign keys, which prevents a newly added account-scoped table from being
/// silently omitted. The explicit reinsert retains the configured identity
/// used by the authorization boundary while all partition state starts empty.
final class DatabaseAccountPartitionResetStore implements LocalDataResetStore {
  const DatabaseAccountPartitionResetStore(
    this._database, {
    this.transactionControl,
  });

  final AppDatabase _database;
  final AccountPartitionResetTransactionControl? transactionControl;

  @override
  Future<LocalDataResetPreview> preview(AccountId accountId) async {
    await _requireAccount(accountId);
    final counts = await _database
        .customSelect(
          '''
      SELECT
        (SELECT COUNT(*) FROM task_lists WHERE account_id = ?1) AS lists,
        (SELECT COUNT(*) FROM tasks WHERE account_id = ?1) AS tasks,
        (SELECT COUNT(*) FROM desired_states
          WHERE account_id = ?1 AND state IN ('pending', 'in_flight', 'failed'))
          AS pending_changes,
        (SELECT COUNT(*) FROM (
          SELECT id FROM desired_states
            WHERE account_id = ?1 AND state = 'uncertain'
          UNION
          SELECT desired_state_id FROM desired_state_attempts
            WHERE account_id = ?1 AND state = 'uncertain'
        )) AS uncertain_changes,
        ((SELECT COUNT(*) FROM task_delete_groups WHERE account_id = ?1) +
         (SELECT COUNT(*) FROM task_delete_tombstones
           WHERE account_id = ?1 AND group_id IS NULL) +
         (SELECT COUNT(*) FROM task_due_change_groups WHERE account_id = ?1))
          AS undo_records,
        ((SELECT COUNT(*) FROM account_preferences WHERE account_id = ?1) +
         (SELECT COUNT(*) FROM task_list_preferences WHERE account_id = ?1) +
         (SELECT COUNT(*) FROM view_preferences WHERE account_id = ?1))
          AS preferences,
        ((SELECT COUNT(*) FROM sync_runs WHERE account_id = ?1) +
         (SELECT COUNT(*) FROM sync_facts WHERE account_id = ?1) +
         (SELECT COUNT(*) FROM desired_state_attempts WHERE account_id = ?1))
          AS sync_history,
        (SELECT COUNT(*) FROM account_backup_import_manifests
          WHERE account_id = ?1) AS manifests
      ''',
          variables: <Variable<Object>>[Variable<int>(accountId.value)],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.taskListCacheRows,
            _database.taskCacheRows,
            _database.desiredStateRows,
            _database.taskDeleteGroupRows,
            _database.taskDeleteTombstoneRows,
            _database.taskDueChangeGroupRows,
            _database.accountPreferenceRows,
            _database.taskListPreferenceRows,
            _database.viewPreferenceRows,
            _database.syncRunRows,
            _database.syncFactRows,
            _database.desiredStateAttemptRows,
            _database.accountBackupImportManifestRows,
          },
        )
        .getSingle();
    return LocalDataResetPreview(
      accountId: accountId,
      cachedListCount: counts.read<int>('lists'),
      cachedTaskCount: counts.read<int>('tasks'),
      pendingChangeCount: counts.read<int>('pending_changes'),
      uncertainChangeCount: counts.read<int>('uncertain_changes'),
      undoRecordCount: counts.read<int>('undo_records'),
      accountPreferenceCount: counts.read<int>('preferences'),
      syncHistoryCount: counts.read<int>('sync_history'),
      importManifestCount: counts.read<int>('manifests'),
    );
  }

  @override
  Future<void> resetPartition(
    AccountId accountId,
  ) => _database.transaction(() async {
    final account = await _requireAccount(accountId);
    await transactionControl?.call(AccountPartitionResetBoundary.beforeDelete);
    final deleted = await (_database.delete(
      _database.accounts,
    )..where((row) => row.id.equals(accountId.value))).go();
    if (deleted != 1) {
      throw const LocalDataRecoveryException('account_delete_failed');
    }
    await _database
        .into(_database.accounts)
        .insert(
          AccountsCompanion.insert(
            id: Value<int>(account.id),
            googleSubject: account.googleSubject,
          ),
        );
    await transactionControl?.call(AccountPartitionResetBoundary.beforeCommit);
  });

  Future<Account> _requireAccount(AccountId accountId) async {
    final account = await (_database.select(
      _database.accounts,
    )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
    if (account == null) {
      throw const LocalDataRecoveryException('account_not_found');
    }
    return account;
  }
}
