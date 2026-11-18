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
// Case 23 failed the same audit: details had no Previous/Next controls.
// Its contract steps through the visible list by touch in manual and title
// order, proves the controls disable at both boundaries and in a one-task
// list, that a subtask steps through its siblings and Backs to its parent,
// that completing the open task (hidden by the completed filter) still leads
// to the task after it, and, from SQLite and the publication intents, that an
// unsaved inline edit is stored on its own task before the next one opens.
// Case 14 failed the same audit: the details actions menu had no Duplicate.
// Its contract opens the menu by touch and selects Duplicate on a subtask and
// on its parent. Each copy must follow the v1.5.3 rule ("<title> (copy)", the
// same list and parent, no notes, no date, open, no subtasks), get a new
// local ID with no Google ID and a pending create intent, and leave every
// source row, remote base and ETag unchanged. After the app is restarted over
// the same SQLite file the copies and their hierarchy must still be there, in
// SQLite and on screen.
// Run through tool/android_regression/runner.dart.
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/task_content_autosave.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/rendering.dart' show SemanticsAction;
import 'package:flutter/services.dart';
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
    expect(find.text('Unsaved changes'), findsNothing);
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
    await t.pumpAndSettle();
    // Native IME metrics can arrive after pumpAndSettle. Hide the keyboard
    // without dropping field focus, so scrolling reaches the subtask while
    // the parent's draft is still unsaved and switching must flush it.
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await settleUntil(
      t,
      () => t.view.viewInsets.bottom == 0,
      description: 'the native keyboard to hide before scrolling to a subtask',
    );
    expect(f.model.contentAutosave.hasUnsavedChanges, isTrue);
    await t.ensureVisible(find.text('Audit child'));
    await t.pumpAndSettle();
    expect(find.text('Audit child').hitTestable(), findsOneWidget);
    await t.tap(find.text('Audit child'));
    await settleUntil(
      t,
      () => f.model.state.selectedTaskId == f.child,
      description: 'the edited parent to flush and its subtask to open',
    );
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

  regressionCase(
    '23_detail_previous_next',
    phoneOnHost: true,
    seed: const RegressionSeed(
      extraTopLevelTitles: <String>['Audit alpha', 'Audit zulu'],
      openChildTitles: <String>['Audit second child'],
    ),
    (t, f) async {
      final desired = DesiredStateDao(f.database);
      final [alpha, zulu] = f.extraTasks;
      final secondChild = f.openChildren.single;
      final previous = find.byKey(const Key('task-detail-previous'));
      final next = find.byKey(const Key('task-detail-next'));
      final notes = find.byKey(const Key('task-detail-notes'));
      expect(f.model.state.visibleTasks.map((task) => task.id), <TaskId>[
        f.parent,
        f.second,
        alpha,
        zulu,
      ], reason: 'manual order');

      // The audit's assertion: details offer Previous and Next.
      await f.openParent(t);
      expect(await _enabled(t), (false, true), reason: 'first task');
      await f.capture(t, 'first_task');
      await _step(t, previous);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, f.parent, reason: 'boundary');

      // An unsaved inline edit is stored on its own task as Next opens the
      // following one, which shows only its own text.
      await t.tap(notes);
      await t.pump();
      await t.enterText(notes, 'Stored before Next');
      await t.pump();
      expect((await f.task(f.parent)).notes, 'Audit notes https://example.com');
      await _step(t, next);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, f.second);
      _expectOpen(t, 'Audit second task');
      expect(
        find.widgetWithText(TextField, 'Stored before Next'),
        findsNothing,
      );
      await settleUntil(
        t,
        () async => (await f.task(f.parent)).notes == 'Stored before Next',
        description: 'the parent notes to store as Next opens another task',
      );
      final parentIntent = await desired.readTask(f.account, f.parent);
      expect(parentIntent?.notes, 'Stored before Next');
      expect(parentIntent?.state, DesiredStateLifecycle.pending);
      expect((await f.task(f.second)).notes, isNull);
      expect(await desired.readTask(f.account, f.second), isNull);
      expect(await _enabled(t), (true, true));
      await _openTaskActions(t);
      await t.ensureVisible(next);
      _expectTouchTargetsApart(t, previous, next);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      await f.capture(t, 'middle_task');

      // Next walks to the end, where it disables; Previous walks back.
      await _step(t, next);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, alpha);
      _expectOpen(t, 'Audit alpha');
      await _step(t, next);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, zulu);
      _expectOpen(t, 'Audit zulu');
      expect(await _enabled(t), (true, false), reason: 'last task');
      await _step(t, next);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, zulu, reason: 'boundary');
      await _step(t, previous);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, alpha);

      // Stepping is lateral: one Back leaves details for the collection.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, isNull);

      // Title order: alpha, parent, second, zulu.
      await t.tap(find.byKey(const Key('collection-sort')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(CheckedPopupMenuItem<ViewSort>, 'Title'));
      await settleUntil(
        t,
        () => f.model.state.selectedViewPreferences.sort == ViewSort.title,
        description: 'title sorting to be selected',
      );
      await f.openParent(t);
      expect(await _enabled(t), (true, true));
      await _step(t, previous);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, alpha, reason: 'title order');
      expect(await _enabled(t), (false, true), reason: 'first by title');
      await _step(t, next);
      await t.pumpAndSettle();
      await _step(t, next);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, f.second);

      // Completing the open task hides it from the list; details stay on it
      // and Next leads to the task that followed it, not one further.
      await t.tap(find.byKey(const Key('task-detail-completion-action')));
      await settleUntil(
        t,
        () async => (await f.task(f.second)).status == TaskStatus.completed,
        description: 'the open task to be completed in SQLite',
      );
      expect(f.model.state.visibleTasks.map((task) => task.id), <TaskId>[
        alpha,
        f.parent,
        zulu,
      ]);
      expect(f.model.state.selectedTaskId, f.second);
      _expectOpen(t, 'Audit second task');
      expect(await _enabled(t), (true, true));
      await f.capture(t, 'completed_task');
      await _step(t, next);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, zulu);
      await _step(t, previous);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, f.parent, reason: 'second hidden');

      // A subtask steps through its siblings; Back returns to the parent.
      await t.ensureVisible(find.text('Audit child'));
      await t.pumpAndSettle();
      await t.tap(find.text('Audit child'));
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, f.child);
      _expectOpen(t, 'Audit child');
      expect(await _enabled(t), (false, true));
      await _step(t, next);
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, secondChild);
      _expectOpen(t, 'Audit second child');
      expect(await _enabled(t), (true, false));
      await f.capture(t, 'subtask_steps');
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, f.parent, reason: 'Back to parent');
      _expectOpen(t, 'Audit parent');

      // A one-task list offers neither direction.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Open navigation'));
      await t.pumpAndSettle();
      await t.tap(find.text('Audit destination').hitTestable());
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskListId, f.destination);
      await t.tap(find.text('Audit destination task'));
      await t.pumpAndSettle();
      _expectOpen(t, 'Audit destination task');
      expect(await _enabled(t), (
        false,
        false,
      ), reason: 'only task in the list');

      // Only the edit and the completion changed anything.
      for (final id in <TaskId>[alpha, zulu, f.child, secondChild]) {
        expect(await desired.readTask(f.account, id), isNull, reason: '$id');
      }
      expect(f.model.contentAutosave.hasUnsavedChanges, isFalse);
    },
  );

  regressionCase('14_duplicate_action', phoneOnHost: true, (t, f) async {
    final sourcesBefore = <TaskId, Object?>{
      for (final id in <TaskId>[f.parent, f.child, f.second])
        id: await _storedSource(f, id),
    };
    final rowsBefore = (await f.tasks()).length;

    // A subtask: open it from its parent and select Duplicate by touch.
    await f.openParent(t);
    await t.ensureVisible(find.text('Audit child'));
    await t.pumpAndSettle();
    await t.tap(find.text('Audit child'));
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, f.child);
    await _openTaskActions(t);
    expect(
      find.textContaining('Duplicate').hitTestable(),
      findsOneWidget,
      reason: 'v1.5.3 offers Duplicate in the task-detail actions',
    );
    _expectMenuTarget(t, find.byKey(const Key('task-detail-duplicate')));
    await f.capture(t, 'actions_menu');
    await t.tap(find.byKey(const Key('task-detail-duplicate')));
    final childCopy = await _awaitCopy(t, f, 'Audit child (copy)');
    expect(f.model.state.selectedTaskId, f.child, reason: 'source stays open');
    final confirmation = find.byKey(const Key('task-detail-duplicated'));
    await t.ensureVisible(confirmation);
    await t.pumpAndSettle();
    expect(
      find.text('Duplicated as “Audit child (copy)”').hitTestable(),
      findsOneWidget,
    );
    await f.capture(t, 'subtask_duplicated');
    await _expectCopy(f, childCopy, parent: f.parent);

    // The parent: back to it and Duplicate again. Its subtask is not copied.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, f.parent);
    await _openTaskActions(t);
    await t.tap(find.byKey(const Key('task-detail-duplicate')));
    final parentCopy = await _awaitCopy(t, f, 'Audit parent (copy)');
    await _expectCopy(f, parentCopy, parent: null);
    expect(
      (await f.tasks()).where((task) => task.parentTaskId == parentCopy.id),
      isEmpty,
      reason: 'v1.5.3 copies a parent without its subtasks',
    );

    // Open copy leads from the confirmation to the copy.
    final openCopy = find.byKey(const Key('task-detail-open-duplicate'));
    await t.ensureVisible(openCopy);
    await t.pumpAndSettle();
    expectTouchTarget(t, openCopy, label: 'Open copy');
    await t.tap(openCopy);
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, parentCopy.id);
    _expectOpen(t, 'Audit parent (copy)');

    // Exactly two new rows; no source changed.
    expect((await f.tasks()).length, rowsBefore + 2);
    for (final entry in sourcesBefore.entries) {
      expect(
        await _storedSource(f, entry.key),
        entry.value,
        reason: 'source ${entry.key} must not change',
      );
    }

    // Restart over the same SQLite file: the copies and hierarchy persist.
    await f.restartApp(t);
    expect((await f.tasks()).length, rowsBefore + 2);
    await _expectCopy(f, await f.task(childCopy.id), parent: f.parent);
    await _expectCopy(f, await f.task(parentCopy.id), parent: null);
    for (final entry in sourcesBefore.entries) {
      expect(await _storedSource(f, entry.key), entry.value);
    }
    expect(find.text('Audit parent (copy)'), findsOneWidget);
    await t.tap(find.text('Audit parent (copy)'));
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, parentCopy.id);
    _expectOpen(t, 'Audit parent (copy)');
    expect(
      f.model.state.tasks.where((task) => task.parentTaskId == parentCopy.id),
      isEmpty,
    );
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await f.openParent(t);
    await t.ensureVisible(find.text('Audit child (copy)'));
    await t.pumpAndSettle();
    expect(find.text('Audit child (copy)').hitTestable(), findsOneWidget);
    expect(find.text('Audit child').hitTestable(), findsOneWidget);
    await f.capture(t, 'after_restart');
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
  await t.ensureVisible(find.text('Choose date'));
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

