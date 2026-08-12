// AuthController tests — the ports of `state.rs`'s five auth cases onto the
// three-state machine, plus the two new invariants the migration plan adds:
// #174 (every transition emits so the affordance follows) and #175 (a silent
// restore triggers startup auto-sync with no gesture, and a hung restore never
// gates the first frame).

import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:axiotask/src/auth/auth_controller.dart';
import 'package:axiotask/src/auth/auth_error.dart';
import 'package:axiotask/src/auth/desktop_auth.dart';
import 'package:axiotask/src/auth/desktop_token_provider.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _config = OAuthConfig(clientId: 'id', clientSecret: 'secret');

/// A provider whose authorize never completes — models Play Services / a token
/// endpoint that hangs. Used to prove restore is detached from first frame.
class _HungTokenProvider implements TokenProvider {
  final Completer<String> _never = Completer<String>();
  @override
  Future<String> authorize({required bool interactive}) => _never.future;
  @override
  Future<void> signOut() async {}
}

/// A provider that throws an arbitrary (non-auth-flow) error on authorize —
/// models an unexpected failure escaping the platform seam.
class _ThrowingTokenProvider implements TokenProvider {
  _ThrowingTokenProvider(this.error);
  final Exception error;
  @override
  Future<String> authorize({required bool interactive}) async => throw error;
  @override
  Future<void> signOut() async {}
}

/// A live provider whose remote `signOut` fails — models a raw GMS crash on
/// Android (or an IO error dropping the desktop token file). The grant is live
/// until then, so the controller can sign in and only the sign-out drop breaks.
class _SignOutFailingProvider implements TokenProvider {
  _SignOutFailingProvider(this.token);
  final String token;
  bool signOutAttempted = false;
  @override
  Future<String> authorize({required bool interactive}) async => token;
  @override
  Future<void> signOut() async {
    signOutAttempted = true;
    throw Exception('GMS sign-out blew up');
  }
}

