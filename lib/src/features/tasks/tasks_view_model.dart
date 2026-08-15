import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/model/tasks.dart';
import '../../domain/repository/tasks_repository.dart';
import '../../sync/health/sync_health.dart';
import '../../sync/health/sync_health_repository.dart';

final class TasksViewState {
  const TasksViewState({
    required this.isLoading,
    required this.taskLists,
    required this.tasks,
    required this.health,
    this.selectedTaskListId,
    this.selectedTaskId,
    this.failureMessage,
  });

  final bool isLoading;
  final List<CachedTaskList> taskLists;
  final List<CachedTask> tasks;
  final SyncHealth health;
  final TaskListId? selectedTaskListId;
  final TaskId? selectedTaskId;
  final String? failureMessage;

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
    List<CachedTaskList>? taskLists,
    List<CachedTask>? tasks,
    SyncHealth? health,
    Object? selectedTaskListId = _notProvided,
    Object? selectedTaskId = _notProvided,
    Object? failureMessage = _notProvided,
  }) => TasksViewState(
    isLoading: isLoading ?? this.isLoading,
    taskLists: taskLists ?? this.taskLists,
    tasks: tasks ?? this.tasks,
    health: health ?? this.health,
    selectedTaskListId: identical(selectedTaskListId, _notProvided)
        ? this.selectedTaskListId
        : selectedTaskListId as TaskListId?,
    selectedTaskId: identical(selectedTaskId, _notProvided)
        ? this.selectedTaskId
        : selectedTaskId as TaskId?,
    failureMessage: identical(failureMessage, _notProvided)
        ? this.failureMessage
        : failureMessage as String?,
  );
}

final class TasksViewModel extends ChangeNotifier {
  TasksViewModel({
    required this.accountId,
    required this.tasksRepository,
    required this.syncHealthRepository,
  }) : _state = TasksViewState(
         isLoading: true,
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
  TasksViewState _state;
  StreamSubscription<CachedTasksSnapshot>? _tasksSubscription;
  StreamSubscription<SyncHealth>? _healthSubscription;
  bool _started = false;

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
