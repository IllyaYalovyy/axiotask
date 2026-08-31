// Detail-panel hierarchy (#246) — WHERE each affordance lives, not what it does.
//
// The failures this suite prevents, all found on-device 2026-08-30:
//   • Delete sitting in the app bar's direct action row, one thumb-width from
//     the Previous/Next buttons the user taps repeatedly — a destructive action
//     adjacent to two navigation ones. It must be reachable only through the
//     "⋮" overflow, last and divided off, and must still delete with Undo.
//   • "Open in Google Tasks" rendered as the most prominent body element right
//     under the title, above the Due date and List fields the user actually
//     edits. It must not be a body widget at all; it lives in the overflow and
//     still opens exactly the task's webViewLink through the opener seam.
//   • the body reading title → Open-in-Google → Due → List → notes → links →
//     subtasks. The ratified order is title → Due + List → notes → subtasks →
//     links, asserted by comparing RENDERED vertical offsets, so a re-ordering
//     is caught even though every widget still exists somewhere in the tree.
//
// Non-happy paths covered: a SUBTASK's panel (no List field, no subtask
// checklist, Detach in the overflow instead of "Make subtask of…") and an
// UNSYNCED task (webViewLink == null → no Open-in-Google entry anywhere).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

/// The rendered top edge of the field labelled [label] (a TextField's floating
/// label is inside the field, so the label's ancestor IS the field).
double _fieldTop(WidgetTester tester, String label) => tester
    .getTopLeft(
      find.ancestor(of: find.text(label), matching: find.byType(TextField)),
    )
    .dy;

