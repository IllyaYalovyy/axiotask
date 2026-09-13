// OnboardingIntro — the first-launch welcome card (ui/onboarding.dart). Asserts
// what the user SEES: the welcome copy, the dismiss button fires its callback,
// and — the F19 #198 fix — the card SCROLLS instead of overflowing when the
// system text scale is cranked to 2.0 on a short viewport.

import 'package:axiotask/src/ui/onboarding.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester, {
  required VoidCallback onDismiss,
  TextScaler textScaler = TextScaler.noScaling,
  Size size = const Size(400, 800),
  TargetPlatform platform = TargetPlatform.linux,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      key: ValueKey(platform),
      theme: ThemeData(platform: platform),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: textScaler),
        child: OnboardingIntro(onDismiss: onDismiss),
      ),
    ),
  );
}

void main() {
  testWidgets('names the visible capture entry point for each pointer class', (
    tester,
  ) async {
    // The failure this prevents: the first-run phone welcome directs a new
    // user to an inline field that is hidden until they tap the FAB.
    await _pump(tester, onDismiss: () {}, platform: TargetPlatform.android);
    expect(find.textContaining('Tap + to add a task.'), findsOneWidget);
    expect(find.textContaining('“tomorrow”'), findsOneWidget);
    expect(find.textContaining('quick-add field'), findsNothing);

    await _pump(tester, onDismiss: () {}, platform: TargetPlatform.linux);
    expect(find.textContaining('quick-add field'), findsOneWidget);
    expect(find.textContaining('“tomorrow”'), findsOneWidget);
    expect(find.textContaining('Tap + to add a task.'), findsNothing);
  });

  testWidgets('renders the welcome copy and dismisses on the button', (
    tester,
  ) async {
    var dismissed = 0;
    await _pump(tester, onDismiss: () => dismissed++);
    expect(find.text('Welcome to axiotask'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-dismiss')));
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets(
    'scrolls instead of overflowing at 2.0 text scale on a short viewport '
    '(F19 #198)',
    (tester) async {
      // The failure this prevents: at a large system font the fixed card
      // overflows a short phone viewport and throws a RenderFlex overflow (which
      // fails this render). It must scroll — and the dismiss button must stay
      // reachable by scrolling to it.
      var dismissed = 0;
      await _pump(
        tester,
        onDismiss: () => dismissed++,
        textScaler: const TextScaler.linear(2.0),
        size: const Size(360, 360), // deliberately short — forces the overflow
      );

      // No overflow was thrown (the render completed); a scroll view is present.
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsOneWidget);

      // The dismiss button is reachable by scrolling, and still fires.
      final dismiss = find.byKey(const Key('onboarding-dismiss'));
      await tester.scrollUntilVisible(dismiss, 100);
      await tester.tap(dismiss);
      await tester.pump();
      expect(dismissed, 1);
    },
  );
}
