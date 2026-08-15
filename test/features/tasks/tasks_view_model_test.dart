import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/task_lists_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'renders cached rows immediately and keeps health as independent truth',
    () async {
      final tasks = _TasksRepository();
      final health = _HealthRepository();
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: tasks,
        syncHealthRepository: health,
      );
      addTearDown(viewModel.dispose);

      viewModel.start();
      tasks.controller.add(_snapshot);
      health.controller.add(_pending);
      await pumpEventQueue();

      expect(viewModel.state.isLoading, isFalse);
      expect(viewModel.state.taskLists.single.title, 'Synthetic inbox');
      expect(viewModel.state.visibleTasks.map((task) => task.title), <String>[
        'Cached parent',
      ]);
      expect(viewModel.state.health.outcome, SyncHealthOutcome.pending);
      expect(viewModel.state.health.lastSuccessLabel, 'Never');
    },
  );

  test(
    'selection exposes task details and direct subtasks without mutating',
    () async {
      final tasks = _TasksRepository();
      final health = _HealthRepository();
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: tasks,
        syncHealthRepository: health,
      );
      addTearDown(viewModel.dispose);
      viewModel.start();
      tasks.controller.add(_snapshot);
      health.controller.add(_pending);
      await pumpEventQueue();

      viewModel.selectTask(const TaskId(11));

      expect(viewModel.state.selectedTask?.title, 'Cached parent');
      expect(viewModel.state.selectedTaskChildren.single.title, 'Cached child');
    },
  );

  test(
    'Refresh delegates once while the foreground verification is active',
    () async {
      final tasks = _TasksRepository();
      final health = _HealthRepository();
      final refresh = Completer<void>();
      var calls = 0;
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: tasks,
        syncHealthRepository: health,
        refreshRequested: () {
          calls += 1;
          return refresh.future;
        },
      );
      addTearDown(viewModel.dispose);

      final first = viewModel.refresh();
      final duplicate = viewModel.refresh();
      expect(viewModel.state.isRefreshing, isTrue);
      expect(calls, 1);
      refresh.complete();
      await Future.wait(<Future<void>>[first, duplicate]);

      expect(viewModel.state.isRefreshing, isFalse);
      expect(calls, 1);
    },
  );

  test(
    'Stop and Resume delegate once and expose deterministic progress',
    () async {
      final tasks = _TasksRepository();
      final health = _HealthRepository();
      final stop = Completer<void>();
      var stopCalls = 0;
      var resumeCalls = 0;
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: tasks,
        syncHealthRepository: health,
        stopSyncRequested: () {
          stopCalls += 1;
          return stop.future;
        },
        resumeSyncRequested: () async {
          resumeCalls += 1;
        },
      );
      addTearDown(viewModel.dispose);

      final first = viewModel.stopSync();
      final duplicate = viewModel.stopSync();
      expect(viewModel.state.isSyncControlPending, isTrue);
      expect(stopCalls, 1);
      stop.complete();
      await Future.wait(<Future<void>>[first, duplicate]);
      expect(viewModel.state.isSyncControlPending, isFalse);

      await viewModel.handleSyncHealthAction(SyncHealthAction.resume);
      expect(resumeCalls, 1);
    },
  );

  test(
    'list create waits for durable repository success and suppresses duplicate taps',
    () async {
      final tasks = _TasksRepository();
      final health = _HealthRepository();
      final lists = _TaskListsRepository();
      final durable = Completer<Outcome<TaskListId>>();
      lists.createResult = durable.future;
      var committedNotifications = 0;
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: tasks,
        taskListsRepository: lists,
        syncHealthRepository: health,
        localEditCommitted: () async {
          committedNotifications += 1;
        },
      );
      addTearDown(viewModel.dispose);

      final first = viewModel.createTaskList('Offline list');
      final duplicate = viewModel.createTaskList('Duplicate tap');
      expect(viewModel.state.isListCommandPending, isTrue);
      expect(lists.createCalls, 1);
      expect(committedNotifications, 0);
      durable.complete(const Outcome<TaskListId>.success(TaskListId(19)));
      await Future.wait(<Future<void>>[first, duplicate]);

      expect(viewModel.state.isListCommandPending, isFalse);
      expect(viewModel.state.listCommandFailureMessage, isNull);
      expect(committedNotifications, 1);
      expect(lists.created.single.title, 'Offline list');
    },
  );

  test(
    'list persistence failure is visible and never schedules sync',
    () async {
      final lists = _TaskListsRepository()
        ..createResult = Future.value(
          const Outcome<TaskListId>.failure(_listPersistenceFailure),
        );
      var notifications = 0;
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: _TasksRepository(),
        taskListsRepository: lists,
        syncHealthRepository: _HealthRepository(),
        localEditCommitted: () async {
          notifications += 1;
        },
      );
      addTearDown(viewModel.dispose);

      await viewModel.createTaskList('Unsafe result');

      expect(
        viewModel.state.listCommandFailureMessage,
        'The task list could not be saved safely.',
      );
      expect(notifications, 0);
    },
  );

  test(
    'task create waits for durable success and suppresses duplicate taps',
    () async {
      final tasks = _TasksRepository();
      final durable = Completer<Outcome<TaskId>>();
      tasks.createResult = durable.future;
      var notifications = 0;
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: tasks,
        syncHealthRepository: _HealthRepository(),
        localEditCommitted: () async {
          notifications += 1;
        },
      );
      addTearDown(viewModel.dispose);

      final first = viewModel.createTask(
        taskListId: const TaskListId(7),
        title: 'Offline task',
      );
      final duplicate = viewModel.createTask(
        taskListId: const TaskListId(7),
        title: 'Duplicate tap',
      );
      expect(viewModel.state.isTaskCommandPending, isTrue);
      expect(tasks.createCalls, 1);
      expect(notifications, 0);
      durable.complete(const Outcome<TaskId>.success(TaskId(21)));
      await Future.wait(<Future<void>>[first, duplicate]);

      expect(viewModel.state.isTaskCommandPending, isFalse);
      expect(viewModel.state.taskCommandFailureMessage, isNull);
      expect(tasks.created.single.title, 'Offline task');
      expect(notifications, 1);
    },
  );

  test(
    'task persistence failure is visible and never schedules sync',
    () async {
      final tasks = _TasksRepository()
        ..applyResult = Future.value(
          const Outcome<void>.failure(_taskPersistenceFailure),
        );
      var notifications = 0;
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: tasks,
        syncHealthRepository: _HealthRepository(),
        localEditCommitted: () async {
          notifications += 1;
        },
      );
      addTearDown(viewModel.dispose);

      await viewModel.setTaskCompletion(const TaskId(11), TaskStatus.completed);

      expect(
        viewModel.state.taskCommandFailureMessage,
        'The task could not be saved safely.',
      );
      expect(notifications, 0);
    },
  );
}

