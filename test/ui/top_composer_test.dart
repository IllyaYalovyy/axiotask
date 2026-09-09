// The phone's creation surface is a bar pinned UNDER THE APP BAR (#304), not a
// bottom sheet.
//
// The defect this suite pins down is one of position, and it cost the user the
// whole "add three things in a row" workflow: the composer opened at the BOTTOM
// of the screen while every task it created landed at the TOP of the list. The
// row you just typed was never where you were looking, and checking it meant
// scrolling the list up past everything the sheet was covering.
//
// So the composer now hangs off the app bar, directly above the first row:
//
//   • it opens where the new rows land, and each add inserts its row IMMEDIATELY
//     under it — nothing is covered, because the list is PUSHED down rather
//     than overlaid, and nothing scrolls;
//   • the field keeps focus between adds, so "a", "b", "c" is three taps of
//     submit and no re-aiming;
//   • the soft keyboard cannot reach it. The old sheet lived in the keyboard's
//     half of the screen and spent a whole contract (#166) staying out of its
//     way; a bar under the app bar is structurally out of reach, and the IME
//     test here is what keeps it that way.
//
// Determinism: static provider streams over the in-memory FakeCommands (no
// database, no clock, no network); no seeded task carries a due date, so
// nothing reads the clock. Animations are driven by explicit `pump(duration)`
// wherever a frame mid-flight is the thing under test.

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'composed_list.dart';
import 'detail_harness.dart' show FakeCommands, list, row;

void _noop(String _) {}

