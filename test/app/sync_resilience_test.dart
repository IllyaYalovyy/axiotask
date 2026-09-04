// #270 — the background sync loop must survive a run that fails in a way the
// typed error union does not describe, and a row the server permanently
// refuses must stop costing a push every cadence tick.
//
// Three defects, one theme: a failure path that was narrower than reality.
//
//  * `SyncEngine.run` wrote the sync_log OUTSIDE the coercion, and both
//    `SyncScheduler._runSyncInner` and `AuthSyncRuntime._syncNow` caught only
//    `SyncError`. A `writeSyncLog` that throws a raw exception (disk full, DB
//    locked) therefore escaped every guard — the startup auto-sync rejected,
//    `startLoop()` never ran, and there was no sync at all until the app was
//    restarted. Nothing recorded the failure either: the status stayed clean.
//  * A row the server rejects permanently stayed dirty and was re-pushed on
//    every run, forever, under a "will retry" message that would never come
//    true.
//
// Everything here is asserted from what the USER can observe: the sanitized
// status the UI renders, and what the fake server was actually asked to do.

import 'dart:io';

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/auth_state.dart';
import 'package:axiotask/src/app/auth_sync_runtime.dart';
import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:axiotask/src/app/logging.dart';
import 'package:axiotask/src/app/sync_scheduler.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/model/sync_run.dart';
import 'package:axiotask/src/model/task.dart' show NewTask;
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/sync/sync_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A store whose sync-log write fails the way a full or locked SQLite file
/// does: with a RAW exception that is neither a [StoreError] nor a [SyncError].
/// Everything else behaves exactly like the real store.
class _LogFailingStore extends Store {
  _LogFailingStore(super.db);

  /// While true, every `writeSyncLog` throws.
  bool failLog = true;

  /// How many log writes were attempted (the run bookkeeping must still be
  /// attempted once per run, failing or not).
  int logWrites = 0;

  @override
  Future<void> writeSyncLog({
    required int pulled,
    required int pushed,
    required int conflicts,
    required int durationMs,
    SyncFailureKind? failure,
  }) async {
    logWrites += 1;
    if (failLog) {
      // Not an ApiError, not a StoreError, not a SyncError — exactly what
      // `package:sqlite3` throws when the disk is full.
      throw Exception('SqliteException(13): database or disk is full');
    }
    return super.writeSyncLog(
      pulled: pulled,
      pushed: pushed,
      conflicts: conflicts,
      durationMs: durationMs,
      failure: failure,
    );
  }
}

class _FakeAuth implements AuthState {
  @override
  bool isAuthenticated = true;

  bool _needsReauth = false;

  @override
  bool get needsReauth => _needsReauth;

  @override
  void setNeedsReauth(bool value) => _needsReauth = value;
}

