// Behavior tests for the standalone auth/sync footer (T6.2).
//
// These pin the footer's PRIORITY LADDER (needsReauth > needsAttention > sync)
// and its sign-in/out routing as user-visible outcomes: which button renders,
// what the status line reads, and — load-bearing — which callback a tap fires,
// so a mis-wired priority (e.g. offering "Sync now" on a dead session, which
// could only fail) is caught here, not by the user.

import 'package:axiotask/src/ui/auth/auth_sync_footer.dart';
import 'package:axiotask/src/ui/auth/auth_sync_status.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Pump the footer for [status]; the returned record exposes what each
  /// callback recorded so a tap's ROUTING (not just that some button exists)
  /// is assertable.
  Future<({List<String> fired})> pumpFooter(
    WidgetTester tester,
    AuthSyncStatus status,
  ) async {
    final fired = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: AuthSyncFooter(
              status: status,
              onSignIn: () => fired.add('signIn'),
              onSignOut: () => fired.add('signOut'),
              onSync: () => fired.add('sync'),
              onOpenProperties: () => fired.add('properties'),
            ),
          ),
        ),
      ),
    );
    return (fired: fired);
  }

  testWidgets('needsReauth outranks needsAttention and sync', (tester) async {
    // A dead session that ALSO has a stuck failure and live tokens: the ladder
    // must surface re-auth, hide the attention button, and never offer Sync.
    final h = await pumpFooter(
      tester,
      const AuthSyncStatus(
        isAuthenticated: true,
        needsReauth: true,
        needsAttention: true,
      ),
    );

    expect(find.text('Sign in again'), findsOneWidget);
    expect(find.text('Session expired'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
    expect(find.text('Sync needs attention'), findsNothing);

    await tester.tap(find.byKey(const Key('auth-footer-signin')));
    expect(h.fired, ['signIn']);
  });

  testWidgets('needsAttention shows the attention button and keeps Sync', (
    tester,
  ) async {
    final h = await pumpFooter(
      tester,
      const AuthSyncStatus(
        isAuthenticated: true,
        needsReauth: false,
        needsAttention: true,
      ),
    );

    expect(find.text('Sync needs attention'), findsOneWidget);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);

    // The attention button routes to Properties, where the cause lives (#136).
    await tester.tap(find.byKey(const Key('auth-footer-attention')));
    expect(h.fired, ['properties']);
  });

  testWidgets('signed out offers Google sign-in and hides Sign out/Sync', (
    tester,
  ) async {
    final h = await pumpFooter(
      tester,
      const AuthSyncStatus(isAuthenticated: false, needsReauth: false),
    );

    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Sign out'), findsNothing);
    expect(find.text('Sync now'), findsNothing);

    await tester.tap(find.byKey(const Key('auth-footer-signin')));
    expect(h.fired, ['signIn']);
  });

  testWidgets('signed in offers Sync now + Sign out, routing each tap', (
    tester,
  ) async {
    // A healthy session synced 5 minutes ago (clock frozen for a stable label).
    await withClock(Clock.fixed(DateTime.utc(2026, 1, 1, 12, 5)), () async {
      final h = await pumpFooter(
        tester,
        const AuthSyncStatus(
          isAuthenticated: true,
          needsReauth: false,
          lastSynced: '2026-01-01T12:00:00.000Z',
        ),
      );

      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Synced 5m ago'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsNothing);

      await tester.tap(find.byKey(const Key('auth-footer-sync')));
      await tester.tap(find.byKey(const Key('auth-footer-signout')));
      expect(h.fired, ['sync', 'signOut']);
    });
  });

  testWidgets('a run in flight disables the primary button (non-happy)', (
    tester,
  ) async {
    final h = await pumpFooter(
      tester,
      const AuthSyncStatus(
        isAuthenticated: true,
        needsReauth: false,
        activity: SyncActivity.syncing,
      ),
    );

    expect(find.text('Syncing…'), findsOneWidget);
    // Disabled: the tap does nothing, no second run is queued.
    await tester.tap(find.byKey(const Key('auth-footer-sync')));
    expect(h.fired, isEmpty);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('auth-footer-sync')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a surfaced error reads "Sync error" below needsAttention', (
    tester,
  ) async {
    await pumpFooter(
      tester,
      const AuthSyncStatus(
        isAuthenticated: true,
        needsReauth: false,
        hasError: true,
      ),
    );

    expect(find.text('Sync error'), findsOneWidget);
    // Still a live session, so Sync-now remains the action.
    expect(find.text('Sync now'), findsOneWidget);
  });

  testWidgets('the synced phrase hides the absolute local time in a tooltip', (
    tester,
  ) async {
    // #222: "Synced 12m ago" is friendly but unverifiable. The absolute time is
    // one hover/long-press away — never inline (no clutter), never UTC/ISO.
    // The moment is built from LOCAL calendar fields and stored as the UTC
    // instant sync persists, so a UTC-rendering implementation shows different
    // digits in any non-UTC zone and fails here.
    final syncedAt = DateTime(2026, 8, 22, 10, 48);
    final now = syncedAt.add(const Duration(minutes: 12));
    await withClock(Clock.fixed(now), () async {
      await pumpFooter(
        tester,
        AuthSyncStatus(
          isAuthenticated: true,
          needsReauth: false,
          lastSynced: syncedAt.toUtc().toIso8601String(),
        ),
      );

      expect(find.text('Synced 12m ago'), findsOneWidget);
      // Nothing absolute on screen until the user asks for it.
      expect(find.text('Last sync: Aug 22 10:48'), findsNothing);

      // Touch has no hover: the coarse-pointer path is a long press.
      await tester.longPress(find.text('Synced 12m ago'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Last sync: Aug 22 10:48'), findsOneWidget);

      // Let the tooltip time out and fade so no timer outlives the test.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('a footer with nothing to date carries no tooltip (non-happy)', (
    tester,
  ) async {
    // Never synced: there is no absolute time, so there must be no tooltip to
    // long-press — an empty or "Last sync: recently" bubble would be a lie.
    await pumpFooter(
      tester,
      const AuthSyncStatus(isAuthenticated: true, needsReauth: false),
    );

    expect(find.text('Ready'), findsOneWidget);
    await tester.longPress(find.text('Ready'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Last sync'), findsNothing);
    expect(find.byType(Tooltip), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('an unparseable stamp carries no tooltip (non-happy)', (
    tester,
  ) async {
    // The relative label degrades to "recently" for a stamp it cannot parse;
    // there is no absolute time behind it, so nothing may claim one.
    await pumpFooter(
      tester,
      const AuthSyncStatus(
        isAuthenticated: true,
        needsReauth: false,
        lastSynced: 'not-a-timestamp',
      ),
    );

    expect(find.text('Synced recently'), findsOneWidget);
    await tester.longPress(find.text('Synced recently'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Last sync'), findsNothing);
    expect(find.byType(Tooltip), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  group('#228 missing credentials outrank every other footer state', () {
    const configPath = '/home/u/.config/axiotask/config.json';

    testWidgets('the footer says setup is required and offers the way in', (
      tester,
    ) async {
      final h = await pumpFooter(
        tester,
        const AuthSyncStatus(
          isAuthenticated: false,
          needsReauth: false,
          missingConfigPath: configPath,
        ),
      );

      // Not the quiet "Offline" idle: a persistent, named attention state.
      expect(find.text('Setup required'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('Google setup needed'), findsOneWidget);

      // And it goes somewhere — Properties, where the config path is named.
      await tester.tap(find.byKey(const Key('auth-footer-not-configured')));
      await tester.pump();
      expect(h.fired, ['properties']);
    });

    testWidgets('the sign-in affordance stays, so the message is reachable', (
      tester,
    ) async {
      // The gesture is where the actionable sentence comes from (#228): the
      // button must remain tappable rather than be disabled into silence.
      final h = await pumpFooter(
        tester,
        const AuthSyncStatus(
          isAuthenticated: false,
          needsReauth: false,
          missingConfigPath: configPath,
        ),
      );

      await tester.tap(find.byKey(const Key('auth-footer-signin')));
      await tester.pump();
      expect(h.fired, ['signIn']);
      // No session, so nothing may offer to sign out or sync.
      expect(find.byKey(const Key('auth-footer-signout')), findsNothing);
      expect(find.byKey(const Key('auth-footer-sync')), findsNothing);
    });

    testWidgets('it displaces the stuck-sync attention button', (tester) async {
      // Both faults at once: "Sync needs attention" would send the user
      // chasing a sync that cannot run at all without credentials.
      await pumpFooter(
        tester,
        const AuthSyncStatus(
          isAuthenticated: false,
          needsReauth: false,
          needsAttention: true,
          hasError: true,
          missingConfigPath: configPath,
        ),
      );

      expect(find.text('Google setup needed'), findsOneWidget);
      expect(find.text('Sync needs attention'), findsNothing);
      expect(find.text('Setup required'), findsOneWidget);
      expect(find.text('Sync error'), findsNothing);
    });

    testWidgets('a configured install is untouched', (tester) async {
      await pumpFooter(
        tester,
        const AuthSyncStatus(isAuthenticated: false, needsReauth: false),
      );

      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.byKey(const Key('auth-footer-not-configured')), findsNothing);
    });
  });
}
