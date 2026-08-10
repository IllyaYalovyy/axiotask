// SafeArea contracts (MIGRATION-PLAN §5 T8.2, #166/#160). The phone chrome must
// clear the status bar / notch / bottom gesture pill:
//   • the app bar (toolbar) sits past the top status bar;
//   • the list body clears the side insets;
//   • the FAB floats above the bottom pill and off the right edge;
//   • the slide-in drawer is inset from the top, bottom, and left;
//   • the full-screen detail header clears the status bar;
//   • every inset has an explicit fallback so an un-notched device still breathes.
//
// These pin geometry directly (getRect against injected MediaQuery padding), so
// they are the Flutter-native re-verification of the reference's CSS
// env(safe-area-inset-*) rules — a regression is a measurable overlap.

import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const phone = Size(400, 800);
  // A device with a top status bar, a bottom gesture pill, and side cutouts.
  const insets = EdgeInsets.only(top: 50, bottom: 34, left: 20, right: 16);

  final destinations = [
    for (final v in SmartView.values)
      ShellDestination(
        icon: v.icon,
        selectedIcon: v.selectedIcon,
        label: v.label,
      ),
  ];

  Widget marker(String key) => SizedBox.expand(
    key: Key(key),
    child: const ColoredBox(color: Colors.teal),
  );

  Future<GlobalKey<ScaffoldState>> pumpChrome(
    WidgetTester tester, {
    EdgeInsets padding = insets,
    Widget? detail,
  }) async {
    final scaffoldKey = GlobalKey<ScaffoldState>();
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: phone, padding: padding),
          child: ListDetailScaffold(
            scaffoldKey: scaffoldKey,
            sidebar: marker('sidebar'),
            destinations: destinations,
            selectedIndex: SmartView.all.index,
            onDestinationSelected: (_) {},
            title: 'All Tasks',
            onNewTask: () {},
            list: marker('list'),
            detail: detail,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return scaffoldKey;
  }

  testWidgets('the app bar clears the top status bar', (tester) async {
    await pumpChrome(tester);
    // The hamburger (auto-added because a drawer is present) sits below the
    // status bar, not under it.
    final hamburger = tester.getRect(find.byTooltip('Open navigation menu'));
    expect(
      hamburger.top,
      greaterThanOrEqualTo(insets.top),
      reason: 'app-bar content is pushed past the status bar',
    );
  });

  testWidgets('the list body clears the side insets', (tester) async {
    await pumpChrome(tester);
    final list = tester.getRect(find.byKey(const Key('list')));
    expect(list.left, greaterThanOrEqualTo(insets.left));
    expect(list.right, lessThanOrEqualTo(phone.width - insets.right));
  });

  testWidgets('the FAB floats above the bottom pill and off the right edge', (
    tester,
  ) async {
    await pumpChrome(tester);
    final fab = tester.getRect(find.byType(FloatingActionButton));
    expect(
      fab.bottom,
      lessThanOrEqualTo(phone.height - insets.bottom),
      reason: 'above the bottom gesture pill',
    );
    expect(
      fab.right,
      lessThanOrEqualTo(phone.width - insets.right),
      reason: 'off a right-side cutout',
    );
  });

  testWidgets('the slide-in drawer is inset from the top, bottom, and left', (
    tester,
  ) async {
    final key = await pumpChrome(tester);
    key.currentState!.openDrawer();
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(const Key('sidebar')));
    expect(panel.top, greaterThanOrEqualTo(insets.top), reason: 'below notch');
    expect(panel.left, greaterThanOrEqualTo(insets.left), reason: 'off left');
    expect(
      panel.bottom,
      lessThanOrEqualTo(phone.height - insets.bottom),
      reason: 'above the gesture pill',
    );
  });

  testWidgets('the full-screen detail header clears the status bar', (
    tester,
  ) async {
    await pumpChrome(tester, detail: marker('detail'));
    // The detail covers the screen; its top edge is inset past the status bar.
    final panel = tester.getRect(find.byKey(const Key('detail')));
    expect(panel.top, greaterThanOrEqualTo(insets.top));
  });

  testWidgets(
    'an open drawer does not block the app-level back (rotation-safe)',
    (tester) async {
      // Regression: caching "drawer open" to intercept back deadens the button
      // after a phone rotates into the expanded layout mid-open (the compact
      // Scaffold, and the framework's drawer back-handler, unmount). The app
      // PopScope must therefore never block on the drawer.
      final key = await pumpChrome(tester);
      key.currentState!.openDrawer();
      await tester.pumpAndSettle();

      final popScope =
          tester.firstWidget(find.byWidgetPredicate((w) => w is PopScope))
              as PopScope;
      expect(
        popScope.canPop,
        isTrue,
        reason: 'the drawer is dismissed by the framework, not a cached flag',
      );
    },
  );

  testWidgets(
    'every inset has an explicit fallback (un-notched device still breathes)',
    (tester) async {
      // No MediaQuery padding at all — a legacy / un-notched device.
      final key = await pumpChrome(tester, padding: EdgeInsets.zero);
      key.currentState!.openDrawer();
      await tester.pumpAndSettle();

      final panel = tester.getRect(find.byKey(const Key('sidebar')));
      expect(
        panel.top,
        greaterThanOrEqualTo(8),
        reason: 'the drawer keeps its minimum breathing room with zero insets',
      );
    },
  );
}