final class _TasksRepository implements TasksRepository {
  final controller = StreamController<CachedTasksSnapshot>.broadcast();
  Future<Outcome<TaskId>> createResult = Future.value(
    const Outcome<TaskId>.success(TaskId(99)),
  );
  Future<Outcome<void>> applyResult = Future.value(
    const Outcome<void>.success(null),
  );
  final List<CreateTaskCommand> created = <CreateTaskCommand>[];
  final List<ExistingTaskCommand> applied = <ExistingTaskCommand>[];
  var createCalls = 0;

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) {
    createCalls += 1;
    created.add(command);
    return createResult;
  }

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) {
    applied.add(command);
    return applyResult;
  }

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => controller.stream;
}

final class _HealthRepository implements SyncHealthRepository {
  final controller = StreamController<SyncHealth>.broadcast();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => controller.stream;
}

final class _TaskListsRepository implements TaskListsRepository {
  Future<Outcome<TaskListId>> createResult = Future.value(
    const Outcome<TaskListId>.success(TaskListId(99)),
  );
  Future<Outcome<void>> renameResult = Future.value(
    const Outcome<void>.success(null),
  );
  final List<CreateTaskListCommand> created = <CreateTaskListCommand>[];
  final List<RenameTaskListCommand> renamed = <RenameTaskListCommand>[];
  var createCalls = 0;

  @override
  Future<Outcome<TaskListId>> createTaskList(CreateTaskListCommand command) {
    createCalls += 1;
    created.add(command);
    return createResult;
  }

  @override
  Future<Outcome<void>> renameTaskList(RenameTaskListCommand command) {
    renamed.add(command);
    return renameResult;
  }
}

const _listPersistenceFailure = Failure(
  code: 'list.persistence_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The task list was not saved.',
  safeSummary: 'The list transaction failed.',
);

const _taskPersistenceFailure = Failure(
  code: 'task.persistence_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The task was not saved.',
  safeSummary: 'The task transaction failed.',
);

final _snapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-list'),
      title: 'Synthetic inbox',
    ),
  ],
  tasks: <CachedTask>[
    CachedTask(
      id: TaskId(11),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-parent'),
      title: 'Cached parent',
      notes: 'Stored locally while verification is pending.',
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 8, 16),
    ),
    const CachedTask(
      id: TaskId(12),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(11),
      remoteId: TaskRemoteId('synthetic-child'),
      title: 'Cached child',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
  ],
  completeness: CacheCompleteness.complete,
);

final _pending = SyncHealth(
  outcome: SyncHealthOutcome.pending,
  pendingReason: SyncPendingReason.verifying,
  counts: const SyncWorkCounts(),
  lastSuccessfulSyncAt: null,
  evaluatedAt: DateTime.utc(2026, 8, 15, 12),
);