/// Whether the details' Previous and Next controls are enabled.
Future<(bool, bool)> _enabled(WidgetTester t) async {
  await _openTaskActions(t);
  final result = (
    t
        .widget<PopupMenuItem<Object?>>(
          find.byKey(const Key('task-detail-previous')),
        )
        .enabled,
    t
        .widget<PopupMenuItem<Object?>>(
          find.byKey(const Key('task-detail-next')),
        )
        .enabled,
  );
  await t.binding.handlePopRoute();
  await t.pumpAndSettle();
  return result;
}

Future<void> _step(WidgetTester t, Finder control) async {
  await _openTaskActions(t);
  await t.ensureVisible(control);
  await t.pumpAndSettle();
  final enabled = t.widget<PopupMenuItem<Object?>>(control).enabled;
  await t.tap(control);
  await t.pumpAndSettle();
  if (!enabled) {
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
  }
}

/// The details show [title] in their own title field.
void _expectOpen(WidgetTester t, String title) {
  final field = find.byKey(const Key('task-detail-title'));
  expect(t.widget<TextField>(field).controller?.text, title);
}

/// Both controls are 48 dp touch targets and a tap at either's edge never
/// reaches the other.
void _expectTouchTargetsApart(WidgetTester t, Finder first, Finder second) {
  final firstRegion = expectTouchTarget(t, first, label: 'Previous task');
  final secondRegion = expectTouchTarget(t, second, label: 'Next task');
  for (final probe in edgeProbes(firstRegion)) {
    expect(reachesControl(t, second, probe), isFalse, reason: '$probe');
  }
  for (final probe in edgeProbes(secondRegion)) {
    expect(reachesControl(t, first, probe), isFalse, reason: '$probe');
  }
}

