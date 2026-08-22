import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/bulk_operations.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_clock.dart';

void main() {
  test('PAR-BULK-001 selection is transient and collection-scoped', () async {
    final repository = _BulkRepository();
    final model = _model(repository)..start();
    addTearDown(model.dispose);
    repository.tasks.add(_snapshot);
    repository.health.add(_pendingHealth);
    await Future<void>.delayed(Duration.zero);

    model.beginBulkSelection(const TaskId(11));
    model.toggleBulkSelection(const TaskId(13));
    expect(model.state.bulkSelectedTaskIds, <TaskId>{
      const TaskId(11),
      const TaskId(13),
    });
    model.toggleBulkSelection(const TaskId(11));
    expect(model.state.bulkSelectedTaskIds, <TaskId>{const TaskId(13)});

    model.selectTaskList(const TaskListId(8));
    expect(model.state.bulkSelectedTaskIds, isEmpty);
  });

  test(
    'bulk result with pending Google work clears selection and remains actionable',
    () async {
      final repository = _BulkRepository();
      final edits = <String>[];
      final model = _model(
        repository,
        localEditCommitted: () async => edits.add('committed'),
      )..start();
      addTearDown(model.dispose);
      repository.tasks.add(_snapshot);
      repository.health.add(_pendingHealth);
      await Future<void>.delayed(Duration.zero);
      model.beginBulkSelection(const TaskId(11));
      model.toggleBulkSelection(const TaskId(13));

      await model.completeBulkSelection();
      repository.summaries.add(_summary);
      await Future<void>.delayed(Duration.zero);

      expect(repository.commands.single, isA<BulkCompleteTasksCommand>());
      expect(model.state.bulkSelectedTaskIds, isEmpty);
      expect(model.state.latestBulkOperation, same(_summary));
      expect(model.state.transientFeedback, isNull);
      expect(model.state.bulkCommandFailureMessage, isNull);
      expect(edits, <String>['committed']);
    },
  );

  test(
    'settled bulk success clears after its deterministic short deadline',
    () async {
      final clock = FakeClock(DateTime.utc(2026, 8, 16, 14));
      final repository = _BulkRepository()
        ..result = Outcome<BulkOperationReceipt>.success(
          BulkOperationReceipt(
            summary: _settledSummary,
            taskIds: const <TaskId>[TaskId(11)],
          ),
        );
      final model = _model(repository, clock: clock)..start();
      addTearDown(model.dispose);
      repository.tasks.add(_snapshot);
      repository.health.add(_pendingHealth);
      await pumpEventQueue();
      model.beginBulkSelection(const TaskId(11));

      await model.completeBulkSelection();

      expect(
        model.state.transientFeedback?.bulkOperation,
        same(_settledSummary),
      );
      clock.advance(const Duration(seconds: 3));
      expect(
        model.state.transientFeedback?.bulkOperation,
        same(_settledSummary),
      );
      clock.advance(const Duration(seconds: 1));
      expect(model.state.transientFeedback, isNull);
    },
  );

  test(
    'pending, partial, and failed bulk outcomes remain actionable',
    () async {
      final repository = _BulkRepository();
      final model = _model(repository)..start();
      addTearDown(model.dispose);
      repository.tasks.add(_snapshot);
      repository.health.add(_pendingHealth);
      await pumpEventQueue();

      repository.summaries.add(_summary);
      await pumpEventQueue();
      expect(model.state.latestBulkOperation, same(_summary));
      expect(model.state.transientFeedback, isNull);

      final failed = BulkOperationSummary(
        operationId: 5,
        kind: BulkOperationKind.reschedule,
        selectedCount: 2,
        affectedCount: 2,
        confirmedCount: 1,
        pendingCount: 0,
        failedCount: 1,
        createdAt: DateTime.utc(2026, 8, 16, 14),
      );
      repository.summaries.add(failed);
      await pumpEventQueue();

      expect(model.state.latestBulkOperation, same(failed));
      expect(model.state.transientFeedback, isNull);
    },
  );

  test('settled bulk history does not reappear after restart', () async {
    final repository = _BulkRepository()..initialSummary = _settledSummary;
    final first = _model(repository)..start();
    addTearDown(first.dispose);
    await pumpEventQueue();

    expect(first.state.latestBulkOperation, isNull);
    expect(first.state.transientFeedback, isNull);
  });

  test(
    'bulk transaction failure retains selection and reports no success',
    () async {
      final repository = _BulkRepository()
        ..result = const Outcome<BulkOperationReceipt>.failure(_failure);
      final model = _model(repository)..start();
      addTearDown(model.dispose);
      repository.tasks.add(_snapshot);
      repository.health.add(_pendingHealth);
      await Future<void>.delayed(Duration.zero);
      model.beginBulkSelection(const TaskId(11));

      await model.moveBulkSelection(const TaskListId(8));

      expect(model.state.bulkSelectedTaskIds, <TaskId>{const TaskId(11)});
      expect(model.state.latestBulkOperation, isNull);
      expect(
        model.state.bulkCommandFailureMessage,
        'No selected tasks were changed.',
      );
    },
  );
}

