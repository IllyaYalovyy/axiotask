// The compact shell's Android back stack, end to end (#273).
//
// Two INDEPENDENT mechanisms answer a back on the phone, and until this file
// nothing exercised them together:
//
//   • the shell's PopScope ladder (app_shell.dart) — drawer → welcome → detail
//     → rename → selection → the OS, one rung per press;
//   • the compact detail layer's predictive-back observer (#253), a
//     WidgetsBindingObserver that CLAIMS the gesture so the surface follows the
//     finger.
//
// A claimed gesture skips `handlePopRoute()` entirely (widgets/binding.dart
// `_handleCommitBackGesture`), so an observer that claims while a menu, sheet
// or dialog is open above the detail scrubs the detail closed UNDERNEATH the
// modal — and the entry the user then picks runs against a disposed panel
// (`ref` after dispose). The observer therefore claims only when its own route
// is current AND the event is a real drag; a back BUTTON press carries no
// finger to follow and falls through to the ladder, which closes the same
// things through the app's own path.
//
// Every case below is driven at the REAL shell over a [FakeCommands], through
// the platform channel Android actually uses, in BOTH forms:
//   • predictive — startBackGesture (edge touch) → progress → commit;
//   • button     — startBackGesture with no touch point → commit, which is what
//                  API 34+ delivers for the 3-button navigation bar
//                  ([PredictiveBackEvent.isButtonEvent]).
// Each asserts that EXACTLY the topmost surface closed and what sits below it
// is untouched — and, where a modal was involved, that the detail still WORKS
// afterwards (the fake holds the edit made through it).
//
// Determinism: no real timers. Route transitions and the 400ms detail
// transform are pumped against the fake clock by [settle]; nothing calls
// pumpAndSettle while a caret is blinking.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/window_title_controller.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:axiotask/src/ui/detail_motion.dart'
    show DetailContainerTransform;
import 'package:axiotask/src/ui/quick_date_menu.dart' show quickDateKey;
import 'package:axiotask/src/ui/router.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import 'detail_harness.dart' show FakeCommands, list, row;

/// A bounded settle. The surfaces here (the detail's Title/Notes fields, the
/// composer, an inline rename editor) hold focused text fields, and
/// `pumpAndSettle` never returns while a caret blinks.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

