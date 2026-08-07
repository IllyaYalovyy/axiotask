// Desktop window size persistence — the wrapper around `window_manager` that
// keeps the plugin from spreading through the app (RESEARCH §8), and the port
// of the reference's window-geometry handling narrowed to what survived the Q3
// UI ruling: SIZE ONLY.
//
// Two hard-won rules are encoded structurally, not by convention:
//
//  1. SIZE-ONLY persistence. The [WindowController] seam exposes only
//     get/set SIZE — there is no position API to call — so the app CANNOT
//     accidentally restore a window position. Position restore is the class of
//     bug behind stale off-screen windows; we don't store it, so we can't.
//
//  2. NO restore work before the first frame. Restoring geometry during mount
//     wedged the reference's renderer IPC (the "loading forever" freeze). This
//     service never touches the window at construction; [restoreSize] is an
//     explicit call the bootstrap schedules AFTER the first frame. A test
//     asserts construction is inert.
//
// The logic lives here against the [WindowController] abstraction so it is
// unit-testable with a fake; the real [WindowManagerController] is thin glue
// over the plugin and only runs on a real desktop window.

import 'dart:async';
import 'dart:ui';

import 'prefs.dart';

/// The minimal window surface this app needs — deliberately SIZE-ONLY. There is
/// no position getter/setter, so size-only persistence is structural.
abstract class WindowController {
  /// The current window size in logical pixels.
  Future<Size> getSize();

  /// Resize the window to [size] (logical pixels).
  Future<void> setSize(Size size);
}

/// Persists and restores the desktop window SIZE via [PrefsStore], mediated by
/// a [WindowController] seam.
class WindowService {
  WindowService({required this.controller, required this.prefs});

  /// The window seam (size-only).
  final WindowController controller;

  /// The prefs store the window size persists into.
  final PrefsStore prefs;

  /// Apply the last persisted size to the window, if one was saved. No-op when
  /// nothing is stored (the runner's default size stands).
  ///
  /// MUST be called after the first frame — never during mount (rule 2). It is
  /// a normal async call the bootstrap schedules post-frame; constructing this
  /// service does nothing.
  Future<void> restoreSize() async {
    final saved = prefs.load().windowSize;
    if (saved == null) return;
    await controller.setSize(Size(saved.width, saved.height));
  }

  /// Persist the current window size to `prefs.json` (size-only). Call this on
  /// window-resize events; [size] is read from the event (or the controller).
  void persistSize(Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    prefs.saveWindowSize(WindowSize(size.width, size.height));
  }

  /// Read the live size from the controller and persist it. Convenience for a
  /// resize listener that carries no size payload.
  Future<void> persistCurrentSize() async =>
      persistSize(await controller.getSize());
}
