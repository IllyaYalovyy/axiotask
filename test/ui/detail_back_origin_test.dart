// Back from a SUBTASK panel returns to the parent panel it was opened from
// (#310).
//
// Opening a checklist row used to be a one-way door: the subtask's Back (and
// the phone's system back) dropped straight to the list, so a user checking one
// subtask after another had to re-open the parent every single time. The way
// back up was the breadcrumb — a different target, in a different corner, doing
// what Back should have done.
//
// What these tests protect: the panel a subtask was opened FROM is recorded in
// the URL (`?task=S&from=P`), so it survives a restore; Back with an origin
// re-opens that parent (exactly where the breadcrumb goes), and the NEXT back
// closes to the list. An open with no origin — a search jump onto a subtask, a
// restored URL naming a task that is gone — closes to the list as it always
// did. A sibling step keeps the origin it arrived with.
//
// Assertions are on what the panel RENDERS (whose title is in the field, which
// app-bar title is up, whether the list is back) and on the URL the router
// holds — never on which callback fired.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/window_title_controller.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import 'detail_harness.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_backorigin'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Bounded pumps against the test clock — the panel holds focusable text
  /// fields, so `pumpAndSettle` would never return, and the compact detail
  /// arrives with a container transform that keeps the surface pointer-inert
  /// while it runs.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  /// The real shell over a [FakeCommands], phone-sized (the compact layout, so
  /// the detail owns the screen and the list is only back when it closes).
  Future<GoRouter> pumpShell(
    WidgetTester tester, {
    required List<StoredTask> tasks,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = FakeCommands(List.of(tasks));
    addTearDown(fake.dispose);
    final store = PrefsStore(File(p.join(tmp.path, 'prefs.json')))
      ..save(const Prefs(onboardingSeen: true));
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
          listsProvider.overrideWith((ref) => Stream.value([list('L1', 'Ls')])),
          routerProvider.overrideWithValue(router),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await settle(tester);
    return router;
  }

  /// A parent with two open subtasks, in checklist order: one, two.
  List<StoredTask> family() => [
    row('P', 'Parent'),
    row('S1', 'one', parent: 'P', position: '000'),
    row('S2', 'two', parent: 'P', position: '001'),
  ];

  /// Which task's panel is open — the title the editable field holds.
  Finder openPanel(String title) => find.widgetWithText(TextField, title);

  Future<void> goTo(WidgetTester tester, GoRouter router, String url) async {
    router.go(url);
    await settle(tester);
  }

  /// The panel's own Back (the app bar's arrow — the desktop back arrow and the
  /// phone's, one widget).
  Future<void> tapBack(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Back'));
    await settle(tester);
  }

  /// Open the checklist row titled [title] from the parent's panel.
  Future<void> openSubtaskRow(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await settle(tester);
  }

  String location(GoRouter router) =>
      router.routerDelegate.currentConfiguration.uri.toString();

  testWidgets('a subtask opened from its parent goes Back to the parent, and '
      'the next Back to the list', (tester) async {
    final router = await pumpShell(tester, tasks: family());
    await goTo(tester, router, viewPath('all', taskId: 'P'));
    expect(openPanel('Parent'), findsOneWidget);

    await openSubtaskRow(tester, 'one');
    expect(openPanel('one'), findsOneWidget);
    expect(find.text('Subtask'), findsOneWidget);
    expect(
      location(router),
      contains('from=P'),
      reason: 'the origin lives in the URL, so a restore keeps it',
    );

    await tapBack(tester);

    expect(
      openPanel('Parent'),
      findsOneWidget,
      reason: 'Back walks the path that opened the subtask — up to its parent',
    );
    expect(find.text('Task Details'), findsOneWidget);
    expect(location(router), viewPath('all', taskId: 'P'));

    await tapBack(tester);

    expect(
      openPanel('Parent'),
      findsNothing,
      reason: 'the second Back closes the parent panel too',
    );
    expect(
      find.text('Parent'),
      findsOneWidget,
      reason: 'and the list is back, with the parent as a row',
    );
    expect(location(router), viewPath('all'));
  });

  testWidgets('the breadcrumb and Back are one path: both re-open the parent', (
    tester,
  ) async {
    final router = await pumpShell(tester, tasks: family());
    await goTo(tester, router, viewPath('all', taskId: 'P'));
    await openSubtaskRow(tester, 'one');

    // The breadcrumb names the parent; tapping it opens that panel.
    await tester.tap(find.text('Parent'));
    await settle(tester);
    expect(openPanel('Parent'), findsOneWidget);
    expect(
      location(router),
      viewPath('all', taskId: 'P'),
      reason: 'the breadcrumb lands exactly where Back does',
    );
  });

  testWidgets('a search jump onto a subtask has no origin: Back closes to the '
      'list', (tester) async {
    final router = await pumpShell(tester, tasks: family());
    // What a search hit (or any open that did not come from the parent panel)
    // navigates to: the subtask alone, no origin.
    await goTo(tester, router, viewPath('all', taskId: 'S1'));
    expect(openPanel('one'), findsOneWidget);

    await tapBack(tester);

    expect(openPanel('one'), findsNothing);
    expect(
      find.text('Parent'),
      findsOneWidget,
      reason: 'no origin means the list, exactly as before #310',
    );
    expect(location(router), viewPath('all'));
  });

  testWidgets('a restored URL carrying an origin still goes Back to the '
      'parent', (tester) async {
    final router = await pumpShell(tester, tasks: family());
    // The shape a restored route arrives in — parsed from the URL, with no
    // navigation having happened in this session.
    await goTo(tester, router, '/view/all?task=S1&from=P');
    expect(openPanel('one'), findsOneWidget);

    await tapBack(tester);

    expect(openPanel('Parent'), findsOneWidget);
    expect(location(router), viewPath('all', taskId: 'P'));
  });

  testWidgets('an origin that no longer exists falls back to the list', (
    tester,
  ) async {
    final router = await pumpShell(tester, tasks: family());
    // A restored URL naming a parent that has since been deleted: Back must not
    // navigate to a panel that would render "task not found".
    await goTo(tester, router, '/view/all?task=S1&from=GONE');
    expect(openPanel('one'), findsOneWidget);

    await tapBack(tester);

    expect(location(router), viewPath('all'));
    expect(
      find.text('Parent'),
      findsOneWidget,
      reason: 'the list, not a panel for a task that is gone',
    );
  });

  testWidgets('stepping to a sibling keeps the origin', (tester) async {
    final router = await pumpShell(tester, tasks: family());
    await goTo(tester, router, viewPath('all', taskId: 'P'));
    await openSubtaskRow(tester, 'one');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
    await settle(tester);
    expect(openPanel('two'), findsOneWidget);
    expect(location(router), contains('from=P'));

    await tapBack(tester);

    expect(
      openPanel('Parent'),
      findsOneWidget,
      reason: 'a step along the checklist stays inside the same path back',
    );
  });
}
