import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/outcome.dart';
import '../../domain/commands/task_commands.dart';
import '../../domain/commands/task_list_commands.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/task_lists_repository.dart';
import '../../domain/repository/tasks_repository.dart';
import '../../sync/health/sync_health.dart';
import '../../sync/health/sync_health_repository.dart';

final class TasksViewState {
  const TasksViewState({
    required this.isLoading,
    required this.isRefreshing,
    required this.taskLists,
    required this.tasks,
    required this.taskDeleteUndos,
    required this.health,
    this.isSyncControlPending = false,
    this.isListCommandPending = false,
    this.isTaskCommandPending = false,
    this.selectedTaskListId,
    this.selectedTaskId,
    this.failureMessage,
    this.syncControlFailureMessage,
    this.listCommandFailureMessage,
    this.taskCommandFailureMessage,
  });

  final bool isLoading;
  final bool isRefreshing;
  final List<CachedTaskList> taskLists;
  final List<CachedTask> tasks;
  final List<TaskDeleteUndo> taskDeleteUndos;
  final SyncHealth health;
  final bool isSyncControlPending;
  final bool isListCommandPending;
  final bool isTaskCommandPending;
  final TaskListId? selectedTaskListId;
  final TaskId? selectedTaskId;
  final String? failureMessage;
  final String? syncControlFailureMessage;
  final String? listCommandFailureMessage;
  final String? taskCommandFailureMessage;

  CachedTaskList? get selectedTaskList =>
      _firstWhereOrNull(taskLists, (value) => value.id == selectedTaskListId);

  List<CachedTask> get visibleTasks => List<CachedTask>.unmodifiable(
    tasks.where(
      (task) =>
          task.parentTaskId == null &&
          (selectedTaskListId == null || task.taskListId == selectedTaskListId),
    ),
  );

  CachedTask? get selectedTask =>
      _firstWhereOrNull(tasks, (value) => value.id == selectedTaskId);

  List<CachedTask> get selectedTaskChildren => List<CachedTask>.unmodifiable(
    tasks.where((value) => value.parentTaskId == selectedTaskId),
  );

  TasksViewState copyWith({
    bool? isLoading,
    bool? isRefreshing,
    List<CachedTaskList>? taskLists,
    List<CachedTask>? tasks,
    List<TaskDeleteUndo>? taskDeleteUndos,
    SyncHealth? health,
    bool? isSyncControlPending,
    bool? isListCommandPending,
    bool? isTaskCommandPending,
    Object? selectedTaskListId = _notProvided,
    Object? selectedTaskId = _notProvided,
    Object? failureMessage = _notProvided,
    Object? syncControlFailureMessage = _notProvided,
    Object? listCommandFailureMessage = _notProvided,
    Object? taskCommandFailureMessage = _notProvided,
  }) => TasksViewState(
    isLoading: isLoading ?? this.isLoading,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    taskLists: taskLists ?? this.taskLists,
    tasks: tasks ?? this.tasks,
    taskDeleteUndos: taskDeleteUndos ?? this.taskDeleteUndos,
    health: health ?? this.health,
    isSyncControlPending: isSyncControlPending ?? this.isSyncControlPending,
    isListCommandPending: isListCommandPending ?? this.isListCommandPending,
    isTaskCommandPending: isTaskCommandPending ?? this.isTaskCommandPending,
    selectedTaskListId: identical(selectedTaskListId, _notProvided)
        ? this.selectedTaskListId
        : selectedTaskListId as TaskListId?,
    selectedTaskId: identical(selectedTaskId, _notProvided)
        ? this.selectedTaskId
        : selectedTaskId as TaskId?,
    failureMessage: identical(failureMessage, _notProvided)
        ? this.failureMessage
        : failureMessage as String?,
    syncControlFailureMessage:
        identical(syncControlFailureMessage, _notProvided)
        ? this.syncControlFailureMessage
        : syncControlFailureMessage as String?,
    listCommandFailureMessage:
        identical(listCommandFailureMessage, _notProvided)
        ? this.listCommandFailureMessage
        : listCommandFailureMessage as String?,
    taskCommandFailureMessage:
        identical(taskCommandFailureMessage, _notProvided)
        ? this.taskCommandFailureMessage
        : taskCommandFailureMessage as String?,
  );
}

