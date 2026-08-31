// The drawer's list section, pinned in both themes (#248).
//
// New baselines by intent: exclusion stopped being "50% opacity + italic" —
// the universal inactive-control look, which said nothing about WHY a row was
// quiet — and became an explicit `visibility_off` glyph beside the title, with
// the name itself moved to the quiet-but-readable `onSurfaceVariant` tone. The
// signal is entirely visual, so it is a golden or it is unprotected: a
// regression that drops the glyph, or that puts the row back behind an opacity
// layer, is a byte diff a reviewer has to explain.
//
// Three rows in one frame, because the treatment only means something in
// contrast: a SELECTED list (the secondary-container pill), an EXCLUDED one
// (glyph + quiet title), and an ordinary synced one.
//
// Determinism: a presentational widget over static data — no store, no router,
// no clock, no timers, nothing focused.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';

StoredTaskList _list(String id, String title, {bool localOnly = false}) =>
    StoredTaskList(
      list: TaskList(id: id, title: title, etag: 'e', updated: 't'),
      syncState: SyncState.clean,
      localUpdated: 't',
      localOnly: localOnly,
    );

final _lists = [
  _list('L1', 'My Tasks'),
  _list('L2', 'Someday'),
  _list('L3', 'Scratch', localOnly: true),
];

Widget _sidebar(ThemeData theme) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: theme,
  home: Scaffold(
    body: Row(
      children: [
        Sidebar(
          // "Someday" is the excluded one — parked, still openable, and now
          // saying so.
          selectedViewId: 'L1',
          counts: const {'all': 7, 'focus': 2, 'L1': 4, 'L2': 12},
          lists: _lists,
          excludedLists: const {'L2'},
          onSelectView: (_) {},
          onCreateList: (_, {localOnly = false}) {},
          onRenameList: (_, _) {},
          onDeleteList: (_) {},
          onToggleExclude: (_) {},
          onReorderLists: (_) {},
        ),
        const Expanded(child: SizedBox()),
      ],
    ),
  ),
);

void main() {
  const panel = Size(260, 460);

  goldenTest(
    'drawer — an excluded list is marked, not just dimmed',
    fileName: 'sidebar_excluded_list',
    builder: () => GoldenTestGroup(
      columns: 2,
      children: [
        GoldenTestScenario(
          name: 'light',
          constraints: BoxConstraints.tight(panel),
          child: _sidebar(buildLightTheme()),
        ),
        GoldenTestScenario(
          name: 'dark',
          constraints: BoxConstraints.tight(panel),
          child: _sidebar(buildDarkTheme()),
        ),
      ],
    ),
  );
}
