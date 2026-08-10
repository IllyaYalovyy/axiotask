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
  }) async {
    final cap = _Captured();
    await tester.pumpWidget(
      MaterialApp(
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

  testWidgets('an excluded list is dimmed and italicized', (tester) async {
    await pump(tester, lists: [list('L1', 'Work')], excluded: {'L1'});
    final text = tester.widget<Text>(find.text('Work'));
    expect(text.style?.fontStyle, FontStyle.italic);
    // The dimming Opacity wraps the row.
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('Work'), matching: find.byType(Opacity))
          .first,
    );
    expect(opacity.opacity, 0.5);
  });

  testWidgets('create-list dialog reports a trimmed title and local-only flag', (
    tester,
  ) async {
    final cap = await pump(tester);
    await tester.tap(find.byKey(const Key('sidebar-add-list')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Shopping  ');
    await tester.tap(find.byKey(const Key('new-list-local-only')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-list-create')));
    await tester.pumpAndSettle();
    expect(cap.created, [('Shopping', true)]);
  });

  testWidgets('a blank create submits nothing (non-happy path)', (tester) async {
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
}