void main() {
  group('five state.rs auth cases', () {
    test('sign-in gesture clears needs-reauth (interactive)', () async {
      final provider = FakeTokenProvider.withToken('live-access-token');
      final controller = AuthController(provider);
      addTearDown(controller.dispose);
      // Start from a dead session — the re-auth banner is showing.
      controller.setNeedsReauth(true);
      expect(controller.needsReauth, isTrue, reason: 'precondition');

      await controller.signIn();

      expect(controller.needsReauth, isFalse, reason: 'banner clears');
      expect(controller.isAuthenticated, isTrue);
      expect(controller.accessToken, 'live-access-token');
      expect(provider.calls, [
        true,
      ], reason: 'sign-in is the interactive gesture');
    });

    test(
      'cancelled sign-in errors and preserves the dead-session state',
      () async {
        final provider = FakeTokenProvider.needsInteraction();
        final controller = AuthController(provider);
        addTearDown(controller.dispose);
        controller.setNeedsReauth(true);

        await expectLater(
          controller.signIn(),
          throwsA(isA<TokenProviderException>()),
        );

        // The dead-session banner is untouched — the app is not falsely signed in.
        expect(controller.needsReauth, isTrue);
        expect(controller.isAuthenticated, isFalse);
        expect(provider.calls, [true]);
      },
    );

    test('silent restore recovers a previously granted session', () async {
      final provider = FakeTokenProvider.withToken('live-access-token');
      final controller = AuthController(provider);
      addTearDown(controller.dispose);
      controller.setNeedsReauth(true);

      final restored = await controller.restore();

      expect(restored, isTrue);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.needsReauth, isFalse);
      expect(provider.calls, [false], reason: 'restore asks once, silently');
    });

    test(
      'fresh install restore stays quietly signed out (no banner)',
      () async {
        final provider = FakeTokenProvider.needsInteraction();
        final controller = AuthController(provider);
        addTearDown(controller.dispose);
        expect(
          controller.needsReauth,
          isFalse,
          reason: 'precondition: no banner',
        );

        final restored = await controller.restore();

        expect(restored, isFalse);
        // A never-signed-in user must NOT see a "session expired" banner.
        expect(controller.needsReauth, isFalse);
        expect(controller.isAuthenticated, isFalse);
        expect(provider.calls, [false]);
      },
    );

    test('restore during an outage stays offline without a banner', () async {
      final provider = FakeTokenProvider.unavailable('GMS updating');
      final controller = AuthController(provider);
      addTearDown(controller.dispose);

      final restored = await controller.restore();

      expect(restored, isFalse, reason: 'an outage cannot restore a session');
      expect(
        controller.needsReauth,
        isFalse,
        reason: 'an outage is not a dead session',
      );
      expect(controller.isAuthenticated, isFalse);
      expect(provider.calls, [false]);
    });
  });

  group('#174 every transition emits on the auth stream', () {
    test(
      'sign-in, needs-reauth, recovery and logout each emit a snapshot',
      () async {
        final provider = FakeTokenProvider.withToken('tok');
        final controller = AuthController(provider);
        addTearDown(controller.dispose);
        final events = StreamQueue<AuthSnapshot>(controller.changes);

        await controller.signIn();
        expect((await events.next).phase, AuthPhase.signedIn);

        // The scheduler flags a dead session after an auth-expired sync.
        controller.setNeedsReauth(true);
        final dead = await events.next;
        expect(dead.phase, AuthPhase.needsReauth);
        expect(
          dead.isAuthenticated,
          isTrue,
          reason: 'a dead session keeps tokens',
        );

        // A later successful sync clears it.
        controller.setNeedsReauth(false);
        expect((await events.next).phase, AuthPhase.signedIn);

        await controller.logout();
        expect((await events.next).phase, AuthPhase.signedOut);

        await events.cancel();
      },
    );

    test(
      'an unchanged setNeedsReauth does not emit a spurious event',
      () async {
        final provider = FakeTokenProvider.withToken('tok');
        final controller = AuthController(provider);
        addTearDown(controller.dispose);
        await controller.signIn();
        final events = StreamQueue<AuthSnapshot>(controller.changes);

        controller.setNeedsReauth(false); // already false — no transition
        controller.setNeedsReauth(true); // real transition

        expect((await events.next).phase, AuthPhase.needsReauth);
        await events.cancel();
      },
    );
  });

  group('logout is robust to a failing provider signOut (G6 / #204)', () {
    test(
      'a raw provider signOut failure still signs the app out (not a no-op)',
      () async {
        final provider = _SignOutFailingProvider('tok');
        final controller = AuthController(provider);
        addTearDown(controller.dispose);
        await controller.signIn();
        expect(controller.isAuthenticated, isTrue, reason: 'precondition');

        // The remote drop throws, but Sign out must NOT be a silent no-op: the
        // local session is cleared first and unconditionally, and the failure is
        // swallowed (logged) rather than escaping the gesture.
        await controller.logout();

        expect(provider.signOutAttempted, isTrue, reason: 'remote drop tried');
        expect(
          controller.isAuthenticated,
          isFalse,
          reason: 'signed out anyway',
        );
        expect(controller.phase, AuthPhase.signedOut);
        expect(controller.accessToken, isNull);
      },
    );

    test(
      'the signed-out transition is emitted even when signOut throws',
      () async {
        final controller = AuthController(_SignOutFailingProvider('tok'));
        addTearDown(controller.dispose);
        await controller.signIn();
        final events = StreamQueue<AuthSnapshot>(controller.changes);

        await controller.logout();

        // The affordance follows the stream (#174): a wedged "signed in" banner
        // would be the visible symptom of a swallowed logout.
        expect((await events.next).phase, AuthPhase.signedOut);
        await events.cancel();
      },
    );
  });

  group('#175 startup restore → auto-sync, never blocking first frame', () {
    test(
      'a successful silent restore triggers auto-sync with no gesture',
      () async {
        final provider = FakeTokenProvider.withToken('tok');
        final controller = AuthController(provider);
        addTearDown(controller.dispose);
        var autoSyncs = 0;

        await controller.restoreThenAutoSync(
          autoSyncOnStart: true,
          onAutoSync: () async => autoSyncs++,
        );

        expect(controller.isAuthenticated, isTrue);
        expect(autoSyncs, 1, reason: 'restore→auto-sync fires once');
        expect(provider.calls, [false], reason: 'no interactive gesture');
      },
    );

    test('auto-sync is skipped when the setting is off', () async {
      final controller = AuthController(FakeTokenProvider.withToken('tok'));
      addTearDown(controller.dispose);
      var autoSyncs = 0;

      await controller.restoreThenAutoSync(
        autoSyncOnStart: false,
        onAutoSync: () async => autoSyncs++,
      );

      expect(controller.isAuthenticated, isTrue);
      expect(autoSyncs, 0);
    });

    test('a failed restore does not trigger auto-sync', () async {
      final controller = AuthController(FakeTokenProvider.needsInteraction());
      addTearDown(controller.dispose);
      var autoSyncs = 0;

      await controller.restoreThenAutoSync(
        autoSyncOnStart: true,
        onAutoSync: () async => autoSyncs++,
      );

      expect(autoSyncs, 0);
      expect(controller.isAuthenticated, isFalse);
    });

    test(
      'a hung restore never completes and never flips state (detached)',
      () async {
        final controller = AuthController(_HungTokenProvider());
        addTearDown(controller.dispose);
        var autoSyncs = 0;

        // Fire-and-forget, exactly as bootstrap runs it after the first frame.
        final pending = controller.restoreThenAutoSync(
          autoSyncOnStart: true,
          onAutoSync: () async => autoSyncs++,
        );

        // Let every pending microtask/event drain: a hung restore must leave the
        // app untouched, so nothing here can gate first paint.
        await pumpEventQueue();
        expect(
          autoSyncs,
          0,
          reason: 'auto-sync waits on a restore that never returns',
        );
        expect(controller.isAuthenticated, isFalse);
        expect(controller.needsReauth, isFalse);
        // The detached future is still pending — proof it can never block a caller
        // that (correctly) does not await it on the render path.
        expect(pending, doesNotComplete);
      },
    );
  });

  group('F9 #189 restore/sign-in exception hardening', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_f9'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File tokensFile() => File(p.join(tmp.path, 'tokens.json'));

    test(
      'a malformed tokens.json restore ends signed-out, emits, never throws',
      () async {
        // A corrupt tokens.json on disk: FileTokenStore.load() raises
        // TokenStoreException, which used to escape restore and kill the
        // detached startup task unobserved.
        final file = tokensFile()..writeAsStringSync('{ not json');
        final provider = DesktopTokenProvider(
          config: _config,
          store: FileTokenStore(file),
          login: (_) async => throw StateError('restore must not log in'),
        );
        final controller = AuthController(provider);
        addTearDown(controller.dispose);
        final events = StreamQueue<AuthSnapshot>(controller.changes);

        final restored = await controller.restore();

        expect(restored, isFalse, reason: 'a corrupt store cannot restore');
        expect(controller.isAuthenticated, isFalse);
        expect(
          controller.needsReauth,
          isFalse,
          reason: 'a corrupt store is not a dead session — no banner',
        );
        expect(
          (await events.next).phase,
          AuthPhase.signedOut,
          reason: 'the failure is emitted, not swallowed',
        );
        await events.cancel();
      },
    );

    test(
      'a malformed-store restore never rejects the detached startup task',
      () async {
        final file = tokensFile()..writeAsStringSync('not even json');
        final controller = AuthController(
          DesktopTokenProvider(
            config: _config,
            store: FileTokenStore(file),
            login: (_) async => throw StateError('restore must not log in'),
          ),
        );
        addTearDown(controller.dispose);
        var autoSyncs = 0;

        // Exactly as bootstrap runs it, detached, after the first frame: the
        // future must COMPLETE (not reject) so nothing dies unobserved.
        await expectLater(
          controller.restoreThenAutoSync(
            autoSyncOnStart: true,
            onAutoSync: () async => autoSyncs++,
          ),
          completes,
        );
        expect(autoSyncs, 0, reason: 'a failed restore skips auto-sync');
        expect(controller.isAuthenticated, isFalse);
      },
    );

    test(
      'a save-failure sign-in ends signed-out, emits, never rejects',
      () async {
        // The loopback login succeeds but persisting the session fails: a
        // FileTokenStore whose chmod lockdown returns non-zero refuses to write
        // the refresh token and raises TokenStoreException from save().
        final file = tokensFile();
        final provider = DesktopTokenProvider(
          config: _config,
          store: FileTokenStore(file, chmod: (_) => 1),
          login: (_) async =>
              const StoredTokens(accessToken: 'a', refreshToken: 'r'),
        );
        final controller = AuthController(provider);
        addTearDown(controller.dispose);
        final events = StreamQueue<AuthSnapshot>(controller.changes);

        // The gesture must not reject the caller with a raw store error.
        await expectLater(controller.signIn(), completes);

        expect(
          controller.isAuthenticated,
          isFalse,
          reason: 'a session that could not be persisted is not a live one',
        );
        expect(controller.needsReauth, isFalse);
        expect((await events.next).phase, AuthPhase.signedOut);
        expect(
          file.existsSync(),
          isFalse,
          reason: 'the empty placeholder was cleaned up on the failed save',
        );
        await events.cancel();
      },
    );

    test('an unexpected error escaping the provider degrades to signed-out '
        'with an emission', () async {
      final controller = AuthController(
        _ThrowingTokenProvider(const TokenStoreException('disk on fire')),
      );
      addTearDown(controller.dispose);
      final events = StreamQueue<AuthSnapshot>(controller.changes);

      final restored = await controller.restore();

      expect(restored, isFalse);
      expect(controller.isAuthenticated, isFalse);
      expect((await events.next).phase, AuthPhase.signedOut);
      await events.cancel();
    });

    test('an expected auth failure still propagates from sign-in, state '
        'untouched', () async {
      // The catch-all must NOT swallow a cancelled/denied gesture: those stay
      // observable to the caller and leave a dead session untouched.
      final controller = AuthController(FakeTokenProvider.needsInteraction());
      addTearDown(controller.dispose);
      controller.setNeedsReauth(true);

      await expectLater(
        controller.signIn(),
        throwsA(isA<TokenProviderException>()),
      );
      expect(controller.needsReauth, isTrue, reason: 'banner preserved');
      expect(controller.isAuthenticated, isFalse);
    });
  });
}
