// Goldens for the "Needs attention" view (#296) — two items on each form
// factor, because the two entry kinds are what the layout has to hold: a held
// row (title, where it lives, three actions) and a conflicted pair (two
// versions to compare, three ways out).
//
// The pair is the reason both widths are pinned. On the desktop the two
// versions sit SIDE BY SIDE, which is the only arrangement in which a diff can
// be read at a glance; below [kConflictSideBySideWidth] they stack, because two
// columns of task text on a phone are two columns of ellipsis. A regression in
// either direction is a layout the user cannot use, and neither shows up in a
// finder-based test.
//
// Determinism: no due dates anywhere (nothing reads the clock — formatDue and
// dueUrgency never fire), no focused fields (no cursor-blink timer). The
// snapshot is a pure function of the tree.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/model/attention.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/attention_view.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _list = StoredTaskList(
  list: TaskList(id: 'L1', title: 'Work', etag: 'e', updated: 'u'),
  syncState: SyncState.clean,
  localUpdated: 'u',
);

StoredTask _row(
  String id,
  String title, {
  String? notes,
  SyncState syncState = SyncState.dirty,
}) => StoredTask(
  task: Task(
    id: id,
    position: '1',
    title: title,
    notes: notes,
    status: TaskStatus.needsAction,
    updated: 'u',
  ),
  listId: 'L1',
  syncState: syncState,
  localUpdated: 'u',
);

final _tasks = <StoredTask>[
  _row('t1', 'Send the invoice to accounting'),
  _row(
    'c1',
    'Book the venue',
    notes: 'Called, they hold it until Friday',
    syncState: SyncState.clean,
  ),
  _row('c2', 'Book the venue hall (conflicted copy)', notes: 'Emailed instead'),
];

const _status = SyncStatusView(
  lastSynced: null,
  lastPulled: 0,
  lastPushed: 0,
  lastConflicts: 0,
  lastDeleted: 0,
  totalSyncs: 0,
  lastError: null,
  needsAttention: false,
  needsReauth: false,
  quarantined: [
    QuarantinedRow(id: 't1', title: 'Send the invoice to accounting'),
  ],
  conflicts: [ConflictLink(originalId: 'c1', copyId: 'c2')],
);

Widget _view(Size size, {ThemeData? theme}) => MediaQuery(
  data: MediaQueryData(size: size),
  child: ProviderScope(
    overrides: [
      allTasksProvider.overrideWith((ref) => Stream.value(_tasks)),
      listsProvider.overrideWith((ref) => Stream.value(const [_list])),
      syncStatusStreamProvider.overrideWith((ref) => Stream.value(_status)),
    ],
    child: Theme(
      data: (theme ?? buildLightTheme()).copyWith(
        platform: TargetPlatform.linux,
      ),
      child: Material(
        color: (theme ?? buildLightTheme()).colorScheme.surface,
        child: AttentionView(onOpenTask: (_) {}),
      ),
    ),
  ),
);

void main() {
  const phone = Size(400, 800);
  const desktop = Size(900, 760);

  goldenTest(
    'needs attention — phone: two items, versions stacked',
    fileName: 'attention_phone',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'phone',
          constraints: BoxConstraints.tight(phone),
          child: _view(phone),
        ),
      ],
    ),
  );

  goldenTest(
    'needs attention — desktop: two items, versions side by side',
    fileName: 'attention_desktop',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'desktop',
          constraints: BoxConstraints.tight(desktop),
          child: _view(desktop),
        ),
        GoldenTestScenario(
          name: 'desktop · dark',
          constraints: BoxConstraints.tight(desktop),
          child: _view(desktop, theme: buildDarkTheme()),
        ),
      ],
    ),
  );
}
