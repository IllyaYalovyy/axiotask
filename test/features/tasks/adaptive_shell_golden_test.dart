import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/bulk_operations.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(_loadFlutterRoboto);

  final cases = <(String, SyncHealth)>[
    (
      'cached_pending',
      _health(
        SyncHealthOutcome.pending,
        pendingReason: SyncPendingReason.verifying,
        counts: const SyncWorkCounts(pending: 2),
      ),
    ),
    (
      'stale_failed',
      _health(
        SyncHealthOutcome.failed,
        failureReason: SyncFailureReason.stale,
        action: SyncHealthAction.retry,
        lastSuccessfulSyncAt: DateTime.utc(2026, 8, 15, 11, 45),
        counts: const SyncWorkCounts(uncertain: 1),
      ),
    ),
    (
      'no_authorization',
      _health(
        SyncHealthOutcome.inactive,
        inactiveReason: SyncInactiveReason.noAuthorization,
        action: SyncHealthAction.reauthorize,
        lastSuccessfulSyncAt: DateTime.utc(2026, 8, 15, 10),
        counts: const SyncWorkCounts(pending: 2),
      ),
    ),
    (
      'sync_stopped',
      _health(
        SyncHealthOutcome.inactive,
        inactiveReason: SyncInactiveReason.syncStopped,
        action: SyncHealthAction.resume,
        lastSuccessfulSyncAt: DateTime.utc(2026, 8, 14, 12),
        counts: const SyncWorkCounts(pending: 3, uncertain: 1),
      ),
    ),
    (
      'hierarchy_error',
      _health(
        SyncHealthOutcome.failed,
        failureReason: SyncFailureReason.applicationFailure,
        counts: const SyncWorkCounts(),
        diagnosticCode: 'sync.unsupported_task_depth',
      ),
    ),
    (
      'retry_waiting',
      _health(
        SyncHealthOutcome.failed,
        failureReason: SyncFailureReason.remoteFailure,
        action: SyncHealthAction.retry,
        retryNextAttemptAt: DateTime.utc(2026, 8, 15, 12, 0, 30),
        retryAttemptCount: 2,
      ),
    ),
    (
      'retry_executing',
      _health(
        SyncHealthOutcome.pending,
        pendingReason: SyncPendingReason.retrying,
      ),
    ),
    (
      'retry_exhausted',
      _health(
        SyncHealthOutcome.failed,
        failureReason: SyncFailureReason.remoteFailure,
        action: SyncHealthAction.retry,
        automaticRetryExhausted: true,
      ),
    ),
  ];

  for (final (name, health) in cases) {
    testWidgets('Linux $name', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: const _GoldenTasksRepository(),
        syncHealthRepository: _GoldenHealthRepository(health),
      );
      addTearDown(viewModel.dispose);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: const Color(0xff315da8),
            fontFamily: 'GoldenRoboto',
            useMaterial3: true,
          ),
          home: AdaptiveShell(viewModel: viewModel, onHealthAction: (_) {}),
        ),
      );
      await tester.pump();
      viewModel.selectTask(const TaskId(11));
      await tester.pump();

      await expectLater(
        find.byType(AdaptiveShell),
        matchesGoldenFile('../../goldens/linux/health_$name.png'),
      );
    });
  }

  testWidgets('Linux durable delete Undo', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: _GoldenTasksRepository(
        hideDeletedSubtree: true,
        undos: <TaskDeleteUndo>[
          TaskDeleteUndo(
            taskId: const TaskId(11),
            title: 'Prepare the synthetic review',
            notBefore: DateTime.utc(2026, 8, 15, 12, 0, 30),
          ),
        ],
      ),
      syncHealthRepository: _GoldenHealthRepository(
        _health(
          SyncHealthOutcome.pending,
          pendingReason: SyncPendingReason.verifying,
          counts: const SyncWorkCounts(pending: 1),
        ),
      ),
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xff315da8),
          fontFamily: 'GoldenRoboto',
          useMaterial3: true,
        ),
        home: AdaptiveShell(viewModel: viewModel, onHealthAction: (_) {}),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byType(AdaptiveShell),
      matchesGoldenFile('../../goldens/linux/delete_undo.png'),
    );
  });

  for (final (width, brightness) in <(double, Brightness)>[
    (1024, Brightness.light),
    (1280, Brightness.dark),
  ]) {
    testWidgets('Linux desktop interactions $width ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: const _GoldenTasksRepository(),
        syncHealthRepository: _GoldenHealthRepository(
          _health(
            SyncHealthOutcome.pending,
            pendingReason: SyncPendingReason.verifying,
            counts: const SyncWorkCounts(pending: 2),
          ),
        ),
      );
      addTearDown(viewModel.dispose);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: brightness,
            colorSchemeSeed: const Color(0xff315da8),
            fontFamily: 'GoldenRoboto',
            useMaterial3: true,
          ),
          home: AdaptiveShell(viewModel: viewModel, onHealthAction: (_) {}),
        ),
      );
      await tester.pump();
      viewModel.selectTask(const TaskId(11));
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('desktop-task-row-11'))),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(AdaptiveShell),
        matchesGoldenFile(
          '../../goldens/linux/desktop_interactions_${width.toInt()}_${brightness.name}.png',
        ),
      );
    });
  }

  testWidgets('Linux drag preview light', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: const _GoldenTasksRepository(showCompletedTask: true),
      syncHealthRepository: _GoldenHealthRepository(
        _health(
          SyncHealthOutcome.pending,
          pendingReason: SyncPendingReason.localChanges,
          counts: const SyncWorkCounts(pending: 1),
        ),
      ),
    );
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xff315da8),
          fontFamily: 'GoldenRoboto',
          useMaterial3: true,
        ),
        home: AdaptiveShell(viewModel: viewModel, onHealthAction: (_) {}),
      ),
    );
    await tester.pump();
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('desktop-task-row-13'))),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(
      tester.getTopLeft(find.byKey(const Key('desktop-task-row-11'))) +
          const Offset(80, 8),
    );
    await tester.pump();

    await expectLater(
      find.byType(AdaptiveShell),
      matchesGoldenFile('../../goldens/linux/drag_preview_light.png'),
    );
    await drag.up();
  });

  testWidgets('Linux drag failure dark restores canonical order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: const _GoldenTasksRepository(
        failMoves: true,
        showCompletedTask: true,
      ),
      syncHealthRepository: _GoldenHealthRepository(
        _health(
          SyncHealthOutcome.failed,
          failureReason: SyncFailureReason.remoteFailure,
          counts: const SyncWorkCounts(pending: 1),
        ),
      ),
    );
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xff315da8),
          fontFamily: 'GoldenRoboto',
          useMaterial3: true,
        ),
        home: AdaptiveShell(viewModel: viewModel, onHealthAction: (_) {}),
      ),
    );
    await tester.pump();
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('desktop-task-row-13'))),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(
      tester.getTopLeft(find.byKey(const Key('desktop-task-row-11'))) +
          const Offset(80, 8),
    );
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(AdaptiveShell),
      matchesGoldenFile('../../goldens/linux/drag_failure_dark.png'),
    );
  });

  for (final scenario in <(String, Brightness, BulkOperationSummary?)>[
    ('selection_light', Brightness.light, null),
    ('result_dark', Brightness.dark, _bulkGoldenSummary),
  ]) {
    testWidgets('Linux bulk ${scenario.$1}', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: _BulkGoldenTasksRepository(summary: scenario.$3),
        syncHealthRepository: _GoldenHealthRepository(
          _health(
            SyncHealthOutcome.pending,
            pendingReason: SyncPendingReason.localChanges,
            counts: const SyncWorkCounts(pending: 2),
          ),
        ),
      );
      addTearDown(viewModel.dispose);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: scenario.$2,
            colorSchemeSeed: const Color(0xff315da8),
            fontFamily: 'GoldenRoboto',
            useMaterial3: true,
          ),
          home: AdaptiveShell(viewModel: viewModel, onHealthAction: (_) {}),
        ),
      );
      await tester.pump();
      if (scenario.$3 == null) {
        viewModel.beginBulkSelection(const TaskId(11));
        viewModel.toggleBulkSelection(const TaskId(13));
        await tester.pump();
      }

      await expectLater(
        find.byType(AdaptiveShell),
        matchesGoldenFile('../../goldens/linux/bulk_${scenario.$1}.png'),
      );
    });
  }

  testWidgets('Linux bulk confirmation light', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: const _BulkGoldenTasksRepository(),
      syncHealthRepository: _GoldenHealthRepository(
        _health(
          SyncHealthOutcome.pending,
          pendingReason: SyncPendingReason.localChanges,
          counts: const SyncWorkCounts(pending: 2),
        ),
      ),
    );
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xff315da8),
          fontFamily: 'GoldenRoboto',
          useMaterial3: true,
        ),
        home: AdaptiveShell(viewModel: viewModel, onHealthAction: (_) {}),
      ),
    );
    await tester.pump();
    viewModel.beginBulkSelection(const TaskId(11));
    viewModel.toggleBulkSelection(const TaskId(13));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-complete-open')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../goldens/linux/bulk_confirmation_light.png'),
    );
  });

  testWidgets('Linux grouped bulk delete Undo light', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: _DestructiveGoldenTasksRepository(
        groupUndos: <TaskDeleteGroupUndo>[
          TaskDeleteGroupUndo(
            groupId: 51,
            selectedCount: 2,
            rootCount: 2,
            notBefore: DateTime.utc(2026, 8, 15, 12, 0, 30),
          ),
        ],
      ),
      syncHealthRepository: _GoldenHealthRepository(
        _health(
          SyncHealthOutcome.pending,
          pendingReason: SyncPendingReason.localChanges,
          counts: const SyncWorkCounts(pending: 2),
        ),
      ),
    );
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xff315da8),
          fontFamily: 'GoldenRoboto',
          useMaterial3: true,
        ),
        home: AdaptiveShell(viewModel: viewModel),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(AdaptiveShell),
      matchesGoldenFile('../../goldens/linux/bulk_delete_undo_light.png'),
    );
  });

  testWidgets('Linux Clear completed confirmation dark', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: const _DestructiveGoldenTasksRepository(),
      syncHealthRepository: _GoldenHealthRepository(
        _health(
          SyncHealthOutcome.pending,
          pendingReason: SyncPendingReason.localChanges,
          counts: const SyncWorkCounts(pending: 1),
        ),
      ),
    );
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xff315da8),
          fontFamily: 'GoldenRoboto',
          useMaterial3: true,
        ),
        home: AdaptiveShell(viewModel: viewModel),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear-completed-open')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        '../../goldens/linux/clear_completed_confirmation_dark.png',
      ),
    );
  });
}

