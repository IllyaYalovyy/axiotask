// The reported first production install (#228), reproduced end to end.
//
// The Flutter build took over the directory the Tauri build left behind: its
// `config.toml`, its WebKit session files, and — after a fresh wipe — NO
// `tokens.json`. Finding no `config.json`, bootstrap wrote its default, whose
// `google` section is EMPTY, and the app was left unable to authenticate at
// all. What the user saw was silence: no error anywhere, no sync, and an
// Account tab that read as though a session existed.
//
// This runs the REAL sequence — [bootstrap] over that directory, then the real
// composition root [buildRuntime] — so a defect in the desktop wiring itself is
// caught here rather than restated. What is asserted is what renders: the
// persistent setup-required state naming the file to edit, and the absence of
// any affordance or grant that would imply a session.

import 'dart:io';

import 'package:axiotask/main.dart' show buildRuntime;
import 'package:axiotask/src/app/auth_sync_runtime.dart';
import 'package:axiotask/src/app/bootstrap.dart';
import 'package:axiotask/src/app/instance.dart';
import 'package:axiotask/src/ui/auth/sidebar_auth_sync_footer.dart';
import 'package:axiotask/src/ui/properties.dart';
import 'package:axiotask/src/ui/url_opener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../ui/toast_harness.dart' show wrapWithToast;

void main() {
  late Directory tmp;
  late Directory dataBase;
  late Directory configBase;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('axiotask_228_takeover');
    dataBase = Directory(p.join(tmp.path, 'data'))..createSync();
    configBase = Directory(p.join(tmp.path, 'config'))..createSync();

    // The foreign leftovers, in the shape they were found: the Tauri build's
    // TOML config — which carries credentials this build cannot read — beside
    // the WebKit state it kept. Deliberately no tokens.json: the wipe removed
    // it, so nothing on disk grants a session.
    final cfgDir = Directory(p.join(configBase.path, appDirName(env: const {})))
      ..createSync(recursive: true);
    File(p.join(cfgDir.path, 'config.toml')).writeAsStringSync(
      '[google]\nclient_id = "left-over.apps.googleusercontent.com"\n'
      'client_secret = "left-over-secret"\n',
    );
    final dataDir = Directory(p.join(dataBase.path, appDirName(env: const {})))
      ..createSync(recursive: true);
    final webkit = Directory(p.join(dataDir.path, 'EphemeralNetworkSession'))
      ..createSync(recursive: true);
    File(
      p.join(webkit.path, 'resource-load-statistics.db'),
    ).writeAsStringSync('leftover WebKit state');
    Directory(p.join(dataDir.path, 'localstorage')).createSync(recursive: true);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// One real cold start over the takeover directory: bootstrap, the real
  /// desktop composition root, then the detached restore — awaited here so the
  /// test never races the startup task.
  Future<({BootstrapReady ready, AuthSyncRuntime runtime})>
  firstLaunch() async {
    final result = await bootstrap(
      dataBase: dataBase,
      configBase: configBase,
      env: const {},
    );
    final ready = result as BootstrapReady;
    addTearDown(ready.database.close);

    // The fixture really is the reported situation, not an approximation of it:
    // no session on disk, and a config.json written with blank credentials
    // because the leftover TOML is not a file this build reads.
    expect(ready.tokensFile.existsSync(), isFalse);
    expect(ready.configController.google.clientId, isEmpty);
    expect(ready.configController.google.clientSecret, isEmpty);

    final runtime = buildRuntime(ready);
    addTearDown(runtime.dispose);
    await runtime.restoreAndAutoSync();
    return (ready: ready, runtime: runtime);
  }

  /// Mount a surface exactly as the entry point does — both the bootstrap and
  /// the runtime overrides, over the real toast overlay.
  Future<void> pumpLaunched(
    WidgetTester tester,
    ({BootstrapReady ready, AuthSyncRuntime runtime}) launch,
    Widget home, {
    List<String>? urlsOpened,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...launch.ready.overrides,
          ...launch.runtime.overrides,
          if (urlsOpened != null)
            urlOpenerProvider.overrideWithValue((url) async {
              urlsOpened.add(url);
            }),
        ],
        child: MaterialApp(
          builder: wrapWithToast,
          home: Scaffold(body: home),
        ),
      ),
    );
    // Bounded pumps: the real database is open behind these providers, so the
    // tree is never settled to quiescence.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the launch says setup is required instead of going quiet', (
    tester,
  ) async {
    final launch = await firstLaunch();
    await pumpLaunched(tester, launch, const SidebarAuthSyncFooter());

    expect(find.text('Setup required'), findsOneWidget);
    expect(find.text('Google setup needed'), findsOneWidget);
    expect(
      find.text('Offline'),
      findsNothing,
      reason: 'the quiet idle is what hid the fatal misconfiguration',
    );
    // Honest about the session too: nothing to sign out of, nothing to sync.
    expect(find.byKey(const Key('auth-footer-signout')), findsNothing);
    expect(find.byKey(const Key('auth-footer-sync')), findsNothing);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });

  testWidgets('tapping Sign in stays in-app and names the file to edit', (
    tester,
  ) async {
    final launch = await firstLaunch();
    final urlsOpened = <String>[];
    await pumpLaunched(
      tester,
      launch,
      const SidebarAuthSyncFooter(),
      urlsOpened: urlsOpened,
    );

    await tester.tap(find.byKey(const Key('auth-footer-signin')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Nothing left the app — no browser, so no Google 400 to dead-end in.
    expect(urlsOpened, isEmpty);
    expect(
      find.textContaining('credentials are not configured'),
      findsOneWidget,
    );
    expect(
      find.textContaining(launch.ready.configController.path.path),
      findsOneWidget,
    );
    // The gesture changed nothing about the session.
    expect(find.byKey(const Key('auth-footer-signout')), findsNothing);
  });

  testWidgets('the Account tab never reads as signed in', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final launch = await firstLaunch();
    await pumpLaunched(tester, launch, const PropertiesDialog());

    await tester.tap(find.text('Account'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Nothing implies a session: no Sign out, and no granted Access list —
    // listing the REQUESTED scope with no session is what read as signed in.
    expect(find.byKey(const Key('account-signout')), findsNothing);
    expect(find.text('Signed in'), findsNothing);
    expect(find.text('Access'), findsNothing);
    expect(find.text('Google Tasks — read & write'), findsNothing);

    // And the tab says what is wrong and which file fixes it.
    expect(find.byKey(const Key('account-not-configured')), findsOneWidget);
    expect(find.text('Not signed in — setup required'), findsOneWidget);
    expect(
      find.textContaining(launch.ready.configController.path.path),
      findsOneWidget,
    );
    expect(find.text('Sign in with Google'), findsOneWidget);
  });
}
