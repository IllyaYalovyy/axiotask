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
    await tester.pumpWidget(
      ProviderScope(
        // The default "all" view renders the store-backed list; empty streams
        // let the root render without a database.
        overrides: [
          allTasksProvider.overrideWith((ref) => const Stream.empty()),
          listsProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The app root is Riverpod-scoped and router-driven (covers runApp wiring).
    expect(find.byType(ProviderScope), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(ListDetailScaffold), findsOneWidget);
    // The "All Tasks" nav destination label renders (the pane itself is the
    // real task list now, showing its empty state).
    expect(find.text('All Tasks'), findsWidgets);
  });

  testWidgets('a dev instance still renders the shell', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          instancePrefixProvider.overrideWithValue('dev'),
          allTasksProvider.overrideWith((ref) => const Stream.empty()),
          listsProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ListDetailScaffold), findsOneWidget);
  });
}
