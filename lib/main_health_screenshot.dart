import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'src/app/adaptive_shell.dart';
import 'src/core/clock.dart';
import 'src/core/outcome.dart';
import 'src/domain/commands/task_commands.dart';
import 'src/domain/commands/task_list_commands.dart';
import 'src/domain/model/preferences.dart';
import 'src/domain/model/tasks.dart';
import 'src/domain/policy/smart_views.dart';
import 'src/domain/repository/preferences_repository.dart';
import 'src/domain/repository/task_lists_repository.dart';
import 'src/domain/repository/tasks_repository.dart';
import 'src/features/tasks/tasks_view_model.dart';
import 'src/sync/health/sync_health.dart';
import 'src/sync/health/sync_health_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _HealthScreenshotSequence());
}

final class _HealthScreenshotSequence extends StatefulWidget {
  const _HealthScreenshotSequence();

  @override
  State<_HealthScreenshotSequence> createState() =>
      _HealthScreenshotSequenceState();
}

final class _HealthScreenshotSequenceState
    extends State<_HealthScreenshotSequence> {
  final GlobalKey _boundaryKey = GlobalKey();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  var _index = 0;
  late TasksViewModel _viewModel = _createViewModel(_captureScenarios.first);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _captureAll());
  }

  Future<void> _captureAll() async {
    try {
      final output = Directory('screenshots/actual');
      await output.create(recursive: true);
      for (var index = 0; index < _captureScenarios.length; index += 1) {
        await _settleFrames();
        if (_captureScenarios[index].name.startsWith('smart-views-') ||
            _captureScenarios[index].name.startsWith('quick-capture-')) {
          _viewModel.selectSmartView(SmartView.focus);
        }
        _viewModel.selectTask(const TaskId(11));
        await _settleFrames();
        final scenario = _captureScenarios[index];
        if (scenario.name == 'delete-list-confirmation') {
          unawaited(
            showDialog<void>(
              context: _navigatorKey.currentContext!,
              builder: (_) => DeleteTaskListConfirmationDialog(
                viewModel: _viewModel,
                taskList: scenario.snapshot.taskLists.first,
              ),
            ),
          );
          await _settleFrames();
        }
        final boundary =
            _boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (bytes == null) throw StateError('PNG encoding failed.');
        await File(
          '${output.path}/${_captureScenarios[index].name}.png',
        ).writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true,
        );
        if (index + 1 < _captureScenarios.length) {
          final previous = _viewModel;
          setState(() {
            _index = index + 1;
            _viewModel = _createViewModel(_captureScenarios[_index]);
          });
          await _settleFrames();
          previous.dispose();
        }
      }
      exit(0);
    } on Object catch (error) {
      stderr.writeln('Synthetic screenshot capture failed: $error');
      exit(1);
    }
  }

  Future<void> _settleFrames() async {
    await Future<void>.delayed(Duration.zero);
    for (var count = 0; count < 3; count += 1) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _boundaryKey,
      child: MaterialApp(
        key: ValueKey<String>('app-${_captureScenarios[_index].name}'),
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xff315da8),
          brightness: _captureScenarios[_index].name.endsWith('-dark')
              ? Brightness.dark
              : Brightness.light,
          useMaterial3: true,
        ),
        home: AdaptiveShell(
          key: ValueKey<String>(_captureScenarios[_index].name),
          viewModel: _viewModel,
          initialQuickAddInput:
              _captureScenarios[_index].name.startsWith('quick-capture-')
              ? 'Prepare synthetic brief tomorrow'
              : null,
          onHealthAction: (_) {},
        ),
      ),
    );
  }
}

