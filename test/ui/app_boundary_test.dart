// The app-level UI error boundary (T7.8): a render failure must not vanish into
// a bare gray Flutter error box (release builds have no console) — it shows a
// human, self-contained "axiotask hit a UI error" screen with the detail as
// text. Port of the reference's AppBoundary + errorBoundary suites.

import 'package:axiotask/src/ui/app_boundary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppErrorView', () {
    testWidgets('shows a human heading and the error detail verbatim', (
      tester,
    ) async {
      await tester.pumpWidget(
        const AppErrorView(message: 'render exploded at line 42'),
      );

      expect(find.textContaining('axiotask hit a UI error'), findsOneWidget);
      expect(find.textContaining('render exploded at line 42'), findsOneWidget);
    });

    testWidgets(
      'renders a message containing markup as text, never as markup',
      (tester) async {
        // A message that happens to contain angle-bracket markup is DATA — it
        // renders as literal text, so a nasty error string can never smuggle
        // structure into the screen.
        const nasty = "open db: <script>alert('x')</script>";
        await tester.pumpWidget(const AppErrorView(message: nasty));
        expect(find.text(nasty), findsOneWidget);
      },
    );

    testWidgets('offers a Retry affordance only when a reset is possible', (
      tester,
    ) async {
      var retried = 0;
      await tester.pumpWidget(
        AppErrorView(message: 'boom', onRetry: () => retried++),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();
      expect(retried, 1);
    });

    testWidgets('shows no Retry button when there is nothing to reset', (
      tester,
    ) async {
      await tester.pumpWidget(const AppErrorView(message: 'boom'));
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('installAppErrorBoundary', () {
    testWidgets('a widget that throws during build renders the friendly screen', (
      tester,
    ) async {
      // ErrorWidget.builder must be restored WITHIN the test body — the test
      // framework asserts it is left unset, before any tearDown runs.
      final original = ErrorWidget.builder;
      installAppErrorBoundary();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                throw StateError('render exploded');
              },
            ),
          ),
        );

        // The framework caught the build error…
        expect(tester.takeException(), isA<StateError>());
        // …and the boundary showed the human screen with the cause, not a gray box.
        expect(find.textContaining('axiotask hit a UI error'), findsOneWidget);
        expect(find.textContaining('render exploded'), findsOneWidget);
      } finally {
        ErrorWidget.builder = original;
      }
    });
  });
}
