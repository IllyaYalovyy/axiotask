// The landscape/expanded sidebar (#235). On a phone in landscape the shell is
// past the 600dp breakpoint, so the permanent sidebar replaces the drawer — and
// with it the ONLY way to reach All Tasks and the user's lists. A pinned
// auth/sync footer that eats half a 360dp-tall viewport silently cut the
// navigation off mid-list: the four first smart views showed, All Tasks and the
// whole Lists section did not, and a swipe over the (unscrollable) footer moved
// nothing.
//
// These drive the REAL shell (AxiotaskApp → AppShell → ListDetailScaffold →
// Sidebar) with the REAL auth/sync footer mounted, over static provider streams
// — no database. Every assertion is about what a finger can actually reach:
// hit-testable at the size, and tapping it navigates.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/auth/auth_sync_footer.dart';
import 'package:axiotask/src/ui/auth/auth_sync_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A landscape phone past the expand breakpoint (the reported Pixel geometry,
/// rounded to the size named in #235).
const _landscape = Size(800, 360);

/// The same phone in portrait — the compact/drawer layout.
const _portrait = Size(400, 800);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_landscape'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  StoredTask task(String id, String title, String listId) => StoredTask(
    task: Task(
      id: id,
      position: '1',
      title: title,
      status: TaskStatus.needsAction,
      updated: 't',
    ),
    listId: listId,
    syncState: SyncState.clean,
    localUpdated: 't',
  );

  StoredTaskList list(String id, String title) => StoredTaskList(
    list: TaskList(id: id, title: title, etag: 'e', updated: 't'),
    syncState: SyncState.clean,
    localUpdated: 't',
  );

  /// The shell as it runs on device: onboarding dismissed, a signed-in
  /// auth/sync footer mounted in the sidebar (the surface that was stealing the
  /// viewport), and whatever [view] the user had open.
  Future<PrefsStore> pumpShell(
    WidgetTester tester, {
    Size size = _landscape,
    List<StoredTaskList> lists = const [],
    List<StoredTask> tasks = const [],
    String view = 'focus',
    double textScaleFactor = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final store = PrefsStore(File(p.join(tmp.path, 'prefs.json')))
      ..save(Prefs(onboardingSeen: true, view: view));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(store.load()),
          prefsStoreProvider.overrideWithValue(store),
          allTasksProvider.overrideWith((ref) => Stream.value(tasks)),
          listsProvider.overrideWith((ref) => Stream.value(lists)),
          sidebarFooterProvider.overrideWithValue(
            AuthSyncFooter(
              status: const AuthSyncStatus(
                isAuthenticated: true,
                needsReauth: false,
              ),
              onSignIn: () {},
              onSignOut: () {},
              onSync: () {},
              onOpenProperties: () {},
            ),
          ),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  final sidebar = find.byKey(const Key('expanded-sidebar'));

  /// The named text INSIDE the permanent sidebar, restricted to what a finger
  /// can actually hit — anything scrolled past the fold or buried under the
  /// pinned footer fails this finder even though it is still in the tree.
  Finder reachable(String label) =>
      find.descendant(of: sidebar, matching: find.text(label)).hitTestable();

  /// Scroll the sidebar itself (not the task list beside it) by [dy].
  Future<void> scrollSidebar(WidgetTester tester, double dy) async {
    await tester.drag(
      find.descendant(of: sidebar, matching: find.byType(Scrollable)).first,
      Offset(0, dy),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
  }

  group('landscape phone (#235)', () {
    testWidgets(
      'the expanded sidebar reaches every smart view AND the lists at rest',
      (tester) async {
        final store = await pumpShell(
          tester,
          lists: [list('L1', 'E2E-Test')],
          tasks: [task('T1', 'Buy milk', 'L1')],
        );

        // The landscape layout is the expanded one — no hamburger to fall back
        // on, so the sidebar is the ONLY navigation surface.
        expect(sidebar, findsOneWidget);
        expect(find.byTooltip('Open navigation menu'), findsNothing);

        // Every destination the portrait drawer offers is here and touchable.
        for (final label in [
          'Focus',
          'Upcoming',
          'Missed',
          'Unscheduled',
          'All Tasks',
          'Lists',
          'E2E-Test',
        ]) {
          expect(
            reachable(label),
            findsOneWidget,
            reason: '"$label" must be reachable in the landscape sidebar',
          );
        }
        expect(
          find
              .descendant(
                of: sidebar,
                matching: find.byKey(const Key('sidebar-add-list')),
              )
              .hitTestable(),
          findsOneWidget,
          reason: 'the add-list affordance must not be dropped either',
        );

        // …and they are real destinations: tapping the list navigates to it.
        await tester.tap(reachable('E2E-Test'));
        await tester.pumpAndSettle();
        expect(store.load().view, 'L1');
        expect(find.text('Buy milk'), findsOneWidget);
      },
    );

    testWidgets(
      'at a 1.3 system text scale nothing is dropped — All Tasks stays at rest '
      'and the footer is still reachable by scrolling',
      (tester) async {
        // The non-happy path: a larger system font inflates the footer, which is
        // exactly what squeezed the navigation off the screen.
        await pumpShell(
          tester,
          lists: [list('L1', 'E2E-Test')],
          tasks: [task('T1', 'Buy milk', 'L1')],
          textScaleFactor: 1.3,
        );

        expect(
          reachable('All Tasks'),
          findsOneWidget,
          reason: 'the fifth smart view must survive a 1.3 text scale',
        );

        // The footer/chrome may scroll out of view when space is this tight —
        // but they must be reachable, not lost.
        await scrollSidebar(tester, -400);
        expect(reachable('E2E-Test'), findsOneWidget);
        expect(reachable('Sync now'), findsOneWidget);
        expect(reachable('Properties'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a swipe that starts on the footer scrolls the sidebar too', (
      tester,
    ) async {
      // The literal on-device complaint: "the sidebar does not scroll (swipe
      // inside it moves nothing)". Over half of a landscape sidebar WAS the
      // pinned footer, so most swipes landed on dead surface.
      await pumpShell(
        tester,
        lists: [for (var i = 1; i <= 6; i++) list('L$i', 'List $i')],
        tasks: [task('T1', 'Buy milk', 'L1')],
      );

      // Scroll to the far end, where the footer is.
      await scrollSidebar(tester, -600);
      expect(reachable('List 6'), findsOneWidget, reason: 'the last list');
      expect(reachable('Sync now'), findsOneWidget);
      expect(reachable('Focus'), findsNothing, reason: 'scrolled off the top');

      // Now swipe back DOWN starting on the footer's own Sync button.
      await tester.drag(reachable('Sync now'), const Offset(0, 600));
      await tester.pumpAndSettle();

      expect(
        reachable('Focus'),
        findsOneWidget,
        reason: 'a swipe on the footer must move the sidebar, not nothing',
      );
    });

    testWidgets('rotating with a list open keeps it open and selected', (
      tester,
    ) async {
      final store = await pumpShell(
        tester,
        size: _portrait,
        lists: [list('L1', 'E2E-Test')],
        tasks: [task('T1', 'Buy milk', 'L1')],
        view: 'L1',
      );
      // Portrait: the compact layout, the list open behind the drawer.
      expect(sidebar, findsNothing);
      expect(find.text('Buy milk'), findsOneWidget);

      tester.view.physicalSize = _landscape;
      await tester.pumpAndSettle();

      // The open list survived the rotation …
      expect(store.load().view, 'L1');
      expect(find.text('Buy milk'), findsOneWidget);
      // … and its sidebar row is reachable and shows as the selected one.
      expect(reachable('E2E-Test'), findsOneWidget);
      // Every Material over the row's label — the row's own coloured one, and
      // the transparent one the row's state layer paints its ink on (#259).
      final rowColors = tester
          .widgetList<Material>(
            find.ancestor(
              of: find.descendant(of: sidebar, matching: find.text('E2E-Test')),
              matching: find.byType(Material),
            ),
          )
          .map((m) => m.color)
          .toList();
      final selected = Theme.of(
        tester.element(find.byType(Scaffold).first),
      ).colorScheme.secondaryContainer;
      expect(
        rowColors,
        contains(selected),
        reason: 'the open list must render as the selected sidebar row',
      );
    });
  });

  testWidgets(
    'on a tall desktop window the footer stays pinned at the bottom',
    (tester) async {
      // The landscape fix must not un-pin the footer where there IS room: on a
      // desktop window Sync/Properties stay put at the foot of the sidebar.
      await pumpShell(
        tester,
        size: const Size(1200, 900),
        lists: [list('L1', 'E2E-Test')],
        tasks: [task('T1', 'Buy milk', 'L1')],
      );

      final sidebarBottom = tester.getRect(sidebar).bottom;
      final propertiesBottom = tester
          .getRect(
            find.descendant(
              of: sidebar,
              matching: find.byKey(const Key('open-properties')),
            ),
          )
          .bottom;
      expect(
        propertiesBottom,
        closeTo(sidebarBottom, 12),
        reason:
            'Properties belongs at the foot of a roomy sidebar, not '
            'floating right under the lists',
      );
      expect(reachable('Sync now'), findsOneWidget);
    },
  );
}
