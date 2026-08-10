// AuthController tests — the ports of `state.rs`'s five auth cases onto the
// three-state machine, plus the two new invariants the migration plan adds:
// #174 (every transition emits so the affordance follows) and #175 (a silent
// restore triggers startup auto-sync with no gesture, and a hung restore never
// gates the first frame).

import 'dart:async';

import 'package:async/async.dart';
import 'package:axiotask/src/auth/auth_controller.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// A provider whose authorize never completes — models Play Services / a token
/// endpoint that hangs. Used to prove restore is detached from first frame.
class _HungTokenProvider implements TokenProvider {
  final Completer<String> _never = Completer<String>();
  @override
  Future<String> authorize({required bool interactive}) => _never.future;
  @override
  Future<void> signOut() async {}
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
}
