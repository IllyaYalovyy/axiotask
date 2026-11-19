// Selection subset of the Android behavior manifest (manifest.json).
//
// Case 06 failed the 2026-11-15 native audit of v1.5.6: long press entered
// selection, but the bulk toolbar overflowed the 443-wide phone by 250
// logical pixels, so Delete and the other trailing controls were
// unreachable. This contract drives the real shell over the isolated SQLite
// fixture by touch at 320, 360 and 443 logical-pixel phone widths, portrait
// and landscape, at 1x and 2x text. It measures every toolbar control's hit
// region by real hit tests, captures each layout, and executes every bulk
// action on several synthetic tasks, checking cancellation, the pending
// state, deletion Undo and the stored outcome in SQLite.
// Run through tool/android_regression/runner.dart.
import 'dart:async';

import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../test/support/selection_toolbar.dart';
import '../../test/support/touch_targets.dart';
import 'support/regression_harness.dart';

const _alpha = 'Bulk alpha';
const _beta = 'Bulk beta';
const _gamma = 'Bulk gamma';
const _delta = 'Bulk delta';
const _epsilon = 'Bulk epsilon';
const _zeta = 'Bulk zeta';

void main() {
  ensureRegressionBinding();

  regressionCase(
    '06_long_press_selection',
    phoneOnHost: true,
    seed: const RegressionSeed(
      extraTopLevelTitles: <String>[
        _alpha,
        _beta,
        _gamma,
        _delta,
        _epsilon,
        _zeta,
      ],
    ),
    _longPressSelection,
  );
}

