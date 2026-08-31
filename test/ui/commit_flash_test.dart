// #252 — the commit flash: a confirmed write washes the element it changed.
//
// The failure this suite prevents is the one the issue opens with: an edit that
// LANDS is invisible. "Tomorrow" from the quick-date menu only swaps one small
// grey label; a move to another list changes nothing the eye is drawn to; a
// bulk action rewrites N rows with no sign of which. Each test below drives a
// REAL user path through the real [TaskListView] over the mutating FakeBackend
// and reads the colour actually being painted over the element in that frame —
// the wash a user sees, not a controller, a callback or a flag.
//
// The rules under test:
//
//   what     secondaryContainer at 40%, decaying to fully transparent
//   how long Motion.emphasized (400ms), ease-out
//   where    the CHANGED element — date badge, list tag, title; the whole row
//            only for a bulk action or a sync-pulled change
//   when     at the COMMIT (the store confirming), never at the tap
//   repeat   a second commit RESTARTS the wash; two never stack
//   reduced  no flash at all — the state change is the feedback
//
// Frame discipline: [land] pumps WITHOUT advancing the clock, so a command can
// run and the task stream deliver while the test still owns every frame of the
// motion that follows. Durations are written out as literals on purpose — a
// test that reads the same constant as the code cannot catch the constant being
// wrong.

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/ui/commit_flash.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
import 'package:axiotask/src/ui/task_detail.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeBackend, list, row;
import 'list_harness.dart';
import 'toast_harness.dart' show wrapWithToast;

/// The wash's opacity at the instant a write lands.
const _peak = 0.4;

