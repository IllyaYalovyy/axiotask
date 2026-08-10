// The command watchdog — a per-family time budget around an async command so a
// hung operation returns control to the UI instead of stranding it forever.
// Dart port of the reference frontend's `ipc.js` timeout guard.
//
// In the Tauri app this wrapped every IPC call to the Rust backend; with no IPC
// boundary in the Flutter app most "commands" are fast local store writes, but
// the operations that can genuinely hang — a network sync, an OAuth login the
// user is completing in the browser, a large backup import — still need a
// bound. A uniform budget would break the paced ones (auth is minutes-normal,
// sync backs off), so the budget is per family. On expiry the awaited future
// rejects with a [CommandTimeoutError] the UI turns into a calm "taking too
// long" toast (see `ui/user_message.dart`).

import 'dart:async';

/// The budget for a command with no family-specific override. Long enough that
/// a healthy local write never trips it, short enough that a wedged call hands
/// control back while the user is still watching.
const Duration kDefaultCommandTimeout = Duration(seconds: 12);

/// Commands that legitimately outlive [kDefaultCommandTimeout]. `auth_login` is
/// paced by the human completing the browser OAuth consent (minutes are
/// normal); the sync commands are network-bound with exponential rate-limit
/// backoff; backup import/export touch the whole store on disk.
const Map<String, Duration> kCommandTimeoutOverrides = <String, Duration>{
  'auth_login': Duration(minutes: 10),
  'sync_now': Duration(minutes: 5),
  'fresh_sync': Duration(minutes: 5),
  'import_backup': Duration(minutes: 1),
  'export_backup': Duration(minutes: 1),
};

/// The time budget for command [name] — its override, else the default.
Duration timeoutFor(String name) =>
    kCommandTimeoutOverrides[name] ?? kDefaultCommandTimeout;

/// Raised when a command outruns its budget. Carries the command [command] and
/// the [timeout] it exceeded so the user-facing message can name the action and
/// the log can record what stalled.
class CommandTimeoutError implements Exception {
  const CommandTimeoutError(this.command, this.timeout);

  /// The command family that hung (e.g. `sync_now`).
  final String command;

  /// The budget it exceeded.
  final Duration timeout;

  /// The rounded-seconds sentence, matching the reference's wording.
  String get message =>
      '$command timed out after ${(timeout.inMilliseconds / 1000).round()}s';

  @override
  String toString() => message;
}

/// Run [body] under command [name]'s time budget (an explicit [timeout] wins).
///
/// Resolves with the command's value when it finishes in time; rejects with a
/// [CommandTimeoutError] when it does not — never leaving the caller awaiting a
/// wedged future. A command that fails on its own propagates that error
/// unchanged (a real failure is not a timeout). The underlying [Future.timeout]
/// schedules an ordinary timer, so the whole thing is deterministic under
/// `fakeAsync`.
Future<T> runCommandWithTimeout<T>(
  String name,
  Future<T> Function() body, {
  Duration? timeout,
}) {
  final budget = timeout ?? timeoutFor(name);
  return body().timeout(
    budget,
    onTimeout: () => throw CommandTimeoutError(name, budget),
  );
}
