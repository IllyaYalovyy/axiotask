// #288 — what a screen reader says when it lands on a CHECKBOX.
//
// The failure this bars: every checkbox in the app was an unnamed semantics
// node of its own. A row's checkbox published `hasCheckedState` and a tap
// action and nothing else, so swiping element-by-element through a list gave
// "not checked, checkbox, double tap to activate" — identically for every
// row. The name of the task it would complete sat in the SIBLING node, which
// made the one control that changes data the one element that never says
// what it acts on. Switch Access and keyboard-with-TalkBack land on it the
// same way.
//
// A checkbox is named after the thing it toggles: a row's checkbox says the
// task's title, a subtask's says the subtask's title, and the two
// label-beside-a-box toggles are ONE stop that says its label rather than a
// named parent wrapping a nameless child.
//
// Not a tooltip: a tooltip is a hover affordance and touch has no hover.
//
// Determinism: the clock is pinned (the row's due segment derives its label
// from `clock.now()`), and nothing animates at rest.

import 'dart:ui' show CheckedState, Tristate;

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_view.dart';
import 'package:axiotask/src/ui/compact_chrome.dart';
import 'package:axiotask/src/ui/detail_subtasks.dart';
import 'package:axiotask/src/ui/list_toolbar.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/visible_rows.dart' show TaskRowData;
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show inertRowActions, row;

final _clock = Clock.fixed(DateTime(2026, 6, 15, 12));

/// Every STOP a screen reader announces as a checkbox: a semantics node that
/// carries a checked state and is not merged up into an ancestor (a merged-up
/// node is part of its parent's announcement, never its own).
List<SemanticsData> _checkboxNodes(WidgetTester tester) {
  final found = <SemanticsData>[];
  void visit(SemanticsNode node) {
    if (!node.isMergedIntoParent) {
      final data = node.getSemanticsData();
      if (data.flagsCollection.isChecked != CheckedState.none) found.add(data);
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.binding.rootElement!.renderObject!.debugSemantics!);
  return found;
}

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    String title = 'buy milk',
    bool completed = false,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    await withClock(_clock, () async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: TaskRow(
              title: title,
              completed: completed,
              onOpen: () {},
              onToggle: () {},
              onRename: (_) {},
              onPickDate: () {},
              onOpenUrl: (_) {},
            ),
          ),
        ),
      );
    });
  }

  group('a task row checkbox (#288)', () {
    testWidgets('says the title of the task it would complete', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpRow(tester);

      final boxes = _checkboxNodes(tester);
      expect(boxes, hasLength(1));
      expect(
        boxes.single.label,
        'buy milk',
        reason: 'the checkbox said "checkbox" and nothing else',
      );
      expect(boxes.single.flagsCollection.isChecked, CheckedState.isFalse);
      handle.dispose();
    });

    testWidgets('a completed row: same name, only the flag changes', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpRow(tester, completed: true);

      final boxes = _checkboxNodes(tester);
      expect(boxes, hasLength(1));
      expect(boxes.single.label, 'buy milk');
      expect(
        boxes.single.flagsCollection.isChecked,
        CheckedState.isTrue,
        reason: 'naming the box must not cost it its checked state',
      );
      handle.dispose();
    });

    testWidgets('the compact MOUSE checkbox is named too', (tester) async {
      // A fine pointer builds the other of the two Checkbox call sites.
      final handle = tester.ensureSemantics();
      await pumpRow(tester, platform: TargetPlatform.linux);

      final boxes = _checkboxNodes(tester);
      expect(boxes, hasLength(1));
      expect(boxes.single.label, 'buy milk');
      handle.dispose();
    });

    testWidgets('an untitled task: the box says what the row shows', (
      tester,
    ) async {
      // Non-happy path: a blank title renders as "Untitled", so an empty
      // label here would put the box straight back to anonymous.
      final handle = tester.ensureSemantics();
      await pumpRow(tester, title: '');

      final boxes = _checkboxNodes(tester);
      expect(boxes, hasLength(1));
      expect(boxes.single.label, 'Untitled');
      handle.dispose();
    });

    testWidgets('the row itself still says its title exactly once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpRow(tester);

      final row = tester.getSemantics(find.byType(TaskRow)).getSemanticsData();
      expect(
        row.label,
        'buy milk',
        reason: 'naming the child box must not double the row announcement',
      );
      handle.dispose();
    });
  });

  group('the detail panel checkboxes (#288)', () {
    Future<void> pumpSubtask(
      WidgetTester tester, {
      String title = 'call the plumber',
      TaskStatus status = TaskStatus.needsAction,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubtaskRow(
              data: TaskRowData(
                stored: row(
                  's1',
                  title,
                  parent: 'P',
                  done: status == TaskStatus.completed,
                ),
              ),
              actions: inertRowActions(),
            ),
          ),
        ),
      );
    }

    testWidgets('a subtask checkbox says the subtask it would complete', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSubtask(tester);

      final boxes = _checkboxNodes(tester);
      expect(boxes, hasLength(1));
      expect(boxes.single.label, 'call the plumber');
      expect(boxes.single.flagsCollection.isChecked, CheckedState.isFalse);
      handle.dispose();
    });

    testWidgets('a completed subtask keeps its name and reads as checked', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSubtask(tester, status: TaskStatus.completed);

      final boxes = _checkboxNodes(tester);
      expect(boxes.single.label, 'call the plumber');
      expect(boxes.single.flagsCollection.isChecked, CheckedState.isTrue);
      handle.dispose();
    });

    testWidgets('an untitled subtask says what the row shows', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSubtask(tester, title: '');

      final boxes = _checkboxNodes(tester);
      expect(boxes.single.label, 'Untitled');
      handle.dispose();
    });

    // #306 retired the panel's "Hide completed" checkbox — the preference is
    // stated in Properties, and the panel gathers the finished subtasks under a
    // "N completed" disclosure. What it announces is a BUTTON with an expansion
    // state, not a checkbox: a screen reader that hears "checkbox" here would
    // be told the group is a thing to tick.
    testWidgets('the completed group announces as one expandable button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompletedSubtasksGroup(
              count: 3,
              expanded: false,
              onToggle: (_) {},
              onUncompleteAll: () {},
            ),
          ),
        ),
      );

      expect(_checkboxNodes(tester), isEmpty);
      final node = tester.getSemantics(
        find.byKey(const Key('completed-subtasks-toggle')),
      );
      expect(node.label, '3 completed subtasks');
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isExpanded, Tristate.isFalse);
      handle.dispose();
    });
  });

  group('the list toolbar checkbox (#288)', () {
    Future<void> pumpToolbar(WidgetTester tester, {bool show = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListToolbar(
              ListChromeActions(
                sort: SortMode.manual,
                showCompleted: show,
                onSearch: () {},
                onSelectTasks: null,
                selectTasksEnabled: false,
                onBulkAdd: () {},
                onSort: (_) {},
                onShowCompleted: (_) {},
                onClearCompleted: null,
                onExport: null,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('"Show completed" is one named checkbox, not two stops', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpToolbar(tester);

      final boxes = _checkboxNodes(tester);
      expect(boxes, hasLength(1));
      expect(boxes.single.label, 'Show completed');
      expect(boxes.single.flagsCollection.isChecked, CheckedState.isFalse);
      handle.dispose();
    });

    testWidgets('with completed shown it still names itself, now checked', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpToolbar(tester, show: true);

      final boxes = _checkboxNodes(tester);
      expect(boxes.single.label, 'Show completed');
      expect(boxes.single.flagsCollection.isChecked, CheckedState.isTrue);
      handle.dispose();
    });
  });
}
