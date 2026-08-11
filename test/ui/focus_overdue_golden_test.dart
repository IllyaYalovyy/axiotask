// F17 (#195) golden: the Focus view's "Overdue (N)" headed bucket above the
// dated bucket. Pins the real [TaskListView] in the Focus view fed a mix of
// overdue and in-window tasks, so a regression in the heading (its text, tone,
// or placement) or in the two-bucket order is a byte diff a reviewer must
// explain — never a silent rewrite (TESTING.md §"Golden discipline").
//
// Determinism: the clock is pinned to 2026-06-15 for BOTH the initial pump and
// the settle pump (the render reads clock.now() to place tasks in Focus and to
// decide the overdue split), and the quick-add field is unfocused (no
// cursor-blink timer). The snapshot is a pure function of the widget tree.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

StoredTask _task(
  String id,
  String title, {
  required String? due,
  String pos = '1',
}) => StoredTask(
  task: Task(
    id: id,
    position: pos,
    title: title,
    status: TaskStatus.needsAction,
    due: due == null ? null : '${due}T00:00:00.000Z',
    updated: 't',
  ),
  listId: 'L1',
  syncState: SyncState.clean,
  localUpdated: 't',
);

final _seed = <StoredTask>[
  _task('over1', 'Pay the invoice', due: '2026-06-09', pos: '1'),
  _task('over2', 'Renew the domain', due: '2026-06-13', pos: '2'),
  _task('today', 'Write the stand-up notes', due: '2026-06-15', pos: '3'),
  _task('soon', 'Ship the release', due: '2026-06-18', pos: '4'),
];

const _myTasks = StoredTaskList(
  list: TaskList(id: 'L1', title: 'My Tasks', etag: 'e', updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

Widget _focusList(Size size) => MediaQuery(
  data: MediaQueryData(size: size),
  child: ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(
        const Prefs(sortPerView: {'focus': 'due'}),
      ),
      allTasksProvider.overrideWith((ref) => Stream.value(_seed)),
      listsProvider.overrideWith((ref) => Stream.value(const [_myTasks])),
    ],
    child: Theme(
      // A mouse platform (no per-row "⋯" overflow — F16); the Focus overdue
      // heading is what this golden pins.
      data: buildLightTheme().copyWith(platform: TargetPlatform.linux),
      child: const Scaffold(
        body: TaskListView(
          viewId: 'focus',
          selectedTaskId: null,
          onOpenTask: _noop,
        ),
      ),
    ),
  ),
);

void _noop(String _) {}

void main() {
  const desktop = Size(700, 640);

  goldenTest(
    'focus — Overdue section above the dated bucket',
    fileName: 'focus_overdue',
    // Pin the clock across BOTH the initial build and the settle pump so every
    // clock.now() read (Focus filter + overdue split) sees the fixed today.
    pumpWidget: (tester, widget) =>
        withClock(_clock, () => tester.pumpWidget(widget)),
    pumpBeforeTest: (tester) => withClock(_clock, () => tester.pumpAndSettle()),
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'focus with overdue',
          constraints: BoxConstraints.tight(desktop),
          child: _focusList(desktop),
        ),
      ],
    ),
  );
}
