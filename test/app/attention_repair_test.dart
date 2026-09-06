// #296 — the repairs the "Needs attention" view performs, asserted against the
// STORE and the fake server rather than against the widgets that call them.
//
// Three things could previously happen to a user's data with no way to act on
// them from the app:
//
//   * a row the server keeps rejecting is QUARANTINED (#270) — held, never
//     pushed again, releasable only by an edit. "Retry" gives it a fresh budget
//     and "Discard local change" adopts the server's copy instead;
//   * an unresolvable `412` forks the local edit into a "(conflicted copy)"
//     row (RFC-009 P3) — both rows survive, and until now nothing could tell
//     the app which one the user wanted;
//   * a discarded change and a resolved conflict are both destructive, so each
//     hands back a token the undo toast reverts.
//
// Every conflict here is a REAL one: it is forked by the engine out of a real
// `412` against the fake Google, so the pairing rule in `model/attention.dart`
// is checked against what the engine actually writes, not against a
// hand-built row that merely looks like it.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/auth_state.dart';
import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/app/sync_scheduler.dart';
import 'package:axiotask/src/model/attention.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/conflicts.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/poison.dart' show kPoisonRejectCap;
import 'package:flutter_test/flutter_test.dart';

import '../sync/sync_fixture.dart';

/// Always-live auth, so the scheduler runs without an auth controller.
class _LiveAuth implements AuthState {
  @override
  bool get isAuthenticated => true;
  @override
  bool get needsReauth => false;
  @override
  void setNeedsReauth(bool value) {}
}

/// A store + fake server + commands, with the fake holding one list.
Future<(FakeTasksApi, Store, Commands)> fixture() async {
  final client = FakeTasksApi();
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  final store = Store(db);
  return (client, store, Commands(store));
}

/// Drive a REAL unresolvable 412: the server-side row moves to
/// 'their-version', the local row is edited to 'local-edit' against a stale
/// etag, and the run forks the conflicted copy.
Future<ConflictedPair> forkConflict(
  FakeTasksApi client,
  Store store,
  ConflictRegistry conflicts,
) async {
  final eng = SyncEngine.withPush(client, store, true, conflicts: conflicts);
  await seedSyncedList(client, store, 'L1', 'Inbox');
  client.seedTask('L1', 'T1', 'server-version', '1');
  await eng.run();

  await client.patchTask('L1', 'T1', const TaskPatch(title: 'their-version'));
  final row = (await findByAnyId(store, 'T1'))!;
  await store.upsertTask(
    StoredTask(
      task: row.task.copyWith(title: 'local-edit', etag: 'stale'),
      listId: row.listId,
      syncState: SyncState.dirty,
      localUpdated: '2026-06-02T00:00:00Z',
      pendingOp: 'update',
    ),
  );
  final out = await eng.run();
  expect(out.conflicts, 1, reason: 'the fork must be a real 412 resolution');

  final pairs = conflictedPairs(await store.allTasks(), conflicts.links);
  expect(
    pairs,
    hasLength(1),
    reason: 'the engine-written fork must be recognised as a pair',
  );
  return pairs.single;
}

/// Every live (non-tombstoned) row title in the store.
Future<List<String>> liveTitles(Store store) async => [
  for (final t in await store.allTasks())
    if (t.syncState != SyncState.deleted) t.task.title,
];

