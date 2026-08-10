// axiotask entry point — the Dart port of `main.rs` + the desktop slice of
// `lib.rs::run`.
//
// The ordered startup lives in `app/bootstrap.dart`; this file is the thin
// platform shim: resolve the data/config roots, initialize window_manager on
// desktop, run the bootstrap, and mount either the app or the startup-error
// screen. The window SIZE is restored only AFTER the first frame — never during
// mount (the geometry-freeze lesson, made structural).

import 'dart:io' show Platform, stdout;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/app.dart';
import 'src/app/bootstrap.dart';
import 'src/app/logging.dart';
import 'src/app/platform_paths.dart';
import 'src/app/providers.dart';
import 'src/app/startup_error.dart';
import 'src/app/startup_trace.dart';
import 'src/app/window_manager_controller.dart';
import 'src/app/window_service.dart';
import 'src/app/window_title_controller.dart';
import 'src/ui/app_boundary.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

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
      runApp(
        ProviderScope(
          overrides: [
            ...result.overrides,
            // Real desktop window-title seam; mobile keeps the no-op default.
            if (_isDesktop)
              windowTitleControllerProvider.overrideWithValue(
                const WindowManagerTitleController(),
              ),
          ],
          child: const AxiotaskApp(),
        ),
      );
      if (_isDesktop) {
        // Restore the persisted window size and start tracking resizes — but
        // only AFTER the first frame. No geometry work happens during mount.
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final service = WindowService(
            controller: const WindowManagerController(),
            prefs: result.prefsStore,
          );
          await service.restoreSize();
          WindowSizePersister(service).attach();
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
