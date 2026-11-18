import 'dart:async';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/date_workflow.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/domain/policy/task_traversal.dart';
import 'package:axiotask/src/domain/repository/preferences_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/task_detail_view_model.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'touch reorder accepts siblings only and uses shared move intent',
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
      tasks.selectTaskList(const TaskListId(7));
      tasks.selectTask(const TaskId(11));
      final detail = TaskDetailViewModel.fromTasks(tasks);
      await detail.reorderChild(
        const TaskId(14),
        const TaskId(12),
        after: false,
      );
      await detail.reorderChild(
        const TaskId(12),
        const TaskId(12),
        after: true,
      );
      expect(repository.applied, isEmpty);
      await detail.reorderChild(
        const TaskId(13),
        const TaskId(12),
        after: false,
      );
      final move = repository.applied.single as MoveTaskCommand;
      expect(move.taskId, const TaskId(13));
      expect(move.parentTaskId, const TaskId(11));
      expect(move.previousTaskId, isNull);
    },
  );

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
      expect(detail.state?.effectiveDue.effective, TaskDate(2026, 8, 16));
      expect(detail.state?.effectiveDue.fromChildren, TaskDate(2026, 8, 16));
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

  test(
    'inline autosave writes field commands and yields to the dialog',
    () async {
      final repository = _TasksRepository();
      final tasks = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: repository,
        syncHealthRepository: const _HealthRepository(),
        clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
      );
      addTearDown(tasks.dispose);
      tasks.start();
      repository.snapshots.add(_snapshot);
      await pumpEventQueue();
      tasks.selectTask(const TaskId(11));
      final detail = TaskDetailViewModel.fromTasks(tasks);
      final autosave = detail.contentAutosave;
      expect(autosave, same(tasks.contentAutosave));

      // Typed inline text that is still waiting for its debounce is stored
      // before an explicit dialog save, which then supersedes the draft.
      autosave.open(_snapshot.tasks.first);
      autosave.edit(const TaskId(11), title: 'Typed inline', notes: '');
      await detail.saveContent(
        task: _snapshot.tasks.first,
        title: 'From the dialog',
        notes: 'Dialog notes',
      );
      expect(repository.applied.map((command) => command.runtimeType), <Type>[
        SetTaskTitleCommand,
        UpdateTaskContentCommand,
      ]);
      expect(
        (repository.applied.first as SetTaskTitleCommand).title,
        'Typed inline',
      );
      final draft = autosave.draft(const TaskId(11))!;
      expect(draft.title, 'From the dialog');
      expect(draft.notes, 'Dialog notes');
      expect(tasks.state.isTaskCommandPending, isFalse);

      // Selecting another task stores the edit without waiting.
      autosave.edit(const TaskId(11), title: 'Before switching', notes: 'x');
      tasks.selectTask(const TaskId(12));
      await pumpEventQueue();
      expect(
        repository.applied.skip(2).map((command) => command.taskId),
        const <TaskId>[TaskId(11), TaskId(11)],
      );
      expect(
        (repository.applied[2] as SetTaskTitleCommand).title,
        'Before switching',
      );
      expect((repository.applied[3] as SetTaskNotesCommand).notes, 'x');
    },
  );

  test(
    'completion and every date action use the shared command boundary',
    () async {
      final repository = _TasksRepository();
      final tasks = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: repository,
        syncHealthRepository: const _HealthRepository(),
        clock: _FixedClock(),
      );
      addTearDown(tasks.dispose);
      tasks.start();
      repository.snapshots.add(_snapshot);
      await pumpEventQueue();
      tasks.selectTask(const TaskId(11));
      final detail = TaskDetailViewModel.fromTasks(tasks);

      await detail.toggleCompletion(const TaskId(11));
      expect(
        repository.applied.whereType<SetTaskCompletionCommand>().single.status,
        TaskStatus.completed,
      );

      await detail.setDueShortcut(const TaskId(11), DateShortcut.nextMonth);
      expect(repository.dueCommands.last.due, TaskDate(2026, 9, 15));
      await detail.setDue(const TaskId(11), null);
      expect(repository.dueCommands.last.due, isNull);

      await detail.undoDueChange(72);
      expect(repository.undoneDueGroups, <int>[72]);
    },
  );

  group('Previous/Next (Android audit 23)', () {
    Future<(TasksViewModel, _TasksRepository, _ViewPreferences)> open({
      CachedTasksSnapshot? snapshot,
    }) async {
      final repository = _TasksRepository();
      final preferences = _ViewPreferences();
      final tasks = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: repository,
        preferencesRepository: preferences,
        syncHealthRepository: const _HealthRepository(),
        clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
      );
      addTearDown(tasks.dispose);
      addTearDown(preferences.close);
      tasks.start();
      repository.snapshots.add(snapshot ?? _orderSnapshot);
      await pumpEventQueue();
      tasks.selectTaskList(const TaskListId(7));
      return (tasks, repository, preferences);
    }

    TaskNeighbors neighborsOf(TasksViewModel tasks, TaskId id) {
      tasks.selectTask(id);
      final detail = TaskDetailViewModel.fromTasks(tasks).state!;
      expect(detail.task.id, id);
      return detail.neighbors;
    }

    test('walk the visible collection and disable at its boundaries', () async {
      final (tasks, _, _) = await open();
      // Manual order, completed hidden: Charlie, Alpha, Delta.
      expect(neighborsOf(tasks, _charlie), const TaskNeighbors(next: _alpha));
      expect(
        neighborsOf(tasks, _alpha),
        const TaskNeighbors(previous: _charlie, next: _delta),
      );
      expect(neighborsOf(tasks, _delta), const TaskNeighbors(previous: _alpha));

      final detail = TaskDetailViewModel.fromTasks(tasks);
      tasks.selectTask(_charlie);
      detail.selectPrevious();
      expect(tasks.state.selectedTaskId, _charlie, reason: 'first boundary');
      detail.selectNext();
      expect(tasks.state.selectedTaskId, _alpha);
      detail.selectNext();
      expect(tasks.state.selectedTaskId, _delta);
      detail.selectNext();
      expect(tasks.state.selectedTaskId, _delta, reason: 'last boundary');
      detail.selectPrevious();
      expect(tasks.state.selectedTaskId, _alpha);
    });

    test('follow the view sort and completed filter', () async {
      final (tasks, _, preferences) = await open();
      await tasks.setViewSort(ViewSort.title);
      await pumpEventQueue();
      // Alpha, Charlie, Delta.
      expect(
        neighborsOf(tasks, _charlie),
        const TaskNeighbors(previous: _alpha, next: _delta),
      );
      expect(neighborsOf(tasks, _alpha), const TaskNeighbors(next: _charlie));

      await tasks.setShowCompleted(true);
      await pumpEventQueue();
      expect(preferences.current.values.single.showCompleted, isTrue);
      // Completed tasks follow open ones: Alpha, Charlie, Delta, Bravo.
      expect(
        neighborsOf(tasks, _delta),
        const TaskNeighbors(previous: _charlie, next: _bravo),
      );
      expect(neighborsOf(tasks, _bravo), const TaskNeighbors(previous: _delta));

      // A smart view walks its own membership: Focus holds only Delta.
      tasks.selectSmartView(SmartView.focus);
      expect(tasks.state.visibleTasks.map((task) => task.id), const <TaskId>[
        _delta,
      ]);
      expect(neighborsOf(tasks, _delta), TaskNeighbors.none);
    });

    test('a subtask walks its parent\'s subtasks', () async {
      final (tasks, _, _) = await open();
      expect(
        neighborsOf(tasks, _childOne),
        const TaskNeighbors(next: _childTwo),
      );
      expect(
        neighborsOf(tasks, _childTwo),
        const TaskNeighbors(previous: _childOne),
      );
      TaskDetailViewModel.fromTasks(tasks).selectPrevious();
      expect(tasks.state.selectedTaskId, _childOne);
      TaskDetailViewModel.fromTasks(tasks).back();
      expect(tasks.state.selectedTaskId, _charlie, reason: 'Back to parent');
    });

    test('a single-task view has neither control', () async {
      final (tasks, _, _) = await open();
      tasks.selectTaskList(const TaskListId(8));
      expect(neighborsOf(tasks, _solo), TaskNeighbors.none);
    });

    test(
      'completing or removing tasks never navigates by a stale index',
      () async {
        final (tasks, repository, _) = await open();
        tasks.selectTask(_alpha);
        final detail = TaskDetailViewModel.fromTasks(tasks);
        expect(
          detail.state!.neighbors,
          const TaskNeighbors(previous: _charlie, next: _delta),
        );

        // Alpha is completed while completed tasks are hidden: it stays open
        // in details and still leads to the tasks that surrounded it.
        repository.snapshots.add(_orderWith(completed: <TaskId>{_alpha}));
        await pumpEventQueue();
        expect(tasks.state.visibleTasks.map((task) => task.id), const <TaskId>[
          _charlie,
          _delta,
        ]);
        expect(detail.state!.task.id, _alpha);
        expect(
          detail.state!.neighbors,
          const TaskNeighbors(previous: _charlie, next: _delta),
        );

        // Its successor is deleted too; Next resolves when used.
        repository.snapshots.add(
          _orderWith(completed: <TaskId>{_alpha}, removed: <TaskId>{_delta}),
        );
        await pumpEventQueue();
        expect(
          detail.state!.neighbors,
          const TaskNeighbors(previous: _charlie),
        );
        detail.selectNext();
        expect(tasks.state.selectedTaskId, _alpha, reason: 'nothing follows');
        detail.selectPrevious();
        expect(tasks.state.selectedTaskId, _charlie);

        // A task opened with no place in the ordering has no neighbours.
        tasks.selectTask(_alpha);
        expect(detail.state!.neighbors, TaskNeighbors.none);

        // Removing a neighbour of a shown task re-resolves by identity.
        repository.snapshots.add(_orderSnapshot);
        await pumpEventQueue();
        tasks.selectTask(_charlie);
        repository.snapshots.add(_orderWith(removed: <TaskId>{_alpha}));
        await pumpEventQueue();
        detail.selectNext();
        expect(tasks.state.selectedTaskId, _delta);

        // Removing the open task closes details instead of stepping on.
        repository.snapshots.add(_orderWith(removed: <TaskId>{_delta}));
        await pumpEventQueue();
        expect(tasks.state.selectedTaskId, isNull);
        expect(detail.state, isNull);
        expect(tasks.selectedTaskNeighbors, TaskNeighbors.none);
      },
    );

    test('stores the open task\'s inline edits for that task only', () async {
      final (tasks, repository, _) = await open();
      tasks.selectTask(_charlie);
      final autosave = tasks.contentAutosave;
      final charlie = tasks.state.selectedTask!;
      autosave.open(charlie);
      autosave.edit(_charlie, title: 'Charlie edited', notes: 'Kept here');

      TaskDetailViewModel.fromTasks(tasks).selectNext();
      await pumpEventQueue();

      expect(tasks.state.selectedTaskId, _alpha);
      expect(
        repository.applied.map((command) => command.taskId),
        const <TaskId>[_charlie, _charlie],
        reason: 'only Charlie is written',
      );
      expect(
        repository.applied.whereType<SetTaskTitleCommand>().single.title,
        'Charlie edited',
      );
      expect(
        repository.applied.whereType<SetTaskNotesCommand>().single.notes,
        'Kept here',
      );
      expect(autosave.draft(_alpha), isNull, reason: 'no draft moved over');
      expect(autosave.open(tasks.state.selectedTask!).title, 'Alpha');
      await autosave.close(_charlie);
      await autosave.close(_alpha);
      expect(
        repository.applied,
        hasLength(2),
        reason: 'viewing Alpha writes nothing',
      );
    });
  });

  group('opening a search result (Android audit 17)', () {
    Future<TasksViewModel> open() async {
      final repository = _TasksRepository();
      final tasks = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: repository,
        syncHealthRepository: const _HealthRepository(),
        clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
      );
      addTearDown(tasks.dispose);
      tasks.start();
      repository.snapshots.add(_orderSnapshot);
      await pumpEventQueue();
      return tasks;
    }

    test(
      'opens the matched subtask in the collection that shows its parent',
      () async {
        final tasks = await open();
        tasks.selectTaskList(const TaskListId(7));
        expect(tasks.openSearchResult(_childTwo), isTrue);
        expect(tasks.state.selectedTaskId, _childTwo);
        expect(tasks.state.selectedTaskListId, const TaskListId(7));
        final detail = TaskDetailViewModel.fromTasks(tasks).state!;
        expect(detail.parent?.id, _charlie);
        expect(detail.neighbors, const TaskNeighbors(previous: _childOne));
        TaskDetailViewModel.fromTasks(tasks).back();
        expect(tasks.state.selectedTaskId, _charlie);
      },
    );

    test('a hit outside the shown collection opens its own list', () async {
      final tasks = await open();
      tasks.selectTaskList(const TaskListId(7));
      expect(tasks.openSearchResult(_soloChild), isTrue);
      expect(tasks.state.selectedTaskListId, const TaskListId(8));
      expect(tasks.state.selectedSmartView, isNull);
      expect(tasks.state.selectedTaskId, _soloChild);
      TaskDetailViewModel.fromTasks(tasks).back();
      expect(tasks.state.selectedTaskId, _solo);
      TaskDetailViewModel.fromTasks(tasks).back();
      expect(tasks.state.selectedTaskId, isNull);
      expect(tasks.state.selectedTaskListId, const TaskListId(8));

      // A smart view that shows the parent is kept.
      tasks.selectSmartView(SmartView.all);
      expect(tasks.openSearchResult(_soloChild), isTrue);
      expect(tasks.state.selectedSmartView, SmartView.all);
      expect(tasks.state.selectedTaskId, _soloChild);

      // A completed top-level hit hidden by the filter keeps the list but has
      // no place in its order.
      tasks.selectTaskList(const TaskListId(7));
      expect(tasks.openSearchResult(_bravo), isTrue);
      expect(tasks.state.selectedTaskListId, const TaskListId(7));
      expect(tasks.selectedTaskNeighbors, TaskNeighbors.none);
    });

    test('an uncached hit changes nothing', () async {
      final tasks = await open();
      tasks.selectTaskList(const TaskListId(7));
      tasks.selectTask(_alpha);
      expect(tasks.openSearchResult(const TaskId(999)), isFalse);
      expect(tasks.state.selectedTaskId, _alpha);
      expect(tasks.state.selectedTaskListId, const TaskListId(7));
    });
  });
}

