// Touch-gesture subset of the Android behavior manifest (manifest.json).
//
// Cases 02, 03 and 32 failed the 2026-11-15 native audit of v1.5.6: a touch
// swipe right on a task row no longer completed it, and a swipe left on a
// task row or on a subtask row in details no longer opened quick scheduling,
// unlike v1.5.3. These contracts drive the real shell by touch over the
// isolated file-backed SQLite fixture. They check the stored task state and
// the durable publication intent behind every changed task, that cancelled
// or short swipes and vertical scrolling change nothing, and that the shared
// completion and due-date policies (subtask cascade, due cascade and both
// Undo offers) apply exactly as for the buttons. Cases 34 and 35 also cover
// pull-to-refresh and task/subtask touch reordering. Run through
// tool/android_regression/runner.dart.
import 'dart:async';

import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../test/support/calendar_date.dart';
import 'support/regression_harness.dart';

/// Swipe travel used by the v1.5.6 audit for task rows and subtask rows.
const _rowSwipe = 130.0;
const _subtaskSwipe = 140.0;

/// Travel that clears touch slop (so the drag wins the arena) but stays short
/// of the action distance.
const _shortSwipe = 40.0;

final _today = TaskDate(2026, 11, 15);
final _tomorrow = TaskDate(2026, 11, 16);

