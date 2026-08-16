import 'dart:async';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/domain/repository/preferences_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ViewModel uses one projection for smart rows, counts, and preferences',
    () async {
      final preferences = _PreferencesRepository();
      final tasks = _TasksRepository(_snapshot);
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: tasks,
        preferencesRepository: preferences,
        syncHealthRepository: const _HealthRepository(),
        clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
      );
      addTearDown(viewModel.dispose);
      addTearDown(preferences.close);

      viewModel.start();
      await pumpEventQueue();
      viewModel.selectSmartView(SmartView.focus);

      expect(viewModel.state.visibleTasks.map((task) => task.title), <String>[
        'Soon parent',
        'Other list today',
        'Completed today',
      ]);
      expect(
        viewModel.state.viewCount(const SmartTaskView(SmartView.focus)),
        viewModel.state.visibleTasks.length,
      );

      await viewModel.setShowCompleted(false);
      expect(viewModel.state.visibleTasks.map((task) => task.title), <String>[
        'Soon parent',
        'Other list today',
      ]);
      await viewModel.setViewSort(ViewSort.title);
      expect(viewModel.state.visibleTasks.map((task) => task.title), <String>[
        'Other list today',
        'Soon parent',
      ]);

      await viewModel.toggleListExclusion(const TaskListId(20));
      expect(viewModel.state.visibleTasks.map((task) => task.title), <String>[
        'Soon parent',
      ]);
      expect(
        viewModel.state.viewCount(const SmartTaskView(SmartView.focus)),
        viewModel.state.visibleTasks.length,
      );
    },
  );

  test(
    'new lists append and ordered list preferences survive ViewModel restart',
    () async {
      final preferences = _PreferencesRepository();
      final tasks = _TasksRepository(_snapshot);
      var viewModel = _viewModel(tasks, preferences);
      viewModel.start();
      await pumpEventQueue();

      expect(
        viewModel.state.orderedTaskLists.map((list) => list.title),
        <String>['First', 'Second'],
      );
      await viewModel.moveTaskList(const TaskListId(20), -1);
      expect(
        viewModel.state.orderedTaskLists.map((list) => list.title),
        <String>['Second', 'First'],
      );
      viewModel.dispose();

      tasks.snapshot = CachedTasksSnapshot(
        accountId: _snapshot.accountId,
        taskLists: <CachedTaskList>[
          ..._snapshot.taskLists,
          const CachedTaskList(
            id: TaskListId(30),
            accountId: AccountId(1),
            remoteId: TaskListRemoteId('synthetic-list-30'),
            title: 'New list',
          ),
        ],
        tasks: _snapshot.tasks,
        completeness: CacheCompleteness.complete,
      );
      viewModel = _viewModel(tasks, preferences);
      addTearDown(viewModel.dispose);
      addTearDown(preferences.close);
      viewModel.start();
      await pumpEventQueue();

      expect(
        viewModel.state.orderedTaskLists.map((list) => list.title),
        <String>['Second', 'First', 'New list'],
      );
    },
  );

  test(
    'local midnight recomputes membership without a repository event',
    () async {
      final clock = ManualClock(DateTime(2026, 8, 15, 23, 59, 59));
      final preferences = _PreferencesRepository();
      final tasks = _TasksRepository(
        CachedTasksSnapshot(
          accountId: const AccountId(1),
          taskLists: _snapshot.taskLists,
          tasks: <CachedTask>[
            _task(20, title: 'Becomes missed', due: TaskDate(2026, 8, 15)),
          ],
          completeness: CacheCompleteness.complete,
        ),
      );
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: tasks,
        preferencesRepository: preferences,
        syncHealthRepository: const _HealthRepository(),
        clock: clock,
      );
      addTearDown(viewModel.dispose);
      addTearDown(preferences.close);
      viewModel.start();
      await pumpEventQueue();
      viewModel.selectSmartView(SmartView.missed);

      expect(viewModel.state.visibleTasks, isEmpty);
      clock.advance(const Duration(seconds: 1));
      expect(viewModel.state.visibleTasks.map((task) => task.title), <String>[
        'Becomes missed',
      ]);
    },
  );
}

