// #287 — what a screen reader says when it lands on a task row.
//
// The failure this bars: the row's subtask progress bar is a
// [LinearProgressIndicator], and a determinate one publishes a semantic VALUE
// ("0") and the `progressBar` ROLE. The row is one merged semantics node, so
// that value and that role were the ROW's — and Android's accessibility bridge
// reads a node's value BEFORE its label, so a task with two unfinished
// subtasks announced as "0, ext two (copy)": a bare number ahead of the title,
// on a node the AT believed was a progress bar rather than a list item.
//
// A progress BAR is a picture of a fraction that is already written beside it.
// It carries no information of its own, so it says nothing, and the count says
// it in words instead.
//
// Determinism: the clock is pinned (the due segment's label is derived from
// `clock.now()`), and no animation is running at rest.

import 'package:axiotask/src/ui/task_row.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

final _clock = Clock.fixed(DateTime(2026, 6, 15, 12));

void main() {
  Future<SemanticsData> pumpRow(
    WidgetTester tester, {
    String title = 'ext two (copy)',
    String? notes,
    String? due,
    bool pendingSync = false,
    int subtaskDone = 0,
    int subtaskTotal = 0,
  }) async {
    await withClock(_clock, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskRow(
              title: title,
              notes: notes,
              completed: false,
              due: due,
              pendingSync: pendingSync,
              subtaskDone: subtaskDone,
              subtaskTotal: subtaskTotal,
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
    return tester.getSemantics(find.byType(TaskRow)).getSemanticsData();
  }

  group('the task row (#287)', () {
    testWidgets('announces its TITLE first, and the subtask count in words', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final data = await pumpRow(tester, subtaskDone: 1, subtaskTotal: 3);

      expect(
        data.label.split('\n').first,
        'ext two (copy)',
        reason: 'the title is the first thing said about a row',
      );
      expect(data.label, contains('1 of 3 subtasks complete'));
      expect(
        data.label,
        isNot(contains('1/3')),
        reason: 'a screen reader reads "1/3" as a date or a fraction glyph',
      );
      expect(
        data.value,
        isEmpty,
        reason: 'the bar\'s "33" was read BEFORE the title on Android',
      );
      expect(
        data.role,
        isNot(SemanticsRole.progressBar),
        reason: 'the row is a list item, not a progress bar',
      );
      handle.dispose();
    });

    testWidgets('a row with NO finished subtask says so — no bare "0"', (
      tester,
    ) async {
      // The reported case: done == 0, i.e. the bar's value is exactly 0.
      final handle = tester.ensureSemantics();
      final data = await pumpRow(tester, subtaskDone: 0, subtaskTotal: 2);

      expect(data.label.split('\n').first, 'ext two (copy)');
      expect(data.label, contains('0 of 2 subtasks complete'));
      expect(data.value, isEmpty);
      expect(data.role, isNot(SemanticsRole.progressBar));
      handle.dispose();
    });

    testWidgets('the other badges stay behind the title and speak words', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final data = await pumpRow(
        tester,
        notes: 'a note about https://example.test/x',
        due: '2026-06-10',
        pendingSync: true,
        subtaskDone: 1,
        subtaskTotal: 2,
      );

      final lines = data.label.split('\n');
      expect(lines.first, 'ext two (copy)');
      expect(lines, containsAllInOrder(<String>['Pending sync', 'Has notes']));
      expect(data.label, contains('1 of 2 subtasks complete'));
      expect(data.value, isEmpty);

      // The link badge and the due segment are their own nodes — they are
      // separately actionable, so a screen reader reaches them on their own.
      // Each must NAME itself; neither may contribute a bare value.
      final link = tester
          .getSemantics(find.byKey(const Key('link-badge')))
          .getSemanticsData();
      expect(link.label, 'Open link');
      expect(link.value, isEmpty);
      final date = tester
          .getSemantics(find.text('5d overdue'))
          .getSemanticsData();
      // The date segment names the DUE DATE in words (#289) — the badge's
      // "5d overdue" is what the eye reads, not what the ear gets.
      expect(date.label, 'Due 5 days ago');
      expect(date.value, isEmpty);
      handle.dispose();
    });

    testWidgets('a row with no subtasks says nothing about subtasks', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final data = await pumpRow(tester);

      expect(data.label, 'ext two (copy)');
      expect(data.label, isNot(contains('subtask')));
      handle.dispose();
    });
  });
}
