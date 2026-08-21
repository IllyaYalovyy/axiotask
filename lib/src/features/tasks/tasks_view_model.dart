import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/clock.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../core/outcome.dart';
import '../../domain/commands/task_commands.dart';
import '../../domain/commands/task_list_commands.dart';
import '../../domain/model/bulk_operations.dart';
import '../../domain/model/preferences.dart';
import '../../domain/model/tasks.dart';
import '../../domain/policy/bulk_task_operations.dart';
import '../../domain/policy/date_workflow.dart';
import '../../domain/policy/smart_views.dart';
import '../../domain/policy/task_links.dart';
import '../../domain/repository/external_link_launcher.dart';
import '../../domain/repository/preferences_repository.dart';
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
    required this.taskDeleteGroupUndos,
    required this.taskDueChangeUndos,
    required this.health,
    required this.today,
    this.listPreferences = const <TaskListId, ListPreferences>{},
    this.viewPreferences = const <ViewKey, ViewPreferences>{},
    this.isSyncControlPending = false,
    this.isListCommandPending = false,
    this.isTaskCommandPending = false,
    this.isPreferenceCommandPending = false,
    this.isBulkCommandPending = false,
    this.bulkSelectedTaskIds = const <TaskId>{},
    this.selectedSmartView,
    this.selectedTaskListId,
    this.selectedTaskId,
    this.failureMessage,
    this.syncControlFailureMessage,
    this.listCommandFailureMessage,
    this.taskCommandFailureMessage,
    this.preferenceFailureMessage,
    this.bulkCommandFailureMessage,
    this.latestBulkOperation,
  });

  final bool isLoading;
  final bool isRefreshing;
  final List<CachedTaskList> taskLists;
  final List<CachedTask> tasks;
  final List<TaskDeleteUndo> taskDeleteUndos;
  final List<TaskDeleteGroupUndo> taskDeleteGroupUndos;
  final List<TaskDueChangeUndo> taskDueChangeUndos;
  final SyncHealth health;
  final TaskDate today;
  final Map<TaskListId, ListPreferences> listPreferences;
  final Map<ViewKey, ViewPreferences> viewPreferences;
  final bool isSyncControlPending;
  final bool isListCommandPending;
  final bool isTaskCommandPending;
  final bool isPreferenceCommandPending;
  final bool isBulkCommandPending;
  final Set<TaskId> bulkSelectedTaskIds;
  final SmartView? selectedSmartView;
  final TaskListId? selectedTaskListId;
  final TaskId? selectedTaskId;
  final String? failureMessage;
  final String? syncControlFailureMessage;
  final String? listCommandFailureMessage;
  final String? taskCommandFailureMessage;
  final String? preferenceFailureMessage;
  final String? bulkCommandFailureMessage;
  final BulkOperationSummary? latestBulkOperation;

  bool get isBulkSelectionActive => bulkSelectedTaskIds.isNotEmpty;

  TaskView get selectedView => switch (selectedSmartView) {
    final value? => SmartTaskView(value),
    null => switch (selectedTaskListId) {
      final value? => TaskListView(value),
      null => const SmartTaskView(SmartView.focus),
    },
  };

  ViewPreferences get selectedViewPreferences =>
      viewPreferences[selectedView.key] ?? const ViewPreferences.defaults();

  Set<TaskListId> get excludedTaskLists => listPreferences.entries
      .where((entry) => entry.value.excludedFromSmartViews)
      .map((entry) => entry.key)
      .toSet();

  List<CachedTaskList> get orderedTaskLists {
    final indexed = taskLists.indexed.toList(growable: false);
    indexed.sort((left, right) {
      final leftOrder = listPreferences[left.$2.id]?.sidebarOrder;
      final rightOrder = listPreferences[right.$2.id]?.sidebarOrder;
      if (leftOrder == null && rightOrder == null) {
        return left.$1.compareTo(right.$1);
      }
      if (leftOrder == null) return 1;
      if (rightOrder == null) return -1;
      final compared = leftOrder.compareTo(rightOrder);
      return compared == 0 ? left.$1.compareTo(right.$1) : compared;
    });
    return List<CachedTaskList>.unmodifiable(indexed.map((entry) => entry.$2));
  }

  CachedTaskList? get selectedTaskList =>
      _firstWhereOrNull(taskLists, (value) => value.id == selectedTaskListId);

  TaskViewProjection get visibleProjection => projectTaskView(
    tasks: tasks,
    view: selectedView,
    preferences: selectedViewPreferences,
    excludedTaskLists: excludedTaskLists,
    today: today,
  );

  List<CachedTask> get visibleTasks => List<CachedTask>.unmodifiable(
    visibleProjection.rows.map((row) => row.task),
  );

  int viewCount(TaskView view) => projectTaskView(
    tasks: tasks,
    view: view,
    preferences: viewPreferences[view.key] ?? const ViewPreferences.defaults(),
    excludedTaskLists: excludedTaskLists,
    today: today,
  ).count;

  CachedTask? get selectedTask =>
      _firstWhereOrNull(tasks, (value) => value.id == selectedTaskId);

  List<CachedTask> get selectedTaskChildren => List<CachedTask>.unmodifiable(
    tasks.where((value) => value.parentTaskId == selectedTaskId),
  );

  ClearCompletedSelection? get clearCompletedSelection {
    final taskListId = selectedTaskListId;
    if (taskListId == null) return null;
    return selectClearCompletedTasks(
      tasks: tasks.where((task) => task.taskListId == taskListId),
    );
  }

  TasksViewState copyWith({
    bool? isLoading,
    bool? isRefreshing,
    List<CachedTaskList>? taskLists,
    List<CachedTask>? tasks,
    List<TaskDeleteUndo>? taskDeleteUndos,
    List<TaskDeleteGroupUndo>? taskDeleteGroupUndos,
    List<TaskDueChangeUndo>? taskDueChangeUndos,
    SyncHealth? health,
    TaskDate? today,
    Map<TaskListId, ListPreferences>? listPreferences,
    Map<ViewKey, ViewPreferences>? viewPreferences,
    bool? isSyncControlPending,
    bool? isListCommandPending,
    bool? isTaskCommandPending,
    bool? isPreferenceCommandPending,
    bool? isBulkCommandPending,
    Set<TaskId>? bulkSelectedTaskIds,
    Object? selectedSmartView = _notProvided,
    Object? selectedTaskListId = _notProvided,
    Object? selectedTaskId = _notProvided,
    Object? failureMessage = _notProvided,
    Object? syncControlFailureMessage = _notProvided,
    Object? listCommandFailureMessage = _notProvided,
    Object? taskCommandFailureMessage = _notProvided,
    Object? preferenceFailureMessage = _notProvided,
    Object? bulkCommandFailureMessage = _notProvided,
    Object? latestBulkOperation = _notProvided,
  }) => TasksViewState(
    isLoading: isLoading ?? this.isLoading,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    taskLists: taskLists ?? this.taskLists,
    tasks: tasks ?? this.tasks,
    taskDeleteUndos: taskDeleteUndos ?? this.taskDeleteUndos,
    taskDeleteGroupUndos: taskDeleteGroupUndos ?? this.taskDeleteGroupUndos,
    taskDueChangeUndos: taskDueChangeUndos ?? this.taskDueChangeUndos,
    health: health ?? this.health,
    today: today ?? this.today,
    listPreferences: listPreferences ?? this.listPreferences,
    viewPreferences: viewPreferences ?? this.viewPreferences,
    isSyncControlPending: isSyncControlPending ?? this.isSyncControlPending,
    isListCommandPending: isListCommandPending ?? this.isListCommandPending,
    isTaskCommandPending: isTaskCommandPending ?? this.isTaskCommandPending,
    isPreferenceCommandPending:
        isPreferenceCommandPending ?? this.isPreferenceCommandPending,
    isBulkCommandPending: isBulkCommandPending ?? this.isBulkCommandPending,
    bulkSelectedTaskIds: bulkSelectedTaskIds ?? this.bulkSelectedTaskIds,
    selectedSmartView: identical(selectedSmartView, _notProvided)
        ? this.selectedSmartView
        : selectedSmartView as SmartView?,
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
    preferenceFailureMessage: identical(preferenceFailureMessage, _notProvided)
        ? this.preferenceFailureMessage
        : preferenceFailureMessage as String?,
    bulkCommandFailureMessage:
        identical(bulkCommandFailureMessage, _notProvided)
        ? this.bulkCommandFailureMessage
        : bulkCommandFailureMessage as String?,
    latestBulkOperation: identical(latestBulkOperation, _notProvided)
        ? this.latestBulkOperation
        : latestBulkOperation as BulkOperationSummary?,
  );
}