Future<void> _openTaskActions(WidgetTester t) async {
  final actions = find.byKey(const Key('task-detail-actions-menu'));
  await t.ensureVisible(actions);
  await t.pumpAndSettle();
  await t.tap(actions);
  await t.pumpAndSettle();
}

/// Waits for exactly one stored task titled [title] and returns it.
Future<CachedTask> _awaitCopy(
  WidgetTester t,
  RegressionFixture f,
  String title,
) async {
  await settleUntil(
    t,
    () async => (await f.tasks()).any((task) => task.title == title),
    description: 'the copy "$title" to be stored in SQLite',
  );
  return (await f.tasks()).singleWhere((task) => task.title == title);
}

/// [copy] follows the v1.5.3 rule and waits, with its own identity, to be
/// created on Google.
Future<void> _expectCopy(
  RegressionFixture f,
  CachedTask copy, {
  required TaskId? parent,
}) async {
  expect(
    <TaskId>[f.parent, f.child, f.second],
    isNot(contains(copy.id)),
    reason: 'a copy has its own local ID',
  );
  expect(copy.taskListId, f.list);
  expect(copy.parentTaskId, parent);
  expect(copy.notes, isNull);
  expect(copy.due, isNull);
  expect(copy.status, TaskStatus.needsAction);
  expect(copy.remoteId, isNull, reason: 'no Google ID is reused');
  expect(copy.webViewLink, isNull);
  final intent = await DesiredStateDao(f.database).readTask(f.account, copy.id);
  expect(intent?.state, DesiredStateLifecycle.pending);
  expect(intent?.title, copy.title);
  expect(intent?.parentTaskId, parent);
  expect(intent?.baseRemoteId, isNull);
  expect(intent?.baseEtag, isNull);
  final bases = await f.database
      .customSelect(
        'SELECT COUNT(*) AS c FROM task_remote_bases WHERE task_id = ?',
        variables: [Variable<int>(copy.id.value)],
      )
      .getSingle();
  expect(bases.read<int>('c'), 0, reason: 'no remote base or ETag copied');
}

