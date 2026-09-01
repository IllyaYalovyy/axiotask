// The composer's DRAFT AIM across consecutive adds (#264).
//
// The defect: the phone's bottom-sheet composer captured the parent's
// `pickedDue` ONCE, when the sheet route was built, while the pane cleared that
// same field after every create. So a user who tapped "Tomorrow", added a task,
// and typed the next one saw a chip that still said "tomorrow" — and got an
// UNDATED task. The composer said one thing and created another, which is the
// one thing a create surface may never do.
//
// The ratified rule these tests pin: the draft's AIM — an explicitly picked due
// date and the destination list — is what the NEXT add uses, and it stays put
// across submits. It goes away when the user says so (the chip's ×) or when the
// composer closes. Both composer surfaces observe ONE draft, so they cannot
// disagree about it: the always-visible desktop bar and the phone's sheet are
// asserted separately here, because the bug lived entirely in the gap between
// them.
//
// Every assertion is about what the user sees (the chip's label in the composer)
// and what the backend HOLDS (the created task's `due` / `listId`) — never that
// a callback fired. Determinism: a fixed clock ([_clock]) so "Tomorrow" is a
// known date, and static provider streams over the in-memory FakeBackend.

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeBackend, list;
import 'list_harness.dart' show pumpList, settleList;

/// Fixed "now" — 2026-06-15, so "Tomorrow" is 2026-06-16 and nothing reads the
/// wall clock.
final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

/// What the backend stores for the fixed clock's "Tomorrow".
const _tomorrow = '2026-06-16T00:00:00.000Z';

const _barKey = Key('quick-add-bar');
const _dateButton = Key('quick-add-date-button');
const _dismissChip = Key('quick-add-date-dismiss');
const _submit = Key('quick-add-submit');

/// The composer's own input — scoped to the bar, because a created row carries
/// a due label of its own and would otherwise answer a bare text finder.
final _field = find.descendant(
  of: find.byKey(_barKey),
  matching: find.byType(TextField),
);

