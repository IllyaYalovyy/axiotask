// #289 — what a screen reader says when it lands on the row's QUICK-DATE
// control (and on the link badge beside it).
//
// The failure this bars: the due / "no date" segment IS the row's quick-date
// button (#243) on every pointer, but its semantics node carried only the
// label a sighted user reads and no role —
//
//     SemanticsNode#7  actions: focus, tap  label: "5d overdue"
//
// so TalkBack said "5d overdue, double tap to activate": nothing named it a
// control, and nothing said WHAT was overdue. A sighted user gets that from
// position (under the title, beside the notes icon); a screen reader got
// nothing. The [StateLayer] wrapper the segment is built on is an [InkWell],
// which publishes a tap action but never the button flag, so every affordance
// built on it had the same gap — the link badge included.
//
// Two things are asserted here, on the RENDERED semantics tree:
//
//   • the button ROLE, so the control announces as one; and
//   • a label that names the DUE DATE in words a screen reader can say —
//     "Due 5 days ago", not "5d overdue" ("5d" is not a word, and a bare
//     relative phrase names nothing). Same reasoning as #287's "1 of 3
//     subtasks complete".
//
// Determinism: the clock is pinned (every date label is relative to "now"),
// and nothing here animates at rest.

import 'package:axiotask/src/ui/task_row.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

final _clock = Clock.fixed(DateTime(2026, 6, 15, 12));