/// Send one message on the channel Android drives back with.
Future<void> _back(
  WidgetTester tester,
  String method, [
  Map<String, dynamic>? args,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
}

/// A full predictive back: a drag in from the left edge, released past the
/// commit threshold.
Future<void> predictiveBack(WidgetTester tester) async {
  await _back(tester, 'startBackGesture', {
    'touchOffset': <double>[5, 400],
    'progress': 0.0,
    'swipeEdge': 0,
  });
  await _back(tester, 'updateBackGestureProgress', {
    'touchOffset': <double>[240, 400],
    'progress': 0.6,
    'swipeEdge': 0,
  });
  await tester.pump();
  await _back(tester, 'commitBackGesture');
  await settle(tester);
}

/// A press of the 3-button navigation bar's back: the same channel, with NO
/// touch point — the shape Android reports for a button invocation.
Future<void> buttonBack(WidgetTester tester) async {
  await _back(tester, 'startBackGesture', {
    'touchOffset': null,
    'progress': 0.0,
    'swipeEdge': 0,
  });
  await _back(tester, 'commitBackGesture');
  await settle(tester);
}

/// Both back forms, run as one test body each.
const backForms = <String, Future<void> Function(WidgetTester)>{
  'predictive back': predictiveBack,
  'button back': buttonBack,
};

void main() {
  late Directory tmp;
  setUp(() {
    debugDefaultTargetPlatformOverride = null;
    tmp = Directory.systemTemp.createTempSync('axiotask_back_ladder_test');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Onboarding already dismissed — the welcome overlay is its own rung and
  /// would otherwise sit over every case here.
  PrefsStore seenPrefs() =>
      PrefsStore(File(p.join(tmp.path, 'prefs.json')))
        ..save(const Prefs(onboardingSeen: true));

  Future<(FakeCommands, GoRouter)> pumpPhone(
    WidgetTester tester, {
    List<StoredTask> tasks = const [],
    TargetPlatform? platform,
  }) async {
    // NOT an addTearDown: flutter_test asserts every foundation debug var is
    // unset at the END OF THE BODY, before tear-downs run — so a test that pins
    // a platform clears it itself and the setUp above catches an early-failure
    // leak.
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = FakeCommands(List.of(tasks));
    addTearDown(fake.dispose);
    final store = seenPrefs();
    final router = buildAppRouter(initialViewId: 'all');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(store.load()),
          prefsStoreProvider.overrideWithValue(store),
          windowTitleControllerProvider.overrideWithValue(
            const NoopWindowTitleController(),
          ),
          commandsProvider.overrideWithValue(fake),
          allTasksProvider.overrideWith((ref) => fake.tasksStream),
          listsProvider.overrideWith(
            (ref) => Stream.value([list('L1', 'My Tasks')]),
          ),
          routerProvider.overrideWithValue(router),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
    return (fake, router);
  }

  /// The open detail panel — its app bar title, which only the panel renders
  /// (a covered compact shell is Offstage and finds nothing).
  final detail = find.text('Task Details');
  final overflow = find.byKey(const Key('detail-overflow'));
  final dueField = find.byKey(const Key('due-field'));
  final drawerLists = find.byKey(const Key('sidebar-lists-reorderable'));
  final calendar = find.byType(CalendarDatePicker);

  Future<void> openDetail(
    WidgetTester tester,
    GoRouter router,
    String taskId,
  ) async {
    router.go(viewPath('all', taskId: taskId));
    await settle(tester);
    expect(detail, findsOneWidget);
  }

  backForms.forEach((name, back) {
    group(name, () {
      testWidgets('an open drawer closes; the list behind it stays', (
        tester,
      ) async {
        await pumpPhone(tester, tasks: [row('T1', 'my task')]);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await settle(tester);
        expect(drawerLists, findsOneWidget);

        await back(tester);

        expect(drawerLists, findsNothing, reason: 'the drawer is rung 0');
        expect(
          find.text('my task'),
          findsOneWidget,
          reason: 'the list behind the drawer was never navigated away from',
        );
      });

      testWidgets('an open detail closes back to its list', (tester) async {
        final (_, router) = await pumpPhone(
          tester,
          tasks: [row('T1', 'my task')],
        );
        await openDetail(tester, router, 'T1');

        await back(tester);

        expect(detail, findsNothing);
        expect(find.text('my task'), findsOneWidget);
      });

      testWidgets('the detail overflow MENU closes; the detail stays open and '
          'still works', (tester) async {
        final (fake, router) = await pumpPhone(
          tester,
          tasks: [row('T1', 'my task')],
        );
        await openDetail(tester, router, 'T1');
        await tester.tap(overflow);
        await settle(tester);
        expect(find.byKey(const Key('detail-delete')), findsOneWidget);

        await back(tester);

        expect(
          find.byKey(const Key('detail-delete')),
          findsNothing,
          reason: 'the menu is the topmost route — back closes IT',
        );
        expect(
          detail,
          findsOneWidget,
          reason: 'the detail under the menu must not close with it',
        );
        // …and it is a live panel, not a corpse: an edit made through it lands.
        await tester.enterText(
          find.widgetWithText(TextField, 'Notes'),
          'still alive',
        );
        await settle(tester);
        expect(
          fake.tasks.firstWhere((t) => t.task.id == 'T1').task.notes,
          'still alive',
        );
      });

      testWidgets('the quick-date SHEET closes; the detail stays open', (
        tester,
      ) async {
        final (_, router) = await pumpPhone(
          tester,
          tasks: [row('T1', 'my task')],
        );
        await openDetail(tester, router, 'T1');
        await tester.tap(dueField);
        await settle(tester);
        expect(find.byKey(quickDateKey('today')), findsOneWidget);

        await back(tester);

        expect(find.byKey(quickDateKey('today')), findsNothing);
        expect(detail, findsOneWidget);
      });

      testWidgets('the date-picker DIALOG closes; the detail stays open and '
          'the date can still be set', (tester) async {
        final (fake, router) = await pumpPhone(
          tester,
          tasks: [row('T1', 'my task')],
        );
        await openDetail(tester, router, 'T1');
        // Due → the sheet → "Pick a date…" → the calendar dialog.
        await tester.tap(dueField);
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('pick')));
        await settle(tester);
        expect(calendar, findsOneWidget);

        await back(tester);

        expect(
          calendar,
          findsNothing,
          reason: 'back dismisses the calendar it was aimed at',
        );
        expect(
          detail,
          findsOneWidget,
          reason: 'the detail under the dialog must not close with it',
        );
        // The panel the dialog was raised from is still the live one: the same
        // Due control, taken to a real date, reaches the store.
        await tester.tap(dueField);
        await settle(tester);
        await tester.tap(find.byKey(quickDateKey('today')));
        await settle(tester);
        expect(
          fake.tasks.firstWhere((t) => t.task.id == 'T1').task.due,
          isNotNull,
          reason: 'a menu entry chosen after the back ran on a LIVE panel',
        );
      });

      testWidgets('the composer sheet closes; nothing else moves', (
        tester,
      ) async {
        await pumpPhone(tester, tasks: [row('T1', 'my task')]);
        await tester.tap(find.byType(FloatingActionButton));
        await settle(tester);
        expect(find.byKey(const Key('composer-surface')), findsOneWidget);

        await back(tester);

        expect(find.byKey(const Key('composer-surface')), findsNothing);
        expect(find.text('my task'), findsOneWidget);
      });

      testWidgets('an active selection clears; the list stays', (tester) async {
        await pumpPhone(tester, tasks: [row('T1', 'my task')]);
        await tester.longPress(find.text('my task'));
        await settle(tester);
        expect(find.byType(BulkBar), findsOneWidget);

        await back(tester);

        expect(find.byType(BulkBar), findsNothing);
        expect(find.text('my task'), findsOneWidget);
        expect(
          detail,
          findsNothing,
          reason: 'clearing a selection is not a navigation',
        );
      });

      testWidgets('an open detail wins over a standing selection — one back is '
          'one rung', (tester) async {
        final (_, router) = await pumpPhone(
          tester,
          tasks: [row('T1', 'my task')],
        );
        await tester.longPress(find.text('my task'));
        await settle(tester);
        expect(find.byType(BulkBar), findsOneWidget);
        await openDetail(tester, router, 'T1');

        await back(tester);

        expect(detail, findsNothing, reason: 'the detail is the higher rung');
        expect(
          find.byType(BulkBar),
          findsOneWidget,
          reason: 'the selection behind it survives the same press',
        );
      });

      testWidgets('an inline rename commits and closes; the row stays', (
        tester,
      ) async {
        // Inline rename is a FINE-pointer affordance (double-click), so this is
        // the narrow desktop window — the same compact chrome, the same ladder.
        final (fake, _) = await pumpPhone(
          tester,
          tasks: [row('T1', 'my task')],
          platform: TargetPlatform.linux,
        );
        final rowEditor = find.descendant(
          of: find.byType(TaskRow),
          matching: find.byType(TextField),
        );
        await tester.tap(find.text('my task'));
        await tester.pump(kDoubleTapMinTime);
        await tester.tap(find.text('my task'));
        await settle(tester);
        expect(rowEditor, findsOneWidget);
        await tester.enterText(rowEditor, 'renamed');
        await settle(tester);

        await back(tester);

        expect(rowEditor, findsNothing, reason: 'the editor closed');
        expect(
          fake.tasks.firstWhere((t) => t.task.id == 'T1').task.title,
          'renamed',
          reason: 'a back mid-rename COMMITS the text, it does not drop it',
        );
        debugDefaultTargetPlatformOverride = null;
      });
    });
  });

  // A BUTTON back is declined by the detail's observer so the ladder can own it
  // — but the user must not be able to tell: the panel still shrinks back into
  // the list rather than being cut away. Guards the other half of the #273 fix
  // (declining must not degrade the close it hands over).
  testWidgets('a button back closes the detail with the shrink-back transform, '
      'not a cut', (tester) async {
    await pumpPhone(tester, tasks: [row('T1', 'my task')]);
    // Opened by TAPPING the row, so the panel has a row rect to shrink back
    // into — a detail reached from a URL has no container and only fades.
    await tester.tap(find.text('my task'));
    await settle(tester);
    expect(detail, findsOneWidget);
    final surface = find.byKey(DetailContainerTransform.surfaceKey);
    expect(tester.getSize(surface).height, 800);

    await _back(tester, 'startBackGesture', {
      'touchOffset': null,
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await _back(tester, 'commitBackGesture');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final mid = tester.getSize(surface).height;
    expect(mid, lessThan(800), reason: 'it is leaving …');
    expect(mid, greaterThan(0), reason: '… and travelling, not cut away');

    await settle(tester);
    expect(surface, findsNothing);
    expect(find.text('my task'), findsOneWidget);
  });
}
