import 'dart:async';

import 'package:axiotask/src/app/axiotask_app.dart';
import 'package:axiotask/src/app/visual_tokens.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/preferences_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/onboarding/onboarding_view.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'PAR-UX-001/002 onboarding explains truth without claiming sync',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: axiotaskTheme(Brightness.light, DensityPreference.standard),
          home: const OnboardingView(onDismiss: _dismiss),
        ),
      );

      expect(find.text('Connect to Google Tasks'), findsOneWidget);
      expect(find.text('Sync stays truthful'), findsOneWidget);
      expect(find.text('Work through an outage'), findsOneWidget);
      expect(find.text('Capture without breaking flow'), findsOneWidget);
      expect(find.text('Recover safely'), findsOneWidget);
      expect(
        find.textContaining('Connected does not mean synced'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Cached tasks stay available'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Welcome to Axiotask onboarding'),
        findsOneWidget,
      );
      expect(find.text('Synced'), findsNothing);
    },
  );

  testWidgets(
    'onboarding is readable at large text scale on narrow and wide layouts',
    (tester) async {
      for (final width in <double>[390, 1280]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                accessibleNavigation: true,
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: const OnboardingView(onDismiss: _dismiss),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull, reason: 'width $width');
        expect(find.byKey(const Key('onboarding-scroll')), findsOneWidget);
        expect(find.bySemanticsLabel('Finish onboarding'), findsOneWidget);
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );

  testWidgets('onboarding finish has keyboard and touch parity', (
    tester,
  ) async {
    var dismissed = 0;
    await tester.pumpWidget(
      MaterialApp(home: OnboardingView(onDismiss: () async => dismissed += 1)),
    );

    final finish = find.bySemanticsLabel('Finish onboarding');
    await tester.scrollUntilVisible(finish, 160);
    await tester.tap(finish);
    await tester.pump();
    expect(dismissed, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(dismissed, 2);
  });

  testWidgets(
    'failed dismissal write reveals the app without trapping semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final preferences = _FailingPreferences();
      final diagnostics = InMemoryDiagnosticHistory();
      final tasks = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: const _EmptyTasksRepository(),
        syncHealthRepository: const _InactiveHealthRepository(),
        diagnostics: ProductionDiagnosticSink(diagnostics),
      );
      addTearDown(tasks.dispose);

      await tester.pumpWidget(
        AxiotaskApp(viewModel: tasks, preferencesRepository: preferences),
      );
      await tester.pump();

      expect(find.bySemanticsLabel('Finish onboarding'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Axiotask')), findsNothing);

      final finish = find.text('Start using Axiotask').first;
      await tester.scrollUntilVisible(
        finish,
        160,
        scrollable: find.descendant(
          of: find.byKey(const Key('onboarding-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(finish);
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Finish onboarding'), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'^Axiotask')), findsWidgets);
      expect(find.textContaining('may appear again next time'), findsOneWidget);
      expect(preferences.current.onboardingDismissed, isFalse);
      expect(
        diagnostics.records.single.code,
        'onboarding.dismissal_write_failed',
      );

      await tester.tap(find.byTooltip('Keyboard shortcuts'));
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsWidgets);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}

Future<void> _dismiss() async {}

final class _FailingPreferences implements PreferencesRepository {
  final StreamController<DevicePreferences> _changes =
      StreamController<DevicePreferences>.broadcast();
  var current = const DevicePreferences.defaults();

  @override
  Stream<DevicePreferences> watchDevicePreferences() async* {
    yield current;
    yield* _changes.stream;
  }

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async =>
      const Outcome<void>.failure(_writeFailure);

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async =>
      const Outcome<void>.success(null);

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
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) => const Stream<Map<TaskListId, ListPreferences>>.empty();

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) => const Stream<Map<ViewKey, ViewPreferences>>.empty();

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
}

final class _EmptyTasksRepository implements TasksRepository {
  const _EmptyTasksRepository();

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async =>
      const Outcome<TaskId>.success(TaskId(2));

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async =>
      const Outcome<void>.success(null);

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => Stream.value(
    CachedTasksSnapshot(
      accountId: query.accountId,
      taskLists: const <CachedTaskList>[],
      tasks: const <CachedTask>[],
      completeness: CacheCompleteness.unobserved,
    ),
  );

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      const Stream<List<TaskDeleteUndo>>.empty();

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => const Stream<List<TaskDueChangeUndo>>.empty();

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async => const Outcome<TaskDueChangeReceipt>.success(
    TaskDueChangeReceipt(undo: null),
  );

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async => Outcome<TaskDeleteReceipt>.success(
    TaskDeleteReceipt(taskId: command.taskId, notBefore: DateTime.utc(2026)),
  );

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async => const Outcome<void>.success(null);
}

final class _InactiveHealthRepository implements SyncHealthRepository {
  const _InactiveHealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.noAuthorization,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 20),
    ),
  );
}

const Failure _writeFailure = Failure(
  code: 'synthetic.write_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'Synthetic preference failure.',
  safeSummary: 'Synthetic preference failure.',
);