TasksViewModel _createViewModel(_ScreenshotScenario scenario) => TasksViewModel(
  accountId: const AccountId(1),
  tasksRepository: _ScreenshotTasksRepository(
    scenario.snapshot,
    undos: scenario.name == 'delete-undo'
        ? <TaskDeleteUndo>[
            TaskDeleteUndo(
              taskId: const TaskId(11),
              title: 'Cached synthetic task',
              notBefore: DateTime.utc(2026, 8, 15, 12, 0, 30),
            ),
          ]
        : const <TaskDeleteUndo>[],
    dueUndos: scenario.name.startsWith('task-workflows-')
        ? <TaskDueChangeUndo>[
            TaskDueChangeUndo(
              groupId: 41,
              editedTaskId: const TaskId(11),
              editedTaskTitle: 'Plan the synthetic release',
              cascadedCount: 2,
              cascadedParent: false,
              createdAt: DateTime.utc(2026, 8, 15, 12),
            ),
          ]
        : const <TaskDueChangeUndo>[],
  ),
  taskListsRepository: const _ScreenshotTaskListsRepository(),
  preferencesRepository: const _ScreenshotPreferencesRepository(),
  syncHealthRepository: _ScreenshotHealthRepository(scenario.health),
  clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
);

final class _ScreenshotTasksRepository implements TasksRepository {
  const _ScreenshotTasksRepository(
    this.snapshot, {
    this.undos = const <TaskDeleteUndo>[],
    this.dueUndos = const <TaskDueChangeUndo>[],
  });

  final CachedTasksSnapshot snapshot;
  final List<TaskDeleteUndo> undos;
  final List<TaskDueChangeUndo> dueUndos;

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) =>
      Future.value(const Outcome<TaskId>.success(TaskId(900)));

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) =>
      Future.value(const Outcome<void>.success(null));

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) =>
      Stream.value(snapshot);

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream<List<TaskDeleteUndo>>.value(undos);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => Stream<List<TaskDueChangeUndo>>.value(dueUndos);

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async => Outcome<TaskDeleteReceipt>.success(
    TaskDeleteReceipt(taskId: command.taskId, notBefore: DateTime.utc(2026)),
  );

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async => const Outcome<TaskDueChangeReceipt>.success(
    TaskDueChangeReceipt(undo: null),
  );

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async => const Outcome<void>.success(null);
}

final class _ScreenshotTaskListsRepository implements TaskListsRepository {
  const _ScreenshotTaskListsRepository();

  @override
  Future<Outcome<TaskListId>> createTaskList(
    CreateTaskListCommand command,
  ) async => const Outcome<TaskListId>.success(TaskListId(90));

  @override
  Future<Outcome<void>> renameTaskList(RenameTaskListCommand command) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> deleteTaskList(DeleteTaskListCommand command) async =>
      const Outcome<void>.success(null);
}

final class _ScreenshotHealthRepository implements SyncHealthRepository {
  const _ScreenshotHealthRepository(this.health);

  final SyncHealth health;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(health);
}

final class _ScreenshotPreferencesRepository implements PreferencesRepository {
  const _ScreenshotPreferencesRepository();

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) => Stream.value(const <TaskListId, ListPreferences>{});

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) => Stream.value(const <ViewKey, ViewPreferences>{});

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => Stream.value(const ListPreferences.defaults());

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) => Stream.value(const ViewPreferences.defaults());

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
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Stream<DevicePreferences> watchDevicePreferences() =>
      Stream.value(const DevicePreferences.defaults());

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async =>
      const Outcome<void>.success(null);
}

typedef _ScreenshotScenario = ({
  String name,
  SyncHealth health,
  CachedTasksSnapshot snapshot,
});

