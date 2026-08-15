// Narrow-window layout (G9 #208): the adaptive shell must never throw a
// RenderFlex overflow at any window width down to the compact minimum. Two
// mechanisms keep that promise and are pinned here:
//
//   1. An OPEN detail raises the expand threshold, so a mid-width window
//      collapses to the full-screen compact detail instead of crushing three
//      panes side by side (the collapse itself is asserted in
//      list_detail_scaffold_test.dart; here we prove it yields ZERO overflow at
//      700/800dp with a detail open).
//   2. In the band that DOES stay side-by-side (≥ detailBreakpoint), the task
//      row's meta line (due chip, subtask progress, list tag) ellipsizes so a
//      long list name never overflows the narrow list column.
//
// Every test captures FlutterError.onError and asserts no "overflowed" error
// was reported — the mechanical form of "no RenderFlex overflow".

import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _destinations = [
  ShellDestination(
    icon: Icons.bolt_outlined,
    selectedIcon: Icons.bolt,
    label: 'Focus',
  ),
  ShellDestination(
    icon: Icons.checklist_outlined,
    selectedIcon: Icons.checklist,
    label: 'All Tasks',
  ),
];

/// Pump [child] and return every overflow error the framework reported while
/// laying it out (FlutterError.onError is captured, not rethrown, so the test
/// can assert on the collected list rather than dying on the first overflow).
Future<List<String>> overflowErrors(WidgetTester tester, Widget child) async {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString();
    if (text.contains('overflowed')) errors.add(text);
  };
  addTearDown(() => FlutterError.onError = previous);
  await tester.pumpWidget(child);
  await tester.pump();
  return errors;
}

/// A list pane packed with the meta line's worst case: a long title, a due
/// chip, subtask progress, AND a long cross-list tag on every row — exactly the
/// combination that overflows a narrow list column without the ellipsis fix.
Widget _denseList() => ListView(
  children: [
    for (var i = 0; i < 6; i++)
      TaskRow(
        title:
            'A deliberately long task title #$i that must ellipsize instead of '
            'overflowing when the list column gets narrow',
        completed: false,
        due: '2026-08-20',
        subtaskDone: 3,
        subtaskTotal: 10,
        listTag: 'Engineering Roadmap Q3 2026 Planning & Delivery',
        onOpen: () {},
        onToggle: () {},
        onRename: (_) {},
        onPickDate: () {},
      ),
  ],
);

/// A representative detail pane (its own app bar over scrolling content) — the
/// scaffold only needs it non-null to treat the detail as open.
Widget _detailPane() => Column(
  children: [
    AppBar(title: const Text('Task Details')),
    const Expanded(
      child: SingleChildScrollView(
        child: Padding(padding: EdgeInsets.all(16), child: Text('detail body')),
      ),
    ),
  ],
);

Widget _shellAt(double width, {Widget? detail}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(size: Size(width, 800)),
    child: ListDetailScaffold(
      sidebar: const SizedBox(width: 260, child: Text('SIDEBAR')),
      destinations: _destinations,
      selectedIndex: 0,
      onDestinationSelected: (_) {},
      title: 'All Tasks',
      list: _denseList(),
      detail: detail,
      onCloseDetail: () {},
    ),
  ),
);

void main() {
  group('detail open collapses so a narrow window never overflows', () {
    for (final width in [700.0, 800.0]) {
      testWidgets('no overflow at ${width.toInt()}px with a detail open', (
        tester,
      ) async {
        final errors = await overflowErrors(
          tester,
          _shellAt(width, detail: _detailPane()),
        );
        expect(
          errors,
          isEmpty,
          reason:
              'a $width-wide window with a detail open must collapse to the '
              'full-screen compact detail, not overflow',
        );
        // Proof it actually collapsed: the dense list is offstage/gone.
        expect(find.byType(TaskRow), findsNothing);
      });
    }
  });

  testWidgets(
    'side-by-side at detailBreakpoint: the dense list column does NOT overflow',
    (tester) async {
      // At the narrowest side-by-side width the list column is at its tightest;
      // the meta line (long list tag included) must ellipsize, not overflow.
      final errors = await overflowErrors(
        tester,
        _shellAt(ListDetailScaffold.detailBreakpoint, detail: _detailPane()),
      );
      expect(errors, isEmpty);
      // Confirm we are genuinely in the three-pane layout (rows are on screen).
      expect(find.byType(TaskRow), findsWidgets);
    },
  );

  testWidgets(
    'the task-row meta line ellipsizes instead of overflowing a tiny column',
    (tester) async {
      // A directly-constrained row: 175dp forces the meta column to ~111dp,
      // where the un-ellipsized subtask progress + long list tag overflowed
      // before G9. Every meta element must now shrink to fit.
      final errors = await overflowErrors(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 175, child: _MetaRow()),
            ),
          ),
        ),
      );
      expect(errors, isEmpty);
      // The long tag is still present as a (now-ellipsizing) widget.
      expect(find.textContaining('Engineering Roadmap'), findsOneWidget);
    },
  );
}

/// A single worst-case [TaskRow] as a const-constructible child.
class _MetaRow extends StatelessWidget {
  const _MetaRow();

  @override
  Widget build(BuildContext context) => TaskRow(
    title: 'A long enough title to force the main line to ellipsize as well',
    completed: false,
    due: '2026-08-20',
    subtaskDone: 3,
    subtaskTotal: 10,
    listTag: 'Engineering Roadmap Q3 2026 Planning & Delivery',
    onOpen: () {},
    onToggle: () {},
    onRename: (_) {},
    onPickDate: () {},
  );
}
