// The hand-rolled compact bottom bar (#237) at the widget level.
//
// Replacing Material's NavigationBar means the shell now OWNS the bar's M3
// treatment, including the [NavigationBarThemeData] seam a themed app expects
// to be honoured. Nothing in the app sets that theme today, so without this
// test the seam would be a promise nobody checks: a themed bar that silently
// ignored the theme would still pass every shell golden.

import 'package:axiotask/src/ui/shell_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const destinations = [
    ShellDestination(
      icon: Icons.star_border,
      selectedIcon: Icons.star,
      label: 'One',
    ),
    ShellDestination(
      icon: Icons.circle_outlined,
      selectedIcon: Icons.circle,
      label: 'Two',
    ),
  ];

  Future<void> pumpBar(
    WidgetTester tester, {
    required int? selectedIndex,
    NavigationBarThemeData? barTheme,
    ValueChanged<int>? onSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          navigationBarTheme: barTheme ?? const NavigationBarThemeData(),
        ),
        home: Scaffold(
          bottomNavigationBar: ShellNavBar(
            destinations: destinations,
            selectedIndex: selectedIndex,
            onDestinationSelected: onSelected ?? (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The bar's own surface (the outermost Material the widget builds).
  Material barSurface(WidgetTester tester) => tester.widget<Material>(
    find
        .descendant(
          of: find.byType(ShellNavBar),
          matching: find.byType(Material),
        )
        .first,
  );

  testWidgets('an app-supplied nav-bar theme drives the bar', (tester) async {
    await pumpBar(
      tester,
      selectedIndex: 1,
      barTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xFF102030),
        indicatorColor: Color(0xFF405060),
        height: 96,
      ),
    );

    expect(barSurface(tester).color, const Color(0xFF102030));
    expect(
      tester.getSize(find.byType(ShellNavBar)).height,
      96,
      reason: 'the themed height, not the M3 default of 80',
    );
    final pills = tester.widgetList<NavigationIndicator>(
      find.byType(NavigationIndicator),
    );
    expect(pills.map((p) => p.color), everyElement(const Color(0xFF405060)));
  });

  testWidgets('with nothing selected every pill stays fully collapsed', (
    tester,
  ) async {
    // The out-of-set state (a drawer list): no destination is the active one,
    // so no pill may be painted at any size — there is no sentinel to hide.
    await pumpBar(tester, selectedIndex: null);

    final pills = tester.widgetList<NavigationIndicator>(
      find.byType(NavigationIndicator),
    );
    expect(pills, hasLength(destinations.length));
    expect(pills.map((p) => p.animation.value), everyElement(0.0));
    for (final d in destinations) {
      expect(find.byIcon(d.icon), findsOneWidget);
      expect(find.byIcon(d.selectedIcon), findsNothing);
    }
  });

  testWidgets('every destination reports its own index when tapped', (
    tester,
  ) async {
    final taps = <int>[];
    // From the out-of-set state: the slot a bar with no selection is most
    // likely to swallow is the first one.
    await pumpBar(tester, selectedIndex: null, onSelected: taps.add);

    await tester.tap(find.text('One'));
    await tester.tap(find.text('Two'));
    expect(taps, [0, 1]);
  });
}
