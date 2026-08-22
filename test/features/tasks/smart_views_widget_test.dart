import 'dart:async';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/preferences_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('smart controls keep badges and visible rows in agreement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = _PreferencesRepository();
    addTearDown(preferences.close);
    final viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: const _TasksRepository(),
      preferencesRepository: preferences,
      syncHealthRepository: const _HealthRepository(),
      clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();

    expect(find.text('Soon parent'), findsOneWidget);
    expect(find.text('Other list today'), findsOneWidget);
    expect(find.text('Completed today'), findsNothing);
    expect(find.text('2 cached tasks'), findsOneWidget);
    await tester.tap(find.byTooltip('Collection actions'));
    await tester.pumpAndSettle();
    expect(find.text('Show completed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('collection-show-completed')));
    await tester.pumpAndSettle();
    expect(find.text('Completed today'), findsOneWidget);
    expect(find.text('3 cached tasks'), findsOneWidget);

    final secondListTile = find.ancestor(
      of: find.text('Second'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(
        of: secondListTile,
        matching: find.byTooltip('List view settings'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exclude from smart views'));
    await tester.pumpAndSettle();

    expect(find.text('Other list today'), findsNothing);
    expect(find.text('2 cached tasks'), findsOneWidget);
    expect(find.byTooltip('Excluded from smart views'), findsOneWidget);
  });
}

final class _TasksRepository implements TasksRepository {
  const _TasksRepository();

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => Stream.value(
    CachedTasksSnapshot(
      accountId: query.accountId,
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
        _task(
          2,
          title: 'Child tomorrow',
          parent: 1,
          due: TaskDate(2026, 8, 16),
        ),
        _task(
          3,
          title: 'Completed today',
          due: TaskDate(2026, 8, 15),
          status: TaskStatus.completed,
        ),
        _task(
          4,
          title: 'Other list today',
          list: 20,
          due: TaskDate(2026, 8, 15),
        ),
      ],
      completeness: CacheCompleteness.complete,
    ),
  );

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream.value(const <TaskDeleteUndo>[]);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => Stream.value(const <TaskDueChangeUndo>[]);

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) =>
      Future.value(const Outcome<void>.success(null));

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(SetTaskDueCommand command) =>
      Future.value(const Outcome.success(TaskDueChangeReceipt(undo: null)));

  @override
  Future<Outcome<void>> undoTaskDueChange(UndoTaskDueChangeCommand command) =>
      Future.value(const Outcome.success(null));

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
  final _lists = <TaskListId, ListPreferences>{};
  final _views = <ViewKey, ViewPreferences>{};
  final _listChanges =
      StreamController<Map<TaskListId, ListPreferences>>.broadcast();
  final _viewChanges =
      StreamController<Map<ViewKey, ViewPreferences>>.broadcast();

  Future<void> close() async {
    await _listChanges.close();
    await _viewChanges.close();
  }

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) async* {
    yield Map<TaskListId, ListPreferences>.of(_lists);
    yield* _listChanges.stream;
  }

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) async* {
    yield Map<ViewKey, ViewPreferences>.of(_views);
    yield* _viewChanges.stream;
  }

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) async {
    _lists[taskListId] = preferences;
    _listChanges.add(Map<TaskListId, ListPreferences>.of(_lists));
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async {
    _views[viewKey] = preferences;
    _viewChanges.add(Map<ViewKey, ViewPreferences>.of(_views));
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  ) async => const Outcome<void>.success(null);

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => watchAllListPreferences(
    accountId,
  ).map((value) => value[taskListId] ?? const ListPreferences.defaults());

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) => watchAllViewPreferences(
    accountId,
  ).map((value) => value[viewKey] ?? const ViewPreferences.defaults());

  @override
  Stream<DevicePreferences> watchDevicePreferences() =>
      Stream.value(const DevicePreferences.defaults());

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setWorkspacePreferences(
    DesktopWorkspacePreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async =>
      const Outcome<void>.success(null);
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
