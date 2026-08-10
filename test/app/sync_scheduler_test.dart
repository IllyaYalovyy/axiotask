// T5.9 scheduler — the DB-backed behaviors of [SyncScheduler] (MIGRATION-PLAN
// §5): how a run's OUTCOME becomes user-visible state. These exercise the real
// engine over an in-memory drift store and the fake Tasks API, so the
// assertions read what the user would see — the status snapshot, the re-auth
// flag, the next poll delay, the level a failure is logged at, what actually
// reached the server on exit — never which method was called.
//
// The pure timing/message/backoff units live in `sync_scheduler_units_test.dart`.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/auth_state.dart';
import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/app/logging.dart';
import 'package:axiotask/src/app/sync_scheduler.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal in-memory [AuthState] — the T5.9 "fake" for the auth seam. Auth is
/// a three-state machine: [isAuthenticated] and [needsReauth] move
/// independently, so a dead session keeps its tokens (authenticated stays true
/// while needs-reauth goes true).
class FakeAuthState implements AuthState {
  FakeAuthState({this.isAuthenticated = false});

  @override
  bool isAuthenticated;

  bool _needsReauth = false;

  @override
  bool get needsReauth => _needsReauth;

  @override
  void setNeedsReauth(bool value) => _needsReauth = value;
}

/// A scheduler wired over a fresh in-memory store and fake API, torn down with
/// the test. Mirrors the reference's `new_memory` / `new_memory_with_push`.
class Harness {
  Harness(this.client, this.store, this.auth, this.scheduler, this.commands);

  final FakeTasksApi client;
  final Store store;
  final FakeAuthState auth;
  final SyncScheduler scheduler;
  final Commands commands;
}

Future<Harness> makeHarness({bool push = false, bool signedIn = false}) async {
  final client = FakeTasksApi();
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  final store = Store(db);
  final auth = FakeAuthState(isAuthenticated: signedIn);
  final scheduler = SyncScheduler(
    store: store,
    client: () => client,
    auth: auth,
    pushEnabled: () => push,
  );
  addTearDown(scheduler.dispose);
  return Harness(client, store, auth, scheduler, Commands(store));
}

/// Insert a local-only list so a task can hang off it without any server round
/// trip (used for the signed-out flush case).
Future<void> seedLocalList(Store store, String id, String title) =>
    store.upsertList(
      StoredTaskList(
        list: TaskList(id: id, title: title, updated: '2026-06-01T00:00:00Z'),
        syncState: SyncState.clean,
        localUpdated: '2026-06-01T00:00:00Z',
        localOnly: true,
      ),
    );

Future<bool> taskStillDirty(Store store, String listId, String title) async {
  final rows = await store.listTasks(listId);
  return rows.any(
    (t) => t.task.title == title && t.syncState == SyncState.dirty,
  );
}

Future<bool> remoteHasTitle(
  FakeTasksApi client,
  String listId,
  String title,
) async {
  final page = await client.listTasks(listId);
  return page.items.any((t) => t.title == title);
}