void main() {
  Log.initLogging();

  group('a run that fails outside the typed error union (#270)', () {
    late _LogFailingStore store;
    late FakeTasksApi client;
    late SyncScheduler scheduler;

    setUp(() async {
      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      store = _LogFailingStore(db);
      client = FakeTasksApi();
      scheduler = SyncScheduler(
        store: store,
        client: () => client,
        auth: _FakeAuth(),
        pushEnabled: () => false,
        debounce: Duration.zero,
        period: const Duration(milliseconds: 1),
      );
      addTearDown(scheduler.dispose);
    });

    test('a raw sync-log write failure surfaces as a SyncError and is '
        'recorded, and the next cycle still runs', () async {
      // The run itself succeeds; only the bookkeeping write blows up.
      await expectLater(
        scheduler.runSync(),
        throwsA(isA<SyncError>()),
        reason:
            'every run failure reaches the caller as a SyncError — a raw '
            'exception escaping here is what kills the startup task',
      );

      expect(
        scheduler.status.lastError,
        'Sync hit a local database problem — the details are in the log.',
        reason: 'a failure the user cannot see is a failure nobody fixes',
      );
      expect(scheduler.status.needsAttention, isTrue);
      expect(scheduler.status.totalSyncs, 0);

      // The disk frees up. The loop is still able to drive a cycle, and it
      // clears the attention state.
      store.failLog = false;
      await scheduler.runSyncCycle();

      expect(scheduler.status.totalSyncs, 1);
      expect(scheduler.status.lastError, isNull);
      expect(scheduler.status.needsAttention, isFalse);
    });

    test("a failing log write never masks the run's own failure", () async {
      // Both halves fail: the run hits a permanent API error AND the log write
      // throws. What reaches the user must be the API failure — the one that
      // explains why nothing synced.
      client.failNext(
        Method.listTasklists,
        () => const OtherApiError('bad gateway markup'),
      );

      final error = await scheduler.runSync().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );

      expect(error, isA<SyncApiError>());
      expect(
        (error! as SyncApiError).error,
        const OtherApiError('bad gateway markup'),
      );
      expect(
        store.logWrites,
        1,
        reason: 'the run still tried to record itself',
      );
    });
  });

  group('startup survives a failed auto-sync (#270)', () {
    test('a raw failure inside the startup auto-sync still starts the '
        'background loop', () async {
      final tmp = Directory.systemTemp.createTempSync('axiotask_270');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      final store = _LogFailingStore(db);
      final client = FakeTasksApi();
      final runtime = AuthSyncRuntime(
        store: store,
        config: ConfigController(
          path: File(p.join(tmp.path, 'config.json')),
          initial: const AppConfig(
            sync: SyncConfig(pushEnabled: false, autoSyncOnStart: true),
          ),
        ),
        tokenProvider: FakeTokenProvider.withToken('access-1'),
        buildClient: (_) => client,
        debounce: Duration.zero,
        // Long enough that the ONLY thing that can produce a run here is the
        // mutation trigger — an idle tick would prove nothing about whether the
        // loop was started, and would keep spinning past the test's teardown.
        period: const Duration(seconds: 30),
      );
      addTearDown(runtime.dispose);

      // Startup: restore succeeds, the auto-sync's log write explodes. The
      // detached startup task must not reject — and, above all, must still
      // bring the background loop up.
      await runtime.start();

      // The disk frees up. A mutation now has to reach the server, which can
      // only happen if the loop is alive.
      store.failLog = false;
      runtime.scheduler.scheduleSync();

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (runtime.scheduler.status.totalSyncs == 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        runtime.scheduler.status.totalSyncs,
        greaterThan(0),
        reason:
            'a startup auto-sync that failed must not cost the session its '
            'background sync until the app is restarted',
      );
    });
  });

  group('a permanently rejected row is quarantined (#270)', () {
    test('five rejected runs stop the push, name the row, and an edit '
        'releases it', () async {
      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      final store = Store(db);
      final client = FakeTasksApi();
      final scheduler = SyncScheduler(
        store: store,
        client: () => client,
        auth: _FakeAuth(),
        pushEnabled: () => true,
        debounce: Duration.zero,
        period: const Duration(milliseconds: 1),
      );
      addTearDown(scheduler.dispose);
      final commands = Commands(store);

      // A server-backed list holding one server-backed task.
      final list = await client.insertTasklist('Work');
      final remote = await client.insertTask(
        list.id,
        const NewTask(title: 'Poison'),
      );
      await scheduler.runSync();
      final localList = (await store.allLists()).single.list.id;
      final local = (await store.listTasks(
        localList,
      )).firstWhere((t) => t.remoteId == remote.id);

      // The user renames it; Google refuses the patch, permanently, forever.
      await commands.renameTask(local.task.id, 'Poison renamed');

      for (var run = 1; run <= 4; run++) {
        client.failNextForId(
          Method.patchTask,
          remote.id,
          () => const OtherApiError('400 invalid value'),
        );
        await scheduler.runSync();
        expect(
          client.callCount(Method.patchTask),
          run,
          reason: 'run $run must still try the push',
        );
        expect(
          scheduler.status.lastError,
          contains('rejected by the server'),
          reason: 'run $run is still inside the retry budget',
        );
      }

      // The fifth rejection exhausts the budget: the row is quarantined and
      // the user is told WHICH change is stuck, in words that ask for an edit.
      client.failNextForId(
        Method.patchTask,
        remote.id,
        () => const OtherApiError('400 invalid value'),
      );
      await scheduler.runSync();
      expect(client.callCount(Method.patchTask), 5);
      expect(scheduler.status.lastError, contains('Poison renamed'));
      expect(scheduler.status.lastError, contains('could not be synced'));

      // The sixth run does not spend a request on it at all — no fault is
      // armed, so a push here would SUCCEED and hide the regression.
      await scheduler.runSync();
      expect(
        client.callCount(Method.patchTask),
        5,
        reason: 'a quarantined row must not be pushed again',
      );
      expect(scheduler.status.lastError, contains('Poison renamed'));

      // Editing the row is the release: the next run pushes it, and it lands.
      await commands.renameTask(local.task.id, 'Poison fixed');
      await scheduler.runSync();
      expect(
        client.callCount(Method.patchTask),
        6,
        reason: 'an edited row gets a fresh push budget',
      );
      expect(scheduler.status.lastError, isNull);
      final onServer = await client.listTasks(list.id);
      expect(onServer.items.single.title, 'Poison fixed');
    });
  });
}
