// TouchInteractions suite (MIGRATION-PLAN §5 T8.2). The phone-native chrome
// gestures:
//   • the FAB focuses the always-visible quick-add input (never a silent
//     empty-task create — #166);
//   • a pull-down from the top of the list runs the refresh action and shows
//     the spinner while it is in flight;
//   • a pull begun after scrolling DOWN does not refresh (it just scrolls);
//   • the soft keyboard (IME) resizes the compact body so content is not hidden
//     behind it.
//
// Everything runs over the in-memory [FakeCommands] and static provider streams
// (no database), and the refresh action is a captured completer, so the
// assertions are about what the user sees: focus, the spinner, the resized body.

import 'dart:async';

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

  // Pump the REAL compact chrome (ListDetailScaffold with a live TaskListView)
  // over [fake], at phone width. [onRefresh] overrides the pull-to-refresh
  // action; [viewInsetsBottom] simulates the soft keyboard.
  Future<void> pumpChrome(
    WidgetTester tester, {
    required FakeCommands fake,
    required List<StoredTaskList> lists,
    Future<void> Function()? onRefresh,
    double viewInsetsBottom = 0,
    Map<String, String> sortPerView = const {},
  }) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(Prefs(sortPerView: sortPerView)),
          commandsProvider.overrideWithValue(fake),
          allTasksProvider.overrideWith((ref) => fake.tasksStream),
          listsProvider.overrideWith((ref) => Stream.value(lists)),
          if (onRefresh != null)
            refreshActionProvider.overrideWithValue(onRefresh),
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
                list: composedList(viewId: 'all', onOpenTask: _noop),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('touch mounts NO inline quick-add bar — the FAB is the one '
      'creation affordance (#216)', (tester) async {
    final fake = FakeCommands([row('T1', 'Buy milk')]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    expect(
      find.text('Add a task'),
      findsNothing,
      reason: 'the bar would duplicate the FAB and cost a row of screen',
    );
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('the FAB opens the bottom-sheet composer, focused and ready '
      '(no empty-task create) (#216)', (tester) async {
    final fake = FakeCommands([row('T1', 'Buy milk')]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // The composer is up, and its input took focus with no extra tap.
    final field = find.widgetWithText(TextField, 'Add a task');
    expect(field, findsOneWidget);
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(editable).focusNode.hasFocus,
      isTrue,
      reason: 'the sheet raises the keyboard immediately',
    );
    // Opening must NOT create a task — the fake still holds exactly the seed.
    expect(fake.tasks.length, 1);
  });

  testWidgets('submitting in the composer creates the task, clears the field, '
      'and keeps the sheet open for rapid entry (#216)', (tester) async {
    final fake = FakeCommands([row('T1', 'Buy milk')]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Add a task'),
      'buy oats',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(fake.tasks.where((t) => t.task.title == 'buy oats'), isNotEmpty);
    final sheetField = find.widgetWithText(TextField, 'Add a task');
    expect(
      sheetField,
      findsOneWidget,
      reason: 'the sheet stays open for the next task',
    );
    expect(
      tester.widget<TextField>(sheetField).controller?.text,
      isEmpty,
      reason: 'the field cleared for rapid consecutive adds',
    );
  });

  testWidgets('dismissing the composer keeps an unsubmitted draft (#216)', (
    tester,
  ) async {
    final fake = FakeCommands([row('T1', 'Buy milk')]);
    addTearDown(fake.dispose);
    await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Add a task'),
      'half a thought',
    );
    // Tap the scrim above the sheet to dismiss without submitting.
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(find.text('Add a task'), findsNothing, reason: 'sheet closed');
    expect(fake.tasks.length, 1, reason: 'nothing was created');

    // Reopening shows the draft again — dismissal is not data loss.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('half a thought'), findsOneWidget);
  });

  // #233 — the composer must never leave the soft keyboard behind. A focused,
  // detached field on a route that is on its way out is the suspected mechanism
  // for the stranded bottom view inset (half the screen reserved for a keyboard
  // that is gone), so every dismissal path is pinned: the keyboard goes down
  // with the sheet, and it does not come back up on its own afterwards.
  for (final dismissal
      in <({String name, Future<void> Function(WidgetTester) go})>[
        (
          name: 'a scrim tap',
          go: (tester) => tester.tapAt(const Offset(200, 40)),
        ),
        (
          name: 'the system back button',
          go: (tester) => tester.binding.handlePopRoute(),
        ),
        (
          name: 'a swipe down',
          go: (tester) async {
            // From the sheet's drag handle, not its text field — a swipe that
            // starts on the input is a text gesture, not a dismissal.
            final sheet = tester.getRect(find.byType(BottomSheet));
            await tester.flingFrom(
              Offset(sheet.center.dx, sheet.top + 12),
              const Offset(0, 400),
              1000,
            );
          },
        ),
      ]) {
    testWidgets('${dismissal.name} takes the keyboard down with the composer, '
        'and it stays down (#233)', (tester) async {
      final fake = FakeCommands([row('T1', 'Buy milk')]);
      addTearDown(fake.dispose);
      await pumpChrome(tester, fake: fake, lists: [list('L1', 'Groceries')]);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(
        tester.testTextInput.isVisible,
        isTrue,
        reason: 'the composer raised the keyboard when it opened',
      );

      await dismissal.go(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.testTextInput.isVisible,
        isFalse,
        reason:
            'the keyboard must fall the moment the sheet is popped — an IME '
            'held open over a route that is leaving is what strands the bottom '
            'view inset and blacks out the lower half of the screen (#233)',
      );

      // ...and nothing re-raises it while the sheet finishes leaving.
      await tester.pumpAndSettle();
      expect(find.text('Add a task'), findsNothing, reason: 'sheet closed');
      expect(
        tester.testTextInput.isVisible,
        isFalse,
        reason: 'no handler may re-focus the composer on a route that popped',
      );

      // The release is a dismissal, not a permanent kill: the composer is
      // still ready to type the next time it is asked for.
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('pulling down from the top runs the refresh action + spinner', (
    tester,
  ) async {
    final fake = FakeCommands([row('T1', 'a'), row('T2', 'b'), row('T3', 'c')]);
    addTearDown(fake.dispose);
    var refreshed = false;
    final gate = Completer<void>();
    await pumpChrome(
      tester,
      fake: fake,
      lists: [list('L1', 'L')],
      // Alphabetical sort → a plain scrollable ListView (the reorderable manual
      // list still carries the same RefreshIndicator).
      sortPerView: const {'all': 'alpha'},
      onRefresh: () {
        refreshed = true;
        return gate.future;
      },
    );

    // Pull down from the top of the list.
    await tester.fling(find.text('a'), const Offset(0, 300), 1000);
    await tester.pump(); // start the drag settle
    await tester.pump(const Duration(seconds: 1)); // arm + fire onRefresh

    expect(refreshed, isTrue, reason: 'the pull ran the refresh action');
    expect(
      find.byType(RefreshProgressIndicator),
      findsOneWidget,
      reason: 'the spinner shows while the refresh is in flight',
    );

    // Completing the action retires the spinner.
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('a pull begun after scrolling down does NOT refresh', (
    tester,
  ) async {
    // Enough rows to scroll the viewport well past the top.
    final many = [for (var i = 0; i < 30; i++) row('T$i', 'task $i')];
    final fake = FakeCommands(many);
    addTearDown(fake.dispose);
    var refreshed = false;
    await pumpChrome(
      tester,
      fake: fake,
      lists: [list('L1', 'L')],
      sortPerView: const {'all': 'alpha'},
      onRefresh: () async => refreshed = true,
    );

    // Scroll down, then pull down without returning to the top.
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(refreshed, isFalse, reason: 'a scrolled list must not refresh');
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('IME: the compact body resizes above the soft keyboard', (
    tester,
  ) async {
    // A keyed marker fills the body so we can measure where it ends.
    Future<double> bodyBottomWith(double kb) async {
      final fake = FakeCommands([row('T1', 'a')]);
      addTearDown(fake.dispose);
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(const Prefs()),
            commandsProvider.overrideWithValue(fake),
            allTasksProvider.overrideWith((ref) => fake.tasksStream),
            listsProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: phone,
                viewInsets: EdgeInsets.only(bottom: kb),
              ),
              child: ListDetailScaffold(
                sidebar: const Text('SIDEBAR'),
                destinations: destinations,
                selectedIndex: SmartView.all.index,
                onDestinationSelected: (_) {},
                title: 'All Tasks',
                onNewTask: () {},
                list: const SizedBox.expand(
                  key: Key('body-marker'),
                  child: ColoredBox(color: Color(0xFF00FF00)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getRect(find.byKey(const Key('body-marker'))).bottom;
    }

    final noKeyboard = await bodyBottomWith(0);
    final withKeyboard = await bodyBottomWith(300);

    expect(
      withKeyboard,
      lessThan(noKeyboard),
      reason: 'the body lifts above the keyboard (resizeToAvoidBottomInset)',
    );
    expect(
      noKeyboard - withKeyboard,
      greaterThan(200),
      reason: 'lifted by roughly the keyboard inset, not a token amount',
    );
  });
}

void _noop(String _) {}