final class TasksViewModel extends ChangeNotifier {
  TasksViewModel({
    required this.accountId,
    required this.tasksRepository,
    required this.syncHealthRepository,
    Clock? clock,
    MonotonicScheduler? calendarScheduler,
    this.preferencesRepository,
    this.taskListsRepository,
    this.localEditCommitted,
    this.taskDeleteCommitted,
    this.refreshRequested,
    this.retryRequested,
    this.reauthorizeRequested,
    this.stopSyncRequested,
    this.resumeSyncRequested,
    this.diagnostics,
    this.externalLinkLauncher = const UnavailableExternalLinkLauncher(),
  }) : clock = clock ?? SystemClock(),
       calendarScheduler =
           calendarScheduler ??
           (clock is MonotonicScheduler ? clock as MonotonicScheduler : null),
       _state = TasksViewState(
         isLoading: true,
         isRefreshing: false,
         isSyncControlPending: false,
         isListCommandPending: false,
         isTaskCommandPending: false,
         isPreferenceCommandPending: false,
         isBulkCommandPending: false,
         taskLists: const <CachedTaskList>[],
         tasks: const <CachedTask>[],
         taskDeleteUndos: const <TaskDeleteUndo>[],
         taskDeleteGroupUndos: const <TaskDeleteGroupUndo>[],
         taskDueChangeUndos: const <TaskDueChangeUndo>[],
         health: SyncHealth(
           outcome: SyncHealthOutcome.pending,
           pendingReason: SyncPendingReason.checkingAuthorization,
           counts: const SyncWorkCounts(),
           lastSuccessfulSyncAt: null,
           evaluatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
         ),
         today: _localTaskDate((clock ?? SystemClock()).now()),
       );

