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
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/router.dart';
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

  testWidgets('window title reflects the initial view', (tester) async {
    final title = _FakeTitle();
    await pumpApp(tester, store: prefs(), title: title);
    // Default view is "all" (T2.1 prefs default) → "All Tasks — axiotask".
    expect(title.titles.last, 'All Tasks — axiotask');
  });

  testWidgets('a dev instance keeps its prefix in the window title', (
    tester,
  ) async {
    final title = _FakeTitle();
    await pumpApp(tester, store: prefs(), title: title, instancePrefix: 'dev');
    expect(title.titles.last, 'All Tasks — axiotask (dev)');
  });

  testWidgets('selecting a view persists it and retitles the window', (
    tester,
  ) async {
    final store = prefs();
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
}
