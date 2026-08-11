// SearchOverlay suite — the live task search (ui/search.dart). Asserts what the
// user SEES in the overlay and what task an activation lands on: title+notes
// live filtering, open-before-completed ranking, subtask-through-parent (#92),
// LOCAL date rendering (#76), and selection-reset-on-narrowing. Pumps the plain
// widget (no router) so behavior is asserted directly.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/search.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

StoredTask _row(
  String id,
  String title, {
  String? parent,
  bool done = false,
  String? notes,
  String? due,
  String listId = 'L1',
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: '1',
    title: title,
    notes: notes,
    due: due,
    status: done ? TaskStatus.completed : TaskStatus.needsAction,
    updated: 't',
  ),
  listId: listId,
  syncState: SyncState.clean,
  localUpdated: 't',
);

Future<StoredTask?> _pumpSearch(
  WidgetTester tester,
  List<StoredTask> tasks, {
  Map<String, String> listTitles = const {},
  List<StoredTask>? closed,
}) async {
  StoredTask? selected;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SearchOverlay(
          tasks: tasks,
          listTitles: listTitles,
          onSelect: (t) => selected = t,
          onClose: () => (closed ?? <StoredTask>[]).add(_row('x', 'closed')),
        ),
      ),
    ),
  );
  await tester.pump();
  return selected;
}

