import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/model/tasks.dart';
import '../../domain/repository/sync_activity_repository.dart';
import 'app_database.dart';

/// Projects the durable `sync_runs` rows the engine already writes.
final class DatabaseSyncActivityRepository implements SyncActivityRepository {
  const DatabaseSyncActivityRepository(this._database);

  final AppDatabase _database;

  @override
  Stream<List<SyncRunRecord>> watchRecentRuns(
    AccountId accountId, {
    int limit = 50,
  }) {
    final query = _database.select(_database.syncRunRows)
      ..where((row) => row.accountId.equals(accountId.value))
      ..orderBy([
        (row) => OrderingTerm.desc(row.startedAt),
        (row) => OrderingTerm.desc(row.runId),
      ])
      ..limit(limit);
    return query.watch().map(
      (rows) => <SyncRunRecord>[
        for (final row in rows)
          SyncRunRecord(
            state: switch (row.state) {
              'succeeded' => SyncRunRecordState.succeeded,
              'failed' => SyncRunRecordState.failed,
              'interrupted' => SyncRunRecordState.interrupted,
              _ => SyncRunRecordState.inProgress,
            },
            triggers: _triggers(row.triggersJson),
            startedAt: row.startedAt.toUtc(),
            finishedAt: row.finishedAt?.toUtc(),
            failureCode: row.failureCode,
          ),
      ],
    );
  }

  static List<String> _triggers(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is List) return decoded.whereType<String>().toList();
    } on FormatException {
      // A malformed trigger list is shown as an unlabelled run.
    }
    return const <String>[];
  }
}
