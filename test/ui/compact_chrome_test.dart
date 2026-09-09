// The compact shell's ONE bar (#244).
//
// On a phone the list view used to keep TWO full-width bars pinned above the
// first row — the shell's [AppBar] (hamburger + view title) and the list's own
// toolbar (search, add-multiple, sort, show-completed) — and neither of them
// ever moved. Together with the bottom nav that is roughly a quarter of a
// 6-inch screen spent on chrome that never gets out of the way.
//
// So on the compact shell (and ONLY there) the toolbar's actions merge INTO the
// app bar, and that one bar rides the SAME scroll gesture the FAB already rides
// (#234): past [ListDetailScaffold.scrollThreshold] of downward travel it slides
// off the top, and a reversal brings it back — the END of a scroll brings back
// nothing (#305), because a bar that returns the moment a finger stops is a bar
// that shoves the list down under it. It is an OVERLAY, so neither its leaving
// nor its return moves a row. The bulk bar is not part of it — a selection keeps
// its actions on screen whatever the scroll is doing — and a raised keyboard
// cancels the hide outright.
//
// Every assertion here is geometric or about what a finger can reach: where the
// app bar's render box actually IS, which surface a tap opened, which rows
// render. The harness is the REAL compact chrome over the REAL [TaskListView]
// (the list mounted inside a nested Navigator, the shape go_router's ShellRoute
// gives it), fed by an in-memory [FakeCommands] — no database, no clock, no
// network.

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/search.dart';
import 'package:axiotask/src/ui/sync_feedback.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'composed_list.dart';
import 'detail_harness.dart' show FakeCommands, list, row;

void _noop(String _) {}

