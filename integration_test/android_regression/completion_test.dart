// Completion subset of the Android behavior manifest (manifest.json).
//
// Cases 05 and 33 failed the 2026-11-15 native audit of v1.5.6: completing a
// task offered no Undo, and completing a parent left its open subtask open in
// SQLite, unlike v1.5.3. These contracts drive the real shell by touch over
// the isolated file-backed SQLite fixture. They check the stored task state
// and the durable publication intent behind every changed task, and that the
// Undo feedback is reachable from the row button, the row menu and the
// details pane. Run through tool/android_regression/runner.dart.
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/regression_harness.dart';

/// The v1.5.3 Undo window, also pinned by test/domain/completion_policy_test.
const _undoWindow = Duration(seconds: 30);

void main() {
  ensureRegressionBinding();

  regressionCase('05_completion_undo', phoneOnHost: true, (t, f) async {
    // Row completion button.
    await t.tap(_rowCompletion(f, f.parent));
    await _expectFamilyStatus(t, f, TaskStatus.completed);
    _expectUndoOffered('“Audit parent” and 1 subtask completed');
    await f.capture(t, 'button_undo_offered');
    await _undo(t, f);

    // Row ⋮ menu.
    await t.tap(
      find.descendant(
        of: f.row(f.parent),
        matching: find.byTooltip('Task actions for Audit parent'),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Complete task').hitTestable());
    await _expectFamilyStatus(t, f, TaskStatus.completed);
    _expectUndoOffered('“Audit parent” and 1 subtask completed');
    await _undo(t, f);

    // Details pane: the Undo stays reachable while details are open.
    await f.openParent(t);
    await t.tap(find.byKey(const Key('task-detail-completion-action')));
    await _expectFamilyStatus(t, f, TaskStatus.completed);
    _expectUndoOffered('“Audit parent” and 1 subtask completed');
    await f.capture(t, 'detail_undo_offered');
    await _undo(t, f);
    expect(f.model.state.selectedTaskId, f.parent);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    // The offer expires after the Undo window; the completion stays stored.
    await t.tap(_rowCompletion(f, f.parent));
    await _expectFamilyStatus(t, f, TaskStatus.completed);
    _expectUndoOffered('“Audit parent” and 1 subtask completed');
    f.clock.advance(_undoWindow);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('task-completion-undo')), findsNothing);
    expect((await f.task(f.parent)).status, TaskStatus.completed);
    expect((await f.task(f.child)).status, TaskStatus.completed);
    expect((await f.task(f.second)).status, TaskStatus.needsAction);
  });

  regressionCase(
    '33_parent_completion_cascade',
    phoneOnHost: true,
    seed: const RegressionSeed(completedChildTitles: <String>['Audit done']),
    (t, f) async {
      final done = f.completedChildren.single;
      final desired = DesiredStateDao(f.database);
      expect((await f.task(done)).status, TaskStatus.completed);

      await t.tap(_rowCompletion(f, f.parent));
      await settleUntil(
        t,
        () async => (await f.task(f.parent)).status == TaskStatus.completed,
        description: 'the parent to be completed in SQLite',
      );
      expect(
        (await f.task(f.child)).status,
        TaskStatus.completed,
        reason: 'v1.5.3 completes the parent and its open subtasks together',
      );
      expect((await f.task(done)).status, TaskStatus.completed);
      expect((await f.task(f.second)).status, TaskStatus.needsAction);
      for (final id in <TaskId>[f.parent, f.child]) {
        final intent = await desired.readTask(f.account, id);
        expect(intent?.status, TaskStatus.completed, reason: '$id intent');
        expect(intent?.state, DesiredStateLifecycle.pending, reason: '$id');
      }
      expect(
        await desired.readTask(f.account, done),
        isNull,
        reason: 'an already-completed subtask is not rewritten',
      );
      expect(await desired.readTask(f.account, f.second), isNull);
      _expectUndoOffered('“Audit parent” and 1 subtask completed');
      await f.capture(t, 'cascade_completed');

      await t.tap(find.text('Undo').hitTestable());
      await settleUntil(
        t,
        () async =>
            (await f.task(f.parent)).status == TaskStatus.needsAction &&
            (await f.task(f.child)).status == TaskStatus.needsAction,
        description: 'Undo to reopen the parent and its cascaded subtask',
      );
      expect(
        (await f.task(done)).status,
        TaskStatus.completed,
        reason: 'Undo reopens only what the completion changed',
      );
      for (final id in <TaskId>[f.parent, f.child]) {
        final intent = await desired.readTask(f.account, id);
        expect(intent?.status, TaskStatus.needsAction, reason: '$id intent');
        expect(intent?.state, DesiredStateLifecycle.pending, reason: '$id');
      }
      expect(await desired.readTask(f.account, done), isNull);

      // Completing a subtask alone never completes its parent.
      await f.openParent(t);
      await t.ensureVisible(find.byTooltip('Complete Audit child'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Complete Audit child'));
      await settleUntil(
        t,
        () async => (await f.task(f.child)).status == TaskStatus.completed,
        description: 'the subtask to be completed in SQLite',
      );
      expect((await f.task(f.parent)).status, TaskStatus.needsAction);
      expect((await f.task(f.second)).status, TaskStatus.needsAction);
      _expectUndoOffered('“Audit child” completed');
      await f.capture(t, 'subtask_completed');
    },
  );
}

Finder _rowCompletion(RegressionFixture f, TaskId task) =>
    find.descendant(of: f.row(task), matching: find.byTooltip('Complete task'));

Future<void> _expectFamilyStatus(
  WidgetTester t,
  RegressionFixture f,
  TaskStatus status,
) async {
  await settleUntil(
    t,
    () async =>
        (await f.task(f.parent)).status == status &&
        (await f.task(f.child)).status == status,
    description: 'the parent and its subtask to be ${status.name} in SQLite',
  );
  expect(
    (await f.task(f.second)).status,
    TaskStatus.needsAction,
    reason: 'an unrelated task never changes',
  );
}

void _expectUndoOffered(String message) {
  final banner = find.byKey(const Key('task-completion-undo'));
  expect(banner, findsOneWidget, reason: 'completion feedback is shown');
  expect(
    find.descendant(of: banner, matching: find.text(message)),
    findsOneWidget,
  );
  expect(
    find.text('Undo').hitTestable(),
    findsOneWidget,
    reason: 'Accidental completion must be reversible from feedback',
  );
}

Future<void> _undo(WidgetTester t, RegressionFixture f) async {
  await t.tap(find.text('Undo').hitTestable());
  await _expectFamilyStatus(t, f, TaskStatus.needsAction);
  expect(find.byKey(const Key('task-completion-undo')), findsNothing);
}
