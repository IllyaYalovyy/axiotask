// The auth seam the sync scheduler depends on — the narrow slice of the
// reference's `AppState` auth surface (`is_authenticated`, `needs_reauth`, and
// the `needs_reauth` store) that the scheduler needs, and nothing more.
//
// Auth is a THREE-state machine (invariant #6): signed out, signed in, and
// needs-reauth — a dead session where tokens are still present but refresh is
// permanently denied. needs-reauth is NOT the signed-out state: the tokens
// remain, so [isAuthenticated] stays true while [needsReauth] also goes true.
// A sync failure sets the flag ([setNeedsReauth]); the next successful sync (or
// a re-login/logout) clears it.
//
// This is a seam, not the auth implementation: the real desktop auth controller
// (over a token store) and the mobile Play-Services session both implement it
// in a later step (T6.1). Keeping it abstract here lets T5.9's scheduler — and
// its tests — run without any token store, keyring, or network.
abstract interface class AuthState {
  /// Whether a live session exists — tokens present on desktop, a Play-Services
  /// grant on mobile. Stays true across a [needsReauth] transition: a dead
  /// session keeps its tokens, so this is NOT how "signed out" is detected.
  bool get isAuthenticated;

  /// Whether the stored session is dead (refresh permanently denied) and only a
  /// fresh sign-in can recover it. The distinct third auth state.
  bool get needsReauth;

  /// Flag or clear the dead-session state. The scheduler sets it after a sync
  /// run: true on an `invalid_grant` refresh denial, false on any success.
  void setNeedsReauth(bool value);
}
