// #249 — what the LIST does while a create lands on Google.
//
// The placement contract itself is pinned in test/sync/create_placement_test.dart
// (the order the display pipeline derives, before and after the sync). The risk
// that only exists above that layer is the one this file covers: a row whose
// slot changes is a row the list tears down and rebuilds. Its [State] — the
// inline-edit controller, the completion animation, the pressed/hover state —
// goes with it, and the user sees rows blink and re-enter while they are still
// looking at the task they just typed.
//
// So this pumps the REAL [TaskListView] over a REAL store, commands and sync
// engine against the fake Google, creates tasks the way an offline session does,
// then runs the sync that lands them and asserts that every row on screen is
// the SAME State object it was before — nothing re-inserted.
//
// #251 gave those rows an ARRIVAL motion, which sharpens the same contract: a
// row whose identity survived the landing must not replay its entrance either.
// Learning a remote id is not a task joining the list, and a list that shivered
// three to five seconds after every create would be worse than the silence it
// replaced.

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/ui/list_motion.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'toast_harness.dart' show wrapWithToast;

final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

/// The row titles the list currently renders, top to bottom.
List<String> _rowTitles(WidgetTester tester) => tester
    .widgetList<TaskRow>(find.byType(TaskRow))
    .map((r) => r.title)
    .toList();

/// The live [State] behind the row titled [title] — the object that dies if the
/// list re-inserts the row instead of moving it.
State _rowState(WidgetTester tester, String title) =>
    tester.state(find.widgetWithText(TaskRow, title));

/// The rendered height of the slot holding the row titled [title]. A row that is
/// growing into place (#251) is shorter than one that is simply there.
double _slotHeight(WidgetTester tester, String title) => tester
    .getSize(
      find
          .ancestor(
            of: find.widgetWithText(TaskRow, title),
            matching: find.byType(RowMotion),
          )
          .first,
    )
    .height;

/// Let the store's stream deliver and the list rebuild, without ever settling
/// on the quick-add field's cursor timer.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('the sync that lands offline creates neither re-orders nor '
      're-inserts the rows on screen', (tester) async {
    final client = FakeTasksApi();
    client.seedList('L1', 'Inbox');
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final store = Store(db);
    final engine = SyncEngine.withPush(client, store, true);

    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await withClock(_clock, () async {
      // A first run adopts the server's list; then one task is created AND
      // synced, so it carries the position Google itself assigned.
      await engine.run();
      final listId = (await store.allLists()).single.list.id;
      final container = ProviderContainer(
        overrides: [storeProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container
          .read(commandsProvider)
          .createTask(listId: listId, title: 'kept');
      await engine.run();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => wrapWithToast(context, child),
            home: Scaffold(
              body: TaskListView(
                viewId: listId,
                selectedTaskId: null,
                onOpenTask: (_) {},
                onOpenTaskNotes: (_) {},
              ),
            ),
          ),
        ),
      );
      await _flush(tester);
      expect(_rowTitles(tester), ['kept']);

      // An offline burst: three creates, none of them pushed yet.
      for (final title in ['one', 'two', 'three']) {
        await container
            .read(commandsProvider)
            .createTask(listId: listId, title: title);
      }
      await _flush(tester);
      // Let the three arrivals finish, so what follows measures the landing and
      // nothing else.
      await tester.pump(listMotionWindow);

      final before = _rowTitles(tester);
      final states = {for (final t in before) t: _rowState(tester, t)};
      final heights = {for (final t in before) t: _slotHeight(tester, t)};
      expect(before, [
        'three',
        'two',
        'one',
        'kept',
      ], reason: 'each create goes on top of the one before it');

      // Back online: the pushes land, every row learns its remote id and adopts
      // the position Google assigned it.
      await engine.run();
      await _flush(tester);

      expect(
        _rowTitles(tester),
        before,
        reason: 'landing the creates must not re-order the list',
      );
      for (final title in before) {
        expect(
          _rowState(tester, title),
          same(states[title]),
          reason: '"$title" was re-inserted instead of staying put',
        );
        // …and it did not replay its arrival either (#251): the row is exactly
        // as tall as it was, so nothing is growing back into place.
        expect(
          _slotHeight(tester, title),
          heights[title],
          reason: '"$title" re-ran its enter when the create landed',
        );
      }
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'the landing left no row motion running',
      );
    });
  });
}