void main() {
  const phone = Size(400, 800);

  final destinations = [
    for (final v in SmartView.values)
      ShellDestination(
        icon: v.icon,
        selectedIcon: v.selectedIcon,
        label: v.label,
      ),
  ];

  /// The REAL compact chrome over [fake] at phone width, with the list mounted
  /// inside a NESTED navigator — the shape go_router's ShellRoute gives it.
  Widget tree({
    required FakeCommands fake,
    required List<StoredTaskList> lists,
    double viewInsetsBottom = 0,
  }) => ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(const Prefs()),
      commandsProvider.overrideWithValue(fake),
      allTasksProvider.overrideWith((ref) => fake.tasksStream),
      listsProvider.overrideWith((ref) => Stream.value(lists)),
    ],
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: phone,
          viewInsets: EdgeInsets.only(bottom: viewInsetsBottom),
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
                builder: (_) => composedList(viewId: 'all', onOpenTask: _noop),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> pumpChrome(
    WidgetTester tester, {
    required FakeCommands fake,
    required List<StoredTaskList> lists,
  }) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(tree(fake: fake, lists: lists));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  final fab = find.byType(FloatingActionButton);
  final surface = find.byKey(const Key('composer-surface'));
  final field = find.widgetWithText(TextField, 'Add a task');
  final submit = find.byKey(const Key('quick-add-submit'));

  /// The list's own scroll position (the TextField inside the composer has a
  /// Scrollable of its own, so the list's is found through one of its rows).
  double listOffset(WidgetTester tester, Finder anyRow) => tester
      .state<ScrollableState>(
        find.ancestor(of: anyRow, matching: find.byType(Scrollable)).first,
      )
      .position
      .pixels;

  Future<void> openComposer(WidgetTester tester) async {
    await tester.tap(fab);
    await tester.pumpAndSettle();
  }

  testWidgets('the composer opens UNDER the app bar and ABOVE the first row — '
      'nothing it creates is out of sight (#304)', (tester) async {
    final fake = FakeCommands([row('T1', 'Buy milk')]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    await openComposer(tester);

    final barBottom = tester.getRect(find.byType(AppBar)).bottom;
    final composer = tester.getRect(surface);
    final firstRow = tester.getRect(find.text('Buy milk'));
    expect(
      composer.top,
      greaterThanOrEqualTo(barBottom),
      reason: 'the composer hangs off the app bar, never under it',
    );
    expect(
      composer.bottom,
      lessThanOrEqualTo(firstRow.top),
      reason: 'and the list is PUSHED below it, not covered by it',
    );
    expect(
      tester.getRect(field).top,
      greaterThanOrEqualTo(barBottom),
      reason: 'the field itself is in the top third of the screen',
    );
  });

  testWidgets('three adds in a row land directly under the composer, newest '
      'first, without scrolling the list (#304)', (tester) async {
    var minted = 0;
    final fake = FakeCommands([
      for (var i = 0; i < 20; i++) row('T$i', 'Task $i', position: '$i'),
    ], newId: () => 'new-${minted++}');
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    await openComposer(tester);
    final offsetBefore = listOffset(tester, find.text('Task 0'));

    for (final title in ['a', 'b', 'c']) {
      await tester.enterText(field, title);
      await tester.tap(submit);
      await tester.pumpAndSettle();
    }

    // Newest first, immediately below the composer — the row the user just
    // typed is the first thing under the field they typed it into.
    final composerBottom = tester.getRect(surface).bottom;
    final tops = {
      for (final t in ['a', 'b', 'c']) t: tester.getRect(find.text(t)).top,
    };
    expect(tops['c']!, greaterThanOrEqualTo(composerBottom));
    expect(tops['c']!, lessThan(tops['b']!));
    expect(tops['b']!, lessThan(tops['a']!));
    expect(
      tops['a']!,
      lessThan(tester.getRect(find.text('Task 0')).top),
      reason: 'the three new rows are above every row that was there before',
    );

    expect(
      listOffset(tester, find.text('Task 0')),
      offsetBefore,
      reason: 'creating a task never scrolls the list out from under the user',
    );
    expect(
      surface.hitTestable(),
      findsOneWidget,
      reason: 'the composer stays open and reachable for the next add',
    );
    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: 'and keeps the caret, so the next title is just typing',
    );
  });

  testWidgets('opening the composer keeps the list exactly where it was — it '
      'is pushed, not rebuilt (#304)', (tester) async {
    final fake = FakeCommands([
      // Positions padded so the manual (position) order IS the numeric one:
      // '10' sorts before '2' as a string, and a test that names a row has to
      // know where that row is.
      for (var i = 0; i < 30; i++)
        row('T$i', 'Task $i', position: '$i'.padLeft(2, '0')),
    ]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    // Read something further down the list, then ask for the composer.
    await tester.drag(find.text('Task 1'), const Offset(0, -200));
    await tester.pumpAndSettle();
    final anyRow = find.text('Task 5');
    final scrolled = listOffset(tester, anyRow);
    expect(scrolled, greaterThan(0), reason: 'the list really did move');
    final before = tester.getRect(anyRow);

    await openComposer(tester);

    expect(
      listOffset(tester, anyRow),
      scrolled,
      reason:
          'the composer is laid out ABOVE the list, not around it — a pane '
          'that was rebuilt instead would have dropped the scroll offset (and '
          'every row\'s entrance with it)',
    );
    final composerBottom = tester.getRect(surface).bottom;
    final after = tester.getRect(anyRow);
    expect(
      after.top - before.top,
      closeTo(composerBottom - tester.getRect(find.byType(AppBar)).bottom, 0.5),
      reason:
          'every row moved down by the composer\'s height, and by nothing '
          'else — the app bar\'s own band was already theirs',
    );
  });

  testWidgets('the soft keyboard cannot cover the composer (#304)', (
    tester,
  ) async {
    final fake = FakeCommands([row('T1', 'Buy milk')]);
    addTearDown(fake.dispose);
    final lists = [list('L1', 'Groceries')];
    await pumpChrome(tester, fake: fake, lists: lists);
    await openComposer(tester);

    // The keyboard comes up under the composer's own focus request.
    await tester.pumpWidget(
      tree(fake: fake, lists: lists, viewInsetsBottom: 300),
    );
    await tester.pumpAndSettle();

    final composer = tester.getRect(surface);
    expect(
      composer.bottom,
      lessThanOrEqualTo(phone.height - 300),
      reason: 'the composer is entirely in the half the keyboard leaves',
    );
    expect(
      field.hitTestable(),
      findsOneWidget,
      reason: 'and the field it is there to offer is still tappable',
    );
  });

  testWidgets('opening the composer brings the collapsed app bar back, and the '
      'composer lands under it (#304/#305)', (tester) async {
    final fake = FakeCommands([
      for (var i = 0; i < 30; i++) row('T$i', 'Task $i', position: '$i'),
    ]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    // Non-happy path: the user has scrolled down, so the app bar is GONE (it
    // stays away at rest, #305) — and the composer is opened into that state.
    await tester.fling(find.text('Task 0'), const Offset(0, -300), 1000);
    await tester.pumpAndSettle();
    expect(
      find.byType(AppBar),
      findsNothing,
      reason: 'the collapsed bar really is off screen before the FAB is tapped',
    );

    await openComposer(tester);

    expect(
      find.byType(AppBar),
      findsOneWidget,
      reason: 'a composer hanging off the bar cannot hang off nothing',
    );
    expect(
      tester.getRect(surface).top,
      greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
      reason: 'and it sits under the bar it just brought back',
    );
  });
}
