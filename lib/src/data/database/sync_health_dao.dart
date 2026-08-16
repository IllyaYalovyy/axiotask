import 'package:drift/drift.dart';

import '../../domain/model/tasks.dart';
import '../../sync/health/sync_health.dart';
import 'app_database.dart';

final class SyncHealthDao {
  const SyncHealthDao(this._database);

  final AppDatabase _database;

  Future<void> writeFacts(AccountId accountId, PersistedSyncFacts facts) {
    final failure = facts.latestFailure;
    return _database.transaction(() async {
      await _database
          .into(_database.accountPreferenceRows)
          .insert(
            AccountPreferenceRowsCompanion.insert(
              accountId: Value(accountId.value),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      await (_database.update(
        _database.accountPreferenceRows,
      )..where((row) => row.accountId.equals(accountId.value))).write(
        AccountPreferenceRowsCompanion(
          syncEnabled: Value<bool>(facts.syncEnabled),
        ),
      );
      await _database
          .into(_database.syncFactRows)
          .insertOnConflictUpdate(
            SyncFactRowsCompanion.insert(
              accountId: Value(accountId.value),
              lastSuccessfulSyncAt: Value(facts.lastSuccessfulSyncAt),
              latestFailureReason: Value(_failureReasonValue(failure?.reason)),
              latestFailureAt: Value(failure?.occurredAt),
              latestFailureDiagnosticCode: Value(failure?.diagnosticCode),
              latestFailureAction: Value(_actionValue(failure?.action)),
              pendingCount: Value(facts.counts.pending),
              inFlightCount: Value(facts.counts.inFlight),
              uncertainCount: Value(facts.counts.uncertain),
              failedCount: Value(facts.counts.failed),
              reauthorizationRequired: Value(facts.reauthorizationRequired),
              retryWaiting: Value(facts.retryWaiting),
              automaticRetryExhausted: Value(facts.automaticRetryExhausted),
              requiredScopeIncomplete: Value(facts.requiredScopeIncomplete),
              followUpRequired: Value(facts.followUpRequired),
            ),
          );
    });
  }

  Stream<PersistedSyncFacts> watchFacts(AccountId accountId) {
    final query = _database.customSelect(
      '''
      SELECT
        COALESCE(p.sync_enabled, 1) AS sync_enabled,
        f.last_successful_sync_at,
        f.latest_failure_reason,
        f.latest_failure_at,
        f.latest_failure_diagnostic_code,
        f.latest_failure_action,
        COALESCE(f.pending_count, 0) AS pending_count,
        COALESCE(f.in_flight_count, 0) AS in_flight_count,
        COALESCE(f.uncertain_count, 0) AS uncertain_count,
        COALESCE(f.failed_count, 0) AS failed_count,
        COALESCE(f.reauthorization_required, 0) AS reauthorization_required,
        COALESCE(f.retry_waiting, 0) AS retry_waiting,
        COALESCE(f.automatic_retry_exhausted, 0) AS automatic_retry_exhausted,
        f.retry_next_attempt_at,
        COALESCE(f.retry_attempt_count, 0) AS retry_attempt_count,
        COALESCE(f.required_scope_incomplete, 0) AS required_scope_incomplete,
        COALESCE(f.follow_up_required, 0) AS follow_up_required
      FROM accounts a
      LEFT JOIN account_preferences p ON p.account_id = a.id
      LEFT JOIN sync_facts f ON f.account_id = a.id
      WHERE a.id = ?1
      ''',
      variables: <Variable<Object>>[Variable<int>(accountId.value)],
      readsFrom: <ResultSetImplementation<Table, Object?>>{
        _database.accounts,
        _database.accountPreferenceRows,
        _database.syncFactRows,
      },
    );
    return query.watchSingle().map(_mapFacts);
  }
}

PersistedSyncFacts _mapFacts(QueryRow row) {
  final reason = _mapFailureReason(
    row.readNullable<String>('latest_failure_reason'),
  );
  final failure = switch (reason) {
    final value? => SyncFailureFact(
      reason: value,
      occurredAt: row.read<DateTime>('latest_failure_at').toUtc(),
      diagnosticCode: row.read<String>('latest_failure_diagnostic_code'),
      action: _mapAction(row.read<String>('latest_failure_action')),
    ),
    null => null,
  };
  return PersistedSyncFacts(
    syncEnabled: row.read<bool>('sync_enabled'),
    reauthorizationRequired: row.read<bool>('reauthorization_required'),
    lastSuccessfulSyncAt: row
        .readNullable<DateTime>('last_successful_sync_at')
        ?.toUtc(),
    latestFailure: failure,
    counts: SyncWorkCounts(
      pending: row.read<int>('pending_count'),
      inFlight: row.read<int>('in_flight_count'),
      uncertain: row.read<int>('uncertain_count'),
      failed: row.read<int>('failed_count'),
    ),
    retryWaiting: row.read<bool>('retry_waiting'),
    automaticRetryExhausted: row.read<bool>('automatic_retry_exhausted'),
    retryNextAttemptAt: row
        .readNullable<DateTime>('retry_next_attempt_at')
        ?.toUtc(),
    retryAttemptCount: row.read<int>('retry_attempt_count'),
    requiredScopeIncomplete: row.read<bool>('required_scope_incomplete'),
    followUpRequired: row.read<bool>('follow_up_required'),
  );
}

String? _failureReasonValue(SyncFailureReason? reason) => switch (reason) {
  SyncFailureReason.noConnection => 'no_connection',
  SyncFailureReason.remoteFailure => 'remote_failure',
  SyncFailureReason.applicationFailure => 'application_failure',
  SyncFailureReason.stale => 'stale',
  null => null,
};

SyncFailureReason? _mapFailureReason(String? value) => switch (value) {
  'no_connection' => SyncFailureReason.noConnection,
  'remote_failure' => SyncFailureReason.remoteFailure,
  'application_failure' => SyncFailureReason.applicationFailure,
  'stale' => SyncFailureReason.stale,
  null => null,
  _ => throw StateError('Unknown persisted synchronization failure reason.'),
};

String? _actionValue(SyncHealthAction? action) => switch (action) {
  SyncHealthAction.none => 'none',
  SyncHealthAction.retry => 'retry',
  null => null,
  _ => throw ArgumentError.value(
    action,
    'action',
    'is not a persisted failure action',
  ),
};

SyncHealthAction _mapAction(String value) => switch (value) {
  'none' => SyncHealthAction.none,
  'retry' => SyncHealthAction.retry,
  _ => throw StateError('Unknown persisted synchronization failure action.'),
};
