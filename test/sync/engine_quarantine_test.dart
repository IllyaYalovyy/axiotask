// The poison-row quarantine (#270) as the ENGINE reports it.
//
// A row the server rejects permanently is pushed at most [kPoisonRejectCap]
// runs running; after that its push is HELD and the outcome names it, because
// "will retry" has stopped being true and only the user editing the row can
// release it. `SyncScheduler` turns `SyncOutcome.quarantined` into the status
// line that tells the user WHICH change is stuck, so the engine getting the
// cap boundary or the naming wrong is a user-visible lie — either a request
// per cadence tick forever, or a stuck change nothing ever mentions.
//
// The scheduler-level test for #270 lives in `test/app/sync_resilience_test`
// and reads the rendered status; this one pins the engine's own contract, on
// the run counts and the outcome fields the scheduler is derived from: the
// budget is spent to the cap and not past it, the row is named on the run that
// exhausts it AND on every held run after, and an edit is the release.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/attention.dart' show QuarantinedRow;
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/poison.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_fixture.dart';

/// Re-stage the row the server calls [id] as a local rename that happened at
/// [at]. `local_updated` is the streak's identity: the SAME value across runs
/// is what makes rejections consecutive, and a NEW one is the release.
Future<void> stageEditAt(
  Store store,
  String id,
  String title,
  String at,
) async {
  final r = (await findByAnyId(store, id))!;
  await store.upsertTask(
    StoredTask(
      task: r.task.copyWith(title: title),
      listId: r.listId,
      syncState: SyncState.dirty,
      localUpdated: at,
      pendingOp: 'update',
      remoteId: r.remoteId,
    ),
  );
}

void main() {
  test('a permanently rejected row is held at the cap and stays named '
      'until it is edited', () async {
    final client = FakeTasksApi();
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final store = Store(db);
    // The registry is what carries the streak ACROSS runs; each run gets its
    // own engine, exactly as the scheduler builds one per tick.
    final poison = PoisonRegistry();
    Future<SyncOutcome> runSync() =>
        SyncEngine.withPush(client, store, true, poison: poison).run();
    Future<String> serverTitle() async =>
        (await client.listTasks('L1')).items.single.title;

    await seedSyncedList(client, store, 'L1', 'Inbox');
    client.seedTask('L1', 'T1', 'first', '00000000000001');
    await runSync();
    await stageEditAt(store, 'T1', 'Poison renamed', '2026-01-02T00:00:00Z');

    // Inside the budget: every run spends a request and reports an error the
    // status still describes as retrying.
    for (var run = 1; run < kPoisonRejectCap; run++) {
      client.failNextForId(
        Method.patchTask,
        'T1',
        () => const OtherApiError('400 invalid value'),
      );
      final out = await runSync();
      expect(
        client.callCount(Method.patchTask),
        run,
        reason: 'run $run is inside the budget and must still try the push',
      );
      expect(out.errors, 1, reason: 'run $run reports a retryable failure');
      expect(
        out.quarantined,
        isEmpty,
        reason: 'run $run has not exhausted the budget, so nothing is stuck',
      );
    }

    // The rejection AT the cap is the one that quarantines: the row is named
    // instead of counted, because it is no longer going to be retried.
    client.failNextForId(
      Method.patchTask,
      'T1',
      () => const OtherApiError('400 invalid value'),
    );
    final capped = await runSync();
    expect(client.callCount(Method.patchTask), kPoisonRejectCap);
    final localId = (await findByAnyId(store, 'T1'))!.task.id;
    expect(
      capped.quarantined,
      [QuarantinedRow(id: localId, title: 'Poison renamed')],
      reason:
          'the run that exhausts the budget names the stuck change AND says '
          'which row it is, so the "Needs attention" view can act on it (#296)',
    );
    expect(
      capped.errors,
      0,
      reason: 'a held row is not one of the failures that will retry',
    );

    // The next run arms NO fault — a push here would SUCCEED and hide the
    // regression — and the held row must still be named.
    final held = await runSync();
    expect(
      client.callCount(Method.patchTask),
      kPoisonRejectCap,
      reason: 'a quarantined row must not be pushed again',
    );
    expect(held.quarantined, [
      QuarantinedRow(id: localId, title: 'Poison renamed'),
    ], reason: 'the status keeps naming it for as long as it is held');
    expect(held.errors, 0);
    expect(
      await serverTitle(),
      'first',
      reason: 'nothing the server rejected ever landed',
    );
    expect(
      (await findByAnyId(store, 'T1'))!.task.title,
      'Poison renamed',
      reason: 'the edit the user made is still theirs to fix',
    );

    // Editing the row is the release: a fresh budget, and the push lands.
    await stageEditAt(store, 'T1', 'Poison fixed', '2026-01-03T00:00:00Z');
    final released = await runSync();
    expect(
      client.callCount(Method.patchTask),
      kPoisonRejectCap + 1,
      reason: 'an edited row gets a fresh push budget',
    );
    expect(
      released.quarantined,
      isEmpty,
      reason: 'nothing is stuck any more, so nothing is named',
    );
    expect(await serverTitle(), 'Poison fixed');
  });
}
