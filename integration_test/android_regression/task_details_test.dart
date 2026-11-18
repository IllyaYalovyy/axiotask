// Task-details subset of the Android behavior manifest (manifest.json).
//
// Case 09 failed the 2026-11-15 native audit of v1.5.6: Change due date →
// Choose date opened a YYYY-MM-DD text field instead of the v1.5.3 calendar.
// This contract drives the real shell by touch over the isolated file-backed
// SQLite fixture. The calendar must open on the stored date, navigate by
// month and year, and change nothing on Cancel, Back or a tap outside. Set
// date and Clear date must store exactly the chosen value through the shared
// due command, so the parent/subtask cascade and its Undo apply, and the
// durable publication intent must carry the date. A subtask's later date
// changes only the subtask at narrow, landscape and 2x-text phone shapes.
//
// Case 11 failed the same audit: details showed read-only title and notes,
// so editing needed the separate Edit dialog and Save. Its contract edits
// the title and multiline notes in place by touch and proves, from SQLite and
// the durable publication intent, that the text is stored on a focus change,
// on Back, when opening another task and after the typing debounce; that
// reopening the task shows the stored text; and that an empty title is
// rejected while the notes still save.
// Cases 14 and 23 share this file's manifest path and stay outstanding.
// Run through tool/android_regression/runner.dart.
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/task_content_autosave.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../test/support/calendar_date.dart';
import '../../test/support/touch_targets.dart';
import 'support/regression_harness.dart';

final _parentDue = TaskDate(2026, 11, 15);
final _childDue = TaskDate(2026, 11, 14);

/// Phone shapes the calendar must stay usable at: the narrowest width,
/// landscape, and 2x text.
const _calendarViewports = <PhoneViewport>[
  PhoneViewport(320, PhoneOrientation.portrait, 1),
  PhoneViewport(320, PhoneOrientation.portrait, 2),
  PhoneViewport(360, PhoneOrientation.landscape, 1),
  PhoneViewport(360, PhoneOrientation.landscape, 2),
  PhoneViewport(443, PhoneOrientation.landscape, 2),
];