Future<void> _longPressSelection(WidgetTester t, RegressionFixture f) async {
  final [alpha, beta, gamma, delta, epsilon, zeta] = f.extraTasks;
  final initial = await _stored(f);

  // Long press enters selection; every control stays reachable at each
  // phone size; Exit and system Back both leave it without a change.
  for (final (index, viewport) in selectionViewports.indexed) {
    await usePhoneViewport(t, viewport);
    expect(t.takeException(), isNull, reason: '$viewport list layout');
    await _longPressRow(t, 'Audit second task');
    expect(f.model.state.bulkSelectedTaskIds, {f.second});
    expectSelectionToolbarReachable(
      t,
      count: 1,
      reason: '$viewport after long press',
    );
    await _tapRow(t, 'Audit parent');
    expect(f.model.state.bulkSelectedTaskIds, {f.second, f.parent});
    expectSelectionToolbarReachable(
      t,
      count: 2,
      reason: '$viewport with two selected',
    );
    await f.capture(t, 'toolbar_${viewport.name}');
    if (index.isEven) {
      await tapSelectionControl(t, exitSelectionControl);
    } else {
      await t.binding.handlePopRoute();
    }
    await t.pumpAndSettle();
    expect(f.model.state.bulkSelectedTaskIds, isEmpty, reason: '$viewport');
    expect(find.byKey(const Key('bulk-action-bar')), findsNothing);
  }
  expect(await _stored(f), initial, reason: 'Exit and Back change nothing');

  // Complete: Cancel keeps the selection and the data; confirm completes
  // both tasks in SQLite.
  await usePhoneViewport(
    t,
    const PhoneViewport(320, PhoneOrientation.portrait, 1),
  );
  await _select(t, f, <String>[_alpha, _beta], {alpha, beta});
  await tapSelectionControl(t, completeSelectionControl);
  await t.pumpAndSettle();
  expect(find.text('Complete 2 tasks?'), findsOneWidget);
  await f.capture(t, 'complete_confirmation_320_portrait_1x');
  await t.tap(find.text('Cancel').hitTestable());
  await t.pumpAndSettle();
  expect(f.model.state.bulkSelectedTaskIds, {alpha, beta});
  expect(await _stored(f), initial, reason: 'Cancel completes nothing');
  await tapSelectionControl(t, completeSelectionControl);
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('bulk-complete-confirm')).hitTestable());
  await settleUntil(
    t,
    () async =>
        (await f.task(alpha)).status == TaskStatus.completed &&
        (await f.task(beta)).status == TaskStatus.completed,
    description: 'both selected tasks to be completed in SQLite',
  );
  expect(f.model.state.bulkSelectedTaskIds, isEmpty);
  expect(f.model.state.bulkCommandFailureMessage, isNull);
  expect(
    await _stored(f, except: {alpha, beta}),
    _without(initial, {alpha, beta}),
    reason: 'Complete changes only the selected tasks',
  );

  // Reschedule: system Back dismisses the dialog without a change;
  // Tomorrow then sets both due dates.
  await usePhoneViewport(
    t,
    const PhoneViewport(360, PhoneOrientation.landscape, 2),
  );
  await _select(t, f, <String>[_gamma, _delta], {gamma, delta});
  await tapSelectionControl(t, rescheduleSelectionControl);
  await t.pumpAndSettle();
  expect(find.byKey(const Key('bulk-reschedule-dialog')), findsOneWidget);
  await f.capture(t, 'reschedule_dialog_360_landscape_2x');
  await t.binding.handlePopRoute();
  await t.pumpAndSettle();
  expect(f.model.state.bulkSelectedTaskIds, {gamma, delta});
  expect((await f.task(gamma)).due, isNull);
  await tapSelectionControl(t, rescheduleSelectionControl);
  await t.pumpAndSettle();
  await t.ensureVisible(find.byKey(const Key('bulk-reschedule-tomorrow')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('bulk-reschedule-tomorrow')).hitTestable());
  final tomorrow = TaskDate(2026, 11, 16);
  await settleUntil(
    t,
    () async =>
        (await f.task(gamma)).due == tomorrow &&
        (await f.task(delta)).due == tomorrow,
    description: 'both selected tasks to be due tomorrow in SQLite',
  );
  expect(f.model.state.bulkSelectedTaskIds, isEmpty);

  // Move: Back dismisses the list choice; the destination then moves
  // both tasks, keeping their new dates.
  await usePhoneViewport(
    t,
    const PhoneViewport(443, PhoneOrientation.portrait, 2),
  );
  await _select(t, f, <String>[_gamma, _delta], {gamma, delta});
  await tapSelectionControl(t, moveSelectionControl);
  await t.pumpAndSettle();
  expect(find.byKey(const Key('bulk-move-dialog')), findsOneWidget);
  await f.capture(t, 'move_dialog_443_portrait_2x');
  await t.binding.handlePopRoute();
  await t.pumpAndSettle();
  expect((await f.task(gamma)).taskListId, f.list);
  await tapSelectionControl(t, moveSelectionControl);
  await t.pumpAndSettle();
  await t.tap(
    find.byKey(Key('bulk-move-list-${f.destination.value}')).hitTestable(),
  );
  await settleUntil(
    t,
    () async =>
        (await f.task(gamma)).taskListId == f.destination &&
        (await f.task(delta)).taskListId == f.destination,
    description: 'both selected tasks to move to the destination list',
  );
  for (final moved in <TaskId>[gamma, delta]) {
    expect((await f.task(moved)).due, tomorrow);
  }
  expect(f.model.state.bulkSelectedTaskIds, isEmpty);

  // Delete at the shortest viewport: Cancel deletes nothing; while the
  // command waits on SQLite every control is disabled; then Undo all
  // restores both tasks.
  await usePhoneViewport(
    t,
    const PhoneViewport(320, PhoneOrientation.landscape, 2),
  );
  await _select(t, f, <String>[_epsilon, _zeta], {epsilon, zeta});
  expectSelectionToolbarReachable(
    t,
    count: 2,
    reason: '320_landscape_2x after earlier bulk results',
  );
  await tapSelectionControl(t, deleteSelectionControl);
  await t.pumpAndSettle();
  expect(find.text('Delete 2 selected tasks?'), findsOneWidget);
  await f.capture(t, 'delete_confirmation_320_landscape_2x');
  await t.tap(find.text('Cancel').hitTestable());
  await t.pumpAndSettle();
  expect(await f.taskOrNull(epsilon), isNotNull);
  expect(await f.taskOrNull(zeta), isNotNull);
  expect(f.model.state.bulkSelectedTaskIds, {epsilon, zeta});

  // Hold SQLite in a transaction so the confirmed command stays pending.
  final held = Completer<void>();
  final release = Completer<void>();
  final transaction = f.database.transaction(() async {
    held.complete();
    await release.future;
  });
  await held.future;
  try {
    await tapSelectionControl(t, deleteSelectionControl);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bulk-delete-confirm')).hitTestable());
    // The progress indicator never settles; let the dialog close.
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(f.model.state.isBulkCommandPending, isTrue);
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('bulk-action-bar')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    await f.capture(t, 'delete_pending_320_landscape_2x', settle: false);
    for (final control in selectionControls) {
      final finder = selectionControlFinder(control);
      expect(
        t
            .getSemantics(finder)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse,
        reason: '${control.label} is disabled while the delete is pending',
      );
      await t.tapAt(t.getCenter(finder));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(Dialog), findsNothing, reason: control.label);
      expect(f.model.state.bulkSelectedTaskIds, {epsilon, zeta});
    }
  } finally {
    // Teardown closes the database, which would wait on a held lock.
    if (!release.isCompleted) release.complete();
    await transaction;
  }
  await settleUntil(
    t,
    () async =>
        await f.taskOrNull(epsilon) == null && await f.taskOrNull(zeta) == null,
    description: 'both selected tasks to be deleted locally',
  );
  expect(f.model.state.isBulkCommandPending, isFalse);
  expect(f.model.state.bulkSelectedTaskIds, isEmpty);
  expect(find.text('2 tasks deleted'), findsOneWidget);
  await f.capture(t, 'delete_undo_offer_320_landscape_2x');
  await t.ensureVisible(find.text('Undo all'));
  await t.pumpAndSettle();
  await t.tap(find.text('Undo all').hitTestable());
  await settleUntil(
    t,
    () async =>
        await f.taskOrNull(epsilon) != null && await f.taskOrNull(zeta) != null,
    description: 'Undo all to restore both tasks',
  );
  for (final (id, title) in <(TaskId, String)>[
    (epsilon, _epsilon),
    (zeta, _zeta),
  ]) {
    final restored = await f.task(id);
    expect(restored.title, title);
    expect(restored.taskListId, f.list);
    expect(restored.status, TaskStatus.needsAction);
  }
  expect(f.model.state.taskCommandFailureMessage, isNull);
  expect(f.model.state.bulkCommandFailureMessage, isNull);

  // Everything the bulk actions did not select is exactly as seeded.
  final touched = {alpha, beta, gamma, delta};
  expect(
    await _stored(f, except: touched),
    _without(initial, touched),
    reason: 'Bulk actions change only their selected tasks',
  );
}

