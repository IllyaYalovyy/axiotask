import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'src/app/adaptive_shell.dart';
import 'src/app/visual_tokens.dart';
import 'src/core/clock.dart';
import 'src/core/failure.dart';
import 'src/core/outcome.dart';
import 'src/domain/commands/task_commands.dart';
import 'src/domain/commands/task_list_commands.dart';
import 'src/domain/model/bulk_operations.dart';
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
        final scenario = _captureScenarios[index];
        await _settleFrames();
        if (scenario.name.startsWith('smart-views-') ||
            scenario.name.startsWith('quick-capture-') ||
            scenario.name.startsWith('bulk-capture-') ||
            scenario.name.startsWith('bulk-operation-')) {
          _viewModel.selectSmartView(SmartView.focus);
        }
        if (scenario.name == 'bulk-operation-selection-light' ||
            scenario.name == 'bulk-operation-confirmation-light') {
          _viewModel.beginBulkSelection(const TaskId(11));
          _viewModel.toggleBulkSelection(const TaskId(13));
        } else if (!scenario.name.startsWith('search-results-') &&
            scenario.name != 'bulk-operation-result-dark' &&
            scenario.name != 'bulk-delete-undo-light' &&
            scenario.name != 'clear-completed-confirmation-dark') {
          _viewModel.selectTask(const TaskId(11));
        }
        await _settleFrames();
        if (scenario.name.contains('-result-')) {
          _pressBulkAddSubmit();
          await _settleFrames();
        }
        if (scenario.name == 'bulk-operation-confirmation-light') {
          _pressButton(const Key('bulk-complete-open'));
          await _settleFrames();
        }
        if (scenario.name == 'clear-completed-confirmation-dark') {
          _pressButton(const Key('clear-completed-open'));
          await _settleFrames();
        }
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
        var dragHeld = false;
        if (scenario.name == 'drag-preview-light') {
          await _performSyntheticDrag(release: false);
          dragHeld = true;
        } else if (scenario.name == 'drag-failure-dark') {
          await _performSyntheticDrag(release: true);
        }
        final boundary =
            _boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (bytes == null) throw StateError('PNG encoding failed.');
        final suffix = _screenshotOutputSuffix;
        final outputName = suffix.isEmpty
            ? _captureScenarios[index].name
            : '${_captureScenarios[index].name}-$suffix';
        await File('${output.path}/$outputName.png').writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true,
        );
        if (dragHeld) {
          GestureBinding.instance.handlePointerEvent(
            const PointerUpEvent(pointer: 42, position: Offset(500, 420)),
          );
          GestureBinding.instance.handlePointerEvent(
            const PointerRemovedEvent(pointer: 42, position: Offset(500, 420)),
          );
          await _settleFrames();
        }
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

  Future<void> _performSyntheticDrag({required bool release}) async {
    final source = _renderBoxFor(const Key('desktop-task-row-13'));
    final target = _renderBoxFor(const Key('desktop-task-row-11'));
    final sourcePosition = source.localToGlobal(
      source.size.center(Offset.zero),
    );
    final targetPosition = target.localToGlobal(const Offset(80, 8));
    GestureBinding.instance.handlePointerEvent(
      PointerAddedEvent(pointer: 42, position: sourcePosition),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        pointer: 42,
        position: sourcePosition,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      ),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerMoveEvent(
        pointer: 42,
        position: targetPosition,
        delta: targetPosition - sourcePosition,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      ),
    );
    if (release) {
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          pointer: 42,
          position: targetPosition,
          kind: PointerDeviceKind.mouse,
        ),
      );
      GestureBinding.instance.handlePointerEvent(
        PointerRemovedEvent(pointer: 42, position: targetPosition),
      );
    }
    await _settleFrames();
  }

  RenderBox _renderBoxFor(Key key) {
    RenderBox? result;
    void visit(Element element) {
      if (element.widget.key == key) {
        result = element.findRenderObject()! as RenderBox;
        return;
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root == null) throw StateError('Screenshot element tree unavailable.');
    visit(root);
    return result ?? (throw StateError('Screenshot target $key unavailable.'));
  }

  @override
  Widget build(BuildContext context) {
    final boundary = RepaintBoundary(
      key: _boundaryKey,
      child: MaterialApp(
        key: ValueKey<String>('app-${_captureScenarios[_index].name}'),
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: axiotaskTheme(
          _captureScenarios[_index].name.endsWith('-dark')
              ? Brightness.dark
              : Brightness.light,
          DensityPreference.standard,
        ),
        home: AdaptiveShell(
          key: ValueKey<String>(_captureScenarios[_index].name),
          viewModel: _viewModel,
          initialQuickAddInput:
              _captureScenarios[_index].name.startsWith('quick-capture-')
              ? 'Prepare synthetic brief tomorrow'
              : null,
          initialBulkAddInput:
              _captureScenarios[_index].name.startsWith('bulk-capture-')
              ? 'Draft release notes\nReview accessibility\nVerify restart recovery'
              : null,
          initialSearchQuery:
              _captureScenarios[_index].name.startsWith('search-results-')
              ? 'inherited'
              : null,
          onHealthAction: (_) {},
        ),
      ),
    );
    final requestedSize = _screenshotSize;
    if (requestedSize != null) {
      return OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: requestedSize.width,
        maxWidth: requestedSize.width,
        minHeight: requestedSize.height,
        maxHeight: requestedSize.height,
        child: SizedBox(
          width: requestedSize.width,
          height: requestedSize.height,
          child: boundary,
        ),
      );
    }
    if (_captureScenarios[_index].name != 'desktop-interactions-1024-light') {
      return boundary;
    }
    final viewSize = MediaQueryData.fromView(View.of(context)).size;
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 1024, height: viewSize.height, child: boundary),
    );
  }

  void _pressBulkAddSubmit() {
    _pressButton(const Key('bulk-add-submit'));
  }

  void _pressButton(Key key) {
    void visit(Element element) {
      final widget = element.widget;
      if (widget is ButtonStyleButton && widget.key == key) {
        widget.onPressed?.call();
        return;
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root == null) throw StateError('Screenshot element tree unavailable.');
    visit(root);
  }
}

