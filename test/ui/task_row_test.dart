// TaskWidget [non-touch] (MIGRATION-PLAN §5 T7.2). Protects the complete
// desktop task row: the T2.3 basics (body-tap opens, checkbox toggles WITHOUT
// opening, double-tap renames) plus the T7.2 metadata line (notes badge,
// pending-sync dot, due / inherited / "no date" segment, subtask progress) and
// the completion fade. Every assertion is on the rendered tree / the callback a
// gesture actually fires — never "a method was called".
//
// The row's MEASURED geometry — the pitch, the title→meta gap, where the
// checkbox and the list label sit — lives in `task_row_layout_test.dart`
// (#276), which superseded the "touch row density" group that used to close
// this file (its ≤76dp touch row / ≤68dp desktop row are now one 72dp pitch).

import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/task_row_parts.dart';
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
    List<String>? openedUrl,
    TargetPlatform? platform,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
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
            onOpenUrl: openedUrl?.add,
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
      // Double-tap-to-rename is a DESKTOP affordance (F19 #198); pin the mouse
      // platform where it lives.
      await pumpRow(tester, renamed: renamed, platform: TargetPlatform.linux);

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
      await pumpRow(tester, renamed: renamed, platform: TargetPlatform.linux);

      await tester.tap(find.text('buy milk'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('buy milk'));
      await settle(tester);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      expect(renamed, isEmpty);
    });

    testWidgets(
      'on a touch pointer a double-tap does NOT rename — and the FIRST tap '
      'opens immediately (F19 #198: no double-tap delay on the open gesture)',
      (tester) async {
        // The failure this prevents: onDoubleTap left on the row title makes
        // every touch open-tap wait out the ~300ms double-tap window before it
        // fires — a sluggish tap-to-open on the primary mobile gesture. On a
        // coarse pointer the row must have NO double-tap recognizer, so a single
        // tap opens with no delay and a second tap never enters inline rename.
        final opened = <String>[];
        final renamed = <String>[];
        await pumpRow(
          tester,
          opened: opened,
          renamed: renamed,
          platform: TargetPlatform.android,
        );

        // A single tap opens the detail without any pump past a double-tap gap.
        await tester.tap(find.text('buy milk'));
        await tester.pump();
        expect(opened, ['buy milk'], reason: 'open-tap fires immediately');

        // A second tap after the double-tap window never opens the rename editor.
        await tester.tap(find.text('buy milk'));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(find.text('buy milk'));
        await settle(tester);
        expect(
          find.byType(TextField),
          findsNothing,
          reason: 'touch has no double-tap-to-rename',
        );
        expect(renamed, isEmpty);
      },
    );
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
      // Standing alone (no CompletionMotion around it — #241) a row simply
      // wears the resting look for its state.
      await pumpRow(tester, completed: true);
      final fade = tester.widget<FadeTransition>(
        find.byKey(const Key('row-completion-fade')),
      );
      final scale = tester.widget<ScaleTransition>(
        find
            .descendant(
              of: find.byKey(const Key('row-completion-fade')),
              matching: find.byType(ScaleTransition),
            )
            .first,
      );
      expect(fade.opacity.value, 0.5, reason: 'completed rows are dimmed');
      expect(scale.scale.value, lessThan(1.0), reason: 'completed rows shrink');

      await pumpRow(tester, completed: false);
      final fade2 = tester.widget<FadeTransition>(
        find.byKey(const Key('row-completion-fade')),
      );
      expect(fade2.opacity.value, 1.0, reason: 'open rows are at full opacity');
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
      // No handler → plain text, no tap surface of its own around the segment.
      // (The ROW is one tap surface either way — this asserts the segment does
      // not become a second, dead one.)
      await pumpRow(tester);
      expect(find.byKey(const Key('row-due-segment')), findsNothing);

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

  group('metadata badge touch targets (F19 #198, resized by #276)', () {
    // The tap target for the metadata badges (the due segment, the link badge)
    // is the tap surface wrapping the glyph. On a touch pointer it must be big
    // enough for a finger — the whole meta band, [kTouchMetaBand] tall and
    // ≥48dp wide, which is every dp the row's 72dp two-line pitch leaves under
    // the title (a 48dp-tall badge would make the row 100dp — see
    // [metaTouchTarget]). On a mouse it stays compact (the desktop row is
    // dense — the vision's standard).
    double dueSegmentHeight(WidgetTester tester) =>
        tester.getSize(find.byKey(const Key('row-due-segment'))).height;

    testWidgets('the due segment fills the meta band on a touch pointer', (
      tester,
    ) async {
      await pumpRow(
        tester,
        picked: <String>[],
        platform: TargetPlatform.android,
      );
      expect(dueSegmentHeight(tester), greaterThanOrEqualTo(kTouchMetaBand));
      expect(
        tester.getSize(find.byKey(const Key('row-due-segment'))).width,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('the due segment stays compact (<48dp) on a mouse pointer', (
      tester,
    ) async {
      await pumpRow(tester, picked: <String>[], platform: TargetPlatform.linux);
      expect(
        dueSegmentHeight(tester),
        lessThan(48),
        reason: 'the desktop row keeps its dense metadata line',
      );
    });

    testWidgets('the link badge fills the meta band on a touch pointer', (
      tester,
    ) async {
      await pumpRow(
        tester,
        notes: 'see https://example.com for details',
        openedUrl: <String>[],
        platform: TargetPlatform.android,
      );
      final badge = tester.getSize(find.byKey(const Key('link-badge')));
      expect(badge.width, greaterThanOrEqualTo(48));
      expect(badge.height, greaterThanOrEqualTo(kTouchMetaBand));
    });
  });

  group('checkbox precision — complete ONLY from the checkbox (#214)', () {
    // The completion tap target must be the checkbox affordance the user SEES,
    // and every other tap on the row body must do the harmless expected thing
    // (open the detail). Before this contract the checkbox's invisible 48×48
    // box spanned the row's whole leading column (~75% of the desktop row's
    // height), so clicks on what reads as "the record" completed tasks; and
    // parts of the body were dead zones. Precision directive 2026-08-18.

    testWidgets('desktop: a click at the row edge OUTSIDE the checkbox glyph '
        'opens the detail and never completes', (tester) async {
      final toggled = <String>[];
      final opened = <String>[];
      await pumpRow(
        tester,
        toggled: toggled,
        opened: opened,
        platform: TargetPlatform.linux,
      );

      final rect = tester.getRect(find.byKey(const Key('swipe-content')));
      // Inside the OLD invisible 48×48 hit box, outside the compact target.
      await tester.tapAt(rect.topLeft + const Offset(8, 40));
      await tester.pump(const Duration(milliseconds: 400));

      expect(toggled, isEmpty, reason: 'only the checkbox completes');
      expect(opened, ['buy milk'], reason: 'a body tap opens the detail');
    });

    testWidgets('desktop: the checkbox itself still completes', (tester) async {
      final toggled = <String>[];
      await pumpRow(tester, toggled: toggled, platform: TargetPlatform.linux);
      await tester.tap(find.byKey(const Key('row-checkbox-target')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(toggled, ['buy milk']);
    });

    testWidgets('desktop: the checkbox hit target stays compact (<48dp) on a '
        'mouse — same rule as the metadata badges', (tester) async {
      await pumpRow(tester, platform: TargetPlatform.linux);
      final size = tester.getSize(find.byKey(const Key('row-checkbox-target')));
      expect(size.width, lessThan(48));
      expect(size.height, lessThan(48));
    });

    testWidgets('touch: former dead zones open the detail — leading column '
        'below the checkbox and meta-line whitespace', (tester) async {
      final toggled = <String>[];
      final opened = <String>[];
      await pumpRow(
        tester,
        due: '2026-08-01',
        listTag: 'My Tasks',
        toggled: toggled,
        opened: opened,
        picked: <String>[],
        platform: TargetPlatform.android,
      );

      final rect = tester.getRect(find.byKey(const Key('swipe-content')));
      // Leading column BELOW the 48dp checkbox box.
      await tester.tapAt(rect.topLeft + const Offset(24, 60));
      await tester.pump(const Duration(milliseconds: 400));
      // Meta-band whitespace to the right of the badges.
      await tester.tapAt(rect.topLeft + Offset(rect.width * 0.8, 60));
      await tester.pump(const Duration(milliseconds: 400));

      expect(toggled, isEmpty);
      expect(opened, [
        'buy milk',
        'buy milk',
      ], reason: 'every non-control tap on the row opens the detail');
    });
  });
}
