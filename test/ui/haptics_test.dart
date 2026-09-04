// The haptic vocabulary (#257) — the seam itself, and the FIXED event set the
// app is allowed to fire.
//
// The failures these prevent:
//
//  • a phone that answers a gesture with nothing — the absence that makes an
//    Android app feel unfinished (there was not one HapticFeedback call in the
//    codebase before this);
//  • the opposite failure, which is worse: a device that buzzes on scroll, on
//    navigation, on every once-a-minute background sync. The vocabulary is
//    CLOSED, so the "zero calls" tests are as load-bearing as the "one call"
//    ones;
//  • a desktop build reaching for a haptic engine it does not have — the seam
//    must resolve to the no-op off Android;
//  • a user who silenced haptics in Properties still feeling them.
//
// Intensity cannot be judged headless. What CAN be pinned is exactly what the
// app asks the platform for, and that is what these assert: the recorded
// vocabulary on the device seam, and the real platform-channel message the
// Android implementation sends.

import 'dart:async';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/prefs_controller.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/model/task.dart' show TaskStatus;
import 'package:axiotask/src/ui/haptics.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
import 'package:axiotask/src/ui/toast.dart' show toastControllerProvider;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_haptics.dart';
import '../support/test_container.dart';
import 'detail_harness.dart'
    show list, openDetailOverflow, pumpDetail, row, settleDetail;
import 'list_harness.dart';
import 'toast_harness.dart' show wrapWithToast;

