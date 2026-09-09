// The detail panel's Prev/Next for a SUBTASK (#303).
//
// A subtask has no place in the list's ordering — the list renders top-level
// rows only (invariant #1) — so the shell used to leave both chevrons dead the
// moment a checklist row was opened, stranding the user: the only way to the
// next subtask was back out to the parent and in again.
//
// What these tests protect: a subtask's Prev/Next walk the PARENT'S CHECKLIST
// in the order that checklist is shown — `position` ascending (newest first
// since #302), with completed siblings skipped exactly while "Hide completed"
// hides them — disabled at the two ends, and top-level navigation untouched.
//
// Assertions are on what the panel RENDERS after the step (which task's title
// is in the field, whose breadcrumb is above it) and on whether the app bar's
// buttons are live — never on which callback fired.

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
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_sibnav'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Let the shell's open/step motion land: the compact detail arrives with a
  /// container transform, and while it runs the surface is pointer-inert — a
  /// chevron tapped mid-flight lands on nothing. Bounded pumps against the test
  /// clock, never pumpAndSettle (the panel holds text fields).
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  /// The real shell over a [FakeCommands], with the welcome already dismissed
  /// and [hideCompletedSubtasks] as the caller wants it.
  Future<GoRouter> pumpShell(
    WidgetTester tester, {
    required List<StoredTask> tasks,
    bool hideCompletedSubtasks = false,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = FakeCommands(List.of(tasks));
    addTearDown(fake.dispose);
    final store = PrefsStore(File(p.join(tmp.path, 'prefs.json')))
      ..save(
        Prefs(
          onboardingSeen: true,
          hideCompletedSubtasks: hideCompletedSubtasks,
        ),
      );
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

  Future<void> open(WidgetTester tester, GoRouter router, String id) async {
    router.go(viewPath('all', taskId: id));
    await settle(tester);
  }

  bool enabled(WidgetTester tester, IconData icon) =>
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, icon))
          .onPressed !=
      null;

  bool prevEnabled(WidgetTester t) => enabled(t, Icons.chevron_left);
  bool nextEnabled(WidgetTester t) => enabled(t, Icons.chevron_right);

  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
    await settle(tester);
  }

  Future<void> tapPrev(WidgetTester tester) async {
    await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_left));
    await settle(tester);
  }

  /// Which task's panel is open — the title the editable field holds.
  Finder openPanel(String title) => find.widgetWithText(TextField, title);

  // A parent with three open subtasks, in checklist order: one, two, three.
  List<StoredTask> family() => [
    row('P', 'Parent'),
    row('S1', 'one', parent: 'P', position: '000'),
    row('S2', 'two', parent: 'P', position: '001'),
    row('S3', 'three', parent: 'P', position: '002'),
  ];

  group('a subtask steps through its parent checklist', () {
    testWidgets('Next walks down the checklist, Previous back up', (
      tester,
    ) async {
      final router = await pumpShell(tester, tasks: family());
      await open(tester, router, 'S2');
      expect(openPanel('two'), findsOneWidget);

      await tapNext(tester);
      expect(openPanel('three'), findsOneWidget);
      expect(
        find.text('Parent'),
        findsOneWidget,
        reason: 'still inside the same checklist — the breadcrumb says so',
      );

      await tapPrev(tester);
      expect(openPanel('two'), findsOneWidget);
      await tapPrev(tester);
      expect(openPanel('one'), findsOneWidget);
    });

    testWidgets('the two ends are disabled, the middle is not', (tester) async {
      final router = await pumpShell(tester, tasks: family());

      await open(tester, router, 'S1');
      expect(prevEnabled(tester), isFalse);
      expect(nextEnabled(tester), isTrue);

      await open(tester, router, 'S2');
      expect(prevEnabled(tester), isTrue);
      expect(nextEnabled(tester), isTrue);

      await open(tester, router, 'S3');
      expect(prevEnabled(tester), isTrue);
      expect(nextEnabled(tester), isFalse);
    });

    testWidgets('an only child has neither direction', (tester) async {
      final router = await pumpShell(
        tester,
        tasks: [
          row('P', 'Parent'),
          row('S1', 'one', parent: 'P'),
        ],
      );
      await open(tester, router, 'S1');
      expect(prevEnabled(tester), isFalse);
      expect(nextEnabled(tester), isFalse);
    });
  });

  group('Hide completed subtasks', () {
    testWidgets('a hidden completed sibling is stepped OVER, not into', (
      tester,
    ) async {
      final router = await pumpShell(
        tester,
        hideCompletedSubtasks: true,
        tasks: [
          row('P', 'Parent'),
          row('S1', 'one', parent: 'P', position: '000'),
          row('S2', 'two', parent: 'P', position: '001', done: true),
          row('S3', 'three', parent: 'P', position: '002'),
        ],
      );
      await open(tester, router, 'S1');
      await tapNext(tester);
      expect(
        openPanel('three'),
        findsOneWidget,
        reason:
            'the checklist does not show "two", so the walk does not visit it',
      );
      expect(nextEnabled(tester), isFalse, reason: 'and that is the last one');
    });

    testWidgets('with the completed group open, the walk ends on it', (
      tester,
    ) async {
      // #306 gathers the completed subtasks at the BOTTOM of the checklist,
      // under the "N completed" group — so the walk follows the open ones
      // first and reaches the finished one last. The rule is unchanged: the
      // step goes where the checklist SHOWS the row, and it now shows it
      // there.
      final router = await pumpShell(
        tester,
        tasks: [
          row('P', 'Parent'),
          row('S1', 'one', parent: 'P', position: '000'),
          row('S2', 'two', parent: 'P', position: '001', done: true),
          row('S3', 'three', parent: 'P', position: '002'),
        ],
      );
      await open(tester, router, 'S1');
      await tapNext(tester);
      expect(openPanel('three'), findsOneWidget);
      await tapNext(tester);
      expect(openPanel('two'), findsOneWidget);
      expect(nextEnabled(tester), isFalse, reason: 'the finished one is last');
    });

    testWidgets('a subtask the checklist hides has no step at all', (
      tester,
    ) async {
      // The completed one's own panel, opened while "Hide completed" is on (a
      // restored URL, or the toggle flipped with it open): it is not in the
      // shown ordering, so — exactly like a filtered-out top-level task — it
      // has no neighbours to step to.
      final router = await pumpShell(
        tester,
        hideCompletedSubtasks: true,
        tasks: [
          row('P', 'Parent'),
          row('S1', 'one', parent: 'P', position: '000'),
          row('S2', 'two', parent: 'P', position: '001', done: true),
          row('S3', 'three', parent: 'P', position: '002'),
        ],
      );
      await open(tester, router, 'S2');
      expect(openPanel('two'), findsOneWidget);
      expect(prevEnabled(tester), isFalse);
      expect(nextEnabled(tester), isFalse);
    });
  });

  group('top-level navigation is unchanged', () {
    testWidgets('Next still walks the view ordering, past the subtasks', (
      tester,
    ) async {
      final router = await pumpShell(
        tester,
        tasks: [
          row('A', 'alpha', position: '000'),
          row('S1', 'one', parent: 'A', position: '000'),
          row('B', 'beta', position: '001'),
        ],
      );
      await open(tester, router, 'A');
      expect(prevEnabled(tester), isFalse);
      await tapNext(tester);
      expect(
        openPanel('beta'),
        findsOneWidget,
        reason: 'top-level steps skip subtasks, which are not list rows',
      );
      expect(nextEnabled(tester), isFalse);
    });
  });
}
