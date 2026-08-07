// axiotask entry point — the Dart port of `main.rs` + the desktop slice of
// `lib.rs::run`.
//
// The ordered startup lives in `app/bootstrap.dart`; this file is the thin
// platform shim: resolve the data/config roots, initialize window_manager on
// desktop, run the bootstrap, and mount either the app or the startup-error
// screen. The window SIZE is restored only AFTER the first frame — never during
// mount (the geometry-freeze lesson, made structural).

import 'dart:io' show Platform;

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
import 'src/app/window_manager_controller.dart';
import 'src/app/window_service.dart';
import 'src/app/window_title_controller.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Log.initLogging();

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
}