final class _TasksRepository implements TasksRepository {
  final snapshots = StreamController<CachedTasksSnapshot>.broadcast();
  final List<CreateTaskCommand> created = <CreateTaskCommand>[];
  final List<ExistingTaskCommand> applied = <ExistingTaskCommand>[];
  final List<DeleteTaskCommand> deleted = <DeleteTaskCommand>[];
  final List<SetTaskDueCommand> dueCommands = <SetTaskDueCommand>[];
  final List<int> undoneDueGroups = <int>[];

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => snapshots.stream;

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream.value(const <TaskDeleteUndo>[]);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => Stream.value(const <TaskDueChangeUndo>[]);

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
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async {
    dueCommands.add(command);
    return const Outcome<TaskDueChangeReceipt>.success(
      TaskDueChangeReceipt(undo: null),
    );
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

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async {
    undoneDueGroups.add(command.groupId);
    return const Outcome<void>.success(null);
  }
}

final class _FixedClock implements Clock {
  @override
  DateTime now() => DateTime(2026, 8, 15, 23, 30);

  @override
  Duration get monotonicElapsed => Duration.zero;
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
    CachedTask(
      id: TaskId(11),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: null,
      title: 'Parent',
      notes: '',
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 8, 20),
    ),
    CachedTask(
      id: TaskId(12),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(11),
      remoteId: null,
      title: 'First child',
      notes: null,
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 8, 16),
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

const _charlie = TaskId(21);
const _alpha = TaskId(22);
const _bravo = TaskId(23);
const _delta = TaskId(24);
const _childOne = TaskId(25);
const _childTwo = TaskId(26);
const _solo = TaskId(31);
const _soloChild = TaskId(32);

CachedTask _ordered(
  TaskId id,
  String title, {
  TaskId? parent,
  int list = 7,
  TaskStatus status = TaskStatus.needsAction,
  TaskDate? due,
}) => CachedTask(
  id: id,
  accountId: const AccountId(1),
  taskListId: TaskListId(list),
  parentTaskId: parent,
  remoteId: null,
  title: title,
  notes: null,
  status: status,
  due: due,
);

/// List 7 holds Charlie (with two subtasks), Alpha, completed Bravo and
/// Delta, the only dated task, in manual order; list 8 holds one parent.
CachedTasksSnapshot _orderWith({
  Set<TaskId> completed = const <TaskId>{},
  Set<TaskId> removed = const <TaskId>{},
}) {
  final tasks = <CachedTask>[
    _ordered(_charlie, 'Charlie'),
    _ordered(_childOne, 'Child one', parent: _charlie),
    _ordered(_alpha, 'Alpha'),
    _ordered(_bravo, 'Bravo', status: TaskStatus.completed),
    _ordered(_childTwo, 'Child two', parent: _charlie),
    _ordered(_delta, 'Delta', due: TaskDate(2026, 8, 16)),
    _ordered(_solo, 'Solo', list: 8),
    _ordered(_soloChild, 'Solo child', parent: _solo, list: 8),
  ];
  return CachedTasksSnapshot(
    accountId: const AccountId(1),
    taskLists: const <CachedTaskList>[
      CachedTaskList(
        id: TaskListId(7),
        accountId: AccountId(1),
        remoteId: null,
        title: 'Ordered list',
      ),
      CachedTaskList(
        id: TaskListId(8),
        accountId: AccountId(1),
        remoteId: null,
        title: 'Single list',
      ),
    ],
    tasks: <CachedTask>[
      for (final task in tasks)
        if (!removed.contains(task.id))
          completed.contains(task.id)
              ? _ordered(
                  task.id,
                  task.title,
                  parent: task.parentTaskId,
                  list: task.taskListId.value,
                  status: TaskStatus.completed,
                  due: task.due,
                )
              : task,
    ],
    completeness: CacheCompleteness.complete,
  );
}

final _orderSnapshot = _orderWith();

/// View preferences held in memory, emitted the way the stored repository
/// emits them.
final class _ViewPreferences implements PreferencesRepository {
  final _views = StreamController<Map<ViewKey, ViewPreferences>>.broadcast();
  final current = <ViewKey, ViewPreferences>{};

  Future<void> close() => _views.close();

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) async* {
    yield Map<ViewKey, ViewPreferences>.of(current);
    yield* _views.stream;
  }

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async {
    current[viewKey] = preferences;
    _views.add(Map<ViewKey, ViewPreferences>.of(current));
    return const Outcome<void>.success(null);
  }

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) => Stream.value(const <TaskListId, ListPreferences>{});

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => const Stream<ListPreferences>.empty();

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) => const Stream<ViewPreferences>.empty();

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  ) async => const Outcome<void>.success(null);

  @override
  Stream<DevicePreferences> watchDevicePreferences() =>
      Stream.value(const DevicePreferences.defaults());

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setWorkspacePreferences(
    DesktopWorkspacePreferences preferences,
  ) async => const Outcome<void>.success(null);
}