void main() {
  group('conflicted copy (#296)', () {
    test('Keep mine puts the local edit on the canonical row and takes the '
        'copy away', () async {
      final (client, store, commands) = await fixture();
      final conflicts = ConflictRegistry();
      final pair = await forkConflict(client, store, conflicts);

      await commands.resolveConflict(
        originalId: pair.original.task.id,
        copyId: pair.copy.task.id,
        choice: ConflictChoice.keepMine,
      );

      expect(await liveTitles(store), [
        'local-edit',
      ], reason: 'one row survives, carrying the edit, with no marker left');
      final kept = (await store.findTaskAny(pair.original.task.id))!;
      expect(
        kept.syncState,
        SyncState.dirty,
        reason: 'the kept edit has not reached Google yet — it must push',
      );
      expect(
        conflictedPairs(await store.allTasks(), conflicts.links),
        isEmpty,
        reason: 'the view empties once the conflict is resolved',
      );

      // …and the next sync actually lands it on the server.
      await SyncEngine.withPush(client, store, true).run();
      final onServer = await client.listTasks('L1');
      expect(onServer.items.map((t) => t.title), ['local-edit']);
    });

    test(
      'Keep theirs discards the copy and leaves the canonical row alone',
      () async {
        final (client, store, commands) = await fixture();
        final conflicts = ConflictRegistry();
        final pair = await forkConflict(client, store, conflicts);

        await commands.resolveConflict(
          originalId: pair.original.task.id,
          copyId: pair.copy.task.id,
          choice: ConflictChoice.keepTheirs,
        );

        expect(await liveTitles(store), ['their-version']);
        final kept = (await store.findTaskAny(pair.original.task.id))!;
        expect(
          kept.syncState,
          SyncState.clean,
          reason: "the server's row was already agreed — nothing to push",
        );
      },
    );

    test(
      'Keep both leaves two rows and stops calling them a conflict',
      () async {
        final (client, store, commands) = await fixture();
        final conflicts = ConflictRegistry();
        final pair = await forkConflict(client, store, conflicts);

        await commands.resolveConflict(
          originalId: pair.original.task.id,
          copyId: pair.copy.task.id,
          choice: ConflictChoice.keepBoth,
        );

        expect((await liveTitles(store))..sort(), [
          'local-edit',
          'their-version',
        ], reason: 'both rows survive; the marker is not the user’s word');
        expect(
          conflictedPairs(await store.allTasks(), conflicts.links),
          isEmpty,
          reason: 'keeping both resolves the pair — the view must empty',
        );
      },
    );

    test('undo puts both rows back exactly as they were', () async {
      final (client, store, commands) = await fixture();
      final conflicts = ConflictRegistry();
      final pair = await forkConflict(client, store, conflicts);
      final before = await store.allTasks();

      final token = await commands.resolveConflict(
        originalId: pair.original.task.id,
        copyId: pair.copy.task.id,
        choice: ConflictChoice.keepMine,
      );
      await commands.undoResolveConflict(token);

      expect((await liveTitles(store))..sort(), [
        'local-edit (conflicted copy)',
        'their-version',
      ]);
      final original = (await store.findTaskAny(pair.original.task.id))!;
      expect(original.task.title, 'their-version');
      expect(original.syncState, before.first.syncState);
      expect(
        conflictedPairs(await store.allTasks(), conflicts.links),
        hasLength(1),
        reason: 'undo restores the conflict, so the view shows it again',
      );
    });

    test('undo of Keep both restores the marker', () async {
      final (client, store, commands) = await fixture();
      final conflicts = ConflictRegistry();
      final pair = await forkConflict(client, store, conflicts);

      final token = await commands.resolveConflict(
        originalId: pair.original.task.id,
        copyId: pair.copy.task.id,
        choice: ConflictChoice.keepBoth,
      );
      await commands.undoResolveConflict(token);

      expect(
        conflictedPairs(await store.allTasks(), conflicts.links),
        hasLength(1),
      );
    });
  });

  group('quarantined row (#296)', () {
    /// A server-backed row the server refuses to patch, pushed until the poison
    /// cap holds it. Returns the scheduler, the client and the local row id.
    Future<(SyncScheduler, FakeTasksApi, Store, Commands, String)>
    quarantined() async {
      final client = FakeTasksApi();
      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      final store = Store(db);
      final scheduler = SyncScheduler(
        store: store,
        client: () => client,
        auth: _LiveAuth(),
        pushEnabled: () => true,
        debounce: Duration.zero,
        period: const Duration(milliseconds: 1),
      );
      addTearDown(scheduler.dispose);
      final commands = Commands(store);

      final list = await client.insertTasklist('Work');
      final remote = await client.insertTask(
        list.id,
        const NewTask(title: 'Poison'),
      );
      await scheduler.runSync();
      final local = (await store.allTasks()).firstWhere(
        (t) => t.remoteId == remote.id,
      );
      await commands.renameTask(local.task.id, 'Poison renamed');

      for (var run = 0; run < kPoisonRejectCap; run++) {
        client.failNextForId(
          Method.patchTask,
          remote.id,
          () => const OtherApiError('400 invalid value'),
        );
        await scheduler.runSync();
      }
      return (scheduler, client, store, commands, local.task.id);
    }

    test(
      'the held row is published by id, so the view can act on it',
      () async {
        final (scheduler, client, _, _, localId) = await quarantined();

        expect(scheduler.status.quarantined.map((q) => q.id), [
          localId,
        ], reason: 'a title alone cannot be retried or discarded');
        expect(scheduler.status.quarantined.single.title, 'Poison renamed');
        expect(client.callCount(Method.patchTask), kPoisonRejectCap);
      },
    );

    test('Retry gives the held row a fresh budget and the view empties on '
        'success', () async {
      final (scheduler, client, store, _, localId) = await quarantined();

      scheduler.releaseQuarantine(localId);
      await scheduler.runSync();

      expect(
        client.callCount(Method.patchTask),
        kPoisonRejectCap + 1,
        reason: 'Retry must actually re-queue the push',
      );
      expect(
        scheduler.status.quarantined,
        isEmpty,
        reason: 'the push landed, so nothing is held any more',
      );
      expect((await store.findTaskAny(localId))!.syncState, SyncState.clean);
      final onServer = await client.listTasks(
        (await client.listTasklists()).single.id,
      );
      expect(onServer.items.single.title, 'Poison renamed');
    });

    test('Discard local change adopts the server copy', () async {
      final (scheduler, client, store, commands, localId) = await quarantined();

      await commands.discardLocalChange(localId);

      final row = (await store.findTaskAny(localId))!;
      expect(
        row.task.title,
        'Poison',
        reason: 'the row reverts to the content Google holds',
      );
      expect(
        row.syncState,
        SyncState.clean,
        reason: 'there is no local change left to push',
      );

      // A run now must not try the rejected push at all.
      await scheduler.runSync();
      expect(client.callCount(Method.patchTask), kPoisonRejectCap);
      expect(scheduler.status.quarantined, isEmpty);
    });

    test('undo of Discard brings the local change back', () async {
      final (_, _, store, commands, localId) = await quarantined();

      final token = await commands.discardLocalChange(localId);
      await commands.undoDiscardLocalChange(token);

      final row = (await store.findTaskAny(localId))!;
      expect(row.task.title, 'Poison renamed');
      expect(
        row.syncState,
        SyncState.dirty,
        reason: 'the restored edit is unpushed again',
      );
    });

    test('discarding a change the server has NEVER agreed to takes the row '
        'away', () async {
      // The non-happy path: a CREATE the server refuses has no server copy to
      // adopt — the local row is the whole change, so discarding it discards
      // the row. Reverting to a base that does not exist would leave an
      // un-pushable row in the list forever.
      final (client, store, commands) = await fixture();
      await seedSyncedList(client, store, 'L1', 'Inbox');
      final created = await commands.createTask(
        listId: 'L1',
        title: 'never agreed',
      );

      await commands.discardLocalChange(created.task.id);

      expect(await liveTitles(store), isEmpty);
    });
  });
}