Future<void> _loadFlutterRoboto() async {
  final packageConfig = File('.dart_tool/package_config.json');
  final document = jsonDecode(await packageConfig.readAsString());
  final packages =
      (document as Map<String, Object?>)['packages']! as List<Object?>;
  final flutter = packages.cast<Map<String, Object?>>().singleWhere(
    (value) => value['name'] == 'flutter',
  );
  final configUri = packageConfig.absolute.uri;
  final flutterPackage = Directory.fromUri(
    configUri.resolve(flutter['rootUri']! as String),
  );
  final flutterRoot = flutterPackage.parent.parent;
  final fontFile = File(
    '${flutterRoot.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  if (!fontFile.existsSync()) {
    throw StateError('The locked Flutter SDK Roboto font is unavailable.');
  }
  final bytes = await fontFile.readAsBytes();
  await (FontLoader('GoldenRoboto')..addFont(
        Future<ByteData>.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
        ),
      ))
      .load();
}

final class _GoldenTasksRepository implements TasksRepository {
  const _GoldenTasksRepository({
    this.undos = const <TaskDeleteUndo>[],
    this.hideDeletedSubtree = false,
    this.failMoves = false,
    this.showCompletedTask = false,
  });

  final List<TaskDeleteUndo> undos;
  final bool hideDeletedSubtree;
  final bool failMoves;
  final bool showCompletedTask;

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) =>
      Future.value(const Outcome<TaskId>.success(TaskId(900)));

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
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => Stream.value(
    CachedTasksSnapshot(
      accountId: query.accountId,
      taskLists: const <CachedTaskList>[
        CachedTaskList(
          id: TaskListId(7),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-list'),
          title: 'Synthetic inbox',
        ),
        CachedTaskList(
          id: TaskListId(8),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-work'),
          title: 'Sample projects',
        ),
      ],
      tasks: <CachedTask>[
        if (!hideDeletedSubtree) ...<CachedTask>[
          CachedTask(
            id: const TaskId(11),
            accountId: const AccountId(1),
            taskListId: const TaskListId(7),
            parentTaskId: null,
            remoteId: const TaskRemoteId('synthetic-parent'),
            title: 'Prepare the synthetic review',
            notes: 'This cached note is synthetic and safe for visual testing.',
            status: TaskStatus.needsAction,
            due: TaskDate(2026, 8, 16),
          ),
          const CachedTask(
            id: TaskId(12),
            accountId: AccountId(1),
            taskListId: TaskListId(7),
            parentTaskId: TaskId(11),
            remoteId: TaskRemoteId('synthetic-child'),
            title: 'Check the task details pane',
            notes: null,
            status: TaskStatus.needsAction,
            due: null,
          ),
        ],
        CachedTask(
          id: TaskId(13),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: null,
          remoteId: TaskRemoteId('synthetic-completed'),
          title: 'Confirm cache isolation',
          notes: null,
          status: showCompletedTask
              ? TaskStatus.needsAction
              : TaskStatus.completed,
          due: null,
        ),
      ],
      completeness: CacheCompleteness.complete,
    ),
  );

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream<List<TaskDeleteUndo>>.value(undos);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => Stream.value(const <TaskDueChangeUndo>[]);

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async => const Outcome.success(TaskDueChangeReceipt(undo: null));

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async => const Outcome.success(null);

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async => Outcome<TaskDeleteReceipt>.success(
    TaskDeleteReceipt(taskId: command.taskId, notBefore: DateTime.utc(2026)),
  );

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      const Outcome<void>.success(null);
}

