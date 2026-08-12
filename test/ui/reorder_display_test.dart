// G1 (#202) — drag reorder correctness end to end. The list view computes a
// drop target over the VISIBLE rows in DISPLAY order; the command rewrites the
// FULL sibling list in POSITION order. When hidden completed rows interleave
// (Hide completed), or Focus lifts an overdue bucket to the front, display
// order diverges from position order, so an index computed in one and applied
// in the other lands the row in the wrong slot — silently corrupting the stored
// "My order" while the drag renders as a no-op.
//
// These tests wire the REAL display pipeline (visibleTasksForView + the Focus
// partition), the REAL drop resolver the list view feeds, and a REAL
// Store/Commands, then assert BOTH the re-derived visible order AND the stored
// position order — the two the corruption drives apart.

import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/model/task_view.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

const _t0 = '2026-06-15T00:00:00.000Z';
final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

Future<Store> _freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return Store(db);
}

Future<void> _seedList(Store store, String id) => store.upsertList(
  StoredTaskList(
    list: TaskList(id: id, title: 'My Tasks', etag: 'e', updated: _t0),
    syncState: SyncState.clean,
    localUpdated: _t0,
  ),
);

Future<void> _seed(
  Store store,
  String id,
  String pos, {
  String? due,
  bool done = false,
}) => store.upsertTask(
  StoredTask(
    task: Task(
      id: id,
      position: pos,
      title: id,
      status: done ? TaskStatus.completed : TaskStatus.needsAction,
      due: due,
      etag: 'e',
      updated: _t0,
    ),
    listId: 'L1',
    syncState: SyncState.clean,
    localUpdated: _t0,
  ),
);

/// The list view's display order for [viewId]: the visible rows (Hide completed
/// on) in the chosen [sort], with Focus lifting its overdue bucket to the front
/// — exactly what TaskListView.build assembles before it renders.
List<StoredTask> _display(List<StoredTask> all, String viewId, SortMode sort) {
  final tasks = visibleTasksForView(
    allTasks: all,
    viewId: viewId,
    excludedLists: const {},
    showCompleted: false,
    sort: sort,
    window: dateWindowNow(),
  );
  if (viewId == 'focus') {
    final part = partitionFocusOverdue(
      rows: tasks,
      allTasks: all,
      window: dateWindowNow(),
    );
    return [...part.overdue, ...part.rest];
  }
  return tasks;
}

/// The stored order (position order, hidden rows included) as a list of ids.
Future<List<String>> _stored(Store store) async =>
    (await store.listTasks('L1')).map((t) => t.task.id).toList();

/// The visible ids of [viewId] after a mutation, in display order.
Future<List<String>> _visible(
  Store store,
  String viewId,
  SortMode sort,
) async => _display(
  await store.listTasks('L1'),
  viewId,
  sort,
).map((t) => t.task.id).toList();

void main() {
  test(
    'a drag across a HIDDEN completed sibling lands where it was dropped',
    () => withClock(_clock, () async {
      final store = await _freshStore();
      final commands = Commands(store);
      await _seedList(store, 'L1');
      await _seed(store, 'A', '00000000000001');
      await _seed(store, 'B', '00000000000002', done: true); // hidden
      await _seed(store, 'C', '00000000000003');
      await _seed(store, 'D', '00000000000004');

      // Visible (Hide completed) manual order drops B: [A, C, D].
      const sort = SortMode.manual;
      final display = _display(await store.listTasks('L1'), 'all', sort);
      expect(display.map((t) => t.task.id), ['A', 'C', 'D']);

      // Drag A down one visible slot — past C. onReorderItem hands back the
      // post-removal landing index (1: A now follows C in the reduced list).
      final anchor = reorderAnchor(display, 0, 1);
      expect(anchor, isNotNull);
      await commands.reorderTaskAfter('A', anchor!.previousId);

      // The move landed A after C in the VISIBLE order, and rewrote the stored
      // order to match — the hidden completed B kept its slot, never crossed.
      expect(
        await _visible(store, 'all', sort),
        ['C', 'A', 'D'],
        reason: 'A lands after C, where it was dropped',
      );
      expect(
        await _stored(store),
        ['B', 'C', 'A', 'D'],
        reason: 'stored order matches the visible drop, B untouched',
      );
    }),
  );

  test(
    'a Focus manual-sort drag past the overdue partition keeps visible and '
    'stored order in agreement',
    () => withClock(_clock, () async {
      final store = await _freshStore();
      final commands = Commands(store);
      await _seedList(store, 'L1');
      // Position order X, Y, over, Z. "over" is overdue (lifted to the front in
      // Focus), so DISPLAY order [over, X, Y, Z] diverges from POSITION order.
      await _seed(
        store,
        'X',
        '00000000000001',
        due: '2026-06-16T00:00:00.000Z',
      );
      await _seed(
        store,
        'Y',
        '00000000000002',
        due: '2026-06-17T00:00:00.000Z',
      );
      await _seed(
        store,
        'over',
        '00000000000003',
        due: '2026-06-10T00:00:00.000Z',
      );
      await _seed(
        store,
        'Z',
        '00000000000004',
        due: '2026-06-18T00:00:00.000Z',
      );

      const sort = SortMode.manual;
      final display = _display(await store.listTasks('L1'), 'focus', sort);
      expect(display.map((t) => t.task.id), ['over', 'X', 'Y', 'Z']);

      // Drag Z up one visible slot — past Y, dropped between X and Y (landing
      // index 2 in the post-removal display).
      final anchor = reorderAnchor(display, 3, 2);
      expect(anchor, isNotNull);
      await commands.reorderTaskAfter('Z', anchor!.previousId);

      // Z now renders between X and Y, and the stored order agrees — no silent
      // divergence where the drag looks like a no-op but the order shifts.
      expect(
        await _visible(store, 'focus', sort),
        ['over', 'X', 'Z', 'Y'],
        reason: 'Z lands between X and Y in the dated bucket',
      );
      expect(
        await _stored(store),
        ['X', 'Z', 'Y', 'over'],
        reason: 'stored order tracks the drop, not a mis-indexed slot',
      );
    }),
  );
}
