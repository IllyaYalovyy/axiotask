// Behavior tests for the standalone Account section (T6.2).
//
// These pin the three auth states (signed in / needs-reauth / signed out) as
// user-visible outcomes: the status phrase, whether the reauth explanation
// shows, the friendly scope labels, and which actions render + route where — so
// a state offering the wrong button (e.g. Sign-out only, with no way back in on
// a dead session) is caught here.

import 'package:axiotask/src/ui/auth/account_section.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<({List<String> fired})> pumpAccount(
    WidgetTester tester, {
    required bool isAuthenticated,
    required bool needsReauth,
    List<String> scopes = const ['https://www.googleapis.com/auth/tasks'],
  }) async {
    final fired = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: AccountSection(
              isAuthenticated: isAuthenticated,
              needsReauth: needsReauth,
              scopes: scopes,
              onSignIn: () => fired.add('signIn'),
              onSignOut: () => fired.add('signOut'),
            ),
          ),
        ),
      ),
    );
    return (fired: fired);
  }

  testWidgets('signed in: status, friendly scope, Sign out only', (
    tester,
  ) async {
    final h = await pumpAccount(
      tester,
      isAuthenticated: true,
      needsReauth: false,
    );

    expect(find.text('Signed in'), findsOneWidget);
    expect(find.text('Google Tasks — read & write'), findsOneWidget);
    // No raw scope URL leaks to the user.
    expect(find.textContaining('googleapis.com'), findsNothing);
    expect(find.byKey(const Key('account-signin')), findsNothing);

    await tester.tap(find.byKey(const Key('account-signout')));
    expect(h.fired, ['signOut']);
  });

  testWidgets('needs reauth: expired status, hint, both actions routed', (
    tester,
  ) async {
    final h = await pumpAccount(
      tester,
      isAuthenticated: true,
      needsReauth: true,
    );

    expect(find.text('Session expired — sign in again'), findsOneWidget);
    expect(find.byKey(const Key('account-reauth-hint')), findsOneWidget);
    // A dead session must offer BOTH a way back in and a way out.
    expect(find.text('Sign in again'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);

    await tester.tap(find.byKey(const Key('account-signin')));
    expect(h.fired, ['signIn']);
  });

  testWidgets('signed out: not-signed-in, no scopes block, sign-in only', (
    tester,
  ) async {
    // Non-happy path: no session, so the Access block and its scopes hide.
    final h = await pumpAccount(
      tester,
      isAuthenticated: false,
      needsReauth: false,
      scopes: const [],
    );

    expect(find.text('Not signed in'), findsOneWidget);
    expect(find.text('Access'), findsNothing);
    expect(find.byKey(const Key('account-reauth-hint')), findsNothing);
    expect(find.byKey(const Key('account-signout')), findsNothing);
    expect(find.text('Sign in with Google'), findsOneWidget);

    await tester.tap(find.byKey(const Key('account-signin')));
    expect(h.fired, ['signIn']);
  });

  testWidgets('read-only scope gets its own friendly label', (tester) async {
    await pumpAccount(
      tester,
      isAuthenticated: true,
      needsReauth: false,
      scopes: const ['https://www.googleapis.com/auth/tasks.readonly'],
    );

    expect(find.text('Google Tasks — read only'), findsOneWidget);
  });
}
