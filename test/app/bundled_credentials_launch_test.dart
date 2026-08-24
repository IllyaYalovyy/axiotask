// A packaged install signs in out of the box (#229) — the real cold start.
//
// #228 made an install with no credentials fail LOUDLY. It did not make one
// work: a user who installs the RPM still could not sync until they created an
// OAuth client and hand-edited `config.json`. The build now compiles the
// installed-app client into the binary, so this runs the real sequence —
// [bootstrap] over an empty data directory, then the real composition root
// [buildRuntime] — and asserts what the launch renders and what the disk holds.
//
// The bundled secret must never reach disk: `config.json` is a file the user
// reads, edits and copies between machines, and the app writing a credential
// into it would both leak the secret out of the binary and freeze that client
// into a config the next release could not change.

import 'dart:io';

import 'package:axiotask/main.dart' show buildRuntime;
import 'package:axiotask/src/app/auth_sync_runtime.dart';
import 'package:axiotask/src/app/bootstrap.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/google_credentials.dart';
import 'package:axiotask/src/app/instance.dart';
import 'package:axiotask/src/ui/auth/sidebar_auth_sync_footer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../ui/toast_harness.dart' show wrapWithToast;

void main() {
  const bundled = BundledCredentials(
    clientId: 'bundled-id.apps.example.test',
    clientSecret: 'bundled-secret',
  );

  late Directory tmp;
  late Directory dataBase;
  late Directory configBase;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('axiotask_229_bundled');
    dataBase = Directory(p.join(tmp.path, 'data'))..createSync();
    configBase = Directory(p.join(tmp.path, 'config'))..createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// One real cold start on a machine that has never run axiotask: bootstrap
  /// writes the default config (empty `google` section), the real desktop
  /// composition root assembles auth over it, then the detached startup restore
  /// runs — awaited, so the test never races it.
  Future<({BootstrapReady ready, AuthSyncRuntime runtime})> firstLaunch(
    BundledCredentials credentials,
  ) async {
    final result = await bootstrap(
      dataBase: dataBase,
      configBase: configBase,
      env: const {},
    );
    final ready = result as BootstrapReady;
    addTearDown(ready.database.close);

    // The fixture is a genuine first launch: nothing granted, nothing edited.
    expect(ready.tokensFile.existsSync(), isFalse);
    expect(ready.configController.google.clientId, isEmpty);

    final runtime = buildRuntime(ready, bundled: credentials);
    addTearDown(runtime.dispose);
    await runtime.restoreAndAutoSync();
    return (ready: ready, runtime: runtime);
  }

  Future<void> pumpFooter(
    WidgetTester tester,
    ({BootstrapReady ready, AuthSyncRuntime runtime}) launch,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [...launch.ready.overrides, ...launch.runtime.overrides],
        child: MaterialApp(
          builder: wrapWithToast,
          home: const Scaffold(body: SidebarAuthSyncFooter()),
        ),
      ),
    );
    // Bounded pumps: a real database is open behind these providers, so the
    // tree never settles to quiescence.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a packaged launch is ready to sign in, not asking for setup', (
    tester,
  ) async {
    final launch = await firstLaunch(bundled);
    await pumpFooter(tester, launch);

    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(
      find.text('Setup required'),
      findsNothing,
      reason:
          'the app HAS credentials — nothing is left for the user to set up',
    );
    expect(find.text('Google setup needed'), findsNothing);
    // And the auth machine agrees: no configuration fault was ever recorded.
    expect(launch.runtime.auth.snapshot.missingConfigPath, isNull);
  });

  testWidgets('the bundled secret is never written into config.json', (
    tester,
  ) async {
    final launch = await firstLaunch(bundled);
    await pumpFooter(tester, launch);

    // Every write path the app has over that file: the default written by
    // bootstrap, and a settings toggle re-saving it.
    await launch.ready.configController.setPushEnabled(true);

    final onDisk = launch.ready.configController.path;
    final text = onDisk.readAsStringSync();
    expect(
      text,
      isNot(contains('bundled-secret')),
      reason: 'a credential compiled into the binary must not leak to disk',
    );
    expect(text, isNot(contains('bundled-id.apps.example.test')));

    final reloaded = AppConfig.loadFrom(onDisk)!;
    expect(reloaded.google.clientId, isEmpty);
    expect(reloaded.google.clientSecret, isEmpty);
    expect(reloaded.sync.pushEnabled, isTrue, reason: 'the toggle did persist');
  });

  testWidgets('a build with nothing bundled still fails loud (#228 intact)', (
    tester,
  ) async {
    // The non-happy path that keeps the fallback chain honest: an unofficial
    // build made without the gitignored credentials file behaves exactly as it
    // did before #229 — the setup-required state naming the file to edit.
    final launch = await firstLaunch(const BundledCredentials());
    await pumpFooter(tester, launch);

    expect(find.text('Setup required'), findsOneWidget);
    expect(find.text('Google setup needed'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
    // And the fault still names the file the user has to edit — the footer
    // shows the state, the sign-in toast and the Account tab show the path
    // (#228), so this is where the path itself is pinned.
    expect(
      launch.runtime.auth.snapshot.missingConfigPath,
      launch.ready.configController.path.path,
    );
  });

  testWidgets('a config the user edited still beats the bundled client', (
    tester,
  ) async {
    // Written before the launch, the way an operator pointing the app at their
    // own Google Cloud project does it.
    final cfgDir = Directory(p.join(configBase.path, appDirName(env: const {})))
      ..createSync(recursive: true);
    File(p.join(cfgDir.path, 'config.json')).writeAsStringSync(
      '{"google":{"client_id":"operator.apps.example.test",'
      '"client_secret":"operator-secret","scopes":["$tasksScope"]},'
      '"sync":{"push_enabled":false,"auto_sync_on_start":true}}',
    );

    final result = await bootstrap(
      dataBase: dataBase,
      configBase: configBase,
      env: const {},
    );
    final ready = result as BootstrapReady;
    addTearDown(ready.database.close);
    expect(
      ready.configController.google.clientId,
      'operator.apps.example.test',
    );

    final resolved = resolveGoogleCredentials(
      config: ready.configController.google,
      bundled: bundled,
    );
    expect(resolved.clientId, 'operator.apps.example.test');
    expect(resolved.clientSecret, 'operator-secret');

    final runtime = buildRuntime(ready, bundled: bundled);
    addTearDown(runtime.dispose);
    await runtime.restoreAndAutoSync();
    await pumpFooter(tester, (ready: ready, runtime: runtime));

    expect(find.text('Setup required'), findsNothing);
  });
}
