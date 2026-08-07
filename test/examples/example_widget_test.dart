// EXAMPLE — widget layer (rendered tree + interaction).
//
// Template for asserting what the USER SEES: pump a widget, find rendered
// content, drive a gesture, assert the tree changed. The subject is the app
// root, so this also covers the ProviderScope wiring in main.dart (the app
// must mount inside a ProviderScope — enforced statically by riverpod_lint and
// verified here at runtime).
import 'package:axiotask/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app renders inside a ProviderScope and reacts to a tap', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: MyApp()));

    // The app root is Riverpod-scoped (covers main.dart's runApp wiring).
    expect(find.byType(ProviderScope), findsOneWidget);

    // Starts at 0; the incremented value is NOT yet on screen (non-happy
    // guard against a false-positive that would pass whatever the state).
    expect(find.text('0'), findsOneWidget);
    expect(find.text('1'), findsNothing);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsOneWidget);
  });
}