final List<_ScreenshotScenario> _scenarios = <_ScreenshotScenario>[
  (
    name: 'task-details-light',
    snapshot: _taskDetailsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 2),
    ),
  ),
  (
    name: 'task-details-dark',
    snapshot: _taskDetailsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 2),
    ),
  ),
  (
    name: 'task-workflows-light',
    snapshot: _taskWorkflowsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 3),
    ),
  ),
  (
    name: 'task-workflows-dark',
    snapshot: _taskWorkflowsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 3),
    ),
  ),
  (
    name: 'smart-views-light',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
    ),
  ),
  (
    name: 'smart-views-dark',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
    ),
  ),
  (
    name: 'quick-capture-light',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'quick-capture-dark',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'health-cached-pending',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
      counts: const SyncWorkCounts(pending: 2),
    ),
  ),
  (
    name: 'health-partial-failed',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.remoteFailure,
      action: SyncHealthAction.retry,
      lastSuccessfulSyncAt: DateTime.utc(2026, 8, 15, 11, 58),
    ),
  ),
  (
    name: 'health-first-good',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.good,
      lastSuccessfulSyncAt: DateTime.utc(2026, 8, 15, 12),
    ),
  ),
  (
    name: 'health-stale-failed',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.stale,
      action: SyncHealthAction.retry,
      lastSuccessfulSyncAt: DateTime.utc(2026, 8, 15, 11, 45),
      counts: const SyncWorkCounts(uncertain: 1),
    ),
  ),
  (
    name: 'health-no-authorization',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.noAuthorization,
      action: SyncHealthAction.reauthorize,
      counts: const SyncWorkCounts(pending: 2),
    ),
  ),
  (
    name: 'health-sync-stopped',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.syncStopped,
      action: SyncHealthAction.resume,
      counts: const SyncWorkCounts(pending: 3, uncertain: 1),
    ),
  ),
  (
    name: 'health-retry-waiting',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.remoteFailure,
      action: SyncHealthAction.retry,
      retryNextAttemptAt: DateTime.utc(2026, 8, 15, 12, 0, 30),
      retryAttemptCount: 2,
    ),
  ),
  (
    name: 'health-retry-executing',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.retrying,
    ),
  ),
  (
    name: 'health-retry-exhausted',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.remoteFailure,
      action: SyncHealthAction.retry,
      automaticRetryExhausted: true,
    ),
  ),
  (
    name: 'list-create-pending',
    snapshot: CachedTasksSnapshot(
      accountId: const AccountId(1),
      taskLists: const <CachedTaskList>[
        CachedTaskList(
          id: TaskListId(21),
          accountId: AccountId(1),
          remoteId: null,
          title: 'Offline project',
        ),
        CachedTaskList(
          id: TaskListId(7),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-list'),
          title: 'Synthetic inbox',
        ),
      ],
      tasks: const <CachedTask>[],
      completeness: CacheCompleteness.complete,
    ),
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'list-rename-sync-stopped',
    snapshot: CachedTasksSnapshot(
      accountId: const AccountId(1),
      taskLists: const <CachedTaskList>[
        CachedTaskList(
          id: TaskListId(7),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-list'),
          title: 'Renamed offline',
        ),
      ],
      tasks: const <CachedTask>[
        CachedTask(
          id: TaskId(11),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: null,
          remoteId: TaskRemoteId('synthetic-task'),
          title: 'Cached synthetic task',
          notes: 'No personal data is used in this screenshot.',
          status: TaskStatus.needsAction,
          due: null,
        ),
      ],
      completeness: CacheCompleteness.complete,
    ),
    health: _health(
      SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.syncStopped,
      action: SyncHealthAction.resume,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'task-create-pending',
    snapshot: CachedTasksSnapshot(
      accountId: const AccountId(1),
      taskLists: const <CachedTaskList>[
        CachedTaskList(
          id: TaskListId(7),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-list'),
          title: 'Synthetic inbox',
        ),
      ],
      tasks: const <CachedTask>[
        CachedTask(
          id: TaskId(11),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: null,
          remoteId: null,
          title: 'Created while offline 🌍',
          notes: null,
          status: TaskStatus.needsAction,
          due: null,
        ),
      ],
      completeness: CacheCompleteness.complete,
    ),
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'task-content-sync-stopped',
    snapshot: CachedTasksSnapshot(
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
          id: const TaskId(11),
          accountId: const AccountId(1),
          taskListId: const TaskListId(7),
          parentTaskId: null,
          remoteId: const TaskRemoteId('synthetic-task'),
          title: 'Edited durably',
          notes: 'Unicode notes: 離線 🌍\nSecond line remains plain text.',
          status: TaskStatus.completed,
          due: TaskDate(2026, 8, 20),
        ),
      ],
      completeness: CacheCompleteness.complete,
    ),
    health: _health(
      SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.syncStopped,
      action: SyncHealthAction.resume,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'delete-undo',
    snapshot: CachedTasksSnapshot(
      accountId: const AccountId(1),
      taskLists: _baseSnapshot.taskLists,
      tasks: const <CachedTask>[],
      completeness: CacheCompleteness.complete,
    ),
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'delete-list-confirmation',
    snapshot: _baseSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
    ),
  ),
  (
    name: 'hierarchy-controls',
    snapshot: _hierarchySnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'hierarchy-unsupported-error',
    snapshot: _hierarchySnapshot,
    health: _health(
      SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.applicationFailure,
      diagnosticCode: 'sync.unsupported_task_depth',
    ),
  ),
];

