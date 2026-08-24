// Behavior tests for the standalone Account section (T6.2, extended by #215).
//
// These pin the three auth states (signed in / needs-reauth / signed out) as
// user-visible outcomes: the status phrase, whether the reauth explanation
// shows, the friendly scope labels, and which actions render + route where — so
// a state offering the wrong button (e.g. Sign-out only, with no way back in on
// a dead session) is caught here.
//
// The "Switch account" half (#215) is the destructive one: the reset is the
// single place Undo cannot exist, so what is pinned here is the GATE — it is
// unreachable while a session is live (the ratified order is sign out FIRST),
// it never fires on the button alone, and the confirm only arms once the user
// has typed the word out. Every relaxation of that gate breaks a test.

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
    int pendingPushes = 0,
    String? resetNotice,
    bool resetNoticeIsError = false,
    String? missingConfigPath,
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
              pendingPushes: pendingPushes,
              resetNotice: resetNotice,
              resetNoticeIsError: resetNoticeIsError,
              missingConfigPath: missingConfigPath,
              onSignIn: () => fired.add('signIn'),
              onSignOut: () => fired.add('signOut'),
              onResetLocalData: () => fired.add('reset'),
            ),
          ),
        ),
      ),
    );
    return (fired: fired);
  }

  /// Type into the confirm field. Never `pumpAndSettle` afterwards: the focused
  /// field's caret animates forever, which would hang the settle.
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(
      find.byKey(const Key('reset-data-confirm-field')),
      text,
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  bool confirmArmed(WidgetTester tester) =>
      tester
          .widget<FilledButton>(
            find.byKey(const Key('reset-data-confirm-button')),
          )
          .onPressed !=
      null;

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

  group('switch account — the reset gate (#215)', () {
    testWidgets('the reset is unreachable while a session is live', (
      tester,
    ) async {
      final h = await pumpAccount(
        tester,
        isAuthenticated: true,
        needsReauth: false,
      );

      // The affordance is visible (the user must be able to FIND the flow) but
      // inert: the ratified order is sign out, then erase.
      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('account-reset-data')),
      );
      expect(button.onPressed, isNull);
      expect(find.textContaining('Sign out first'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('account-reset-data')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.byKey(const Key('reset-data-confirm')), findsNothing);
      expect(h.fired, isEmpty);
    });

    testWidgets('a dead session is still a session — reset stays gated', (
      tester,
    ) async {
      // Non-happy path: needs-reauth keeps isAuthenticated true, and erasing
      // there would destroy data the user can still recover by signing in.
      await pumpAccount(tester, isAuthenticated: true, needsReauth: true);

      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('account-reset-data')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('signed out: the button opens a confirm and fires nothing', (
      tester,
    ) async {
      final h = await pumpAccount(
        tester,
        isAuthenticated: false,
        needsReauth: false,
        scopes: const [],
      );

      await tester.tap(find.byKey(const Key('account-reset-data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('reset-data-confirm')), findsOneWidget);
      expect(h.fired, isEmpty, reason: 'the button alone never erases');
      // The DIALOG itself (not just the section blurb behind it) says what dies
      // and what survives — the last thing read before the point of no return.
      Finder inDialog(String text) => find.descendant(
        of: find.byKey(const Key('reset-data-confirm')),
        matching: find.textContaining(text),
      );
      expect(inDialog('cannot be undone'), findsOneWidget);
      expect(inDialog('local-only'), findsOneWidget);
      expect(inDialog('preferences are kept'), findsOneWidget);
    });

    testWidgets('the confirm arms only once the word is typed exactly', (
      tester,
    ) async {
      final h = await pumpAccount(
        tester,
        isAuthenticated: false,
        needsReauth: false,
        scopes: const [],
      );
      await tester.tap(find.byKey(const Key('account-reset-data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(confirmArmed(tester), isFalse, reason: 'disarmed on open');

      await type(tester, 'RES');
      expect(confirmArmed(tester), isFalse, reason: 'a prefix is not the word');

      await type(tester, 'DELETE');
      expect(confirmArmed(tester), isFalse, reason: 'the wrong word disarms');

      await type(tester, 'RESET');
      expect(confirmArmed(tester), isTrue);

      await tester.tap(find.byKey(const Key('reset-data-confirm-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(h.fired, ['reset'], reason: 'only the typed confirm erases');
      expect(find.byKey(const Key('reset-data-confirm')), findsNothing);
    });

    testWidgets('cancelling the confirm erases nothing', (tester) async {
      final h = await pumpAccount(
        tester,
        isAuthenticated: false,
        needsReauth: false,
        scopes: const [],
      );
      await tester.tap(find.byKey(const Key('account-reset-data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await type(tester, 'RESET');

      await tester.tap(find.byKey(const Key('reset-data-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(h.fired, isEmpty);
      expect(find.byKey(const Key('reset-data-confirm')), findsNothing);
    });

    testWidgets('unsynced changes are named in the confirm', (tester) async {
      await pumpAccount(
        tester,
        isAuthenticated: false,
        needsReauth: false,
        scopes: const [],
        pendingPushes: 3,
      );
      await tester.tap(find.byKey(const Key('account-reset-data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('3 change(s) on this device never reached Google'),
        findsOneWidget,
      );
    });

    testWidgets('no unsynced changes: no scary warning is invented', (
      tester,
    ) async {
      await pumpAccount(
        tester,
        isAuthenticated: false,
        needsReauth: false,
        scopes: const [],
      );
      await tester.tap(find.byKey(const Key('account-reset-data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('never reached Google'), findsNothing);
    });

    testWidgets('the outcome is reported where the action was taken', (
      tester,
    ) async {
      await pumpAccount(
        tester,
        isAuthenticated: false,
        needsReauth: false,
        scopes: const [],
        resetNotice: 'Erased 4 task(s) in 2 list(s).',
      );

      expect(find.byKey(const Key('account-reset-notice')), findsOneWidget);
      expect(find.text('Erased 4 task(s) in 2 list(s).'), findsOneWidget);
    });

    testWidgets('the confirm stays usable on a phone at 1.3x text scale', (
      tester,
    ) async {
      // Non-happy path: the smallest screen the app targets, large text, and a
      // raised keyboard. The warning + unsynced line + field is a tall stack;
      // if it cannot scroll, the confirm field is clipped out of reach and the
      // user is stuck staring at an overflow stripe.
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(1.3),
              viewInsets: EdgeInsets.only(bottom: 300),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: AccountSection(
                  isAuthenticated: false,
                  needsReauth: false,
                  scopes: const [],
                  pendingPushes: 2,
                  onSignIn: () {},
                  onSignOut: () {},
                  onResetLocalData: () {},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.ensureVisible(find.byKey(const Key('account-reset-data')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-reset-data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: 'nothing overflowed');

      // The field is reachable: the dialog scrolls it into view, and typing
      // into it arms the confirm.
      await tester.ensureVisible(
        find.byKey(const Key('reset-data-confirm-field')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await type(tester, 'RESET');
      expect(confirmArmed(tester), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('#228 an unconfigured install says so on the Account tab', () {
    const configPath = '/home/u/.config/axiotask/config.json';

    testWidgets('the setup block names the file and the way to fix it', (
      tester,
    ) async {
      final h = await pumpAccount(
        tester,
        isAuthenticated: false,
        needsReauth: false,
        scopes: const [],
        missingConfigPath: configPath,
      );

      expect(find.byKey(const Key('account-not-configured')), findsOneWidget);
      expect(find.textContaining(configPath), findsOneWidget);
      expect(find.textContaining('README'), findsOneWidget);
      // Not the quiet idle — the status line itself says setup is pending.
      expect(find.text('Not signed in — setup required'), findsOneWidget);

      // The gesture stays reachable: it is what produces the toast (#228).
      await tester.tap(find.byKey(const Key('account-signin')));
      await tester.pump();
      expect(h.fired, ['signIn']);
    });

    testWidgets('a configured signed-out install shows no setup block', (
      tester,
    ) async {
      await pumpAccount(
        tester,
        isAuthenticated: false,
        needsReauth: false,
        scopes: const [],
      );

      expect(find.byKey(const Key('account-not-configured')), findsNothing);
      expect(find.text('Not signed in'), findsOneWidget);
    });

    testWidgets('signed out grants nothing, so no Access is listed', (
      tester,
    ) async {
      // The Access list is what Google HAS granted; showing the requested scope
      // to someone with no session made the tab read as signed in (#228).
      await pumpAccount(
        tester,
        isAuthenticated: false,
        needsReauth: false,
        scopes: const [],
      );

      expect(find.text('Access'), findsNothing);
      expect(find.text('Google Tasks — read & write'), findsNothing);
      expect(find.byKey(const Key('account-signout')), findsNothing);
      expect(find.text('Sign in with Google'), findsOneWidget);
    });
  });
}
