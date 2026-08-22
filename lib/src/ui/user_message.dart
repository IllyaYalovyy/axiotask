// The redaction surface — the last-line guard that turns a raw command failure
// into the calm sentence a toast shows the user. Dart port of the reference
// frontend's `friendlyError` (#128/#135).
//
// It is an ALLOWLIST, the inverse of a marker denylist: the ONLY strings that
// reach the user verbatim are ones WE author — validation refusals the user
// must understand, plus the two auth signals. Everything else defaults to
// REDACTED, so a future internal error, a raw SQL/sqlx string, or raw network
// text (which can embed the full request URL and its query params) never leaks
// to the user from any path — they get a family-scoped "a local error occurred,
// the details are in the log" sentence instead. The full typed error is still
// written to the log at the call site.

import '../app/command_watchdog.dart' show CommandTimeoutError;
import '../auth/token_provider.dart';

/// Fragments of messages WE author to explain a refusal — the allowlist. Each
/// is distinctive to an authored message, never a generic word a raw error
/// could also contain, so nothing leaks by accident.
const List<String> _userAuthoredMarkers = <String>[
  'invalid due date',
  'unknown date move',
  'cannot nest under a subtask',
  'cannot make a task with subtasks',
  'not found in siblings',
  'no backup file found',
  'invalid backup file',
  'newer than this app supports',
];

/// The backend's `task <id> not found` shape — pinned exactly so a network
/// error that merely contains "not found" cannot slip through.
final RegExp _taskNotFound = RegExp(r'^task .+ not found$');

/// A human clause per command family, so a redacted error reads naturally for
/// what the user was doing.
const Map<String, String> _familyAction = <String, String>{
  'list_tasklists': 'update your lists',
  'create_list': 'update your lists',
  'rename_list': 'update your lists',
  'delete_list': 'update your lists',
  'sync_now': 'sync with Google',
  'fresh_sync': 'sync with Google',
  'auth_login': 'update your Google sign-in',
  'auth_logout': 'update your Google sign-in',
  'get_settings': 'update your settings',
  'set_push_enabled': 'update your settings',
  'set_auto_sync': 'update your settings',
  'set_editing': 'update your settings',
  'export_backup': 'export your backup',
  'import_backup': 'restore your backup',
};

/// The clause for command [name] — everything not listed is task-shaped
/// (create/rename/complete/delete/move/…) and reads "save your change".
String familyAction(String name) => _familyAction[name] ?? 'save your change';

/// Strip a `dart:core` `Exception:` / `<Type>:` wrapper prefix so marker
/// matching sees the message the code actually authored. A [CommandError]'s
/// `toString` has no prefix, so this is a no-op there; a wrapped exception in a
/// generic `catch` is normalized.
String _bareMessage(Object error) {
  final s = error.toString();
  const prefix = 'Exception: ';
  return s.startsWith(prefix) ? s.substring(prefix.length) : s;
}

bool _isUserAuthored(String msg) {
  final m = msg.toLowerCase();
  if (_userAuthoredMarkers.any(m.contains)) return true;
  return _taskNotFound.hasMatch(m.trim());
}

/// The user-facing sentence for a failed command [family] with [error].
///
/// Priority: the two auth signals first (they carry their own recovery
/// action), then a watchdog timeout (reassure the app is still alive), then any
/// authored refusal verbatim, and finally — the default — a redacted,
/// family-scoped sentence pointing at the log.
String commandUserMessage(String family, Object error) {
  final msg = _bareMessage(error);
  if (msg.contains('not authenticated')) {
    return 'Not signed in — use Sign in with Google to sync.';
  }
  if (msg.contains('session expired')) {
    return 'Google session expired — sign in again to resume sync.';
  }
  if (error is CommandTimeoutError) {
    return '${error.command} is taking too long. The app is still responsive; '
        'try again or restart if it keeps happening.';
  }
  if (_isUserAuthored(msg)) return msg;
  return "Couldn't ${familyAction(family)} — a local error occurred. "
      'The details are in the log.';
}

/// The user-facing sentence for a FAILED interactive sign-in gesture, or null
/// when the failure needs NO feedback (#212).
///
/// A user-initiated gesture that fails must say so — logging alone is invisible
/// on Android (`Log` writes through `dart:developer`), which is what made a
/// config error or a Play Services outage look like an inert Sign-in button.
/// The one exception is the failure the user themselves caused: closing the
/// account picker / declining the scope raises
/// [TokenProviderInteractionRequired], and they need no toast to tell them what
/// they just did.
///
/// Classification is by error TYPE, never by matching the error's text: a
/// provider message can carry the signed-in account, a request URL, or raw
/// Play-Services detail, and none of it may reach a toast (#131/#187). The full
/// typed error is written to the log at the call site.
String? signInUserMessage(Object error) {
  if (error is TokenProviderInteractionRequired) return null;
  if (error is TokenProviderUnavailable) {
    // Transient and actionable — say which half is down and what to try, so the
    // user does not read it as "this app is broken".
    return "Couldn't sign in — Google sign-in is unavailable right now. "
        'Check your connection and try again.';
  }
  // An OAuth-flow rejection (AuthException: denied consent, state mismatch,
  // no refresh token, timeout) or anything unclassified: the user cannot act on
  // the detail, so they get the calm sentence and the log keeps the specifics.
  return "Couldn't sign in with Google. The details are in the log.";
}
