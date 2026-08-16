import 'package:drift/drift.dart';

import '../../domain/model/bulk_operations.dart';
import '../../domain/model/tasks.dart';
import 'app_database.dart';

final class BulkOperationMemberInput {
  const BulkOperationMemberInput({
    required this.taskId,
    required this.desiredStateId,
    required this.generation,
  });

  final TaskId taskId;
  final int desiredStateId;
  final int generation;
}

final class BulkOperationDao {
  const BulkOperationDao(this._database);

  final AppDatabase _database;

  Future<BulkOperationSummary> replaceLatest({
    required AccountId accountId,
    required BulkOperationKind kind,
    required int selectedCount,
    required List<BulkOperationMemberInput> members,
    required DateTime createdAt,
  }) async {
    await (_database.delete(
      _database.bulkOperationRows,
    )..where((row) => row.accountId.equals(accountId.value))).go();
    final operationId = await _database
        .into(_database.bulkOperationRows)
        .insert(
          BulkOperationRowsCompanion.insert(
            accountId: accountId.value,
            kind: kind.name,
            selectedCount: selectedCount,
            affectedCount: members.length,
            createdAt: createdAt.toUtc(),
          ),
        );
    for (final member in members) {
      await _database
          .into(_database.bulkOperationMemberRows)
          .insert(
            BulkOperationMemberRowsCompanion.insert(
              accountId: accountId.value,
              operationId: operationId,
              taskId: member.taskId.value,
              desiredStateId: member.desiredStateId,
              generation: member.generation,
              outcome: 'pending',
            ),
          );
    }
    return BulkOperationSummary(
      operationId: operationId,
      kind: kind,
      selectedCount: selectedCount,
      affectedCount: members.length,
      confirmedCount: 0,
      pendingCount: members.length,
      failedCount: 0,
      createdAt: createdAt.toUtc(),
    );
  }

  Stream<BulkOperationSummary?> watchLatest(AccountId accountId) {
    final query = _database.customSelect(
      '''
      SELECT
        operation.id,
        operation.kind,
        operation.selected_count,
        operation.affected_count,
        operation.created_at,
        COALESCE(SUM(CASE WHEN member.outcome = 'confirmed' THEN 1 ELSE 0 END), 0)
          AS confirmed_count,
        COALESCE(SUM(CASE WHEN member.outcome = 'pending' THEN 1 ELSE 0 END), 0)
          AS pending_count,
        COALESCE(SUM(CASE WHEN member.outcome = 'failed' THEN 1 ELSE 0 END), 0)
          AS failed_count
      FROM bulk_operations operation
      LEFT JOIN bulk_operation_members member
        ON member.account_id = operation.account_id
       AND member.operation_id = operation.id
      WHERE operation.account_id = ?1
      GROUP BY operation.id
      ''',
      variables: <Variable<Object>>[Variable<int>(accountId.value)],
      readsFrom: <ResultSetImplementation<Table, Object?>>{
        _database.bulkOperationRows,
        _database.bulkOperationMemberRows,
      },
    );
    return query.watchSingleOrNull().map((row) {
      if (row == null) return null;
      return BulkOperationSummary(
        operationId: row.read<int>('id'),
        kind: _kind(row.read<String>('kind')),
        selectedCount: row.read<int>('selected_count'),
        affectedCount: row.read<int>('affected_count'),
        confirmedCount: row.read<int>('confirmed_count'),
        pendingCount: row.read<int>('pending_count'),
        failedCount: row.read<int>('failed_count'),
        createdAt: row.read<DateTime>('created_at').toUtc(),
      );
    });
  }
}

BulkOperationKind _kind(String value) => switch (value) {
  'complete' => BulkOperationKind.complete,
  'reschedule' => BulkOperationKind.reschedule,
  'move' => BulkOperationKind.move,
  'delete' => BulkOperationKind.delete,
  'clearCompleted' => BulkOperationKind.clearCompleted,
  _ => throw StateError('unknown_bulk_operation_kind'),
};