void main() {
  ensureRegressionBinding();

  regressionCase('09_date_calendar', phoneOnHost: true, (t, f) async {
    final desired = DesiredStateDao(f.database);
    final initial = await _dates(f);
    expect(initial[f.parent], _parentDue);
    expect(initial[f.child], _childDue, reason: 'an earlier-due child');

    // Choose date opens the calendar on the stored date.
    await f.openParent(t);
    await _openCalendar(t);
    await f.capture(t, 'date_picker');
    expect(
      find.byType(CalendarDatePicker),
      findsOneWidget,
      reason: 'Phone date selection should provide the existing calendar',
    );
    expectCalendarState(t, year: 2026, month: 11, selected: _parentDue);

    // Month and year navigation and a tapped day only change the pending
    // selection; Cancel, Back and a tap outside store nothing.
    await navigateCalendar(t, from: (2026, 11), to: (2027, 1));
    await navigateCalendar(t, from: (2027, 1), to: (2026, 12));
    await tapCalendarDay(t, 31);
    expectCalendarState(
      t,
      year: 2026,
      month: 12,
      selected: TaskDate(2026, 12, 31),
    );
    await f.capture(t, 'pending_selection');
    await tapCalendarAction(t, calendarCancel);
    await t.pumpAndSettle();
    expect(calendarDialog, findsNothing, reason: 'Cancel closes');
    await _openCalendar(t);
    expectCalendarState(t, year: 2026, month: 11, selected: _parentDue);
    await tapCalendarDay(t, 20);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(calendarDialog, findsNothing, reason: 'Back closes');
    await _openCalendar(t);
    await tapCalendarDay(t, 21);
    await t.tapAt(const Offset(4, 4));
    await t.pumpAndSettle();
    expect(calendarDialog, findsNothing, reason: 'a tap outside closes');
    expect(await _dates(f), initial, reason: 'cancelling stored nothing');
    for (final id in initial.keys) {
      expect(await desired.readTask(f.account, id), isNull, reason: '$id');
    }
    expect(f.model.state.selectedTaskId, f.parent);

    // A later parent date across a year boundary onto a leap day pushes the
    // earlier-due child with it; the details Undo restores both.
    final leapDay = TaskDate(2028, 2, 29);
    await _openCalendar(t);
    await navigateCalendar(t, from: (2026, 11), to: (2028, 2));
    await tapCalendarDay(t, 29);
    expectCalendarState(t, year: 2028, month: 2, selected: leapDay);
    await _commit(t);
    await settleUntil(
      t,
      () async => (await f.task(f.parent)).due == leapDay,
      description: 'the leap-day parent date stored in SQLite',
    );
    expect(f.model.state.taskCommandFailureMessage, isNull);
    expect(
      (await f.task(f.child)).due,
      leapDay,
      reason: 'a later parent date pushes its earlier-due child',
    );
    for (final id in <TaskId>[f.parent, f.child]) {
      final intent = await desired.readTask(f.account, id);
      expect(intent?.due, leapDay, reason: '$id intent');
      expect(intent?.state, DesiredStateLifecycle.pending, reason: '$id');
    }
    expect(await desired.readTask(f.account, f.second), isNull);
    expect(find.text('Date changed for 2 related tasks'), findsOneWidget);
    await f.capture(t, 'cascade_undo_offer');
    await t.ensureVisible(find.text('Undo due changes'));
    await t.pumpAndSettle();
    await t.tap(find.text('Undo due changes'));
    await settleUntil(
      t,
      () async =>
          (await f.task(f.parent)).due == _parentDue &&
          (await f.task(f.child)).due == _childDue,
      description: 'Undo to restore the parent and child dates',
    );
    expect(f.model.state.taskCommandFailureMessage, isNull);

    // A subtask date later than its parent changes only the subtask, at
    // every phone shape; the calendar opens on the subtask's own date.
    await t.ensureVisible(find.text('Audit child'));
    await t.pumpAndSettle();
    await t.tap(find.text('Audit child'));
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, f.child);
    final parentIntent = await desired.readTask(f.account, f.parent);
    var childDue = _childDue;
    for (final (index, viewport) in _calendarViewports.indexed) {
      await usePhoneViewport(t, viewport);
      expect(f.model.state.selectedTaskId, f.child, reason: '$viewport');
      await _openCalendar(t);
      expectCalendarState(t, year: 2026, month: 11, selected: childDue);
      _expectCalendarFits(t, viewport);
      final target = TaskDate(2026, 11, 16 + index);
      await tapCalendarDay(t, target.day);
      expectCalendarState(t, year: 2026, month: 11, selected: target);
      await f.capture(t, 'child_${viewport.name}');
      await _commit(t);
      await settleUntil(
        t,
        () async => (await f.task(f.child)).due == target,
        description: 'the child-only date at $viewport',
      );
      childDue = target;
      expect((await f.task(f.parent)).due, _parentDue, reason: '$viewport');
      final intent = await desired.readTask(f.account, f.parent);
      expect(intent?.due, parentIntent?.due, reason: 'parent intent unchanged');
      expect(intent?.generation, parentIntent?.generation);
      expect((await desired.readTask(f.account, f.child))?.due, target);
      expect(find.text('Date changed for 2 related tasks'), findsNothing);
      expect(t.takeException(), isNull, reason: '$viewport');
    }
    await usePhoneViewport(
      t,
      const PhoneViewport(360, PhoneOrientation.portrait, 1),
    );

    // An earlier subtask date pulls the parent back to it; Undo restores
    // the parent and the subtask's previous date.
    final earlier = TaskDate(2026, 11, 10);
    await _openCalendar(t);
    await tapCalendarDay(t, earlier.day);
    await _commit(t);
    await settleUntil(
      t,
      () async =>
          (await f.task(f.child)).due == earlier &&
          (await f.task(f.parent)).due == earlier,
      description: 'the earlier child date to pull its parent earlier',
    );
    expect(find.text('Date changed for 2 related tasks'), findsOneWidget);
    await t.ensureVisible(find.text('Undo due changes'));
    await t.pumpAndSettle();
    await t.tap(find.text('Undo due changes'));
    await settleUntil(
      t,
      () async =>
          (await f.task(f.parent)).due == _parentDue &&
          (await f.task(f.child)).due == childDue,
      description: 'Undo to restore the parent and the child-only date',
    );

    // Clear date stores no date for the parent and keeps the child's.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, f.parent);
    await _openCalendar(t);
    await tapCalendarAction(t, calendarClear);
    await settleUntil(
      t,
      () async => (await f.task(f.parent)).due == null,
      description: 'the cleared parent date stored in SQLite',
    );
    await settleUntil(
      t,
      () => calendarDialog.evaluate().isEmpty,
      description: 'the calendar to close after Clear date',
    );
    expect((await f.task(f.child)).due, childDue);
    final cleared = await desired.readTask(f.account, f.parent);
    expect(cleared?.due, isNull);
    expect(cleared?.state, DesiredStateLifecycle.pending);
    expect(f.model.state.taskCommandFailureMessage, isNull);
  });

  regressionCase('11_inline_detail_edit', phoneOnHost: true, (t, f) async {
    final desired = DesiredStateDao(f.database);
    final title = find.byKey(const Key('task-detail-title'));
    final notes = find.byKey(const Key('task-detail-notes'));
    final parentBefore = await f.task(f.parent);

    await f.openParent(t);
    expect(
      find.byType(TextField),
      findsWidgets,
      reason: 'v1.5.3 title and notes are editable directly with autosave',
    );
    expect(find.widgetWithText(TextField, 'Audit parent'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Audit notes https://example.com'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
    expect(find.text('Changes save automatically'), findsOneWidget);
    await f.capture(t, 'inline_fields');

    // Title by touch; tapping the notes field moves focus and stores it.
    await t.tap(title);
    await t.pump();
    await t.enterText(title, 'Inline parent title');
    await t.pump();
    expect((await f.task(f.parent)).title, 'Audit parent');
    await t.tap(notes);
    await settleUntil(
      t,
      () async => (await f.task(f.parent)).title == 'Inline parent title',
      description: 'the title to store when focus moves to the notes',
    );

    // Multiline notes, then Android Back while the save is still pending.
    await t.enterText(notes, 'First inline line\nSecond inline line');
    await t.pump();
    await f.capture(t, 'editing_notes', settle: false);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, isNull, reason: 'Back left details');
    await settleUntil(
      t,
      () async =>
          (await f.task(f.parent)).notes ==
          'First inline line\nSecond inline line',
      description: 'the notes to store on Back',
    );
    final stored = await f.task(f.parent);
    expect(stored.status, parentBefore.status);
    expect(stored.due, parentBefore.due, reason: 'text saves keep the date');
    final intent = await desired.readTask(f.account, f.parent);
    expect(intent?.title, 'Inline parent title');
    expect(intent?.notes, 'First inline line\nSecond inline line');
    expect(intent?.state, DesiredStateLifecycle.pending);
    expect(f.model.contentAutosave.hasUnsavedChanges, isFalse);

    // Navigating back shows the stored text in the fields.
    await t.tap(find.text('Inline parent title'));
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, f.parent);
    expect(
      find.widgetWithText(TextField, 'Inline parent title'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextField, 'First inline line\nSecond inline line'),
      findsOneWidget,
    );

    // Opening a subtask mid-edit stores the parent's text for the parent
    // only; Back returns to the parent showing it.
    await t.tap(title);
    await t.pump();
    await t.enterText(title, 'Parent renamed before switching');
    await t.pump();
    await t.ensureVisible(find.text('Audit child'));
    await t.pumpAndSettle();
    await t.tap(find.text('Audit child'));
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, f.child);
    expect(find.widgetWithText(TextField, 'Audit child'), findsOneWidget);
    await settleUntil(
      t,
      () async =>
          (await f.task(f.parent)).title == 'Parent renamed before switching',
      description: 'the parent title to store when a subtask opens',
    );
    expect((await f.task(f.child)).title, 'Audit child');

    // Rapid typing in the subtask stores once typing pauses, without
    // leaving the details.
    await t.tap(notes);
    await t.pump();
    for (final text in <String>['C', 'Ch', 'Chi', 'Child notes']) {
      await t.enterText(notes, text);
      await t.pump();
    }
    expect((await f.task(f.child)).notes, isNull, reason: 'still typing');
    f.clock.advance(TaskContentAutosave.defaultDebounce);
    await settleUntil(
      t,
      () async => (await f.task(f.child)).notes == 'Child notes',
      description: 'the subtask notes to store after the typing pause',
    );
    expect(f.model.state.selectedTaskId, f.child);

    // An empty title is rejected with guidance; the notes still save.
    await t.tap(title);
    await t.pump();
    await t.enterText(title, '');
    await t.pump();
    expect(
      find.text('Enter a title. The saved title stays until you do.'),
      findsOneWidget,
    );
    await f.capture(t, 'empty_title_rejected');
    await t.tap(notes);
    await t.pump();
    await t.enterText(notes, 'Notes kept without a title');
    await t.pump();
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, f.parent, reason: 'Back to parent');
    expect(
      find.widgetWithText(TextField, 'Parent renamed before switching'),
      findsOneWidget,
    );
    await settleUntil(
      t,
      () async => (await f.task(f.child)).notes == 'Notes kept without a title',
      description: 'the subtask notes to store despite the empty title',
    );
    expect((await f.task(f.child)).title, 'Audit child');
    expect(
      (await desired.readTask(f.account, f.child))?.title,
      'Audit child',
      reason: 'the empty title never reached the publication intent',
    );
    await t.ensureVisible(find.text('Audit child'));
    await t.pumpAndSettle();
    await t.tap(find.text('Audit child'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Audit child'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Notes kept without a title'),
      findsOneWidget,
    );
    expect(f.model.contentAutosave.hasUnsavedChanges, isFalse);
  });
}

