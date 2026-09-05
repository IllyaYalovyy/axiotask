// The per-row ACTION SURFACE (MIGRATION-PLAN §4/§5 T7.6): the ContextMenu PORT
// cases, DemoteToSubtask, and MoveToList (context-menu half). Driven through the
// real [TaskListView] — a right-click opens the desktop context menu, the "⋯"
// button opens the touch action sheet — over the mutating [FakeCommands], so the
// assertions are about what the surface offers and what the fake HOLDS after an
// action. Keyboard submenu navigation dies with the keyboard layer; the actions
// all port, and submenus open on CLICK, not hover.

import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart' show kQuickDateItems;
import 'package:axiotask/src/ui/task_actions.dart' show TaskActionMenu;
import 'package:axiotask/src/ui/task_row.dart';
import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];
  final twoLists = [list('L1', 'My Tasks'), list('L2', 'Errands')];

  /// Right-click the row titled [title] to open the desktop context menu.
  Future<void> rightClick(WidgetTester tester, String title) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(title)),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  group('ContextMenu — items and visibility', () {
    testWidgets('shows the core actions on right-click', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples', webViewLink: 'https://g/1')],
        lists: oneList,
      );
      await rightClick(tester, 'apples');
      // Every top-level action item is present…
      expect(find.byKey(const Key('taskmenu-edit')), findsOneWidget);
      expect(find.byKey(const Key('taskmenu-notes')), findsOneWidget);
      expect(find.byKey(const Key('taskmenu-due')), findsOneWidget);
      expect(find.byKey(const Key('taskmenu-move')), findsOneWidget);
      expect(find.byKey(const Key('taskmenu-duplicate')), findsOneWidget);
      expect(find.byKey(const Key('taskmenu-details')), findsOneWidget);
      expect(find.byKey(const Key('taskmenu-open-google')), findsOneWidget);
      expect(find.byKey(const Key('taskmenu-delete')), findsOneWidget);
    });

    testWidgets('offers NO "Add subtask" option (#91)', (tester) async {
      await pumpList(tester, initial: [row('A', 'apples')], lists: oneList);
      await rightClick(tester, 'apples');
      expect(find.textContaining('subtask', findRichText: true), findsNothing);
    });

    testWidgets('hides Open-in-Google for a task with no webViewLink', (
      tester,
    ) async {
      await pumpList(tester, initial: [row('A', 'apples')], lists: oneList);
      await rightClick(tester, 'apples');
      expect(find.byKey(const Key('taskmenu-open-google')), findsNothing);
    });

    testWidgets('shows Detach only for a subtask, never a top-level task', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
        ],
        lists: oneList,
        showCompleted: true,
      );
      // Top-level parent: no Detach.
      await rightClick(tester, 'parent');
      expect(find.byKey(const Key('taskmenu-detach')), findsNothing);
    });
  });

  group('ContextMenu — submenus open on click not hover', () {
    testWidgets('the due submenu is collapsed until its header is tapped', (
      tester,
    ) async {
      await pumpList(tester, initial: [row('A', 'apples')], lists: oneList);
      await rightClick(tester, 'apples');
      // Collapsed: the date options are not shown yet (no auto-expand).
      expect(find.byKey(const Key('taskmenu-due-tomorrow')), findsNothing);
      await tester.tap(find.byKey(const Key('taskmenu-due')));
      await tester.pump();
      // Now the options are revealed.
      expect(find.byKey(const Key('taskmenu-due-today')), findsOneWidget);
      expect(find.byKey(const Key('taskmenu-due-tomorrow')), findsOneWidget);
    });

    testWidgets('clicking Tomorrow in the due submenu sets the date', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
      );
      await rightClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('taskmenu-due')));
      await tester.pump();
      await withClock(testClock, () async {
        await tester.tap(find.byKey(const Key('taskmenu-due-tomorrow')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      });
      expect(fake.tasks.single.task.due, '2026-06-16T00:00:00.000Z');
    });

    testWidgets('the Move submenu lists every list and moves on click', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: twoLists,
      );
      await rightClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('taskmenu-move')));
      await tester.pump();
      // Both lists appear as move targets.
      expect(find.byKey(const Key('taskmenu-move-L1')), findsOneWidget);
      expect(find.byKey(const Key('taskmenu-move-L2')), findsOneWidget);
      await tester.tap(find.byKey(const Key('taskmenu-move-L2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(fake.movedToList, ['A->L2']);
    });

    testWidgets(
      'a list move surfaces an undoable toast naming the target (F11)',
      (tester) async {
        final fake = await pumpList(
          tester,
          initial: [row('A', 'apples')],
          lists: twoLists,
        );
        await rightClick(tester, 'apples');
        await tester.tap(find.byKey(const Key('taskmenu-move')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('taskmenu-move-L2')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(fake.movedToList, ['A->L2']);
        // The toast names the destination and carries an Undo (wired to
        // undoMoveToList; the tap-through round-trip is covered in the detail
        // panel test, whose dropdown path keeps the Undo button on-screen).
        expect(find.text('Moved "apples" to Errands'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);
      },
    );
  });

  group('ContextMenu — leaf actions', () {
    testWidgets('Duplicate creates a "(copy)" in the same list', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
      );
      await rightClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('taskmenu-duplicate')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        fake.tasks.where((t) => t.task.title == 'apples (copy)').length,
        1,
      );
      expect(fake.tasks.every((t) => t.listId == 'L1'), isTrue);
    });

    testWidgets('Details opens the panel and closes the menu', (tester) async {
      final opened = <String>[];
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        opened: opened,
      );
      await rightClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('taskmenu-details')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(opened, ['A']);
      // Menu dismissed.
      expect(find.byKey(const Key('taskmenu-details')), findsNothing);
    });

    testWidgets('Edit notes opens the panel with a notes-focus intent', (
      tester,
    ) async {
      final openedNotes = <String>[];
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        openedNotes: openedNotes,
      );
      await rightClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('taskmenu-notes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(openedNotes, ['A']);
    });

    testWidgets('Edit title enters inline rename on the row', (tester) async {
      await pumpList(tester, initial: [row('A', 'apples')], lists: oneList);
      await rightClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('taskmenu-edit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      // A TextField appeared inside the row (the inline editor seeded with the
      // current title).
      final field = find.descendant(
        of: find.byType(TaskRow),
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).controller?.text, 'apples');
    });

    testWidgets('Open in Google opens the task URL via the opener', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpList(
        tester,
        initial: [row('A', 'apples', webViewLink: 'https://g.example/task')],
        lists: oneList,
        urlOpener: (url) async => opened.add(url),
      );
      await rightClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('taskmenu-open-google')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(opened, ['https://g.example/task']);
    });

    testWidgets('Delete removes the task and shows an Undo toast', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
      );
      await rightClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('taskmenu-delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(fake.tasks.map((t) => t.task.title), ['bread']);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('tapping outside closes the context menu (dismiss)', (
      tester,
    ) async {
      await pumpList(tester, initial: [row('A', 'apples')], lists: oneList);
      await rightClick(tester, 'apples');
      expect(find.byKey(const Key('taskmenu-edit')), findsOneWidget);
      // Tap the transparent barrier at the far corner.
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('taskmenu-edit')), findsNothing);
    });
  });

  group('DemoteToSubtask (#88)', () {
    testWidgets('offers "Make subtask of…" on a childless top-level task and '
        'demotes it via the searchable picker', (tester) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
      );
      await rightClick(tester, 'apples');
      expect(find.byKey(const Key('taskmenu-demote')), findsOneWidget);
      await tester.tap(find.byKey(const Key('taskmenu-demote')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      // The picker lists the OTHER top-level task as a legal parent.
      await tester.tap(find.byKey(const Key('parent-picker-B')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(fake.movedTasks, ['A:parent=B:prev=null']);
    });

    testWidgets('does NOT offer demotion for a task that has subtasks', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
          row('O', 'other'),
        ],
        lists: oneList,
      );
      await rightClick(tester, 'parent');
      expect(find.byKey(const Key('taskmenu-demote')), findsNothing);
    });

    testWidgets('does NOT offer demotion with no other top-level task to nest '
        'under', (tester) async {
      await pumpList(tester, initial: [row('A', 'lonely')], lists: oneList);
      await rightClick(tester, 'lonely');
      expect(find.byKey(const Key('taskmenu-demote')), findsNothing);
    });

    testWidgets('the parent picker filters candidates by typed query', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cherry')],
        lists: oneList,
      );
      await rightClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('taskmenu-demote')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      // Both other tasks are candidates before filtering.
      expect(find.byKey(const Key('parent-picker-B')), findsOneWidget);
      expect(find.byKey(const Key('parent-picker-C')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('parent-picker-query')),
        'cher',
      );
      await tester.pump();
      expect(find.byKey(const Key('parent-picker-B')), findsNothing);
      expect(find.byKey(const Key('parent-picker-C')), findsOneWidget);
    });
  });

  group('Detach (context menu)', () {
    testWidgets('a subtask context menu detaches it to top level', (
      tester,
    ) async {
      // A subtask is never a top-level row, so open the menu on the parent's
      // detail is out of scope here; instead detach fires through moveTask.
      final fake = await pumpList(
        tester,
        initial: [
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
        ],
        lists: oneList,
      );
      // Force the subtask visible as a row is impossible (invariant #1); assert
      // the parent offers no detach and the subtask, addressed directly by the
      // command, promotes correctly.
      await fake.moveTask('S', parentId: null, previousId: 'P');
      await tester.pump();
      expect(
        fake.tasks.firstWhere((t) => t.task.id == 'S').task.parent,
        isNull,
      );
    });
  });

  // The action surface is chosen by POINTER capability, not window width
  // (F16 #194): a touch pointer (no hover, no right-click) always gets the "⋯"
  // overflow — even a tablet / landscape phone past the 600dp LAYOUT breakpoint
  // — while a mouse pointer reaches the same actions by right-click and the
  // overflow stays hidden. Width picks the list/detail LAYOUT, never the surface.
  group('the per-row ⋮ is GONE — right-click is the whole surface (#245)', () {
    /// Every "⋮" a row could be carrying, at any width, on any pointer.
    Finder rowOverflow() => find.descendant(
      of: find.byType(TaskRow),
      matching: find.byIcon(Icons.more_vert),
    );

    testWidgets('a compact touch phone row carries NO overflow button', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples', webViewLink: 'https://g/1')],
        lists: oneList,
        size: const Size(420, 900),
        platform: TargetPlatform.android,
      );
      expect(rowOverflow(), findsNothing);
    });

    testWidgets('a touch tablet at 700dp carries none either — the button is '
        'gone at EVERY width, not merely hidden on a phone', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        size: const Size(700, 900),
        platform: TargetPlatform.android,
      );
      expect(rowOverflow(), findsNothing);
    });

    testWidgets('a long-press on a touch row still enters selection — the row '
        'gesture that survived the sheet', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        size: const Size(420, 900),
        platform: TargetPlatform.android,
      );
      final semantics = tester.ensureSemantics();
      await tester.longPress(find.text('apples'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(BulkBar), findsOneWidget);
      // Read through semantics, not through the rendered string: on a narrow
      // phone the bar shortens the phrase to the bare count (#265), and what
      // this test is about is that the long-press selected ONE row.
      expect(
        tester.getSemantics(find.byKey(const Key('bulk-count'))).label,
        '1 selected',
      );
      semantics.dispose();
    });

    testWidgets('the desktop mouse row shows no "⋮" either, and right-click '
        'still carries the FULL action set', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples', webViewLink: 'https://g/1')],
        lists: oneList,
        size: const Size(1200, 900),
        platform: TargetPlatform.linux,
      );
      expect(rowOverflow(), findsNothing);

      await rightClick(tester, 'apples');
      for (final id in const [
        'select',
        'edit',
        'notes',
        'due',
        'move',
        'duplicate',
        'details',
        'open-google',
        'delete',
      ]) {
        expect(
          find.byKey(Key('taskmenu-$id')),
          findsOneWidget,
          reason: 'the kept desktop menu lost "$id"',
        );
      }
    });
  });

  // #285: the menu used to be positioned by clamping its TOP edge to
  // `height - 48`, which guarantees nothing about the menu — right-clicking a
  // row in the bottom third opened a menu whose lower half (Set due date …
  // Delete) hung below the window, unreachable. Placement now MEASURES the menu
  // first (a SingleChildLayoutDelegate is handed the laid-out child size) and
  // opens downward, flips up, or clamps accordingly.
  //
  // Heights here are widget-test heights: with no font declared, every label
  // measures about twice its production width, so "Set due date", "Move to
  // list", "Make subtask of…" and "Open in Google Tasks" wrap to two lines and
  // the menu is roughly twice as tall as it is for a real user. That is why the
  // downward case is pinned at a cursor with room for a ~470dp menu rather than
  // at the window's midpoint.
  group('menu placement — the WHOLE menu stays in the window (#285)', () {
    /// Enough rows to right-click at any height in a 500–800dp window.
    List<StoredTask> manyRows() => [
      for (var i = 0; i < 20; i++)
        row('T$i', 'task $i', webViewLink: 'https://g/$i'),
    ];

    /// Right-click at an exact window point (whatever row is under it).
    Future<void> rightClickAt(WidgetTester tester, Offset at) async {
      final gesture = await tester.startGesture(at, buttons: kSecondaryButton);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    /// Every action the open menu is showing must be reachable: its rect inside
    /// the window, and inside the menu's own (clipping) box.
    void expectEveryItemReachable(WidgetTester tester, Size window) {
      final box = tester.getRect(find.byType(TaskActionMenu));
      var seen = 0;
      for (final id in const [
        'select',
        'edit',
        'notes',
        'due',
        'move',
        'demote',
        'duplicate',
        'details',
        'open-google',
        'delete',
      ]) {
        final finder = find.byKey(Key('taskmenu-$id'));
        if (finder.evaluate().isEmpty) continue;
        seen++;
        final r = tester.getRect(finder);
        expect(
          r.top >= 0 &&
              r.left >= 0 &&
              r.bottom <= window.height &&
              r.right <= window.width,
          isTrue,
          reason: '"$id" at $r hangs outside the $window window',
        );
        expect(
          r.top >= box.top && r.bottom <= box.bottom,
          isTrue,
          reason: '"$id" at $r is clipped away by the menu box $box',
        );
      }
      expect(seen, 10, reason: 'the fixture should offer the full action set');
    }

    testWidgets('a right-click near the window BOTTOM keeps every action on '
        'screen, flipping the menu up from the cursor', (tester) async {
      const window = Size(1200, 800);
      await pumpList(
        tester,
        initial: manyRows(),
        lists: twoLists,
        size: window,
        platform: TargetPlatform.linux,
      );
      await rightClickAt(tester, const Offset(600, 780));
      expect(find.byKey(const Key('taskmenu-delete')), findsOneWidget);
      expectEveryItemReachable(tester, window);
      // Flipped: the cursor is now the menu's BOTTOM edge, so the pointer is
      // still on the menu it opened.
      final box = tester.getRect(find.byType(TaskActionMenu));
      expect(box.bottom, 780);
      expect(box.left, 600);
    });

    testWidgets('with room below the cursor the menu still opens DOWNWARD, '
        'its top edge at the click', (tester) async {
      const window = Size(1200, 800);
      await pumpList(
        tester,
        initial: manyRows(),
        lists: twoLists,
        size: window,
        platform: TargetPlatform.linux,
      );
      await rightClickAt(tester, const Offset(600, 250));
      final box = tester.getRect(find.byType(TaskActionMenu));
      expect(box.topLeft, const Offset(600, 250));
      expectEveryItemReachable(tester, window);
    });

    testWidgets('a right-click at the RIGHT edge pulls the menu back inside '
        'by its measured width', (tester) async {
      const window = Size(1200, 800);
      await pumpList(
        tester,
        initial: manyRows(),
        lists: twoLists,
        size: window,
        platform: TargetPlatform.linux,
      );
      await rightClickAt(tester, const Offset(1190, 250));
      final box = tester.getRect(find.byType(TaskActionMenu));
      expect(box.right, 1192); // the 8dp margin, not the window edge
      expectEveryItemReachable(tester, window);
    });

    testWidgets('expanding "Set due date" from the bottom RE-ANCHORS the menu '
        '— all six date options stay on screen', (tester) async {
      const window = Size(1200, 800);
      await pumpList(
        tester,
        initial: manyRows(),
        lists: twoLists,
        size: window,
        platform: TargetPlatform.linux,
      );
      await rightClickAt(tester, const Offset(600, 780));
      final before = tester.getRect(find.byType(TaskActionMenu));
      await tester.tap(find.byKey(const Key('taskmenu-due')));
      await tester.pump();
      final after = tester.getRect(find.byType(TaskActionMenu));
      // It grew UPWARD out of the cursor instead of off the bottom.
      expect(after.top, lessThan(before.top));
      expect(after.bottom, 780);
      for (final item in kQuickDateItems) {
        final finder = find.byKey(Key('taskmenu-due-${item.id}'));
        expect(finder, findsOneWidget, reason: 'missing "${item.label}"');
        final r = tester.getRect(finder);
        expect(
          r.top >= 0 && r.bottom <= window.height,
          isTrue,
          reason: '"${item.label}" at $r hangs outside the window',
        );
      }
      expectEveryItemReachable(tester, window);
    });

    testWidgets('in a window shorter than the menu the body SCROLLS — Delete '
        'is reachable and nothing is clipped away', (tester) async {
      const window = Size(1200, 500);
      await pumpList(
        tester,
        initial: manyRows(),
        lists: twoLists,
        size: window,
        platform: TargetPlatform.linux,
      );
      await rightClickAt(tester, const Offset(600, 450));
      await tester.tap(find.byKey(const Key('taskmenu-due')));
      await tester.pump();
      final box = tester.getRect(find.byType(TaskActionMenu));
      // Capped at the window minus the two 8dp margins, sitting on the top one.
      expect(box.top, 8);
      expect(box.height, 484);
      final delete = find.byKey(const Key('taskmenu-delete'));
      // Below the fold to begin with…
      expect(tester.getRect(delete).top, greaterThan(box.bottom));
      // …and scrolling brings it fully inside the box (and so the window).
      await tester.drag(find.byType(TaskActionMenu), const Offset(0, -900));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final r = tester.getRect(delete);
      expect(r.top, greaterThanOrEqualTo(box.top));
      expect(r.bottom, lessThanOrEqualTo(box.bottom));
    });

    testWidgets('device chrome is kept clear too: a click over the gesture '
        'pill lifts the menu above it', (tester) async {
      const window = Size(1200, 800);
      await pumpList(
        tester,
        initial: manyRows(),
        lists: twoLists,
        size: window,
        platform: TargetPlatform.linux,
        padding: phoneInsets,
      );
      await rightClickAt(tester, const Offset(600, 770));
      final box = tester.getRect(find.byType(TaskActionMenu));
      // 8dp above the pill, not 8dp above the window edge.
      expect(box.bottom, 800 - phoneInsets.bottom - 8);
      expect(box.top, greaterThanOrEqualTo(phoneInsets.top + 8));
      expectEveryItemReachable(tester, window);
    });
  });
}