  final AccountId accountId;
  final TasksRepository tasksRepository;
  final SyncHealthRepository syncHealthRepository;
  final Clock clock;
  final MonotonicScheduler? calendarScheduler;
  final PreferencesRepository? preferencesRepository;
  final TaskListsRepository? taskListsRepository;
  final Future<void> Function()? localEditCommitted;
  final Future<void> Function(DateTime notBefore)? taskDeleteCommitted;
  final Future<void> Function()? refreshRequested;
  final Future<void> Function()? retryRequested;
  final Future<void> Function()? reauthorizeRequested;
  final Future<void> Function()? stopSyncRequested;
  final Future<void> Function()? resumeSyncRequested;
  final DiagnosticSink? diagnostics;
  final ExternalLinkLauncher externalLinkLauncher;
  TasksViewState _state;
  StreamSubscription<CachedTasksSnapshot>? _tasksSubscription;
  StreamSubscription<SyncHealth>? _healthSubscription;
  StreamSubscription<List<TaskDeleteUndo>>? _taskDeleteUndoSubscription;
  StreamSubscription<List<TaskDeleteGroupUndo>>?
  _taskDeleteGroupUndoSubscription;
  StreamSubscription<List<TaskDueChangeUndo>>? _taskDueChangeUndoSubscription;
  StreamSubscription<Map<TaskListId, ListPreferences>>?
  _listPreferencesSubscription;
  StreamSubscription<Map<ViewKey, ViewPreferences>>?
  _viewPreferencesSubscription;
  StreamSubscription<BulkOperationSummary?>? _bulkOperationSubscription;
  bool _started = false;
  Future<void>? _refreshInFlight;
  Future<void>? _syncControlInFlight;
  Future<void>? _listCommandInFlight;
  Future<void>? _taskCommandInFlight;
  Future<void>? _preferenceCommandInFlight;
  Future<void>? _bulkCommandInFlight;
  ScheduledTimer? _calendarTimer;

  TasksViewState get state => _state;

