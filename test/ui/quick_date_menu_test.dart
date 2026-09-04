// ONE QuickDateMenu (#243) — the unification suite.
//
// The defect this suite pins down: the app had FOUR quick-date surfaces with
// THREE vocabularies ("1 wk" on the row strip, "Next week" in the action menu,
// "+1 week" in the detail panel), the bulk bar offered a fourth subset, and a
// tap on a row's date skipped the quick options entirely and went straight to
// the calendar. The user ruled (2026-08-30) that the option set is FROZEN —
// Today · Tomorrow · Next week · Next month · Pick a date… · Clear — and that
// ONE component speaks it everywhere: the row's date / "no date" segment, a
// swipe-left on a row, the detail Due field, each subtask's due button, the
// bulk bar's "Due ▾", the row action menu's submenu, and the composer.
//
// D-1 (ratified): the hover/swipe quick-date STRIP is retired outright — the
// row's date tap replaces it on the desktop and the swipe opens the same sheet
// on touch. The strip's keys must be gone from every row.
//
// Every assertion is on what a user sees (the labels the surface renders, the
// row's re-rendered date badge) or what the fake backend HOLDS afterwards —
// never that a callback fired. Time is a fixed clock, so "tomorrow" is a date,
// not a guess.

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/dates.dart' show DateMove;
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
import 'package:axiotask/src/ui/task_actions.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeCommands, list, pumpDetail, row;
import 'list_harness.dart';

/// The exact wording, in the exact order, the FROZEN option set must show
/// wherever it renders. Spelled out as literals — reading them off
/// [kQuickDateItems] would let a silent edit to the frozen set pass.
const _frozenLabels = <String>[
  'Today',
  'Tomorrow',
  'Next week',
  'Next month',
  'Pick a date…',
  'Clear',
];

/// Fixed clock: today = 2026-06-15, tomorrow = 06-16, next week = 06-22,
/// next month = 07-15. Same instant [testClock] (list_harness) uses.
final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

/// The labels the open menu/sheet currently renders, in tree order.
List<String> renderedMenuLabels(WidgetTester tester) => [
  for (final item in kQuickDateItems)
    if (tester.any(find.byKey(quickDateKey(item.id))))
      tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(quickDateKey(item.id)),
              matching: find.byType(Text),
            ),
          )
          .first
          .data!,
];

