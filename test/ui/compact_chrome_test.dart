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
// off the top, a reversal (or the end of the scroll) brings it back. The bulk
// bar is not part of it — a selection keeps its actions on screen whatever the
// scroll is doing — and a raised keyboard cancels the hide outright.
//
// Every assertion here is geometric or about what a finger can reach: where the
// app bar's render box actually IS, which surface a tap opened, which rows
// render. The harness is the REAL compact chrome over the REAL [TaskListView]
// (the list mounted inside a nested Navigator, the shape go_router's ShellRoute
// gives it), fed by an in-memory [FakeBackend] — no database, no clock, no
// network.

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/search.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeBackend, list, row;

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
    required FakeBackend fake,
    required List<StoredTaskList> lists,
    Size size = phone,
    String viewId = 'all',
    bool showCompleted = false,
    EdgeInsets padding = EdgeInsets.zero,
    ValueNotifier<double>? ime,
    bool disableAnimations = false,
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
                onNewTask: ref.read(newTaskRequestProvider.notifier).bump,
                composerOpen: ref.watch(composerOpenProvider),
                list: Navigator(
                  onGenerateRoute: (settings) => MaterialPageRoute<void>(
                    builder: (_) => TaskListView(
                      viewId: viewId,
                      selectedTaskId: null,
                      onOpenTask: _noop,
                    ),
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

  group('one bar (#244)', () {
    testWidgets('the toolbar actions live IN the app bar — search, sort and '
        'the overflow, with no second bar under it', (tester) async {
      final fake = FakeBackend(manyRows());
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
      final fake = FakeBackend(manyRows());
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
      final fake = FakeBackend([
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
      final fake = FakeBackend([
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
      final fake = FakeBackend([row('D', 'done thing', done: true)]);
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
      final fake = FakeBackend(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);
      expect(tester.getRect(appBar).top, 0, reason: 'pinned at rest');

      // Mid-flight it is on its way out: its own top has gone negative, so the
      // rows below have followed it up rather than sitting under a hole.
      final gesture = await dragListDown(tester, settle: false);
      await tester.pump(const Duration(milliseconds: 60));
      final leaving = tester.getRect(appBar);
      expect(leaving.top, lessThan(0));
      expect(leaving.bottom, lessThan(barHeight));
      expect(
        tester.getRect(find.byType(TaskListView)).top,
        closeTo(leaving.bottom, 0.5),
        reason: 'the rows keep their edge glued to the leaving bar',
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
      final fake = FakeBackend(manyRows());
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);
      expect(find.byType(FloatingActionButton), findsOneWidget);

      final gesture = await dragListDown(tester);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(appBar, findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(tester.getRect(appBar).top, 0);
    });

    testWidgets('a nudge under the threshold never flickers the bar', (
      tester,
    ) async {
      final fake = FakeBackend(manyRows());
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
      final fake = FakeBackend(manyRows());
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
      final fake = FakeBackend(manyRows());
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
      final fake = FakeBackend(manyRows());
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

    testWidgets('a selection keeps the bulk bar on screen whatever the scroll '
        'is doing', (tester) async {
      final fake = FakeBackend(manyRows());
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
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  testWidgets('the EXPANDED layout is untouched: no app bar, and the list '
      'keeps its own toolbar', (tester) async {
    final fake = FakeBackend(manyRows());
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
