// #249 — where a freshly created row SITS, before and after the sync that
// lands it on Google.
//
// The user-reported defect: create a task and, once the debounced push
// completes 3-5s later, the list re-shuffles — the new row (and sometimes its
// untouched neighbours) jumps to a different position.
//
// The cause these tests pin: Google places an `insert` with no `previous` at
// the TOP of its list and hands it a 20-digit descending position
// (`!18446744073709551611` — `u64::MAX - n`). The local placeholder
// [nextLocalPosition] mints while the row is still un-pushed has to sort above
// those, or local placement disagrees with the placement the sync then adopts
// and the list visibly re-orders under the user's hands.
//
// Every test here drives the REAL command service, the REAL sync engine and the
// fake Google, then reads the order back through the REAL display pipeline
// ([visibleTasksForView]) — the same function the list view builds its rows
// from — so what is asserted is the order the user SEES, before and after.
//
// The "newest pin" is deliberately NOT applied: it holds only the single
// most-recent row, only while that view stays mounted. The order asserted here
// is what the list shows the moment the pin is gone — a view switch, a restart,
// a bulk/offline batch — and what every OTHER row shows all along.

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/model/task_view.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fixed clock: the date windows the smart views compare against, and the
/// monotonic placeholder tick, both read it.
final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

/// Today, as the quick-add would write it on [_clock].
const _today = '2026-06-15';

/// One app instance — real store, real commands, real engine — over a fake
/// Google that starts out holding [remoteLists] as already-synced lists.
class Rig {
  Rig._(this.client, this.store, this.commands, this.engine, this.listIds);

  final FakeTasksApi client;
  final Store store;
  final Commands commands;
  final SyncEngine engine;

  /// LOCAL list id per seeded remote list id.
  final Map<String, String> listIds;

  static Future<Rig> open({List<String> remoteLists = const ['L1']}) async {
    final client = FakeTasksApi();
    for (final id in remoteLists) {
      client.seedList(id, id);
    }
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final store = Store(db);
    var n = 0;
    String newId() => 'gen-${++n}';
    final engine = SyncEngine.withPush(client, store, true, newId: newId);
    // The first run adopts the server's lists into local rows.
    await engine.run();
    final ids = {
      for (final l in await store.allLists()) l.remoteId!: l.list.id,
    };
    return Rig._(client, store, Commands(store, newId: newId), engine, ids);
  }

  /// Create [title] and let the sync that lands it run, so the row ends up
  /// carrying the position GOOGLE assigned it — exactly like a row created in
  /// an earlier session.
  Future<void> createAndSync(
    String title, {
    String list = 'L1',
    String? due,
  }) async {
    await commands.createTask(listId: listIds[list]!, title: title, due: due);
    await engine.run();
  }

  /// Create [title] and leave it un-pushed (the 3-5s window before the
  /// debounced sync fires — and the whole of an offline session).
  Future<StoredTask> create(String title, {String list = 'L1', String? due}) =>
      commands.createTask(listId: listIds[list]!, title: title, due: due);

  /// The titles the list view would render for [viewId], top to bottom.
  Future<List<String>> order(
    String viewId, {
    SortMode sort = SortMode.manual,
  }) async {
    final all = await store.allTasks();
    return visibleTasksForView(
      allTasks: all,
      viewId: viewId,
      excludedLists: const {},
      showCompleted: false,
      sort: sort,
      window: dateWindowNow(),
    ).map((t) => t.task.title).toList();
  }
}

void main() {
  group('a create sits where Google will put it', () {
    // The plain case: a list whose rows were themselves created in the app, so
    // they carry Google's own top-insert positions. RED before the fix: the new
    // row renders LAST (`!9223…` sorts after every `!1844…`) and the sync that
    // adopts Google's position teleports it to the top.
    test(
      'concrete list, My order: the sync does not move the new row',
      () async {
        await withClock(_clock, () async {
          final rig = await Rig.open();
          await rig.createAndSync('older');
          await rig.createAndSync('newer');

          await rig.create('fresh');
          final l1 = rig.listIds['L1']!;
          final before = await rig.order(l1);
          await rig.engine.run();
          final after = await rig.order(l1);

          expect(after, [
            'fresh',
            'newer',
            'older',
          ], reason: 'Google inserts a task with no `previous` at the top');
          expect(
            before,
            after,
            reason:
                'the sync that lands the create must not re-shuffle the list',
          );
        });
      },
    );

    // Focus interleaves several lists in one "my order" ordering, so a fresh
    // row is compared against positions minted in a DIFFERENT list — the
    // context the issue calls out first.
    test('Focus view: the sync does not move the new row', () async {
      await withClock(_clock, () async {
        final rig = await Rig.open(remoteLists: ['L1', 'L2']);
        await rig.createAndSync('other list', list: 'L2', due: _today);
        await rig.createAndSync('same list', list: 'L1', due: _today);

        await rig.create('fresh', due: _today);
        final before = await rig.order('focus');
        await rig.engine.run();
        final after = await rig.order('focus');

        expect(after, ['fresh', 'same list', 'other list']);
        expect(
          before,
          after,
          reason: 'a create made from Focus must not jump once it lands',
        );
      });
    });

    // A due-sorted view ranks by date first, but rows sharing a date fall
    // through to the POSITION tiebreak — so the same placeholder decides the
    // order inside every date bucket.
    test('due-sorted view: the sync does not move the new row', () async {
      await withClock(_clock, () async {
        final rig = await Rig.open();
        await rig.createAndSync('earlier', due: '2026-06-14');
        await rig.createAndSync('same day', due: _today);

        await rig.create('fresh', due: _today);
        final l1 = rig.listIds['L1']!;
        final before = await rig.order(l1, sort: SortMode.due);
        await rig.engine.run();
        final after = await rig.order(l1, sort: SortMode.due);

        expect(after, [
          'earlier',
          'fresh',
          'same day',
        ], reason: 'within one due date the newest task is on top');
        expect(before, after, reason: 'the sync must not re-rank the bucket');
      });
    });

    // The issue's explicit case: making a SECOND task must not drag the first
    // one around when the second one's push lands.
    test('a second create does not move the first', () async {
      await withClock(_clock, () async {
        final rig = await Rig.open();
        await rig.createAndSync('first');

        await rig.create('second');
        final l1 = rig.listIds['L1']!;
        final before = await rig.order(l1);
        await rig.engine.run();
        final after = await rig.order(l1);

        expect(after, ['second', 'first']);
        expect(
          before,
          after,
          reason: 'landing the second create must not move the first row',
        );
      });
    });

    // Non-happy path: OFFLINE. Every create queues un-pushed and a single later
    // run lands them all — the shape a bulk add and a plane ride both take.
    // This is where the defect is visible with no newest-pin masking anything:
    // the untouched neighbour 'kept' is dragged from the top to the bottom.
    test('offline creates keep their order — and their neighbour — when the '
        'sync finally runs', () async {
      await withClock(_clock, () async {
        final rig = await Rig.open();
        await rig.createAndSync('kept');

        // Offline: three creates, no sync in between.
        await rig.create('one');
        await rig.create('two');
        await rig.create('three');

        final l1 = rig.listIds['L1']!;
        final before = await rig.order(l1);
        await rig.engine.run();
        final after = await rig.order(l1);

        expect(after, [
          'three',
          'two',
          'one',
          'kept',
        ], reason: 'each create went on top of the one before it');
        expect(
          before,
          after,
          reason: 'coming back online must not re-shuffle the backlog',
        );
      });
    });
  });
}
