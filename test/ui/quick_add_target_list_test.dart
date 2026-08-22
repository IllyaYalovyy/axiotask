// QuickAddTargetList suite (#217) — choosing WHERE a quick-add lands.
//
// Before this, a quick-add always went to the current list (or the FIRST list
// from a smart view) and the user only learned where it went from the landing
// toast (#190). The composer now carries a compact target-list picker, and
// these tests pin the ratified semantics:
//
//   • the default target is the view's own list (concrete view) or the first
//     list (smart view) — unchanged behaviour when the user picks nothing;
//   • a pick applies to that add AND to every subsequent add;
//   • a pick is NEVER persisted (no prefs write) and resets on a view change;
//   • the landing toast names the PICKED list;
//   • a picked list that disappears falls back to the view default;
//   • on a phone the composer stays ONE line and every target stays ≥48dp.
//
// Everything runs over the in-memory [FakeBackend], so the assertions are about
// what the user sees (the picker's label, the rendered rows, the toast) and
// what the backend HOLDS (the created task's listId) — never that a callback
// fired.

import 'dart:async';
import 'dart:io';

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeBackend, list;
import 'toast_harness.dart' show wrapWithToast;

/// Fixed clock — the smart views' auto-dates and the landing rules must not
/// read the wall clock.
final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

const _pickerKey = Key('quick-add-list-picker');
const _barKey = Key('quick-add-bar');

/// The two lists every test picks between; a picker only earns its space when
/// there is a real choice.
final _twoLists = [list('L1', 'My Tasks'), list('L2', 'Work')];