  void start() {
    if (_started) return;
    _started = true;
    _scheduleNextCalendarBoundary();
    _tasksSubscription = tasksRepository
        .watchTasks(TasksQuery(accountId: accountId))
        .listen(_acceptTasks, onError: _acceptRepositoryError);
    _healthSubscription = syncHealthRepository
        .watchHealth(accountId)
        .listen(_acceptHealth, onError: _acceptRepositoryError);
    _taskDeleteUndoSubscription = tasksRepository
        .watchUndoableTaskDeletes(accountId)
        .listen(_acceptTaskDeleteUndos, onError: _acceptTaskDeleteUndoError);
    if (tasksRepository case final DestructiveTaskOperationsRepository value) {
      _taskDeleteGroupUndoSubscription = value
          .watchUndoableTaskDeleteGroups(accountId)
          .listen(
            _acceptTaskDeleteGroupUndos,
            onError: _acceptTaskDeleteUndoError,
          );
    }
    _taskDueChangeUndoSubscription = tasksRepository
        .watchUndoableTaskDueChanges(accountId)
        .listen(
          _acceptTaskDueChangeUndos,
          onError: _acceptTaskDueChangeUndoError,
        );
    _listPreferencesSubscription = preferencesRepository
        ?.watchAllListPreferences(accountId)
        .listen(_acceptListPreferences, onError: _acceptPreferenceReadError);
    _viewPreferencesSubscription = preferencesRepository
        ?.watchAllViewPreferences(accountId)
        .listen(_acceptViewPreferences, onError: _acceptPreferenceReadError);
    final repository = tasksRepository;
    if (repository is BulkTaskOperationsRepository) {
      final bulkRepository = repository as BulkTaskOperationsRepository;
      _bulkOperationSubscription = bulkRepository
          .watchLatestBulkOperation(accountId)
          .listen(_acceptBulkOperation, onError: _acceptBulkOperationError);
    }
  }

  void _scheduleNextCalendarBoundary() {
    final scheduler = calendarScheduler;
    if (scheduler == null) return;
    _calendarTimer?.cancel();
    final local = clock.now().toLocal();
    final nextMidnight = DateTime(local.year, local.month, local.day + 1);
    _calendarTimer = scheduler.schedule(nextMidnight.difference(local), () {
      _replaceState(_state.copyWith(today: _localTaskDate(clock.now())));
      _scheduleNextCalendarBoundary();
    });
  }

  void selectSmartView(SmartView smartView) {
    _replaceState(
      _state.copyWith(
        selectedSmartView: smartView,
        selectedTaskListId: null,
        selectedTaskId: null,
        bulkSelectedTaskIds: const <TaskId>{},
      ),
    );
  }

  void selectTaskList(TaskListId taskListId) {
    if (!_state.taskLists.any((value) => value.id == taskListId)) return;
    _replaceState(
      _state.copyWith(
        selectedSmartView: null,
        selectedTaskListId: taskListId,
        selectedTaskId: null,
        bulkSelectedTaskIds: const <TaskId>{},
      ),
    );
  }

  void selectTask(TaskId taskId) {
    final task = _firstWhereOrNull(_state.tasks, (value) => value.id == taskId);
    if (task == null) return;
    _replaceState(_state.copyWith(selectedTaskId: taskId));
  }

  Future<void> setViewSort(ViewSort sort) {
    final repository = preferencesRepository;
    if (repository == null) return Future<void>.value();
    final current = _state.selectedViewPreferences;
    return _performPreferenceCommand(
      () => repository.setViewPreferences(
        accountId,
        _state.selectedView.key,
        ViewPreferences(sort: sort, showCompleted: current.showCompleted),
      ),
    );
  }

  Future<void> setShowCompleted(bool showCompleted) {
    final repository = preferencesRepository;
    if (repository == null) return Future<void>.value();
    final current = _state.selectedViewPreferences;
    return _performPreferenceCommand(
      () => repository.setViewPreferences(
        accountId,
        _state.selectedView.key,
        ViewPreferences(sort: current.sort, showCompleted: showCompleted),
      ),
    );
  }

  Future<void> toggleListExclusion(TaskListId taskListId) {
    final repository = preferencesRepository;
    if (repository == null) return Future<void>.value();
    final current =
        _state.listPreferences[taskListId] ?? const ListPreferences.defaults();
    return _performPreferenceCommand(
      () => repository.setListPreferences(
        accountId,
        taskListId,
        ListPreferences(
          sidebarOrder: current.sidebarOrder,
          excludedFromSmartViews: !current.excludedFromSmartViews,
        ),
      ),
    );
  }

