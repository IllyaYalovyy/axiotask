// The list UNDER A PHONE'S FULL DEVICE INSETS (#274).
//
// The existing phone goldens render either on an inset-free surface or under a
// top inset alone (#262), and that is exactly where an inset bug hides: with a
// zero inset, counting one twice — or not at all — costs nothing, so not one
// baseline moves. A real phone has a status bar or notch at the TOP, a gesture
// pill at the BOTTOM, and often a cutout down one SIDE, and the contract
// (#166/#160) is that nothing is drawn under the notch and nothing tappable
// sits under the pill.
//
// Three scenarios, because the list has three states whose geometry is decided
// by different code:
//
//   • ROWS — the app bar sits past the notch, the rows start below it, and the
//     bottom of the scroll clears BOTH the nav bar and the pill under it;
//   • THE EMPTY STATE — it is centred in whatever the pane has left, which is
//     the one place a doubled inset shows up as visible off-centre drift;
//   • TEXT SCALE 1.3 WITH THE SAME INSETS — the combination nothing pins
//     today: a phone that is both notched and set to a large system font is
//     the narrowest, shortest pane the app ever renders into.
//
// Determinism: the seeded tasks carry no due dates (nothing reads the clock),
// nothing is focused (no cursor-blink timer), and the sync line is idle — so
// each snapshot is a pure function of the widget tree.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'composed_list.dart';
import 'list_harness.dart' show phoneInsets;

StoredTask _task(String id, String title, String pos) => StoredTask(
  task: Task(
    id: id,
    position: pos,
    title: title,
    status: TaskStatus.needsAction,
    updated: 't',
  ),
  listId: 'L1',
  syncState: SyncState.clean,
  localUpdated: 't',
);

final _seed = <StoredTask>[
  _task('A', 'Pay the invoice', '1'),
  _task('B', 'Renew the domain', '2'),
  _task('C', 'Write the stand-up notes', '3'),
];

const _myTasks = StoredTaskList(
  list: TaskList(id: 'L1', title: 'My Tasks', etag: 'e', updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

/// The REAL compact shell at [size], inside [phoneInsets], on a touch platform
/// (the pointer class that actually meets a notch).
Widget _phoneShell(
  Size size, {
  List<StoredTask> tasks = const [],
  TextScaler textScaler = TextScaler.noScaling,
}) => MediaQuery(
  data: MediaQueryData(
    size: size,
    textScaler: textScaler,
    padding: phoneInsets,
    viewPadding: phoneInsets,
  ),
  child: ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(const Prefs()),
      allTasksProvider.overrideWith((ref) => Stream.value(tasks)),
      listsProvider.overrideWith((ref) => Stream.value(const [_myTasks])),
    ],
    child: Theme(
      data: buildLightTheme().copyWith(platform: TargetPlatform.android),
      child: ListDetailScaffold(
        sidebar: Sidebar(
          selectedViewId: SmartView.all.id,
          counts: {'all': tasks.length, 'L1': tasks.length},
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
        title: SmartView.all.label,
        onNewTask: () {},
        list: composedList(viewId: SmartView.all.id, onOpenTask: _noop),
      ),
    ),
  ),
);

void _noop(String _) {}

void main() {
  const phone = Size(400, 760);

  goldenTest(
    'list — rows on a fully-inset phone',
    fileName: 'list_insets_rows',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'rows clear the notch, the pill and the side cutout',
          constraints: BoxConstraints.tight(phone),
          child: _phoneShell(phone, tasks: _seed),
        ),
      ],
    ),
  );

  goldenTest(
    'list — the empty state on a fully-inset phone',
    fileName: 'list_insets_empty',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'empty state centred in what the insets leave',
          constraints: BoxConstraints.tight(phone),
          child: _phoneShell(phone),
        ),
      ],
    ),
  );

  goldenTest(
    'list — a fully-inset phone at text scale 1.3',
    fileName: 'list_insets_text_scale',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'notched, pilled AND large-font — still no overflow',
          constraints: BoxConstraints.tight(phone),
          child: _phoneShell(
            phone,
            tasks: _seed,
            textScaler: const TextScaler.linear(1.3),
          ),
        ),
      ],
    ),
  );
}
