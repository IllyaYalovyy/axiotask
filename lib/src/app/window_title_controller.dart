// The desktop window-TITLE seam — the second (and only other) place the shell
// touches window state, kept behind an abstraction just like the size seam
// (RESEARCH §8: wrap window_manager, don't spread it).
//
// The reference set the GTK title to "<View> — axiotask" from the UI whenever
// the view changed (App.svelte). We re-honor that contract (MIGRATION-PLAN §1:
// "Desktop window TITLE contract is NOT dead — re-honored via window_manager").
//
// Two implementations, one interface:
//   - [NoopWindowTitleController] — the default provider value; used on mobile
//     and in widget tests (no window to title). Importing this pulls in NO
//     plugin, so the common path never touches window_manager.
//   - [WindowManagerTitleController] — desktop-only, thin glue over the plugin.
//     Constructed and injected by main.dart on desktop, exactly like the size
//     controller. Untested by unit tests on purpose (needs a live window).

import 'package:window_manager/window_manager.dart';

/// The minimal window-title surface the shell needs.
abstract class WindowTitleController {
  /// Set the native window title to [title].
  Future<void> setTitle(String title);
}

/// Does nothing — the default on mobile and under widget tests.
class NoopWindowTitleController implements WindowTitleController {
  const NoopWindowTitleController();

  @override
  Future<void> setTitle(String title) async {}
}

/// [WindowTitleController] backed by the real `window_manager` plugin (desktop).
class WindowManagerTitleController implements WindowTitleController {
  const WindowManagerTitleController();

  @override
  Future<void> setTitle(String title) => windowManager.setTitle(title);
}
