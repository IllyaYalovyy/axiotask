// Bottom-nav selection honesty (#236, #237). The compact bottom [ShellNavBar]
// carries the smart views only — a list opened from the drawer is NOT one of
// its destinations. While such a list is the active view the bar must show NO
// destination as selected: the previously visited smart view keeps neither its
// filled icon nor its indicator pill, and — since #237 — no destination is
// ANNOUNCED as selected either, so the bar never claims the user is somewhere
// they are not, on screen or in a screen reader. Picking a destination from
// that state still navigates (no dead tap) and restores that highlight.
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
import 'package:axiotask/src/ui/shell_nav_bar.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
    of: find.byType(ShellNavBar),
    matching: find.byIcon(v.selectedIcon),
  );

  /// Every smart view's unselected (outlined) icon, i.e. the resting bar.
  void expectNoDestinationHighlighted(WidgetTester tester) {
    expect(find.byType(ShellNavBar), findsOneWidget);
    for (final v in SmartView.values) {
      expect(
        highlightOf(v),
        findsNothing,
        reason: '${v.label} must not render as selected',
      );
      expect(
        find.descendant(
          of: find.byType(ShellNavBar),
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
    // Coming back from the out-of-set state, ONLY the destination the user
    // picked may light up: every other indicator pill (whose animation value
    // IS its painted scale and opacity) stays at zero while that one grows in.
    // The pre-#237 bar only managed this by rebuilding itself from scratch on
    // every crossing: its sentinel index otherwise kept a COMPLETED selection
    // animation parked on the wrong slot, which flashed a full-size pill the
    // moment the indicator colour went opaque again. Without a sentinel there
    // is no such slot, but the guarantee is the user's, not the mechanism's.
    await pumpShell(tester);
    await openListFromDrawer(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(ShellNavBar),
        matching: find.byIcon(SmartView.all.icon),
      ),
    );
    await tester.pump(); // first frame of the restored smart view
    await tester.pump(const Duration(milliseconds: 100)); // mid-transition

    final pills = tester
        .widgetList<NavigationIndicator>(
          find.descendant(
            of: find.byType(ShellNavBar),
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
        of: find.byType(ShellNavBar),
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

  // What a SCREEN READER hears (#237). #236 fixed the pixels; the semantic
  // announcement stayed wrong, because Material's NavigationBar has no
  // "nothing selected" index and hardcodes `selected: i == selectedIndex` on an
  // ANCESTOR of anything a caller supplies — so the sentinel slot the shell had
  // to point at was announced "Focus, tab, selected" while the user sat in a
  // list. These assertions read the rendered semantics tree, so they hold no
  // matter which widget draws the bar.
  group('bottom-nav semantics', () {
    /// The bar's tab strip. [WidgetTester.getSemantics] walks UP to the
    /// nearest unmerged node, so this starts above the bar and descends to the
    /// strip itself.
    SemanticsNode tabStrip(WidgetTester tester) {
      SemanticsNode? strip;
      void visit(SemanticsNode node) {
        if (node.getSemanticsData().role == SemanticsRole.tabBar) {
          strip = node;
          return;
        }
        node.visitChildren((child) {
          visit(child);
          return strip == null;
        });
      }

      visit(tester.getSemantics(find.byType(ShellNavBar)));
      return strip!;
    }

    /// Every destination node, in bar order — read off the ONE strip they hang
    /// from, so a screen reader treats the five as a single tab strip rather
    /// than five loose buttons.
    List<SemanticsNode> tabNodes(WidgetTester tester) {
      final result = <SemanticsNode>[];
      tabStrip(tester).visitChildren((child) {
        expect(child.getSemanticsData().role, SemanticsRole.tab);
        result.add(child);
        return true;
      });
      return result;
    }

    testWidgets('a drawer list announces no destination as selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // The restore path (the non-happy start): the app comes up straight on a
      // list, with no smart view ever visited to clear.
      await pumpShell(
        tester,
        prefs: const Prefs(view: 'L1', onboardingSeen: true),
      );

      final tabs = tabNodes(tester);
      expect(tabs, hasLength(SmartView.values.length));
      for (final v in SmartView.values) {
        final data = tabs[v.index].getSemanticsData();
        expect(
          data.flagsCollection.isSelected.toBoolOrNull(),
          isFalse,
          reason: '${v.label} must not be announced as selected on a list',
        );
        // The destination is still a reachable, position-announced tab: the
        // honesty fix must not cost the user the rest of the announcement.
        expect(
          data.label,
          '${v.label}\nTab ${v.index + 1} of ${SmartView.values.length}',
        );
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        expect(tabs[v.index].rect.size, const Size(80, 80));
      }

      handle.dispose();
    });

    testWidgets('a smart view announces exactly its own destination', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpShell(tester); // All Tasks, the default view

      final tabs = tabNodes(tester);
      for (final v in SmartView.values) {
        expect(
          tabs[v.index]
              .getSemanticsData()
              .flagsCollection
              .isSelected
              .toBoolOrNull(),
          v == SmartView.all,
          reason: '${v.label} selected state on the All Tasks view',
        );
      }
      handle.dispose();
    });

    testWidgets('a destination still gives press feedback under the finger', (
      tester,
    ) async {
      await pumpShell(
        tester,
        prefs: const Prefs(view: 'L1', onboardingSeen: true),
      );
      final ink = tester.allRenderObjects.firstWhere(
        (o) => o.runtimeType.toString() == '_RenderInkFeatures',
      );
      // At rest the ink layer draws only the indicator pills (rounded rects).
      expect(ink, isNot(paints..circle()));

      final press = await tester.startGesture(
        tester.getCenter(find.text(SmartView.focus.label)),
      );
      addTearDown(press.up);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // A splash under the pressed destination — the touch acknowledgement.
      expect(ink, paints..circle());
    });
  });
}