/// Everything stored for one source task: its row, remote base (with ETag)
/// and publication intent.
Future<List<Object?>> _storedSource(RegressionFixture f, TaskId id) async {
  Future<List<Map<String, Object?>>> rows(String sql) async => [
    for (final row
        in await f.database
            .customSelect(sql, variables: [Variable<int>(id.value)])
            .get())
      Map<String, Object?>.of(row.data),
  ];
  return <Object?>[
    await rows('SELECT * FROM tasks WHERE id = ?'),
    await rows('SELECT * FROM task_remote_bases WHERE task_id = ?'),
    await rows('SELECT * FROM desired_states WHERE target_task_id = ?'),
  ];
}

/// [item] is a whole, on-screen menu entry with a 48 dp tall hit region and
/// a tap action for assistive technology.
void _expectMenuTarget(WidgetTester t, Finder item) {
  final region = measureHitRegion(t, item);
  final screen = Offset.zero & t.view.physicalSize / t.view.devicePixelRatio;
  expect(
    region.height,
    greaterThanOrEqualTo(kMinInteractiveDimension - hitRegionTolerance),
    reason: 'menu entry hit region $region is tall enough to tap',
  );
  expect(
    screen.contains(region.topLeft) &&
        screen.contains(region.bottomRight - const Offset(1, 1)),
    isTrue,
    reason: 'menu entry $region lies on the $screen screen',
  );
  expect(
    t.getSemantics(item).getSemanticsData().hasAction(SemanticsAction.tap),
    isTrue,
    reason: 'menu entry exposes a tap action',
  );
}