/// Every STOP a screen reader announces as a BUTTON: a semantics node that
/// carries the button role and is not merged up into an ancestor (a merged-up
/// node is part of its parent's announcement, never its own).
List<SemanticsData> _buttons(WidgetTester tester) {
  final found = <SemanticsData>[];
  void visit(SemanticsNode node) {
    if (!node.isMergedIntoParent) {
      final data = node.getSemanticsData();
      if (data.flagsCollection.isButton) found.add(data);
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.binding.rootElement!.renderObject!.debugSemantics!);
  return found;
}

/// The usage hint a screen reader reads in place of "double tap to activate".
///
/// An `onTapHint` does NOT land in [SemanticsData.hint]: it reaches the
/// platform as the LABEL OF THE CLICK ACTION (Android's
/// `BaseRoleConfigurator.configureTappable`), which is the point — a plain
/// `hint` is folded into the node's content description
/// (`AccessibilityBridge.getValueLabelHint`), so it would become part of the
/// control's NAME on every announcement.
String? _tapHint(SemanticsData data) {
  for (final id in data.customSemanticsActionIds ?? const <int>[]) {
    final action = CustomSemanticsAction.getAction(id);
    if (action?.action == SemanticsAction.tap) return action?.hint;
  }
  return null;
}

/// The one button that is the date segment — the link badge is the only other
/// button any of these rows builds, and it names itself.
SemanticsData _dateButton(WidgetTester tester) {
  final buttons = _buttons(
    tester,
  ).where((b) => !b.label.startsWith('Open link')).toList();
  expect(buttons, hasLength(1), reason: 'the date segment is a button');
  return buttons.single;
}

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    String? due,
    String? inheritedDue,
    String? notes,
    bool dateWired = true,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    await withClock(_clock, () async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: TaskRow(
              title: 'buy milk',
              completed: false,
              due: due,
              inheritedDue: inheritedDue,
              notes: notes,
              onOpen: () {},
              onToggle: () {},
              onRename: (_) {},
              onSetDue: dateWired ? (_) {} : null,
              onPickDate: dateWired ? () {} : null,
              onOpenUrl: (_) {},
            ),
          ),
        ),
      );
    });
  }

  group('the row date segment announces as a button (#289)', () {
    testWidgets('an overdue row: "Due 5 days ago", not "5d overdue"', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpRow(tester, due: '2026-06-10T00:00:00.000Z');

      final button = _dateButton(tester);
      expect(
        button.label,
        'Due 5 days ago',
        reason: 'the node said only what the eye reads: "5d overdue"',
      );
      expect(_tapHint(button), 'open the date options');
      expect(
        button.hint,
        isEmpty,
        reason: 'a plain hint would become part of the control\'s NAME',
      );
      expect(
        button.hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'naming the segment must not cost it its tap',
      );
      handle.dispose();
    });

    testWidgets('the near-today words are spoken as-is', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpRow(tester, due: '2026-06-15T00:00:00.000Z');
      expect(_dateButton(tester).label, 'Due today');

      await pumpRow(tester, due: '2026-06-16T00:00:00.000Z');
      expect(_dateButton(tester).label, 'Due tomorrow');

      await pumpRow(tester, due: '2026-06-14T00:00:00.000Z');
      expect(_dateButton(tester).label, 'Due yesterday');

      await pumpRow(tester, due: '2026-06-18T00:00:00.000Z');
      expect(
        _dateButton(tester).label,
        'Due in 3 days',
        reason: '"in 3d" is not a sentence',
      );

      await pumpRow(tester, due: '2026-07-04T00:00:00.000Z');
      expect(_dateButton(tester).label, 'Due Jul 4');
      handle.dispose();
    });

    testWidgets('an UNDATED row still names the field it would set', (
      tester,
    ) async {
      // Non-happy path: "no date" is a button by user ruling — it is how an
      // undated task gets a date without opening the detail panel.
      final handle = tester.ensureSemantics();
      await pumpRow(tester);

      final button = _dateButton(tester);
      expect(
        button.label,
        'No due date',
        reason: 'the node said "no date", which names nothing',
      );
      expect(_tapHint(button), 'open the date options');
      handle.dispose();
    });

    testWidgets('a borrowed subtask date says whose date it is', (
      tester,
    ) async {
      // The "↳" marker: the task has no date of its own, and the arrow glyph
      // is silent to a screen reader.
      final handle = tester.ensureSemantics();
      await pumpRow(tester, inheritedDue: '2026-06-18T00:00:00.000Z');

      expect(
        _dateButton(tester).label,
        'No due date, earliest subtask due in 3 days',
      );
      handle.dispose();
    });

    testWidgets('on a MOUSE it is the same button', (tester) async {
      // The compact desktop segment is the other of the two hit targets.
      final handle = tester.ensureSemantics();
      await pumpRow(
        tester,
        due: '2026-06-15T00:00:00.000Z',
        platform: TargetPlatform.linux,
      );

      expect(_dateButton(tester).label, 'Due today');
      handle.dispose();
    });

    testWidgets('with only the calendar wired the hint names the calendar', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await withClock(_clock, () async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: Scaffold(
              body: TaskRow(
                title: 'buy milk',
                completed: false,
                due: '2026-06-15T00:00:00.000Z',
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

      final button = _dateButton(tester);
      expect(button.label, 'Due today');
      expect(_tapHint(button), 'open the calendar');
      handle.dispose();
    });

    testWidgets('a row that cannot set a date has no button at all', (
      tester,
    ) async {
      // Non-happy path: with neither callback the segment is plain text, and
      // a button role there would announce an affordance that does nothing.
      final handle = tester.ensureSemantics();
      await pumpRow(tester, due: '2026-06-10T00:00:00.000Z', dateWired: false);

      expect(_buttons(tester), isEmpty);
      expect(find.text('5d overdue'), findsOneWidget);
      handle.dispose();
    });
  });

  group('the link badge announces as a button (#289)', () {
    testWidgets('it carries the role, its name and the URL', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpRow(
        tester,
        due: '2026-06-15T00:00:00.000Z',
        notes: 'see https://example.com',
      );

      final badge = _buttons(
        tester,
      ).where((b) => b.label.startsWith('Open link')).toList();
      expect(badge, hasLength(1), reason: 'the badge was a bare tap action');
      expect(badge.single.label, 'Open link');
      expect(badge.single.tooltip, 'https://example.com');
      expect(badge.single.hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  });
}