void main() {
  final oneList = [list('L1', 'My Tasks')];

  // ── The seam ─────────────────────────────────────────────────────────────
  group('the seam resolves per platform', () {
    test('Android gets the platform implementation', () {
      expect(hapticsFor(android: true), isA<PlatformHaptics>());
    });

    test('every other platform gets the no-op', () {
      expect(hapticsFor(android: false), isA<NoHaptics>());
    });

    test('the un-overridden device seam is the no-op on this desktop host', () {
      // The gate runs on Linux; the app must never reach for a haptic engine
      // that is not there (and a widget test must never fire one either).
      final container = createTestContainer();
      expect(container.read(hapticsDeviceProvider), isA<NoHaptics>());
    });
  });

  group('what the platform implementation actually sends', () {
    late List<Object?> sent;

    setUp(() {
      sent = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              sent.add(call.arguments);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('tick is a light impact, confirm medium, warn heavy', () async {
      const haptics = PlatformHaptics();
      haptics.tick();
      haptics.confirm();
      haptics.warn();
      await pumpEventQueue();

      expect(sent, <String>[
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.heavyImpact',
      ]);
    });

    test('the no-op never touches the platform channel', () async {
      const haptics = NoHaptics();
      haptics.tick();
      haptics.confirm();
      haptics.warn();
      await pumpEventQueue();

      expect(sent, isEmpty);
    });
  });

  group('the haptics pref gates the seam', () {
    test('pref ON reaches the device', () {
      final device = FakeHaptics();
      final container = createTestContainer(
        overrides: [
          prefsProvider.overrideWithValue(const Prefs()),
          hapticsDeviceProvider.overrideWithValue(device),
        ],
      );
      container.read(hapticsProvider).tick();
      expect(device.events, <String>['tick']);
    });

    test('the pref defaults ON — a fresh install feels its gestures', () {
      expect(const Prefs().haptics, isTrue);
    });

    test('pref OFF never reaches the device', () {
      final device = FakeHaptics();
      final container = createTestContainer(
        overrides: [
          prefsProvider.overrideWithValue(const Prefs(haptics: false)),
          hapticsDeviceProvider.overrideWithValue(device),
        ],
      );
      final haptics = container.read(hapticsProvider);
      haptics
        ..tick()
        ..confirm()
        ..warn();
      expect(device.events, isEmpty);
    });
  });

  // ── The vocabulary, through the real list surface ────────────────────────
  group('tick', () {
    testWidgets('a checkbox tap ticks — once', (tester) async {
      final haptics = FakeHaptics();
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        hapticsDevice: haptics,
      );
      expect(haptics.events, isEmpty, reason: 'nothing fires on mount');

      await tester.tap(checkboxOf('apples'));
      await settleList(tester);

      expect(haptics.events, <String>['tick']);
    });

    testWidgets('re-opening a completed task ticks too', (tester) async {
      final haptics = FakeHaptics();
      await pumpList(
        tester,
        initial: [row('A', 'apples', done: true)],
        lists: oneList,
        showCompleted: true,
        hapticsDevice: haptics,
      );

      await tester.tap(checkboxOf('apples'));
      await settleList(tester);

      expect(haptics.events, <String>['tick']);
    });

    testWidgets('toggling a row into the selection ticks', (tester) async {
      final haptics = FakeHaptics();
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
        hapticsDevice: haptics,
      );

      await ctrlClick(tester, 'apples');
      expect(haptics.events, <String>['tick']);

      // And leaving the selection is the same event.
      await ctrlClick(tester, 'apples');
      expect(haptics.events, <String>['tick', 'tick']);
    });

    testWidgets('applying a quick date ticks', (tester) async {
      final haptics = FakeHaptics();
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
        hapticsDevice: haptics,
      );

      // The row's date segment opens the shared quick-date surface.
      await tester.tap(find.byKey(const Key('row-due-segment')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(quickDateKey('tomorrow')));
      await settleList(tester);

      expect(fake.setDueCalls, isNotEmpty, reason: 'the date was applied');
      expect(haptics.events, <String>['tick']);
    });

    testWidgets('a drag ticks on the lift and again on the drop', (
      tester,
    ) async {
      final haptics = FakeHaptics();
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'a', position: '1'),
          row('B', 'b', position: '2'),
        ],
        lists: oneList,
        hapticsDevice: haptics,
      );

      final handle = find.byKey(const Key('drag-handle-A'));
      final rowHeight = tester.getSize(find.byKey(const ValueKey('A'))).height;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(Offset(0, rowHeight * 0.6));
      await tester.pump();
      expect(haptics.events, <String>[
        'tick',
      ], reason: 'the lift is felt while the finger is still down');
      await gesture.moveBy(Offset(0, rowHeight * 0.6));
      await tester.pump();
      expect(haptics.events, <String>[
        'tick',
      ], reason: 'travelling is not an event — only the lift and the drop are');
      await gesture.up();
      await tester.pumpAndSettle();

      expect(fake.reordered, <String>['A:B']);
      expect(haptics.events, <String>['tick', 'tick']);
    });

    testWidgets('a swipe ticks the moment it crosses the action threshold', (
      tester,
    ) async {
      final haptics = FakeHaptics();
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        hapticsDevice: haptics,
      );

      // Swipe LEFT past the threshold: the arming tick fires under the finger,
      // before the quick-date sheet is raised on release.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('apples')),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(
        haptics.events,
        isEmpty,
        reason: 'a sub-threshold nudge commits nothing, so it says nothing',
      );
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(haptics.events, <String>['tick'], reason: 'threshold crossed');

      // Crossing again in the same drag must not re-arm.
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(haptics.events, <String>['tick']);
      await gesture.up();
      await settleList(tester);
    });

    testWidgets('a swipe that never reaches the threshold says nothing', (
      tester,
    ) async {
      final haptics = FakeHaptics();
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        hapticsDevice: haptics,
      );

      await tester.drag(find.text('apples'), const Offset(40, 0));
      await settleList(tester);

      expect(haptics.events, isEmpty);
    });

    testWidgets('a swipe right on an ALREADY completed row says nothing', (
      tester,
    ) async {
      // Swipe-right on a completed row is a deliberate no-op (F15 #193). A
      // gesture that changes nothing must not claim it did.
      final haptics = FakeHaptics();
      await pumpList(
        tester,
        initial: [row('A', 'apples', done: true)],
        lists: oneList,
        showCompleted: true,
        hapticsDevice: haptics,
      );

      await tester.drag(find.text('apples'), const Offset(180, 0));
      await settleList(tester);

      expect(haptics.events, isEmpty);
    });
  });

  group('confirm', () {
    testWidgets('deleting one task confirms', (tester) async {
      final haptics = FakeHaptics();
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
        hapticsDevice: haptics,
      );

      await tester.tap(find.text('apples'), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('taskmenu-delete')));
      await settleList(tester);

      expect(fake.tasks, isEmpty);
      expect(haptics.events, <String>['confirm']);
    });

    testWidgets('a bulk delete confirms once, not once per task', (
      tester,
    ) async {
      final haptics = FakeHaptics();
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cheese')],
        lists: oneList,
        platform: TargetPlatform.linux,
        hapticsDevice: haptics,
      );
      await ctrlClick(tester, 'apples');
      await ctrlClick(tester, 'bread');
      haptics.clear(); // the selection ticks are not what this asserts

      await tester.tap(find.byKey(const Key('bulk-delete')));
      await settleList(tester);

      expect(fake.tasks.map((t) => t.task.id), <String>['C']);
      expect(haptics.events, <String>['confirm']);
    });

    testWidgets('Undo confirms the reversal', (tester) async {
      final haptics = FakeHaptics();
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
        hapticsDevice: haptics,
      );
      await tester.tap(find.text('apples'), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('taskmenu-delete')));
      await settleList(tester);
      haptics.clear(); // the delete's own confirm

      await tester.tap(find.text('Undo'));
      await settleList(tester);

      expect(fake.tasks.map((t) => t.task.id), <String>['A']);
      expect(haptics.events, <String>['confirm']);
    });
  });

  group('silence — the vocabulary is closed', () {
    testWidgets('opening a task says nothing', (tester) async {
      final haptics = FakeHaptics();
      final opened = <String>[];
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        opened: opened,
        platform: TargetPlatform.linux,
        hapticsDevice: haptics,
      );

      await tester.tap(find.text('apples'));
      await settleList(tester);

      expect(opened, <String>['A'], reason: 'the row really did open');
      expect(haptics.events, isEmpty);
    });

    testWidgets('changing the sort says nothing', (tester) async {
      final haptics = FakeHaptics();
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
        hapticsDevice: haptics,
      );

      await tester.tap(find.byKey(const Key('sort-dropdown')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Alphabetical').last);
      await settleList(tester);

      expect(haptics.events, isEmpty);
    });

    testWidgets('scrolling the list says nothing', (tester) async {
      final haptics = FakeHaptics();
      await pumpList(
        tester,
        initial: [
          for (var i = 0; i < 40; i++) row('T$i', 'task $i', position: '$i'),
        ],
        lists: oneList,
        size: const Size(400, 800),
        hapticsDevice: haptics,
      );

      await tester.drag(find.text('task 0'), const Offset(0, -400));
      await settleList(tester);

      expect(haptics.events, isEmpty);
    });
  });

  group('the detail panel speaks the same vocabulary', () {
    testWidgets('a subtask checkbox ticks', (tester) async {
      final haptics = FakeHaptics();
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C', 'child', parent: 'P'),
        ],
        hapticsDevice: haptics,
      );

      await tester.tap(
        find.descendant(
          of: find.ancestor(of: find.text('child'), matching: find.byType(Row)),
          matching: find.byType(Checkbox),
        ),
      );
      await settleDetail(tester);

      expect(
        fake.tasks.firstWhere((t) => t.task.id == 'C').task.status,
        TaskStatus.completed,
      );
      expect(haptics.events, <String>['tick']);
    });

    testWidgets('deleting the open task confirms', (tester) async {
      final haptics = FakeHaptics();
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'doomed')],
        hapticsDevice: haptics,
      );

      await openDetailOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-delete')));
      await settleDetail(tester);

      expect(fake.deleted, hasLength(1));
      expect(haptics.events, <String>['confirm']);
    });

    testWidgets('a subtask quick date ticks', (tester) async {
      final haptics = FakeHaptics();
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C', 'child', parent: 'P'),
        ],
        hapticsDevice: haptics,
      );

      await tester.tap(find.byKey(const Key('sub-due-C')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(quickDateKey('today')));
      await settleDetail(tester);

      expect(fake.setDueCalls, isNotEmpty);
      expect(haptics.events, <String>['tick']);
    });

    testWidgets('typing in the title says nothing', (tester) async {
      final haptics = FakeHaptics();
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'parent')],
        hapticsDevice: haptics,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'parent'),
        'parental',
      );
      await settleDetail(tester);

      expect(haptics.events, isEmpty);
    });
  });

  group('through the whole shell', () {
    testWidgets('switching views and a background sync say nothing', (
      tester,
    ) async {
      // The two events the design explicitly rules out: navigation, and the
      // once-a-minute poll. A device that buzzed for either would be buzzing
      // all day for things the user did not do.
      final haptics = FakeHaptics();
      final runs = StreamController<SyncRunEvent>.broadcast();
      addTearDown(runs.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(const Prefs(onboardingSeen: true)),
            hapticsDeviceProvider.overrideWithValue(haptics),
            allTasksProvider.overrideWith((ref) => Stream.value([])),
            listsProvider.overrideWith((ref) => Stream.value(oneList)),
            syncRunEventsProvider.overrideWith((ref) => runs.stream),
          ],
          child: const AxiotaskApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Focus'));
      await tester.pumpAndSettle();
      expect(find.text('Focus'), findsWidgets, reason: 'the view did switch');

      runs.add(const SyncRunEvent.started());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      runs.add(const SyncRunEvent.finished(changed: true, failed: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(haptics.events, isEmpty);
    });

    testWidgets('dragging a LIST in the sidebar ticks on lift and drop', (
      tester,
    ) async {
      // The same two-ended gesture as a task drag, through the shell's own
      // sidebar — so this covers the wiring from the shell down, not just the
      // widget in isolation.
      final haptics = FakeHaptics();
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(const Prefs(onboardingSeen: true)),
            hapticsDeviceProvider.overrideWithValue(haptics),
            allTasksProvider.overrideWith((ref) => Stream.value([])),
            listsProvider.overrideWith(
              (ref) => Stream.value([
                list('L1', 'Work'),
                list('L2', 'Home'),
                list('L3', 'Errands'),
              ]),
            ),
          ],
          child: const AxiotaskApp(),
        ),
      );
      await tester.pumpAndSettle();

      final handles = find.byIcon(Icons.drag_indicator);
      final start = tester.getCenter(handles.at(2));
      final target = tester.getCenter(handles.at(0));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(Offset(target.dx, target.dy - 40));
      await tester.pump(const Duration(milliseconds: 50));
      expect(haptics.events, <String>['tick'], reason: 'the lift');
      await gesture.up();
      await tester.pumpAndSettle();

      expect(haptics.events, <String>['tick', 'tick'], reason: 'and the drop');
    });
  });

  group('the pref silences every event', () {
    testWidgets('silencing haptics while an undo toast is UP silences it too', (
      tester,
    ) async {
      // The toast stack lives in its own overlay entry, which does not rebuild
      // with the app: a card already on screen must not keep the seam it was
      // built with.
      final haptics = FakeHaptics();
      final container = createTestContainer(
        overrides: [
          prefsProvider.overrideWithValue(const Prefs()),
          hapticsDeviceProvider.overrideWithValue(haptics),
        ],
      );
      final toasts = container.read(toastControllerProvider);
      var undone = 0;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: wrapWithToast,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );
      toasts.showUndo('Deleted "apples"', () => undone++);
      await tester.pump();
      expect(find.text('Undo'), findsOneWidget);

      // The user opens Properties and turns haptics off while the toast is up.
      container.read(prefsControllerProvider.notifier).setHaptics(false);
      await tester.pump();

      await tester.tap(find.text('Undo'));
      await tester.pump();

      expect(undone, 1, reason: 'the undo still ran');
      expect(haptics.events, isEmpty);
    });

    testWidgets('a checkbox tap and a delete both stay silent', (tester) async {
      final haptics = FakeHaptics();
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        platform: TargetPlatform.linux,
        hapticsDevice: haptics,
        haptics: false,
      );

      await tester.tap(checkboxOf('apples'));
      await settleList(tester);
      await tester.tap(find.text('bread'), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('taskmenu-delete')));
      await settleList(tester);

      // The actions themselves still happened — only the feedback is gone.
      expect(fake.tasks.map((t) => t.task.id), <String>['A']);
      expect(haptics.events, isEmpty);
    });

    testWidgets('a drag and a quick date stay silent', (tester) async {
      final haptics = FakeHaptics();
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'a', position: '1'),
          row('B', 'b', position: '2'),
        ],
        lists: oneList,
        hapticsDevice: haptics,
        haptics: false,
      );

      final handle = find.byKey(const Key('drag-handle-A'));
      final rowHeight = tester.getSize(find.byKey(const ValueKey('A'))).height;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(Offset(0, rowHeight * 0.6));
      await tester.pump();
      await gesture.moveBy(Offset(0, rowHeight * 0.6));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(fake.reordered, <String>['A:B'], reason: 'the drag still worked');
      expect(haptics.events, isEmpty);
    });
  });
}

/// The row [title]'s own checkbox — the list toolbar carries one too, so an
/// unscoped [Checkbox] finder would tap the wrong control.
Finder checkboxOf(String title) => find.descendant(
  of: find.ancestor(
    of: find.text(title),
    matching: find.byKey(const Key('swipe-content')),
  ),
  matching: find.byType(Checkbox),
);

/// Ctrl-click the row titled [title] — the desktop selection gesture. The row
/// body has an onDoubleTap, so a single tap only resolves after the double-tap
/// timeout; pump past it while the modifier is still held.
Future<void> ctrlClick(WidgetTester tester, String title) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.tap(find.text(title));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}
