// Baseline subset of the Android behavior manifest (manifest.json).
//
// Every case here passed the 2026-11-15 native audit of v1.5.6 against the
// v1.5.3 reference. Run through tool/android_regression/runner.dart so missing
// cases, teardown errors and infrastructure failures fail the gate.
import 'dart:io';

import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/regression_harness.dart';

void main() {
  ensureRegressionBinding();

  regressionCase('04_complete_button_persists', (t, f) async {
    await t.tap(
      find.descendant(
        of: f.row(f.parent),
        matching: find.byTooltip('Complete task'),
      ),
    );
    await settleUntil(
      t,
      () async => (await f.task(f.parent)).status == TaskStatus.completed,
      description: 'the parent to be completed in SQLite',
    );
    expect((await f.task(f.second)).status, TaskStatus.needsAction);
  });

  regressionCase('07_quick_capture_twice', (t, f) async {
    const titles = <String>['Captured first', 'Captured second'];
    for (final title in titles) {
      await t.enterText(find.byKey(const Key('quick-add-input')), title);
      await t.pump();
      await t.tap(find.byKey(const Key('quick-add-submit')));
      await settleUntil(
        t,
        () async => (await f.tasks()).any((task) => task.title == title),
        description: '"$title" to persist',
      );
    }
    final captured = (await f.tasks()).where(
      (task) => titles.contains(task.title),
    );
    expect(captured.map((task) => task.title), unorderedEquals(titles));
    expect(captured.map((task) => task.taskListId).toSet(), {f.list});
    expect(captured.map((task) => task.id).toSet(), hasLength(2));
  });

  regressionCase('10_edit_save_persists', (t, f) async {
    await f.openParent(t);
    await t.tap(find.byTooltip('Edit task content'));
    await t.pumpAndSettle();
    await t.enterText(_textFieldLabelled('Notes'), 'Edited audit notes');
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await settleUntil(
      t,
      () async => (await f.task(f.parent)).notes == 'Edited audit notes',
      description: 'edited notes to persist',
    );
    expect((await f.task(f.parent)).title, 'Audit parent');
  });

  regressionCase('12_add_subtask_persists', (t, f) async {
    await f.openParent(t);
    await t.ensureVisible(find.text('Add subtask'));
    await t.tap(find.text('Add subtask'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Created child');
    await t.tap(find.widgetWithText(FilledButton, 'Create'));
    await settleUntil(
      t,
      () async =>
          (await f.tasks()).any((task) => task.title == 'Created child'),
      description: 'the subtask to persist',
    );
    final created = (await f.tasks()).singleWhere(
      (task) => task.title == 'Created child',
    );
    expect(created.parentTaskId, f.parent);
    expect(created.taskListId, f.list);
  });

  regressionCase('13_subtask_back_returns_parent', (t, f) async {
    await f.openParent(t);
    await t.ensureVisible(find.text('Audit child'));
    await t.tap(find.text('Audit child'));
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, f.child);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(
      f.model.state.selectedTaskId,
      f.parent,
      reason: 'Back from a subtask returns to its parent details',
    );
  });

  regressionCase('16_move_task_persists', (t, f) async {
    await f.openParent(t);
    await t.ensureVisible(find.text('Move to list'));
    await t.tap(find.text('Move to list'));
    await t.pumpAndSettle();
    await t.tap(find.text('Audit destination').hitTestable());
    await settleUntil(
      t,
      () async => (await f.task(f.parent)).taskListId == f.destination,
      description: 'the parent to move in SQLite',
    );
    expect((await f.task(f.child)).taskListId, f.destination);
    expect((await f.task(f.child)).parentTaskId, f.parent);
    expect((await f.task(f.second)).taskListId, f.list);
  });

  regressionCase('19_failure_explanation', label: CaseLabel.limitedPass, (
    t,
    f,
  ) async {
    f.health.set(
      SyncHealth(
        outcome: SyncHealthOutcome.failed,
        counts: const SyncWorkCounts(failed: 1),
        lastSuccessfulSyncAt: regressionNow,
        evaluatedAt: regressionNow,
        failureReason: SyncFailureReason.applicationFailure,
        diagnosticCode: 'regression.unspecified_failure',
        action: SyncHealthAction.retry,
      ),
    );
    await t.pumpAndSettle();
    await f.capture(t, 'failure_banner');
    expect(t.takeException(), isNull);
    expect(
      find.textContaining('Sync could not finish').hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Audit parent').hitTestable(), findsOneWidget);
  });

  regressionCase('21_delete_and_undo', (t, f) async {
    await f.openParent(t);
    await t.ensureVisible(find.byKey(const Key('task-detail-actions-menu')));
    await t.tap(find.byKey(const Key('task-detail-actions-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete task').hitTestable());
    await settleUntil(
      t,
      () async => await f.taskOrNull(f.parent) == null,
      description: 'the parent to be deleted locally',
    );
    await t.tap(find.text('Undo').hitTestable());
    await settleUntil(
      t,
      () async => await f.taskOrNull(f.parent) != null,
      description: 'Undo to restore the parent',
    );
    final restored = await f.task(f.parent);
    expect(restored.title, 'Audit parent');
    expect(restored.notes, 'Audit notes https://example.com');
    expect(restored.taskListId, f.list);
  });

  regressionCase('24_navigation_drawer', (t, f) async {
    await t.tap(find.byTooltip('Open navigation'));
    await t.pumpAndSettle();
    await t.tap(find.text('Audit destination').hitTestable());
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskListId, f.destination);
    expect(find.text('Audit destination task').hitTestable(), findsOneWidget);
    expect(find.text('Audit parent'), findsNothing);
  });

  regressionCase('25_date_shortcut_and_undo', (t, f) async {
    final parentDue = TaskDate(2026, 11, 15);
    final childDue = TaskDate(2026, 11, 14);
    final tomorrow = TaskDate(2026, 11, 16);
    expect((await f.task(f.parent)).due, parentDue);
    expect(
      (await f.task(f.child)).due,
      childDue,
      reason: 'An earlier-due child exercises the cascade receipt',
    );

    await f.openParent(t);
    await t.ensureVisible(find.byKey(const Key('task-detail-due-action')));
    await t.tap(find.byKey(const Key('task-detail-due-action')));
    await t.pumpAndSettle();
    await t.tap(find.text('Tomorrow').hitTestable());
    await settleUntil(
      t,
      () async => (await f.task(f.parent)).due == tomorrow,
      description: 'the parent due date to advance',
    );
    expect(f.model.state.taskCommandFailureMessage, isNull);
    expect(
      (await f.task(f.child)).due,
      tomorrow,
      reason: 'A later parent date pushes its earlier-due child with it',
    );
    expect(find.text('Date changed for 2 related tasks'), findsOneWidget);

    await t.ensureVisible(find.text('Undo due changes'));
    await t.tap(find.text('Undo due changes'));
    await settleUntil(
      t,
      () async => (await f.task(f.parent)).due == parentDue,
      description: 'Undo to restore the parent due date',
    );
    expect((await f.task(f.child)).due, childDue);
    expect(f.model.state.taskCommandFailureMessage, isNull);
  });

  regressionCase('26_large_text_layout', label: CaseLabel.limitedPass, (
    t,
    f,
  ) async {
    t.platformDispatcher.textScaleFactorTestValue = 2;
    await t.pumpAndSettle();
    await f.capture(t, 'large_text');
    expect(t.takeException(), isNull);
    expect(
      find.byKey(const Key('quick-add-submit')).hitTestable(),
      findsOneWidget,
    );
  });

  regressionCase('27_landscape_capture', label: CaseLabel.limitedPass, (
    t,
    f,
  ) async {
    if (Platform.isAndroid) {
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
      ]);
      await settleUntil(
        t,
        () => t.view.physicalSize.width > t.view.physicalSize.height,
        description: 'landscape orientation',
      );
    } else {
      t.view.physicalSize = const Size(900, 412);
      await t.pumpAndSettle();
    }
    await f.capture(t, 'landscape');
    expect(t.takeException(), isNull);
    expect(
      find.byKey(const Key('quick-add-input')).hitTestable(),
      findsOneWidget,
    );
  });

  regressionCase('28_create_list', (t, f) async {
    await t.tap(find.byKey(const Key('collection-actions-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Create Google task list').hitTestable());
    await t.pumpAndSettle();
    await t.enterText(_textFieldLabelled('List title'), 'Created audit list');
    await t.tap(find.widgetWithText(FilledButton, 'Create'));
    await settleUntil(
      t,
      () async => (await f.snapshot()).taskLists.any(
        (list) => list.title == 'Created audit list',
      ),
      description: 'the new list to persist',
    );
    expect(
      f.model.state.taskLists.where(
        (list) => list.title == 'Created audit list',
      ),
      hasLength(1),
    );
  });

  regressionCase('29_rename_delete_list', (t, f) async {
    await t.tap(find.byKey(const Key('collection-actions-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Rename task list').hitTestable());
    await t.pumpAndSettle();
    await t.enterText(_textFieldLabelled('List title'), 'Renamed audit list');
    await t.tap(find.widgetWithText(FilledButton, 'Rename'));
    await settleUntil(
      t,
      () async => (await f.snapshot()).taskLists.any(
        (list) => list.id == f.list && list.title == 'Renamed audit list',
      ),
      description: 'the rename to persist',
    );
    expect(find.text('Renamed audit list'), findsWidgets);

    await t.tap(find.byKey(const Key('collection-actions-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete task list').hitTestable());
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Delete list'));
    await settleUntil(
      t,
      () async => !(await f.tasks()).any((task) => task.taskListId == f.list),
      description: 'the list tasks to be deleted locally',
    );
    final remaining = await f.snapshot();
    expect(remaining.taskLists.map((list) => list.id), isNot(contains(f.list)));
    expect(
      remaining.tasks.map((task) => task.title),
      contains('Audit destination task'),
    );
  });

  regressionCase(
    '30_completed_filter_and_sort',
    seed: const RegressionSeed(extraTopLevelTitles: <String>['Audit alpha']),
    (t, f) async {
      final alpha = f.extraTasks.single;
      List<TaskId> openTopLevelOrder() => f.model.state.visibleProjection.rows
          .map((row) => row.task)
          .where(
            (task) =>
                task.parentTaskId == null &&
                task.status == TaskStatus.needsAction,
          )
          .map((task) => task.id)
          .toList();
      expect(openTopLevelOrder(), <TaskId>[f.parent, f.second, alpha]);

      await t.tap(
        find.descendant(
          of: f.row(f.parent),
          matching: find.byTooltip('Complete task'),
        ),
      );
      await settleUntil(
        t,
        () async => (await f.task(f.parent)).status == TaskStatus.completed,
        description: 'the parent to be completed in SQLite',
      );
      await t.tap(find.byKey(const Key('collection-actions-menu')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('collection-show-completed')));
      await t.pumpAndSettle();
      expect(find.text('Audit parent').hitTestable(), findsOneWidget);
      expect(f.model.state.selectedViewPreferences.showCompleted, isTrue);

      await t.tap(find.byKey(const Key('collection-sort')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(CheckedPopupMenuItem<ViewSort>, 'Title'));
      await settleUntil(
        t,
        () => f.model.state.selectedViewPreferences.sort == ViewSort.title,
        description: 'title sorting to be selected',
      );

      expect(openTopLevelOrder(), <TaskId>[
        alpha,
        f.second,
      ], reason: 'Title sorting reorders the visible open tasks');
      expect(
        t.getTopLeft(f.row(alpha)).dy,
        lessThan(t.getTopLeft(f.row(f.second)).dy),
        reason: 'The rendered rows follow the title order',
      );
      final stored = await f.preferences
          .watchViewPreferences(f.account, f.model.state.selectedView.key)
          .first;
      expect(stored.sort, ViewSort.title);
      expect(stored.showCompleted, isTrue);
    },
  );

  regressionCase('31_settings_theme', (t, f) async {
    await t.tap(find.text('More').hitTestable());
    await t.pumpAndSettle();
    await t.tap(find.text('Settings').hitTestable());
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('settings-theme-light')));
    await settleUntil(
      t,
      () async =>
          (await f.preferences.watchDevicePreferences().first).theme ==
          ThemePreference.light,
      description: 'the light theme to persist',
    );
  });

  regressionCase('36_detail_move_down', (t, f) async {
    List<TaskId> topLevelOrder() => f.model.state.visibleProjection.rows
        .map((row) => row.task)
        .where((task) => task.parentTaskId == null)
        .map((task) => task.id)
        .toList();
    expect(topLevelOrder(), <TaskId>[f.parent, f.second]);
    await f.openParent(t);
    await t.ensureVisible(find.text('Move down'));
    await t.tap(find.text('Move down'));
    await settleUntil(
      t,
      () => topLevelOrder().last == f.parent,
      description: 'the parent to move below its sibling',
    );
    expect(f.model.state.taskCommandFailureMessage, isNull);
    expect(topLevelOrder(), <TaskId>[f.second, f.parent]);
    expect((await f.task(f.child)).parentTaskId, f.parent);
  });
}

Finder _textFieldLabelled(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);
