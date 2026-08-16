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
import 'package:axiotask/src/api/tasks_api.dart' show TasksApi;
import 'package:axiotask/src/app/auth_sync_runtime.dart';
import 'package:axiotask/src/app/authed_api.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:axiotask/src/app/logging.dart';
import 'package:axiotask/src/app/providers.dart' show commandsProvider;
import 'package:axiotask/src/auth/auth_controller.dart';
import 'package:axiotask/src/auth/desktop_auth.dart' show OAuthConfig;
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
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
    TasksApi? Function(String accessToken)? buildClient,
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
      buildClient: buildClient ?? (accessToken) => client,
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

  test('a successful manual Sync now clears needs-reauth (scheduler contract, '
      'G6 / #204)', () async {
    final env = await makeEnv(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
      autoSyncOnStart: false,
    );
    // Signed in with a live client, nothing synced yet.
    await env.runtime.restoreAndAutoSync();
    expect(env.runtime.auth.isAuthenticated, isTrue, reason: 'precondition');

    // Simulate the scheduler having flagged a dead session after an
    // auth-expired background sync. The tokens (and client) are still present:
    // needsReauth is the "sign in again" banner, distinct from signed-out.
    env.runtime.auth.setNeedsReauth(true);
    expect(env.runtime.auth.needsReauth, isTrue, reason: 'precondition');

    // The user hits "Sync now" — an explicit re-check. Its documented contract
    // is that a SUCCESS clears the dead-session flag. Before G6 the runtime
    // guarded the manual path on needsReauth, so this ran nothing and the
    // banner stayed stuck until a full re-login.
    await env.runtime.refresh();

    expect(
      env.runtime.scheduler.status.totalSyncs,
      1,
      reason: 'the manual sync actually ran, not short-circuited',
    );
    expect(
      env.runtime.auth.needsReauth,
      isFalse,
      reason: 'a successful manual sync clears needs-reauth',
    );
    expect(env.runtime.scheduler.status.needsReauth, isFalse);
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

  // ── G2 / #203: the desktop client rebuild is crash-proof ──────────────────
  //
  // The desktop builder reads the FULL token bundle back from tokens.json at
  // rebuild time (the bare access token the runtime carries is not enough — the
  // refresh token drives the 401 seam). If that file is deleted or corrupted
  // between the session being acquired and the rebuild reading it, the old code
  // did `store.load()!` and CRASHED: a missing file threw a TypeError (killing
  // the detached startup task) or a malformed one a TokenStoreException, and on
  // the sign-in path it stranded isAuthenticated=true with _client=null — every
  // later sync then threw a StateError. These pin the crash-proof behavior.
  group('desktop client rebuild is crash-proof (G2 / #203)', () {
    const oauth = OAuthConfig(clientId: 'cid', clientSecret: 'secret');

    // A real tokens.json seeded with a valid bundle, wired to the PRODUCTION
    // desktop builder — so the test exercises the actual disk-read rebuild path.
    FileTokenStore seedStore() {
      final store = FileTokenStore(File(p.join(tmp.path, 'tokens.json')));
      store.save(
        const StoredTokens(
          accessToken: 'access-1',
          refreshToken: 'rt',
          scope: 'tasks',
        ),
      );
      return store;
    }

    test(
      'restore with tokens.json deleted between load and rebuild ends '
      'needs-reauth, the startup future completing (never a throw)',
      () async {
        final tokenStore = seedStore();
        final env = await makeEnv(
          // The provider hands back a live token, but the tokens file is gone
          // by the time the rebuild reads it back (the modeled race).
          tokenProvider: _FileVanishingProvider(
            file: tokenStore.file,
            token: 'access-1',
          ),
          buildClient: (_) =>
              buildDesktopTasksApiFromStore(store: tokenStore, config: oauth),
        );

        final snapshots = <AuthSnapshot>[];
        final sub = env.runtime.auth.changes.listen(snapshots.add);
        addTearDown(sub.cancel);

        // The awaitable startup prefix must COMPLETE, not reject — a throw here
        // is exactly the bug (it killed the detached startup task).
        await env.runtime.restoreAndAutoSync();
        // Drain the broadcast stream so the emitted transitions are observable.
        await pumpEventQueue();

        expect(
          env.runtime.auth.needsReauth,
          isTrue,
          reason: 'a session that vanished before rebuild is a dead session',
        );
        expect(
          env.runtime.scheduler.status.totalSyncs,
          0,
          reason: 'no auto-sync runs without a client',
        );
        expect(
          snapshots.map((s) => s.phase),
          contains(AuthPhase.needsReauth),
          reason: 'the flip emits so the footer follows without polling',
        );
      },
    );

    test('sign-in with the store wiped mid-gesture never yields the '
        'signed-in-without-client state ("Sync now" stays a no-op)', () async {
      final tokenStore = seedStore();
      final env = await makeEnv(
        tokenProvider: _FileVanishingProvider(
          file: tokenStore.file,
          token: 'access-1',
        ),
        buildClient: (_) =>
            buildDesktopTasksApiFromStore(store: tokenStore, config: oauth),
      );

      // The gesture completes without an unhandled throw...
      await env.runtime.signIn();

      // ...and lands in needs-reauth, NOT signed-in-with-a-null-client (the
      // footer would show "sign in again", not a live session).
      expect(env.runtime.auth.needsReauth, isTrue);
      expect(env.runtime.scheduler.status.totalSyncs, 0);

      // "Sync now" must be a harmless no-op, not a StateError rethrown into
      // the button handler.
      await env.runtime.refresh();
      expect(env.runtime.scheduler.status.totalSyncs, 0);
      expect(env.client.callCount(Method.listTasklists), 0);
    });
  });

  // #209: a local change must start the debounced sync — the periodic cycle
  // (60s here, untouched) exists to pick up REMOTE edits. Observable outcome:
  // with the background loop running, one mutation through the runtime-mounted
  // commandsProvider reaches the fake server within the debounce (zero in this
  // harness), decades before the periodic cycle could.
  test('a local mutation through the mounted commands triggers the debounced '
      'sync (#209)', () async {
    final env = await makeEnv(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
      autoSyncOnStart: false,
    );
    await env.runtime.restoreAndAutoSync();
    expect(env.runtime.scheduler.status.totalSyncs, 0);

    env.runtime.startLoop();
    final container = ProviderContainer(overrides: env.runtime.overrides);
    addTearDown(container.dispose);

    await container.read(commandsProvider).createList('local change');

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (env.runtime.scheduler.status.totalSyncs == 0 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      env.runtime.scheduler.status.totalSyncs,
      greaterThan(0),
      reason:
          'the mutation must trigger a sync at the debounce, '
          'not wait for the periodic cycle',
    );
    expect(env.client.callCount(Method.listTasklists), greaterThan(0));
  });
}

/// A [TokenProvider] that hands back a live access token but deletes [file] as a
/// side effect of authorizing — modeling the race the G2 fix defends against: a
/// tokens.json that is gone by the time the desktop client rebuild reads it back
/// (restore and sign-in both go through `authorize`).
class _FileVanishingProvider implements TokenProvider {
  _FileVanishingProvider({required this.file, required this.token});

  final File file;
  final String token;

  @override
  Future<String> authorize({required bool interactive}) async {
    if (file.existsSync()) file.deleteSync();
    return token;
  }

  @override
  Future<void> signOut() async {}
}