void main() {
  /// Bounded pump — pumpAndSettle hangs on a focused TextField's cursor timer.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Pump the real [TaskListView] over a [FakeBackend]. [view] lets a test
  /// switch views IN PLACE (no remount) so the reset-on-view-change contract is
  /// tested on the widget itself, not on the shell's per-view key.
  Future<FakeBackend> pumpQuickAdd(
    WidgetTester tester, {
    List<StoredTask> initial = const [],
    List<StoredTaskList> lists = const [],
    Stream<List<StoredTaskList>>? listsStream,
    ValueNotifier<String>? view,
    String viewId = 'all',
    List<String> excludedLists = const [],
    List<Override> extraOverrides = const [],
    TargetPlatform platform = TargetPlatform.linux,
    Size size = const Size(1200, 900),
    double keyboardInset = 0,
    double textScale = 1.0,
    String Function()? newId,
  }) async {
    var seq = 0;
    final fake = FakeBackend(initial, newId: newId ?? (() => 'gen-${seq++}'));
    addTearDown(fake.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    if (keyboardInset > 0) {
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
    }
    addTearDown(tester.view.reset);
    final viewIds = view ?? ValueNotifier(viewId);
    addTearDown(viewIds.dispose);

    await withClock(_clock, () async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(
              Prefs(excludedLists: excludedLists),
            ),
            commandsProvider.overrideWithValue(fake),
            allTasksProvider.overrideWith((ref) => fake.tasksStream),
            listsProvider.overrideWith(
              (ref) => listsStream ?? Stream.value(lists),
            ),
            ...extraOverrides,
          ],
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: wrapWithToast(context, child),
            ),
            home: Scaffold(
              body: ValueListenableBuilder<String>(
                valueListenable: viewIds,
                builder: (context, id, _) => TaskListView(
                  viewId: id,
                  selectedTaskId: null,
                  onOpenTask: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
    });
    return fake;
  }

  /// Open the composer's target-list menu (bounded pumps — a focused field's
  /// cursor timer never idles).
  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.byKey(_pickerKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Choose the list with [listId] from the open menu.
  Future<void> chooseList(WidgetTester tester, String listId) async {
    await tester.tap(find.byKey(Key('quick-add-list-$listId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Type [title] into the composer and submit it.
  Future<void> add(WidgetTester tester, String title) async {
    await withClock(_clock, () async {
      await tester.enterText(find.byType(TextField), title);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
    });
  }

  /// The list the fake actually stored [title] in.
  String landedIn(FakeBackend fake, String title) =>
      fake.tasks.firstWhere((t) => t.task.title == title).listId;

  /// The label the picker button currently shows.
  Finder pickerLabel(String text) =>
      find.descendant(of: find.byKey(_pickerKey), matching: find.text(text));

  testWidgets('the picker defaults to the CURRENT list in a concrete-list '
      'view', (tester) async {
    // The failure this prevents: a picker that ignores the view would retarget
    // an add away from the list the user is looking at.
    final fake = await pumpQuickAdd(tester, lists: _twoLists, viewId: 'L2');

    expect(pickerLabel('Work'), findsOneWidget);
    await add(tester, 'buy milk');
    expect(landedIn(fake, 'buy milk'), 'L2');
  });

  testWidgets('the picker defaults to the FIRST list in a smart view', (
    tester,
  ) async {
    // A smart view imposes no list, so the first one wins — the behaviour that
    // existed before the picker must survive it.
    final fake = await pumpQuickAdd(tester, lists: _twoLists, viewId: 'focus');

    expect(pickerLabel('My Tasks'), findsOneWidget);
    await add(tester, 'buy milk');
    expect(landedIn(fake, 'buy milk'), 'L1');
  });

  testWidgets('picking another list creates the task there, and the pick '
      'survives consecutive adds', (tester) async {
    // The core contract: the pick is not a one-shot. Two adds after ONE pick
    // both land in the picked list (ratified: it does not reset per task).
    final fake = await pumpQuickAdd(tester, lists: _twoLists, viewId: 'all');

    await openPicker(tester);
    await chooseList(tester, 'L2');
    expect(pickerLabel('Work'), findsOneWidget);
    // Aiming is a detour, not a destination — the caret comes straight back to
    // the draft so the next keystroke types the title.
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    await add(tester, 'buy milk');
    await add(tester, 'buy oats');

    expect(landedIn(fake, 'buy milk'), 'L2');
    expect(landedIn(fake, 'buy oats'), 'L2');
    expect(
      pickerLabel('Work'),
      findsOneWidget,
      reason: 'the picker still names the chosen list after two adds',
    );
  });

  testWidgets('switching views resets the pick to the new view\'s default', (
    tester,
  ) async {
    // Ratified: the pick belongs to the view, not the session. Switching to a
    // concrete list must aim the composer back at THAT list.
    final viewIds = ValueNotifier('all');
    final fake = await pumpQuickAdd(tester, lists: _twoLists, view: viewIds);

    await openPicker(tester);
    await chooseList(tester, 'L2');
    expect(pickerLabel('Work'), findsOneWidget);

    viewIds.value = 'L1';
    await settle(tester);

    expect(pickerLabel('My Tasks'), findsOneWidget);
    await add(tester, 'buy milk');
    expect(landedIn(fake, 'buy milk'), 'L1');
  });

  testWidgets('the pick is NEVER persisted — no prefs write', (tester) async {
    // Ratified: this is a transient aim, not a saved default. A prefs write
    // would resurrect the pick in the next session (and across views).
    final tmp = Directory.systemTemp.createTempSync('axiotask_pickprefs');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final file = File('${tmp.path}/prefs.json');
    final store = PrefsStore(file);

    final fake = await pumpQuickAdd(
      tester,
      lists: _twoLists,
      viewId: 'all',
      extraOverrides: [prefsStoreProvider.overrideWithValue(store)],
    );

    await openPicker(tester);
    await chooseList(tester, 'L2');
    await add(tester, 'buy milk');

    expect(landedIn(fake, 'buy milk'), 'L2', reason: 'the pick took effect');
    expect(
      file.existsSync(),
      isFalse,
      reason: 'picking a target list must not touch prefs',
    );
  });

  testWidgets('the landing toast (#190) names the PICKED list', (tester) async {
    // Adding from Focus into a list excluded from the smart views renders
    // nowhere in Focus — the toast is the only feedback, and it must name where
    // the task actually went, not the view default.
    await pumpQuickAdd(
      tester,
      lists: _twoLists,
      viewId: 'focus',
      excludedLists: ['L2'],
    );

    await openPicker(tester);
    await chooseList(tester, 'L2');
    await add(tester, 'buy milk');

    expect(find.widgetWithText(TaskRow, 'buy milk'), findsNothing);
    expect(find.text('Added "buy milk" to Work'), findsOneWidget);
  });

  testWidgets('a picked list that disappears falls back to the view default', (
    tester,
  ) async {
    // Non-happy path: a sync (or another device) deletes the picked list while
    // the composer still aims at it. The add must land in the view's default
    // list, never in a dead id the backend would reject.
    final lists = StreamController<List<StoredTaskList>>.broadcast();
    addTearDown(lists.close);
    final fake = await pumpQuickAdd(
      tester,
      viewId: 'all',
      listsStream: lists.stream,
    );
    lists.add(_twoLists);
    await settle(tester);

    await openPicker(tester);
    await chooseList(tester, 'L2');
    expect(pickerLabel('Work'), findsOneWidget);

    lists.add([list('L1', 'My Tasks')]);
    await settle(tester);

    await add(tester, 'buy milk');
    expect(landedIn(fake, 'buy milk'), 'L1');
  });

  testWidgets('a single list offers no picker — there is nothing to choose', (
    tester,
  ) async {
    await pumpQuickAdd(tester, lists: [list('L1', 'My Tasks')], viewId: 'all');
    expect(find.byKey(_pickerKey), findsNothing);
  });

  group('phone composer geometry', () {
    const phone = Size(400, 800);

    /// Open the FAB's bottom-sheet composer (#216) — the touch creation
    /// surface, which mounts the same bar as the desktop.
    Future<void> openComposer(WidgetTester tester) async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TaskListView)),
        listen: false,
      );
      container.read(newTaskRequestProvider.notifier).bump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    /// Measure the composer once for [lists]: the bar's height and the input's
    /// width. The tree is torn down afterwards so the next configuration does
    /// not measure two live composers (the first sheet's route would survive a
    /// re-pump).
    Future<({double barHeight, double editableWidth, Size? picker})> measure(
      WidgetTester tester,
      List<StoredTaskList> lists,
    ) async {
      await pumpQuickAdd(
        tester,
        lists: lists,
        platform: TargetPlatform.android,
        size: phone,
      );
      await openComposer(tester);
      final picker = find.byKey(_pickerKey);
      final measured = (
        barHeight: tester.getSize(find.byKey(_barKey)).height,
        // The room actually left for typing — the field's own box includes the
        // decorative prefix the picker replaces, so it would flatter the result.
        editableWidth: tester.getSize(find.byType(EditableText)).width,
        picker: picker.evaluate().isEmpty ? null : tester.getSize(picker),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      return measured;
    }

    testWidgets('the picker keeps the composer to ONE line, with a real input '
        'and a finger-sized target', (tester) async {
      // The hard constraint: ONE line on mobile. A picker that wrapped or
      // stacked shows up here as a taller bar; one that crowded the row out of
      // usefulness shows up as a stunted input.
      final without = await measure(tester, [list('L1', 'My Tasks')]);
      final with_ = await measure(tester, _twoLists);

      expect(without.picker, isNull, reason: 'one list, nothing to pick');
      expect(with_.picker, isNotNull);
      expect(
        with_.barHeight,
        without.barHeight,
        reason: 'the picker must live on the composer\'s single line',
      );
      expect(
        with_.editableWidth,
        greaterThanOrEqualTo(150),
        reason:
            'on a 400dp phone the input must still hold ~20 characters while '
            'the destination is on screen',
      );
      expect(with_.picker!.height, greaterThanOrEqualTo(48));
      expect(with_.picker!.width, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });

    testWidgets('with the soft keyboard up the whole menu stays above it, '
        'however many lists there are', (tester) async {
      // The composer is always typed into, so the menu opens with the IME up.
      // Uncapped, ten lists put the last entries behind the keyboard where no
      // finger can reach them; capped, the menu scrolls above it instead.
      const keyboard = 350.0;
      await pumpQuickAdd(
        tester,
        lists: [for (var i = 1; i <= 10; i++) list('L$i', 'List $i')],
        platform: TargetPlatform.android,
        size: phone,
        keyboardInset: keyboard,
      );
      await openComposer(tester);
      await openPicker(tester);

      // The menu's visible box — what the user can actually see and scroll.
      final panel = tester.getRect(
        find.ancestor(
          of: find.byKey(const Key('quick-add-list-L1')),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(
        panel.bottom,
        lessThanOrEqualTo(phone.height - keyboard),
        reason: 'no menu entry may sit behind the soft keyboard',
      );
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('a long date chip and the picker share the row at text '
          'scale $scale — no overflow, a usable input', (tester) async {
        // The failure this prevents: the destination picker plus an uncapped
        // date chip ("Aug 15, 2027") overran the 400dp row — a black-and-yellow
        // overflow stripe at the enlarged font, and a zero-width input even at
        // the normal one.
        await pumpQuickAdd(
          tester,
          lists: _twoLists,
          platform: TargetPlatform.android,
          size: phone,
          textScale: scale,
        );
        await openComposer(tester);
        await withClock(_clock, () async {
          await tester.enterText(find.byType(TextField), 'pay rent 2027-08-15');
          await tester.pump();
        });

        expect(find.byKey(_pickerKey), findsOneWidget);
        expect(
          tester.getSize(find.byType(EditableText)).width,
          greaterThan(24),
          reason: 'the draft must still be visible while the chip is up',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'no RenderFlex overflow',
        );
      });
    }

    testWidgets('with the date chip up the composer sheds the picker LABEL, '
        'never the control', (tester) async {
      // Coarse pointer + a parsed date puts a 147dp chip, a 48dp × and the send
      // button on one 400dp line, leaving ~125dp of input — a labelled picker
      // does not fit inside it. The label goes; the control (and its menu)
      // stays reachable and still retargets the add.
      final fake = await pumpQuickAdd(
        tester,
        lists: _twoLists,
        platform: TargetPlatform.android,
        size: phone,
      );
      await openComposer(tester);
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'buy milk tomorrow');
        await tester.pump();
      });

      expect(pickerLabel('My Tasks'), findsNothing);
      final picker = tester.getSize(find.byKey(_pickerKey));
      expect(picker.height, greaterThanOrEqualTo(48));
      expect(picker.width, greaterThanOrEqualTo(48));

      await openPicker(tester);
      await chooseList(tester, 'L2');
      // Submit with the send button — the menu took focus off the input, which
      // is exactly how a finger reaches this state.
      await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_upward));
      await settle(tester);
      // The title keeps the typed phrase verbatim; only the DUE is parsed.
      expect(landedIn(fake, 'buy milk tomorrow'), 'L2');
      expect(tester.takeException(), isNull);
    });
  });
}
