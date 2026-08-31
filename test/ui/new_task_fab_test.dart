// The touch creation affordance as ONE entity (#234): the FAB and the
// bottom-sheet composer it opens.
//
// The defect this suite pins down: the composer was pushed onto the SHELL's
// nested navigator (go_router's ShellRoute), while the FAB belongs to the outer
// compact Scaffold — so the "modal" rendered UNDER the FAB and the FAB covered
// the composer's own submit button. Task creation on a phone was broken by
// construction, not by z-order luck.
//
// So the harness below models the real tree exactly: a [ListDetailScaffold]
// whose `list` child sits inside its OWN [Navigator], the way the ShellRoute
// mounts it. Every assertion is about what a finger can see and reach — the
// composer's submit is hit-testable, the FAB is on screen or it is not, the last
// row's date button clears the FAB — never about which route object the sheet
// landed on.
//
// Determinism: static provider streams over the in-memory FakeBackend (no
// database, no clock, no network). Animations are driven by explicit
// `pump(duration)` where a frame in the MIDDLE of the morph is the thing under
// test.

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/new_task_fab.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeBackend, list, row;

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

  /// The REAL compact chrome over [fake], at phone width, with the list mounted
  /// inside a NESTED navigator — the shape go_router's ShellRoute gives it, and
  /// the reason the composer used to render under the FAB.
  Future<void> pumpChrome(
    WidgetTester tester, {
    required FakeBackend fake,
    required List<StoredTaskList> lists,
    double viewInsetsBottom = 0,
  }) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
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
                    builder: (_) => const TaskListView(
                      viewId: 'all',
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

  final fab = find.byType(FloatingActionButton);
  final submit = find.byKey(const Key('quick-add-submit'));

  testWidgets('the composer layers ABOVE the shell — its submit button is '
      'reachable and no FAB is left on screen (#234)', (tester) async {
    final fake = FakeBackend([row('T1', 'Buy milk')]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    await tester.tap(fab);
    await tester.pumpAndSettle();

    // The FAB became the composer: while it is open there is no FAB anywhere.
    expect(
      fab,
      findsNothing,
      reason: 'the FAB morphs INTO the composer — it cannot also sit over it',
    );
    // And the composer's own submit is the topmost thing at its own centre: a
    // tap that lands on anything else fails here (warnIfMissed).
    expect(submit.hitTestable(), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Add a task'),
      'Bread',
    );
    await tester.tap(submit);
    await tester.pump();
    expect(
      fake.tasks.map((t) => t.task.title),
      contains('Bread'),
      reason: 'the submit the user can see must be the submit that creates',
    );
  });

  testWidgets('open is ONE morph: mid-flight the composer is still unfolding '
      'from the FAB corner (#234)', (tester) async {
    final fake = FakeBackend([row('T1', 'Buy milk')]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    // Where the FAB stands right now — the corner the composer must come out of.
    final fabRect = tester.getRect(fab);
    await tester.tap(fab);
    await tester.pump(); // the route is pushed; the morph is at its start

    final surface = find.byKey(const Key('composer-surface'));
    expect(surface, findsOneWidget);
    final start = tester.getRect(surface);
    expect(
      start.width,
      closeTo(NewTaskFab.size, 0.5),
      reason: 'the composer BEGINS as the FAB — one surface, not two',
    );
    expect(
      start.right,
      closeTo(fabRect.right, 0.5),
      reason: 'and it begins in the corner the FAB just left',
    );

    // Mid-flight it is neither: it is unfolding.
    await tester.pump(const Duration(milliseconds: 100));
    final mid = tester.getRect(surface).width;
    expect(mid, greaterThan(NewTaskFab.size));
    expect(mid, lessThan(phone.width));

    await tester.pumpAndSettle();
    final open = tester.getRect(surface);
    expect(open.width, phone.width, reason: 'and lands as a full-width sheet');
    expect(open.right, phone.width);
  });

  testWidgets('the FAB is gone while the keyboard is up (#234)', (
    tester,
  ) async {
    final fake = FakeBackend([row('T1', 'Buy milk')]);
    addTearDown(fake.dispose);
    await pumpChrome(
      tester,
      fake: fake,
      lists: [list('L1', 'Groceries')],
      viewInsetsBottom: 300,
    );

    expect(
      fab,
      findsNothing,
      reason:
          'a raised keyboard means something has focus; a creation '
          'affordance floating over it is noise (and #233 floated it mid-screen)',
    );
  });

  testWidgets('the FAB slides out while the list scrolls down and comes back '
      'when the scroll stops (#234)', (tester) async {
    final fake = FakeBackend([
      for (var i = 0; i < 30; i++) row('T$i', 'Task $i', position: '$i'),
    ]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);
    expect(fab, findsOneWidget);

    // Scroll DOWN (content moves up) without letting go: the FAB retreats.
    // Two moves, not one: the first is eaten by the drag slop, and the
    // recognizer only forwards the pending delta once a SECOND event arrives.
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      fab,
      findsNothing,
      reason: 'while the user scrolls down the FAB stops sitting on rows',
    );

    // Reverse the drag: it returns without waiting for the gesture to end.
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fab, findsOneWidget, reason: 'scrolling up restores the FAB');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(fab, findsOneWidget, reason: 'at rest the FAB is always there');
  });

  testWidgets('the last row keeps its date button out from under the FAB at '
      'rest (#234)', (tester) async {
    final fake = FakeBackend([
      for (var i = 0; i < 30; i++) row('T$i', 'Task $i', position: '$i'),
    ]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    // Ride the list to its very end, then let it settle so the FAB is back.
    await tester.fling(find.text('Task 0'), const Offset(0, -2000), 3000);
    await tester.pumpAndSettle();
    await tester.fling(
      find.byType(Scrollable).last,
      const Offset(0, -2000),
      3000,
    );
    await tester.pumpAndSettle();
    expect(fab, findsOneWidget);

    // The bottom-most row's own quick-date button is still the topmost thing at
    // its own centre (the per-row "⋮" that used to stand here is gone, #245 —
    // the date segment is now the last row's trailing affordance).
    final dueButton = find.byKey(const Key('row-due-segment')).last;
    expect(
      tester.getRect(dueButton).overlaps(tester.getRect(fab)),
      isFalse,
      reason:
          'the list is padded by the FAB clearance, so the last row never '
          'hides under it',
    );
    await tester.tap(dueButton);
    await tester.pumpAndSettle();
    expect(find.byKey(quickDateKey('tomorrow')), findsOneWidget);
  });

  testWidgets('a row quick-date sheet covers the FAB — it can never swallow a '
      'tap meant for an action (#234)', (tester) async {
    final fake = FakeBackend([
      for (var i = 0; i < 12; i++) row('T$i', 'Task $i', position: '$i'),
    ]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    await tester.tap(find.byKey(const Key('row-due-segment')).first);
    await tester.pumpAndSettle();

    // The sheet is a modal on the ROOT navigator — the one the composer uses —
    // so it is ABOVE the shell's FAB rather than under it: the FAB is no longer
    // reachable at its own centre, where the sheet's last option is drawn.
    expect(
      fab.hitTestable(),
      findsNothing,
      reason:
          'a tap on the option under the FAB must reach the option — a sheet '
          'pushed on the shell navigator renders beneath the FAB',
    );
    expect(find.byKey(quickDateKey('clear')).hitTestable(), findsOneWidget);
  });

  testWidgets('rapid consecutive adds: the sheet stays open and an empty '
      'submit creates nothing (#234)', (tester) async {
    // Unique ids: two adds in a row must not collide in the list's key space.
    var minted = 0;
    final fake = FakeBackend([], newId: () => 'new-${minted++}');
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    await tester.tap(fab);
    await tester.pumpAndSettle();

    final field = find.widgetWithText(TextField, 'Add a task');
    await tester.enterText(field, 'First');
    await tester.tap(submit);
    await tester.pump();
    await tester.enterText(field, 'Second');
    await tester.tap(submit);
    await tester.pump();
    // Non-happy path: the field is empty again — submitting it must add nothing.
    await tester.tap(submit);
    await tester.pump();

    expect(fake.tasks.map((t) => t.task.title), ['First', 'Second']);
    expect(
      submit.hitTestable(),
      findsOneWidget,
      reason: 'the composer stays open and reachable for the next add',
    );
    expect(fab, findsNothing);
  });
}