  Future<void> moveTaskList(TaskListId taskListId, int offset) {
    final repository = preferencesRepository;
    if (repository == null || (offset != -1 && offset != 1)) {
      return Future<void>.value();
    }
    final ids = _state.orderedTaskLists.map((list) => list.id).toList();
    final index = ids.indexOf(taskListId);
    final target = index + offset;
    if (index < 0 || target < 0 || target >= ids.length) {
      return Future<void>.value();
    }
    final moved = ids.removeAt(index);
    ids.insert(target, moved);
    return _performPreferenceCommand(
      () => repository.setSidebarOrder(accountId, ids),
    );
  }

  void clearTaskSelection() {
    _replaceState(_state.copyWith(selectedTaskId: null));
  }

  void beginBulkSelection(TaskId taskId) {
    if (!_state.visibleTasks.any((task) => task.id == taskId)) return;
    _replaceState(
      _state.copyWith(
        bulkSelectedTaskIds: Set<TaskId>.unmodifiable(<TaskId>{taskId}),
        selectedTaskId: null,
        bulkCommandFailureMessage: null,
      ),
    );
  }

  void toggleBulkSelection(TaskId taskId) {
    if (!_state.visibleTasks.any((task) => task.id == taskId)) return;
    final selected = Set<TaskId>.of(_state.bulkSelectedTaskIds);
    if (!selected.add(taskId)) selected.remove(taskId);
    _replaceState(
      _state.copyWith(
        bulkSelectedTaskIds: Set<TaskId>.unmodifiable(selected),
        bulkCommandFailureMessage: null,
      ),
    );
  }

  void clearBulkSelection() {
    if (_state.bulkSelectedTaskIds.isEmpty) return;
    _replaceState(
      _state.copyWith(
        bulkSelectedTaskIds: const <TaskId>{},
        bulkCommandFailureMessage: null,
      ),
    );
  }

  void backFromTaskDetail() {
    final selected = _state.selectedTask;
    final parentTaskId = selected?.parentTaskId;
    if (parentTaskId == null) {
      clearTaskSelection();
    } else {
      selectTask(parentTaskId);
    }
  }

