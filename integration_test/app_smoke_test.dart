// The real-engine smoke suite (T2.5 / MIGRATION-PLAN §5).
//
// The 400-plus widget/store tests run in the host VM against fakes and an
// in-memory DB; a green VM run does NOT prove the app boots on the actual Linux
// desktop engine — window/plugin channels, a file-backed sqlite open, the
// go_router shell, and a clean shutdown only exist there. This suite is that
// gate. The verify.sh integration stage runs it headless under xvfb whenever
// product code changes.
//
// It exercises the whole walking skeleton end to end through the REAL bootstrap
// and the REAL widget tree on a throwaway data dir (never production — an
// isolated temp XDG root, per the isolate-from-production rule):
//
//   launch → DB opens & seeds "My Tasks" → All-Tasks list renders →
//   CRUD round-trip (create via quick-add, read back from the DB, complete it,
//   delete it) → clean exit (the DB closes without error).
//
// Assertions read what the USER SEES (rendered rows) and what PERSISTS (rows in
// the opened database) — never "a method was called".

import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/bootstrap.dart';
import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory dataBase;
  late Directory configBase;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('axiotask_smoke');
    dataBase = Directory(p.join(tmp.path, 'data'))..createSync();
    configBase = Directory(p.join(tmp.path, 'config'))..createSync();
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Bounded pump — never pumpAndSettle: the quick-add TextField owns a
  /// cursor-blink timer that never settles once focused. A couple of frames plus
  /// a real delay is enough for a drift stream to deliver its next snapshot.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('launch → DB opens, seeds "My Tasks", All-Tasks list renders', (
    tester,
  ) async {
    final result = await bootstrap(
      dataBase: dataBase,
      configBase: configBase,
      env: const {},
    );
    expect(result, isA<BootstrapReady>(), reason: 'the app must boot');
    final ready = result as BootstrapReady;

    // DB opened and seeded the default list — the source of truth the UI reads.
    final store = Store(ready.database);
    expect((await store.allLists()).single.list.title, 'My Tasks');

    await tester.pumpWidget(
      ProviderScope(overrides: ready.overrides, child: const AxiotaskApp()),
    );
    await settle(tester);

    // The real engine rendered the app and the empty All-Tasks view.
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('No tasks yet'), findsOneWidget);

    // Clean exit: the store closes without throwing (asserted, not tear-down'd).
    await ready.database.close();
  });

  testWidgets('CRUD round-trip: create → read → complete → delete', (
    tester,
  ) async {
    final ready =
        await bootstrap(
              dataBase: dataBase,
              configBase: configBase,
              env: const {},
            )
            as BootstrapReady;
    final store = Store(ready.database);

    await tester.pumpWidget(
      ProviderScope(overrides: ready.overrides, child: const AxiotaskApp()),
    );
    await settle(tester);

    // ── CREATE ── through the real quick-add bar.
    await tester.enterText(find.byType(TextField), 'buy milk');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // READ (user-visible): the row rendered in the list.
    expect(find.widgetWithText(TaskRow, 'buy milk'), findsOneWidget);
    // READ (persisted): exactly one task, in the seeded list, still open.
    final rows = await store.allTasks();
    expect(rows, hasLength(1));
    final created = rows.single;
    expect(created.task.title, 'buy milk');
    expect(created.task.status, TaskStatus.needsAction);

    // ── UPDATE ── complete it by tapping its checkbox (the row's — the list
    // toolbar now also has a "Show completed" checkbox).
    await tester.tap(
      find.descendant(of: find.byType(TaskRow), matching: find.byType(Checkbox)),
    );
    await settle(tester);
    // Persisted as completed …
    expect(
      (await store.findTaskAny(created.task.id))!.task.status,
      TaskStatus.completed,
    );
    // … and gone from the open list (show-completed defaults off).
    expect(find.widgetWithText(TaskRow, 'buy milk'), findsNothing);

    // ── DELETE ── through the same commands wiring the UI uses.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AxiotaskApp)),
    );
    final Commands commands = container.read(commandsProvider);
    await commands.deleteTask(created.task.id);
    await settle(tester);

    // Round-trip complete: the task is gone from the visible store.
    expect(await store.allTasks(), isEmpty);
    expect(find.byType(TaskRow), findsNothing);

    // Clean exit.
    await ready.database.close();
  });
}
