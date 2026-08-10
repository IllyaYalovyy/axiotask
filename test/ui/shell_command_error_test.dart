// End-to-end wiring (T7.8): a list mutation that fails in the REAL app shell
// surfaces a redacted error toast in the root toast overlay — not an unhandled
// exception, and not a message leaking internals. Proves the shell routes its
// list callbacks through the guarded seam and that the overlay is mounted in
// the running AxiotaskApp.

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'detail_harness.dart' show FakeBackend;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_shell_err'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets(
    'a failing "New list" shows a redacted error toast above the shell',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // FakeBackend.createList throws — the failure path under test.
      final fake = FakeBackend(const <StoredTask>[]);
      addTearDown(fake.dispose);
      final store = PrefsStore(File(p.join(tmp.path, 'prefs.json')))
        ..save(const Prefs(onboardingSeen: true));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(store.load()),
            prefsStoreProvider.overrideWithValue(store),
            commandsProvider.overrideWithValue(fake),
            allTasksProvider.overrideWith((ref) => fake.tasksStream),
            listsProvider.overrideWith(
              (ref) => const Stream<List<StoredTaskList>>.empty(),
            ),
          ],
          child: const AxiotaskApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Open the New-list dialog, name it, and create — the create throws.
      await tester.tap(find.byTooltip('New list'));
      await tester.pumpAndSettle();
      // Scope to the dialog's own field (the list pane also has a quick-add
      // TextField that would otherwise be matched first).
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('new-list-dialog')),
          matching: find.byType(TextField),
        ),
        'Groceries',
      );
      await tester.tap(find.byKey(const Key('new-list-create')));
      await tester.pumpAndSettle();

      // The redacted family sentence surfaced — internals never leaked.
      expect(find.textContaining("Couldn't update your lists"), findsOneWidget);
      expect(find.textContaining('UnimplementedError'), findsNothing);

      // Let the 5s auto-dismiss timer fire so the test ends clean.
      await tester.pump(const Duration(seconds: 6));
    },
  );
}