final class TasksViewModel extends ChangeNotifier {
  TasksViewModel({
    required this.accountId,
    required this.tasksRepository,
    required this.syncHealthRepository,
    this.taskListsRepository,
    this.localEditCommitted,
    this.taskDeleteCommitted,
    this.refreshRequested,
    this.retryRequested,
    this.stopSyncRequested,
    this.resumeSyncRequested,
  }) : _state = TasksViewState(
         isLoading: true,
         isRefreshing: false,
         isSyncControlPending: false,
         isListCommandPending: false,
         isTaskCommandPending: false,
         taskLists: const <CachedTaskList>[],
         tasks: const <CachedTask>[],
         taskDeleteUndos: const <TaskDeleteUndo>[],
         health: SyncHealth(
           outcome: SyncHealthOutcome.pending,
           pendingReason: SyncPendingReason.checkingAuthorization,
           counts: const SyncWorkCounts(),
           lastSuccessfulSyncAt: null,
           evaluatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
         ),
       );

  final AccountId accountId;
  final TasksRepository tasksRepository;
  final SyncHealthRepository syncHealthRepository;
  final TaskListsRepository? taskListsRepository;
  final Future<void> Function()? localEditCommitted;
  final Future<void> Function(DateTime notBefore)? taskDeleteCommitted;
  final Future<void> Function()? refreshRequested;
  final Future<void> Function()? retryRequested;
  final Future<void> Function()? stopSyncRequested;
  final Future<void> Function()? resumeSyncRequested;
  TasksViewState _state;
  StreamSubscription<CachedTasksSnapshot>? _tasksSubscription;
  StreamSubscription<SyncHealth>? _healthSubscription;
  StreamSubscription<List<TaskDeleteUndo>>? _taskDeleteUndoSubscription;
  bool _started = false;
  Future<void>? _refreshInFlight;
  Future<void>? _syncControlInFlight;
  Future<void>? _listCommandInFlight;
  Future<void>? _taskCommandInFlight;

  TasksViewState get state => _state;

  void start() {
    if (_started) return;
    _started = true;
    _tasksSubscription = tasksRepository
        .watchTasks(TasksQuery(accountId: accountId))
        .listen(_acceptTasks, onError: _acceptRepositoryError);
    _healthSubscription = syncHealthRepository
        .watchHealth(accountId)
        .listen(_acceptHealth, onError: _acceptRepositoryError);
    _taskDeleteUndoSubscription = tasksRepository
        .watchUndoableTaskDeletes(accountId)
        .listen(_acceptTaskDeleteUndos, onError: _acceptTaskDeleteUndoError);
  }

  void selectTaskList(TaskListId taskListId) {
    if (!_state.taskLists.any((value) => value.id == taskListId)) return;
    _replaceState(
      _state.copyWith(selectedTaskListId: taskListId, selectedTaskId: null),
    );
  }

  void selectTask(TaskId taskId) {
    final task = _firstWhereOrNull(_state.tasks, (value) => value.id == taskId);
    if (task == null) return;
    _replaceState(
      _state.copyWith(
        selectedTaskListId: task.taskListId,
        selectedTaskId: taskId,
      ),
    );
  }

  void clearTaskSelection() {
    _replaceState(_state.copyWith(selectedTaskId: null));
  }