TasksViewModel _createViewModel(_ScreenshotScenario scenario) => TasksViewModel(
  accountId: const AccountId(1),
  tasksRepository:
      scenario.name == 'bulk-delete-undo-light' ||
          scenario.name == 'clear-completed-confirmation-dark'
      ? _DestructiveScreenshotTasksRepository(
          scenario.snapshot,
          groupUndos: scenario.name == 'bulk-delete-undo-light'
              ? <TaskDeleteGroupUndo>[
                  TaskDeleteGroupUndo(
                    groupId: 51,
                    selectedCount: 2,
                    rootCount: 2,
                    notBefore: DateTime.utc(2026, 8, 15, 12, 0, 30),
                  ),
                ]
              : const <TaskDeleteGroupUndo>[],
        )
      : _ScreenshotTasksRepository(
          scenario.snapshot,
          bulkSummary: scenario.name == 'bulk-operation-result-dark'
              ? _bulkScreenshotSummary
              : null,
          failMoves: scenario.name == 'drag-failure-dark',
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

class _ScreenshotTasksRepository
    implements
        TasksRepository,
        BulkTasksRepository,
        BulkTaskOperationsRepository {
  const _ScreenshotTasksRepository(
    this.snapshot, {
    this.undos = const <TaskDeleteUndo>[],
    this.dueUndos = const <TaskDueChangeUndo>[],
    this.failMoves = false,
    this.bulkSummary,
  });

  final CachedTasksSnapshot snapshot;
  final List<TaskDeleteUndo> undos;
  final List<TaskDueChangeUndo> dueUndos;
  final bool failMoves;
  final BulkOperationSummary? bulkSummary;

  @override
  Stream<BulkOperationSummary?> watchLatestBulkOperation(AccountId accountId) =>
      Stream.value(bulkSummary);

  @override
  Future<Outcome<BulkOperationReceipt>> applyBulk(
    BulkExistingTaskCommand command,
  ) async => Outcome.success(
    BulkOperationReceipt(
      summary: _bulkScreenshotSummary,
      taskIds: command.taskIds.toList(growable: false),
    ),
  );

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) =>
      Future.value(const Outcome<TaskId>.success(TaskId(900)));

  @override
  Future<Outcome<List<TaskId>>> createTasks(BulkCreateTasksCommand command) =>
      Future.value(
        Outcome<List<TaskId>>.success(
          List<TaskId>.generate(
            command.entries.length,
            (index) => TaskId(910 + index),
          ),
        ),
      );

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) => Future.value(
    failMoves && command is MoveTaskCommand
        ? const Outcome<void>.failure(
            Failure(
              code: 'sync.synthetic_structure_rejected',
              category: FailureCategory.remote,
              operation: FailureOperation.write,
              retry: RetryClassification.permanent,
              impact: 'Synthetic structure failure.',
              safeSummary: 'Synthetic structure failure.',
            ),
          )
        : const Outcome<void>.success(null),
  );

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

final class _DestructiveScreenshotTasksRepository
    extends _ScreenshotTasksRepository
    implements DestructiveTaskOperationsRepository {
  const _DestructiveScreenshotTasksRepository(
    super.snapshot, {
    this.groupUndos = const <TaskDeleteGroupUndo>[],
  });

  final List<TaskDeleteGroupUndo> groupUndos;

  @override
  Stream<List<TaskDeleteGroupUndo>> watchUndoableTaskDeleteGroups(
    AccountId accountId,
  ) => Stream.value(groupUndos);

  @override
  Future<Outcome<BulkOperationReceipt>> clearCompleted(
    ClearCompletedTasksCommand command,
  ) async => Outcome.success(
    BulkOperationReceipt(
      summary: BulkOperationSummary(
        operationId: 52,
        kind: BulkOperationKind.clearCompleted,
        selectedCount: 1,
        affectedCount: 1,
        confirmedCount: 0,
        pendingCount: 1,
        failedCount: 0,
        createdAt: DateTime.utc(2026, 8, 15, 12),
      ),
      taskIds: const <TaskId>[TaskId(13)],
    ),
  );

  @override
  Future<Outcome<void>> undoTaskDeleteGroup(
    UndoTaskDeleteGroupCommand command,
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
    name: 'bulk-delete-undo-light',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 2),
    ),
  ),
  (
    name: 'clear-completed-confirmation-dark',
    snapshot: _clearCompletedSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'bulk-operation-selection-light',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 2),
    ),
  ),
  (
    name: 'bulk-operation-result-dark',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.remoteFailure,
      action: SyncHealthAction.retry,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'bulk-operation-confirmation-light',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 2),
    ),
  ),
  (
    name: 'drag-preview-light',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'drag-failure-dark',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.remoteFailure,
      counts: const SyncWorkCounts(pending: 1),
    ),
  ),
  (
    name: 'desktop-interactions-1024-light',
    snapshot: _taskDetailsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 2),
    ),
  ),
  (
    name: 'desktop-interactions-1280-dark',
    snapshot: _taskDetailsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 2),
    ),
  ),
  (
    name: 'search-results-light',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
    ),
  ),
  (
    name: 'search-results-dark',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
    ),
  ),
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
    name: 'bulk-capture-preview-light',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 3),
    ),
  ),
  (
    name: 'bulk-capture-preview-dark',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 3),
    ),
  ),
  (
    name: 'bulk-capture-result-light',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 3),
    ),
  ),
  (
    name: 'bulk-capture-result-dark',
    snapshot: _smartViewsSnapshot,
    health: _health(
      SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 3),
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

final _bulkScreenshotSummary = BulkOperationSummary(
  operationId: 28,
  kind: BulkOperationKind.move,
  selectedCount: 3,
  affectedCount: 2,
  confirmedCount: 1,
  pendingCount: 0,
  failedCount: 1,
  createdAt: DateTime.utc(2026, 8, 16, 14),
);

const _requestedScenario = String.fromEnvironment(
  'AXIOTASK_SCREENSHOT_SCENARIO',
);

const _requestedSize = String.fromEnvironment('AXIOTASK_SCREENSHOT_SIZE');
const _screenshotOutputSuffix = String.fromEnvironment(
  'AXIOTASK_SCREENSHOT_OUTPUT_SUFFIX',
);

Size? get _screenshotSize {
  final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(_requestedSize);
  if (match == null) return null;
  return Size(double.parse(match.group(1)!), double.parse(match.group(2)!));
}

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

final _clearCompletedSnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-clear-list'),
      title: 'Safety review',
    ),
  ],
  tasks: const <CachedTask>[
    CachedTask(
      id: TaskId(31),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-clear-parent'),
      title: 'Completed parent kept safely',
      notes: null,
      status: TaskStatus.completed,
      due: null,
    ),
    CachedTask(
      id: TaskId(32),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(31),
      remoteId: TaskRemoteId('synthetic-clear-child'),
      title: 'Unfinished child remains',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
    CachedTask(
      id: TaskId(33),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-clear-leaf'),
      title: 'Completed leaf is selected',
      notes: null,
      status: TaskStatus.completed,
      due: null,
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