void main() {
  group('sync status', () {
    test('starts empty, then records a successful run', () async {
      final h = await makeHarness();
      final before = h.scheduler.status;
      expect(before.lastSynced, isNull);
      expect(before.totalSyncs, 0);
      expect(before.lastError, isNull);

      await h.scheduler.runSync();

      final after = h.scheduler.status;
      expect(after.lastSynced, isNotNull, reason: 'timestamp recorded');
      expect(after.totalSyncs, 1);
      expect(after.lastError, isNull);
    });
  });

  group('notifier stream', () {
    test('emits exactly one snapshot on a successful run', () async {
      final h = await makeHarness();
      final seen = <SyncStatus>[];
      final sub = h.scheduler.statuses.listen(seen.add);
      addTearDown(sub.cancel);

      await h.scheduler.runSync();
      await pumpEventQueue();

      expect(seen, hasLength(1), reason: 'exactly one notification per run');
      expect(seen.single.lastError, isNull, reason: 'success clears lastError');
      expect(seen.single.lastSynced, isNotNull);
      expect(seen.single.totalSyncs, 1);
    });

    test('still emits a snapshot on a failed run', () async {
      final h = await makeHarness();
      final seen = <SyncStatus>[];
      final sub = h.scheduler.statuses.listen(seen.add);
      addTearDown(sub.cancel);

      // A non-transient error on the first pull call fails the whole run.
      h.client.failNext(Method.listTasklists, () => const Unauthorized());
      await expectLater(h.scheduler.runSync(), throwsA(isA<Object>()));
      await pumpEventQueue();

      expect(seen, hasLength(1), reason: 'failure still notifies the observer');
      expect(seen.single.lastError, isNotNull, reason: 'failure surfaces it');
    });
  });

  group('auth — the three-state machine (#6)', () {
    test('expired session sets needs-reauth with an actionable error, then '
        'a working sync clears it', () async {
      final h = await makeHarness(push: true, signedIn: true);
      h.client.seedList('L1', 'Inbox');
      expect(h.auth.needsReauth, isFalse);

      h.client.failNext(
        Method.listTasklists,
        () => const AuthExpired('invalid_grant: Token expired or revoked.'),
      );
      await expectLater(h.scheduler.runSync(), throwsA(isA<Object>()));

      expect(h.auth.needsReauth, isTrue, reason: 'dead session is flagged');
      final msg = h.scheduler.status.lastError;
      expect(msg, isNotNull);
      expect(msg, contains('sign in again'), reason: 'actionable message');
      expect(
        h.scheduler.status.needsReauth,
        isTrue,
        reason: 'the flag rides the status snapshot to the UI',
      );

      // After re-login the next sync works — the flag and error clear.
      await h.scheduler.runSync();
      expect(h.auth.needsReauth, isFalse);
      expect(h.scheduler.status.needsReauth, isFalse);
      expect(h.scheduler.status.lastError, isNull);
    });

    test('exposes three distinct states, not two', () async {
      final h = await makeHarness(push: true);
      h.client.seedList('L1', 'Inbox');

      // State 1 — SIGNED OUT: no session, no re-auth prompt.
      expect(h.auth.isAuthenticated, isFalse);
      expect(h.auth.needsReauth, isFalse);

      // State 2 — SIGNED IN: a completed login leaves a live session.
      h.auth.isAuthenticated = true;
      expect(h.auth.needsReauth, isFalse);

      // State 3 — NEEDS_REAUTH: refresh permanently denied. The session is
      // STILL present (distinct from signed out) and the flag rides the status.
      h.client.failNext(
        Method.listTasklists,
        () => const AuthExpired('invalid_grant: revoked'),
      );
      await expectLater(h.scheduler.runSync(), throwsA(isA<Object>()));

      expect(h.auth.needsReauth, isTrue, reason: 'dead session is flagged');
      expect(
        h.auth.isAuthenticated,
        isTrue,
        reason: 'needs-reauth keeps the session — NOT the signed-out state',
      );
      expect(h.scheduler.status.needsReauth, isTrue);
    });
  });

  group('permanent-failure attention & backoff', () {
    test(
      'flags attention, backs off, surfaces the real error, then recovers',
      () async {
        final h = await makeHarness(push: true);
        h.client.seedList('L1', 'Inbox');
        expect(h.scheduler.status.needsAttention, isFalse);
        final base = h.scheduler.nextSyncPeriod();

        // First permanent failure.
        h.client.failNext(
          Method.listTasklists,
          () => const OtherApiError(
            'schema mismatch: column tasks.blorp missing',
          ),
        );
        await expectLater(h.scheduler.runSync(), throwsA(isA<Object>()));

        final status = h.scheduler.status;
        expect(status.needsAttention, isTrue);
        expect(status.lastError, contains('column tasks.blorp missing'));
        // Distinct from the dead-session state — this is NOT a re-auth prompt.
        expect(h.auth.needsReauth, isFalse);
        expect(status.needsReauth, isFalse);
        final afterOne = h.scheduler.nextSyncPeriod();
        expect(afterOne, greaterThan(base), reason: 'cadence backs off');

        // A second consecutive permanent failure backs off further still.
        h.client.failNext(
          Method.listTasklists,
          () => const OtherApiError(
            'schema mismatch: column tasks.blorp missing',
          ),
        );
        await expectLater(h.scheduler.runSync(), throwsA(isA<Object>()));
        final afterTwo = h.scheduler.nextSyncPeriod();
        expect(
          afterTwo,
          greaterThan(afterOne),
          reason: 'cadence keeps growing',
        );

        // The first success clears attention and restores the base cadence.
        await h.scheduler.runSync();
        final recovered = h.scheduler.status;
        expect(recovered.needsAttention, isFalse);
        expect(recovered.lastError, isNull);
        expect(h.scheduler.nextSyncPeriod(), const Duration(seconds: 60));
      },
    );

    test('a transient failure never flags attention or backs off', () async {
      final h = await makeHarness(push: true);
      final base = h.scheduler.nextSyncPeriod();

      // A 5xx on the lists pull is transient; the engine swallows it into a
      // partial Ok, so no error reaches the scheduler and attention stays clear.
      h.client.failNext(Method.listTasklists, () => const ServerError(503));
      await h.scheduler.runSync();

      expect(h.scheduler.status.needsAttention, isFalse);
      expect(h.scheduler.nextSyncPeriod(), base, reason: 'cadence unchanged');
    });

    test('logs a distinct permanent failure once at ERROR, mutes the repeat to '
        'DEBUG, and re-logs after a clean sync (#131)', () async {
      const blorp = 'schema mismatch: tasks.blorp';
      const zonk = 'schema mismatch: lists.zonk';
      final records = <(LogLevel, String)>[];
      Log.useSink((level, message) => records.add((level, message)));
      addTearDown(Log.initLogging);

      int count(LogLevel level, String needle) =>
          records.where((r) => r.$1 == level && r.$2.contains(needle)).length;

      final h = await makeHarness(push: true);
      h.client.seedList('L1', 'Inbox');

      // The same permanent failure twice, then a genuinely different one.
      for (var i = 0; i < 2; i++) {
        h.client.failNext(
          Method.listTasklists,
          () => const OtherApiError(blorp),
        );
        await expectLater(h.scheduler.runSync(), throwsA(isA<Object>()));
      }
      h.client.failNext(Method.listTasklists, () => const OtherApiError(zonk));
      await expectLater(h.scheduler.runSync(), throwsA(isA<Object>()));

      // The user-visible state carries the failure text and flags attention.
      final status = h.scheduler.status;
      expect(status.needsAttention, isTrue);
      expect(status.lastError, contains(zonk));

      expect(count(LogLevel.error, blorp), 1, reason: 'first distinct → ERROR');
      expect(count(LogLevel.debug, blorp), 1, reason: 'the repeat → DEBUG');
      expect(count(LogLevel.error, zonk), 1, reason: 'a new cause earns ERROR');

      // A success clears attention AND the raw dedup key, so the SAME failure
      // recurring afterwards is treated as new and re-logs at ERROR.
      await h.scheduler.runSync();
      final recovered = h.scheduler.status;
      expect(recovered.needsAttention, isFalse);
      expect(recovered.lastError, isNull);

      h.client.failNext(Method.listTasklists, () => const OtherApiError(blorp));
      await expectLater(h.scheduler.runSync(), throwsA(isA<Object>()));
      expect(
        count(LogLevel.error, blorp),
        2,
        reason: 'after a clean sync the dedup key was reset — re-logs at ERROR',
      );
    });
  });

  group('runSyncIfAuthed / scheduleSync gate (GH#26)', () {
    test(
      'does not sync when not authenticated — remote data never appears',
      () async {
        final h = await makeHarness();
        expect(h.auth.isAuthenticated, isFalse);

        // Seed remote data that WOULD appear locally if a sync ran.
        h.client.seedList('REMOTE', 'Remote List');
        h.client.seedTask('REMOTE', 'RT1', 'remote task', '1');

        // A background trigger while signed out must not run a sync.
        h.scheduler.scheduleSync();
        await expectLater(
          h.scheduler.runSyncIfAuthed(),
          throwsA(isA<StateError>()),
        );

        final lists = await h.store.allLists();
        expect(
          lists.any((l) => l.list.title == 'Remote List'),
          isFalse,
          reason: 'sync must not have run while signed out',
        );
      },
    );

    test('the loop cycle skips the run while the session is dead', () async {
      final h = await makeHarness(push: true, signedIn: true);
      h.auth.setNeedsReauth(true); // dead session
      h.client.seedList('REMOTE', 'Remote List');

      // Drive one loop cycle under fake time: the trigger fires, but the
      // needs-reauth gate short-circuits before any sync — no API call, no
      // remote data pulled.
      h.scheduler.scheduleSync();
      await h.scheduler.runSyncCycle();

      expect(h.client.callCount(Method.listTasklists), 0);
      final lists = await h.store.allLists();
      expect(lists.any((l) => l.list.title == 'Remote List'), isFalse);
    });
  });

  group('flush on exit', () {
    test('pushes a change made just before quitting', () async {
      final h = await makeHarness(push: true, signedIn: true);
      h.client.seedList('L1', 'Inbox');
      await h.scheduler.runSync(); // pull the list locally

      await h.commands.createTask(listId: 'L1', title: 'buy milk');
      expect(
        await h.scheduler.pendingPushCount(),
        1,
        reason: 'precondition: the create is stuck locally, unpushed',
      );

      await h.scheduler.flushOnExit();

      expect(
        await remoteHasTitle(h.client, 'L1', 'buy milk'),
        isTrue,
        reason: 'the just-created task reached Google on exit',
      );
      expect(
        await h.scheduler.pendingPushCount(),
        0,
        reason: 'nothing left stuck after the exit flush',
      );
    });

    test('releases the held create the open panel was holding', () async {
      final h = await makeHarness(push: true, signedIn: true);
      h.client.seedList('L1', 'Inbox');
      await h.scheduler.runSync();

      final created = await h.commands.createTask(
        listId: 'L1',
        title: 'call dad',
      );
      // The detail panel follows the new task → it is the held create.
      h.scheduler.setEditingTask(created.task.id);

      // Sanity: with the hold in place a normal sync would NOT push it.
      final out = await h.scheduler.runSync();
      expect(
        out.pushed,
        0,
        reason: 'precondition: the held create is not pushed',
      );
      expect(await h.scheduler.pendingPushCount(), 1);

      // Quit: the exit flush must release the hold and push it.
      await h.scheduler.flushOnExit();

      expect(await remoteHasTitle(h.client, 'L1', 'call dad'), isTrue);
      expect(await h.scheduler.pendingPushCount(), 0);
    });

    test('does nothing when signed out', () async {
      final h = await makeHarness(); // not signed in, push off
      await seedLocalList(h.store, 'L1', 'Inbox');
      await h.commands.createTask(listId: 'L1', title: 'offline task');

      await h.scheduler.flushOnExit();

      expect(
        await taskStillDirty(h.store, 'L1', 'offline task'),
        isTrue,
        reason:
            'offline change stays pending — nothing pushed to a phantom server',
      );
      expect(await remoteHasTitle(h.client, 'L1', 'offline task'), isFalse);
    });

    test('does nothing in read-only mode', () async {
      final h = await makeHarness(push: false, signedIn: true);
      h.client.seedList('L1', 'Inbox');
      // Pull the list locally via a temporarily push-off... actually push is
      // already off; a plain sync pulls the seeded list.
      await h.scheduler.runSync();

      await h.commands.createTask(listId: 'L1', title: 'read only');

      await h.scheduler.flushOnExit();

      expect(
        await taskStillDirty(h.store, 'L1', 'read only'),
        isTrue,
        reason: 'read-only mode keeps the change local on exit',
      );
      expect(await remoteHasTitle(h.client, 'L1', 'read only'), isFalse);
    });

    test('does nothing with a dead session', () async {
      final h = await makeHarness(push: true, signedIn: true);
      h.client.seedList('L1', 'Inbox');
      await h.scheduler.runSync(); // pull the list locally

      // Kill the session.
      h.client.failNext(
        Method.listTasklists,
        () => const AuthExpired('invalid_grant: revoked'),
      );
      await expectLater(h.scheduler.runSync(), throwsA(isA<Object>()));
      expect(h.auth.needsReauth, isTrue, reason: 'precondition: session dead');

      await h.commands.createTask(listId: 'L1', title: 'after reauth');

      await h.scheduler.flushOnExit();

      expect(
        await taskStillDirty(h.store, 'L1', 'after reauth'),
        isTrue,
        reason:
            'a dead session keeps the change local on exit (no doomed push)',
      );
    });
  });
}