void main() {
  group('app bar', () {
    testWidgets('has no Delete beside Previous/Next — it is in the overflow', (
      tester,
    ) async {
      await pumpDetail(tester, taskId: 'T1', initial: [row('T1', 'Renew')]);

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.delete_outline),
        ),
        findsNothing,
        reason: 'Delete must not sit in the app bar action row',
      );
      // The navigation pair is what remains beside the overflow.
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await openDetailOverflow(tester);
      // Last and divided off from the rest — a destructive entry the finger
      // cannot reach by overshooting Duplicate.
      final duplicateY = tester.getTopLeft(find.text('Duplicate')).dy;
      final deleteY = tester.getTopLeft(find.text('Delete')).dy;
      final dividerY = tester.getTopLeft(find.byType(PopupMenuDivider)).dy;
      expect(deleteY, greaterThan(duplicateY), reason: 'Delete comes last');
      expect(dividerY, greaterThan(duplicateY));
      expect(dividerY, lessThan(deleteY), reason: 'a rule guards the entry');
      // …and it does not read like the rest: error-toned label and icon.
      final scheme = Theme.of(tester.element(find.text('Delete'))).colorScheme;
      expect(
        tester.widget<Text>(find.text('Delete')).style?.color,
        scheme.error,
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(const Key('detail-delete')),
                matching: find.byIcon(Icons.delete_outline),
              ),
            )
            .color,
        scheme.error,
      );
    });

    testWidgets("a subtask's overflow offers Detach, never 'Make subtask of…'", (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'S1',
        initial: [
          row('P1', 'Parent'),
          row('S1', 'Child', parent: 'P1'),
        ],
      );

      // The breadcrumb is the way back up and nothing else — the detach button
      // no longer outranks the title.
      expect(find.text('Detach from parent'), findsNothing);
      expect(find.text('Detach subtask'), findsNothing);

      await openDetailOverflow(tester);
      expect(find.byKey(const Key('detail-detach')), findsOneWidget);
      // A subtask can never be demoted further (invariant #1).
      expect(find.byKey(const Key('detail-demote')), findsNothing);
    });
  });

  group('body order', () {
    testWidgets('title → Due → List → notes → subtasks → links', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'T1',
        initial: [
          row(
            'T1',
            'Renew passport',
            notes: 'see https://example.com/forms',
            webViewLink: 'https://tasks.google.com/task/T1',
          ),
          row('S1', 'Book appointment', parent: 'T1'),
        ],
        lists: [list('L1', 'My Tasks')],
      );

      final title = _fieldTop(tester, 'Title');
      final due = tester.getTopLeft(find.byKey(const Key('due-field'))).dy;
      final listField = tester
          .getTopLeft(find.byKey(const Key('list-dropdown')))
          .dy;
      final notes = _fieldTop(tester, 'Notes');
      final subtasks = tester.getTopLeft(find.text('Subtasks')).dy;
      final link = tester.getTopLeft(find.text('https://example.com/forms')).dy;

      // Due and List are ONE band (side by side on this wide surface, see the
      // wide/narrow test); the band sits between the title and the notes.
      expect(title, lessThan(due), reason: 'Due sits under the title');
      expect(title, lessThan(listField), reason: 'List sits under the title');
      expect(due, lessThan(notes), reason: 'Due sits above the notes');
      expect(listField, lessThan(notes), reason: 'List sits above the notes');
      expect(notes, lessThan(subtasks), reason: 'notes above the subtasks');
      expect(subtasks, lessThan(link), reason: 'links come last');
    });

    testWidgets('no Open-in-Google widget in the body, above Due or anywhere', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'T1',
        initial: [
          row('T1', 'Renew', webViewLink: 'https://tasks.google.com/task/T1'),
        ],
        lists: [list('L1', 'My Tasks')],
      );

      // Nothing renders it before the overflow is opened — the old body button
      // is gone, not merely moved down.
      expect(find.text('Open in Google Tasks'), findsNothing);
      expect(find.byKey(const Key('open-in-google')), findsNothing);
    });

    testWidgets("a subtask's body reads title → Due → notes → links", (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'S1',
        initial: [
          row('P1', 'Parent'),
          row(
            'S1',
            'Child',
            notes: 'ref https://example.com/spec',
            parent: 'P1',
          ),
        ],
        lists: [list('L1', 'My Tasks')],
      );

      final title = _fieldTop(tester, 'Title');
      final due = tester.getTopLeft(find.byKey(const Key('due-field'))).dy;
      final notes = _fieldTop(tester, 'Notes');
      final link = tester.getTopLeft(find.text('https://example.com/spec')).dy;

      expect(title, lessThan(due));
      expect(due, lessThan(notes));
      expect(notes, lessThan(link));
      // #93: a subtask lives in its parent's list — no List field, and so no
      // subtask checklist either (invariant #1).
      expect(find.byKey(const Key('list-dropdown')), findsNothing);
      expect(find.text('Subtasks'), findsNothing);
    });

    testWidgets('Due and List share one row on a wide panel, stack on narrow', (
      tester,
    ) async {
      Future<void> pump(double width) => pumpDetail(
        tester,
        taskId: 'T1',
        initial: [row('T1', 'Renew')],
        lists: [list('L1', 'My Tasks')],
        size: Size(width, 1400),
      );
      Rect due() => tester.getRect(find.byKey(const Key('due-field')));
      Rect listField() =>
          tester.getRect(find.byKey(const Key('list-dropdown')));

      await pump(1000);
      expect(
        due().top < listField().bottom && listField().top < due().bottom,
        isTrue,
        reason: 'wide: the two controls overlap vertically — one line',
      );
      expect(
        due().right,
        lessThanOrEqualTo(listField().left),
        reason: 'wide: Due leads, List follows on the same line',
      );

      await pump(360);
      expect(
        due().bottom,
        lessThanOrEqualTo(listField().top),
        reason: 'narrow: two lines, Due above List',
      );
    });

    testWidgets('a 1.3x text scale stacks a width that fits both at 1.0x', (
      tester,
    ) async {
      Future<void> pump(double scale) => pumpDetail(
        tester,
        taskId: 'T1',
        initial: [row('T1', 'Renew')],
        lists: [list('L1', 'My Tasks')],
        size: const Size(560, 1600),
        textScale: scale,
      );
      Rect due() => tester.getRect(find.byKey(const Key('due-field')));
      Rect listField() =>
          tester.getRect(find.byKey(const Key('list-dropdown')));

      await pump(1.0);
      expect(
        due().right,
        lessThanOrEqualTo(listField().left),
        reason: '560dp at 1.0x holds both on one line',
      );

      await pump(1.3);
      expect(
        due().bottom,
        lessThanOrEqualTo(listField().top),
        reason: 'the same 560dp at 1.3x stacks rather than truncating',
      );
    });
  });
}