void main() {
  group('SearchOverlay', () {
    testWidgets('live filter matches title OR notes, case-insensitively', (
      tester,
    ) async {
      await _pumpSearch(tester, [
        _row('a', 'Buy milk'),
        _row('b', 'Call plumber', notes: 'about the MILK leak'),
        _row('c', 'Write report'),
      ]);

      // Empty query: nothing listed, no "no results" message.
      expect(find.text('Buy milk'), findsNothing);
      expect(find.text('No tasks found'), findsNothing);

      await tester.enterText(find.byType(TextField), 'milk');
      await tester.pump();

      expect(find.text('Buy milk'), findsOneWidget); // title match
      expect(find.text('Call plumber'), findsOneWidget); // notes match
      expect(find.text('Write report'), findsNothing); // no match
    });

    testWidgets('a non-matching query shows the empty-state message', (
      tester,
    ) async {
      await _pumpSearch(tester, [_row('a', 'Buy milk')]);
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.text('No tasks found'), findsOneWidget);
    });

    testWidgets('respects the soft-keyboard inset — the box stays above the IME '
        '(F19 #198)', (tester) async {
      // The failure this prevents: with the keyboard up (viewInsets.bottom),
      // the search box is laid out against the FULL screen height and the IME
      // covers the very field being typed into. Padding by the inset keeps the
      // box above it. Rendered on a short surface where a tall keyboard would
      // otherwise overlap the box (the real overlay is a fullscreen route, not
      // a Scaffold body, so it must handle the inset itself).
      const keyboard = 220.0;
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(viewInsets: const EdgeInsets.only(bottom: keyboard)),
              child: SearchOverlay(
                tasks: const [],
                listTitles: const {},
                onSelect: (_) {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The field's bottom edge stays above the keyboard's top (300 - 220).
      final fieldBottom = tester.getRect(find.byType(TextField)).bottom;
      expect(
        fieldBottom,
        lessThanOrEqualTo(300 - keyboard),
        reason: 'the search field must sit above the on-screen keyboard',
      );
    });

    testWidgets('open tasks rank before completed ones', (tester) async {
      await _pumpSearch(tester, [
        _row('done', 'alpha done', done: true),
        _row('open', 'alpha open'),
      ]);
      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pump();

      final open = tester.getTopLeft(find.text('alpha open')).dy;
      final done = tester.getTopLeft(find.text('alpha done')).dy;
      expect(
        open,
        lessThan(done),
        reason: 'open result renders above completed',
      );
    });

    testWidgets('a matched subtask surfaces its parent (#92)', (tester) async {
      await _pumpSearch(tester, [
        _row('p', 'Kitchen remodel'),
        _row('s', 'Order tiles', parent: 'p'),
      ]);
      await tester.enterText(find.byType(TextField), 'tiles');
      await tester.pump();

      expect(find.text('Order tiles'), findsOneWidget);
      expect(find.text('Subtask'), findsOneWidget);
      expect(find.textContaining('Kitchen remodel'), findsOneWidget);
    });

    testWidgets('selecting a subtask returns the subtask; landing view is its '
        'parent list (#92)', (tester) async {
      final tasks = [
        _row('p', 'Kitchen remodel', listId: 'HOME'),
        _row('s', 'Order tiles', parent: 'p', listId: 'HOME'),
      ];
      final selected = await () async {
        StoredTask? picked;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SearchOverlay(
                tasks: tasks,
                listTitles: const {'HOME': 'Home'},
                onSelect: (t) => picked = t,
                onClose: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'tiles');
        await tester.pump();
        await tester.tap(find.text('Order tiles'));
        await tester.pump();
        return picked;
      }();

      expect(selected?.task.id, 's');
      // The overlay hands the caller a task; the pure landing rule sends the
      // list to the PARENT's list so the subtask opens in context.
      expect(searchLandingViewId(tasks, selected!), 'HOME');
    });

    testWidgets('due dates render as LOCAL calendar dates (#76)', (
      tester,
    ) async {
      // Frozen "now" so formatDue is deterministic and far from the due date
      // (an absolute "Jun 15" label rather than a relative one).
      await withClock(Clock.fixed(DateTime(2026, 1, 1)), () async {
        await _pumpSearch(tester, [
          // Google's date-only midnight-UTC form. Parsing the whole string as
          // UTC and rendering locally would shift to Jun 14 in negative zones.
          _row('a', 'Dated task', due: '2026-06-15T00:00:00.000Z'),
        ]);
        await tester.enterText(find.byType(TextField), 'dated');
        await tester.pump();
        expect(find.textContaining('Jun 15'), findsOneWidget);
      });
    });

    testWidgets('the list title chip renders when known', (tester) async {
      await _pumpSearch(
        tester,
        [_row('a', 'Groceries', listId: 'L2')],
        listTitles: {'L2': 'Shopping'},
      );
      await tester.enterText(find.byType(TextField), 'groc');
      await tester.pump();
      expect(find.text('Shopping'), findsOneWidget);
    });

    testWidgets('ArrowDown moves the highlight; submit opens THAT result', (
      tester,
    ) async {
      StoredTask? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchOverlay(
              tasks: [
                _row('1', 'task one'),
                _row('2', 'task two'),
                _row('3', 'task three'),
              ],
              listTitles: const {},
              onSelect: (t) => picked = t,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'task'); // [1,2,3]
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // → idx 1
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(picked?.task.id, '2', reason: 'submit opens the highlighted row');
    });

    testWidgets('narrowing resets selection to the first result', (
      tester,
    ) async {
      StoredTask? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchOverlay(
              tasks: [
                _row('1', 'task one'),
                _row('2', 'task two'),
                _row('3', 'task three'),
              ],
              listTitles: const {},
              onSelect: (t) => picked = t,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      // Broad "task" → [1,2,3]; move the highlight down to the third.
      await tester.enterText(find.byType(TextField), 'task');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // idx 2
      await tester.pump();

      // Narrow to "task t" → still TWO results [task two, task three]. A stale
      // idx 2 would clamp to the LAST (id 3); a proper reset lands on idx 0.
      await tester.enterText(find.byType(TextField), 'task t');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(
        picked?.task.id,
        '2',
        reason: 'reset to first, not the clamped stale index',
      );
    });
  });

  group('searchLandingViewId', () {
    final tasks = [
      _row('p', 'Parent', listId: 'HOME'),
      _row('s', 'Sub', parent: 'p', listId: 'HOME'),
      _row('t', 'Top', listId: 'WORK'),
      _row('orphan', 'Orphan', parent: 'gone', listId: 'WORK'),
    ];

    test('a top-level task lands on its own list', () {
      expect(searchLandingViewId(tasks, tasks[2]), 'WORK');
    });

    test('a subtask lands on its parent list', () {
      expect(searchLandingViewId(tasks, tasks[1]), 'HOME');
    });

    test('a subtask with a missing parent falls back to its own list', () {
      expect(searchLandingViewId(tasks, tasks[3]), 'WORK');
    });
  });
}
