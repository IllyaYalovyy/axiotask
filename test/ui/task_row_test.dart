// TaskWidget [non-touch] (MIGRATION-PLAN §5 T7.2). Protects the complete
// desktop task row: the T2.3 basics (body-tap opens, checkbox toggles WITHOUT
// opening, double-tap renames) plus the T7.2 metadata line (notes badge,
// pending-sync dot, due / inherited / "no date" segment, subtask progress) and
// the completion fade. Every assertion is on the rendered tree / the callback a
// gesture actually fires — never "a method was called".

import 'package:axiotask/src/ui/task_row.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bounded pump — `pumpAndSettle` hangs on a focused TextField's blinking-cursor
/// animation, so we pump one frame past the double-tap window instead.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    String title = 'buy milk',
    String? notes,
    bool completed = false,
    String? due,
    String? inheritedDue,
    bool pendingSync = false,
    int subtaskDone = 0,
    int subtaskTotal = 0,
    String? listTag,
    List<String>? opened,
    List<String>? toggled,
    List<String>? renamed,
    List<String>? picked,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskRow(
            title: title,
            notes: notes,
            completed: completed,
            due: due,
            inheritedDue: inheritedDue,
            pendingSync: pendingSync,
            subtaskDone: subtaskDone,
            subtaskTotal: subtaskTotal,
            listTag: listTag,
            onOpen: () => opened?.add(title),
            onToggle: () => toggled?.add(title),
            onRename: (v) => renamed?.add(v),
            onPickDate: picked == null ? null : () => picked.add(title),
          ),
        ),
      ),
    );
  }

  group('basics (T2.3)', () {
    testWidgets('renders the title (and "Untitled" when blank)', (
      tester,
    ) async {
      await pumpRow(tester, title: '');
      expect(find.text('Untitled'), findsOneWidget);
    });

    testWidgets('a body tap opens the detail', (tester) async {
      final opened = <String>[];
      await pumpRow(tester, opened: opened);
      await tester.tap(find.text('buy milk'));
      await settle(tester);
      expect(opened, ['buy milk']);
    });

    testWidgets('a checkbox tap toggles and does NOT open the detail', (
      tester,
    ) async {
      final opened = <String>[];
      final toggled = <String>[];
      await pumpRow(tester, opened: opened, toggled: toggled);
      await tester.tap(find.byType(Checkbox));
      await settle(tester);
      expect(toggled, ['buy milk']);
      expect(opened, isEmpty, reason: 'checkbox must not open the detail');
    });

    testWidgets('double-tap the title to rename inline; submit commits', (
      tester,
    ) async {
      final renamed = <String>[];
      await pumpRow(tester, renamed: renamed);

      await tester.tap(find.text('buy milk'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('buy milk'));
      await settle(tester);

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'buy oat milk');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      expect(renamed, ['buy oat milk']);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('an unchanged/empty inline title does not rename', (
      tester,
    ) async {
      final renamed = <String>[];
      await pumpRow(tester, renamed: renamed);

      await tester.tap(find.text('buy milk'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('buy milk'));
      await settle(tester);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      expect(renamed, isEmpty);
    });
  });

  group('completion (T7.2)', () {
    testWidgets('a completed task strikes through its title', (tester) async {
      await pumpRow(tester, completed: true);
      final text = tester.widget<Text>(find.text('buy milk'));
      expect(text.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('completion fades and shrinks the row; an open task does not', (
      tester,
    ) async {
      await pumpRow(tester, completed: true);
      final fade = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(fade.opacity, 0.5, reason: 'completed rows are dimmed');
      expect(scale.scale, lessThan(1.0), reason: 'completed rows shrink');

      await pumpRow(tester, completed: false);
      final fade2 = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(fade2.opacity, 1.0, reason: 'open rows are at full opacity');
    });
  });

  group('metadata line (T7.2)', () {
    testWidgets('a notes badge shows only when the task has notes', (
      tester,
    ) async {
      await pumpRow(tester);
      expect(find.byKey(const Key('notes-badge')), findsNothing);

      await pumpRow(tester, notes: 'remember the receipt');
      expect(find.byKey(const Key('notes-badge')), findsOneWidget);
    });

    testWidgets('the pending-sync dot shows only for a dirty row', (
      tester,
    ) async {
      await pumpRow(tester);
      expect(find.byKey(const Key('pending-dot')), findsNothing);

      await pumpRow(tester, pendingSync: true);
      expect(find.byKey(const Key('pending-dot')), findsOneWidget);
    });

    testWidgets('subtask progress renders "done/total" only when there are '
        'subtasks', (tester) async {
      await pumpRow(tester);
      expect(find.text('0/0'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);

      await pumpRow(tester, subtaskDone: 2, subtaskTotal: 5);
      expect(find.text('2/5'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.4, 1e-9));
    });

    testWidgets('a list tag renders when provided', (tester) async {
      await pumpRow(tester, listTag: 'Groceries');
      expect(find.text('Groceries'), findsOneWidget);
    });
  });

  group('due segment (T7.2)', () {
    testWidgets('with no date renders "no date"', (tester) async {
      await pumpRow(tester);
      expect(find.text('no date'), findsOneWidget);
    });

    testWidgets('renders a friendly due label (never the raw ISO)', (
      tester,
    ) async {
      await withClock(Clock.fixed(DateTime(2026, 6, 15)), () async {
        await pumpRow(tester, due: '2026-06-16T00:00:00.000Z');
        expect(find.text('tomorrow'), findsOneWidget);
        expect(find.text('no date'), findsNothing);
      });
    });

    testWidgets('an overdue own-date is coloured with the error colour', (
      tester,
    ) async {
      await withClock(Clock.fixed(DateTime(2026, 6, 15)), () async {
        await pumpRow(tester, due: '2026-06-10');
        final ctx = tester.element(find.text('5d overdue'));
        final text = tester.widget<Text>(find.text('5d overdue'));
        expect(text.style?.color, Theme.of(ctx).colorScheme.error);
      });
    });

    testWidgets('an inherited date shows the read-only "↳" marker when the '
        'task has no own date', (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 6, 15)), () async {
        await pumpRow(tester, inheritedDue: '2026-06-16');
        expect(find.text('↳ tomorrow'), findsOneWidget);
        expect(find.text('no date'), findsNothing);
      });
    });

    testWidgets('an own date wins over an inherited one', (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 6, 15)), () async {
        await pumpRow(tester, due: '2026-06-15', inheritedDue: '2026-06-16');
        expect(find.text('today'), findsOneWidget);
        expect(find.textContaining('↳'), findsNothing);
      });
    });

    testWidgets('the due segment is tappable ONLY when onPickDate is wired', (
      tester,
    ) async {
      // No handler → plain text, no InkWell wrapping the segment.
      await pumpRow(tester);
      expect(
        find.ancestor(of: find.text('no date'), matching: find.byType(InkWell)),
        findsNothing,
      );

      // With a handler → tapping fires it.
      final picked = <String>[];
      await pumpRow(tester, picked: picked);
      await tester.tap(find.text('no date'));
      await settle(tester);
      expect(picked, ['buy milk']);
    });

    testWidgets('tapping a DATED badge also opens the picker (T7.3)', (
      tester,
    ) async {
      final picked = <String>[];
      await withClock(Clock.fixed(DateTime(2026, 6, 15)), () async {
        await pumpRow(tester, due: '2026-08-01', picked: picked);
        // Absolute short label further out than a week.
        await tester.tap(find.text('Aug 1'));
        await settle(tester);
      });
      expect(picked, ['buy milk']);
    });

    testWidgets('the inherited-date marker is a picker affordance too (T7.3)', (
      tester,
    ) async {
      final picked = <String>[];
      await withClock(Clock.fixed(DateTime(2026, 6, 15)), () async {
        await pumpRow(tester, inheritedDue: '2026-08-01', picked: picked);
        await tester.tap(find.text('↳ Aug 1'));
        await settle(tester);
      });
      expect(picked, ['buy milk']);
    });
  });
}