void main() {
  final oneList = [list('L1', 'My Tasks')];
  final twoLists = [list('L1', 'My Tasks'), list('L2', 'Errands')];

  /// The list slot holding task [id] (the default sort is manual, so the list
  /// is a ReorderableListView keyed `reorder-<id>`).
  Finder slot(String id) => find.byKey(ValueKey('reorder-$id'));

  Finder washIn(String id, CommitTarget target) => find.descendant(
    of: slot(id),
    matching: find.byKey(Key('commit-flash-${target.name}')),
  );

  /// The opacity of the wash currently painted over [target] in row [id].
  /// `-1` when that element renders no wash site at all (e.g. a row with no
  /// list tag), which is distinguishable from a site painting nothing.
  double wash(WidgetTester tester, String id, CommitTarget target) {
    final f = washIn(id, target);
    if (f.evaluate().isEmpty) return -1;
    return tester.widget<CommitWash>(f).color.a;
  }

  /// Let a command run and the task stream deliver WITHOUT advancing the clock,
  /// so the caller owns every frame of the flash that follows.
  Future<void> land(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  /// Ctrl-click the row titled [title] — the desktop selection gesture (the row
  /// body has an onDoubleTap, so the tap resolves only after that timeout).
  Future<void> ctrlClick(WidgetTester tester, String title) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  /// Open row [id]'s due segment and pick the quick-date option [option] — the
  /// primary desktop path to a new date. Everything up to the item tap happens
  /// on its own clock; the commit itself lands on the caller's frames.
  Future<void> quickDate(WidgetTester tester, String id, String option) async {
    await withClock(testClock, () async {
      await tester.tap(
        find.descendant(
          of: slot(id),
          matching: find.byKey(const Key('row-due-segment')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(quickDateKey(option)));
      // Inside the clock: the command resolves the move against `clock.now()`
      // on the microtask the tap schedules, not on the tap itself.
      await land(tester);
    });
  }

  group('the changed element washes when the store confirms the write', () {
    testWidgets('a quick-date move washes the DATE BADGE, and only it', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread', position: '2'),
        ],
        lists: oneList,
        platform: TargetPlatform.linux,
      );

      // Nothing is flashing on a list that has only just been drawn.
      expect(wash(tester, 'A', CommitTarget.due), 0);
      expect(wash(tester, 'A', CommitTarget.title), 0);
      expect(wash(tester, 'A', CommitTarget.row), 0);

      await quickDate(tester, 'A', 'tomorrow');

      // The write actually landed (testClock is 2026-06-15).
      expect(
        fake.tasks.firstWhere((t) => t.task.id == 'A').task.due,
        '2026-06-16T00:00:00.000Z',
      );
      // …and the badge that shows it is washed on the very next frame.
      expect(wash(tester, 'A', CommitTarget.due), closeTo(_peak, 0.001));
      // The elements that did NOT change stay untouched — the flash points at
      // what happened, it is not a general "this row was busy" glow.
      expect(wash(tester, 'A', CommitTarget.title), 0);
      expect(wash(tester, 'A', CommitTarget.row), 0);
      // …and so does every other row.
      expect(wash(tester, 'B', CommitTarget.due), 0);

      // Halfway through it is still there, and dimmer (it decays, ease-out).
      await tester.pump(const Duration(milliseconds: 200));
      final mid = wash(tester, 'A', CommitTarget.due);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(_peak));

      // Gone by the end of the span.
      await tester.pump(const Duration(milliseconds: 201));
      expect(wash(tester, 'A', CommitTarget.due), 0);
    });

    testWidgets('the wash covers the date badge, not the whole row', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      await quickDate(tester, 'A', 'tomorrow');

      final washRect = tester.getRect(washIn('A', CommitTarget.due));
      // It sits over the date badge the user just changed…
      expect(
        washRect.contains(
          tester.getCenter(
            find.descendant(
              of: slot('A'),
              matching: find.byKey(const Key('row-due-segment')),
            ),
          ),
        ),
        isTrue,
        reason: 'the wash covers the date badge it belongs to',
      );
      // …and nowhere near the title, which did not change.
      expect(
        washRect.contains(tester.getCenter(find.text('apples'))),
        isFalse,
        reason: 'the wash is on the element, not the row',
      );
    });

    testWidgets('an UNDATED row: dating it from "no date" washes the badge', (
      tester,
    ) async {
      // The non-happy path for the date badge — the empty field. "no date" is a
      // button (user ruling 2026-08-30), and it is how an undated task gets a
      // date without opening the detail.
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      expect(find.text('no date'), findsOneWidget);

      await quickDate(tester, 'A', 'today');

      expect(
        find.text('no date'),
        findsNothing,
        reason: 'the row now carries a date',
      );
      expect(wash(tester, 'A', CommitTarget.due), closeTo(_peak, 0.001));
    });

    testWidgets('a re-homed row washes its LIST TAG', (tester) async {
      // The one thing that changes a row's list IN PLACE: the store re-homing
      // an unpushed task when the list holding it is deleted
      // (`Store.rehomeUnpushedTasks` — same id, still dirty, new list_id). The
      // user-facing "Move to list" is NOT this: Google has no cross-list move,
      // so it is a delete-from-old + create-in-new under a NEW id, and the row
      // leaves and a new one arrives (#251's own motion) — asserted below.
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: twoLists,
        platform: TargetPlatform.linux,
      );
      expect(
        find.descendant(of: slot('A'), matching: find.text('My Tasks')),
        findsOneWidget,
      );

      final before = fake.tasks.single;
      fake.pushAll([
        StoredTask(
          task: before.task,
          listId: 'L2',
          syncState: SyncState.dirty,
          localUpdated: 't',
        ),
      ]);
      await land(tester);

      expect(
        find.descendant(of: slot('A'), matching: find.text('Errands')),
        findsOneWidget,
      );
      expect(wash(tester, 'A', CommitTarget.listTag), closeTo(_peak, 0.001));
      expect(wash(tester, 'A', CommitTarget.row), 0);
      expect(wash(tester, 'A', CommitTarget.title), 0);
    });

    testWidgets('"Move to list" is a departure and an arrival, not a flash', (
      tester,
    ) async {
      // The row the user moved is gone (its subtree was deleted from the old
      // list) and a different row — a new local id — took its place. Flashing
      // either would be a lie about what happened; #251 already folds one away
      // and grows the other in.
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: twoLists,
        platform: TargetPlatform.linux,
      );
      await tester.tap(find.text('apples'), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('taskmenu-move')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('taskmenu-move-L2')));
      await land(tester);
      await tester.pump(const Duration(milliseconds: 50));

      expect(fake.movedToList, ['A->L2']);
      expect(
        find.byWidgetPredicate((w) => w is CommitWash && w.color.a > 0),
        findsNothing,
      );
    });

    testWidgets('an inline rename washes the TITLE when it commits', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      // Double-click to rename is the desktop affordance (F19 #198).
      await tester.tap(find.text('apples'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('apples'));
      await settleList(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'apples'),
        'apricots',
      );
      // Submit commits the rename; the flash starts when the store confirms it,
      // not when the key was pressed.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await land(tester);

      expect(fake.renamed, ['A=apricots']);
      expect(find.text('apricots'), findsOneWidget);
      expect(wash(tester, 'A', CommitTarget.title), closeTo(_peak, 0.001));
      expect(wash(tester, 'A', CommitTarget.due), 0);
    });
  });

  group('the whole row washes when the changed element is not one thing', () {
    testWidgets('a bulk date change flashes every selected row, and no other', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread', position: '2'),
          row('C', 'cheese', position: '3'),
          row('D', 'dates', position: '4'),
        ],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      await ctrlClick(tester, 'apples');
      await ctrlClick(tester, 'bread');
      await ctrlClick(tester, 'cheese');

      await withClock(testClock, () async {
        await tester.tap(find.byKey(const Key('bulk-due')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(quickDateKey('tomorrow')));
        // Inside the clock: the bulk loop resolves each move as it awaits.
        await land(tester);
      });

      for (final id in ['A', 'B', 'C']) {
        expect(
          fake.tasks.firstWhere((t) => t.task.id == id).task.due,
          '2026-06-16T00:00:00.000Z',
          reason: '$id was rescheduled',
        );
        expect(
          wash(tester, id, CommitTarget.row),
          greaterThan(0),
          reason: '$id was in the selection, so the whole row flashes',
        );
        expect(
          wash(tester, id, CommitTarget.due),
          0,
          reason: 'a bulk change flashes the row, not the badge',
        );
      }
      // The row nobody selected is untouched — the flash marks WHICH rows the
      // bulk action hit, which is the whole point of it.
      expect(wash(tester, 'D', CommitTarget.row), 0);
      expect(wash(tester, 'D', CommitTarget.due), 0);
    });

    testWidgets('a sync pull that retitles a task flashes that ROW', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread', position: '2'),
        ],
        lists: oneList,
        platform: TargetPlatform.linux,
      );

      // A pull landing a remote retitle: the row lands CLEAN (nothing local
      // wrote it), which is what makes the changed field "not the app's".
      fake.pushExternal('B', 'brioche');
      await land(tester);

      expect(find.text('brioche'), findsOneWidget);
      expect(wash(tester, 'B', CommitTarget.row), closeTo(_peak, 0.001));
      expect(
        wash(tester, 'B', CommitTarget.title),
        0,
        reason: 'a pull may have changed several fields — the row is the unit',
      );
      expect(wash(tester, 'A', CommitTarget.row), 0);
    });

    testWidgets('a REAL pull — fake Google, real engine — flashes the row it '
        'rewrote, and no other', (tester) async {
      // The widget-layer end of the sync path: a genuine [SyncEngine] run over
      // the fake Google API and the real store, with the list watching. Another
      // device retitles one task; the pull lands it, and the row that changed
      // says so.
      final client = FakeTasksApi();
      client.seedList('L1', 'Inbox');
      client.seedTask('L1', 'r-a', 'apples', '00001');
      client.seedTask('L1', 'r-b', 'bread', '00002');
      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      final store = Store(db);
      final engine = SyncEngine.withPush(client, store, true);

      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await withClock(testClock, () async {
        await engine.run();
        final listId = (await store.allLists()).single.list.id;
        final ids = {
          for (final t in await store.allTasks()) t.task.title: t.task.id,
        };
        final container = ProviderContainer(
          overrides: [storeProvider.overrideWithValue(store)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.linux),
              builder: (context, child) => wrapWithToast(context, child),
              home: Scaffold(
                body: TaskListView(
                  viewId: listId,
                  selectedTaskId: null,
                  onOpenTask: _ignore,
                ),
              ),
            ),
          ),
        );
        await settleList(tester);
        expect(find.text('bread'), findsOneWidget);

        // Another device edits one task…
        await client.patchTask('L1', 'r-b', const TaskPatch(title: 'brioche'));
        // …and our next sync pulls it in.
        await engine.run();
        await land(tester);

        expect(find.text('brioche'), findsOneWidget);
        expect(
          wash(tester, ids['bread']!, CommitTarget.row),
          closeTo(_peak, 0.001),
        );
        expect(wash(tester, ids['apples']!, CommitTarget.row), 0);
      });
    });
  });

  group('the flash restarts, never stacks', () {
    testWidgets('a second date inside the flash restarts it at full strength', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      await quickDate(tester, 'A', 'tomorrow');
      expect(wash(tester, 'A', CommitTarget.due), closeTo(_peak, 0.001));

      // Catch the wash mid-decay…
      await tester.pump(const Duration(milliseconds: 200));
      final mid = wash(tester, 'A', CommitTarget.due);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(_peak));

      // …and commit another date on top of it.
      await quickDate(tester, 'A', 'week');

      // Exactly the peak, not the peak plus what was left of the first wash: a
      // repeat reads as one more event, never as a brighter one.
      expect(wash(tester, 'A', CommitTarget.due), closeTo(_peak, 0.001));
      // …and it runs its own full span from here.
      await tester.pump(const Duration(milliseconds: 399));
      expect(wash(tester, 'A', CommitTarget.due), greaterThan(0));
      await tester.pump(const Duration(milliseconds: 2));
      expect(wash(tester, 'A', CommitTarget.due), 0);
    });
  });

  group('nothing flashes that was not a change to a row already on screen', () {
    testWidgets('the first contents of a view never flash', (tester) async {
      await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread', position: '2'),
        ],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      for (final id in ['A', 'B']) {
        for (final target in CommitTarget.values) {
          final w = wash(tester, id, target);
          expect(w <= 0, isTrue, reason: '$id/$target is not flashing at rest');
        }
      }
    });

    testWidgets('a task that ARRIVES does not flash — it grows in (#251)', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Add a task'),
        'cider',
      );
      await tester.tap(find.byKey(const Key('quick-add-submit')));
      await land(tester);
      // A row still at the very start of its #251 growth is clipped to nothing,
      // so give it a slice of that motion before looking for it.
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('cider'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is CommitWash && w.color.a > 0),
        findsNothing,
        reason: 'an arrival is the entrance motion, not a commit flash',
      );
    });

    testWidgets('our own edit coming back from Google does not flash again', (
      tester,
    ) async {
      // The push landing: the row goes dirty → clean and Google hands back its
      // own normalisation of the value we just wrote. The user already saw that
      // commit; the round trip is not a second one.
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      await quickDate(tester, 'A', 'tomorrow');
      expect(wash(tester, 'A', CommitTarget.due), closeTo(_peak, 0.001));
      await tester.pump(const Duration(milliseconds: 401));
      expect(wash(tester, 'A', CommitTarget.due), 0);

      final pushed = fake.tasks.single;
      fake.pushAll([
        StoredTask(
          // Google returns the same day in its own formatting.
          task: pushed.task.copyWith(due: '2026-06-16T00:00:00.000+00:00'),
          listId: pushed.listId,
          syncState: SyncState.clean,
          localUpdated: pushed.localUpdated,
        ),
      ]);
      await land(tester);

      expect(wash(tester, 'A', CommitTarget.due), 0);
      expect(wash(tester, 'A', CommitTarget.row), 0);
    });
  });

  group('reduced motion', () {
    testWidgets('"remove animations" means no flash at all', (tester) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
        disableAnimations: true,
      );
      await quickDate(tester, 'A', 'tomorrow');

      // The write landed and the badge shows the new date — the state change
      // itself is the feedback…
      expect(
        fake.tasks.single.task.due,
        '2026-06-16T00:00:00.000Z',
        reason: 'the commit is not skipped, only the wash',
      );
      expect(
        find.text('no date'),
        findsNothing,
        reason: 'the row shows its new date',
      );
      // …and there is no wash, in this frame or any later one.
      expect(wash(tester, 'A', CommitTarget.due), 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(wash(tester, 'A', CommitTarget.due), 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(wash(tester, 'A', CommitTarget.due), 0);
    });

    testWidgets('a sync-pulled change is silent under reduced motion too', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
        disableAnimations: true,
      );
      fake.pushExternal('A', 'apricots');
      await land(tester);
      expect(find.text('apricots'), findsOneWidget);
      expect(wash(tester, 'A', CommitTarget.row), 0);
    });
  });

  group('a commit from another surface', () {
    testWidgets(
      'renaming in the DETAIL panel washes the row title in the list',
      (tester) async {
        // Two panes over ONE Commands double — the desktop layout, where the
        // list is watching while the detail is edited. The rename never touches
        // the list's own code path: the store confirms it, and the row reacts.
        final fake = FakeBackend([row('A', 'apples')]);
        addTearDown(fake.dispose);
        tester.view.physicalSize = const Size(1600, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              commandsProvider.overrideWithValue(fake),
              allTasksProvider.overrideWith((ref) => fake.tasksStream),
              listsProvider.overrideWith((ref) => Stream.value(oneList)),
            ],
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.linux),
              builder: (context, child) => wrapWithToast(context, child),
              home: Scaffold(
                body: Row(
                  children: [
                    const SizedBox(
                      width: 800,
                      child: TaskListView(
                        viewId: 'all',
                        selectedTaskId: null,
                        onOpenTask: _ignore,
                      ),
                    ),
                    SizedBox(
                      width: 800,
                      child: TaskDetail(
                        taskId: 'A',
                        onClose: () {},
                        onOpenTask: (_) {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await settleList(tester);

        // The panel's Title field holds the task; the list shows the same title
        // as a plain row.
        final titleField = find.widgetWithText(TextField, 'apples');
        expect(titleField, findsOneWidget);
        await tester.enterText(titleField, 'apricots');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await land(tester);

        // The panel commits on submit and again as its field settles; both are
        // the same write, and a repeat only restarts the one wash.
        expect(fake.tasks.single.task.title, 'apricots');
        expect(wash(tester, 'A', CommitTarget.title), closeTo(_peak, 0.001));
        expect(wash(tester, 'A', CommitTarget.row), 0);
      },
    );
  });
}

void _ignore(String _) {}
