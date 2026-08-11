// The one place `window_manager` is touched (RESEARCH §8: wrap it, don't spread
// it). Concrete [WindowController] over the plugin, plus the resize listener
// that persists the new size. Desktop only — the bootstrap constructs this
// exclusively on Linux; mobile never has a resizable window to manage.
//
// Untested by unit tests on purpose: it is thin glue over a plugin that needs a
// live native window (the WindowService logic it feeds is fully faked-and-tested
// in window_service_test.dart).

import 'dart:async';
import 'dart:ui';

import 'package:window_manager/window_manager.dart';

import 'window_service.dart';

/// [WindowController] backed by the real `window_manager` plugin.
class WindowManagerController implements WindowController {
  const WindowManagerController();

  @override
  Future<Size> getSize() => windowManager.getSize();

  @override
  Future<void> setSize(Size size) => windowManager.setSize(size);
}

/// Bridges `window_manager`'s resize events to [WindowService.persistSize] so
/// the window size is saved as the user drags. Register once after the window
/// is shown; remove it on teardown.
class WindowSizePersister with WindowListener {
  WindowSizePersister(this._service);

  final WindowService _service;

  /// Start listening for resize events.
  void attach() => windowManager.addListener(this);

  /// Stop listening.
  void detach() => windowManager.removeListener(this);

  @override
  void onWindowResized() {
    // The event carries no size; read the live size and persist it.
    unawaited(_service.persistCurrentSize());
  }
}

/// Runs a final flush ([AuthSyncRuntime.flushOnExit]) before the desktop window
/// actually closes — the port of the reference's exit sync. `window_manager`
/// only fires `onWindowClose` when close is prevented, so [attach] sets
/// `setPreventClose(true)`; the handler awaits the flush (bounded inside the
/// scheduler) and then destroys the window. Thin plugin glue, like
/// [WindowManagerController]: exercised on a real desktop window only, its logic
/// (the scheduler's bounded [flushOnExit]) is fully faked-and-tested elsewhere.
class WindowCloseFlusher with WindowListener {
  WindowCloseFlusher(this._flush);

  final Future<void> Function() _flush;

  /// Register the close handler and prevent an immediate close so the flush can
  /// run first. Call once after the window is shown.
  Future<void> attach() async {
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
  }

  @override
  void onWindowClose() async {
    try {
      await _flush();
    } finally {
      await windowManager.destroy();
    }
  }
}
