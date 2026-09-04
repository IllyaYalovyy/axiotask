// Edit-loss protection (F10 / #183). Drives the REAL app shell over a
// FakeCommands and asserts what the fake HOLDS after the two edit-losing paths:
//   • the Android system back that closes an open detail (a go_router pop via
//     the shell's PopScope, which never runs the panel's own flush-on-close),
//     and
//   • the app being backgrounded (paused/hidden), where the OS may kill the
//     process before any blur fires.
// Plus the debounced save-on-change (a focused field left mid-edit persists
// without a blur) and the quick-add draft committed on background.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/window_title_controller.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/router.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import 'detail_harness.dart';

void main() {
  late Directory tmp;
  setUp(() {
    debugDefaultTargetPlatformOverride = null;
    tmp = Directory.systemTemp.createTempSync('axiotask_flush_test');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // A prefs store with onboarding already dismissed — otherwise the welcome
  // overlay sits over the shell on an empty/first-launch workspace.
  PrefsStore seenPrefs() =>
      PrefsStore(File(p.join(tmp.path, 'prefs.json')))
        ..save(const Prefs(onboardingSeen: true));

  Future<(FakeCommands, GoRouter)> pumpShell(
    WidgetTester tester, {
    required List<StoredTask> initialTasks,
    List<StoredTaskList> initialLists = const [],
    TargetPlatform? platform,
  }) async {
    // Compact form factor — the phone chrome where the system-back path is the
    // one that closes a full-screen detail.
    // NOT an addTearDown: flutter_test asserts every foundation debug var is
    // unset at the END OF THE BODY, before tear-downs run — so each test that
    // pins a platform clears it itself, and the setUp above catches a leak from
    // a body that failed early.
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = FakeCommands(List.of(initialTasks));
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
          listsProvider.overrideWith((ref) => Stream.value(initialLists)),
          routerProvider.overrideWithValue(router),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
    return (fake, router);
  }

  // A realistic backgrounding walk (resumed → inactive → hidden → paused), so
  // the AppLifecycleListener sees a legal transition and fires for paused/hidden.
  Future<void> background(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
  }

  testWidgets('system back with dirty notes persists them (#183)', (
    tester,
  ) async {
    final (fake, router) = await pumpShell(
      tester,
      initialTasks: [row('T1', 'my task')],
      initialLists: [list('L1', 'My Tasks')],
    );

    router.go(viewPath('all', taskId: 'T1'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'my task'), findsOneWidget);

    // Type into Notes but do NOT blur — then press the Android system back.
    await tester.enterText(
      find.widgetWithText(TextField, 'Notes'),
      'draft notes',
    );
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handled, isTrue, reason: 'back closed the detail, did not exit');
    // The detail closed …
    expect(find.widgetWithText(TextField, 'my task'), findsNothing);
    // … and the in-progress edit was persisted, not lost.
    expect(
      fake.tasks.firstWhere((t) => t.task.id == 'T1').task.notes,
      'draft notes',
    );
  });

  testWidgets('lifecycle-paused with a dirty title persists it (#183)', (
    tester,
  ) async {
    final (fake, router) = await pumpShell(
      tester,
      initialTasks: [row('T1', 'my task')],
      initialLists: [list('L1', 'My Tasks')],
    );

    router.go(viewPath('all', taskId: 'T1'));
    await tester.pumpAndSettle();

    // Type into Title but do NOT blur — then background the app.
    await tester.enterText(
      find.widgetWithText(TextField, 'my task'),
      'renamed task',
    );
    await background(tester);

    // The edit survived the trip to the background (no lost keystrokes on a
    // process the OS may kill while paused).
    expect(
      fake.tasks.firstWhere((t) => t.task.id == 'T1').task.title,
      'renamed task',
    );
  });

  testWidgets('a focused field saves on a debounce, without a blur (#183)', (
    tester,
  ) async {
    final (fake, router) = await pumpShell(
      tester,
      initialTasks: [row('T1', 'my task', notes: 'old')],
      initialLists: [list('L1', 'My Tasks')],
    );

    router.go(viewPath('all', taskId: 'T1'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'old'), 'typed');
    // No blur, no navigation — just wait out the debounce.
    await tester.pump(const Duration(seconds: 1));

    expect(
      fake.tasks.firstWhere((t) => t.task.id == 'T1').task.notes,
      'typed',
      reason: 'the edit is not left minutes-unsaved waiting for a blur',
    );
  });

  // Open a row's inline-rename editor the way a MOUSE does — a double-click on
  // the title (F19 #198). Since #245 removed the per-row "⋮" sheet this is the
  // only entry to the inline editor: a finger renames in the detail panel
  // instead (covered by the notes/title cases above), so the two rename-flush
  // cases below pin a narrow DESKTOP window, where both a lifecycle pause and a
  // back that closes the app can still strand a mid-typing edit.
  Future<void> startInlineRename(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'system back mid inline-rename persists the new title (G4 #183)',
    (tester) async {
      final (fake, _) = await pumpShell(
        tester,
        initialTasks: [row('T1', 'old title')],
        initialLists: [list('L1', 'My Tasks')],
        platform: TargetPlatform.linux,
      );

      await startInlineRename(tester, 'old title');
      // The inline editor is mounted, seeded with the current title.
      expect(find.widgetWithText(TextField, 'old title'), findsOneWidget);

      // Type a new title but do NOT blur/submit — then press the system back.
      await tester.enterText(
        find.widgetWithText(TextField, 'old title'),
        'new title',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // The mid-typing rename survived the back that no blur would have caught.
      expect(
        fake.tasks.firstWhere((t) => t.task.id == 'T1').task.title,
        'new title',
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('lifecycle-paused mid inline-rename persists it (G4 #183)', (
    tester,
  ) async {
    final (fake, _) = await pumpShell(
      tester,
      initialTasks: [row('T1', 'old title')],
      initialLists: [list('L1', 'My Tasks')],
      platform: TargetPlatform.linux,
    );

    await startInlineRename(tester, 'old title');
    expect(find.widgetWithText(TextField, 'old title'), findsOneWidget);

    // Type into the inline editor but do NOT blur — then background the app.
    await tester.enterText(
      find.widgetWithText(TextField, 'old title'),
      'renamed inline',
    );
    await background(tester);

    expect(
      fake.tasks.firstWhere((t) => t.task.id == 'T1').task.title,
      'renamed inline',
      reason: 'a mid-typing rename is not lost to a process the OS may kill',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('system back from a blank subtask discards it (G4 #183)', (
    tester,
  ) async {
    final (fake, router) = await pumpShell(
      tester,
      initialTasks: [
        row('P', 'Parent'),
        row('S', '', parent: 'P'),
      ],
      initialLists: [list('L1', 'My Tasks')],
    );

    // Open the blank subtask's panel, then press the system back (which never
    // runs the panel's own flush-on-close funnel).
    router.go(viewPath('all', taskId: 'S'));
    await tester.pumpAndSettle();
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handled, isTrue, reason: 'back closed the detail, did not exit');
    // The abandoned blank subtask was discarded, exactly as on the Back button.
    expect(fake.deleted.map((t) => t.id), contains('S'));
    expect(fake.tasks.any((t) => t.task.id == 'S'), isFalse);
  });

  testWidgets(
    'a quick-add draft is committed when the app backgrounds (#183)',
    (tester) async {
      final (fake, _) = await pumpShell(
        tester,
        initialTasks: [row('T1', 'existing')],
        initialLists: [list('L1', 'My Tasks')],
      );

      // On touch (the shell's default test platform) creation goes through the
      // FAB's bottom-sheet composer (#216): open it, type a draft, but never
      // submit.
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Add a task'),
        'buy milk',
      );
      await background(tester);

      // The drafted task was created rather than lost to the killed process.
      expect(
        fake.tasks.where((t) => t.task.title == 'buy milk'),
        isNotEmpty,
        reason: 'a non-empty quick-add draft commits on background',
      );
    },
  );
}