const _requestedScenario = String.fromEnvironment(
  'AXIOTASK_SCREENSHOT_SCENARIO',
);

final List<_ScreenshotScenario> _captureScenarios = _requestedScenario.isEmpty
    ? _scenarios
    : <_ScreenshotScenario>[
        _scenarios.singleWhere(
          (scenario) => scenario.name == _requestedScenario,
        ),
      ];

final _baseSnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-list'),
      title: 'Synthetic inbox',
    ),
  ],
  tasks: const <CachedTask>[
    CachedTask(
      id: TaskId(11),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-task'),
      title: 'Cached synthetic task',
      notes: 'No personal data is used in this screenshot.',
      status: TaskStatus.needsAction,
      due: null,
    ),
  ],
  completeness: CacheCompleteness.complete,
);

final _taskDetailsSnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-detail-list'),
      title: 'Detail review',
    ),
    CachedTaskList(
      id: TaskListId(8),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-detail-archive'),
      title: 'Synthetic archive',
    ),
  ],
  tasks: const <CachedTask>[
    CachedTask(
      id: TaskId(11),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-detail-parent'),
      title: 'Prepare a complete task-detail review',
      notes:
          'Planning notes — café, naïve, résumé.\n'
          'Keep multiline text exact and readable.\n'
          'Task text stays plain: <b>not markup</b>.\n'
          'The detail pane scrolls for longer content.\n'
          'No real account or personal data is present.',
      status: TaskStatus.needsAction,
      due: null,
    ),
    CachedTask(
      id: TaskId(12),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(11),
      remoteId: TaskRemoteId('synthetic-detail-child-a'),
      title: 'Inspect multiline notes',
      notes: '',
      status: TaskStatus.completed,
      due: null,
    ),
    CachedTask(
      id: TaskId(13),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(11),
      remoteId: TaskRemoteId('synthetic-detail-child-b'),
      title: 'Exercise subtask actions',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
  ],
  completeness: CacheCompleteness.complete,
);

final _taskWorkflowsSnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-workflow-list'),
      title: 'Synthetic workflow review',
    ),
  ],
  tasks: <CachedTask>[
    CachedTask(
      id: const TaskId(11),
      accountId: const AccountId(1),
      taskListId: const TaskListId(7),
      parentTaskId: null,
      remoteId: const TaskRemoteId('synthetic-workflow-parent'),
      title: 'Plan the synthetic release',
      notes: 'Completion and dates use durable Google-bound commands.',
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 8, 20),
    ),
    CachedTask(
      id: const TaskId(12),
      accountId: const AccountId(1),
      taskListId: const TaskListId(7),
      parentTaskId: const TaskId(11),
      remoteId: const TaskRemoteId('synthetic-workflow-child-open'),
      title: 'Review the effective date',
      notes: null,
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 8, 15),
    ),
    CachedTask(
      id: const TaskId(13),
      accountId: const AccountId(1),
      taskListId: const TaskListId(7),
      parentTaskId: const TaskId(11),
      remoteId: const TaskRemoteId('synthetic-workflow-child-complete'),
      title: 'Verify Google completion authority',
      notes: null,
      status: TaskStatus.completed,
      due: TaskDate(2026, 8, 18),
    ),
  ],
  completeness: CacheCompleteness.complete,
);

