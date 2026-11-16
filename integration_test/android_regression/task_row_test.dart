// Task-row actions subset of the Android behavior manifest (manifest.json).
//
// Cases 01 and 22 failed the 2026-11-15 native audit of v1.5.6: the row's ⋮
// menu was clipped to its 40 × 40 trigger, and the completion control's hit
// region was 40 × 40 (36 × 36 in compact density). These contracts drive
// the real shell over the isolated SQLite fixture by touch at 360 and 443
// logical-pixel phone widths, portrait and landscape, at 1x and 2x text.
// Run through tool/android_regression/runner.dart.
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../test/support/touch_targets.dart';
import 'support/regression_harness.dart';

const _menuLabels = <String>[
  'Open details',
  'Complete task',
  'Edit task…',
  'Choose date…',
  'Move to list…',
  'Delete task',
];

void main() {
  ensureRegressionBinding();

  regressionCase('01_task_menu', phoneOnHost: true, (t, f) async {
    for (final viewport in phoneViewports) {
      await usePhoneViewport(t, viewport);
      expect(t.takeException(), isNull, reason: '$viewport list layout');
      await t.tap(_overflow(f, f.parent, 'Audit parent'));
      await t.pumpAndSettle();
      await expectReadableMenu(t, _menuLabels);
      expect(t.takeException(), isNull, reason: '$viewport open menu');
      await f.capture(t, 'menu_${viewport.name}');
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('Edit task…'), findsNothing, reason: '$viewport');
    }

    // Edit from the row menu where it is hardest to reach: narrow
    // landscape with large text, where the menu scrolls.
    await usePhoneViewport(
      t,
      const PhoneViewport(360, PhoneOrientation.landscape, 2),
    );
    await _chooseRowAction(t, f, f.parent, 'Audit parent', 'Edit task…');
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.text('Edit task')),
      findsOneWidget,
    );
    await t.enterText(
      find.descendant(of: dialog, matching: _textFieldLabelled('Task title')),
      'Audit parent edited',
    );
    await t.tap(find.widgetWithText(FilledButton, 'Save').hitTestable());
    await settleUntil(
      t,
      () async => (await f.task(f.parent)).title == 'Audit parent edited',
      description: 'the edited title to persist in SQLite',
    );
    final edited = await f.task(f.parent);
    expect(edited.notes, 'Audit notes https://example.com');
    expect(edited.taskListId, f.list);
    expect(f.model.state.taskCommandFailureMessage, isNull);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('Audit parent edited').hitTestable(), findsOneWidget);

    // Delete from the row menu, then restore it with the existing Undo.
    await usePhoneViewport(
      t,
      const PhoneViewport(443, PhoneOrientation.portrait, 1),
    );
    await _chooseRowAction(
      t,
      f,
      f.parent,
      'Audit parent edited',
      'Delete task',
    );
    await settleUntil(
      t,
      () async => await f.taskOrNull(f.parent) == null,
      description: 'the parent to be deleted locally',
    );
    expect((await f.task(f.second)).title, 'Audit second task');
    await f.capture(t, 'delete_undo_offer');
    await t.tap(find.text('Undo').hitTestable());
    await settleUntil(
      t,
      () async => await f.taskOrNull(f.parent) != null,
      description: 'Undo to restore the parent',
    );
    final restored = await f.task(f.parent);
    expect(restored.title, 'Audit parent edited');
    expect(restored.notes, 'Audit notes https://example.com');
    expect(restored.taskListId, f.list);
    expect(restored.status, TaskStatus.needsAction);
    final child = await f.task(f.child);
    expect(child.parentTaskId, f.parent);
    expect(child.taskListId, f.list);
    expect(f.model.state.taskCommandFailureMessage, isNull);
    expect(find.text('Audit parent edited').hitTestable(), findsOneWidget);
  });

  regressionCase('22_touch_target_size', phoneOnHost: true, (t, f) async {
    // Completed rows stay visible so edge taps can toggle one row repeatedly.
    await f.model.setShowCompleted(true);
    await t.pumpAndSettle();
    for (final density in DensityPreference.values) {
      expect(await f.preferences.setDensity(density), isA<Success<void>>());
      await settleUntil(
        t,
        () async =>
            (await f.preferences.watchDevicePreferences().first).density ==
            density,
        description: '$density density to persist',
      );
      for (final viewport in phoneViewports) {
        await usePhoneViewport(t, viewport);
        expect(t.takeException(), isNull, reason: '$density $viewport');
        final completion = _completion(f, f.parent);
        final overflow = _overflow(f, f.parent, 'Audit parent');
        final completionRegion = expectTouchTarget(
          t,
          completion,
          label: 'Complete task',
        );
        final overflowRegion = expectTouchTarget(
          t,
          overflow,
          label: 'Task actions for Audit parent',
        );
        expect(
          completionRegion.overlaps(overflowRegion),
          isFalse,
          reason: '$density $viewport: $completionRegion, $overflowRegion',
        );
        for (final probe in edgeProbes(completionRegion)) {
          expect(reachesControl(t, overflow, probe), isFalse);
        }
        for (final probe in edgeProbes(overflowRegion)) {
          expect(reachesControl(t, completion, probe), isFalse);
        }
        if (viewport.shortSide == 360 && viewport.textScale == 2) {
          await f.capture(t, 'targets_${density.name}_${viewport.name}');
        }
      }

      // Taps that only graze each edge still reach the intended control.
      await usePhoneViewport(
        t,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      final region = measureHitRegion(t, _completion(f, f.second));
      for (final (index, probe) in edgeProbes(region).indexed) {
        final current = await f.task(f.second);
        final next = current.status == TaskStatus.completed
            ? TaskStatus.needsAction
            : TaskStatus.completed;
        final target = measureHitRegion(t, _completion(f, f.second));
        final offset = probe - region.center + target.center;
        await t.tapAt(offset);
        await settleUntil(
          t,
          () async => (await f.task(f.second)).status == next,
          description: '$density edge tap $index at $offset to set $next',
        );
      }
      expect((await f.task(f.parent)).status, TaskStatus.needsAction);
      final overflow = _overflow(f, f.second, 'Audit second task');
      for (final probe in edgeProbes(measureHitRegion(t, overflow))) {
        await t.tapAt(probe);
        await t.pumpAndSettle();
        expect(
          find.text('Edit task…').hitTestable(),
          findsOneWidget,
          reason: '$density: a tap at $probe opens the task menu',
        );
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
      }
      expect(f.model.state.taskCommandFailureMessage, isNull);
    }
  });
}

Finder _completion(RegressionFixture f, TaskId task) => find.descendant(
  of: f.row(task),
  matching: find.byTooltip(RegExp(r'^(Complete|Reopen) task$')),
);

Finder _overflow(RegressionFixture f, TaskId task, String title) =>
    find.descendant(
      of: f.row(task),
      matching: find.byTooltip('Task actions for $title'),
    );

Future<void> _chooseRowAction(
  WidgetTester t,
  RegressionFixture f,
  TaskId task,
  String title,
  String action,
) async {
  await t.tap(_overflow(f, task, title));
  await t.pumpAndSettle();
  await t.ensureVisible(find.text(action));
  await t.pumpAndSettle();
  await t.tap(find.text(action).hitTestable());
  await t.pumpAndSettle();
}

Finder _textFieldLabelled(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);
