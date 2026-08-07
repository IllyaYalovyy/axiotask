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
