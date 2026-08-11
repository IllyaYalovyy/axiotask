// Protects the shell's cross-cutting wiring end to end: the desktop window title
// tracks the active view (and keeps a dev prefix), selecting a view persists it
// to prefs.json, and the detail route opens/closes with a visible back
// affordance. These are the T2.2 contracts a user (or a restart) can observe.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/window_title_controller.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:axiotask/src/ui/router.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

/// Records every title the shell sets, so tests assert the actual native-window
/// contract instead of a method-was-called stub.
class _FakeTitle implements WindowTitleController {
  final List<String> titles = [];

  @override
  Future<void> setTitle(String title) async => titles.add(title);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_shell_test'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  PrefsStore prefs() => PrefsStore(File(p.join(tmp.path, 'prefs.json')));

  // A prefs store with the first-launch onboarding already dismissed — for the
  // shell tests that exercise a normal (not first-launch) empty workspace and
  // would otherwise sit behind the welcome overlay.
  PrefsStore seenPrefs() => prefs()..save(const Prefs(onboardingSeen: true));

  Future<void> pumpApp(
    WidgetTester tester, {
    required PrefsStore store,
    required _FakeTitle title,
    String? instancePrefix,
    GoRouter? router,
    List<StoredTask> tasks = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(store.load()),
          prefsStoreProvider.overrideWithValue(store),
          instancePrefixProvider.overrideWithValue(instancePrefix),
          windowTitleControllerProvider.overrideWithValue(title),
          // The "all" view (and the detail panel) render off the real store
          // streams; feed them fixed values so the shell wiring under test needs
          // no database.
          allTasksProvider.overrideWith((ref) => Stream.value(tasks)),
          listsProvider.overrideWith((ref) => const Stream.empty()),
          if (router != null) routerProvider.overrideWithValue(router),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  StoredTask storedTask(String id, String title) => StoredTask(
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

  Future<void> pumpAppWithLists(
    WidgetTester tester, {
    required PrefsStore store,
    required _FakeTitle title,
    required List<StoredTaskList> lists,
    List<StoredTask> tasks = const [],
    GoRouter? router,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(store.load()),
          prefsStoreProvider.overrideWithValue(store),
          windowTitleControllerProvider.overrideWithValue(title),
          allTasksProvider.overrideWith((ref) => Stream.value(tasks)),
          listsProvider.overrideWith((ref) => Stream.value(lists)),
          if (router != null) routerProvider.overrideWithValue(router),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  StoredTaskList storedList(String id, String title) => StoredTaskList(
    list: TaskList(id: id, title: title, etag: 'e', updated: 't'),
    syncState: SyncState.clean,
    localUpdated: 't',
  );

  testWidgets('window title reflects the initial view', (tester) async {
    final title = _FakeTitle();
    await pumpApp(tester, store: seenPrefs(), title: title);
    // Default view is "all" (T2.1 prefs default) → "All Tasks — axiotask".
    expect(title.titles.last, 'All Tasks — axiotask');
  });

  testWidgets('a dev instance keeps its prefix in the window title', (
    tester,
  ) async {
    final title = _FakeTitle();
    await pumpApp(
      tester,
      store: seenPrefs(),
      title: title,
      instancePrefix: 'dev',
    );
    expect(title.titles.last, 'All Tasks — axiotask (dev)');
  });

  testWidgets('selecting a view persists it and retitles the window', (
    tester,
  ) async {
    final store = seenPrefs();
    final title = _FakeTitle();
    await pumpApp(tester, store: store, title: title);

    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();

    // Persisted (survives restart, localStorage parity) …
    expect(store.load().view, 'focus');
    // … and the live window title followed the view.
    expect(title.titles.last, 'Focus — axiotask');
  });

  testWidgets('a task route opens the detail; the back button closes it', (
    tester,
  ) async {
    final store = prefs();
    final title = _FakeTitle();
    final router = buildAppRouter(initialViewId: 'all');
    await pumpApp(
      tester,
      store: store,
      title: title,
      router: router,
      tasks: [storedTask('T1', 'my task')],
    );

    router.go(viewPath('all', taskId: 'T1'));
    await tester.pumpAndSettle();
    // The detail panel renders the task's real fields (Title label + value).
    expect(find.widgetWithText(TextField, 'my task'), findsOneWidget);

    // The visible back affordance (touch path — no system back on desktop).
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'my task'), findsNothing);
  });

  testWidgets('a list renders in the sidebar with its open-task count', (
    tester,
  ) async {
    await pumpAppWithLists(
      tester,
      store: prefs(),
      title: _FakeTitle(),
      lists: [storedList('L1', 'Work')],
      tasks: [storedTask('T1', 'a'), storedTask('T2', 'b')],
    );
    // Scoped to the sidebar: the default 'all' view now also tags each row with
    // its list name (F18 cross-list tag), so an unscoped find.text('Work') would
    // match the row tags too. The assertion here is about the sidebar entry.
    expect(
      find.descendant(of: find.byType(Sidebar), matching: find.text('Work')),
      findsOneWidget,
    );
    // Two open top-level tasks in the list → a "2" badge (All Tasks + the list).
    expect(find.text('2'), findsWidgets);
  });

  testWidgets('selecting a list navigates, persists it, and retitles', (
    tester,
  ) async {
    final store = seenPrefs();
    final title = _FakeTitle();
    await pumpAppWithLists(
      tester,
      store: store,
      title: title,
      lists: [storedList('L1', 'Work')],
    );

    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();

    // The window title resolves the LIST id to its title (WindowTitle contract).
    expect(title.titles.last, 'Work — axiotask');
    // Persisted as the last view (survives restart).
    expect(store.load().view, 'L1');
  });

  testWidgets('Android system back closes an open detail on a phone', (
    tester,
  ) async {
    // Compact form factor so the PopScope back path is the one under test.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = prefs();
    final title = _FakeTitle();
    final router = buildAppRouter(initialViewId: 'all');
    await pumpApp(
      tester,
      store: store,
      title: title,
      router: router,
      tasks: [storedTask('T1', 'my task')],
    );

    router.go(viewPath('all', taskId: 'T1'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'my task'), findsOneWidget);

    // The system/OS back button, routed through go_router + the shell PopScope.
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      handled,
      isTrue,
      reason: 'back must not fall through to exit the app',
    );
    expect(find.widgetWithText(TextField, 'my task'), findsNothing);
  });

  // The Android system-back precedence ladder (T8.3): one back is one ladder
  // step. On top of the framework's own back handling for routes (dialogs,
  // search, pickers) and the slide-in drawer, the app-owned steps are, in
  // order: dismiss the first-launch welcome → close an open detail → clear an
  // active selection → (nothing left) let the OS exit. Every case is driven at
  // the real shell through go_router + the system back button.
  group('Android back-precedence ladder (T8.3)', () {
    Future<void> pumpPhone(
      WidgetTester tester, {
      required PrefsStore store,
      required GoRouter router,
      List<StoredTask> tasks = const [],
    }) async {
      // Compact form factor — the phone chrome where the ladder is the primary
      // navigation (no side-by-side detail, no persistent sidebar).
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpApp(
        tester,
        store: store,
        title: _FakeTitle(),
        router: router,
        tasks: tasks,
      );
    }

    testWidgets('back with an active selection (no detail) clears it', (
      tester,
    ) async {
      final router = buildAppRouter(initialViewId: 'all');
      await pumpPhone(
        tester,
        store: seenPrefs(),
        router: router,
        tasks: [storedTask('T1', 'my task')],
      );

      // Long-press selects the row (the mobile multi-select gesture).
      await tester.longPress(find.text('my task'));
      await tester.pumpAndSettle();
      expect(find.byType(BulkBar), findsOneWidget);

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        handled,
        isTrue,
        reason: 'back is consumed to clear the selection, not to exit the app',
      );
      expect(find.byType(BulkBar), findsNothing);
      // The detail never opened — back did not over-reach into a navigation.
      expect(find.widgetWithText(TextField, 'my task'), findsNothing);
    });

    testWidgets(
      'back closes the detail FIRST, then a second back clears the selection',
      (tester) async {
        final router = buildAppRouter(initialViewId: 'all');
        await pumpPhone(
          tester,
          store: seenPrefs(),
          router: router,
          tasks: [storedTask('T1', 'my task')],
        );

        // A selection is active …
        await tester.longPress(find.text('my task'));
        await tester.pumpAndSettle();
        expect(find.byType(BulkBar), findsOneWidget);

        // … and a detail opens while the selection persists (the reachable
        // case: searching from a selection lands on a task in the same view).
        router.go(viewPath('all', taskId: 'T1'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'my task'), findsOneWidget);

        // First back: the detail closes; the selection survives (one step).
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'my task'), findsNothing);
        expect(
          find.byType(BulkBar),
          findsOneWidget,
          reason: 'the selection outlives the detach — one back is one step',
        );

        // Second back: now the selection clears.
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expect(find.byType(BulkBar), findsNothing);
      },
    );

    testWidgets(
      'back closes an open drawer FIRST, leaving a selection behind it intact',
      (tester) async {
        // F14 (#192): the drawer is the framework's own back rung. When it sits
        // OVER an active selection, one back must close only the drawer — it
        // must not ALSO clear the selection hidden behind it.
        final router = buildAppRouter(initialViewId: 'all');
        await pumpPhone(
          tester,
          store: seenPrefs(),
          router: router,
          tasks: [storedTask('T1', 'my task')],
        );

        // A selection is active …
        await tester.longPress(find.text('my task'));
        await tester.pumpAndSettle();
        expect(find.byType(BulkBar), findsOneWidget);

        // … and the user opens the drawer over it.
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        final drawerSidebar = find.byKey(
          const Key('sidebar-lists-reorderable'),
        );
        expect(drawerSidebar, findsOneWidget);

        // First back: only the drawer closes; the selection survives.
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expect(drawerSidebar, findsNothing, reason: 'the drawer closed first');
        expect(
          find.byType(BulkBar),
          findsOneWidget,
          reason:
              'the back that closes the drawer must not clear a selection '
              'sitting behind it — one back is one rung',
        );

        // Second back: now (drawer gone) the selection clears.
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expect(find.byType(BulkBar), findsNothing);
      },
    );

    testWidgets('back on the first-launch welcome dismisses it (persisted)', (
      tester,
    ) async {
      final store = prefs();
      final router = buildAppRouter(initialViewId: 'all');
      // Empty, never-seen workspace → the welcome overlay sits on top.
      await pumpPhone(tester, store: store, router: router);
      expect(find.byKey(const Key('onboarding-intro')), findsOneWidget);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding-intro')), findsNothing);
      expect(
        store.load().onboardingSeen,
        isTrue,
        reason: 'a back dismissal persists like a tap dismissal',
      );
    });

    testWidgets('back with nothing active falls through to exit the app', (
      tester,
    ) async {
      final router = buildAppRouter(initialViewId: 'all');
      await pumpPhone(
        tester,
        store: seenPrefs(),
        router: router,
        tasks: [storedTask('T1', 'my task')],
      );
      // No welcome, no detail, no selection.
      expect(find.byType(BulkBar), findsNothing);
      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        handled,
        isFalse,
        reason: 'no app-owned mode to intercept → the OS pops the app',
      );
    });
  });

  group('first-launch onboarding', () {
    testWidgets('shows the welcome once on an empty, never-seen workspace', (
      tester,
    ) async {
      await pumpApp(tester, store: prefs(), title: _FakeTitle());
      expect(find.byKey(const Key('onboarding-intro')), findsOneWidget);
      expect(find.text('Welcome to axiotask'), findsOneWidget);
    });

    testWidgets('does not show when the workspace already has tasks', (
      tester,
    ) async {
      await pumpApp(
        tester,
        store: prefs(),
        title: _FakeTitle(),
        tasks: [storedTask('T1', 'existing')],
      );
      expect(find.byKey(const Key('onboarding-intro')), findsNothing);
    });

    testWidgets('does not show once it has been seen', (tester) async {
      await pumpApp(tester, store: seenPrefs(), title: _FakeTitle());
      expect(find.byKey(const Key('onboarding-intro')), findsNothing);
    });

    testWidgets('dismissing it persists onboardingSeen and hides it', (
      tester,
    ) async {
      final store = prefs();
      await pumpApp(tester, store: store, title: _FakeTitle());
      expect(find.byKey(const Key('onboarding-intro')), findsOneWidget);

      await tester.tap(find.byKey(const Key('onboarding-dismiss')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('onboarding-intro')), findsNothing);
      expect(
        store.load().onboardingSeen,
        isTrue,
        reason: 'the welcome never returns after dismissal',
      );
    });
  });
}