  Future<void> refresh() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final action = refreshRequested;
    if (action == null) return Future<void>.value();
    final operation = _performRefresh(action);
    _refreshInFlight = operation;
    return operation;
  }

  Future<void> _performRefresh(Future<void> Function() action) async {
    _replaceState(_state.copyWith(isRefreshing: true));
    try {
      await action();
    } finally {
      _refreshInFlight = null;
      _replaceState(_state.copyWith(isRefreshing: false));
    }
  }

  Future<void> stopSync() => _performSyncControl(stopSyncRequested);

  Future<void> resumeSync() => _performSyncControl(resumeSyncRequested);

  Future<void> retrySync() => _performSyncControl(retryRequested);

  Future<void> createTaskList(String title) {
    final repository = taskListsRepository;
    if (repository == null) return Future<void>.value();
    return _performListCommand(
      () => repository.createTaskList(
        CreateTaskListCommand(accountId: accountId, title: title),
      ),
    );
  }

  Future<void> renameTaskList(TaskListId taskListId, String title) {
    final repository = taskListsRepository;
    if (repository == null) return Future<void>.value();
    return _performListCommand(
      () => repository.renameTaskList(
        RenameTaskListCommand(
          accountId: accountId,
          taskListId: taskListId,
          title: title,
        ),
      ),
    );
  }

  Future<void> deleteTaskList(TaskListId taskListId) {
    final repository = taskListsRepository;
    if (repository == null) return Future<void>.value();
    return _performListCommand(
      () => repository.deleteTaskList(
        DeleteTaskListCommand(accountId: accountId, taskListId: taskListId),
      ),
    );
  }

  Future<void> createTask({
    required TaskListId taskListId,
    required String title,
    TaskId? parentTaskId,
    String? notes,
    TaskDate? due,
  }) => _performTaskCommand(
    () => tasksRepository.createTask(
      CreateTaskCommand(
        accountId: accountId,
        taskListId: taskListId,
        parentTaskId: parentTaskId,
        title: title,
        notes: notes,
        due: due,
      ),
    ),
  );

  Future<void> updateTaskContent({
    required TaskId taskId,
    required String title,
    required String? notes,
    required TaskStatus status,
    required TaskDate? due,
  }) => _performTaskCommand(
    () => tasksRepository.apply(
      UpdateTaskContentCommand(
        accountId: accountId,
        taskId: taskId,
        title: title,
        notes: notes,
        status: status,
        due: due,
      ),
    ),
  );

  Future<void> setTaskCompletion(TaskId taskId, TaskStatus status) =>
      _performTaskCommand(
        () => tasksRepository.apply(
          SetTaskCompletionCommand(
            accountId: accountId,
            taskId: taskId,
            status: status,
          ),
        ),
      );

  Future<void> promoteTask(TaskId taskId) => _performTaskCommand(
    () => tasksRepository.apply(
      PromoteTaskCommand(accountId: accountId, taskId: taskId),
    ),
  );

  Future<void> demoteTask(TaskId taskId, TaskId parentTaskId) =>
      _performTaskCommand(
        () => tasksRepository.apply(
          DemoteTaskCommand(
            accountId: accountId,
            taskId: taskId,
            parentTaskId: parentTaskId,
          ),
        ),
      );

  Future<void> moveTask({
    required TaskId taskId,
    required TaskListId destinationTaskListId,
    TaskId? parentTaskId,
    TaskId? previousTaskId,
  }) => _performTaskCommand(
    () => tasksRepository.apply(
      MoveTaskCommand(
        accountId: accountId,
        taskId: taskId,
        destinationTaskListId: destinationTaskListId,
        parentTaskId: parentTaskId,
        previousTaskId: previousTaskId,
      ),
    ),
  );

  Future<void> deleteTask(TaskId taskId) => _performTaskCommand(
    () => tasksRepository.deleteTask(
      DeleteTaskCommand(accountId: accountId, taskId: taskId),
    ),
    onSuccess: (receipt) async {
      await taskDeleteCommitted?.call(receipt.notBefore);
    },
  );

  Future<void> undoTaskDelete(TaskId taskId) => _performTaskCommand(
    () => tasksRepository.undoTaskDelete(
      UndoTaskDeleteCommand(accountId: accountId, taskId: taskId),
    ),
  );

  Future<void> _performTaskCommand<T>(
    Future<Outcome<T>> Function() action, {
    Future<void> Function(T value)? onSuccess,
  }) {
    final existing = _taskCommandInFlight;
    if (existing != null) return existing;
    final operation = _runTaskCommand(action, onSuccess: onSuccess);
    _taskCommandInFlight = operation;
    return operation;
  }

  Future<void> _runTaskCommand<T>(
    Future<Outcome<T>> Function() action, {
    Future<void> Function(T value)? onSuccess,
  }) async {
    _replaceState(
      _state.copyWith(
        isTaskCommandPending: true,
        taskCommandFailureMessage: null,
      ),
    );
    try {
      final result = await action();
      switch (result) {
        case Success<T>(:final value):
          if (onSuccess case final callback?) {
            await callback(value);
          } else {
            await localEditCommitted?.call();
          }
        case Failed<T>(:final failure):
          _replaceState(
            _state.copyWith(
              taskCommandFailureMessage: switch (failure.code) {
                'task.title_too_long' =>
                  'Task titles can contain at most 1024 characters.',
                'task.notes_too_long' =>
                  'Task notes can contain at most 8192 characters.',
                'task.unsupported_depth' || 'task.subtree_would_exceed_depth' =>
                  'Axiotask supports one subtask level.',
                'task.parent_deleted' =>
                  'A deleted task cannot become a parent.',
                'task.parent_cross_list' || 'task.parent_cross_account' =>
                  'The parent must be in the same Google task list.',
                _ => 'The task could not be saved safely.',
              },
            ),
          );
      }
    } finally {
      _taskCommandInFlight = null;
      _replaceState(_state.copyWith(isTaskCommandPending: false));
    }
  }

  Future<void> _performListCommand<T>(Future<Outcome<T>> Function() action) {
    final existing = _listCommandInFlight;
    if (existing != null) return existing;
    final operation = _runListCommand(action);
    _listCommandInFlight = operation;
    return operation;
  }

  Future<void> _runListCommand<T>(Future<Outcome<T>> Function() action) async {
    _replaceState(
      _state.copyWith(
        isListCommandPending: true,
        listCommandFailureMessage: null,
      ),
    );
    try {
      final result = await action();
      switch (result) {
        case Success<T>():
          await localEditCommitted?.call();
        case Failed<T>(:final failure):
          _replaceState(
            _state.copyWith(
              listCommandFailureMessage:
                  failure.code == 'task_list.title_too_long'
                  ? 'Task list titles can contain at most 1024 characters.'
                  : 'The task list could not be saved safely.',
            ),
          );
      }
    } finally {
      _listCommandInFlight = null;
      _replaceState(_state.copyWith(isListCommandPending: false));
    }
  }

  Future<void> handleSyncHealthAction(SyncHealthAction action) =>
      switch (action) {
        SyncHealthAction.resume => resumeSync(),
        SyncHealthAction.retry => retrySync(),
        SyncHealthAction.none ||
        SyncHealthAction.connect ||
        SyncHealthAction.reauthorize => Future<void>.value(),
      };

  Future<void> _performSyncControl(Future<void> Function()? action) {
    final existing = _syncControlInFlight;
    if (existing != null) return existing;
    if (action == null) return Future<void>.value();
    final operation = _runSyncControl(action);
    _syncControlInFlight = operation;
    return operation;
  }

  Future<void> _runSyncControl(Future<void> Function() action) async {
    _replaceState(
      _state.copyWith(
        isSyncControlPending: true,
        syncControlFailureMessage: null,
      ),
    );
    try {
      await action();
    } on Object {
      _replaceState(
        _state.copyWith(
          syncControlFailureMessage:
              'The synchronization setting could not be saved safely.',
        ),
      );
    } finally {
      _syncControlInFlight = null;
      _replaceState(_state.copyWith(isSyncControlPending: false));
    }
  }

  void _acceptTasks(CachedTasksSnapshot snapshot) {
    final currentList = _state.selectedTaskListId;
    final selectedList =
        snapshot.taskLists.any((value) => value.id == currentList)
        ? currentList
        : snapshot.taskLists.isEmpty
        ? null
        : snapshot.taskLists.first.id;
    final currentTask = _state.selectedTaskId;
    final selectedTask = snapshot.tasks.any((value) => value.id == currentTask)
        ? currentTask
        : null;
    _replaceState(
      _state.copyWith(
        isLoading: false,
        taskLists: List<CachedTaskList>.unmodifiable(snapshot.taskLists),
        tasks: List<CachedTask>.unmodifiable(snapshot.tasks),
        selectedTaskListId: selectedList,
        selectedTaskId: selectedTask,
        failureMessage: null,
      ),
    );
  }

  void _acceptHealth(SyncHealth health) {
    _replaceState(_state.copyWith(health: health));
  }

  void _acceptTaskDeleteUndos(List<TaskDeleteUndo> values) {
    _replaceState(
      _state.copyWith(
        taskDeleteUndos: List<TaskDeleteUndo>.unmodifiable(values),
      ),
    );
  }

  void _acceptTaskDeleteUndoError(Object _) {
    _replaceState(
      _state.copyWith(
        taskCommandFailureMessage: 'Undo state could not be read safely.',
      ),
    );
  }

  void _acceptRepositoryError(Object _) {
    _replaceState(
      _state.copyWith(
        isLoading: false,
        failureMessage: 'Cached data could not be read safely.',
      ),
    );
  }

  void _replaceState(TasksViewState value) {
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    final tasksSubscription = _tasksSubscription;
    final healthSubscription = _healthSubscription;
    final taskDeleteUndoSubscription = _taskDeleteUndoSubscription;
    if (tasksSubscription != null) unawaited(tasksSubscription.cancel());
    if (healthSubscription != null) unawaited(healthSubscription.cancel());
    if (taskDeleteUndoSubscription != null) {
      unawaited(taskDeleteUndoSubscription.cancel());
    }
    super.dispose();
  }
}

const Object _notProvided = Object();

T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) predicate) {
  for (final value in values) {
    if (predicate(value)) return value;
  }
  return null;
}