void main() {
  const phone = Size(400, 800);
  const desktop = Size(1000, 700);

  final destinations = [
    for (final v in SmartView.values)
      ShellDestination(
        icon: v.icon,
        selectedIcon: v.selectedIcon,
        label: v.label,
      ),
  ];

  /// The REAL adaptive shell over the REAL list at [size], with the list mounted
  /// inside a nested Navigator (the ShellRoute shape). [padding] injects device
  /// insets (a status bar) so the collapsed-bar geometry can be pinned against
  /// them; [ime] is the live bottom view inset — pushing a value into it mid-test
  /// is exactly what a soft keyboard coming up does to the shell.
  Future<void> pumpChrome(
    WidgetTester tester, {
    required FakeCommands fake,
    required List<StoredTaskList> lists,
    Size size = phone,
    String viewId = 'all',
    bool showCompleted = false,
    EdgeInsets padding = EdgeInsets.zero,
    Widget? syncLine,
    ValueNotifier<double>? ime,
    bool disableAnimations = false,
    TargetPlatform platform = TargetPlatform.android,
    ValueChanged<String> onOpenTask = _noop,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final imeInset = ime ?? ValueNotifier<double>(0);
    if (ime == null) addTearDown(imeInset.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(Prefs(showCompleted: showCompleted)),
          commandsProvider.overrideWithValue(fake),
          allTasksProvider.overrideWith((ref) => fake.tasksStream),
          listsProvider.overrideWith((ref) => Stream.value(lists)),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: platform),
          home: ValueListenableBuilder<double>(
            valueListenable: imeInset,
            builder: (context, bottomInset, child) => MediaQuery(
              data: MediaQueryData(
                size: size,
                padding: padding,
                viewInsets: EdgeInsets.only(bottom: bottomInset),
                // Stands in for the platform accessibility flag (Android
                // "remove animations" / desktop reduced motion).
                disableAnimations: disableAnimations,
              ),
              child: child!,
            ),
            child: Consumer(
              builder: (context, ref, _) => ListDetailScaffold(
                sidebar: const Text('SIDEBAR'),
                destinations: destinations,
                selectedIndex: SmartView.all.index,
                onDestinationSelected: (_) {},
                title: 'All Tasks',
                syncLine: syncLine,
                onNewTask: ref.read(newTaskRequestProvider.notifier).bump,
                composerOpen: ref.watch(composerOpenProvider),
                list: Navigator(
                  onGenerateRoute: (settings) => MaterialPageRoute<void>(
                    builder: (_) =>
                        composedList(viewId: viewId, onOpenTask: onOpenTask),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Enough rows to scroll a phone screen several times over.
  List<StoredTask> manyRows() => [
    for (var i = 0; i < 30; i++) row('T$i', 'Task $i', position: '$i'),
  ];

  final appBar = find.byType(AppBar);
  final overflow = find.byKey(const Key('toolbar-overflow'));

  /// The pinned bar's height on this (inset-free) test surface.
  const barHeight = kToolbarHeight;

  /// Scroll the list DOWN past the threshold WITHOUT letting go, and return the
  /// live gesture so the caller can reverse or end it. Two moves, not one: the
  /// first is eaten by the drag slop and the recognizer only forwards the
  /// pending delta once a second event arrives. [settle] leaves the collapse
  /// animation mid-flight when false, so a caller can pin the bar's offset
  /// while it is still on its way out.
  Future<TestGesture> dragListDown(
    WidgetTester tester, {
    bool settle = true,
  }) async {
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    if (settle) await tester.pump(const Duration(milliseconds: 300));
    return gesture;
  }

  // The failure barred: the export reachable only from the desktop toolbar, so
  // a phone — where the app bar IS the toolbar — could never export a view at
  // all. Touch has no right-click and no second place to look.
  group('exporting the view from the one bar (#297)', () {
    testWidgets('the app-bar overflow opens the export sheet for the view', (
      tester,
    ) async {
      final fake = FakeCommands([row('T1', 'Buy milk')]);
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      await tester.tap(find.descendant(of: appBar, matching: overflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('toolbar-export')));
      await tester.pumpAndSettle();

      expect(find.text('Export All Tasks'), findsOneWidget);
      // …and the sheet's buttons are inside the phone's safe area, not under
      // the bar it was opened from.
      expect(find.byKey(const Key('export-copy')), findsOneWidget);
    });
  });

  group('one bar (#244)', () {
    testWidgets('the toolbar actions live IN the app bar — search, sort and '
        'the overflow, with no second bar under it', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      expect(appBar, findsOneWidget, reason: 'exactly one bar above the rows');
      for (final key in const ['search-button', 'sort-dropdown']) {
        expect(
          find.descendant(of: appBar, matching: find.byKey(Key(key))),
          findsOneWidget,
          reason: '$key must be reachable in the one bar, not a second one',
        );
      }
      expect(
        find.descendant(of: appBar, matching: overflow),
        findsOneWidget,
        reason: 'the rest of the actions hang off the app bar overflow',
      );
      // Nothing is left behind in the body: the show-completed control used to
      // cost a whole 48dp row of the list and now lives in the overflow.
      expect(
        find.byKey(const Key('show-completed-toggle')),
        findsNothing,
        reason: 'a merged action must not ALSO render as a second bar',
      );
      // The first row starts directly under the one bar.
      expect(
        tester.getRect(find.text('Task 0')).top,
        lessThan(tester.getRect(appBar).bottom + 24),
        reason: 'no second bar of chrome between the app bar and row one',
      );
    });

    testWidgets('every merged action is reachable: search opens the overlay', (
      tester,
    ) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      await tester.tap(
        find.descendant(
          of: appBar,
          matching: find.byKey(const Key('search-button')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(SearchOverlay), findsOneWidget);
    });

    testWidgets('every merged action is reachable: sort reorders the rows', (
      tester,
    ) async {
      final fake = FakeCommands([
        row('A', 'Zebra', position: '1'),
        row('B', 'Apple', position: '2'),
      ]);
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);
      expect(
        tester.getRect(find.text('Zebra')).top,
        lessThan(tester.getRect(find.text('Apple')).top),
        reason: 'manual order first',
      );

      await tester.tap(
        find.descendant(
          of: appBar,
          matching: find.byKey(const Key('sort-dropdown')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alphabetical').last);
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.text('Apple')).top,
        lessThan(tester.getRect(find.text('Zebra')).top),
        reason: 'the sort picked in the app bar must reorder the list',
      );
    });

    testWidgets('every merged action is reachable: the overflow carries '
        'add-multiple, show-completed and select-tasks', (tester) async {
      final fake = FakeCommands([
        row('A', 'apples'),
        row('D', 'done thing', done: true),
      ]);
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);
      expect(find.text('done thing'), findsNothing);

      // Show completed → the completed row renders.
      await tester.tap(overflow);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('show-completed-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('done thing'), findsOneWidget);

      // Select tasks → multi-select with nothing selected yet.
      await tester.tap(overflow);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('toolbar-select-tasks')));
      await tester.pumpAndSettle();
      expect(find.byType(BulkBar), findsOneWidget);
      await tester.tap(find.byKey(const Key('bulk-clear-selection')));
      await tester.pumpAndSettle();

      // Add multiple → the bulk-add dialog (its field autofocuses, so this is
      // the LAST step: never pumpAndSettle with a live cursor timer).
      await tester.tap(overflow);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bulk-add-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('bulk-add-text')), findsOneWidget);
    });

    testWidgets('a SMART view offers no clear-completed in the overflow — '
        'there is no single list to clear', (tester) async {
      final fake = FakeCommands([row('D', 'done thing', done: true)]);
      addTearDown(fake.dispose);
      await pumpChrome(
        tester,
        fake: fake,
        lists: [list('L1', 'Groceries')],
        viewId: 'missed',
        showCompleted: true,
      );

      await tester.tap(overflow);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clear-completed-button')), findsNothing);
      expect(
        find.byKey(const Key('toolbar-select-tasks')),
        findsOneWidget,
        reason: 'the overflow itself is still there',
      );
    });
  });

  group('the bar rides the scroll (#244)', () {
    testWidgets('scrolling down past the threshold slides the bar off the top; '
        'scrolling back up returns it', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);
      expect(tester.getRect(appBar).top, 0, reason: 'pinned at rest');

      // Mid-flight it is on its way out: its own top has gone negative, and it
      // is sliding OVER the rows — which do not move with it (#305).
      final gesture = await dragListDown(tester, settle: false);
      await tester.pump(const Duration(milliseconds: 20));
      final travelling = tester.getRect(find.text('Task 12'));
      await tester.pump(const Duration(milliseconds: 60));
      final leaving = tester.getRect(appBar);
      expect(leaving.top, lessThan(0));
      expect(leaving.bottom, lessThan(barHeight));
      expect(
        tester.getRect(find.text('Task 12')),
        travelling,
        reason: 'the leaving bar uncovers rows; it does not tow them',
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(
        appBar,
        findsNothing,
        reason:
            'a deliberate scroll down takes the bar off the screen '
            'entirely — not merely out of sight, out of the hit test and the '
            'semantics tree with it',
      );

      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getRect(appBar).top,
        0,
        reason: 'a reversal brings the bar straight back',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(appBar).top, 0, reason: 'at rest the bar is there');
    });

    testWidgets('the bar and the FAB leave and return together — one gesture, '
        'one threshold', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);
      expect(find.byType(FloatingActionButton), findsOneWidget);

      final gesture = await dragListDown(tester);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(appBar, findsNothing);

      // …and they come back on the same reversal, together. Not on the END of
      // the scroll: neither half of the chrome returns until the list moves
      // back up (#305).
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(tester.getRect(appBar).top, 0);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a nudge under the threshold never flickers the bar', (
      tester,
    ) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getRect(appBar).top,
        0,
        reason: 'below the shared threshold the bar must not move at all',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('the collapsed bar still leaves the status bar to the system', (
      tester,
    ) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(
        tester,
        fake: fake,
        lists: [list('L1', 'Groceries')],
        padding: const EdgeInsets.only(top: 50),
      );

      final gesture = await dragListDown(tester);
      expect(appBar, findsNothing);
      expect(
        tester.getRect(find.byType(TaskListView)).top,
        greaterThanOrEqualTo(50),
        reason: 'rows must never slide under the status bar / notch',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a raised keyboard cancels the hide — the bar comes back even '
        'mid-scroll', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      final ime = ValueNotifier<double>(0);
      addTearDown(ime.dispose);
      await pumpChrome(
        tester,
        fake: fake,
        lists: [list('L1', 'Groceries')],
        ime: ime,
      );

      final gesture = await dragListDown(tester);
      expect(appBar, findsNothing);

      // The IME comes up under the same gesture (the shell sees a bottom view
      // inset appear): the user is typing, and a hidden bar would strand them.
      ime.value = 300;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getRect(appBar).top,
        0,
        reason: 'a keyboard-up state never leaves the user without the bar',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('with animations off the bar still leaves — it just stops '
        'travelling to get there', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(
        tester,
        fake: fake,
        lists: [list('L1', 'Groceries')],
        disableAnimations: true,
      );

      // No settling pump: with motion off the bar is gone on the very frame
      // the threshold is crossed.
      final gesture = await dragListDown(tester, settle: false);
      expect(appBar, findsNothing);

      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      expect(tester.getRect(appBar).top, 0);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets("the bulk bar's ⋮ opens ON TOP of the shell — its entries are "
        'reachable, not under the FAB or the nav bar', (tester) async {
      // The bar lives INSIDE the shell's nested navigator (the ShellRoute
      // shape), and a surface raised from there can render under the FAB and
      // the bottom NavigationBar the shell draws over it (#234). The two
      // rarest bulk ops moved behind this menu (#265), so "it opens" is not
      // enough — a finger has to be able to land on what it opened.
      final fake = FakeCommands([
        row('T1', 'oranges'),
        row('T2', 'lemons', position: '2'),
      ]);
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      await tester.longPress(find.text('oranges'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bulk-overflow')));
      await tester.pumpAndSettle();

      for (final key in const ['bulk-duplicate', 'bulk-demote']) {
        expect(
          find.byKey(Key(key)).hitTestable(),
          findsOneWidget,
          reason: '$key opened somewhere no finger on a phone can reach it',
        );
      }
      // …and a system back closes the menu ALONE. The menu is a route on the
      // shell's nested navigator, so it is a back rung of its own: one back is
      // one step, and the selection behind it survives.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bulk-duplicate')), findsNothing);
      expect(
        find.byType(BulkBar),
        findsOneWidget,
        reason:
            'the back that closed the menu must not also clear the '
            'selection under it',
      );

      await tester.tap(find.byKey(const Key('bulk-overflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bulk-duplicate')).hitTestable());
      await tester.pumpAndSettle();
      expect(
        fake.tasks.map((t) => t.task.title),
        contains('oranges (copy)'),
        reason: 'the entry a finger reached must actually run',
      );
    });

    testWidgets('a selection keeps the bulk bar on screen whatever the scroll '
        'is doing', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      await tester.longPress(find.text('Task 0'));
      await tester.pumpAndSettle();
      expect(find.byType(BulkBar), findsOneWidget);

      final gesture = await dragListDown(tester);
      expect(
        appBar,
        findsNothing,
        reason: 'the app bar still rides the scroll during a selection',
      );
      expect(
        find.byType(BulkBar).hitTestable(),
        findsOneWidget,
        reason: 'the bulk bar is not part of the collapsing chrome',
      );
      final bulk = tester.getRect(find.byType(BulkBar));
      expect(bulk.top, greaterThanOrEqualTo(0));
      expect(bulk.bottom, lessThanOrEqualTo(800));

      // …and with the bar back it is UNDER it, not behind it: the shell's bar
      // is painted over this pane (#305), so a bulk bar that merely took the
      // top of the pane would be invisible for as long as the bar is there.
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getRect(find.byType(BulkBar)).top,
        tester.getRect(appBar).bottom,
        reason: 'the bulk bar rides the one bar\'s bottom edge',
      );
      expect(
        find.byType(BulkBar).hitTestable(),
        findsOneWidget,
        reason: 'and a finger reaches it there',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  // The bar that came back on its own (#305). #244 asked for hide-on-scroll-
  // down / return-on-scroll-up, and the merged shell returned it on
  // ScrollEndNotification as well — so every time a finger stopped moving, the
  // bar slid back INTO THE LAYOUT and shoved the whole list down by its own
  // height under a finger that had just lifted. Two rules replace it: the bar
  // returns only when the list moves back up (or is inside the bar's own band,
  // or the keyboard is up), and it is an OVERLAY — its slot is padding INSIDE
  // the scroll view, so the rows it uncovers are rows, and neither leaving nor
  // returning re-lays-out a single one.

  group('the bar never returns at rest, and never moves a row (#305)', () {
    /// A row far enough down the list to still be on screen after the scroll —
    /// the thing whose position must not change. (The rows are ordered by their
    /// string position, so the fifth one down is "Task 12".)
    final anchor = find.text('Task 12');

    testWidgets('a scroll that merely STOPS leaves the bar away, and not one '
        'row moves', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      final gesture = await dragListDown(tester);
      expect(appBar, findsNothing, reason: 'the deliberate scroll hid it');
      final resting = tester.getRect(anchor);

      // The finger lifts. Nothing about the list has moved back up, so nothing
      // about the chrome may change either.
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        appBar,
        findsNothing,
        reason:
            'a scroll that ended is not a scroll up: the bar must stay '
            'away until the user asks for it back',
      );
      expect(
        tester.getRect(anchor),
        resting,
        reason: 'the end of a scroll must not move a single row',
      );
    });

    testWidgets('the bulk bar is opaque to the finger too — a tap on it never '
        'reaches the row scrolled under it', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      await tester.longPress(find.text('Task 0'));
      await tester.pumpAndSettle();
      // The count is what the bar has room to say on a 400dp phone: one task.
      expect(
        find.descendant(of: find.byType(BulkBar), matching: find.text('1')),
        findsOneWidget,
      );

      // Scroll a row up under the bulk bar without sending the app bar away.
      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final bulk = tester.getRect(find.byType(BulkBar));
      expect(
        bulk.top,
        tester.getRect(appBar).bottom,
        reason: 'the bulk bar hangs off the one bar',
      );
      // Dead space: inside the bar's own box, above the 48dp rows of its
      // controls — and directly over a row.
      await tester.tapAt(Offset(bulk.center.dx, bulk.top + 2));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(BulkBar), matching: find.text('1')),
        findsOneWidget,
        reason:
            'a tap that fell through the bulk bar would toggle the row '
            'hiding behind it into or out of the selection',
      );
    });

    testWidgets('a tap on the bar never reaches the rows travelling under it', (
      tester,
    ) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      final opened = <String>[];
      await pumpChrome(
        tester,
        fake: fake,
        lists: [list('L1', 'Groceries')],
        onOpenTask: opened.add,
      );

      // Scroll a little — not far enough to send the bar away — so that a row
      // is genuinely underneath it.
      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(appBar).top, 0, reason: 'the bar is still there');
      // A row well clear of the bar opens on a tap — the control that makes
      // the assertion below mean something.
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(opened, isNotEmpty, reason: 'a tap on a row opens it');
      opened.clear();

      // The bar's own empty middle — its title, over a row.
      await tester.tapAt(const Offset(200, 28));
      await tester.pumpAndSettle();
      expect(
        opened,
        isEmpty,
        reason:
            'the bar is opaque to the finger as well as to the eye: a tap '
            'on it must never open the task hiding behind it',
      );
    });

    testWidgets('the bar returns OVER the rows — the return moves nothing', (
      tester,
    ) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      final gesture = await dragListDown(tester);
      expect(appBar, findsNothing);

      // A reversal past the threshold asks for the bar back; the finger then
      // holds still for the whole of its travel. Everything that moves from
      // here is the bar moving, and the rows must not be part of it.
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      final held = tester.getRect(anchor);

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.getRect(anchor),
        held,
        reason: 'mid-return the bar was still pushing the rows down',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(appBar).top, 0, reason: 'the bar is back');
      expect(
        tester.getRect(anchor),
        held,
        reason:
            'the returning bar must slide OVER the list, not re-lay it '
            'out — a row moving under a finger is the whole defect',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('inside the bar\'s own band the bar stays: a scroll too short '
        'to fill the space it would leave never hides it', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);
      final pinned = tester.getRect(anchor);

      // Past the 24dp reaction threshold, but still inside the bar's own
      // height: hiding here would uncover a band of scroll padding — bar-less
      // AND row-less — instead of content.
      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester.getRect(appBar).top,
        0,
        reason:
            'the list has not yet scrolled the bar\'s own height, so there '
            'is nothing to fill the band it would leave behind',
      );
      expect(
        tester.getRect(anchor).top,
        pinned.top - 40,
        reason: 'the rows scrolled by exactly what the finger moved',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('scrolled back to the top the bar is always there — the '
        'chrome is never left unreachable', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      final gesture = await dragListDown(tester);
      expect(appBar, findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(appBar, findsNothing, reason: 'still away at rest');

      // Back to the top, and the bar with it.
      final back = await tester.startGesture(const Offset(200, 400));
      await back.moveBy(const Offset(0, 20));
      await tester.pump();
      await back.moveBy(const Offset(0, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await back.up();
      await tester.pumpAndSettle();

      expect(tester.getRect(appBar).top, 0);
      expect(
        tester.getRect(find.text('Task 0')).top,
        greaterThanOrEqualTo(tester.getRect(appBar).bottom),
        reason: 'and the first row sits under it, not behind it',
      );
    });
  });

  // The bar's HEIGHT under a status bar (#262). A [Scaffold] adds
  // MediaQuery.padding.top to whatever height its app bar declares
  // (Scaffold._appBarMaxHeight) and an [AppBar] insets ITSELF past the status
  // bar through its own SafeArea — so a collapsing wrapper that also folds the
  // inset into its preferred height has the phone reserve it TWICE. Nothing
  // clips: the AppBar's top-aligned fill takes the whole over-tall slot, so the
  // toolbar draws where it belongs and the surplus becomes a band of bar-
  // coloured nothing under it, with every row pushed down past it and the sync
  // line — bottom-aligned in the bar's flexibleSpace — floating at the bottom
  // of the band instead of on the bar's edge (#255).
  group('the bar reserves the status bar ONCE (#262)', () {
    /// A phone status bar / notch, injected as a real device inset.
    const statusBar = 48.0;

    /// Where the pinned bar must END: one status bar, one toolbar, nothing
    /// else. Every row and the sync line hang off this edge.
    const barBottom = statusBar + barHeight;

    testWidgets('the pinned bar is one toolbar tall under the notch, and the '
        'rows start at its edge — no empty band between', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(
        tester,
        fake: fake,
        lists: [list('L1', 'Groceries')],
        padding: const EdgeInsets.only(top: statusBar),
      );

      final bar = tester.getRect(appBar);
      expect(bar.top, 0, reason: 'the bar still starts at the screen top');
      expect(
        bar.bottom,
        barBottom,
        reason:
            'the status bar is reserved ONCE: a second inset in the bar\'s own '
            'preferred height buys a ${statusBar}dp band of dead bar under the '
            'toolbar',
      );
      expect(
        tester.getRect(find.byType(TaskRow).first).top,
        barBottom,
        reason:
            'the first row starts exactly where the bar ends — a second '
            'inset would buy a band of dead bar above it',
      );
    });

    testWidgets('the sync line rides the bar\'s real bottom edge under the '
        'notch, not the bottom of an over-tall slot (#255)', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(
        tester,
        fake: fake,
        lists: [list('L1', 'Groceries')],
        padding: const EdgeInsets.only(top: statusBar),
        syncLine: const SyncProgressLine(running: true),
      );

      final line = tester.getRect(find.byType(SyncProgressLine));
      expect(
        line.bottom,
        barBottom,
        reason: 'the line marks the bar/list seam — it must sit ON it',
      );
      expect(
        line.top,
        barBottom - kSyncLineHeight,
        reason: 'and it is still the same 2dp line, not a stretched band',
      );
      expect(
        tester.getRect(find.byType(TaskRow).first).top,
        line.bottom,
        reason: 'the line and the first row share one edge',
      );
    });

    testWidgets('through every frame of the slide the rows hold still, and '
        'none of them is ever drawn under the notch', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(
        tester,
        fake: fake,
        lists: [list('L1', 'Groceries')],
        padding: const EdgeInsets.only(top: statusBar),
      );

      // The finger stops moving the instant the threshold is crossed, so every
      // pixel that moves from here belongs to the bar alone.
      final gesture = await dragListDown(tester, settle: false);
      await tester.pump();
      final held = tester.getRect(find.text('Task 12'));
      var gone = false;
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (appBar.evaluate().isEmpty) gone = true;
        expect(
          tester.getRect(find.text('Task 12')),
          held,
          reason:
              'frame $frame: the bar slides over the rows, never through '
              'their layout',
        );
        expect(
          tester.getRect(find.byType(TaskListView)).top,
          statusBar,
          reason:
              'frame $frame: the list is clipped at the notch, so no row '
              'can ever be drawn under it',
        );
      }
      expect(
        gone,
        isTrue,
        reason:
            'the slide must actually take the bar off the screen, or this '
            'proves nothing about what it did to the rows on the way',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  // A narrow window on a MOUSE is the compact shell too (width does not decide
  // — #208/#216), and it keeps the always-visible quick-add bar the FAB stands
  // in for on touch. That bar holds the top of the pane, so there is nothing
  // there to scroll under the shell's bar: the band it would leave behind would
  // be empty. So a fine pointer gets the bar PINNED, and the composer inset
  // below it rather than painted behind it.
  group('a narrow window with a mouse keeps its bar (#305)', () {
    const composer = Key('quick-add-bar');

    testWidgets('the quick-add bar sits under the one bar, and a scroll never '
        'takes the bar off it', (tester) async {
      final fake = FakeCommands(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(
        tester,
        fake: fake,
        lists: [list('L1', 'Groceries')],
        platform: TargetPlatform.linux,
      );

      expect(find.byKey(composer), findsOneWidget);
      expect(
        tester.getRect(find.byKey(composer)).top,
        greaterThanOrEqualTo(tester.getRect(appBar).bottom),
        reason: 'a composer painted behind the bar is one nobody can type in',
      );

      final gesture = await dragListDown(tester);
      expect(
        tester.getRect(appBar).top,
        0,
        reason:
            'the collapsing chrome is a touch affordance: with a composer '
            'holding the top of the pane there is nothing to fill the band '
            'the bar would leave',
      );
      expect(
        tester.getRect(find.byKey(composer)).top,
        greaterThanOrEqualTo(tester.getRect(appBar).bottom),
        reason: 'and the composer stays where it was',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  testWidgets('the EXPANDED layout is untouched: no app bar, and the list '
      'keeps its own toolbar', (tester) async {
    final fake = FakeCommands(manyRows());
    addTearDown(fake.dispose);
    await pumpChrome(
      tester,
      fake: fake,
      lists: [list('L1', 'Groceries')],
      size: desktop,
    );

    expect(appBar, findsNothing, reason: 'the desktop shell has no app bar');
    expect(
      find.byKey(const Key('show-completed-toggle')),
      findsOneWidget,
      reason: 'the merge is compact-only — desktop keeps its inline toolbar',
    );
    expect(find.byKey(const Key('search-button')), findsOneWidget);
  });
}
