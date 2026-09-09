// The detail panel's SUBTASK SECTION, pinned on both form factors (#306).
//
// New goldens by intent: the checklist was rebuilt around the list's own row,
// so every pixel of this section changed at once — the two arrow buttons per
// row are gone, a drag handle takes their column, the finished subtask is
// folded under "N completed", and the progress is the row's own bar + "N/M".
// These are the baselines that say what that section now looks like.
//
// The two form factors differ in more than width: the desktop scenario is a
// FINE pointer, so it draws the tighter subtask density and keeps the drag
// handle hidden until the mouse is over the row; the phone scenario is COARSE,
// so it keeps the 48dp checkbox column, the taller meta band and a permanently
// visible handle.
//
// Determinism: no due dates anywhere, so nothing reads the clock
// (dueUrgency/formatDue never fire), every field is unfocused so no cursor
// blinks, and the progress bar is a determinate value. The snapshot is a pure
// function of the tree.

import 'package:alchemist/alchemist.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/task_detail.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

StoredTask _task(
  String id,
  String title,
  String position, {
  String? parent,
  String? notes,
  bool done = false,
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    notes: notes,
    status: done ? TaskStatus.completed : TaskStatus.needsAction,
    updated: 't',
  ),
  listId: 'L1',
  syncState: SyncState.clean,
  localUpdated: 't',
);

// A parent with three subtasks: two open (one of them carrying notes, so the
// badge the old subtask row could never show is in the baseline) and one
// finished, which the group folds away.
final _seed = <StoredTask>[
  _task('P', 'Plan the offsite', '1'),
  _task('S1', 'Book a venue', '1', parent: 'P', notes: 'A/V for the demos'),
  _task('S2', 'Send the invites', '2', parent: 'P'),
  _task('S3', 'Pick the dates', '3', parent: 'P', done: true),
];

const _myTasks = StoredTaskList(
  list: TaskList(id: 'L1', title: 'My Tasks', etag: 'e1', updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

void _noop() {}
void _noopStr(String _) {}

Widget _detail(
  Size size, {
  required TargetPlatform platform,
  required bool collapsed,
}) => MediaQuery(
  data: MediaQueryData(size: size),
  child: ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(Prefs(hideCompletedSubtasks: collapsed)),
      allTasksProvider.overrideWith((ref) => Stream.value(_seed)),
      listsProvider.overrideWith((ref) => Stream.value(const [_myTasks])),
    ],
    child: Theme(
      data: buildLightTheme().copyWith(platform: platform),
      child: const Scaffold(
        body: TaskDetail(taskId: 'P', onClose: _noop, onOpenTask: _noopStr),
      ),
    ),
  ),
);

void main() {
  const desktop = Size(560, 700);
  const phone = Size(400, 760);

  goldenTest(
    'detail subtasks — desktop pane, drag handles and the completed group',
    fileName: 'detail_subtasks_desktop',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'collapsed',
          constraints: BoxConstraints.tight(desktop),
          child: _detail(
            desktop,
            platform: TargetPlatform.linux,
            collapsed: true,
          ),
        ),
        GoldenTestScenario(
          name: 'expanded',
          constraints: BoxConstraints.tight(desktop),
          child: _detail(
            desktop,
            platform: TargetPlatform.linux,
            collapsed: false,
          ),
        ),
      ],
    ),
  );

  goldenTest(
    'detail subtasks — phone, touch density and a visible drag handle',
    fileName: 'detail_subtasks_phone',
    builder: () => GoldenTestGroup(
      children: [
        GoldenTestScenario(
          name: 'collapsed',
          constraints: BoxConstraints.tight(phone),
          child: _detail(
            phone,
            platform: TargetPlatform.android,
            collapsed: true,
          ),
        ),
      ],
    ),
  );
}
