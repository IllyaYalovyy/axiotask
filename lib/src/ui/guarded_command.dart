// The guarded-command seam (T7.8) — the single helper the UI routes a mutation
// through so the three T7.8 protections meet in one place: the watchdog bounds
// a hung command, the redaction surface turns any failure into a calm sentence,
// and the toast controller shows it. A command that succeeds is silent.
//
// Without this, a command that throws (a store error, a stale-etag 412, a
// wedged network call) would surface as an unhandled exception the user never
// sees explained. With it, every guarded call either completes quietly or
// leaves exactly one user-visible, redacted error toast.

import '../app/command_watchdog.dart';
import 'toast.dart';
import 'user_message.dart';

/// Run [op] as command [family] under the watchdog; on ANY failure show a
/// single redacted error toast on [toasts]. [timeout] overrides the family
/// budget (rarely needed). Returns when the command settles — the caller can
/// keep doing UI work after (e.g. clearing a selection) regardless of outcome.
Future<void> guardCommand(
  ToastController toasts,
  String family,
  Future<void> Function() op, {
  Duration? timeout,
}) async {
  try {
    await runCommandWithTimeout(family, op, timeout: timeout);
  } catch (e) {
    toasts.showError(commandUserMessage(family, e));
  }
}
