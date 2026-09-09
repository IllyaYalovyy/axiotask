// Phone goldens for the TOP-PINNED composer (#304).
//
// The existing phone goldens (`shell_phone*`) all render the composer CLOSED —
// which is exactly why not one of them moved when it stopped being a bottom
// sheet. The state the ruling is about has no picture at all, so these are it:
//
//   • OPEN, empty — the panel hanging off the app bar's bottom edge with the
//     first row pushed below it (never behind it), and no FAB anywhere, because
//     the FAB is what the composer just became (#234);
//   • OPEN, with a draft and a date chip — the row at its most crowded: an
//     input holding a real title, the date chip beside it, and the submit still
//     on the same single line (the ratified mobile constraint, #217/#223).
//
// A regression that puts the composer back over the thumb, hides a row behind
// it, or grows it to a second line is a byte diff a reviewer has to explain
// (TESTING.md §"Golden discipline").
//
// Determinism: the seeded tasks carry no due dates, so only the composer's own
// chip reads the clock — and that scenario pins the clock for the build AND the
// settle pump, with a fixed MediaQuery so alchemist's post-test resize rebuilds
// nothing against the wall clock. Nothing is focused (the composer is opened by
// the provider override, not by a tap), so there is no cursor-blink timer.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/composer_controller.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'composed_list.dart';

final _clock = Clock.fixed(DateTime(2026, 6, 15, 12));

/// The composer open from the first frame — the state under test. Overriding
/// the flag rather than tapping the FAB keeps the field unfocused (no blinking
/// caret) and the unfold finished (no mid-flight frame to catch).
class _ComposerAlreadyOpen extends ComposerOpen {
  @override
  bool build() => true;
}

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

/// The real phone shell at [size] with the composer already open.
Widget _shellWithComposer(Size size, {ThemeData? theme}) => MediaQuery(
  data: MediaQueryData(size: size),
  child: ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(const Prefs()),
      allTasksProvider.overrideWith((ref) => Stream.value(_seedTasks)),
      listsProvider.overrideWith((ref) => Stream.value(const [_myTasks])),
      composerOpenProvider.overrideWith(_ComposerAlreadyOpen.new),
    ],
    child: Theme(
      data: (theme ?? buildLightTheme()).copyWith(
        platform: TargetPlatform.android,
      ),
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
        title: SmartView.all.label,
        onNewTask: () {},
        composerOpen: true,
        list: composedList(viewId: SmartView.all.id, onOpenTask: (_) {}),
      ),
    ),
  ),
);

/// Put a half-typed title and an explicitly picked date on every mounted
/// composer — the draft the second golden is a picture of.
///
/// Seeded through the one [ComposerController] the pane publishes (the same
/// object the FAB's panel and the desktop bar both render from), rather than
/// typed: `enterText` focuses the field, and a blinking caret is not something
/// a golden can hold still.
void _seedDraft(WidgetTester tester, {required String title, String? due}) {
  for (final element in find.byType(ComposerScope).evaluate()) {
    final controller = (element.widget as ComposerScope).notifier!;
    controller.text.text = title;
    if (due != null) controller.draft.pickDue(due);
  }
}

void main() {
  const phone = Size(400, 800);

  goldenTest(
    'composer panel — open on a phone, above the first row',
    fileName: 'composer_panel_open',
    // A bounded settle: the panel is opened by the provider, so nothing is
    // travelling, and pumpAndSettle would spin on any implicit animation
    // rather than fail loudly.
    pumpBeforeTest: (tester) => tester.pump(const Duration(seconds: 1)),
    builder: () => GoldenTestGroup(
      columns: 2,
      children: [
        GoldenTestScenario(
          name: 'composer open',
          constraints: BoxConstraints.tight(phone),
          child: _shellWithComposer(phone),
        ),
        // Dark too: the panel draws its own surface tone a step off the list
        // behind it, and that separation has to hold in both brightnesses.
        GoldenTestScenario(
          name: 'composer open · dark',
          constraints: BoxConstraints.tight(phone),
          child: _shellWithComposer(phone, theme: buildDarkTheme()),
        ),
      ],
    ),
  );

  goldenTest(
    'composer panel — a draft with its date chip on one line',
    fileName: 'composer_panel_draft',
    pumpWidget: (tester, widget) =>
        withClock(_clock, () => tester.pumpWidget(widget)),
    pumpBeforeTest: (tester) => withClock(_clock, () async {
      _seedDraft(tester, title: 'Call the plumber', due: '2026-06-16');
      await tester.pump(const Duration(seconds: 1));
    }),
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'draft + date chip',
          constraints: BoxConstraints.tight(phone),
          child: _shellWithComposer(phone),
        ),
      ],
    ),
  );
}
