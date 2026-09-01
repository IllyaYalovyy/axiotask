// MobileDrawer suite (MIGRATION-PLAN §5 T8.2). On a phone the sidebar is a
// slide-in [Drawer] opened from the app-bar hamburger; picking a view or list
// from it navigates AND dismisses the drawer (drawer > selection), and a system
// back closes an open drawer instead of backgrounding the app.
//
// These drive the REAL shell (AxiotaskApp → AppShell → ListDetailScaffold) over
// static provider streams — no database — so the assertions are about what the
// user sees: the drawer's sidebar appearing and then going away after a tap.
//
// The last group is the PREDICTIVE-back contract (#263). Android 13+ asks the
// app UP FRONT — before the gesture, via
// [SystemNavigator.setFrameworkHandlesBack] — whether Flutter will handle the
// next back. Answer "no" and the OS runs the gesture itself and finishes the
// activity: the app is GONE before any PopScope callback could run. So an open
// drawer is not enough to be closeable by [handlePopRoute] (the legacy button
// path) — the shell has to have TOLD the OS it handles back while the drawer
// is open, which is exactly what these assert.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_drawer'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // Onboarding already dismissed so the welcome overlay never sits over the
  // shell (these tests exercise the chrome, not first launch).
  PrefsStore seenPrefs() =>
      PrefsStore(File(p.join(tmp.path, 'prefs.json')))
        ..save(const Prefs(onboardingSeen: true));

  StoredTask task(String id, String title) => StoredTask(
    task: Task(
      id: id,
      position: '1',
      title: title,
      status: TaskStatus.needsAction,
      updated: 't',
    ),
    listId: 'L1',
    syncState: SyncState.clean,
    localUpdated: 't',
  );

  StoredTaskList list(String id, String title) => StoredTaskList(
    list: TaskList(id: id, title: title, etag: 'e', updated: 't'),
    syncState: SyncState.clean,
    localUpdated: 't',
  );

  // The drawer's sidebar is uniquely identified by this key — a robust proxy
  // for "the drawer is open" that never collides with the bottom-nav labels
  // (Focus/All Tasks appear in BOTH the nav bar and the drawer header).
  final drawerSidebar = find.byKey(const Key('sidebar-lists-reorderable'));

  Future<PrefsStore> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = seenPrefs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(store.load()),
          prefsStoreProvider.overrideWithValue(store),
          allTasksProvider.overrideWith(
            (ref) => Stream.value([task('T1', 'Buy milk')]),
          ),
          listsProvider.overrideWith(
            (ref) => Stream.value([list('L1', 'Groceries')]),
          ),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> openDrawer(WidgetTester tester) async {
    // The app bar's auto hamburger (a drawer is present).
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
  }

  testWidgets('the hamburger opens the drawer, revealing the full sidebar', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(drawerSidebar, findsNothing, reason: 'closed at rest');

    await openDrawer(tester);

    expect(drawerSidebar, findsOneWidget);
    // The user's list is only reachable through the drawer on a phone.
    expect(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Groceries'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'picking a list from the drawer navigates AND closes the drawer',
    (tester) async {
      final store = await pumpShell(tester);
      await openDrawer(tester);

      await tester.tap(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.text('Groceries'),
        ),
      );
      await tester.pumpAndSettle();

      // Navigated to the list (persisted, survives restart) …
      expect(store.load().view, 'L1');
      // … and the drawer dismissed itself after the pick (drawer > selection).
      expect(drawerSidebar, findsNothing);
    },
  );

  testWidgets('picking a smart view from the drawer closes it too', (
    tester,
  ) async {
    final store = await pumpShell(tester);
    await openDrawer(tester);

    // "Focus" lives in both the drawer header and the bottom nav — scope to the
    // drawer so the tap is unambiguous.
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text('Focus')),
    );
    await tester.pumpAndSettle();

    expect(store.load().view, 'focus');
    expect(drawerSidebar, findsNothing);
  });

  testWidgets('a system back closes an open drawer instead of the app', (
    tester,
  ) async {
    await pumpShell(tester);
    await openDrawer(tester);
    expect(drawerSidebar, findsOneWidget);

    // The Android/system back button, routed through the shell PopScope.
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      handled,
      isTrue,
      reason: 'back must not fall through to exit the app',
    );
    expect(drawerSidebar, findsNothing, reason: 'back closed the drawer');
  });

  // The predictive-back contract (#263). What the OS acts on is the LAST value
  // the app pushed through SystemNavigator.setFrameworkHandlesBack; `false`
  // means "nothing here handles back", and Android 13+ then animates the app
  // away and finishes the activity without ever asking Flutter again.
  group('predictive back (#263)', () {
    /// Records every value the app pushes to the platform, newest last, and
    /// puts the app in a lifecycle state where it pushes them at all (WidgetsApp
    /// skips the platform update while the lifecycle state is null/detached).
    ///
    /// Must be called BEFORE the app is pumped: the value is published when a
    /// PopScope registers or changes, not polled.
    List<bool> recordHandlesBack(WidgetTester tester) {
      final pushed = <bool>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          pushed.add(call.arguments as bool);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      messenger.handlePlatformMessage(
        SystemChannels.lifecycle.name,
        const StringCodec().encodeMessage('AppLifecycleState.resumed'),
        (_) {},
      );
      return pushed;
    }

    testWidgets('an open drawer tells the OS that the app handles back', (
      tester,
    ) async {
      final handlesBack = recordHandlesBack(tester);
      await pumpShell(tester);
      expect(
        handlesBack.last,
        isFalse,
        reason: 'at rest nothing is open, so back belongs to the OS',
      );

      await openDrawer(tester);
      expect(drawerSidebar, findsOneWidget);

      expect(
        handlesBack.last,
        isTrue,
        reason:
            'with the drawer open the OS must hand the gesture to Flutter — '
            'told "false" it finishes the activity and the app exits',
      );

      // …and the back it hands over closes the drawer without popping the
      // route the whole app is standing on.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(drawerSidebar, findsNothing, reason: 'back closed the drawer');
      expect(
        find.text('Buy milk'),
        findsOneWidget,
        reason: 'the shell is still on screen — the route did not pop',
      );
      expect(
        handlesBack.last,
        isFalse,
        reason:
            'drawer closed: the NEXT back is the OS\'s again, so the app '
            'stays exitable',
      );
    });

    testWidgets(
      'rotating into the expanded layout with the drawer open leaves back '
      'to the OS — it is never deadened',
      (tester) async {
        // The non-happy path a cached "drawer is open" flag would break (T8.2):
        // the drawer unmounts WITH the compact layout, and nothing closes it
        // first. If the shell kept claiming back after that, the gesture would
        // reach an app that has nothing to do with it — a back button that does
        // nothing at all, on the layout with no drawer to close.
        final handlesBack = recordHandlesBack(tester);
        await pumpShell(tester);
        await openDrawer(tester);
        expect(handlesBack.last, isTrue);

        tester.view.physicalSize = const Size(1200, 800);
        await tester.pumpAndSettle();

        // The permanent sidebar replaced the drawer …
        expect(find.byType(Drawer), findsNothing);
        // … and back went back to the OS.
        expect(
          handlesBack.last,
          isFalse,
          reason: 'no drawer to close: the app must not claim the gesture',
        );
        expect(
          await tester.binding.handlePopRoute(),
          isFalse,
          reason: 'nothing app-owned is open → the OS pops the app',
        );
      },
    );
  });
}
