// #268 — every engine write that lands AFTER an `await` on the network is a
// write against a snapshot the user may have edited in the meantime.
//
// These are the RACE tests, one per site the guard was missing. Each drives a
// real sync run against the fake server and interleaves a LOCAL store edit at
// the exact moment the engine is waiting on a response — through the fake's
// on-call hook (awaited, so the interleaving is deterministic rather than a
// microtask coin-flip) or, where the gap is between the engine's own read and
// its own write, through a store that fires the edit inside that gap.
//
// Every assertion is on the state the two sides converge to: the row the user
// is left holding, and the task the fake server holds. What the engine called
// is never asserted.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_fixture.dart';

const _t0 = '2026-06-01T00:00:00Z';
const _tEdit = '2026-06-02T00:00:00Z';
const _tRace = '2026-06-03T00:00:00Z';

/// A fresh engine over an in-memory store and fake API, torn down with the test.
/// [store] lets a test substitute a [Store] subclass that interleaves an edit.
Future<(FakeTasksApi, SyncEngine)> engine({
  bool push = false,
  Store Function(AppDatabase db)? store,
}) async {
  final client = FakeTasksApi();
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  final s = store == null ? Store(db) : store(db);
  final eng = push
      ? SyncEngine.withPush(client, s, true)
      : SyncEngine(client, s);
  return (client, eng);
}

/// One local row, spelled out so each test can restate it at a new revision.
StoredTask row(
  String id,
  String listId, {
  required String title,
  required SyncState syncState,
  required String localUpdated,
  String? remoteId,
  String? etag,
  String? pendingOp,
  String? parent,
  String position = '1',
  String updated = _t0,
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    status: TaskStatus.needsAction,
    etag: etag,
    updated: updated,
  ),
  listId: listId,
  syncState: syncState,
  localUpdated: localUpdated,
  pendingOp: pendingOp,
  remoteId: remoteId,
);

