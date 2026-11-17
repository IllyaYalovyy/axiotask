import 'dart:async';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/bulk_operations.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/completion_policy.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/task_detail_view_model.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _account = AccountId(1);
const _list = TaskListId(1);
const _parent = TaskId(10);
const _child = TaskId(11);
const _other = TaskId(12);

void main() {
  late ManualClock clock;
  late _CompletionRepository repository;
  late TasksViewModel model;
  late int committedEdits;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 11, 16, 12));
    repository = _CompletionRepository(clock);
    committedEdits = 0;
    model = TasksViewModel(
      accountId: _account,
      tasksRepository: repository,
      syncHealthRepository: _HealthRepository(),
      clock: clock,
      localEditCommitted: () async => committedEdits += 1,
    )..start();
    await pumpEventQueue();
    model.selectTaskList(_list);
  });

  tearDown(() => model.dispose());

  test(
    'every single-task completion goes through the shared command',
    () async {
      await model.setTaskCompletion(_parent, TaskStatus.completed);

      expect(repository.completionCommands.single.taskId, _parent);
      expect(repository.applied, isEmpty, reason: 'no bypass of the policy');
      final undo = model.state.taskCompletionUndo!;
      expect(undo.title, 'Parent');
      expect(undo.cascadedCount, 1);
      expect(committedEdits, 1, reason: 'sync is woken after the commit');

      final details = TaskDetailViewModel.fromTasks(
        model,
        navigateToTask: (_) {},
        navigateBack: () {},
      );
      await details.toggleCompletion(_other);
      expect(repository.completionCommands.last.taskId, _other);
      expect(repository.completionCommands.last.status, TaskStatus.completed);
      expect(model.state.taskCompletionUndo!.title, 'Other');
    },
  );

  test('Undo restores and withdraws the offer', () async {
    await model.setTaskCompletion(_parent, TaskStatus.completed);
    final undo = model.state.taskCompletionUndo!;

    await model.undoTaskCompletion();

    expect(repository.undoCommands.single.operationId, undo.operationId);
    expect(model.state.taskCompletionUndo, isNull);
    expect(model.state.taskCommandFailureMessage, isNull);
    expect(repository.status[_parent], TaskStatus.needsAction);
    expect(repository.status[_child], TaskStatus.needsAction);
  });

  test('reopening withdraws the offer; a no-op keeps it', () async {
    await model.setTaskCompletion(_parent, TaskStatus.completed);
    final undo = model.state.taskCompletionUndo!;

    await model.setTaskCompletion(_parent, TaskStatus.completed);
    expect(model.state.taskCompletionUndo?.operationId, undo.operationId);

    await model.setTaskCompletion(_child, TaskStatus.needsAction);
    expect(model.state.taskCompletionUndo, isNull);
  });

  test('the offer expires with the Undo window', () async {
    await model.setTaskCompletion(_parent, TaskStatus.completed);

    clock.advance(taskCompletionUndoWindow - const Duration(milliseconds: 1));
    expect(model.state.taskCompletionUndo, isNotNull);
    clock.advance(const Duration(milliseconds: 1));
    expect(model.state.taskCompletionUndo, isNull);
  });

  test('a stale or expired receipt withdraws the offer and explains', () async {
    await model.setTaskCompletion(_parent, TaskStatus.completed);
    repository.nextUndoFailure = 'task.completion_undo_unavailable';

    await model.undoTaskCompletion();

    expect(model.state.taskCompletionUndo, isNull);
    expect(
      model.state.taskCommandFailureMessage,
      'The completion changed again and can no longer be undone.',
    );
    expect(repository.status[_parent], TaskStatus.completed);

    await model.setTaskCompletion(_other, TaskStatus.completed);
    repository.nextUndoFailure = 'task.completion_undo_expired';
    await model.undoTaskCompletion();
    expect(model.state.taskCompletionUndo, isNull);
    expect(
      model.state.taskCommandFailureMessage,
      'The completion can no longer be undone.',
    );
  });

  test('a persistence failure keeps the offer for a retry', () async {
    await model.setTaskCompletion(_parent, TaskStatus.completed);
    repository.nextUndoFailure = 'task.persistence_failed';

    await model.undoTaskCompletion();

    expect(model.state.taskCompletionUndo, isNotNull);
    expect(
      model.state.taskCommandFailureMessage,
      'The task could not be saved safely.',
    );
    await model.undoTaskCompletion();
    expect(model.state.taskCompletionUndo, isNull);
    expect(repository.status[_parent], TaskStatus.needsAction);
  });

  test('a failed completion offers no Undo', () async {
    repository.nextCompletionFailure = 'task.persistence_failed';

    await model.setTaskCompletion(_parent, TaskStatus.completed);

    expect(model.state.taskCompletionUndo, isNull);
    expect(model.state.taskCommandFailureMessage, isNotNull);
  });

  test('bulk completion offers the same Undo', () async {
    model.toggleBulkSelection(_parent);
    model.toggleBulkSelection(_other);

    await model.completeBulkSelection();

    final undo = model.state.taskCompletionUndo!;
    expect(undo.title, isNull);
    expect(undo.completedCount, 3);
    expect(undo.cascadedCount, 1);
  });

  test('disposal cancels the expiry timer', () async {
    await model.setTaskCompletion(_parent, TaskStatus.completed);
    model.dispose();
    clock.advance(taskCompletionUndoWindow);
    // Recreated so tearDown can dispose a live model.
    model = TasksViewModel(
      accountId: _account,
      tasksRepository: repository,
      syncHealthRepository: _HealthRepository(),
      clock: clock,
    );
  });

  testWidgets('the banner names the scope and its Undo is tappable', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: AdaptiveShell(viewModel: model)));
    await tester.pumpAndSettle();

    await model.setTaskCompletion(_parent, TaskStatus.completed);
    await tester.pumpAndSettle();
    final banner = find.byKey(const Key('task-completion-undo'));
    expect(
      find.descendant(
        of: banner,
        matching: find.text('“Parent” and 1 subtask completed'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('task-completion-undo-action')));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(repository.status[_parent], TaskStatus.needsAction);

    await model.setTaskCompletion(_child, TaskStatus.completed);
    await tester.pumpAndSettle();
    expect(find.text('“Child” completed'), findsOneWidget);

    model.toggleBulkSelection(_parent);
    model.toggleBulkSelection(_other);
    await model.completeBulkSelection();
    await tester.pumpAndSettle();
    expect(find.text('2 tasks and 0 subtasks completed'), findsNothing);
    expect(find.text('2 tasks completed'), findsOneWidget);
  });
}