TasksViewModel _model(
  _BulkRepository repository, {
  Future<void> Function()? localEditCommitted,
  FakeClock? clock,
}) => TasksViewModel(
  accountId: const AccountId(1),
  tasksRepository: repository,
  syncHealthRepository: repository,
  localEditCommitted: localEditCommitted,
  clock: clock,
);

final class _BulkRepository
    implements
        TasksRepository,
        BulkTaskOperationsRepository,
        SyncHealthRepository {
  final tasks = StreamController<CachedTasksSnapshot>.broadcast();
  final health = StreamController<SyncHealth>.broadcast();
  final summaries = StreamController<BulkOperationSummary?>.broadcast();
  final commands = <BulkExistingTaskCommand>[];
  BulkOperationSummary? initialSummary;
  Outcome<BulkOperationReceipt> result = Outcome<BulkOperationReceipt>.success(
    BulkOperationReceipt(
      summary: _summary,
      taskIds: const <TaskId>[TaskId(11), TaskId(13)],
    ),
  );

  @override
  Future<Outcome<BulkOperationReceipt>> applyBulk(
    BulkExistingTaskCommand command,
  ) async {
    commands.add(command);
    return result;
  }

  @override
  Stream<BulkOperationSummary?> watchLatestBulkOperation(AccountId accountId) =>
      initialSummary == null ? summaries.stream : Stream.value(initialSummary);

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => tasks.stream;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => health.stream;

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      const Stream<List<TaskDeleteUndo>>.empty();

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => const Stream<List<TaskDueChangeUndo>>.empty();

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async =>
      const Outcome<TaskId>.success(TaskId(90));

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async => const Outcome<TaskDueChangeReceipt>.success(
    TaskDueChangeReceipt(undo: null),
  );

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async => Outcome<TaskDeleteReceipt>.success(
    TaskDeleteReceipt(taskId: command.taskId, notBefore: DateTime.utc(2026)),
  );

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async => const Outcome<void>.success(null);
}

final _snapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('bulk-list-a'),
      title: 'Bulk list A',
    ),
    CachedTaskList(
      id: TaskListId(8),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('bulk-list-b'),
      title: 'Bulk list B',
    ),
  ],
  tasks: const <CachedTask>[
    CachedTask(
      id: TaskId(11),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('bulk-task-a'),
      title: 'Bulk task A',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
    CachedTask(
      id: TaskId(13),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('bulk-task-b'),
      title: 'Bulk task B',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
  ],
  completeness: CacheCompleteness.complete,
);

final _summary = BulkOperationSummary(
  operationId: 4,
  kind: BulkOperationKind.complete,
  selectedCount: 2,
  affectedCount: 2,
  confirmedCount: 1,
  pendingCount: 1,
  failedCount: 0,
  createdAt: DateTime.utc(2026, 8, 16, 14),
);

final _settledSummary = BulkOperationSummary(
  operationId: 6,
  kind: BulkOperationKind.complete,
  selectedCount: 1,
  affectedCount: 1,
  confirmedCount: 1,
  pendingCount: 0,
  failedCount: 0,
  createdAt: DateTime.utc(2026, 8, 16, 14),
);

final _pendingHealth = SyncHealth(
  outcome: SyncHealthOutcome.pending,
  pendingReason: SyncPendingReason.localChanges,
  counts: const SyncWorkCounts(pending: 2),
  lastSuccessfulSyncAt: null,
  evaluatedAt: DateTime.utc(2026, 8, 16, 14),
);

const _failure = Failure(
  code: 'task.persistence_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'No selected tasks were changed.',
  safeSummary: 'The bulk transaction failed.',
);
