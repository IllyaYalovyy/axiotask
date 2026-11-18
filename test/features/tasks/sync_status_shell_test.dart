// The phone shell's sync status (Android audit 18 and the tracked finding
// `failure-message-usability`): a routine queued edit stays a compact header
// control that leaves the task list in place, and each recovery action in a
// failure banner reaches its own coordinator port through the view model,
// once, with the banner following what the coordinator then reports.
import 'dart:async';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/touch_targets.dart';

void main() {
  setUpAll(loadAndroidTextFont);
  final now = DateTime.utc(2026, 8, 15, 12);

  for (final width in <double>[320, 360]) {
    for (final scale in <double>[1, 2]) {
      testWidgets('a queued edit keeps the phone list in place at $width, '
          '${scale}x', (tester) async {
        final shell = _Shell(tester, width: width, textScale: scale);
        addTearDown(shell.dispose);
        await shell.pump(_good(now));
        final rowTop = tester.getTopLeft(find.text(_firstTask));
        expect(find.byKey(const Key('sync-health-good')), findsOneWidget);

        await shell.emit(_queuedEdit(now));
        expect(tester.takeException(), isNull);
        expect(shell.model.state.health.counts.pending, 1);
        expect(find.byKey(const Key('sync-health-banner')), findsNothing);
        expect(find.textContaining('Pending'), findsNothing);
        expect(find.text('Synced'), findsNothing);
        final status = find.byKey(const Key('sync-health-pending'));
        expectTouchTarget(
          tester,
          status,
          label: '1 change saved on this device, not yet on Google.',
        );
        expect(tester.getTopLeft(find.text(_firstTask)), rowTop);

        await tester.tap(status);
        await tester.pumpAndSettle();
        expect(find.text('Pending: Changes awaiting Google'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();

        // A failure expands without hiding the list; recovery collapses it.
        await shell.emit(_unknownFailure(now));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('sync-health-banner')), findsOneWidget);
        expect(find.text(_firstTask).hitTestable(), findsOneWidget);
        await shell.emit(_good(now));
        expect(find.byKey(const Key('sync-health-banner')), findsNothing);
        expect(tester.getTopLeft(find.text(_firstTask)), rowTop);
      });
    }
  }

  for (final width in <double>[320, 360]) {
    for (final scale in <double>[1, 2]) {
      testWidgets('the run that publishes a queued edit stays compact at '
          '$width, ${scale}x', (tester) async {
        final shell = _Shell(tester, width: width, textScale: scale);
        addTearDown(shell.dispose);
        await shell.pump(_good(now));
        final rowTop = tester.getTopLeft(find.text(_firstTask));

        // Queued, then verified with Google while sent, then confirmed.
        for (final (phase, health) in <(String, SyncHealth)>[
          ('queued', _queuedEdit(now)),
          ('verifying, pending', _verifying(now, pending: 1)),
          ('verifying, in flight', _verifying(now, inFlight: 1)),
        ]) {
          await shell.emit(health);
          expect(tester.takeException(), isNull, reason: phase);
          expect(
            find.byKey(const Key('sync-health-banner')),
            findsNothing,
            reason: phase,
          );
          expect(find.textContaining('Pending'), findsNothing, reason: phase);
          expect(find.text('Synced'), findsNothing, reason: phase);
          final status = find.byKey(const Key('sync-health-pending'));
          expect(
            find.descendant(of: status, matching: find.text('1')),
            findsOneWidget,
            reason: '$phase shows the waiting count',
          );
          expectTouchTarget(
            tester,
            status,
            label: '1 change saved on this device, not yet on Google.',
          );
          expect(
            tester.getTopLeft(find.text(_firstTask)),
            rowTop,
            reason: phase,
          );
        }
        await shell.emit(_good(now));
        expect(find.byKey(const Key('sync-health-good')), findsOneWidget);
        expect(find.byKey(const Key('sync-health-pending')), findsNothing);
        expect(tester.getTopLeft(find.text(_firstTask)), rowTop);
      });
    }
  }

  testWidgets('each recovery action reaches its own coordinator port once', (
    tester,
  ) async {
    final shell = _Shell(tester, width: 360, textScale: 1);
    addTearDown(shell.dispose);
    await shell.pump(_unknownFailure(now));
    final cases = <(SyncHealth, String, String)>[
      (_unknownFailure(now), 'Retry', 'retry'),
      (
        _inactive(now, SyncInactiveReason.syncStopped, SyncHealthAction.resume),
        'Resume',
        'resume',
      ),
      (
        _inactive(
          now,
          SyncInactiveReason.noAuthorization,
          SyncHealthAction.reauthorize,
        ),
        'Reauthorize',
        'reauthorize',
      ),
      (
        _inactive(
          now,
          SyncInactiveReason.noAuthorization,
          SyncHealthAction.connect,
        ),
        'Connect',
        'connect',
      ),
    ];
    for (final (health, label, port) in cases) {
      shell.calls.clear();
      await shell.emit(health);
      final action = find.byKey(const Key('sync-health-action'));
      expectTouchTarget(tester, action, label: label);

      final gate = Completer<void>();
      shell.gate = gate;
      await tester.tap(action);
      await tester.pump();
      expect(shell.calls, <String>[port], reason: label);
      expect(shell.model.state.isSyncControlPending, isTrue, reason: label);
      // A second tap while the coordinator works issues nothing.
      await tester.tap(action, warnIfMissed: false);
      await tester.pump();
      expect(shell.calls, <String>[port], reason: label);

      gate.complete();
      await tester.pumpAndSettle();
      expect(shell.model.state.isSyncControlPending, isFalse, reason: label);
      await shell.emit(_retrying(now));
      expect(find.text('Pending · Retrying synchronization'), findsOneWidget);
      expect(find.text(label), findsNothing, reason: label);
    }
  });
}

