// F5 (#176) composition root — the [AuthSyncRuntime] that assembles the auth
// controller, the sync scheduler, and the production client seam into the one
// detached startup task and the action seams the UI drives.
//
// These assert the OBSERVABLE outcome of the wiring — did a session come back,
// did an auto-sync run, did a manual refresh reach the server, did fresh-sync
// clear-then-repull — read from the scheduler's sanitized status and the fake
// server's call log, never "a method was called".

import 'dart:io';

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/auth_sync_runtime.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:axiotask/src/app/logging.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Env {
  _Env(this.store, this.config, this.client, this.runtime);
  final Store store;
  final ConfigController config;
  final FakeTasksApi client;
  final AuthSyncRuntime runtime;
}

void main() {
  Log.initLogging();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_f5'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<_Env> makeEnv({
    required TokenProvider tokenProvider,
    bool autoSyncOnStart = true,
    bool push = false,
  }) async {
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final store = Store(db);
    final config = ConfigController(
      path: File(p.join(tmp.path, 'config.json')),
      initial: AppConfig(
        sync: SyncConfig(pushEnabled: push, autoSyncOnStart: autoSyncOnStart),
      ),
    );
    final client = FakeTasksApi();
    final runtime = AuthSyncRuntime(
      store: store,
      config: config,
      tokenProvider: tokenProvider,
      buildClient: (accessToken) => client,
      debounce: Duration.zero,
    );
    addTearDown(runtime.dispose);
    return _Env(store, config, client, runtime);
  }

  // A local-only list so the store is non-empty without any server round trip.
  Future<void> seedLocalList(Store store) => store.upsertList(
    StoredTaskList(
      list: TaskList(id: 'L1', title: 'Local', updated: 't'),
      syncState: SyncState.clean,
      localUpdated: 't',
      localOnly: true,
    ),
  );

  test('restore recovers a live session, then auto-syncs (ordered)', () async {
    final env = await makeEnv(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
    );

    await env.runtime.restoreAndAutoSync();

    // The session came back with NO interactive gesture (silent restore only).
    expect(env.runtime.auth.isAuthenticated, isTrue);
    expect(env.runtime.auth.needsReauth, isFalse);
    // Auto-sync ran: a successful run reached the server and lit the status.
    expect(env.runtime.scheduler.status.totalSyncs, 1);
    expect(env.client.callCount(Method.listTasklists), greaterThan(0));
  });

  test('auto-sync is skipped when auto-sync-on-start is OFF', () async {
    final env = await makeEnv(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
      autoSyncOnStart: false,
    );

    await env.runtime.restoreAndAutoSync();

    // Signed in, but nothing synced automatically.
    expect(env.runtime.auth.isAuthenticated, isTrue);
    expect(env.runtime.scheduler.status.totalSyncs, 0);
    expect(env.client.callCount(Method.listTasklists), 0);
  });

  test('a fresh install with no grant stays quietly signed out', () async {
    final env = await makeEnv(
      tokenProvider: FakeTokenProvider.needsInteraction(),
    );

    await env.runtime.restoreAndAutoSync();

    expect(env.runtime.auth.isAuthenticated, isFalse);
    expect(env.runtime.auth.needsReauth, isFalse);
    expect(env.runtime.scheduler.status.totalSyncs, 0);
    expect(env.client.callCount(Method.listTasklists), 0);
  });

  test('sign-in goes live and triggers a sync', () async {
    final env = await makeEnv(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
    );

    await env.runtime.signIn();

    expect(env.runtime.auth.isAuthenticated, isTrue);
    expect(env.runtime.scheduler.status.totalSyncs, 1);
  });

  test('refresh runs a real sync when authed', () async {
    final env = await makeEnv(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
      autoSyncOnStart: false,
    );
    await env.runtime.restoreAndAutoSync();
    expect(env.runtime.scheduler.status.totalSyncs, 0);

    await env.runtime.refresh();

    expect(env.runtime.scheduler.status.totalSyncs, 1);
  });

  test('refresh signed out is a harmless no-op', () async {
    final env = await makeEnv(
      tokenProvider: FakeTokenProvider.needsInteraction(),
    );
    await env.runtime.restoreAndAutoSync();

    // Must not throw and must not touch the server.
    await env.runtime.refresh();
    expect(env.client.callCount(Method.listTasklists), 0);
  });

  test('fresh sync clears synced local data and re-pulls', () async {
    final env = await makeEnv(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
      autoSyncOnStart: false,
    );
    await env.runtime.restoreAndAutoSync();
    // A synced list that a fresh-sync must drop (local-only survives).
    await env.store.upsertList(
      StoredTaskList(
        list: TaskList(id: 'S1', title: 'Server', etag: 'e', updated: 't'),
        syncState: SyncState.clean,
        localUpdated: 't',
      ),
    );
    await seedLocalList(env.store);

    await env.runtime.freshSync();

    // The synced row was cleared (local-only stays); a re-pull ran.
    final lists = await env.store.allLists();
    expect(lists.map((l) => l.list.id), contains('L1'));
    expect(lists.map((l) => l.list.id), isNot(contains('S1')));
    expect(env.client.callCount(Method.listTasklists), greaterThan(0));
  });

  test(
    'flushOnExit is a no-op when signed out (no destructive push)',
    () async {
      final env = await makeEnv(
        tokenProvider: FakeTokenProvider.needsInteraction(),
        push: true,
      );
      await env.runtime.restoreAndAutoSync();
      await seedLocalList(env.store);

      await env.runtime.flushOnExit();

      // Nothing pushed — a signed-out flush must never round-trip.
      expect(env.client.callCount(Method.insertTasklist), 0);
    },
  );
}