TasksViewModel _viewModel(
  _TasksRepository tasks,
  _PreferencesRepository preferences,
) => TasksViewModel(
  accountId: const AccountId(1),
  tasksRepository: tasks,
  preferencesRepository: preferences,
  syncHealthRepository: const _HealthRepository(),
  clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
);

final class _TasksRepository implements TasksRepository {
  _TasksRepository(this.snapshot);

  CachedTasksSnapshot snapshot;

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) =>
      Stream.value(snapshot);

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream.value(const <TaskDeleteUndo>[]);

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) =>
      Future.value(const Outcome<void>.success(null));

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) =>
      Future.value(const Outcome<TaskId>.success(TaskId(99)));

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(DeleteTaskCommand command) =>
      Future.value(
        Outcome<TaskDeleteReceipt>.success(
          TaskDeleteReceipt(
            taskId: command.taskId,
            notBefore: DateTime.utc(2026, 8, 15, 12, 0, 30),
          ),
        ),
      );

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) =>
      Future.value(const Outcome<void>.success(null));
}

final class _PreferencesRepository implements PreferencesRepository {
  final _listChanges =
      StreamController<Map<TaskListId, ListPreferences>>.broadcast();
  final _viewChanges =
      StreamController<Map<ViewKey, ViewPreferences>>.broadcast();
  final Map<TaskListId, ListPreferences> lists =
      <TaskListId, ListPreferences>{};
  final Map<ViewKey, ViewPreferences> views = <ViewKey, ViewPreferences>{
    SmartView.focus.key: const ViewPreferences(
      sort: ViewSort.manual,
      showCompleted: true,
    ),
  };

  Future<void> close() async {
    await _listChanges.close();
    await _viewChanges.close();
  }

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) async* {
    yield Map<TaskListId, ListPreferences>.of(lists);
    yield* _listChanges.stream;
  }

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) async* {
    yield Map<ViewKey, ViewPreferences>.of(views);
    yield* _viewChanges.stream;
  }

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => watchAllListPreferences(
    accountId,
  ).map((values) => values[taskListId] ?? const ListPreferences.defaults());

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) => watchAllViewPreferences(
    accountId,
  ).map((values) => values[viewKey] ?? const ViewPreferences.defaults());

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) async {
    lists[taskListId] = preferences;
    _listChanges.add(Map<TaskListId, ListPreferences>.of(lists));
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  ) async {
    for (var index = 0; index < orderedTaskListIds.length; index += 1) {
      final id = orderedTaskListIds[index];
      final current = lists[id] ?? const ListPreferences.defaults();
      lists[id] = ListPreferences(
        sidebarOrder: index,
        excludedFromSmartViews: current.excludedFromSmartViews,
      );
    }
    _listChanges.add(Map<TaskListId, ListPreferences>.of(lists));
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async {
    views[viewKey] = preferences;
    _viewChanges.add(Map<ViewKey, ViewPreferences>.of(views));
    return const Outcome<void>.success(null);
  }

  @override
  Stream<DevicePreferences> watchDevicePreferences() =>
      Stream.value(const DevicePreferences.defaults());

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) =>
      Future.value(const Outcome<void>.success(null));

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) =>
      Future.value(const Outcome<void>.success(null));

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) =>
      Future.value(const Outcome<void>.success(null));
}

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 15, 12),
    ),
  );
}

final _snapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(10),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-list-10'),
      title: 'First',
    ),
    CachedTaskList(
      id: TaskListId(20),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-list-20'),
      title: 'Second',
    ),
  ],
  tasks: <CachedTask>[
    _task(1, title: 'Soon parent'),
    _task(2, title: 'Child tomorrow', parent: 1, due: TaskDate(2026, 8, 16)),
    _task(
      3,
      title: 'Completed today',
      due: TaskDate(2026, 8, 15),
      status: TaskStatus.completed,
    ),
    _task(4, title: 'Other list today', list: 20, due: TaskDate(2026, 8, 15)),
  ],
  completeness: CacheCompleteness.complete,
);

CachedTask _task(
  int id, {
  required String title,
  int list = 10,
  int? parent,
  TaskDate? due,
  TaskStatus status = TaskStatus.needsAction,
}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: TaskListId(list),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: TaskRemoteId('synthetic-task-$id'),
  title: title,
  notes: null,
  status: status,
  due: due,
);
