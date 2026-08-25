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

/// The real shell rendered at [size] under [textScaler] and [theme], fed the
/// seeded task list — the widget the golden captures at one form factor.
/// [textScaler] drives the accessibility text-scale goldens (1.3 / 2.0): the
/// mobile chrome must reflow, never overflow, when the system font is enlarged
/// (MIGRATION-PLAN §5 T8.3 / §6 "text-scale 1.3"). [theme] drives the dark-mode
/// goldens (§6 "goldens green … both themes"): the same shell is pinned in both
/// brightnesses so a regression in either theme's surfaces/contrast is a byte
/// diff a reviewer must explain, never a silent rewrite.
/// [listView] renders the shell on a LIST opened from the drawer instead of on
/// a smart view: the list is not one of the bottom-nav destinations, so the bar
/// must come up with no destination highlighted at all (#236).
Widget _shellAt(
  Size size, {
  TextScaler textScaler = TextScaler.noScaling,
  ThemeData? theme,
  TargetPlatform platform = TargetPlatform.android,
  bool listView = false,
}) {
  return MediaQuery(
    data: MediaQueryData(size: size, textScaler: textScaler),
    child: ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(const Prefs()),
        allTasksProvider.overrideWith((ref) => Stream.value(_seedTasks)),
        listsProvider.overrideWith((ref) => Stream.value(const [_myTasks])),
      ],
      child: Theme(
        // The per-row "⋯" overflow is pointer-gated, not width-gated (F16 #194):
        // the desktop form factor is a mouse platform (no overflow — right-click
        // instead), the phone form factor a touch platform (overflow shown). The
        // goldens pin each factor on its real platform so the surface is correct.
        data: (theme ?? buildLightTheme()).copyWith(platform: platform),
        child: ListDetailScaffold(
          sidebar: Sidebar(
            selectedViewId: listView ? _myTasks.list.id : SmartView.all.id,
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
          selectedIndex: listView ? null : SmartView.all.index,
          onDestinationSelected: (_) {},
          // The compact form factor renders the mobile chrome: an app bar with
          // the view title + hamburger, and a "new task" FAB.
          title: listView ? _myTasks.list.title : SmartView.all.label,
          onNewTask: () {},
          list: TaskListView(
            viewId: listView ? _myTasks.list.id : SmartView.all.id,
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
          child: _shellAt(desktop, platform: TargetPlatform.linux),
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

  // The bottom bar over a DRAWER LIST (#236). The active view is not one of the
  // destinations, so the bar carries no indicator pill and no filled icon — the
  // contrast against `shell_phone` (All Tasks highlighted) is the whole point:
  // a regression that re-highlights a smart view over a list is a byte diff.
  goldenTest(
    'shell — phone bottom nav with no selected destination',
    fileName: 'shell_phone_list_view',
    builder: () => GoldenTestGroup(
      columns: 2,
      children: [
        GoldenTestScenario(
          name: 'drawer list — nothing selected',
          constraints: BoxConstraints.tight(phone),
          child: _shellAt(phone, listView: true),
        ),
        // Dark too: the unselected icon/label treatment the bar falls back to
        // is resolved from the theme, so both brightnesses are pinned.
        GoldenTestScenario(
          name: 'drawer list dark — nothing selected',
          constraints: BoxConstraints.tight(phone),
          child: _shellAt(phone, listView: true, theme: buildDarkTheme()),
        ),
      ],
    ),
  );

  // Dark theme at both form factors (T10.1 / §6 "both themes"). The same seeded
  // shell rendered under the real dark theme: the cutover parity bar requires
  // goldens in BOTH brightnesses, and until now only light was pinned. A
  // regression that leaves a surface light-on-light (or blows out contrast) in
  // dark mode is now a byte diff, not an unseen break.
  goldenTest(
    'shell — dark theme (desktop + phone form factors)',
    fileName: 'shell_dark',
    builder: () => GoldenTestGroup(
      columns: 2,
      children: [
        GoldenTestScenario(
          name: 'desktop dark',
          constraints: BoxConstraints.tight(desktop),
          child: _shellAt(
            desktop,
            theme: buildDarkTheme(),
            platform: TargetPlatform.linux,
          ),
        ),
        GoldenTestScenario(
          name: 'phone dark',
          constraints: BoxConstraints.tight(phone),
          child: _shellAt(phone, theme: buildDarkTheme()),
        ),
      ],
    ),
  );

  // Accessibility text scale on the phone (T8.3): the enlarged-font system
  // setting must reflow the mobile chrome — the app bar, quick-add bar, sort
  // toolbar, task rows, and bottom nav — without a RenderFlex overflow (which
  // would throw and fail this render) and without clipping the content. Pinned
  // at the two scales the plan names: 1.3 (the §6 parity floor) and 2.0 (a
  // stress ceiling well past the OS "largest" setting).
  goldenTest(
    'shell — phone accessibility text scale (1.3 & 2.0)',
    fileName: 'shell_phone_text_scale',
    builder: () => GoldenTestGroup(
      columns: 2,
      children: [
        GoldenTestScenario(
          name: 'text-scale 1.3',
          constraints: BoxConstraints.tight(phone),
          child: _shellAt(phone, textScaler: const TextScaler.linear(1.3)),
        ),
        GoldenTestScenario(
          name: 'text-scale 2.0',
          constraints: BoxConstraints.tight(phone),
          child: _shellAt(phone, textScaler: const TextScaler.linear(2.0)),
        ),
      ],
    ),
  );
}