void main() {
  ensureRegressionBinding();

  regressionCase(
    '35_touch_reorder',
    phoneOnHost: true,
    seed: const RegressionSeed(extraTopLevelTitles: ['Last sibling']),
    (t, f) async {
      Future<List<TaskId>> order() async => (await f.tasks())
          .where(
            (task) => task.parentTaskId == null && task.taskListId == f.list,
          )
          .map((task) => task.id)
          .toList();
      final initial = await order();
      await f.model.setViewSort(ViewSort.title);
      await t.pumpAndSettle();
      expect(find.byKey(Key('touch-reorder-${f.second.value}')), findsNothing);
      await f.model.setViewSort(ViewSort.manual);
      await t.pumpAndSettle();
      expect(find.byKey(Key('touch-reorder-${f.second.value}')), findsNothing);
      await t.tap(find.byTooltip('Collection actions'));
      await t.pumpAndSettle();
      await t.tap(find.text('Reorder tasks'));
      await t.pumpAndSettle();
      final handle = find.byKey(Key('touch-reorder-${f.second.value}'));
      await t.ensureVisible(handle);
      final cancelled = await t.startGesture(t.getCenter(handle));
      await t.pump(const Duration(milliseconds: 600));
      await cancelled.cancel();
      await t.pumpAndSettle();
      expect(await order(), initial, reason: 'cancelled drag changes no order');
      final target = t.getTopLeft(f.row(f.parent)) + const Offset(100, 8);
      final gesture = await t.startGesture(t.getCenter(handle));
      await t.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(target);
      await t.pump();
      await gesture.up();
      await settleUntil(
        t,
        () async => (await order()).first == f.second,
        description: 'touch reorder persisted',
      );
      final intent = await DesiredStateDao(f.database)
          .readTask(f.account, f.second);
      expect(intent?.structureDirty, isTrue);
      expect(f.model.state.isBulkSelectionActive, isFalse);
      expect((await f.task(f.second)).status, TaskStatus.needsAction);
      await f.capture(t, 'touch_reordered');
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(handle, findsNothing, reason: 'Back leaves reorder mode');
      expect(f.row(f.parent), findsOneWidget);
      await f.restartApp(t);
      expect((await order()).first, f.second);
      expect((await order()).toSet(), initial.toSet());
      await t.tap(find.byTooltip('Collection actions'));
      await t.pumpAndSettle();
      await t.tap(find.text('Reorder tasks'));
      await t.pumpAndSettle();

      // Move the first row to the end, then back to the middle. Verify the
      // repository order after each drop, not only the visual preview.
      final last = initial.last;
      for (final (targetId, after, expected) in [
        (last, true, [f.parent, last, f.second]),
        (last, false, [f.parent, f.second, last]),
      ]) {
        final source = find.byKey(Key('touch-reorder-${f.second.value}'));
        final targetRow = f.row(targetId);
        await t.ensureVisible(source);
        await t.ensureVisible(targetRow);
        final bounds = t.getRect(targetRow);
        final drag = await t.startGesture(t.getCenter(source));
        await t.pump(const Duration(milliseconds: 600));
        await drag.moveTo(
          Offset(bounds.left + 100, after ? bounds.bottom - 8 : bounds.top + 8),
        );
        await t.pump();
        expect(
          find.byKey(Key('desktop-task-drop-indicator-${targetId.value}')),
          findsOneWidget,
        );
        await drag.up();
        await settleUntil(
          t,
          () async => (await order()).join(',') == expected.join(','),
          description: 'first/last/middle sibling order persisted',
        );
      }
      await f.restartApp(t);
      expect(await order(), [f.parent, f.second, last]);

      // The tap alternative must visibly move a task and survive restart.
      Future<void> step(String action, List<TaskId> expected) async {
        await t.tap(
          find.descendant(
            of: f.row(f.second),
            matching: find.byTooltip('Task actions for Audit second task'),
          ),
        );
        await t.pumpAndSettle();
        await t.ensureVisible(find.text(action));
        await t.tap(find.text(action));
        await settleUntil(
          t,
          () async => (await order()).join(',') == expected.join(','),
          description: 'menu reorder committed',
        );
      }

      await step('Move up', [f.second, f.parent, last]);
      expect(await order(), [f.second, f.parent, last]);
      await f.restartApp(t);
      expect(await order(), [f.second, f.parent, last]);
      await step('Move down', [f.parent, f.second, last]);
      expect(await order(), [f.parent, f.second, last]);
      await f.model.setViewSort(ViewSort.title);
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: f.row(f.second),
          matching: find.byTooltip('Task actions for Audit second task'),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Move up'), findsNothing);
      expect(find.text('Move down'), findsNothing);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
    },
  );

  regressionCase(
    'subtask-touch-reorder',
    phoneOnHost: true,
    seed: const RegressionSeed(openChildTitles: ['Later child']),
    (t, f) async {
      await f.openParent(t);
      final source = f.openChildren.last;
      final handle = find.byKey(Key('touch-reorder-${source.value}'));
      await t.ensureVisible(handle);
      final targetFinder = find.byKey(Key('subtask-${f.child.value}'));
      await t.ensureVisible(targetFinder);
      final gesture = await t.startGesture(t.getCenter(handle));
      await t.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(t.getTopLeft(targetFinder) + const Offset(100, 4));
      await t.pump();
      await gesture.up();
      Future<bool> first() async =>
          (await f.tasks())
              .where((task) => task.parentTaskId == f.parent)
              .first
              .id ==
          source;
      await settleUntil(t, first, description: 'subtask order persisted');
      expect(
        (await DesiredStateDao(
          f.database,
        ).readTask(f.account, source))?.structureDirty,
        isTrue,
      );
      await f.capture(t, 'subtask_reordered');
      await f.restartApp(t);
      expect(await first(), isTrue);
      await f.openParent(t);
      final target = find.byKey(Key('subtask-${f.child.value}'));
      await t.ensureVisible(target);
      final drag = await t.startGesture(t.getCenter(handle));
      await t.pump(const Duration(milliseconds: 600));
      final bounds = t.getRect(target);
      await drag.moveTo(Offset(bounds.left + 100, bounds.bottom - 4));
      await t.pump();
      await drag.up();
      await settleUntil(
        t,
        () async => !await first(),
        description: 'subtask moved after sibling',
      );
      expect(
        (await f.tasks())
            .where((task) => task.parentTaskId == f.parent)
            .map((task) => task.id),
        [f.child, source],
      );
    },
  );

  regressionCase('34_pull_to_refresh', phoneOnHost: true, (t, f) async {
    final before = await _stored(f);
    final completion = Completer<void>();
    f.onRefresh = () => completion.future;
    final list = find.byKey(const Key('desktop-task-scroll'));
    try {
      await t.drag(list, const Offset(0, 300));
      for (var n = 0; n < 100 && f.refreshRequests == 0; n++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(f.refreshRequests, 1);
      expect(f.model.state.isRefreshing, isTrue);
      final duplicate = f.model.refresh();
      expect(
        f.refreshRequests,
        1,
        reason: 'toolbar and pull share one request',
      );
      await f.capture(t, 'refresh_pending', settle: false);
      completion.complete();
      await duplicate;
    } finally {
      if (!completion.isCompleted) completion.complete();
    }
    await t.pumpAndSettle();
    expect(f.model.state.isRefreshing, isFalse);
    expect(await _stored(f), before);

    final emptyList = await CacheDao(f.database).putTaskList(
      accountId: f.account,
      remoteId: const TaskListRemoteId('audit-empty-refresh'),
      title: 'Empty refresh list',
    );
    await settleUntil(
      t,
      () => f.model.state.taskLists.any((list) => list.id == emptyList),
      description: 'empty list to reach the model',
    );
    f.model.selectTaskList(emptyList);
    await t.pumpAndSettle();
    expect(find.text('No cached tasks in this list'), findsOneWidget);
    f.onRefresh = () async => throw StateError('synthetic offline');
    await t.drag(list, const Offset(0, 300));
    await settleUntil(
      t,
      () => f.refreshRequests == 2 && !f.model.state.isRefreshing,
      description: 'empty-list refresh failure to clear progress',
    );
    expect(f.model.state.syncControlFailureMessage, isNotNull);
    expect(await _stored(f), before, reason: 'failed refresh keeps local data');
    await f.capture(t, 'empty_refresh_failed');
  });

  regressionCase(
    '02_swipe_complete',
    phoneOnHost: true,
    seed: RegressionSeed(
      extraTopLevelTitles: <String>[
        for (var index = 1; index <= 14; index += 1) 'Audit filler $index',
      ],
    ),
    (t, f) async {
      final desired = DesiredStateDao(f.database);
      final initial = await _stored(f);

      // A swipe short of the action distance, even flung fast, changes
      // nothing and opens nothing.
      await t.drag(f.row(f.parent), const Offset(_shortSwipe, 0));
      await t.pumpAndSettle();
      await t.fling(f.row(f.parent), const Offset(_shortSwipe, 0), 3000);
      await t.pumpAndSettle();
      expect(await _stored(f), initial);
      expect(f.model.state.selectedTaskId, isNull, reason: 'not a row tap');
      expect(f.model.state.isBulkSelectionActive, isFalse);
      expect(find.byKey(const Key('task-completion-undo')), findsNothing);

      // A mostly vertical drag with horizontal drift past the action
      // distance scrolls the list and completes nothing.
      final list = t.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('desktop-task-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.drag(f.row(f.parent), const Offset(_rowSwipe, -300));
      await t.pumpAndSettle();
      expect(list.position.pixels, greaterThan(0), reason: 'the list scrolls');
      expect(await _stored(f), initial);
      expect(find.byKey(const Key('task-completion-undo')), findsNothing);
      list.position.jumpTo(0);
      await t.pumpAndSettle();

      // A full right swipe completes the row through the shared completion
      // command: its open subtask follows, nothing else changes.
      await t.drag(f.row(f.parent), const Offset(_rowSwipe, 0));
      await settleUntil(
        t,
        () async =>
            (await f.task(f.parent)).status == TaskStatus.completed &&
            (await f.task(f.child)).status == TaskStatus.completed,
        description: 'the swiped parent and its subtask completed in SQLite',
      );
      await _expectOnlyChanged(f, initial, <TaskId>{f.parent, f.child});
      for (final id in <TaskId>[f.parent, f.child]) {
        final intent = await desired.readTask(f.account, id);
        expect(intent?.status, TaskStatus.completed, reason: '$id intent');
        expect(intent?.state, DesiredStateLifecycle.pending, reason: '$id');
      }
      expect(await desired.readTask(f.account, f.second), isNull);
      await _expectCompletionUndo(t, '“Audit parent” and 1 subtask completed');
      await f.capture(t, 'swiped_complete');

      await t.tap(find.text('Undo').hitTestable());
      await settleUntil(
        t,
        () async =>
            (await f.task(f.parent)).status == TaskStatus.needsAction &&
            (await f.task(f.child)).status == TaskStatus.needsAction,
        description: 'Undo to reopen the swiped parent and its subtask',
      );
      expect(await _stored(f), initial);
      expect(find.byKey(const Key('task-completion-undo')), findsNothing);

      // Swiping another row completes exactly that row.
      await t.scrollUntilVisible(
        f.row(f.second),
        100,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('desktop-task-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.pumpAndSettle();
      expect(f.row(f.second).hitTestable(), findsOneWidget);
      await t.drag(f.row(f.second), const Offset(_rowSwipe, 0));
      await settleUntil(
        t,
        () async => (await f.task(f.second)).status == TaskStatus.completed,
        description: 'the swiped second task completed in SQLite',
      );
      await _expectOnlyChanged(f, initial, <TaskId>{f.second});
      await _expectCompletionUndo(t, '“Audit second task” completed');
    },
  );

  regressionCase('03_swipe_schedule', phoneOnHost: true, (t, f) async {
    final desired = DesiredStateDao(f.database);
    final initial = await _stored(f);

    // A short left swipe opens nothing.
    await t.drag(f.row(f.parent), const Offset(-_shortSwipe, 0));
    await t.pumpAndSettle();
    expect(_sheet, findsNothing);

    // A full left swipe opens quick scheduling for exactly the swiped row.
    await t.drag(f.row(f.parent), const Offset(-_rowSwipe, 0));
    await t.pumpAndSettle();
    _expectSheetFor('Audit parent');
    await f.capture(t, 'sheet_open');

    // Back and a tap outside the sheet both cancel without a side effect.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(_sheet, findsNothing);
    await t.drag(f.row(f.parent), const Offset(-_rowSwipe, 0));
    await t.pumpAndSettle();
    _expectSheetFor('Audit parent');
    await t.tapAt(const Offset(200, 120));
    await t.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(await _stored(f), initial);
    for (final id in initial.keys) {
      expect(await desired.readTask(f.account, id), isNull, reason: '$id');
    }

    // Tomorrow schedules only the swiped row.
    await _swipeSchedule(t, f.row(f.second), -_rowSwipe, 'Tomorrow');
    await settleUntil(
      t,
      () async => (await f.task(f.second)).due == _tomorrow,
      description: 'the swiped second task due tomorrow in SQLite',
    );
    await _expectOnlyChanged(f, initial, <TaskId>{f.second});
    final intent = await desired.readTask(f.account, f.second);
    expect(intent?.due, _tomorrow);
    expect(intent?.state, DesiredStateLifecycle.pending);
    expect(await desired.readTask(f.account, f.parent), isNull);

    // On a parent the shared due policy pushes its earlier-dated subtask
    // later, and the existing Undo in details restores both.
    await _swipeSchedule(t, f.row(f.parent), -_rowSwipe, 'Tomorrow');
    await settleUntil(
      t,
      () async =>
          (await f.task(f.parent)).due == _tomorrow &&
          (await f.task(f.child)).due == _tomorrow,
      description: 'the parent and its earlier subtask due tomorrow',
    );
    await f.capture(t, 'parent_cascade');
    await f.openParent(t);
    expect(find.text('Date changed for 2 related tasks'), findsOneWidget);
    await t.ensureVisible(find.text('Undo due changes'));
    await t.pumpAndSettle();
    await t.tap(find.text('Undo due changes'));
    await settleUntil(
      t,
      () async =>
          (await f.task(f.parent)).due == _today &&
          (await f.task(f.child)).due == TaskDate(2026, 11, 14),
      description: 'Undo due changes to restore the parent and subtask',
    );
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, isNull);

    // Clear date, Choose date and Today write the swiped row only.
    await _swipeSchedule(t, f.row(f.second), -_rowSwipe, 'Clear date');
    await settleUntil(
      t,
      () async => (await f.task(f.second)).due == null,
      description: 'the second task date cleared in SQLite',
    );
    await _swipeSchedule(t, f.row(f.second), -_rowSwipe, 'Choose date');
    await _chooseDate(t, TaskDate(2026, 12, 1));
    await settleUntil(
      t,
      () async => (await f.task(f.second)).due == TaskDate(2026, 12, 1),
      description: 'the chosen date stored for the second task',
    );
    await _swipeSchedule(t, f.row(f.second), -_rowSwipe, 'Today');
    await settleUntil(
      t,
      () async => (await f.task(f.second)).due == _today,
      description: 'the second task due today in SQLite',
    );
    await _expectOnlyChanged(f, initial, <TaskId>{f.second});
  });

  regressionCase(
    '32_subtask_swipe_schedule',
    phoneOnHost: true,
    seed: const RegressionSeed(openChildTitles: <String>['Audit sibling']),
    (t, f) async {
      final desired = DesiredStateDao(f.database);
      final sibling = f.openChildren.single;
      await f.openParent(t);
      final child = find.byKey(Key('subtask-${f.child.value}'));
      await t.ensureVisible(child);
      await t.pumpAndSettle();
      final initial = await _stored(f);

      // Short swipes and a cancelled sheet change nothing and stay on the
      // parent's details.
      await t.drag(child, const Offset(-_shortSwipe, 0));
      await t.drag(child, const Offset(_shortSwipe, 0));
      await t.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(find.byKey(const Key('task-completion-undo')), findsNothing);
      await t.drag(child, const Offset(-_subtaskSwipe, 0));
      await t.pumpAndSettle();
      _expectSheetFor('Audit child');
      await f.capture(t, 'sheet_open');
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(f.model.state.selectedTaskId, f.parent);
      expect(await _stored(f), initial);
      expect(await desired.readTask(f.account, f.child), isNull);

      // Tomorrow updates the swiped child, not its parent or sibling.
      await _swipeSchedule(t, child, -_subtaskSwipe, 'Tomorrow');
      await settleUntil(
        t,
        () async => (await f.task(f.child)).due == _tomorrow,
        description: 'the swiped subtask due tomorrow in SQLite',
      );
      await _expectOnlyChanged(f, initial, <TaskId>{f.child});
      expect((await f.task(f.parent)).due, _today);
      expect((await f.task(sibling)).due, isNull);
      final intent = await desired.readTask(f.account, f.child);
      expect(intent?.due, _tomorrow);
      expect(intent?.state, DesiredStateLifecycle.pending);
      for (final id in <TaskId>[f.parent, sibling, f.second]) {
        expect(await desired.readTask(f.account, id), isNull, reason: '$id');
      }
      expect(f.model.state.selectedTaskId, f.parent);
      await f.capture(t, 'child_scheduled');

      // Choose date on the sibling writes the sibling only.
      final siblingRow = find.byKey(Key('subtask-${sibling.value}'));
      await _swipeSchedule(t, siblingRow, -_subtaskSwipe, 'Choose date');
      await _chooseDate(t, TaskDate(2026, 11, 20));
      await settleUntil(
        t,
        () async => (await f.task(sibling)).due == TaskDate(2026, 11, 20),
        description: 'the chosen date stored for the sibling',
      );
      expect((await f.task(f.child)).due, _tomorrow);
      expect((await f.task(f.parent)).due, _today);

      // A child date earlier than its parent pulls the parent earlier by the
      // shared due policy, and the details Undo restores both.
      await _swipeSchedule(t, child, -_subtaskSwipe, 'Choose date');
      await _chooseDate(t, TaskDate(2026, 11, 10));
      await settleUntil(
        t,
        () async =>
            (await f.task(f.child)).due == TaskDate(2026, 11, 10) &&
            (await f.task(f.parent)).due == TaskDate(2026, 11, 10),
        description: 'the earlier child date to pull its parent earlier',
      );
      expect((await f.task(sibling)).due, TaskDate(2026, 11, 20));
      await t.ensureVisible(find.text('Undo due changes'));
      await t.pumpAndSettle();
      await t.tap(find.text('Undo due changes'));
      await settleUntil(
        t,
        () async =>
            (await f.task(f.child)).due == _tomorrow &&
            (await f.task(f.parent)).due == _today,
        description: 'Undo due changes to restore the child and parent',
      );

      // Clear date on the child clears the child only.
      await _swipeSchedule(t, child, -_subtaskSwipe, 'Clear date');
      await settleUntil(
        t,
        () async => (await f.task(f.child)).due == null,
        description: 'the child date cleared in SQLite',
      );
      expect((await f.task(f.parent)).due, _today);
      expect((await f.task(sibling)).due, TaskDate(2026, 11, 20));

      // A right swipe completes the child alone, with a usable Undo.
      await t.ensureVisible(child);
      await t.pumpAndSettle();
      await t.drag(child, const Offset(_subtaskSwipe, 0));
      await settleUntil(
        t,
        () async => (await f.task(f.child)).status == TaskStatus.completed,
        description: 'the swiped subtask completed in SQLite',
      );
      expect((await f.task(f.parent)).status, TaskStatus.needsAction);
      expect((await f.task(sibling)).status, TaskStatus.needsAction);
      expect((await f.task(f.second)).status, TaskStatus.needsAction);
      await _expectCompletionUndo(t, '“Audit child” completed');
      await f.capture(t, 'child_completed');
      await t.tap(find.text('Undo').hitTestable());
      await settleUntil(
        t,
        () async => (await f.task(f.child)).status == TaskStatus.needsAction,
        description: 'Undo to reopen the swiped subtask',
      );
      expect(f.model.state.selectedTaskId, f.parent);
    },
  );
}

final _sheet = find.byKey(const Key('quick-date-sheet'));

const _sheetOptions = <String>[
  'Today',
  'Tomorrow',
  'Next week',
  'Next month',
  'Choose date',
  'Clear date',
];

/// Stored status and due date of every task, read from SQLite.
Future<Map<TaskId, (TaskStatus, TaskDate?)>> _stored(
  RegressionFixture f,
) async => <TaskId, (TaskStatus, TaskDate?)>{
  for (final task in await f.tasks()) task.id: (task.status, task.due),
};

Future<void> _expectOnlyChanged(
  RegressionFixture f,
  Map<TaskId, (TaskStatus, TaskDate?)> initial,
  Set<TaskId> changed,
) async {
  final now = await _stored(f);
  expect(now.keys.toSet(), initial.keys.toSet());
  for (final id in initial.keys) {
    if (changed.contains(id)) {
      expect(now[id], isNot(initial[id]), reason: '$id should change');
    } else {
      expect(now[id], initial[id], reason: '$id must not change');
    }
  }
}

void _expectSheetFor(String title) {
  expect(_sheet, findsOneWidget, reason: 'quick scheduling is open');
  expect(
    find.descendant(of: _sheet, matching: find.text('Schedule “$title”')),
    findsOneWidget,
    reason: 'the sheet names the swiped task',
  );
  for (final label in _sheetOptions) {
    expect(
      find.descendant(of: _sheet, matching: find.text(label)).hitTestable(),
      findsOneWidget,
      reason: '$label is reachable',
    );
  }
}

Future<void> _swipeSchedule(
  WidgetTester t,
  Finder row,
  double dx,
  String option,
) async {
  await t.ensureVisible(row);
  await t.pumpAndSettle();
  await t.drag(row, Offset(dx, 0));
  await t.pumpAndSettle();
  expect(_sheet, findsOneWidget);
  await t.tap(find.descendant(of: _sheet, matching: find.text(option)));
  await t.pumpAndSettle();
  expect(_sheet, findsNothing);
}

/// Chooses [date] in the calendar that Choose date opens. Every caller's row
/// is undated or dated this month, so the calendar opens on the audit month.
Future<void> _chooseDate(WidgetTester t, TaskDate date) async {
  expect(
    calendarPicker,
    findsOneWidget,
    reason: 'Choose date opens the calendar',
  );
  await navigateCalendar(
    t,
    from: (_today.year, _today.month),
    to: (date.year, date.month),
  );
  await tapCalendarDay(t, date.day);
  expect(t.widget<Text>(calendarSelection).data, calendarSelectionLabel(date));
  await tapCalendarAction(t, calendarSet);
  // The dialog closes once the due change has committed to SQLite, which
  // can outlast one settle on a slow device.
  await settleUntil(
    t,
    () => calendarDialog.evaluate().isEmpty,
    description: 'the calendar to close after its save',
  );
}

Future<void> _expectCompletionUndo(WidgetTester t, String message) async {
  final banner = find.byKey(const Key('task-completion-undo'));
  // The offer is made when the command returns, which can trail the stored
  // change observed in SQLite.
  await settleUntil(
    t,
    () => banner.evaluate().isNotEmpty,
    description: 'the completion Undo offer',
  );
  expect(banner, findsOneWidget, reason: 'completion feedback is shown');
  expect(
    find.descendant(of: banner, matching: find.text(message)),
    findsOneWidget,
  );
  expect(
    find.text('Undo').hitTestable(),
    findsOneWidget,
    reason: 'an accidental swipe must be reversible',
  );
}
