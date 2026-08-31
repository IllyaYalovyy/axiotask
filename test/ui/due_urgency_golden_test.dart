// #242 golden: the due-date urgency palette as the user actually sees it — the
// same four rows (overdue / today / tomorrow / no date) in BOTH themes.
//
// The unit and widget tests pin the colour VALUES; only a picture answers the
// question the bug was about: "at a glance, do these four rows say four
// different things?" A future scheme tweak that flattens today back into the
// alarm tone (or tints a future date red) is a byte diff a reviewer has to
// explain — never a silent regression (TESTING.md §"Golden discipline").
//
// Determinism: the clock is pinned to 2026-06-15 for the build AND the settle
// pump (every label and tone is derived from clock.now()), the platform is
// pinned to Linux (no coarse-pointer "⋯"), no row is hovered or focused, and
// no callback that would animate is wired. The snapshot is a pure function of
// the widget tree.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

final _clock = Clock.fixed(DateTime(2026, 6, 15, 12));

Widget _row(String title, String? due) => TaskRow(
  title: title,
  completed: false,
  due: due,
  onOpen: () {},
  onToggle: () {},
  onRename: (_) {},
  onPickDate: () {},
);

// A FIXED MediaQuery: alchemist resizes the test surface after `pumpBeforeTest`
// and pumps one more frame OUTSIDE the pinned-clock zone. Pinning the media
// data means that resize changes nothing this subtree depends on, so no row
// rebuilds against the wall clock and the labels stay the fixed-date ones.
Widget _rows(ThemeData theme, Size size) => MediaQuery(
  data: MediaQueryData(size: size),
  child: Theme(
    data: theme.copyWith(platform: TargetPlatform.linux),
    child: Builder(
      builder: (context) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _row('Pay the invoice', '2026-06-10'),
            _row('Write the stand-up notes', '2026-06-15'),
            _row('Ship the release', '2026-06-16'),
            _row('Someday, maybe', null),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  // Sized to the rows' natural height in the TEST font (which measures far
  // wider than the production font — see the widget-test-font memory), so
  // nothing overflows or ellipsizes in the snapshot.
  const size = Size(640, 300);

  for (final entry in {
    'light': buildLightTheme(),
    'dark': buildDarkTheme(),
  }.entries) {
    goldenTest(
      'due urgency rows — ${entry.key}',
      fileName: 'due_urgency_rows_${entry.key}',
      pumpWidget: (tester, widget) =>
          withClock(_clock, () => tester.pumpWidget(widget)),
      // A bounded settle: a TaskRow carries no running animation at rest, and
      // pumpAndSettle would spin on any implicit one rather than fail loudly.
      pumpBeforeTest: (tester) =>
          withClock(_clock, () => tester.pump(const Duration(seconds: 1))),
      builder: () => GoldenTestGroup(
        children: [
          GoldenTestScenario(
            name: '${entry.key}: overdue / today / tomorrow / no date',
            constraints: BoxConstraints.tight(size),
            child: _rows(entry.value, size),
          ),
        ],
      ),
    );
  }
}