/// A scripted repository that applies the real completion policy in memory.
final class _CompletionRepository
    implements
        TasksRepository,
        TaskCompletionRepository,
        BulkTaskOperationsRepository {
  _CompletionRepository(this.clock);

  final ManualClock clock;
  final status = <TaskId, TaskStatus>{
    _parent: TaskStatus.needsAction,
    _child: TaskStatus.needsAction,
    _other: TaskStatus.needsAction,
  };
  final completionCommands = <SetTaskCompletionCommand>[];
  final undoCommands = <UndoTaskCompletionCommand>[];
  final applied = <ExistingTaskCommand>[];
  final _snapshots = StreamController<CachedTasksSnapshot>.broadcast();
  String? nextUndoFailure;
  String? nextCompletionFailure;
  var _sequence = 0;
  ({int id, List<TaskStatusChange> changes})? _offer;

  List<CachedTask> get _tasks => <CachedTask>[
    _task(_parent, 'Parent', null),
    _task(_child, 'Child', _parent),
    _task(_other, 'Other', null),
  ];

  CachedTask _task(TaskId id, String title, TaskId? parent) => CachedTask(
    id: id,
    accountId: _account,
    taskListId: _list,
    parentTaskId: parent,
    remoteId: TaskRemoteId('remote-${id.value}'),
    title: title,
    notes: null,
    status: status[id]!,
    due: null,
  );

  CachedTasksSnapshot get _snapshot => CachedTasksSnapshot(
    accountId: _account,
    taskLists: const <CachedTaskList>[
      CachedTaskList(
        id: _list,
        accountId: _account,
        remoteId: TaskListRemoteId('remote-list'),
        title: 'List',
      ),
    ],
    tasks: _tasks,
    completeness: CacheCompleteness.complete,
  );

  void _apply(List<TaskStatusChange> changes) {
    for (final change in changes) {
      status[change.taskId] = change.after;
    }
    _snapshots.add(_snapshot);
  }

  TaskCompletionUndo? _record(TaskCompletionPlan plan, String? title) {
    _sequence += 1;
    if (plan.changes.first.after != TaskStatus.completed) {
      _offer = null;
      return null;
    }
    _offer = (id: _sequence, changes: plan.changes);
    return TaskCompletionUndo(
      operationId: _sequence,
      title: title,
      completedCount: plan.changes.length,
      cascadedCount: plan.cascadedCount,
      createdAt: clock.now(),
      expiresAt: clock.now().add(taskCompletionUndoWindow),
    );
  }

  @override
  Future<Outcome<TaskCompletionReceipt>> setTaskCompletion(
    SetTaskCompletionCommand command,
  ) async {
    completionCommands.add(command);
    if (nextCompletionFailure case final code?) {
      nextCompletionFailure = null;
      return Outcome<TaskCompletionReceipt>.failure(_failure(code));
    }
    final plan = planTaskCompletion(
      tasks: _tasks,
      taskId: command.taskId,
      status: command.status,
    );
    if (plan.isEmpty) {
      return Outcome<TaskCompletionReceipt>.success(
        TaskCompletionReceipt(changedTaskIds: const <TaskId>[]),
      );
    }
    _apply(plan.changes);
    final title = _tasks.singleWhere((task) => task.id == command.taskId).title;
    return Outcome<TaskCompletionReceipt>.success(
      TaskCompletionReceipt(
        changedTaskIds: plan.changes.map((change) => change.taskId).toList(),
        undo: _record(plan, title),
      ),
    );
  }

  @override
  Future<Outcome<TaskCompletionUndoResult>> undoTaskCompletion(
    UndoTaskCompletionCommand command,
  ) async {
    undoCommands.add(command);
    if (nextUndoFailure case final code?) {
      nextUndoFailure = null;
      return Outcome<TaskCompletionUndoResult>.failure(_failure(code));
    }
    final offer = _offer;
    if (offer == null || offer.id != command.operationId) {
      return Outcome<TaskCompletionUndoResult>.failure(
        _failure('task.completion_undo_unavailable'),
      );
    }
    final plan = planTaskCompletionUndo(
      recorded: offer.changes,
      current: Map<TaskId, TaskStatus>.of(status),
    );
    _apply(plan.restore);
    _offer = null;
    return Outcome<TaskCompletionUndoResult>.success(
      TaskCompletionUndoResult(
        restoredTaskIds: plan.restore.map((change) => change.taskId).toList(),
        skippedTaskIds: plan.skipped,
      ),
    );
  }

  @override
  Future<Outcome<BulkOperationReceipt>> applyBulk(
    BulkExistingTaskCommand command,
  ) async {
    final plan = planCompletionOfTasks(
      tasks: _tasks,
      taskIds: command.taskIds,
      status: TaskStatus.completed,
    );
    _apply(plan.changes);
    final members = plan.changes
        .map((change) => change.taskId)
        .where(command.taskIds.contains)
        .toList();
    return Outcome<BulkOperationReceipt>.success(
      BulkOperationReceipt(
        summary: BulkOperationSummary(
          operationId: 1,
          kind: BulkOperationKind.complete,
          selectedCount: command.taskIds.length,
          affectedCount: members.length,
          confirmedCount: 0,
          pendingCount: members.length,
          failedCount: 0,
          createdAt: clock.now(),
        ),
        taskIds: members,
        completionUndo: plan.isEmpty ? null : _record(plan, null),
      ),
    );
  }

  @override
  Stream<BulkOperationSummary?> watchLatestBulkOperation(AccountId accountId) =>
      Stream<BulkOperationSummary?>.value(null);

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) async* {
    yield _snapshot;
    yield* _snapshots.stream;
  }

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream<List<TaskDeleteUndo>>.value(const <TaskDeleteUndo>[]);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => Stream<List<TaskDueChangeUndo>>.value(const <TaskDueChangeUndo>[]);

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async {
    applied.add(command);
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) =>
      throw UnimplementedError();

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(SetTaskDueCommand command) =>
      throw UnimplementedError();

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(DeleteTaskCommand command) =>
      throw UnimplementedError();

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) =>
      throw UnimplementedError();

  @override
  Future<Outcome<void>> undoTaskDueChange(UndoTaskDueChangeCommand command) =>
      throw UnimplementedError();
}

Failure _failure(String code) => Failure(
  code: code,
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'Synthetic failure.',
  safeSummary: 'Synthetic failure.',
);

final class _HealthRepository implements SyncHealthRepository {
  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.good,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: DateTime.utc(2026, 11, 16, 12),
      evaluatedAt: DateTime.utc(2026, 11, 16, 12),
    ),
  );
}
