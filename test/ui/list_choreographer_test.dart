// The list's choreography, tested directly (#274).
//
// Which rows animate, in what order, and for how long used to be inferable only
// from pixels — the bookkeeping lived in the pane's `State` and was reachable
// only by pumping a real list and watching heights. [ListChoreographer] is a
// plain object over one before/after pair, so the RULES can be asserted:
//
//   • the first contents a view shows never animate (that is the view, not an
//     event);
//   • a row COMPLETED out of a filtered list is held for its #241 collapse,
//     drawn in its completed state, in the slot it occupied;
//   • a row that left for any other reason is held for its #251 leave, and is
//     drawn from the last snapshot the list had (the task may be gone);
//   • restraint is enforced here: at most [listMotionRowCap] rows move on any
//     one change, and the budget is SHARED by arrivals and departures, so a
//     delete-and-insert cannot double it;
//   • a hold whose row never rendered (it left off-screen, so nothing ever
//     reported back) is expired rather than lingering in the list for good.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/list_choreographer.dart';
import 'package:axiotask/src/ui/list_motion.dart';
import 'package:axiotask/src/ui/visible_rows.dart';
import 'package:flutter_test/flutter_test.dart';

StoredTask _stored(String id, {bool done = false}) => StoredTask(
  task: Task(
    id: id,
    position: id,
    title: id,
    status: done ? TaskStatus.completed : TaskStatus.needsAction,
    updated: 't',
  ),
  listId: 'L1',
  syncState: SyncState.clean,
  localUpdated: 't',
);

TaskRowData _row(String id, {bool done = false}) =>
    TaskRowData(stored: _stored(id, done: done));

void main() {
  /// One choreograph pass at [now] over [visible], with [all] as the live set.
  List<RowItem> pass(
    ListChoreographer c,
    List<String> visible, {
    List<StoredTask>? all,
    Duration now = Duration.zero,
    bool hasData = true,
  }) {
    final rows = [for (final id in visible) _row(id)];
    final live = all ?? [for (final id in visible) _stored(id)];
    return c.choreograph(
      visible: rows,
      byId: {for (final t in live) t.task.id: t},
      hasData: hasData,
      now: now,
    );
  }

  test('the first contents a view shows do not animate', () {
    final c = ListChoreographer();
    final items = pass(c, ['A', 'B', 'C']);
    expect(items.map((i) => i.id), ['A', 'B', 'C']);
    expect(
      items.every((i) => i.motion == SlotMotion.none),
      isTrue,
      reason: 'launching a view is not three rows arriving',
    );
    expect(c.seenContents, isTrue);
  });

  test('a row that arrives after the first pass grows into place', () {
    final c = ListChoreographer();
    pass(c, ['A']);
    final items = pass(c, ['A', 'B'], now: const Duration(seconds: 1));
    expect(items.map((i) => i.id), ['A', 'B']);
    expect(items[0].motion, SlotMotion.none);
    expect(items[1].motion, SlotMotion.entering);
  });

  test('a COMPLETED row is held in its slot, drawn completed (#241)', () {
    final c = ListChoreographer();
    pass(c, ['A', 'B', 'C']);
    // B was ticked while completed rows are hidden: it is gone from `visible`
    // but present-and-completed in the live set.
    final items = c.choreograph(
      visible: [_row('A'), _row('C')],
      byId: {
        'A': _stored('A'),
        'B': _stored('B', done: true),
        'C': _stored('C'),
      },
      hasData: true,
      now: const Duration(seconds: 1),
    );
    expect(items.map((i) => i.id), ['A', 'B', 'C'], reason: 'held in place');
    final held = items[1];
    expect(held.motion, SlotMotion.completing);
    expect(
      held.row.stored.task.status,
      TaskStatus.completed,
      reason: 'it folds away TICKED — the state that made it leave',
    );
    // Once the collapse reports back the slot is released.
    expect(c.departed('B'), isTrue);
    expect(pass(c, ['A', 'C'], now: const Duration(seconds: 2)).length, 2);
  });

  test('a DELETED row folds away from the last snapshot the list held', () {
    final c = ListChoreographer();
    pass(c, ['A', 'B']);
    // B is gone from the live set entirely — there is no current row to read.
    final items = c.choreograph(
      visible: [_row('A')],
      byId: {'A': _stored('A')},
      hasData: true,
      now: const Duration(seconds: 1),
    );
    expect(items.map((i) => i.id), ['A', 'B']);
    expect(items[1].motion, SlotMotion.leaving);
    expect(items[1].row.stored.task.title, 'B');
  });

  test('a completed row that comes BACK reverses instead of replaying', () {
    final c = ListChoreographer();
    pass(c, ['A', 'B']);
    c.choreograph(
      visible: [_row('A')],
      byId: {'A': _stored('A'), 'B': _stored('B', done: true)},
      hasData: true,
      now: const Duration(milliseconds: 100),
    );
    // Undo inside the 30-second toast, WHILE the collapse is still playing:
    // B is open and visible again.
    final items = pass(c, ['A', 'B'], now: const Duration(milliseconds: 150));
    expect(items.map((i) => i.id), ['A', 'B']);
    expect(c.isReturning('B'), isTrue, reason: 'the collapse reverses');
  });

  test(
    'at most listMotionRowCap rows move on one change, arrivals included',
    () {
      final c = ListChoreographer();
      final before = [for (var i = 0; i < 40; i++) 'old$i'];
      pass(c, before);
      // A sync rewrites the whole list: 40 rows leave and 40 arrive at once.
      final after = [for (var i = 0; i < 40; i++) 'new$i'];
      final items = pass(c, after, now: const Duration(seconds: 1));
      final moving = items
          .where((i) => i.motion != SlotMotion.none)
          .toList(growable: false);
      expect(
        moving.length,
        lessThanOrEqualTo(listMotionRowCap),
        reason: 'the budget is ONE per change, shared by leaves and arrivals',
      );
      expect(moving, isNotEmpty, reason: 'and it is actually spent');
      // The stagger is bounded by the window, never a ripple lasting seconds.
      for (final item in moving) {
        expect(item.delay, lessThanOrEqualTo(listMotionWindow));
      }
    },
  );

  test('a hold whose row never rendered is expired, not kept forever', () {
    final c = ListChoreographer();
    pass(c, ['A', 'B']);
    // B leaves while scrolled out of view, so nothing ever reports its fold.
    var items = c.choreograph(
      visible: [_row('A')],
      byId: {'A': _stored('A')},
      hasData: true,
      now: const Duration(seconds: 1),
    );
    expect(items.length, 2);
    // Long past its motion, the slot is gone even though no row reported back.
    items = pass(c, [
      'A',
    ], now: const Duration(seconds: 1) + listMotionWindow * 3);
    expect(items.map((i) => i.id), ['A']);
  });

  test('a view reset starts from nothing (non-happy path: stale holds)', () {
    final c = ListChoreographer();
    pass(c, ['A', 'B']);
    c.choreograph(
      visible: [_row('A')],
      byId: {'A': _stored('A')},
      hasData: true,
      now: const Duration(seconds: 1),
    );
    c.reset();
    expect(c.seenContents, isFalse);
    // Another view's rows are not this view's rows arriving.
    final items = pass(c, ['X', 'Y'], now: const Duration(seconds: 2));
    expect(items.map((i) => i.id), ['X', 'Y']);
    expect(items.every((i) => i.motion == SlotMotion.none), isTrue);
  });
}
