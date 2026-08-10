// MobileDrawer suite (MIGRATION-PLAN §5 T8.2). On a phone the sidebar is a
// slide-in [Drawer] opened from the app-bar hamburger; picking a view or list
// from it navigates AND dismisses the drawer (drawer > selection), and a system
// back closes an open drawer instead of backgrounding the app.
//
// These drive the REAL shell (AxiotaskApp → AppShell → ListDetailScaffold) over
// static provider streams — no database — so the assertions are about what the
// user sees: the drawer's sidebar appearing and then going away after a tap.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter/material.dart';
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
}