Future<Map<TaskId, TaskDate?>> _dates(RegressionFixture f) async => {
  for (final task in await f.tasks()) task.id: task.due,
};

Future<void> _openCalendar(WidgetTester t) async {
  final due = find.byKey(const Key('task-detail-due-action'));
  await t.ensureVisible(due);
  await t.pumpAndSettle();
  await t.tap(due);
  await t.pumpAndSettle();
  await t.tap(find.text('Choose date').hitTestable());
  await t.pumpAndSettle();
  expect(calendarDialog, findsOneWidget, reason: 'Choose date is reachable');
  expect(
    find.widgetWithText(TextField, 'Due date (YYYY-MM-DD)'),
    findsNothing,
    reason: 'phones choose from the calendar, not a typed date',
  );
}

/// Taps Set date and waits for the dialog to close after its save, which
/// can outlast one settle on a slow device.
Future<void> _commit(WidgetTester t) async {
  await tapCalendarAction(t, calendarSet);
  await settleUntil(
    t,
    () => calendarDialog.evaluate().isEmpty,
    description: 'the calendar to close after Set date',
  );
}

/// The dialog lies on screen and its actions keep 48 dp touch targets.
void _expectCalendarFits(WidgetTester t, PhoneViewport viewport) {
  final dialog = t.getRect(calendarDialog);
  final screen = Offset.zero & viewport.logicalSize;
  expect(
    screen.contains(dialog.topLeft) &&
        screen.contains(dialog.bottomRight - const Offset(1, 1)),
    isTrue,
    reason: 'the calendar fits the $viewport screen: $dialog',
  );
  for (final (action, label) in <(Finder, String)>[
    (calendarCancel, 'Cancel'),
    (calendarSet, 'Set date'),
    (calendarClear, 'Clear date'),
  ]) {
    expect(action.hitTestable(), findsOneWidget, reason: '$label $viewport');
    expectTouchTarget(t, action, label: label);
  }
}
