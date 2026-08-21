import 'package:axiotask/src/app/visual_tokens.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/features/onboarding/onboarding_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'PAR-UX-001/002 onboarding explains truth without claiming sync',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: axiotaskTheme(Brightness.light, DensityPreference.standard),
          home: const OnboardingView(onDismiss: _dismiss),
        ),
      );

      expect(find.text('Connect to Google Tasks'), findsOneWidget);
      expect(find.text('Sync stays truthful'), findsOneWidget);
      expect(find.text('Work through an outage'), findsOneWidget);
      expect(find.text('Capture without breaking flow'), findsOneWidget);
      expect(find.text('Recover safely'), findsOneWidget);
      expect(
        find.textContaining('Connected does not mean synced'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Cached tasks stay available'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Welcome to Axiotask onboarding'),
        findsOneWidget,
      );
      expect(find.text('Synced'), findsNothing);
    },
  );

  testWidgets(
    'onboarding is readable at large text scale on narrow and wide layouts',
    (tester) async {
      for (final width in <double>[390, 1280]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                accessibleNavigation: true,
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: const OnboardingView(onDismiss: _dismiss),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull, reason: 'width $width');
        expect(find.byKey(const Key('onboarding-scroll')), findsOneWidget);
        expect(find.bySemanticsLabel('Finish onboarding'), findsOneWidget);
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );

  testWidgets('onboarding finish has keyboard and touch parity', (
    tester,
  ) async {
    var dismissed = 0;
    await tester.pumpWidget(
      MaterialApp(home: OnboardingView(onDismiss: () async => dismissed += 1)),
    );

    final finish = find.bySemanticsLabel('Finish onboarding');
    await tester.scrollUntilVisible(finish, 160);
    await tester.tap(finish);
    await tester.pump();
    expect(dismissed, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(dismissed, 2);
  });
}

Future<void> _dismiss() async {}