void main() {
  test(
    'an edit during the 412 refetch survives, and is what finally reaches Google',
    () async {
      // Site 1 — the base-merge branch of `_resolveConflict` writes a row that
      // was drained at the START of the update pass, a 412 and a GET ago. The
      // user typing into that very row in the meantime must not be erased.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'One');
      final seeded = client.seedTask('L1', 'r1', 'alpha', '1');
      await eng.store.upsertTask(
        row(
          'local-1',
          'L1',
          title: 'alpha',
          syncState: SyncState.clean,
          localUpdated: seeded.updated,
          remoteId: 'r1',
          etag: seeded.etag,
          updated: seeded.updated,
        ),
      );
      // The user's edit. Going clean → dirty captures base_title = 'alpha'.
      await eng.store.upsertTask(
        row(
          'local-1',
          'L1',
          title: 'alpha (mine)',
          syncState: SyncState.dirty,
          localUpdated: _tEdit,
          pendingOp: 'update',
          remoteId: 'r1',
          etag: seeded.etag,
          updated: seeded.updated,
        ),
      );
      // The PATCH comes back 412 (a bare reorder bumped the etag server-side:
      // the row's TYPED content still matches our base, so this is the merge
      // branch, not a conflicted copy).
      client.failNextForId(
        Method.patchTask,
        'r1',
        () => const PreconditionFailed(),
      );
      // While the conflict refetch is in the air, the user types again.
      var raced = false;
      client.setOnCall((c, m) async {
        if (m != Method.getTask || raced) return;
        raced = true;
        await eng.store.upsertTask(
          row(
            'local-1',
            'L1',
            title: 'alpha (newer)',
            syncState: SyncState.dirty,
            localUpdated: _tRace,
            pendingOp: 'update',
            remoteId: 'r1',
            etag: seeded.etag,
            updated: seeded.updated,
          ),
        );
      });

      await eng.run();
      client.clearOnCall();
      expect(raced, isTrue, reason: 'precondition: the refetch really raced');

      final after = await eng.store.findTaskAny('local-1');
      expect(
        after!.task.title,
        'alpha (newer)',
        reason: 'the edit made during the refetch is what the user still has',
      );
      expect(
        after.syncState,
        SyncState.dirty,
        reason: 'and it is still queued to push — not silently marked in sync',
      );

      // The next run pushes it for real.
      await eng.run();
      expect(
        (await client.getTask('L1', 'r1')).title,
        'alpha (newer)',
        reason: 'the edit the user made is the one that reaches Google',
      );
    },
  );

  test('an edit during a refused move survives and is pushed', () async {
    // Site 2 — `_revertLocalMove` writes back a snapshot taken before the move
    // call, which can spend several backoff retries in the air.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'One');
    final seeded = client.seedTask('L1', 'r1', 'alpha', '1');
    await eng.store.upsertTask(
      row(
        'local-1',
        'L1',
        title: 'alpha',
        syncState: SyncState.clean,
        localUpdated: seeded.updated,
        remoteId: 'r1',
        etag: seeded.etag,
        updated: seeded.updated,
      ),
    );
    await eng.store.recordMove('local-1', 'L1', null, null);
    // Google refuses the move permanently — the intent is dropped and the
    // optimistic local half reverted.
    client.failNextForId(Method.moveTask, 'r1', () => const NotFound());
    var raced = false;
    client.setOnCall((c, m) async {
      if (m != Method.moveTask || raced) return;
      raced = true;
      await eng.store.upsertTask(
        row(
          'local-1',
          'L1',
          title: 'alpha (typed while moving)',
          syncState: SyncState.dirty,
          localUpdated: _tRace,
          pendingOp: 'update',
          remoteId: 'r1',
          etag: seeded.etag,
          updated: seeded.updated,
        ),
      );
    });

    await eng.run();
    client.clearOnCall();
    expect(raced, isTrue, reason: 'precondition: the move really raced');

    final after = await eng.store.findTaskAny('local-1');
    expect(
      after!.task.title,
      'alpha (typed while moving)',
      reason: 'the revert must not restore content older than the edit',
    );
    expect(
      after.syncState,
      SyncState.dirty,
      reason: 'reverting it to clean would strand the edit forever',
    );

    await eng.run();
    expect(
      (await client.getTask('L1', 'r1')).title,
      'alpha (typed while moving)',
      reason: 'the edit reaches Google on the next run',
    );
  });

  test('an edit landing inside the D7 flatten survives the promotion', () async {
    // Site 3 — the flatten re-reads the row, so the window is between THAT read
    // and its write rather than around a network call. `_RacingStore` fires the
    // edit inside exactly that gap. Read-only sync (no push), so the flatten
    // takes the local-only `_promoteAndDetach` branch.
    late _RacingStore racing;
    final (client, eng) = await engine(
      store: (db) => racing = _RacingStore(db),
    );
    await seedSyncedList(client, eng.store, 'L1', 'One');
    client.seedTask('L1', 'p1', 'parent', '1');
    client.seedTaskWithParent('L1', 'c1', 'child', '2', 'p1');
    client.seedTaskWithParent('L1', 'g1', 'grandchild', '3', 'c1');

    // First run pulls the three rows and flattens the third level.
    await eng.run();
    final gid = await localIdOf(eng.store, 'g1');
    // Put the grandchild back under the child, the way a pull of a still-nested
    // server row does, so the next run has a third level to repair again.
    final nested = await eng.store.findTaskAny(gid);
    await eng.store.upsertTask(
      StoredTask(
        task: nested!.task.copyWith(parent: await localIdOf(eng.store, 'c1')),
        listId: nested.listId,
        syncState: SyncState.clean,
        localUpdated: nested.localUpdated,
        remoteId: nested.remoteId,
      ),
    );

    // The user renames the grandchild in the gap between the flatten's read of
    // the row and its write of the promoted copy.
    racing.raceOn(gid, () async {
      final cur = await eng.store.findTaskAny(gid);
      await eng.store.upsertTask(
        StoredTask(
          task: cur!.task.copyWith(title: 'renamed mid-flatten'),
          listId: cur.listId,
          syncState: SyncState.dirty,
          localUpdated: _tRace,
          pendingOp: 'update',
          remoteId: cur.remoteId,
        ),
      );
    });

    await eng.run();
    expect(racing.fired, isTrue, reason: 'precondition: the gap really raced');
    final after = await eng.store.findTaskAny(gid);
    expect(
      after!.task.title,
      'renamed mid-flatten',
      reason: 'the promotion must not restore the title it read beforehand',
    );
    expect(
      after.syncState,
      SyncState.dirty,
      reason: 'and the rename is still queued to push',
    );

    // The row is left nested for one run — the next D7 sweep flattens the
    // content the user now has (invariant #1 converges, the edit is kept).
    await eng.run();
    final settled = await eng.store.findTaskAny(gid);
    expect(settled!.task.parent, isNull, reason: 'flattened on the next sweep');
    expect(settled.task.title, 'renamed mid-flatten');
  });

  test(
    'an edit before the marker is written is the content Google gets — no duplicate',
    () async {
      // Site 4 — the payload used to come from the drained row while the
      // in-flight marker's base came from the CURRENT row. An edit made while
      // an EARLIER row was inserting split the two apart, so the lost response
      // to this row's insert could not recognize its own orphan.
      final (client, eng) = await engine(push: true);
      await seedSyncedList(client, eng.store, 'L1', 'One');
      for (var i = 1; i <= 4; i++) {
        await eng.store.upsertTask(
          row(
            'local-$i',
            'L1',
            title: 'task $i',
            syncState: SyncState.dirty,
            localUpdated: '2026-06-01T00:00:0${i}Z',
            pendingOp: 'create',
            position: '$i',
          ),
        );
      }
      var raced = false;
      client.setOnCall((c, m) async {
        if (m != Method.insertTask) return;
        // callCount is recorded AFTER the hook, so n is the number of inserts
        // already done: 0 = this is the first.
        final n = c.callCount(Method.insertTask);
        if (n == 0 && !raced) {
          raced = true;
          await eng.store.upsertTask(
            row(
              'local-4',
              'L1',
              title: 'task 4 (edited)',
              syncState: SyncState.dirty,
              localUpdated: _tRace,
              pendingOp: 'create',
              position: '4',
            ),
          );
        }
        // The fourth insert commits on Google and then loses its response.
        if (n == 3) c.commitThenFailNextInsert();
      });

      await eng.run();
      client.clearOnCall();
      expect(raced, isTrue, reason: 'precondition: the first insert raced');

      // Second run: the marker is resolved by adopting the orphan.
      await eng.run();

      final remote = await client.listTasks('L1');
      expect(
        remote.items.length,
        4,
        reason: 'the lost response must be adopted, never re-inserted',
      );
      expect(
        remote.items.map((t) => t.title),
        containsAll(<String>['task 4 (edited)']),
        reason: 'and the content Google holds is the edit, not the stale draft',
      );
      expect(
        remote.items.where((t) => t.title.startsWith('task 4')).length,
        1,
        reason: 'exactly one copy of the raced row',
      );
    },
  );

  test('an etag-less row never overwrites another device silently', () async {
    // Site 5 — a row the D7 flatten / pull detach / move revert stripped the
    // etag from is still server-backed. Patching it without `If-Match` is an
    // unconditional overwrite: no 412, no conflicted copy, remote-wins gone.
    final (client, eng) = await engine(push: true);
    await seedSyncedList(client, eng.store, 'L1', 'One');
    final seeded = client.seedTask('L1', 'r1', 'alpha', '1');
    await eng.store.upsertTask(
      row(
        'local-1',
        'L1',
        title: 'alpha',
        syncState: SyncState.clean,
        localUpdated: seeded.updated,
        remoteId: 'r1',
        updated: seeded.updated,
      ),
    );
    await eng.store.upsertTask(
      row(
        'local-1',
        'L1',
        title: 'mine',
        syncState: SyncState.dirty,
        localUpdated: _tEdit,
        pendingOp: 'update',
        remoteId: 'r1',
        updated: seeded.updated,
      ),
    );
    // Another device edited the same task while we were detached.
    await client.patchTask('L1', 'r1', const TaskPatch(title: 'theirs'));

    final out = await eng.run();

    expect(
      (await client.getTask('L1', 'r1')).title,
      'theirs',
      reason: 'the other device\'s edit is not silently replaced',
    );
    expect(
      out.conflicts,
      1,
      reason: 'the divergence is reported as a conflict',
    );
    final rows = await eng.store.listTasks('L1');
    expect(
      rows.firstWhere((r) => r.task.id == 'local-1').task.title,
      'theirs',
      reason: 'remote wins locally (Google is the source of truth)',
    );
    expect(
      rows.map((r) => r.task.title),
      contains('mine (conflicted copy)'),
      reason: 'and the local edit survives as a copy, never discarded',
    );
  });
}

/// A [Store] that runs a one-shot callback inside the gap between the engine's
/// own `findTaskAny` read and the write it bases on that read — the window a
/// `local_updated` guard exists to close where there is no network call to
/// interleave with.
class _RacingStore extends Store {
  _RacingStore(super.db);

  String? _raceId;
  Future<void> Function()? _hook;
  int _seen = 0;

  /// Whether the interleaved edit actually ran (a precondition every test that
  /// arms it asserts, so a silent no-fire cannot pass as a green race).
  bool fired = false;

  /// Fire [hook] after the SECOND read of [id] in a run: the D7 sweep reads the
  /// row once to classify it, then again inside the promotion it is about to
  /// write — the second read is the one whose write the guard must protect.
  void raceOn(String id, Future<void> Function() hook) {
    _raceId = id;
    _hook = hook;
    _seen = 0;
  }

  @override
  Future<StoredTask?> findTaskAny(String id) async {
    final result = await super.findTaskAny(id);
    if (id == _raceId && _hook != null) {
      _seen += 1;
      if (_seen == 2) {
        final hook = _hook!;
        _hook = null;
        fired = true;
        await hook();
      }
    }
    return result;
  }
}
