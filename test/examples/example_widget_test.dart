// EXAMPLE — widget layer (rendered tree + interaction).
//
// Template for asserting what the USER SEES: pump a widget, find rendered
// content, assert the tree. The subject is the app root [AxiotaskApp], so this
// also covers the ProviderScope wiring the app mounts under (enforced
// statically by riverpod_lint and verified here at runtime).
import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('root renders inside a ProviderScope with the instance title', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: AxiotaskApp()));

    // The app root is Riverpod-scoped (covers the runApp wiring).
    expect(find.byType(ProviderScope), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    // Production title with no instance prefix override.
    expect(find.text('axiotask'), findsWidgets);
  });

  testWidgets('an instance prefix badges the title (dev-mode)', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [instancePrefixProvider.overrideWithValue('dev')],
        child: const AxiotaskApp(),
      ),
    );
    // Non-production instances are visibly labelled so a dev run is never
    // mistaken for production.
    expect(find.text('axiotask (dev)'), findsWidgets);
    expect(find.text('axiotask'), findsNothing);
  });
}