/// Persisted fields of every task, by ID, read from SQLite.
Future<Map<TaskId, String>> _stored(
  RegressionFixture f, {
  Set<TaskId> except = const <TaskId>{},
}) async => <TaskId, String>{
  for (final task in await f.tasks())
    if (!except.contains(task.id))
      task.id:
          '${task.title}|${task.status}|${task.due}|${task.taskListId}|'
          '${task.parentTaskId}|${task.notes}',
};

Map<TaskId, String> _without(Map<TaskId, String> tasks, Set<TaskId> ids) =>
    <TaskId, String>{
      for (final entry in tasks.entries)
        if (!ids.contains(entry.key)) entry.key: entry.value,
    };

/// Long-presses the first title, taps the rest, and checks the selection.
Future<void> _select(
  WidgetTester t,
  RegressionFixture f,
  List<String> titles,
  Set<TaskId> expected,
) async {
  await _longPressRow(t, titles.first);
  for (final title in titles.skip(1)) {
    await _tapRow(t, title);
  }
  expect(f.model.state.bulkSelectedTaskIds, expected);
}

Future<void> _longPressRow(WidgetTester t, String title) async {
  await t.ensureVisible(find.text(title, skipOffstage: false));
  await t.pumpAndSettle();
  await t.longPress(find.text(title).hitTestable());
  await t.pumpAndSettle();
}

Future<void> _tapRow(WidgetTester t, String title) async {
  await t.ensureVisible(find.text(title, skipOffstage: false));
  await t.pumpAndSettle();
  await t.tap(find.text(title).hitTestable());
  await t.pumpAndSettle();
}
