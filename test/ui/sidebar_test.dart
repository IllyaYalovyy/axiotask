// The sidebar's user-visible contract: the smart views render with their count
// badges (hidden at zero) and highlight the active one; the lists render with
// counts, dim when excluded, and expose management (create / rename / delete
// with confirm / exclude) through a touch-reachable overflow menu; and a drag
// reorder reports the new order. Every action is injected, so these WIDGET tests
// assert what renders and the callback a gesture fires — never a stubbed method.

import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/sidebar.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

StoredTaskList list(String id, String title, {bool localOnly = false}) =>
    StoredTaskList(
      list: TaskList(id: id, title: title, etag: 'e', updated: 't'),
      syncState: SyncState.clean,
      localUpdated: 't',
      localOnly: localOnly,
    );

void main() {
  Future<_Captured> pump(
    WidgetTester tester, {
    String selectedViewId = 'all',
    Map<String, int> counts = const {},
    List<StoredTaskList> lists = const [],
    Set<String> excluded = const {},
    Widget? footer,
    TargetPlatform? platform,
  }) async {
    final cap = _Captured();
    await tester.pumpWidget(
      MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        home: Scaffold(
          body: Row(
            children: [
              Sidebar(
                selectedViewId: selectedViewId,
                counts: counts,
                lists: lists,
                excludedLists: excluded,
                onSelectView: (v) => cap.selected.add(v),
                onCreateList: (t, {localOnly = false}) =>
                    cap.created.add((t, localOnly)),
                onRenameList: (id, t) => cap.renamed.add((id, t)),
                onDeleteList: (id) => cap.deleted.add(id),
                onToggleExclude: (id) => cap.toggled.add(id),
                onReorderLists: (o) => cap.reordered.add(o),
                onExportList: (id) => cap.exported.add(id),
                footer: footer,
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return cap;
  }

  group('list drag handle 48dp touch target (F19 #198)', () {
    double handleHeight(WidgetTester tester) => tester
        .getSize(
          find
              .ancestor(
                of: find.byIcon(Icons.drag_indicator),
                matching: find.byType(ReorderableDragStartListener),
              )
              .first,
        )
        .height;

    testWidgets('the drag handle is a ≥48dp target on a touch pointer', (
      tester,
    ) async {
      // In the drawer the handle is the only touch grab point for reorder; a
      // finger needs a 48dp target.
      await pump(
        tester,
        lists: [list('L1', 'My Tasks')],
        platform: TargetPlatform.android,
      );
      expect(handleHeight(tester), greaterThanOrEqualTo(48));
    });

    testWidgets('the drag handle stays compact (<48dp) on a mouse pointer', (
      tester,
    ) async {
      await pump(
        tester,
        lists: [list('L1', 'My Tasks')],
        platform: TargetPlatform.linux,
      );
      expect(
        handleHeight(tester),
        lessThan(48),
        reason: 'the desktop sidebar keeps its dense list rows',
      );
    });
  });

  testWidgets('renders the five smart views and selects one on tap', (
    tester,
  ) async {
    final cap = await pump(tester);
    for (final v in SmartView.values) {
      expect(find.text(v.label), findsOneWidget);
    }
    await tester.tap(find.text('Upcoming'));
    expect(cap.selected, ['upcoming']);
  });

  testWidgets('a count badge shows when > 0 and is hidden at zero', (
    tester,
  ) async {
    await pump(tester, counts: {'focus': 3, 'missed': 0});
    // Focus badge renders its "3"…
    expect(find.text('3'), findsOneWidget);
    // …and a zero-count view shows no badge (no stray "0").
    expect(find.text('0'), findsNothing);
  });

  testWidgets('lists render with counts and the local-only flag', (
    tester,
  ) async {
    await pump(
      tester,
      lists: [list('L1', 'Work'), list('L2', 'Scratch', localOnly: true)],
      counts: {'L1': 7},
    );
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Scratch'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    // The local-only list carries the offline icon.
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });

  testWidgets('the empty "No lists" state shows when there are none', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('No lists'), findsOneWidget);
  });

  // ── Exclusion: an explicit affordance, not "disabled" styling (#248) ──────
  // The failure barred: an excluded list rendered ONLY as dim + italic. That is
  // the universal inactive-control look — it says nothing about WHY the row is
  // quiet, and a screen reader announces nothing at all about it.
  group('an excluded list says so:', () {
    testWidgets('it shows the visibility_off icon and announces why', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, lists: [list('L1', 'Work')], excluded: {'L1'});

      // The visible signal sits in the row itself, next to the title.
      final icon = find.descendant(
        of: find.ancestor(of: find.text('Work'), matching: find.byType(Row)),
        matching: find.byIcon(Icons.visibility_off_outlined),
      );
      expect(icon, findsOneWidget);
      // …and TalkBack reads the same words the tooltip shows.
      expect(
        tester.getSemantics(icon.first).label,
        'Work\nExcluded from smart views',
        reason: 'the row must announce the list AND why it is quiet',
      );

      // The title is no longer italic: italics carried no meaning and cost
      // legibility on the app's densest navigation surface.
      expect(tester.widget<Text>(find.text('Work')).style?.fontStyle, isNull);
      handle.dispose();
    });

    testWidgets(
      'the glyph is a marker, not a dead zone — the row still opens',
      (tester) async {
        // It sits inside the row's tap target: a finger that lands on it must
        // open the list like any other part of the row.
        final cap = await pump(
          tester,
          lists: [list('L1', 'Work')],
          excluded: {'L1'},
        );
        await tester.tap(find.byIcon(Icons.visibility_off_outlined));
        await tester.pumpAndSettle();
        expect(cap.selected, ['L1']);
      },
    );

    testWidgets('an included list shows neither the icon nor the label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, lists: [list('L1', 'Work')]);
      expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
      expect(find.bySemanticsLabel('Excluded from smart views'), findsNothing);
      handle.dispose();
    });
  });

  testWidgets(
    'create-list dialog reports a trimmed title and local-only flag',
    (tester) async {
      final cap = await pump(tester);
      await tester.tap(find.byKey(const Key('sidebar-add-list')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  Shopping  ');
      await tester.tap(find.byKey(const Key('new-list-local-only')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-list-create')));
      await tester.pumpAndSettle();
      expect(cap.created, [('Shopping', true)]);
    },
  );

  testWidgets('a blank create submits nothing (non-happy path)', (
    tester,
  ) async {
    final cap = await pump(tester);
    await tester.tap(find.byKey(const Key('sidebar-add-list')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byKey(const Key('new-list-create')));
    await tester.pumpAndSettle();
    expect(cap.created, isEmpty);
  });

  testWidgets('rename via the overflow menu reports the new title', (
    tester,
  ) async {
    final cap = await pump(tester, lists: [list('L1', 'Work')]);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Projects');
    await tester.tap(find.byKey(const Key('rename-list-save')));
    await tester.pumpAndSettle();
    expect(cap.renamed, [('L1', 'Projects')]);
  });

  testWidgets('delete asks for confirmation before reporting', (tester) async {
    final cap = await pump(tester, lists: [list('L1', 'Work')]);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete list'));
    await tester.pumpAndSettle();
    // The styled confirm dialog spells out the consequence…
    expect(
      find.text('Delete "Work" and all its tasks? This cannot be undone.'),
      findsOneWidget,
    );
    // …cancelling deletes nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cap.deleted, isEmpty);

    // Confirming deletes.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete list'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-list-confirm-button')));
    await tester.pumpAndSettle();
    expect(cap.deleted, ['L1']);
  });

  testWidgets('the overflow menu toggles exclusion with state-aware wording', (
    tester,
  ) async {
    // An already-excluded list offers to Include it back.
    final cap = await pump(
      tester,
      lists: [list('L1', 'Work')],
      excluded: {'L1'},
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Include in smart views'), findsOneWidget);
    await tester.tap(find.text('Include in smart views'));
    await tester.pumpAndSettle();
    expect(cap.toggled, ['L1']);
  });

  // ── The list menu: three distinct things, Delete fenced off (#248) ────────
  // The failure barred: a list the user can see but cannot get OUT of the app —
  // the export entry has to be on the list's own menu, aimed at THAT list, on
  // the one surface a finger can reach (touch has no right-click).
  group('exporting a list:', () {
    testWidgets('the list menu offers Export… and names the list', (
      tester,
    ) async {
      final cap = await pump(
        tester,
        lists: [list('L1', 'Work'), list('L2', 'Home')],
      );

      // The SECOND list's menu — an export must carry the id of the row it was
      // opened from, not of whichever list happens to be selected.
      await tester.tap(find.byIcon(Icons.more_vert).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export…'));
      await tester.pumpAndSettle();

      expect(cap.exported, ['L2']);
    });
  });

  // The failure barred: `Delete list` sitting undivided, in the same tone,
  // directly under the exclude toggle the user reaches for routinely — a
  // slightly mis-aimed tap lands on an irreversible cascade delete.
  group('the list menu:', () {
    testWidgets('fences Delete list off and tones it destructive', (
      tester,
    ) async {
      await pump(tester, lists: [list('L1', 'Work')]);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      // Reading order down the menu: Rename, the exclude toggle, a rule, then
      // the destructive entry last.
      double y(Finder f) => tester.getCenter(f).dy;
      expect(
        y(find.text('Rename')),
        lessThan(y(find.text('Exclude from smart views'))),
      );
      expect(find.byType(PopupMenuDivider), findsOneWidget);
      expect(
        y(find.text('Exclude from smart views')),
        lessThan(y(find.byType(PopupMenuDivider))),
      );
      expect(
        y(find.byType(PopupMenuDivider)),
        lessThan(y(find.text('Delete list'))),
        reason: 'Delete list must sit below the rule that fences it off',
      );

      // Each entry carries its own glyph, so the three read as three things.
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // …and only the destructive one is error-toned.
      final error = Theme.of(
        tester.element(find.text('Delete list')),
      ).colorScheme.error;
      expect(tester.widget<Text>(find.text('Delete list')).style?.color, error);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.delete_outline)).color,
        error,
      );
      expect(
        tester.widget<Text>(find.text('Rename')).style?.color,
        isNot(error),
      );
    });

    testWidgets('an excluded list offers the mirrored Include glyph', (
      tester,
    ) async {
      // The non-happy state: already excluded, so the menu offers the way back
      // and its glyph flips with it.
      await pump(tester, lists: [list('L1', 'Work')], excluded: {'L1'});
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.widgetWithText(Row, 'Include in smart views'),
          matching: find.byIcon(Icons.visibility_outlined),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the ⋮ button keeps a ≥48dp touch target', (tester) async {
      await pump(
        tester,
        lists: [list('L1', 'Work')],
        platform: TargetPlatform.android,
      );
      final size = tester.getSize(find.byType(PopupMenuButton<String>));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  for (final scale in [1.3, 2.0]) {
    testWidgets(
      'at ${scale}x text scale the excluded row still fits icon + badge',
      (tester) async {
        // The sidebar is a fixed 260dp column: enlarge the system font and the
        // title, the new exclusion glyph, the count badge and the ⋮ all have to
        // keep sharing that width. A RenderFlex overflow throws here.
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: MaterialApp(
              home: Scaffold(
                body: Row(
                  children: [
                    Sidebar(
                      selectedViewId: 'all',
                      counts: const {'L1': 128},
                      lists: [list('L1', 'Household errands and repairs')],
                      excludedLists: const {'L1'},
                      onSelectView: (_) {},
                      onCreateList: (_, {localOnly = false}) {},
                      onRenameList: (_, _) {},
                      onDeleteList: (_) {},
                      onToggleExclude: (_) {},
                      onReorderLists: (_) {},
                    ),
                    const Expanded(child: SizedBox()),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
        expect(find.text('128'), findsOneWidget);
        // …and the menu it opens wraps its longest entry rather than overflowing.
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        expect(find.text('Include in smart views'), findsOneWidget);
        expect(find.text('Delete list'), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Dismiss it well outside both the menu and the 260dp sidebar.
        await tester.tapAt(const Offset(700, 20));
        await tester.pumpAndSettle();
        // Everything still inside the 260dp column, nothing clipped off the edge.
        expect(
          tester.getBottomRight(find.text('128')).dx,
          lessThanOrEqualTo(260),
        );
      },
    );
  }

  testWidgets('dragging a list handle reports the reordered ids', (
    tester,
  ) async {
    final cap = await pump(
      tester,
      lists: [list('L1', 'Work'), list('L2', 'Home'), list('L3', 'Errands')],
    );
    // Grab the last row's drag handle and drag it up past the first row.
    final handles = find.byIcon(Icons.drag_indicator);
    final start = tester.getCenter(handles.at(2));
    final target = tester.getCenter(handles.at(0));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(Offset(target.dx, target.dy - 40));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(cap.reordered, isNotEmpty);
    final order = cap.reordered.last;
    // Errands (originally last) moved up, and the reported order is a complete
    // permutation of the three list ids.
    expect(order.toSet(), {'L1', 'L2', 'L3'});
    expect(order.indexOf('L3'), lessThan(2), reason: 'Errands moved up');
  });

  testWidgets('a lifted list row carries the app-wide drag weight (#256)', (
    tester,
  ) async {
    // The sidebar drags through a bare [SliverReorderableList], which supplies
    // no proxy decorator at all — a list picked up here used to go FLAT while a
    // task picked up two panes over gained elevation, scale and a tonal surface.
    // One lift, both drags.
    await pump(tester, lists: [list('L1', 'Work'), list('L2', 'Home')]);
    final handles = find.byIcon(Icons.drag_indicator);
    final gesture = await tester.startGesture(tester.getCenter(handles.first));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump(); // the proxy mounts, still flat
    await tester.pump(); // the lift's first tick
    await tester.pump(const Duration(milliseconds: 100)); // Motion.short

    final surface = find.byKey(const Key('drag-lift-surface'));
    expect(tester.widget<Material>(surface).elevation, 6);
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('drag-lift-scale')))
          .transform
          .getMaxScaleOnAxis(),
      closeTo(1.02, 0.0001),
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(surface, findsNothing, reason: 'the proxy is gone once it lands');
  });

  testWidgets('the footer is rendered when provided', (tester) async {
    await pump(tester, footer: const Text('FOOTER-MARKER'));
    expect(find.text('FOOTER-MARKER'), findsOneWidget);
  });
}

class _Captured {
  final List<String> selected = [];
  final List<(String, bool)> created = [];
  final List<(String, String)> renamed = [];
  final List<String> deleted = [];
  final List<String> toggled = [];
  final List<List<String>> reordered = [];
  final List<String> exported = [];
}
