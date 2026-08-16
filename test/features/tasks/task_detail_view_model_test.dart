import 'dart:async';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/task_detail_view_model.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'projects ordered direct children, progress, and valid parents',
    () async {
      final repository = _TasksRepository();
      final tasks = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: repository,
        syncHealthRepository: const _HealthRepository(),
      );
      addTearDown(tasks.dispose);
      tasks.start();
      repository.snapshots.add(_snapshot);
      await pumpEventQueue();
      tasks.selectTask(const TaskId(11));

      final detail = TaskDetailViewModel.fromTasks(tasks);

      expect(detail.state?.task.title, 'Parent');
      expect(detail.state?.children.map((child) => child.id), const <TaskId>[
        TaskId(12),
        TaskId(13),
      ]);
      expect(detail.state?.progress.completed, 1);
      expect(detail.state?.progress.total, 2);
      expect(
        detail.state?.parentCandidates.map((task) => task.id),
        const <TaskId>[TaskId(14)],
      );
    },
  );

  test('detail CRUD and reorder actions use shared domain commands', () async {
    final repository = _TasksRepository();
    final tasks = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: repository,
      syncHealthRepository: const _HealthRepository(),
    );
    addTearDown(tasks.dispose);
    tasks.start();
    repository.snapshots.add(_snapshot);
    await pumpEventQueue();
    tasks.selectTask(const TaskId(11));
    var detail = TaskDetailViewModel.fromTasks(tasks);

    await detail.createSubtask(title: 'New child');
    expect(repository.created.single, isA<CreateTaskCommand>());
    expect(repository.created.single.parentTaskId, const TaskId(11));

    await detail.saveContent(
      task: _snapshot.tasks.first,
      title: 'Parent edited',
      notes: '空 🌍\nsecond line',
      due: null,
    );
    final update = repository.applied
        .whereType<UpdateTaskContentCommand>()
        .single;
    expect(update.taskId, const TaskId(11));
    expect(update.notes, '空 🌍\nsecond line');

    await detail.moveChildDown(const TaskId(12));
    final move = repository.applied.whereType<MoveTaskCommand>().single;
    expect(move.taskId, const TaskId(12));
    expect(move.parentTaskId, const TaskId(11));
    expect(move.previousTaskId, const TaskId(13));

    await detail.deleteTask(const TaskId(13));
    expect(repository.deleted.single.taskId, const TaskId(13));

    tasks.selectTask(const TaskId(12));
    detail = TaskDetailViewModel.fromTasks(tasks);
    detail.back();
    expect(tasks.state.selectedTaskId, const TaskId(11));
    detail = TaskDetailViewModel.fromTasks(tasks);
    detail.close();
    expect(tasks.state.selectedTaskId, isNull);
  });
}

final class _TasksRepository implements TasksRepository {
  final snapshots = StreamController<CachedTasksSnapshot>.broadcast();
  final List<CreateTaskCommand> created = <CreateTaskCommand>[];
  final List<ExistingTaskCommand> applied = <ExistingTaskCommand>[];
  final List<DeleteTaskCommand> deleted = <DeleteTaskCommand>[];

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => snapshots.stream;

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream.value(const <TaskDeleteUndo>[]);

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async {
    created.add(command);
    return const Outcome<TaskId>.success(TaskId(90));
  }

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async {
    applied.add(command);
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async {
    deleted.add(command);
    return Outcome<TaskDeleteReceipt>.success(
      TaskDeleteReceipt(taskId: command.taskId, notBefore: DateTime.utc(2026)),
    );
  }

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      const Outcome<void>.success(null);
}

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026),
    ),
  );
}

final _snapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: null,
      title: 'Synthetic list',
    ),
  ],
  tasks: <CachedTask>[
    const CachedTask(
      id: TaskId(11),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: null,
      title: 'Parent',
      notes: '',
      status: TaskStatus.needsAction,
      due: null,
    ),
    const CachedTask(
      id: TaskId(12),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(11),
      remoteId: null,
      title: 'First child',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
    const CachedTask(
      id: TaskId(13),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(11),
      remoteId: null,
      title: 'Second child',
      notes: null,
      status: TaskStatus.completed,
      due: null,
    ),
    const CachedTask(
      id: TaskId(14),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: null,
      title: 'Other parent',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
  ],
  completeness: CacheCompleteness.complete,
);