  /// Opens only a URI which has passed the shared HTTP(S) policy.
  ///
  /// Google-task links are additionally validated by the detail presentation
  /// before reaching this common external-launch boundary.
  Future<bool> launchExternalLink(Uri uri) async {
    final safeUri = TaskLinkPolicy.safeUserAuthoredLink(uri);
    if (safeUri == null) return false;
    try {
      return await externalLinkLauncher.launch(safeUri);
    } on Object {
      return false;
    }
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
    _recordUi('ui.refresh_started', DiagnosticEventKind.transition);
    _replaceState(_state.copyWith(isRefreshing: true));
    try {
      await action();
      _recordUi('ui.refresh_completed', DiagnosticEventKind.transition);
    } on Object {
      _recordUi('ui.refresh_failed', DiagnosticEventKind.failure);
      rethrow;
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

  Future<void> setTaskDue(TaskId taskId, TaskDate? due) => _performTaskCommand(
    () => tasksRepository.setTaskDue(
      SetTaskDueCommand(accountId: accountId, taskId: taskId, due: due),
    ),
  );

  Future<void> setTaskDueShortcut(TaskId taskId, DateShortcut shortcut) =>
      setTaskDue(taskId, resolveDateShortcut(_state.today, shortcut));

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

  Future<void> completeBulkSelection() => _performBulkCommand(
    BulkCompleteTasksCommand(
      accountId: accountId,
      taskIds: Set<TaskId>.unmodifiable(_state.bulkSelectedTaskIds),
    ),
  );

  Future<void> rescheduleBulkSelection(TaskDate? due) => _performBulkCommand(
    BulkRescheduleTasksCommand(
      accountId: accountId,
      taskIds: Set<TaskId>.unmodifiable(_state.bulkSelectedTaskIds),
      due: due,
    ),
  );

  Future<void> rescheduleBulkSelectionShortcut(DateShortcut shortcut) =>
      rescheduleBulkSelection(resolveDateShortcut(_state.today, shortcut));

  Future<void> moveBulkSelection(TaskListId destinationTaskListId) =>
      _performBulkCommand(
        BulkMoveTasksCommand(
          accountId: accountId,
          taskIds: Set<TaskId>.unmodifiable(_state.bulkSelectedTaskIds),
          destinationTaskListId: destinationTaskListId,
        ),
      );

  Future<void> deleteBulkSelection() => _performBulkCommand(
    BulkDeleteTasksCommand(
      accountId: accountId,
      taskIds: Set<TaskId>.unmodifiable(_state.bulkSelectedTaskIds),
    ),
  );

  Future<void> clearCompleted() {
    final existing = _bulkCommandInFlight;
    if (existing != null) return existing;
    final repository = tasksRepository;
    final taskListId = _state.selectedTaskListId;
    if (repository is! DestructiveTaskOperationsRepository ||
        taskListId == null) {
      return Future<void>.value();
    }
    final operation = _runClearCompleted(
      repository as DestructiveTaskOperationsRepository,
      taskListId,
    );
    _bulkCommandInFlight = operation;
    return operation;
  }

  Future<void> _runClearCompleted(
    DestructiveTaskOperationsRepository repository,
    TaskListId taskListId,
  ) async {
    _replaceState(
      _state.copyWith(
        isBulkCommandPending: true,
        bulkCommandFailureMessage: null,
      ),
    );
    try {
      final result = await repository.clearCompleted(
        ClearCompletedTasksCommand(
          accountId: accountId,
          taskListId: taskListId,
        ),
      );
      await _acceptBulkCommandResult(result, clearSelection: false);
    } finally {
      _bulkCommandInFlight = null;
      _replaceState(_state.copyWith(isBulkCommandPending: false));
    }
  }

  Future<void> _performBulkCommand(BulkExistingTaskCommand command) {
    final existing = _bulkCommandInFlight;
    if (existing != null) return existing;
    final taskRepository = tasksRepository;
    if (taskRepository is! BulkTaskOperationsRepository) {
      return Future<void>.value();
    }
    final repository = taskRepository as BulkTaskOperationsRepository;
    final operation = _runBulkCommand(repository, command);
    _bulkCommandInFlight = operation;
    return operation;
  }

  Future<void> _runBulkCommand(
    BulkTaskOperationsRepository repository,
    BulkExistingTaskCommand command,
  ) async {
    _recordUi('ui.bulk_command_started', DiagnosticEventKind.transition);
    _replaceState(
      _state.copyWith(
        isBulkCommandPending: true,
        bulkCommandFailureMessage: null,
      ),
    );
    try {
      final result = await repository.applyBulk(command);
      await _acceptBulkCommandResult(result, clearSelection: true);
    } finally {
      _bulkCommandInFlight = null;
      _replaceState(_state.copyWith(isBulkCommandPending: false));
    }
  }

  Future<void> _acceptBulkCommandResult(
    Outcome<BulkOperationReceipt> result, {
    required bool clearSelection,
  }) async {
    switch (result) {
      case Success<BulkOperationReceipt>(:final value):
        _recordUi('ui.bulk_command_completed', DiagnosticEventKind.transition);
        _replaceState(
          _state.copyWith(
            bulkSelectedTaskIds: clearSelection
                ? const <TaskId>{}
                : _state.bulkSelectedTaskIds,
            latestBulkOperation: value.summary,
          ),
        );
        if (value.notBefore case final notBefore?) {
          await taskDeleteCommitted?.call(notBefore);
        } else {
          await localEditCommitted?.call();
        }
      case Failed<BulkOperationReceipt>():
        _recordUi('ui.bulk_command_failed', DiagnosticEventKind.failure);
        _replaceState(
          _state.copyWith(
            bulkCommandFailureMessage: clearSelection
                ? 'No selected tasks were changed.'
                : 'No completed tasks were deleted.',
          ),
        );
    }
  }

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

  Future<void> undoTaskDeleteGroup(int groupId) {
    final repository = tasksRepository;
    if (repository is! DestructiveTaskOperationsRepository) {
      return Future<void>.value();
    }
    final destructive = repository as DestructiveTaskOperationsRepository;
    return _performTaskCommand<void>(
      () => destructive.undoTaskDeleteGroup(
        UndoTaskDeleteGroupCommand(accountId: accountId, groupId: groupId),
      ),
    );
  }

  Future<void> undoTaskDueChange(int groupId) => _performTaskCommand(
    () => tasksRepository.undoTaskDueChange(
      UndoTaskDueChangeCommand(accountId: accountId, groupId: groupId),
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
    _recordUi('ui.task_command_started', DiagnosticEventKind.transition);
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
          _recordUi(
            'ui.task_command_completed',
            DiagnosticEventKind.transition,
          );
        case Failed<T>(:final failure):
          _recordUi(
            'ui.task_command_failed',
            DiagnosticEventKind.failure,
            failureCode: failure.code,
          );
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
    _recordUi('ui.list_command_started', DiagnosticEventKind.transition);
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
          _recordUi(
            'ui.list_command_completed',
            DiagnosticEventKind.transition,
          );
        case Failed<T>(:final failure):
          _recordUi(
            'ui.list_command_failed',
            DiagnosticEventKind.failure,
            failureCode: failure.code,
          );
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

  Future<void> _performPreferenceCommand(
    Future<Outcome<void>> Function() action,
  ) {
    final existing = _preferenceCommandInFlight;
    if (existing != null) return existing;
    final operation = _runPreferenceCommand(action);
    _preferenceCommandInFlight = operation;
    return operation;
  }

  Future<void> _runPreferenceCommand(
    Future<Outcome<void>> Function() action,
  ) async {
    _recordUi('ui.preference_command_started', DiagnosticEventKind.transition);
    _replaceState(
      _state.copyWith(
        isPreferenceCommandPending: true,
        preferenceFailureMessage: null,
      ),
    );
    try {
      final result = await action();
      if (result case Failed<void>()) {
        _recordUi('ui.preference_command_failed', DiagnosticEventKind.failure);
        _replaceState(
          _state.copyWith(
            preferenceFailureMessage:
                'The view preference could not be saved safely.',
          ),
        );
      } else {
        _recordUi(
          'ui.preference_command_completed',
          DiagnosticEventKind.transition,
        );
      }
    } finally {
      _preferenceCommandInFlight = null;
      _replaceState(_state.copyWith(isPreferenceCommandPending: false));
    }
  }

  Future<void> handleSyncHealthAction(
    SyncHealthAction action,
  ) => switch (action) {
    SyncHealthAction.resume => resumeSync(),
    SyncHealthAction.retry => retrySync(),
    SyncHealthAction.reauthorize => _performSyncControl(reauthorizeRequested),
    SyncHealthAction.none || SyncHealthAction.connect => Future<void>.value(),
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
    _recordUi('ui.sync_control_started', DiagnosticEventKind.transition);
    _replaceState(
      _state.copyWith(
        isSyncControlPending: true,
        syncControlFailureMessage: null,
      ),
    );
    try {
      await action();
      _recordUi('ui.sync_control_completed', DiagnosticEventKind.transition);
    } on Object {
      _recordUi('ui.sync_control_failed', DiagnosticEventKind.failure);
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
    final selectedList = _state.selectedSmartView != null
        ? null
        : snapshot.taskLists.any((value) => value.id == currentList)
        ? currentList
        : snapshot.taskLists.isEmpty
        ? null
        : snapshot.taskLists.first.id;
    final currentTask = _state.selectedTaskId;
    final selectedTask = snapshot.tasks.any((value) => value.id == currentTask)
        ? currentTask
        : null;
    final retainedBulkSelection = _state.bulkSelectedTaskIds
        .where((id) => snapshot.tasks.any((task) => task.id == id))
        .toSet();
    _replaceState(
      _state.copyWith(
        isLoading: false,
        taskLists: List<CachedTaskList>.unmodifiable(snapshot.taskLists),
        tasks: List<CachedTask>.unmodifiable(snapshot.tasks),
        selectedTaskListId: selectedList,
        selectedTaskId: selectedTask,
        bulkSelectedTaskIds: Set<TaskId>.unmodifiable(retainedBulkSelection),
        failureMessage: null,
      ),
    );
  }

  void _acceptListPreferences(Map<TaskListId, ListPreferences> values) {
    _replaceState(
      _state.copyWith(
        listPreferences: Map<TaskListId, ListPreferences>.unmodifiable(values),
      ),
    );
  }

  void _acceptViewPreferences(Map<ViewKey, ViewPreferences> values) {
    _replaceState(
      _state.copyWith(
        viewPreferences: Map<ViewKey, ViewPreferences>.unmodifiable(values),
      ),
    );
  }

  void _acceptBulkOperation(BulkOperationSummary? value) {
    _replaceState(_state.copyWith(latestBulkOperation: value));
  }

  void _acceptBulkOperationError(Object _) {
    _recordUi('ui.bulk_result_read_failed', DiagnosticEventKind.failure);
    _replaceState(
      _state.copyWith(
        bulkCommandFailureMessage:
            'Bulk Google result counts could not be read safely.',
      ),
    );
  }

  void _acceptPreferenceReadError(Object _) {
    _recordUi('ui.preference_read_failed', DiagnosticEventKind.failure);
    _replaceState(
      _state.copyWith(
        preferenceFailureMessage:
            'Saved view preferences could not be read safely.',
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

  void _acceptTaskDeleteGroupUndos(List<TaskDeleteGroupUndo> values) {
    _replaceState(
      _state.copyWith(
        taskDeleteGroupUndos: List<TaskDeleteGroupUndo>.unmodifiable(values),
      ),
    );
  }

  void _acceptTaskDeleteUndoError(Object _) {
    _recordUi('ui.delete_undo_read_failed', DiagnosticEventKind.failure);
    _replaceState(
      _state.copyWith(
        taskCommandFailureMessage: 'Undo state could not be read safely.',
      ),
    );
  }

  void _acceptTaskDueChangeUndos(List<TaskDueChangeUndo> values) {
    _replaceState(
      _state.copyWith(
        taskDueChangeUndos: List<TaskDueChangeUndo>.unmodifiable(values),
      ),
    );
  }

  void _acceptTaskDueChangeUndoError(Object _) {
    _recordUi('ui.due_undo_read_failed', DiagnosticEventKind.failure);
    _replaceState(
      _state.copyWith(
        taskCommandFailureMessage:
            'Due-date Undo state could not be read safely.',
      ),
    );
  }

  void _acceptRepositoryError(Object _) {
    _recordUi('ui.repository_read_failed', DiagnosticEventKind.failure);
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

  void _recordUi(String code, DiagnosticEventKind kind, {String? failureCode}) {
    diagnostics?.record(
      DiagnosticEvent(
        subsystem: DiagnosticSubsystem.ui,
        kind: kind,
        code: code,
        operation: 'tasks_view_model',
        fields: <DiagnosticField>[
          if (failureCode != null)
            DiagnosticField.safe('failure_code', failureCode),
        ],
      ),
    );
  }

  @override
  void dispose() {
    final tasksSubscription = _tasksSubscription;
    final healthSubscription = _healthSubscription;
    final taskDeleteUndoSubscription = _taskDeleteUndoSubscription;
    final taskDeleteGroupUndoSubscription = _taskDeleteGroupUndoSubscription;
    final taskDueChangeUndoSubscription = _taskDueChangeUndoSubscription;
    final listPreferencesSubscription = _listPreferencesSubscription;
    final viewPreferencesSubscription = _viewPreferencesSubscription;
    final bulkOperationSubscription = _bulkOperationSubscription;
    if (tasksSubscription != null) unawaited(tasksSubscription.cancel());
    if (healthSubscription != null) unawaited(healthSubscription.cancel());
    if (taskDeleteUndoSubscription != null) {
      unawaited(taskDeleteUndoSubscription.cancel());
    }
    if (taskDeleteGroupUndoSubscription != null) {
      unawaited(taskDeleteGroupUndoSubscription.cancel());
    }
    if (taskDueChangeUndoSubscription != null) {
      unawaited(taskDueChangeUndoSubscription.cancel());
    }
    if (listPreferencesSubscription != null) {
      unawaited(listPreferencesSubscription.cancel());
    }
    if (viewPreferencesSubscription != null) {
      unawaited(viewPreferencesSubscription.cancel());
    }
    if (bulkOperationSubscription != null) {
      unawaited(bulkOperationSubscription.cancel());
    }
    _calendarTimer?.cancel();
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

TaskDate _localTaskDate(DateTime value) {
  final local = value.toLocal();
  return TaskDate(local.year, local.month, local.day);
}
