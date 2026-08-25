// Bottom-nav selection honesty (#236). The compact bottom [NavigationBar]
// carries the smart views only — a list opened from the drawer is NOT one of
// its destinations. While such a list is the active view the bar must show NO
// destination as selected: the previously visited smart view keeps neither its
// filled icon nor its indicator pill, so the bar never claims the user is
// somewhere they are not. Picking a destination from that state still
// navigates (no dead tap) and restores that destination's highlight.
//
// These drive the REAL shell (AxiotaskApp → AppShell → ListDetailScaffold) over
// static provider streams — no database — so every assertion is about what the
// user sees in the rendered bar.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_nav'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  PrefsStore prefsStore(Prefs prefs) =>
      PrefsStore(File(p.join(tmp.path, 'prefs.json')))..save(prefs);

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

  /// The icon a destination shows ONLY while it is the selected one — the
  /// user-visible mark of "you are here" in the bar.
  Finder highlightOf(SmartView v) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.byIcon(v.selectedIcon),
  );

  /// Every smart view's unselected (outlined) icon, i.e. the resting bar.
  void expectNoDestinationHighlighted(WidgetTester tester) {
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final v in SmartView.values) {
      expect(
        highlightOf(v),
        findsNothing,
        reason: '${v.label} must not render as selected',
      );
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.byIcon(v.icon),
        ),
        findsOneWidget,
        reason: '${v.label} still renders, unselected',
      );
    }
  }

  Future<PrefsStore> pumpShell(WidgetTester tester, {Prefs? prefs}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // Onboarding already dismissed so the welcome overlay never covers the bar.
    final store = prefsStore(prefs ?? const Prefs(onboardingSeen: true));
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

  Future<void> openListFromDrawer(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Groceries'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a smart view highlights its own destination', (tester) async {
    await pumpShell(tester);

    // Baseline: the active view (All Tasks, the default) IS a destination, so
    // it — and only it — renders selected.
    expect(highlightOf(SmartView.all), findsOneWidget);
    for (final v in SmartView.values.where((v) => v != SmartView.all)) {
      expect(highlightOf(v), findsNothing);
    }
  });

  testWidgets('opening a drawer list clears the bottom-nav highlight', (
    tester,
  ) async {
    final store = await pumpShell(tester);
    expect(highlightOf(SmartView.all), findsOneWidget, reason: 'precondition');

    await openListFromDrawer(tester);

    // The list is the active view …
    expect(store.load().view, 'L1');
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Groceries'),
      ),
      findsOneWidget,
    );
    // … and the bar no longer claims a smart view is where the user is.
    expectNoDestinationHighlighted(tester);
  });

  testWidgets('a persisted list view starts with no destination highlighted', (
    tester,
  ) async {
    // Restore path (the non-happy start): the app relaunches straight into a
    // list — the bar must be honest on the very first paint, with no visit to
    // a smart view to clear.
    await pumpShell(
      tester,
      prefs: const Prefs(view: 'L1', onboardingSeen: true),
    );

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Groceries'),
      ),
      findsOneWidget,
    );
    expectNoDestinationHighlighted(tester);
  });

  testWidgets('returning to a smart view leaves no ghost pill behind', (
    tester,
  ) async {
    // The bar has no "nothing selected" index, so the out-of-set state points a
    // sentinel index at a destination it draws unselected. When a real
    // selection returns, that sentinel slot must not light up: its indicator
    // pill (whose animation value IS its painted scale and opacity) stays at
    // zero while the destination the user actually picked grows in.
    await pumpShell(tester);
    await openListFromDrawer(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(SmartView.all.icon),
      ),
    );
    await tester.pump(); // first frame of the restored smart view
    await tester.pump(const Duration(milliseconds: 100)); // mid-transition

    final pills = tester
        .widgetList<NavigationIndicator>(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.byType(NavigationIndicator),
          ),
        )
        .toList();
    expect(pills, hasLength(SmartView.values.length));
    for (final v in SmartView.values) {
      expect(
        pills[v.index].animation.value,
        v == SmartView.all ? greaterThan(0.0) : 0.0,
        reason: '${v.label} pill mid-transition',
      );
    }
  });

  testWidgets('picking a destination from a list navigates and highlights it', (
    tester,
  ) async {
    final store = await pumpShell(tester);
    await openListFromDrawer(tester);
    expectNoDestinationHighlighted(tester);

    // Focus is the FIRST destination — the slot a bar with no selection is
    // most likely to treat as "already selected" and swallow the tap.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(SmartView.focus.icon),
      ),
    );
    await tester.pumpAndSettle();

    expect(store.load().view, SmartView.focus.id);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text(SmartView.focus.label),
      ),
      findsOneWidget,
    );
    // The highlight comes back with the smart view, on the right destination.
    expect(highlightOf(SmartView.focus), findsOneWidget);
    for (final v in SmartView.values.where((v) => v != SmartView.focus)) {
      expect(highlightOf(v), findsNothing);
    }
  });
}