const _firstTask = 'Synthetic first task';

final class _Shell {
  _Shell(this.tester, {required double width, required double textScale}) {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    model = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: const _TasksRepository(),
      syncHealthRepository: _health,
      refreshRequested: () async {},
      retryRequested: () => _call('retry'),
      resumeSyncRequested: () => _call('resume'),
      reauthorizeRequested: () => _call('reauthorize'),
      connectRequested: () async {
        await _call('connect');
        return const Outcome<void>.success(null);
      },
    );
  }

  final WidgetTester tester;
  final _health = _HealthRepository();
  late final TasksViewModel model;
  final calls = <String>[];
  Completer<void>? gate;

  Future<void> _call(String port) async {
    calls.add(port);
    await gate?.future;
  }

  Future<void> pump(SyncHealth initial) async {
    _health.current = initial;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          fontFamily: androidTextFontFamily,
        ),
        home: AdaptiveShell(viewModel: model),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> emit(SyncHealth health) async {
    _health.emit(health);
    await tester.pumpAndSettle();
  }

  void dispose() {
    model.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }
}

SyncHealth _good(DateTime now) => SyncHealth(
  outcome: SyncHealthOutcome.good,
  counts: const SyncWorkCounts(),
  lastSuccessfulSyncAt: now.subtract(const Duration(seconds: 30)),
  evaluatedAt: now,
);

SyncHealth _queuedEdit(DateTime now) => SyncHealth(
  outcome: SyncHealthOutcome.pending,
  pendingReason: SyncPendingReason.localChanges,
  counts: const SyncWorkCounts(pending: 1),
  lastSuccessfulSyncAt: now.subtract(const Duration(seconds: 30)),
  evaluatedAt: now,
);

SyncHealth _verifying(DateTime now, {int pending = 0, int inFlight = 0}) =>
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
      counts: SyncWorkCounts(pending: pending, inFlight: inFlight),
      lastSuccessfulSyncAt: now.subtract(const Duration(seconds: 30)),
      evaluatedAt: now,
    );

SyncHealth _unknownFailure(DateTime now) => SyncHealth(
  outcome: SyncHealthOutcome.failed,
  failureReason: SyncFailureReason.applicationFailure,
  action: SyncHealthAction.retry,
  diagnosticCode: 'synthetic.unclassified',
  counts: const SyncWorkCounts(failed: 1),
  lastSuccessfulSyncAt: now.subtract(const Duration(minutes: 2)),
  evaluatedAt: now,
);

SyncHealth _retrying(DateTime now) => SyncHealth(
  outcome: SyncHealthOutcome.pending,
  pendingReason: SyncPendingReason.retrying,
  counts: const SyncWorkCounts(pending: 1),
  lastSuccessfulSyncAt: now.subtract(const Duration(minutes: 2)),
  evaluatedAt: now,
);

SyncHealth _inactive(
  DateTime now,
  SyncInactiveReason reason,
  SyncHealthAction action,
) => SyncHealth(
  outcome: SyncHealthOutcome.inactive,
  inactiveReason: reason,
  action: action,
  counts: const SyncWorkCounts(pending: 1),
  lastSuccessfulSyncAt: now.subtract(const Duration(minutes: 2)),
  evaluatedAt: now,
);

final class _HealthRepository implements SyncHealthRepository {
  final _changes = StreamController<SyncHealth>.broadcast();
  late SyncHealth current;

  void emit(SyncHealth health) {
    current = health;
    _changes.add(health);
  }

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) async* {
    yield current;
    yield* _changes.stream;
  }
}

final class _TasksRepository implements TasksRepository {
  const _TasksRepository();

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
      ],
      tasks: const <CachedTask>[
        CachedTask(
          id: TaskId(11),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: null,
          remoteId: TaskRemoteId('synthetic-first'),
          title: _firstTask,
          notes: null,
          status: TaskStatus.needsAction,
          due: null,
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
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async =>
      const Outcome<TaskId>.success(TaskId(900));

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async =>
      const Outcome<void>.success(null);

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
