// EXAMPLE — widget layer (rendered tree + interaction).
//
// Template for asserting what the USER SEES: pump a widget, find rendered
// content, assert the tree. The subject is the app root [AxiotaskApp], so this
// also covers the ProviderScope wiring the app mounts under (enforced
// statically by riverpod_lint and verified here at runtime). The app root now
// renders the adaptive shell via go_router; every provider it reads has a safe
// default, so it pumps with no overrides.
import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('root renders the shell inside a ProviderScope', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AxiotaskApp()));
    await tester.pumpAndSettle();

    // The app root is Riverpod-scoped and router-driven (covers runApp wiring).
    expect(find.byType(ProviderScope), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(ListDetailScaffold), findsOneWidget);
    // The default "all" view renders its placeholder pane.
    expect(find.text('All Tasks'), findsWidgets);
  });

  testWidgets('a dev instance still renders the shell', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [instancePrefixProvider.overrideWithValue('dev')],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ListDetailScaffold), findsOneWidget);
  });
}