final _smartViewsSnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-smart-inbox'),
      title: 'Focus lab',
    ),
    CachedTaskList(
      id: TaskListId(8),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-smart-plans'),
      title: 'Future plans',
    ),
  ],
  tasks: <CachedTask>[
    CachedTask(
      id: const TaskId(11),
      accountId: const AccountId(1),
      taskListId: const TaskListId(7),
      parentTaskId: null,
      remoteId: const TaskRemoteId('synthetic-smart-parent'),
      title: 'Prepare the smart-view review',
      notes: 'Synthetic projection evidence.',
      status: TaskStatus.needsAction,
      due: null,
    ),
    CachedTask(
      id: const TaskId(12),
      accountId: const AccountId(1),
      taskListId: const TaskListId(7),
      parentTaskId: const TaskId(11),
      remoteId: const TaskRemoteId('synthetic-smart-child'),
      title: 'Inspect inherited date',
      notes: null,
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 8, 16),
    ),
    CachedTask(
      id: const TaskId(13),
      accountId: const AccountId(1),
      taskListId: const TaskListId(7),
      parentTaskId: null,
      remoteId: const TaskRemoteId('synthetic-smart-overdue'),
      title: 'Review overdue section',
      notes: null,
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 8, 13),
    ),
    CachedTask(
      id: const TaskId(14),
      accountId: const AccountId(1),
      taskListId: const TaskListId(8),
      parentTaskId: null,
      remoteId: const TaskRemoteId('synthetic-smart-today'),
      title: 'Confirm visible row counts',
      notes: null,
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 8, 15),
    ),
    CachedTask(
      id: const TaskId(15),
      accountId: const AccountId(1),
      taskListId: const TaskListId(8),
      parentTaskId: null,
      remoteId: const TaskRemoteId('synthetic-smart-future'),
      title: 'Later than Focus',
      notes: null,
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 9, 15),
    ),
  ],
  completeness: CacheCompleteness.complete,
);

final _hierarchySnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-hierarchy-list'),
      title: 'Synthetic hierarchy',
    ),
    CachedTaskList(
      id: TaskListId(8),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-hierarchy-archive'),
      title: 'Synthetic archive',
    ),
  ],
  tasks: const <CachedTask>[
    CachedTask(
      id: TaskId(11),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-hierarchy-parent'),
      title: 'Plan the synthetic release',
      notes: 'Last valid supported hierarchy remains visible.',
      status: TaskStatus.needsAction,
      due: null,
    ),
    CachedTask(
      id: TaskId(12),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(11),
      remoteId: TaskRemoteId('synthetic-hierarchy-child'),
      title: 'Review protected hierarchy behavior',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
    CachedTask(
      id: TaskId(13),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-hierarchy-leaf'),
      title: 'Promote or demote this leaf',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
  ],
  completeness: CacheCompleteness.incomplete,
);

SyncHealth _health(
  SyncHealthOutcome outcome, {
  SyncInactiveReason? inactiveReason,
  SyncFailureReason? failureReason,
  SyncPendingReason? pendingReason,
  SyncHealthAction action = SyncHealthAction.none,
  DateTime? lastSuccessfulSyncAt,
  SyncWorkCounts counts = const SyncWorkCounts(),
  String? diagnosticCode,
  DateTime? retryNextAttemptAt,
  int retryAttemptCount = 0,
  bool automaticRetryExhausted = false,
}) => SyncHealth(
  outcome: outcome,
  inactiveReason: inactiveReason,
  failureReason: failureReason,
  pendingReason: pendingReason,
  action: action,
  counts: counts,
  diagnosticCode: diagnosticCode,
  retryNextAttemptAt: retryNextAttemptAt,
  retryAttemptCount: retryAttemptCount,
  automaticRetryExhausted: automaticRetryExhausted,
  lastSuccessfulSyncAt: lastSuccessfulSyncAt,
  evaluatedAt: DateTime.utc(2026, 8, 15, 12),
);
