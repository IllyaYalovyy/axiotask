// F5 (#176) composition-root wiring at the widget level — the live sidebar
// footer and the mobile pull-to-refresh driven by the REAL [AuthSyncRuntime]
// over a fake token provider and the in-memory fake API.
//
// These assert what the USER SEES: the footer's primary affordance and status
// phrase before and after sign-in, that a FAILED sign-in gesture says so out
// loud (#212), and that a pull-to-refresh actually reaches the (fake) server
// when a session is live — never "a method was called".

import 'dart:io';

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/auth_sync_runtime.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/auth/auth_error.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/ui/auth/sidebar_auth_sync_footer.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/toast.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../detail_harness.dart' show FakeBackend, list, row;
import '../toast_harness.dart' show wrapWithToast;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_f5_ui'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<AuthSyncRuntime> makeRuntime({
    required TokenProvider tokenProvider,
    bool autoSyncOnStart = false,
    FakeTasksApi? client,
  }) async {
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final config = ConfigController(
      path: File(p.join(tmp.path, 'config.json')),
      initial: AppConfig(sync: SyncConfig(autoSyncOnStart: autoSyncOnStart)),
    );
    final runtime = AuthSyncRuntime(
      store: Store(db),
      config: config,
      tokenProvider: tokenProvider,
      buildClient: (_) => client ?? FakeTasksApi(),
      debounce: Duration.zero,
    );
    addTearDown(runtime.dispose);
    return runtime;
  }

  // A bounded settle — the footer's streams and the sync futures deliver on
  // microtasks/the event loop; a couple of frames plus a real delay is enough.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpFooter(WidgetTester tester, AuthSyncRuntime runtime) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: runtime.overrides,
        // The REAL toast overlay, bound to the ambient controller — the surface
        // a failed sign-in gesture must reach (#212).
        child: MaterialApp(
          builder: wrapWithToast,
          home: const Scaffold(body: SidebarAuthSyncFooter()),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('signed out, the footer offers Sign in and reads Offline', (
    tester,
  ) async {
    final runtime = await makeRuntime(
      tokenProvider: FakeTokenProvider.needsInteraction(),
    );
    await pumpFooter(tester, runtime);

    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    // No session → no Sign out affordance and no Sync button.
    expect(find.byKey(const Key('auth-footer-signout')), findsNothing);
    expect(find.byKey(const Key('auth-footer-sync')), findsNothing);
  });

  testWidgets('signing in transitions the footer and livens the status', (
    tester,
  ) async {
    // A live grant behind the interactive gesture; auto-sync-on-start off so the
    // ONLY sync is the one sign-in itself triggers.
    final runtime = await makeRuntime(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
    );
    await pumpFooter(tester, runtime);
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);

    // Tap the footer's sign-in button — the same action the Account tab drives.
    await tester.tap(find.byKey(const Key('auth-footer-signin')));
    await settle(tester);

    // The footer followed the state change with no polling: signed in now, so
    // Sign out is offered and the status text livened from "Offline".
    expect(find.byKey(const Key('auth-footer-signout')), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
    // Sign-in kicked off a first sync, so the status reads "Synced …".
    expect(find.textContaining('Synced'), findsOneWidget);
    expect(runtime.scheduler.status.totalSyncs, 1);
  });

  testWidgets('a sign-in that fails with a provider outage says so out loud', (
    tester,
  ) async {
    // Play Services down / no network: the gesture cannot succeed and the user
    // did NOT cancel it, so an inert button is a defect (#212).
    final runtime = await makeRuntime(
      tokenProvider: FakeTokenProvider.unavailable(
        'SERVICE_DISABLED: com.google.android.gms raw detail',
      ),
    );
    await pumpFooter(tester, runtime);

    await tester.tap(find.byKey(const Key('auth-footer-signin')));
    await settle(tester);

    // ONE error toast, in words the user can act on.
    expect(find.byType(ToastCard), findsOneWidget);
    expect(
      find.text(
        "Couldn't sign in — Google sign-in is unavailable right now. "
        'Check your connection and try again.',
      ),
      findsOneWidget,
    );
    // The provider's raw text never reaches the screen (#131/#187).
    expect(find.textContaining('SERVICE_DISABLED'), findsNothing);
    expect(find.textContaining('gms'), findsNothing);
    // The failed gesture left the state exactly as it was (invariant #6).
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);

    // Let the toast lapse so no auto-dismiss timer outlives the test.
    await tester.pump(kErrorToastDuration);
  });

  testWidgets('a cancelled sign-in stays silent — no toast', (tester) async {
    // The user closed the account picker / never granted the scope: they know
    // what happened, so feedback would be noise (#212).
    final runtime = await makeRuntime(
      tokenProvider: FakeTokenProvider.needsInteraction(),
    );
    await pumpFooter(tester, runtime);

    await tester.tap(find.byKey(const Key('auth-footer-signin')));
    await settle(tester);

    expect(find.byType(ToastCard), findsNothing);
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('a sign-in the OAuth flow rejects says so out loud', (
    tester,
  ) async {
    // The desktop loopback flow came back denied/mismatched: not a cancelled
    // picker, so the user is owed an answer (#212).
    final runtime = await makeRuntime(
      tokenProvider: _ThrowingTokenProvider(
        const AuthStateMismatch('oauth state mismatch: nonce=abc123'),
      ),
    );
    await pumpFooter(tester, runtime);

    await tester.tap(find.byKey(const Key('auth-footer-signin')));
    await settle(tester);

    expect(find.byType(ToastCard), findsOneWidget);
    expect(
      find.text("Couldn't sign in with Google. The details are in the log."),
      findsOneWidget,
    );
    // The OAuth detail (which can carry a nonce/URL) stays in the log.
    expect(find.textContaining('nonce'), findsNothing);
    expect(find.textContaining('mismatch'), findsNothing);
    expect(find.text('Sign in with Google'), findsOneWidget);

    await tester.pump(kErrorToastDuration);
  });

  testWidgets('the footer Sync button runs a real sync when authed', (
    tester,
  ) async {
    final client = FakeTasksApi();
    final runtime = await makeRuntime(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
      client: client,
    );
    // Bring a live session up WITHOUT any sync yet (auto-sync off).
    await runtime.restoreAndAutoSync();
    await pumpFooter(tester, runtime);
    expect(runtime.scheduler.status.totalSyncs, 0);
    expect(find.byKey(const Key('auth-footer-sync')), findsOneWidget);

    await tester.tap(find.byKey(const Key('auth-footer-sync')));
    await settle(tester);

    // The real refresh action reached the server and lit the status.
    expect(runtime.scheduler.status.totalSyncs, 1);
    expect(client.callCount(Method.listTasklists), greaterThan(0));
    expect(find.textContaining('Synced'), findsOneWidget);
  });

  testWidgets('pull-to-refresh triggers a sync when a session is live', (
    tester,
  ) async {
    const phone = Size(400, 800);
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = FakeTasksApi();
    final runtime = await makeRuntime(
      tokenProvider: FakeTokenProvider.withToken('access-1'),
      client: client,
    );
    await runtime.restoreAndAutoSync(); // live session, nothing synced yet
    expect(runtime.scheduler.status.totalSyncs, 0);

    final fake = FakeBackend([row('T1', 'a'), row('T2', 'b'), row('T3', 'c')]);
    addTearDown(fake.dispose);

    final destinations = [
      for (final v in SmartView.values)
        ShellDestination(
          icon: v.icon,
          selectedIcon: v.selectedIcon,
          label: v.label,
        ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...runtime.overrides,
          prefsProvider.overrideWithValue(
            const Prefs(sortPerView: {'all': 'alpha'}),
          ),
          // No commandsProvider override here: runtime.overrides now mounts
          // the runtime's own mutation-triggering Commands (#209), and this
          // test only reads rows from the stream override below.
          allTasksProvider.overrideWith((ref) => fake.tasksStream),
          listsProvider.overrideWith((ref) => Stream.value([list('L1', 'L')])),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: phone),
            child: Consumer(
              builder: (context, ref, _) => ListDetailScaffold(
                sidebar: const Text('SIDEBAR'),
                destinations: destinations,
                selectedIndex: SmartView.all.index,
                onDestinationSelected: (_) {},
                title: 'All Tasks',
                onNewTask: () {},
                list: const TaskListView(
                  viewId: 'all',
                  selectedTaskId: null,
                  onOpenTask: _noop,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);

    // Pull down from the top of the list — the real refresh action fires.
    await tester.fling(find.text('a'), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);

    expect(
      runtime.scheduler.status.totalSyncs,
      1,
      reason: 'the pull ran a real sync against the live session',
    );
    expect(client.callCount(Method.listTasklists), greaterThan(0));
  });
}

void _noop(String _) {}

/// A [TokenProvider] whose interactive gesture always fails with [error] — the
/// shapes [FakeTokenProvider] cannot produce (an OAuth-flow [AuthException]).
class _ThrowingTokenProvider implements TokenProvider {
  _ThrowingTokenProvider(this.error);

  final Exception error;

  @override
  Future<String> authorize({required bool interactive}) async => throw error;

  @override
  Future<void> signOut() async {}
}
