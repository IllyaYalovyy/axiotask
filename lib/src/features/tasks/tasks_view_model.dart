import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/outcome.dart';
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
    required this.health,
    this.isSyncControlPending = false,
    this.isListCommandPending = false,
    this.selectedTaskListId,
    this.selectedTaskId,
    this.failureMessage,
    this.syncControlFailureMessage,
    this.listCommandFailureMessage,
  });

  final bool isLoading;
  final bool isRefreshing;
  final List<CachedTaskList> taskLists;
  final List<CachedTask> tasks;
  final SyncHealth health;
  final bool isSyncControlPending;
  final bool isListCommandPending;
  final TaskListId? selectedTaskListId;
  final TaskId? selectedTaskId;
  final String? failureMessage;
  final String? syncControlFailureMessage;
  final String? listCommandFailureMessage;

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
    SyncHealth? health,
    bool? isSyncControlPending,
    bool? isListCommandPending,
    Object? selectedTaskListId = _notProvided,
    Object? selectedTaskId = _notProvided,
    Object? failureMessage = _notProvided,
    Object? syncControlFailureMessage = _notProvided,
    Object? listCommandFailureMessage = _notProvided,
  }) => TasksViewState(
    isLoading: isLoading ?? this.isLoading,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    taskLists: taskLists ?? this.taskLists,
    tasks: tasks ?? this.tasks,
    health: health ?? this.health,
    isSyncControlPending: isSyncControlPending ?? this.isSyncControlPending,
    isListCommandPending: isListCommandPending ?? this.isListCommandPending,
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
  );
}

final class TasksViewModel extends ChangeNotifier {
  TasksViewModel({
    required this.accountId,
    required this.tasksRepository,
    required this.syncHealthRepository,
    this.taskListsRepository,
    this.localEditCommitted,
    this.refreshRequested,
    this.stopSyncRequested,
    this.resumeSyncRequested,
  }) : _state = TasksViewState(
         isLoading: true,
         isRefreshing: false,
         isSyncControlPending: false,
         isListCommandPending: false,
         taskLists: const <CachedTaskList>[],
         tasks: const <CachedTask>[],
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
  final Future<void> Function()? refreshRequested;
  final Future<void> Function()? stopSyncRequested;
  final Future<void> Function()? resumeSyncRequested;
  TasksViewState _state;
  StreamSubscription<CachedTasksSnapshot>? _tasksSubscription;
  StreamSubscription<SyncHealth>? _healthSubscription;
  bool _started = false;
  Future<void>? _refreshInFlight;
  Future<void>? _syncControlInFlight;
  Future<void>? _listCommandInFlight;

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
        SyncHealthAction.retry => refresh(),
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
    if (tasksSubscription != null) unawaited(tasksSubscription.cancel());
    if (healthSubscription != null) unawaited(healthSubscription.cancel());
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