/// The composer's date chip label, scoped the same way.
Finder _chip(String label) =>
    find.descendant(of: find.byKey(_barKey), matching: find.text(label));

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

  /// Bounded pump — never pumpAndSettle with a focused TextField (its cursor
  /// timer never idles under the fake zone).
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The REAL compact chrome (FAB + sheet composer) over [fake], at phone width,
  /// with the list inside a NESTED navigator — the shape go_router's ShellRoute
  /// gives it, and the tree the sheet's root-navigator route sits above.
  Future<void> pumpPhone(
    WidgetTester tester, {
    required FakeBackend fake,
    required List<StoredTaskList> lists,
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
            data: const MediaQueryData(size: phone),
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
    await settle(tester);
  }

  /// Open the touch composer by tapping the FAB it morphs out of.
  Future<void> openComposer(WidgetTester tester) async {
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
  }

  /// Set the draft's date to "Tomorrow" through the composer's date button —
  /// the anchored menu on a fine pointer, the root-navigator sheet on a coarse
  /// one. Both land in the same frozen option set (#243).
  Future<void> pickTomorrow(WidgetTester tester) async {
    await withClock(_clock, () async {
      await tester.tap(find.byKey(_dateButton));
      await settle(tester);
      await tester.tap(find.byKey(quickDateKey('tomorrow')));
      await settle(tester);
    });
  }

  Future<void> add(WidgetTester tester, String title) async {
    await tester.enterText(_field, title);
    await settle(tester);
    await withClock(_clock, () async {
      await tester.tap(find.byKey(_submit));
      await settle(tester);
    });
  }

  StoredTask taskNamed(FakeBackend fake, String title) =>
      fake.tasks.firstWhere((t) => t.task.title == title);

  group('phone — the sheet composer', () {
    testWidgets('a date picked in the composer is the date the SECOND add gets '
        'too, and the chip keeps saying so (#264)', (tester) async {
      var minted = 0;
      final fake = FakeBackend([], newId: () => 'new-${minted++}');
      addTearDown(fake.dispose);
      await pumpPhone(tester, fake: fake, lists: [list('L1', 'My Tasks')]);
      await openComposer(tester);

      await pickTomorrow(tester);
      expect(
        _chip('tomorrow'),
        findsOneWidget,
        reason: 'the pick is visible on the composer before the first add',
      );

      await add(tester, 'First');
      expect(taskNamed(fake, 'First').task.due, _tomorrow);

      // THE DEFECT: the chip still says "tomorrow" here because the sheet
      // captured the value once — but the pane had already dropped it, so the
      // next add lands undated. The composer must not promise what it will not
      // deliver: the aim it still SHOWS is the aim it must still USE.
      expect(
        _chip('tomorrow'),
        findsOneWidget,
        reason: 'the aim the composer shows survives the add it was used for',
      );

      await add(tester, 'Second');
      expect(
        taskNamed(fake, 'Second').task.due,
        _tomorrow,
        reason: 'the second add gets the date the chip is still advertising',
      );
    });

    testWidgets(
      'the chip\'s × drops the aim — the next add is undated (#264)',
      (tester) async {
        var minted = 0;
        final fake = FakeBackend([], newId: () => 'new-${minted++}');
        addTearDown(fake.dispose);
        await pumpPhone(tester, fake: fake, lists: [list('L1', 'My Tasks')]);
        await openComposer(tester);

        await pickTomorrow(tester);
        await add(tester, 'First');

        expect(
          _chip('tomorrow'),
          findsOneWidget,
          reason: 'the aim is still standing — there is something to take back',
        );

        // Non-happy path: the user takes the date back off the composer. A
        // sticky aim that no gesture can clear would be worse than the bug.
        await tester.tap(find.byKey(_dismissChip));
        await settle(tester);
        expect(_chip('tomorrow'), findsNothing);

        await add(tester, 'Second');
        expect(taskNamed(fake, 'First').task.due, _tomorrow);
        expect(
          taskNamed(fake, 'Second').task.due,
          isNull,
          reason: 'the × means the composer is aimed at no date at all',
        );
      },
    );

    testWidgets('closing the composer releases the aim — a reopened composer '
        'shows no date and adds undated (#264)', (tester) async {
      var minted = 0;
      final fake = FakeBackend([], newId: () => 'new-${minted++}');
      addTearDown(fake.dispose);
      await pumpPhone(tester, fake: fake, lists: [list('L1', 'My Tasks')]);
      await openComposer(tester);

      await pickTomorrow(tester);
      await add(tester, 'First');

      expect(
        _chip('tomorrow'),
        findsOneWidget,
        reason: 'the aim is still standing — there is something to release',
      );

      // Non-happy path: dismiss the sheet through the scrim, then come back.
      await tester.tapAt(const Offset(200, 60));
      await tester.pumpAndSettle();
      await openComposer(tester);

      expect(
        _chip('tomorrow'),
        findsNothing,
        reason: 'a composer opened afresh carries no date from a past session',
      );
      await add(tester, 'Second');
      expect(taskNamed(fake, 'First').task.due, _tomorrow);
      expect(taskNamed(fake, 'Second').task.due, isNull);
    });

    testWidgets('the destination stays aimed across submits and is released by '
        'a close (#264)', (tester) async {
      var minted = 0;
      final fake = FakeBackend([], newId: () => 'new-${minted++}');
      addTearDown(fake.dispose);
      await pumpPhone(
        tester,
        fake: fake,
        lists: [list('L1', 'My Tasks'), list('L2', 'Work')],
      );
      await openComposer(tester);

      await tester.tap(find.byKey(const Key('quick-add-list-picker')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('quick-add-list-L2')));
      await settle(tester);

      await add(tester, 'First');
      await add(tester, 'Second');
      expect(taskNamed(fake, 'First').listId, 'L2');
      expect(
        taskNamed(fake, 'Second').listId,
        'L2',
        reason: 'the aim applies to this add AND every one after it (#217)',
      );

      await tester.tapAt(const Offset(200, 60));
      await tester.pumpAndSettle();
      await openComposer(tester);
      await add(tester, 'Third');
      expect(
        taskNamed(fake, 'Third').listId,
        'L1',
        reason: 'a closed composer gives its aim back to the view default',
      );
    });
  });

  group('desktop — the always-visible bar', () {
    testWidgets('a date picked in the bar survives the submit that used it '
        '(#264)', (tester) async {
      final fake = await pumpList(
        tester,
        initial: const [],
        lists: [list('L1', 'My Tasks')],
        platform: TargetPlatform.linux,
      );

      await pickTomorrow(tester);
      expect(_chip('tomorrow'), findsOneWidget);

      await add(tester, 'First');
      expect(taskNamed(fake, 'First').task.due, _tomorrow);
      expect(
        _chip('tomorrow'),
        findsOneWidget,
        reason: 'the bar keeps the aim the user set, add after add',
      );

      await add(tester, 'Second');
      expect(taskNamed(fake, 'Second').task.due, _tomorrow);
    });

    testWidgets('the bar\'s × drops the aim — the next add is undated (#264)', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: const [],
        lists: [list('L1', 'My Tasks')],
        platform: TargetPlatform.linux,
      );

      await pickTomorrow(tester);
      await add(tester, 'First');

      expect(
        _chip('tomorrow'),
        findsOneWidget,
        reason: 'the aim is still standing — there is something to take back',
      );

      // Non-happy path: the fine-pointer chip's own delete button.
      await tester.tap(find.byIcon(Icons.close).first);
      await settleList(tester);
      expect(_chip('tomorrow'), findsNothing);

      await add(tester, 'Second');
      expect(taskNamed(fake, 'First').task.due, _tomorrow);
      expect(taskNamed(fake, 'Second').task.due, isNull);
    });
  });
}

void _noop(String _) {}
