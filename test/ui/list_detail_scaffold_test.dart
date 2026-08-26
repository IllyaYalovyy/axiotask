// Protects the adaptive layout contract of ListDetailScaffold at the single
// 600dp breakpoint, and the compact back_dispatcher behavior (a back gesture
// with a detail open closes the detail instead of popping the app).

import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:flutter/gestures.dart'
    show kDoubleTapMinTime, kDoubleTapTimeout;
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
    double sidebarWidth = ListDetailScaffold.defaultSidebarWidth,
    double detailFraction = ListDetailScaffold.defaultDetailFraction,
    ValueChanged<double>? onSidebarWidthChanged,
    ValueChanged<double>? onDetailFractionChanged,
    VoidCallback? onResetSidebarWidth,
    VoidCallback? onResetDetailFraction,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 800)),
          child: ListDetailScaffold(
            sidebar: const Text('SIDEBAR-PANE'),
            destinations: _destinations,
            selectedIndex: 0,
            onDestinationSelected: onSelect ?? (_) {},
            list: const Text('LIST-PANE'),
            detail: detail,
            onCloseDetail: onClose,
            sidebarWidth: sidebarWidth,
            detailFraction: detailFraction,
            onSidebarWidthChanged: onSidebarWidthChanged,
            onDetailFractionChanged: onDetailFractionChanged,
            onResetSidebarWidth: onResetSidebarWidth,
            onResetDetailFraction: onResetDetailFraction,
          ),
        ),
      ),
    );
  }

  double widthOf(WidgetTester tester, String keyValue) =>
      tester.getSize(find.byKey(Key(keyValue))).width;

  group('expanded (width ≥ 600)', () {
    testWidgets('shows the sidebar panel and the list', (tester) async {
      await pumpScaffold(tester, width: 900);
      // Expanded renders the injected sidebar (the real one is the Sidebar
      // widget); no bottom nav bar at this width.
      expect(find.text('SIDEBAR-PANE'), findsOneWidget);
      expect(find.byType(ShellNavBar), findsNothing);
      expect(find.text('LIST-PANE'), findsOneWidget);
    });

    testWidgets('shows list and detail SIDE BY SIDE when a task is selected', (
      tester,
    ) async {
      await pumpScaffold(tester, width: 900, detail: const Text('DETAIL-PANE'));
      // Both panes are visible at once — the expanded contract.
      expect(find.text('LIST-PANE'), findsOneWidget);
      expect(find.text('DETAIL-PANE'), findsOneWidget);
      await tester.pump(kDoubleTapTimeout);
    });
  });

  group('compact (width < 600)', () {
    testWidgets('shows a ShellNavBar over the list', (tester) async {
      await pumpScaffold(tester, width: 400);
      expect(find.byType(ShellNavBar), findsOneWidget);
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
      expect(find.byType(ShellNavBar), findsNothing);
    });

    testWidgets('an open detail gets full height (a lazy ListView renders)', (
      tester,
    ) async {
      // Regression: the Stack sized to the offstage 0×0 list, starving the
      // detail pane of height, so a lazy ListView in it built zero children.
      await pumpScaffold(
        tester,
        width: 400,
        detail: ListView(
          children: const [SizedBox(height: 40, child: Text('DETAIL-ROW'))],
        ),
      );
      expect(find.text('DETAIL-ROW'), findsOneWidget);
      final size = tester.getSize(find.byType(ListView));
      expect(size.height, greaterThan(100), reason: 'detail fills the screen');
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

  // G9 (#208): the breakpoint ACCOUNTS FOR THE DETAIL PANE. A mid-width window
  // (600–839dp) is expanded with no detail, but an OPEN detail there collapses
  // to the full-screen compact layout instead of squeezing three panes.
  group('detail-aware collapse (G9 #208)', () {
    testWidgets(
      'a mid-width window with NO detail is expanded (sidebar + list)',
      (tester) async {
        await pumpScaffold(tester, width: 800);
        // 800 ≥ 600 and no detail → expanded: sidebar shown, no bottom nav.
        expect(find.text('SIDEBAR-PANE'), findsOneWidget);
        expect(find.byType(ShellNavBar), findsNothing);
        expect(find.text('LIST-PANE'), findsOneWidget);
      },
    );

    testWidgets(
      'the SAME mid-width window COLLAPSES to full-screen detail once one opens',
      (tester) async {
        await pumpScaffold(
          tester,
          width: 800,
          detail: const Text('DETAIL-PANE'),
        );
        // 800 < 840 (detailBreakpoint) → compact: the detail owns the screen,
        // the list is covered, and the expanded three-pane row never renders.
        expect(find.text('DETAIL-PANE'), findsOneWidget);
        expect(find.text('LIST-PANE'), findsNothing);
        expect(find.text('SIDEBAR-PANE'), findsNothing);
      },
    );

    testWidgets('just below detailBreakpoint the detail collapses', (
      tester,
    ) async {
      await pumpScaffold(
        tester,
        width: ListDetailScaffold.detailBreakpoint - 1,
        detail: const Text('DETAIL-PANE'),
      );
      expect(find.text('DETAIL-PANE'), findsOneWidget);
      expect(find.text('LIST-PANE'), findsNothing);
    });

    testWidgets('at detailBreakpoint the list + detail sit side by side', (
      tester,
    ) async {
      await pumpScaffold(
        tester,
        width: ListDetailScaffold.detailBreakpoint,
        detail: const Text('DETAIL-PANE'),
      );
      // 840 ≥ 840 → expanded three-pane: both panes visible at once.
      expect(find.text('LIST-PANE'), findsOneWidget);
      expect(find.text('DETAIL-PANE'), findsOneWidget);
      expect(find.text('SIDEBAR-PANE'), findsOneWidget);
      expect(find.byType(ShellNavBar), findsNothing);
    });
  });

  // #210: the expanded layout's two dividers are draggable, clamped, persisted
  // on drag end, and reset on double-click. The compact layout has no handles.
  group('draggable dividers (#210)', () {
    testWidgets('dragging the sidebar handle widens the sidebar live', (
      tester,
    ) async {
      double? persisted;
      await pumpScaffold(
        tester,
        width: 1000,
        onSidebarWidthChanged: (w) => persisted = w,
      );
      expect(widthOf(tester, 'expanded-sidebar'), 260);

      // Live tracking: the pane follows the pointer BEFORE the gesture ends.
      final handle = find.byKey(const Key('sidebar-resize-handle'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(widthOf(tester, 'expanded-sidebar'), 310);
      expect(persisted, isNull, reason: 'no write until the gesture ends');

      await gesture.up();
      await tester.pump();
      expect(persisted, 310, reason: 'one persistence write on drag end');
      await tester.pump(
        kDoubleTapTimeout,
      ); // drain the double-tap tracker timer
    });

    testWidgets(
      'the sidebar width clamps to its max no matter how far dragged',
      (tester) async {
        double? persisted;
        await pumpScaffold(
          tester,
          width: 1200,
          onSidebarWidthChanged: (w) => persisted = w,
        );
        await tester.drag(
          find.byKey(const Key('sidebar-resize-handle')),
          const Offset(1000, 0),
        );
        await tester.pump();
        expect(
          widthOf(tester, 'expanded-sidebar'),
          ListDetailScaffold.maxSidebarWidth,
        );
        expect(persisted, ListDetailScaffold.maxSidebarWidth);
        expect(
          tester.takeException(),
          isNull,
          reason: 'no overflow at the max',
        );
        await tester.pump(kDoubleTapTimeout);
      },
    );

    testWidgets('the sidebar width clamps to its min when dragged left', (
      tester,
    ) async {
      await pumpScaffold(tester, width: 1000);
      await tester.drag(
        find.byKey(const Key('sidebar-resize-handle')),
        const Offset(-1000, 0),
      );
      await tester.pump();
      expect(
        widthOf(tester, 'expanded-sidebar'),
        ListDetailScaffold.minSidebarWidth,
      );
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('double-clicking the sidebar handle resets to the default', (
      tester,
    ) async {
      double? persisted;
      await pumpScaffold(
        tester,
        width: 1000,
        sidebarWidth: 360,
        onResetSidebarWidth: () => persisted = -1,
      );
      expect(widthOf(tester, 'expanded-sidebar'), 360);

      final handle = find.byKey(const Key('sidebar-resize-handle'));
      await tester.tap(handle);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(handle);
      await tester.pump();

      expect(
        widthOf(tester, 'expanded-sidebar'),
        ListDetailScaffold.defaultSidebarWidth,
      );
      expect(persisted, -1, reason: 'the reset was persisted');
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('dragging the detail handle grows the detail pane', (
      tester,
    ) async {
      double? persisted;
      await pumpScaffold(
        tester,
        width: 1000,
        detail: const Text('DETAIL-PANE'),
        onDetailFractionChanged: (f) => persisted = f,
      );
      final before = widthOf(tester, 'expanded-detail');

      // Drag the handle LEFT → the list shrinks, the detail grows ~50px.
      await tester.drag(
        find.byKey(const Key('detail-resize-handle')),
        const Offset(-50, 0),
      );
      await tester.pump();
      final after = widthOf(tester, 'expanded-detail');
      expect(after, greaterThan(before));
      expect(
        (after - before - 50).abs(),
        lessThan(1),
        reason: 'the pane tracks the pointer 1:1',
      );
      expect(persisted, isNotNull);
      expect(persisted, greaterThan(ListDetailScaffold.defaultDetailFraction));
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('the detail fraction clamps to its max (no overflow)', (
      tester,
    ) async {
      await pumpScaffold(tester, width: 900, detail: const Text('DETAIL-PANE'));
      await tester.drag(
        find.byKey(const Key('detail-resize-handle')),
        const Offset(-2000, 0),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Both panes still on screen; the detail did not swallow the list.
      expect(find.text('LIST-PANE'), findsOneWidget);
      expect(find.text('DETAIL-PANE'), findsOneWidget);
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('a persisted width beyond the clamp is pinned on load', (
      tester,
    ) async {
      // A corrupt/stale pref must never crush a pane: the layout clamps on read.
      await pumpScaffold(tester, width: 1000, sidebarWidth: 9999);
      expect(
        widthOf(tester, 'expanded-sidebar'),
        ListDetailScaffold.maxSidebarWidth,
      );
    });

    testWidgets('the compact layout has NO resize handles', (tester) async {
      await pumpScaffold(tester, width: 400);
      expect(find.byKey(const Key('sidebar-resize-handle')), findsNothing);
      expect(find.byKey(const Key('detail-resize-handle')), findsNothing);
    });

    testWidgets('only the sidebar handle exists when no detail is open', (
      tester,
    ) async {
      await pumpScaffold(tester, width: 1000);
      expect(find.byKey(const Key('sidebar-resize-handle')), findsOneWidget);
      expect(find.byKey(const Key('detail-resize-handle')), findsNothing);
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
