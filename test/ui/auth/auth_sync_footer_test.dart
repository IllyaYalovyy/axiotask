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
}
