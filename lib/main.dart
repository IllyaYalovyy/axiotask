// axiotask entry point — the Dart port of `main.rs` + the desktop slice of
// `lib.rs::run`.
//
// The ordered startup lives in `app/bootstrap.dart`; this file is the thin
// platform shim: resolve the data/config roots, initialize window_manager on
// desktop, run the bootstrap, and mount either the app or the startup-error
// screen. The window SIZE is restored only AFTER the first frame — never during
// mount (the geometry-freeze lesson, made structural).

import 'dart:async' show unawaited;
import 'dart:io' show Platform, stdout;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'src/api/tasks_api.dart' show TasksApi;
import 'src/app/app.dart';
import 'src/app/auth_sync_runtime.dart';
import 'src/app/authed_api.dart';
import 'src/app/bootstrap.dart';
import 'src/app/logging.dart';
import 'src/app/platform_paths.dart';
import 'src/app/providers.dart';
import 'src/app/startup_error.dart';
import 'src/app/startup_trace.dart';
import 'src/app/window_manager_controller.dart';
import 'src/app/window_service.dart';
import 'src/app/window_title_controller.dart';
import 'src/auth/desktop_auth.dart';
import 'src/auth/desktop_token_provider.dart';
import 'src/auth/google_sign_in_token_provider.dart';
import 'src/auth/token_provider.dart';
import 'src/auth/token_store.dart';
import 'src/store/store.dart';
import 'src/ui/app_boundary.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

/// Assemble the [AuthSyncRuntime] with the platform-appropriate auth surfaces.
///
/// Desktop drives OAuth PKCE + loopback with a refresh token persisted in
/// `tokens.json`; the Tasks client refreshes reactively on a 401. Android uses
/// Play Services authorization — no tokens are stored, the app is identified by
/// package + SHA-1, and a 401 re-authorizes silently through the same provider
/// (ratified auth decision / RFC-010).
AuthSyncRuntime _buildRuntime(BootstrapReady ready) {
  final store = Store(ready.database);
  final config = ready.configController;

  final TokenProvider tokenProvider;
  final TasksApi Function(String accessToken) buildClient;

  if (_isDesktop) {
    final oauthConfig = OAuthConfig(
      clientId: config.google.clientId,
      clientSecret: config.google.clientSecret,
      scopes: config.google.scopes,
    );
    final tokenStore = FileTokenStore(ready.tokensFile);
    tokenProvider = DesktopTokenProvider(
      config: oauthConfig,
      store: tokenStore,
    );
    // The access token is refreshed from the stored refresh token by the client
    // itself, so the desktop builder reads the persisted bundle rather than the
    // bare token string.
    buildClient = (_) => buildDesktopTasksApi(
      tokens: tokenStore.load()!,
      config: oauthConfig,
      store: tokenStore,
    );
  } else {
    final provider = GoogleSignInTokenProvider(GoogleSignInAuthGateway());
    tokenProvider = provider;
    buildClient = (accessToken) =>
        buildAndroidTasksApi(accessToken: accessToken, provider: provider);
  }

  return AuthSyncRuntime(
    store: store,
    config: config,
    tokenProvider: tokenProvider,
    buildClient: buildClient,
  );
}

Future<void> main() async {
  // Monotonic clock for the cold-start trace (Stopwatch, not DateTime.now).
  // Started as early as possible in main so the marker reflects Dart-side
  // startup; the release measurement harness times spawn → frame externally.
  final startup = Stopwatch()..start();

  WidgetsFlutterBinding.ensureInitialized();
  Log.initLogging();
  // Surface a render-time failure as a human screen instead of the framework's
  // bare gray error box (a release build has no console).
  installAppErrorBoundary();

  if (_isDesktop) {
    await windowManager.ensureInitialized();
  }

  final dataBase = await resolveDataBase();
  final configBase = await resolveConfigBase();

  final result = await bootstrap(
    dataBase: dataBase,
    configBase: configBase,
    takeInstanceLock: _isDesktop,
  );

  switch (result) {
    case BootstrapFailed(:final message):
      // Every entry point mounts a ProviderScope at the root, even the error
      // screen (it uses no providers, but the app is uniformly Riverpod-scoped).
      runApp(ProviderScope(child: StartupErrorApp(message: message)));
    case BootstrapReady():
      // The composition root: assemble auth + sync over the platform token
      // provider and the production Tasks client seam.
      final runtime = _buildRuntime(result);
      runApp(
        ProviderScope(
          overrides: [
            ...result.overrides,
            ...runtime.overrides,
            // Real desktop window-title seam; mobile keeps the no-op default.
            if (_isDesktop)
              windowTitleControllerProvider.overrideWithValue(
                const WindowManagerTitleController(),
              ),
          ],
          child: const AxiotaskApp(),
        ),
      );
      // ONE detached task after the first frame: silent restore → (auto-sync) →
      // background loop. The first frame NEVER waits on it (#175 + the
      // geometry-freeze lesson).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(runtime.start());
      });
      if (_isDesktop) {
        // Restore the persisted window size, track resizes, and flush pending
        // changes on close — but only AFTER the first frame. No geometry or
        // network work happens during mount.
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final service = WindowService(
            controller: const WindowManagerController(),
            prefs: result.prefsStore,
          );
          await service.restoreSize();
          WindowSizePersister(service).attach();
          await WindowCloseFlusher(runtime.flushOnExit).attach();
        });
      }
  }

  // Cold-start trace: on the first rendered frame, print the marker the
  // release-build measurement harness greps for. Silent unless
  // AXIOTASK_STARTUP_TRACE=1, so a normal launch prints nothing. Registered
  // after runApp so the binding exists and the callback fires post-first-frame.
  if (startupTraceEnabled(Platform.environment)) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      stdout.writeln(firstFrameLine(startup.elapsed));
    });
  }
}
