// Collapsed-state goldens for the detail-aware breakpoint (G9 #208).
//
// The shell_golden goldens pin the two form factors with NO detail open. These
// pin the layout G9 adds: what a mid-width window does WHEN A DETAIL IS OPEN.
//
//   • collapsed (800dp): below detailBreakpoint the detail takes the FULL
//     screen through the compact layout — no sidebar, no crushed three-pane row.
//   • side-by-side (860dp): at/above detailBreakpoint the list + detail sit
//     together, and a long subtask title ellipsizes rather than shoving the
//     row's fixed arrows/date off the edge.
//
// Determinism: no due dates anywhere, so nothing reads the clock
// (dueUrgency/formatDue never fire); every field is unfocused, so there is no
// cursor-blink timer. The snapshot is a pure function of the tree.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:axiotask/src/ui/task_detail.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

StoredTask _task(String id, String title, String position, {String? parent}) =>
    StoredTask(
      task: Task(
        id: id,
        parent: parent,
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
  _task('A', 'Plan the offsite agenda and logistics for the whole team', '1'),
  _task('B', 'Review the pull request', '2'),
  _task(
    'A1',
    'Book a venue that fits everyone and has decent A/V for the demos',
    '1',
    parent: 'A',
  ),
  _task('A2', 'Send calendar invites to the extended group', '2', parent: 'A'),
];

const _myTasks = StoredTaskList(
  list: TaskList(id: 'L1', title: 'My Tasks', etag: 'e1', updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

/// The real shell at [size] with task 'A' open in the REAL detail pane — the
/// widget each collapsed-state golden captures.
Widget _shellWithDetail(Size size) => MediaQuery(
  data: MediaQueryData(size: size),
  child: ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(const Prefs()),
      allTasksProvider.overrideWith((ref) => Stream.value(_seedTasks)),
      listsProvider.overrideWith((ref) => Stream.value(const [_myTasks])),
    ],
    child: Theme(
      data: buildLightTheme().copyWith(platform: TargetPlatform.linux),
      child: ListDetailScaffold(
        sidebar: Sidebar(
          selectedViewId: SmartView.all.id,
          counts: const {'all': 2, 'L1': 2},
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
        title: 'All Tasks',
        list: TaskListView(
          viewId: SmartView.all.id,
          selectedTaskId: 'A',
          onOpenTask: (_) {},
        ),
        detail: const TaskDetail(
          taskId: 'A',
          onClose: _noop,
          onOpenTask: _noopStr,
        ),
        onCloseDetail: () {},
      ),
    ),
  ),
);

void _noop() {}
void _noopStr(String _) {}

void main() {
  // Below detailBreakpoint (840): the open detail collapses to full-screen.
  const collapsed = Size(800, 800);
  // At detailBreakpoint: the narrowest side-by-side layout.
  const sideBySide = Size(860, 800);

  goldenTest(
    'narrow layout — detail open collapses to full-screen (< 840dp)',
    fileName: 'narrow_collapsed_detail',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'collapsed',
          constraints: BoxConstraints.tight(collapsed),
          child: _shellWithDetail(collapsed),
        ),
      ],
    ),
  );

  goldenTest(
    'narrow layout — list + detail side by side at detailBreakpoint',
    fileName: 'narrow_side_by_side_detail',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'side-by-side',
          constraints: BoxConstraints.tight(sideBySide),
          child: _shellWithDetail(sideBySide),
        ),
      ],
    ),
  );
}
