// Protects the adaptive layout contract of ListDetailScaffold at the single
// 600dp breakpoint, and the compact back_dispatcher behavior (a back gesture
// with a detail open closes the detail instead of popping the app).

import 'package:axiotask/src/ui/list_detail_scaffold.dart';
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

void main() {
  Future<void> pumpScaffold(
    WidgetTester tester, {
    required double width,
    Widget? detail,
    ValueChanged<int>? onSelect,
    VoidCallback? onClose,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 800)),
          child: ListDetailScaffold(
            destinations: _destinations,
            selectedIndex: 0,
            onDestinationSelected: onSelect ?? (_) {},
            list: const Text('LIST-PANE'),
            detail: detail,
            onCloseDetail: onClose,
          ),
        ),
      ),
    );
  }

  group('expanded (width ≥ 600)', () {
    testWidgets('shows a NavigationRail and the list', (tester) async {
      await pumpScaffold(tester, width: 900);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('LIST-PANE'), findsOneWidget);
    });

    testWidgets('shows list and detail SIDE BY SIDE when a task is selected', (
      tester,
    ) async {
      await pumpScaffold(tester, width: 900, detail: const Text('DETAIL-PANE'));
      // Both panes are visible at once — the expanded contract.
      expect(find.text('LIST-PANE'), findsOneWidget);
      expect(find.text('DETAIL-PANE'), findsOneWidget);
    });
  });

  group('compact (width < 600)', () {
    testWidgets('shows a NavigationBar over the list', (tester) async {
      await pumpScaffold(tester, width: 400);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('LIST-PANE'), findsOneWidget);
    });

    testWidgets('an open detail COVERS the list and hides the nav bar', (
      tester,
    ) async {
      await pumpScaffold(tester, width: 400, detail: const Text('DETAIL-PANE'));
      // Non-happy / coarse-pointer path: detail full-screen, list gone.
      expect(find.text('DETAIL-PANE'), findsOneWidget);
      expect(find.text('LIST-PANE'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('a system back with a detail open closes the detail', (
      tester,
    ) async {
      var closed = false;
      await pumpScaffold(
        tester,
        width: 400,
        detail: const Text('DETAIL-PANE'),
        onClose: () => closed = true,
      );
      // Simulate the Android/system back button.
      final popped = await tester.binding.handlePopRoute();
      await tester.pump();
      // The app did NOT pop; the detail-close handler ran instead.
      expect(popped, isTrue);
      expect(closed, isTrue);
    });
  });

  testWidgets('tapping a destination reports its index', (tester) async {
    int? selected;
    await pumpScaffold(tester, width: 400, onSelect: (i) => selected = i);
    await tester.tap(find.text('All Tasks'));
    await tester.pump();
    expect(selected, 1);
  });
}