final class _GoldenHealthRepository implements SyncHealthRepository {
  const _GoldenHealthRepository(this.health);

  final SyncHealth health;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(health);
}

class _BulkGoldenTasksRepository
    implements TasksRepository, BulkTaskOperationsRepository {
  const _BulkGoldenTasksRepository({this.summary});

  final BulkOperationSummary? summary;
  static const _delegate = _GoldenTasksRepository(showCompletedTask: true);

  @override
  Stream<BulkOperationSummary?> watchLatestBulkOperation(AccountId accountId) =>
      Stream.value(summary);

  @override
  Future<Outcome<BulkOperationReceipt>> applyBulk(
    BulkExistingTaskCommand command,
  ) async => Outcome.success(
    BulkOperationReceipt(
      summary: _bulkGoldenSummary,
      taskIds: command.taskIds.toList(growable: false),
    ),
  );

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) =>
      _delegate.apply(command);

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) =>
      _delegate.createTask(command);

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(DeleteTaskCommand command) =>
      _delegate.deleteTask(command);

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(SetTaskDueCommand command) =>
      _delegate.setTaskDue(command);

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) =>
      _delegate.undoTaskDelete(command);

  @override
  Future<Outcome<void>> undoTaskDueChange(UndoTaskDueChangeCommand command) =>
      _delegate.undoTaskDueChange(command);

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) =>
      _delegate.watchTasks(query);

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      _delegate.watchUndoableTaskDeletes(accountId);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => _delegate.watchUndoableTaskDueChanges(accountId);
}

