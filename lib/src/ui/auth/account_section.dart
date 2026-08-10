// The Account section of Properties — the standalone widget (T6.2) that later
// mounts as the "Account" tab (T7.x). It renders the three auth states (signed
// in / needs-reauth / signed out) with the matching status line, the granted
// OAuth scopes in friendly terms, the privacy assurance, and the state-correct
// sign-in/out actions.
//
// Standalone: it takes its state and callbacks directly, so this task's tests
// and goldens drive every state without a controller. Fresh Material 3 visuals
// (Q3), not a pixel port of the Tauri dialog.

import 'package:flutter/material.dart';

/// A friendly label for an OAuth scope URL — the port of the reference's
/// `scopeLabel`. Unknown scopes fall back to the raw URL so nothing is hidden.
String scopeLabel(String scope) {
  if (scope.endsWith('/tasks')) return 'Google Tasks — read & write';
  if (scope.endsWith('/tasks.readonly')) return 'Google Tasks — read only';
  return scope;
}

/// The Account section, rendered from standalone state.
class AccountSection extends StatelessWidget {
  const AccountSection({
    required this.isAuthenticated,
    required this.needsReauth,
    required this.scopes,
    required this.onSignIn,
    required this.onSignOut,
    super.key,
  });

  /// A live session exists (stays true across a [needsReauth] transition).
  final bool isAuthenticated;

  /// The stored session is dead; only a fresh sign-in recovers it.
  final bool needsReauth;

  /// The granted OAuth scopes (space-joined URLs as Google returns them, split
  /// into a list). Empty when signed out — the Access block then hides.
  final List<String> scopes;

  /// Run the OAuth sign-in (fresh or re-auth).
  final VoidCallback onSignIn;

  /// Drop the session.
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Google account'),
        const SizedBox(height: 8),
        _statusLine(context, colors),
        if (needsReauth) ...[
          const SizedBox(height: 8),
          Text(
            'Google stopped accepting the saved sign-in (it expired or was '
            'revoked). Your changes are kept locally and will sync after you '
            'sign in again.',
            key: const Key('account-reauth-hint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
        if (scopes.isNotEmpty) ...[
          const SizedBox(height: 20),
          _heading(context, 'Access'),
          const SizedBox(height: 8),
          for (final scope in scopes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check, size: 16, color: colors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      scopeLabel(scope),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'axiotask only requests access to your Google Tasks — nothing else.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 24),
        _actions(context),
      ],
    );
  }

  Widget _heading(BuildContext context, String text) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  );

  Widget _statusLine(BuildContext context, ColorScheme colors) {
    final (color, label) = switch ((isAuthenticated, needsReauth)) {
      (_, true) => (colors.error, 'Session expired — sign in again'),
      (true, false) => (colors.primary, 'Signed in'),
      (false, false) => (colors.onSurfaceVariant, 'Not signed in'),
    };
    return Row(
      children: [
        Container(
          key: const Key('account-status-dot'),
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Text(label, style: Theme.of(context).textTheme.bodyLarge),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    final children = <Widget>[];
    if (needsReauth) {
      children.add(
        FilledButton(
          key: const Key('account-signin'),
          onPressed: onSignIn,
          child: const Text('Sign in again'),
        ),
      );
      children.add(
        OutlinedButton(
          key: const Key('account-signout'),
          onPressed: onSignOut,
          child: const Text('Sign out'),
        ),
      );
    } else if (isAuthenticated) {
      children.add(
        OutlinedButton(
          key: const Key('account-signout'),
          onPressed: onSignOut,
          child: const Text('Sign out'),
        ),
      );
    } else {
      children.add(
        FilledButton(
          key: const Key('account-signin'),
          onPressed: onSignIn,
          child: const Text('Sign in with Google'),
        ),
      );
    }
    return Wrap(spacing: 12, runSpacing: 8, children: children);
  }
}
