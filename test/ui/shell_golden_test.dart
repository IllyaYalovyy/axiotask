// Form-factor goldens for the adaptive shell (T2.5 / MIGRATION-PLAN §5).
//
// ListDetailScaffold is the one hand-rolled adaptive layout (no
// flutter_adaptive_scaffold), so its two branches are pinned with pixel
// snapshots at the two form factors the app ships:
//
//   • desktop (≥600dp): the real Sidebar (smart views + lists) beside the list.
//   • phone   (<600dp): the task list (with its sort/show-completed toolbar)
//                       over a bottom NavigationBar.
//
// These are the goldens the plan calls for. They render the REAL shell + the
// REAL All-Tasks list (fed by static provider streams) under the REAL app
// theme, so a regression in the adaptive breakpoint, the nav chrome, the
// quick-add bar, or a task row is a byte diff a reviewer must explain — never a
// silent rewrite (TESTING.md §"Golden discipline").
//
// Determinism: the seeded tasks carry NO due dates, so nothing in the render
// path reads the clock (formatDue(null) == null); the quick-add field is
// unfocused, so there is no cursor-blink timer. The snapshot is a pure function
// of the widget tree.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A clean top-level task with no due date (keeps the golden clock-free).
StoredTask _task(String id, String title, String position) => StoredTask(
  task: Task(
    id: id,
    position: position,
    title: title,
    status: TaskStatus.needsAction,
    updated: 't',
  ),
  listId: 'L1',
  syncState: SyncState.clean,
  localUpdated: 't',
);

final _seedTasks = <StoredTask>[
  _task('A', 'Draft the migration plan', '1'),
  _task('B', 'Review the pull request', '2'),
  _task('C', 'Book the dentist', '3'),
];

const _myTasks = StoredTaskList(
  list: TaskList(id: 'L1', title: 'My Tasks', etag: 'e1', updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

/// The real shell rendered at [size], branded with the real light theme and fed
/// the seeded task list — the widget the golden captures at one form factor.
Widget _shellAt(Size size) {
  return MediaQuery(
    data: MediaQueryData(size: size),
    child: ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(const Prefs()),
        allTasksProvider.overrideWith((ref) => Stream.value(_seedTasks)),
        listsProvider.overrideWith((ref) => Stream.value(const [_myTasks])),
      ],
      child: Theme(
        data: buildLightTheme(),
        child: ListDetailScaffold(
          sidebar: Sidebar(
            selectedViewId: SmartView.all.id,
            counts: const {'all': 3, 'L1': 3},
            lists: const [_myTasks],
            excludedLists: const {},
            onSelectView: (_) {},
            onCreateList: (_, {localOnly = false}) {},
            onRenameList: (_, _) {},
            onDeleteList: (_) {},
            onToggleExclude: (_) {},
            onReorderLists: (_) {},
          ),
          destinations: [
            for (final v in SmartView.values)
              ShellDestination(
                icon: v.icon,
                selectedIcon: v.selectedIcon,
                label: v.label,
              ),
          ],
          selectedIndex: SmartView.all.index,
          onDestinationSelected: (_) {},
          list: TaskListView(
            viewId: SmartView.all.id,
            selectedTaskId: null,
            onOpenTask: (_) {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  const desktop = Size(1000, 700);
  const phone = Size(400, 800);

  goldenTest(
    'shell — desktop form factor (sidebar + list)',
    fileName: 'shell_desktop',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'expanded',
          constraints: BoxConstraints.tight(desktop),
          child: _shellAt(desktop),
        ),
      ],
    ),
  );

  goldenTest(
    'shell — phone form factor (list + bottom nav)',
    fileName: 'shell_phone',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'compact',
          constraints: BoxConstraints.tight(phone),
          child: _shellAt(phone),
        ),
      ],
    ),
  );
}
