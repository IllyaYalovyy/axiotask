// Port of `show_startup_error`: when the store cannot open (a `WipeAborted`
// fail-open, or any open error) the app must surface WHY instead of vanishing
// or hanging on a dead frame. These assert what the user SEES on that screen.

import 'package:axiotask/src/app/startup_error.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the fatal message verbatim to the user', (tester) async {
    await tester.pumpWidget(
      const StartupErrorApp(
        message: 'database wipe aborted: refusing to destroy 412 tasks',
      ),
    );

    expect(
      find.text('database wipe aborted: refusing to destroy 412 tasks'),
      findsOneWidget,
    );
  });

  testWidgets('shows a clear "could not start" heading and an error glyph', (
    tester,
  ) async {
    await tester.pumpWidget(const StartupErrorApp(message: 'boom'));

    // A human-readable headline so the window is obviously an error state,
    // not a half-loaded app.
    expect(
      find.textContaining('could not start', findRichText: true),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    // And it renders inside a real MaterialApp (this IS the whole app now).
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('a multi-line message with quotes renders safely', (
    tester,
  ) async {
    const nasty = 'open failed:\n"C:\\weird\\path" — <disk full>';
    await tester.pumpWidget(const StartupErrorApp(message: nasty));
    expect(find.textContaining('disk full'), findsOneWidget);
  });
}