void main() {
  final oneList = [list('L1', 'My Tasks')];

  /// Bounded pump — never pumpAndSettle around a focused field.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Ctrl-click the row titled [title] (the desktop selection gesture).
  Future<void> ctrlClick(WidgetTester tester, String title) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  String? dueOf(FakeCommands fake, String id) =>
      fake.tasks.firstWhere((t) => t.task.id == id).task.due;

  group('the frozen option set', () {
    test('is exactly the six ratified options, in order', () {
      expect([for (final i in kQuickDateItems) i.label], _frozenLabels);
    });

    test('every move is relative to TODAY, and only "Pick a date…" opens the '
        'calendar', () {
      // The failure this prevents: re-reading "Next week" as next Monday, or
      // as "the current due + 7 days" (both explicitly rejected).
      expect(
        [for (final i in kQuickDateItems) i.move],
        [
          DateMove.today,
          DateMove.tomorrow,
          DateMove.nextWeek,
          DateMove.nextMonth,
          null,
          DateMove.clear,
        ],
      );
    });
  });

  group('the row date / "no date" segment (D-1: it replaces the strip)', () {
    testWidgets('tapping "no date" opens the frozen option set', (
      tester,
    ) async {
      await pumpList(tester, initial: [row('T', 'plan trip')], lists: oneList);
      expect(find.text('no date'), findsOneWidget);

      await tester.tap(find.text('no date'));
      await settle(tester);

      expect(renderedMenuLabels(tester), _frozenLabels);
    });

    testWidgets('choosing Tomorrow dates the task and the row says so', (
      tester,
    ) async {
      final fake = await withClock(_clock, () async {
        final f = await pumpList(
          tester,
          initial: [row('T', 'plan trip')],
          lists: oneList,
        );
        await tester.tap(find.text('no date'));
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('tomorrow')));
        await settle(tester);
        return f;
      });

      expect(dueOf(fake, 'T'), '2026-06-16T00:00:00.000Z');
      expect(find.text('tomorrow'), findsOneWidget);
      expect(find.text('no date'), findsNothing);
    });

    testWidgets('"Pick a date…" opens the calendar, and the pick lands', (
      tester,
    ) async {
      final fake = await withClock(_clock, () async {
        final f = await pumpList(
          tester,
          initial: [row('T', 'plan trip')],
          lists: oneList,
        );
        await tester.tap(find.text('no date'));
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('pick')));
        await settle(tester);
        expect(find.byType(CalendarDatePicker), findsOneWidget);
        await tester.tap(find.text('20'));
        await settle(tester);
        return f;
      });

      expect(dueOf(fake, 'T'), '2026-06-20T00:00:00.000Z');
    });

    testWidgets('Clear removes a date the task already has (non-happy path: '
        'the option is offered on an undated task too)', (tester) async {
      final fake = await withClock(_clock, () async {
        final f = await pumpList(
          tester,
          initial: [row('T', 'plan trip', due: '2026-06-20')],
          lists: oneList,
        );
        await tester.tap(find.text('in 5d'));
        await settle(tester);
        // The set is frozen: Clear is always offered, on a dated task and an
        // undated one alike — one menu, never a per-surface subset.
        expect(renderedMenuLabels(tester), _frozenLabels);
        await tester.tap(find.byKey(quickDateKey('clear')));
        await settle(tester);
        return f;
      });

      expect(dueOf(fake, 'T'), isNull);
      expect(find.text('no date'), findsOneWidget);
    });
  });

  group('D-1: the strip is gone, without a trace', () {
    testWidgets('a desktop hover reveals no in-row strip', (tester) async {
      await pumpList(
        tester,
        initial: [row('T', 'plan trip', due: '2026-06-20')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      await g.moveTo(tester.getCenter(find.byType(TaskRow)));
      await settle(tester);

      for (final key in ['today', 'tomorrow', 'week', 'month', 'clear']) {
        expect(
          find.byKey(Key('quick-date-$key')),
          findsNothing,
          reason: 'the retired strip must leave no key behind',
        );
      }
      expect(find.text('1 wk'), findsNothing);
      expect(find.text('1 mo'), findsNothing);
    });

    testWidgets('a hover still does not reflow the row (#168 survives D-1)', (
      tester,
    ) async {
      // Inherited from the retired strip's suite: the reveal that used to grow
      // the row on hover is gone, and nothing may take its place. A row must
      // measure identically with and without a pointer over it.
      await pumpList(
        tester,
        initial: [row('T', 'plan trip', due: '2026-06-20')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      final before = tester.getSize(find.byType(TaskRow));
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      await g.moveTo(tester.getCenter(find.byType(TaskRow)));
      await settle(tester);
      expect(tester.getSize(find.byType(TaskRow)), before);
    });

    testWidgets('a touch swipe-left opens the SAME option set for that row', (
      tester,
    ) async {
      final fake = await withClock(_clock, () async {
        final f = await pumpList(
          tester,
          initial: [row('T', 'plan trip')],
          lists: oneList,
          platform: TargetPlatform.android,
        );
        await tester.drag(find.byType(TaskRow), const Offset(-180, 0));
        await settle(tester);
        expect(renderedMenuLabels(tester), _frozenLabels);
        await tester.tap(find.byKey(quickDateKey('today')));
        await settle(tester);
        return f;
      });

      expect(dueOf(fake, 'T'), '2026-06-15T00:00:00.000Z');
    });
  });

  group('touch presentation is a ROOT-navigator sheet (#234)', () {
    testWidgets('the sheet covers the FAB, so no option is swallowed by it', (
      tester,
    ) async {
      // The failure this prevents: a sheet pushed on the shell's NESTED
      // navigator renders inside the compact Scaffold's body — under the FAB
      // and the navigation bar — so the finger aiming at "Clear" hits the FAB.
      const phone = Size(400, 800);
      final fake = FakeCommands([row('T', 'plan trip')]);
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
            listsProvider.overrideWith((ref) => Stream.value(oneList)),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: Consumer(
              builder: (context, ref, _) => ListDetailScaffold(
                sidebar: const Text('SIDEBAR'),
                destinations: [
                  for (final v in SmartView.values)
                    ShellDestination(
                      icon: v.icon,
                      selectedIcon: v.selectedIcon,
                      label: v.label,
                    ),
                ],
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
      );
      await settle(tester);

      await tester.tap(find.text('no date'));
      await settle(tester);

      expect(renderedMenuLabels(tester), _frozenLabels);
      expect(
        find.byType(FloatingActionButton).hitTestable(),
        findsNothing,
        reason: 'the sheet layers ABOVE the shell chrome (root navigator)',
      );
      expect(find.text('Clear').hitTestable(), findsOneWidget);
    });
  });

  group('desktop dismissal', () {
    testWidgets('Escape closes the menu and focus returns to the row control', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('T', 'plan trip')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      await tester.tap(find.text('no date'));
      await settle(tester);
      expect(find.byKey(quickDateKey('today')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      expect(find.byKey(quickDateKey('today')), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<QuickDateAnchor>(),
        isNotNull,
        reason: 'the caret returns to the control that opened the menu',
      );
    });

    testWidgets('a click outside dismisses without changing the date', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('T', 'plan trip')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      await tester.tap(find.text('no date'));
      await settle(tester);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);

      expect(find.byKey(quickDateKey('today')), findsNothing);
      expect(dueOf(fake, 'T'), isNull);
      expect(find.text('no date'), findsOneWidget);
    });
  });

  group('the bulk bar speaks the same set behind ONE "Due" button', () {
    testWidgets('Next week moves every selected task', (tester) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
      );
      await ctrlClick(tester, 'apples');
      await ctrlClick(tester, 'bread');

      await withClock(testClock, () async {
        await tester.tap(find.byKey(const Key('bulk-due')));
        await settle(tester);
        expect(renderedMenuLabels(tester), _frozenLabels);
        await tester.tap(find.byKey(quickDateKey('week')));
        await settle(tester);
      });

      for (final id in ['A', 'B']) {
        expect(dueOf(fake, id), '2026-06-22T00:00:00.000Z');
      }
      expect(find.text('2 tasks rescheduled'), findsOneWidget);
    });

    testWidgets('"Pick a date…" is available to bulk too, and applies the '
        'picked day to the whole selection', (tester) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
      );
      await ctrlClick(tester, 'apples');
      await ctrlClick(tester, 'bread');

      await withClock(testClock, () async {
        await tester.tap(find.byKey(const Key('bulk-due')));
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('pick')));
        await settle(tester);
        expect(find.byType(CalendarDatePicker), findsOneWidget);
        await tester.tap(find.text('24'));
        await settle(tester);
      });

      for (final id in ['A', 'B']) {
        expect(dueOf(fake, id), '2026-06-24T00:00:00.000Z');
      }
      expect(find.text('2 tasks rescheduled'), findsOneWidget);
    });

    testWidgets('cancelling the bulk calendar changes nothing and keeps the '
        'selection (non-happy path)', (tester) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples', due: '2026-06-20')],
        lists: oneList,
      );
      await ctrlClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('bulk-due')));
      await settle(tester);
      await tester.tap(find.byKey(quickDateKey('pick')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('due-picker-cancel')));
      await settle(tester);

      expect(dueOf(fake, 'A'), '2026-06-20', reason: 'untouched by a cancel');
      expect(find.text('1 selected'), findsOneWidget);
    });
  });

  group('the detail panel speaks the same set', () {
    testWidgets('the Due field opens the frozen option set', (tester) async {
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'undated')]);
      await tester.tap(find.byKey(const Key('due-field')));
      await settle(tester);
      expect(renderedMenuLabels(tester), _frozenLabels);
    });

    testWidgets('no second vocabulary is left on the panel', (tester) async {
      // The failure this prevents: the "+1 week" / "+1 month" chips surviving
      // beside the unified menu — two wordings for one move.
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'undated')]);
      expect(find.text('+1 week'), findsNothing);
      expect(find.text('+1 month'), findsNothing);
    });

    testWidgets('a subtask due button opens the same set and dates the '
        'subtask', (tester) async {
      final fake = await withClock(_clock, () async {
        final f = await pumpDetail(
          tester,
          taskId: 'P',
          initial: [
            row('P', 'parent'),
            row('S', 'kid', parent: 'P'),
          ],
        );
        await tester.tap(find.byKey(const Key('sub-due-S')));
        await settle(tester);
        expect(renderedMenuLabels(tester), _frozenLabels);
        await tester.tap(find.byKey(quickDateKey('month')));
        await settle(tester);
        return f;
      });

      expect(dueOf(fake, 'S'), '2026-07-15T00:00:00.000Z');
    });
  });

  group('the row action menu speaks the same set', () {
    testWidgets('the "Set due date" submenu is the frozen list, in order', (
      tester,
    ) async {
      final entries = buildTaskMenu(
        task: row('T', 'plan trip'),
        lists: oneList,
        demotable: false,
        selected: false,
        onToggleSelect: () {},
        onEditTitle: () {},
        onEditNotes: () {},
        onSetDue: (_) {},
        onPickDate: () {},
        onMoveToList: (_) {},
        onDetach: () {},
        onDemote: () {},
        onDuplicate: () {},
        onDetails: () {},
        onOpenGoogle: () {},
        onDelete: () {},
      );
      final due = entries.whereType<TaskMenuSubmenu>().firstWhere(
        (s) => s.id == 'due',
      );
      expect([for (final i in due.items) i.label], _frozenLabels);
    });
  });

  group('the composer creates WITH a date, in one tap', () {
    const phone = Size(400, 800);

    Future<FakeCommands> pumpComposer(
      WidgetTester tester, {
      List<StoredTask> initial = const [],
      List<StoredTaskList> lists = const [],
      Size size = phone,
      String Function()? newId,
    }) async {
      final fake = FakeCommands(initial, newId: newId ?? () => 'NEW');
      addTearDown(fake.dispose);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await withClock(_clock, () async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              prefsProvider.overrideWithValue(const Prefs()),
              commandsProvider.overrideWithValue(fake),
              allTasksProvider.overrideWith((ref) => fake.tasksStream),
              listsProvider.overrideWith((ref) => Stream.value(lists)),
            ],
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.android),
              home: const Scaffold(
                body: TaskListView(
                  viewId: 'all',
                  selectedTaskId: null,
                  onOpenTask: _noop,
                ),
              ),
            ),
          ),
        );
        await settle(tester);
        // Touch creates through the FAB's sheet composer (#216).
        ProviderScope.containerOf(
          tester.element(find.byType(TaskListView)),
          listen: false,
        ).read(newTaskRequestProvider.notifier).bump();
        await settle(tester);
      });
      return fake;
    }

    testWidgets('the date button offers the frozen set; Tomorrow previews as '
        'the same chip and submit creates the task with that date', (
      tester,
    ) async {
      final fake = await pumpComposer(tester, lists: oneList);
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'call bank');
        await tester.pump();
        await tester.tap(find.byKey(const Key('quick-add-date-button')));
        await settle(tester);
        expect(renderedMenuLabels(tester), _frozenLabels);
        await tester.tap(find.byKey(quickDateKey('tomorrow')));
        await settle(tester);
        // The SAME preview chip the natural-language parser raises.
        expect(find.widgetWithText(RawChip, 'tomorrow'), findsOneWidget);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);
      });

      final stored = fake.tasks.single.task;
      expect(stored.title, 'call bank');
      expect(stored.due, '2026-06-16T00:00:00.000Z');
    });

    testWidgets('an explicit pick BEATS a date phrase typed afterwards', (
      tester,
    ) async {
      final fake = await pumpComposer(tester, lists: oneList);
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'call bank');
        await tester.pump();
        await tester.tap(find.byKey(const Key('quick-add-date-button')));
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('tomorrow')));
        await settle(tester);
        // The user then types a date phrase into the title. The explicit pick
        // wins — the chip keeps showing it, and that is what gets created.
        await tester.enterText(find.byType(TextField), 'call bank next week');
        await tester.pump();
        expect(find.widgetWithText(RawChip, 'tomorrow'), findsOneWidget);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);
      });

      final stored = fake.tasks.single.task;
      expect(stored.title, 'call bank next week');
      expect(stored.due, '2026-06-16T00:00:00.000Z');
    });

    testWidgets('"Pick a date…" from the composer lands in the chip', (
      tester,
    ) async {
      final fake = await pumpComposer(tester, lists: oneList);
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'call bank');
        await tester.pump();
        await tester.tap(find.byKey(const Key('quick-add-date-button')));
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('pick')));
        await settle(tester);
        expect(find.byType(CalendarDatePicker), findsOneWidget);
        await tester.tap(find.text('24'));
        await settle(tester);
        expect(find.widgetWithText(RawChip, 'Jun 24'), findsOneWidget);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);
      });

      expect(fake.tasks.single.task.due, '2026-06-24T00:00:00.000Z');
    });

    testWidgets('Clear drops the picked date; the task is created undated '
        '(non-happy path)', (tester) async {
      final fake = await pumpComposer(tester, lists: oneList);
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'call bank tomorrow');
        await tester.pump();
        await tester.tap(find.byKey(const Key('quick-add-date-button')));
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('clear')));
        await settle(tester);
        expect(find.widgetWithText(RawChip, 'tomorrow'), findsNothing);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);
      });

      final stored = fake.tasks.single.task;
      expect(stored.title, 'call bank tomorrow');
      expect(stored.due, anyOf(isNull, isEmpty));
    });

    testWidgets('with a destination picker TOO the 400dp row still fits: the '
        'draft keeps its floor and the chip is what gives way', (tester) async {
      // The tightest phone layout there is — draft + date chip + date button +
      // destination picker + send on one 400dp line. #223's floor outranks the
      // chip, so the chip ellipsises rather than the title being typed.
      await pumpComposer(
        tester,
        lists: [list('L1', 'My Tasks'), list('L2', 'Work')],
      );
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'buy milk');
        await tester.pump();
        await tester.tap(find.byKey(const Key('quick-add-date-button')));
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('tomorrow')));
        await settle(tester);
      });

      expect(find.byKey(const Key('quick-add-list-picker')), findsOneWidget);
      expect(find.byKey(const Key('quick-add-date-button')), findsOneWidget);
      expect(
        tester.getSize(find.byType(EditableText)).width,
        greaterThanOrEqualTo(120),
        reason: 'the draft keeps its floor even in the tightest layout',
      );
      // The chip is what yields: the row cannot seat a full-width date chip
      // AND the readable draft, so it is capped (and ellipsises) instead.
      expect(
        tester.getSize(find.byKey(const Key('quick-add-date-dismiss'))).width,
        lessThanOrEqualTo(96),
      );
      expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
    });

    testWidgets('on a 400dp phone with the chip up the draft keeps its floor, '
        'and the date button and send are both still there (#223)', (
      tester,
    ) async {
      // The failure this prevents: the new date button squeezing the composer's
      // input below the readable floor #223 established — the row must shed
      // chip width, never the title being typed.
      await pumpComposer(tester, lists: oneList);
      final bareLine = tester.getSize(find.byKey(const Key('quick-add-bar')));
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'buy milk');
        await tester.pump();
        await tester.tap(find.byKey(const Key('quick-add-date-button')));
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('tomorrow')));
        await settle(tester);
      });

      expect(find.widgetWithText(RawChip, 'tomorrow'), findsOneWidget);
      expect(
        tester.getSize(find.byType(EditableText)).width,
        greaterThanOrEqualTo(120),
        reason: 'the draft stays readable while the date chip is up',
      );
      final button = tester.getSize(
        find.byKey(const Key('quick-add-date-button')),
      );
      expect(button.width, greaterThanOrEqualTo(48));
      expect(button.height, greaterThanOrEqualTo(48));
      expect(find.byKey(const Key('quick-add-submit')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('quick-add-bar'))).height,
        bareLine.height,
        reason: 'the composer stays ONE line',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

void _noop(String _) {}
