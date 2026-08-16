import 'package:drift/drift.dart';

import '../../domain/commands/task_commands.dart';
import '../../domain/model/tasks.dart';
import '../../domain/policy/date_workflow.dart';
import 'app_database.dart';

final class DueChangeSnapshotRecord {
  const DueChangeSnapshotRecord({required this.taskId, required this.priorDue});

  final TaskId taskId;
  final TaskDate? priorDue;
}

final class DueChangeGroupRecord {
  const DueChangeGroupRecord({
    required this.groupId,
    required this.editedTaskId,
    required this.snapshotCount,
    required this.cascadedParent,
    required this.createdAt,
  });

  final int groupId;
  final TaskId editedTaskId;
  final int snapshotCount;
  final bool cascadedParent;
  final DateTime createdAt;
}

final class DueChangeDao {
  const DueChangeDao(this._database);

  final AppDatabase _database;

  Future<void> clearAvailable(AccountId accountId) async {
    await (_database.delete(
      _database.taskDueChangeGroupRows,
    )..where((row) => row.accountId.equals(accountId.value))).go();
  }

  Future<TaskDueChangeUndo> create({
    required AccountId accountId,
    required CachedTask editedTask,
    required DueCascadePlan plan,
    required DateTime createdAt,
  }) async {
    if (plan.cascadedCount <= 0) {
      throw const DueChangeStateException('due_change_has_no_cascade');
    }
    final groupId = await _database
        .into(_database.taskDueChangeGroupRows)
        .insert(
          TaskDueChangeGroupRowsCompanion.insert(
            accountId: accountId.value,
            editedTaskId: editedTask.id.value,
            snapshotCount: plan.changes.length,
            cascadedParent: plan.cascadedParent,
            createdAt: createdAt,
          ),
        );
    for (final change in plan.changes) {
      await _database
          .into(_database.taskDueChangeSnapshotRows)
          .insert(
            TaskDueChangeSnapshotRowsCompanion.insert(
              accountId: accountId.value,
              groupId: groupId,
              taskId: change.taskId.value,
              priorDueEpochDay: Value<int?>(_epochDay(change.before)),
            ),
          );
    }
    return TaskDueChangeUndo(
      groupId: groupId,
      editedTaskId: editedTask.id,
      editedTaskTitle: editedTask.title,
      cascadedCount: plan.cascadedCount,
      cascadedParent: plan.cascadedParent,
      createdAt: createdAt,
    );
  }

  Future<DueChangeGroupRecord?> readGroup(
    AccountId accountId,
    int groupId,
  ) async {
    final row =
        await (_database.select(_database.taskDueChangeGroupRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(groupId),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    return DueChangeGroupRecord(
      groupId: row.id,
      editedTaskId: TaskId(row.editedTaskId),
      snapshotCount: row.snapshotCount,
      cascadedParent: row.cascadedParent,
      createdAt: row.createdAt,
    );
  }

  Future<List<DueChangeSnapshotRecord>> readSnapshots(
    AccountId accountId,
    int groupId,
  ) async {
    final rows =
        await (_database.select(_database.taskDueChangeSnapshotRows)
              ..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.groupId.equals(groupId),
              )
              ..orderBy(
                <OrderingTerm Function($TaskDueChangeSnapshotRowsTable)>[
                  (row) => OrderingTerm.asc(row.id),
                ],
              ))
            .get();
    return rows
        .map(
          (row) => DueChangeSnapshotRecord(
            taskId: TaskId(row.taskId),
            priorDue: _taskDate(row.priorDueEpochDay),
          ),
        )
        .toList(growable: false);
  }

  Future<void> deleteGroup(AccountId accountId, int groupId) async {
    await (_database.delete(_database.taskDueChangeGroupRows)..where(
          (row) =>
              row.accountId.equals(accountId.value) & row.id.equals(groupId),
        ))
        .go();
  }

  Stream<List<TaskDueChangeUndo>> watchAvailable(AccountId accountId) {
    return _database
        .customSelect(
          '''
          SELECT
            g.id AS group_id,
            g.edited_task_id AS edited_task_id,
            t.title AS edited_task_title,
            g.snapshot_count AS snapshot_count,
            g.cascaded_parent AS cascaded_parent,
            g.created_at AS created_at
          FROM task_due_change_groups g
          JOIN tasks t
            ON t.account_id = g.account_id
           AND t.id = g.edited_task_id
          WHERE g.account_id = ?1
            AND t.projection = 'supported'
          ORDER BY g.created_at DESC, g.id DESC
          ''',
          variables: <Variable<Object>>[Variable<int>(accountId.value)],
          readsFrom: <ResultSetImplementation<Object?, Object?>>{
            _database.taskDueChangeGroupRows,
            _database.taskDueChangeSnapshotRows,
            _database.taskCacheRows,
          },
        )
        .watch()
        .map(
          (rows) => rows
              .map(
                (row) => TaskDueChangeUndo(
                  groupId: row.read<int>('group_id'),
                  editedTaskId: TaskId(row.read<int>('edited_task_id')),
                  editedTaskTitle: row.read<String>('edited_task_title'),
                  cascadedCount: row.read<int>('snapshot_count') - 1,
                  cascadedParent: row.read<int>('cascaded_parent') == 1,
                  createdAt: row.read<DateTime>('created_at').toUtc(),
                ),
              )
              .toList(growable: false),
        );
  }
}

final class DueChangeStateException implements Exception {
  const DueChangeStateException(this.code);

  final String code;
}

int? _epochDay(TaskDate? value) => value == null
    ? null
    : DateTime.utc(value.year, value.month, value.day).millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay;

TaskDate? _taskDate(int? epochDay) {
  if (epochDay == null) return null;
  final value = DateTime.fromMillisecondsSinceEpoch(
    epochDay * Duration.millisecondsPerDay,
    isUtc: true,
  );
  return TaskDate(value.year, value.month, value.day);
}