final class _DestructiveGoldenTasksRepository extends _BulkGoldenTasksRepository
    implements DestructiveTaskOperationsRepository {
  const _DestructiveGoldenTasksRepository({this.groupUndos = const []});

  final List<TaskDeleteGroupUndo> groupUndos;
  static const _clearDelegate = _GoldenTasksRepository();

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) =>
      _clearDelegate.watchTasks(query);

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
  ) async => const Outcome.success(null);
}

final _bulkGoldenSummary = BulkOperationSummary(
  operationId: 28,
  kind: BulkOperationKind.move,
  selectedCount: 3,
  affectedCount: 2,
  confirmedCount: 1,
  pendingCount: 0,
  failedCount: 1,
  createdAt: DateTime.utc(2026, 8, 16, 14),
);

SyncHealth _health(
  SyncHealthOutcome outcome, {
  SyncInactiveReason? inactiveReason,
  SyncFailureReason? failureReason,
  SyncPendingReason? pendingReason,
  SyncHealthAction action = SyncHealthAction.none,
  DateTime? lastSuccessfulSyncAt,
  String? diagnosticCode,
  SyncWorkCounts counts = const SyncWorkCounts(),
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
  lastSuccessfulSyncAt: lastSuccessfulSyncAt,
  diagnosticCode: diagnosticCode,
  retryNextAttemptAt: retryNextAttemptAt,
  retryAttemptCount: retryAttemptCount,
  automaticRetryExhausted: automaticRetryExhausted,
  evaluatedAt: DateTime.utc(2026, 8, 15, 12),
);
