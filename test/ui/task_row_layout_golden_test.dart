// #276 goldens: the task row's layout pass, as the user sees it.
//
// The measurements live in `task_row_layout_test.dart`; only a picture answers
// the question the issue was actually about — "does a row read as ONE object,
// and does the list read as a column rather than as fourteen floating meta
// lines?" Three cases, because the row has three shapes to get wrong:
//
//   • a smart view on a phone (the screenshot the complaint came from): every
//     row carries a list label at the trailing edge,
//   • a concrete list on a phone: the trailing slot is empty and nothing else
//     moves — same pitch, same alignment,
//   • the desktop list: the same rules with the mouse's compact controls.
//
// …plus the same phone rows at 1.3x text scale, where the pitch is allowed to
// grow but nothing may overflow or fall off the line.
//
// Determinism: the clock is pinned to 2026-06-15 for the build AND the settle
// pump (every label and tone is derived from clock.now()), the platform is
// pinned per scenario, the media data is fixed (alchemist resizes the surface
// after `pumpBeforeTest` and pumps once more OUTSIDE the pinned-clock zone), no
// row is hovered, focused or selected, and no animation is running at rest.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

final _clock = Clock.fixed(DateTime(2026, 6, 15, 12));

/// One row per shape the meta line can take: a plain overdue task, a task due
/// today with notes and a link, a task with subtask progress, an undated one
/// (whose "no date" is still the date button), and a long title that has to
/// ellipsise against a long list label.
Widget _rows({required bool labels}) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    TaskRow(
      title: 'Pay the invoice',
      completed: false,
      due: '2026-06-10',
      listTag: labels ? 'Work' : null,
      onOpen: () {},
      onToggle: () {},
      onRename: (_) {},
      onPickDate: () {},
    ),
    TaskRow(
      title: 'Read the brief',
      notes: 'see https://example.test/brief',
      completed: false,
      due: '2026-06-15',
      listTag: labels ? 'My Tasks' : null,
      onOpen: () {},
      onToggle: () {},
      onRename: (_) {},
      onPickDate: () {},
      onOpenUrl: (_) {},
    ),
    TaskRow(
      title: 'Plan the trip',
      completed: false,
      due: '2026-06-20',
      subtaskDone: 2,
      subtaskTotal: 5,
      listTag: labels ? 'Personal' : null,
      onOpen: () {},
      onToggle: () {},
      onRename: (_) {},
      onPickDate: () {},
    ),
    TaskRow(
      title: 'Someday, maybe',
      completed: false,
      pendingSync: true,
      listTag: labels ? 'Personal' : null,
      onOpen: () {},
      onToggle: () {},
      onRename: (_) {},
      onPickDate: () {},
    ),
    TaskRow(
      title: 'A title long enough that it has to ellipsise',
      completed: false,
      due: '2026-06-16',
      listTag: labels ? 'Quarterly planning' : null,
      onOpen: () {},
      onToggle: () {},
      onRename: (_) {},
      onPickDate: () {},
    ),
  ],
);

Widget _case(
  ThemeData theme,
  Size size, {
  required TargetPlatform platform,
  required bool labels,
  double textScale = 1.0,
}) => MediaQuery(
  data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
  child: Theme(
    data: theme.copyWith(platform: platform),
    child: Builder(
      builder: (context) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: _rows(labels: labels),
      ),
    ),
  ),
);

void main() {
  // The test font measures roughly twice the width of the real one (this
  // package declares no fonts), so the phone cases run at a generous width:
  // 480dp here is about a 360dp phone's worth of glyphs.
  const phone = Size(480, 380);
  const phoneScaled = Size(480, 440);
  const desktop = Size(640, 380);

  for (final entry in {
    'light': buildLightTheme(),
    'dark': buildDarkTheme(),
  }.entries) {
    goldenTest(
      'task row layout — ${entry.key}',
      fileName: 'task_row_layout_${entry.key}',
      pumpWidget: (tester, widget) =>
          withClock(_clock, () => tester.pumpWidget(widget)),
      // A bounded settle: a TaskRow carries no running animation at rest, and
      // pumpAndSettle would spin on any implicit one rather than fail loudly.
      pumpBeforeTest: (tester) =>
          withClock(_clock, () => tester.pump(const Duration(seconds: 1))),
      builder: () => GoldenTestGroup(
        columns: 2,
        children: [
          GoldenTestScenario(
            name: '${entry.key}: smart view, phone (list label trailing)',
            constraints: BoxConstraints.tight(phone),
            child: _case(
              entry.value,
              phone,
              platform: TargetPlatform.android,
              labels: true,
            ),
          ),
          GoldenTestScenario(
            name: '${entry.key}: concrete list, phone (no label)',
            constraints: BoxConstraints.tight(phone),
            child: _case(
              entry.value,
              phone,
              platform: TargetPlatform.android,
              labels: false,
            ),
          ),
          GoldenTestScenario(
            name: '${entry.key}: desktop list',
            constraints: BoxConstraints.tight(desktop),
            child: _case(
              entry.value,
              desktop,
              platform: TargetPlatform.linux,
              labels: true,
            ),
          ),
          GoldenTestScenario(
            name: '${entry.key}: phone at 1.3x text scale',
            constraints: BoxConstraints.tight(phoneScaled),
            child: _case(
              entry.value,
              phoneScaled,
              platform: TargetPlatform.android,
              labels: true,
              textScale: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}
