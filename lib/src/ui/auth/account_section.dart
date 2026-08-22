// The Account section of Properties — the standalone widget (T6.2) that later
// mounts as the "Account" tab (T7.x). It renders the three auth states (signed
// in / needs-reauth / signed out) with the matching status line, the granted
// OAuth scopes in friendly terms, the privacy assurance, and the state-correct
// sign-in/out actions.
//
// It also hosts the SWITCH-ACCOUNT flow (#215): sign out → reset this device's
// local data → sign in with the other account → the first sync pulls it. The
// reset is the one operation the app cannot undo, so its affordance is
// deliberately awkward: it lives at the bottom of a tab nobody opens by
// accident, it is inert until the session is gone (the ratified order), and it
// takes a typed-out word inside a dialog before it will run. Full multi-account
// support is explicitly future work — this is the supported way to switch.
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
    required this.onResetLocalData,
    this.pendingPushes = 0,
    this.resetNotice,
    this.resetNoticeIsError = false,
    this.resetBusy = false,
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

  /// Erase every local list and task (#215). Invoked ONLY after the typed
  /// confirm inside this widget — never straight off the button.
  final VoidCallback onResetLocalData;

  /// Local changes that have not reached Google. Named in the confirm so the
  /// user is told, before erasing, what is about to be lost for good.
  final int pendingPushes;

  /// The outcome of the last reset, shown where the action was taken.
  final String? resetNotice;

  /// Whether [resetNotice] reports a failure (an erase that was refused).
  final bool resetNoticeIsError;

  /// A reset is running; the affordance is held so it cannot be re-entered.
  final bool resetBusy;

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
        const SizedBox(height: 28),
        const Divider(height: 1),
        const SizedBox(height: 20),
        _switchAccount(context, theme, colors),
      ],
    );
  }

  // ── Switch account (#215) ─────────────────────────────────────────────────
  Widget _switchAccount(
    BuildContext context,
    ThemeData theme,
    ColorScheme colors,
  ) {
    // A live session — including a DEAD one, which still holds tokens and can
    // be revived by signing in again — keeps the erase inert. Erasing first
    // would destroy data that is still recoverable, and the ratified flow is
    // sign out, then reset, then sign in with the other account.
    final gated = isAuthenticated || resetBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Switch account'),
        const SizedBox(height: 8),
        Text(
          'To use a different Google account: sign out, reset this device\'s '
          'local data, then sign in with the other account — the first sync '
          'pulls it. The reset erases every task and list stored here and '
          'cannot be undone; your preferences are kept.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        if (resetNotice != null) ...[
          const SizedBox(height: 12),
          _resetNoticeBanner(theme, colors),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('account-reset-data'),
          onPressed: gated ? null : () => _confirmReset(context),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.error,
            side: BorderSide(color: colors.error.withValues(alpha: 0.5)),
          ),
          icon: const Icon(Icons.delete_forever_outlined, size: 18),
          label: const Text('Reset local data…'),
        ),
        if (isAuthenticated) ...[
          const SizedBox(height: 8),
          Text(
            'Sign out first — the reset is only offered with no session.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _resetNoticeBanner(ThemeData theme, ColorScheme colors) => Container(
    key: const Key('account-reset-notice'),
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: resetNoticeIsError
          ? colors.errorContainer
          : colors.secondaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          resetNoticeIsError ? Icons.error_outline : Icons.check_circle_outline,
          size: 18,
          color: resetNoticeIsError
              ? colors.onErrorContainer
              : colors.onSecondaryContainer,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            resetNotice!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: resetNoticeIsError
                  ? colors.onErrorContainer
                  : colors.onSecondaryContainer,
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ResetConfirmDialog(pendingPushes: pendingPushes),
    );
    if (ok == true) onResetLocalData();
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

/// The typed confirm gate. The button stays inert until the user has written
/// [_word] out in full — the deliberate friction the one un-undoable action in
/// the app earns. The field is NOT autofocused: on a phone that would throw the
/// keyboard over the very warning the user needs to read first.
class _ResetConfirmDialog extends StatefulWidget {
  const _ResetConfirmDialog({required this.pendingPushes});

  final int pendingPushes;

  @override
  State<_ResetConfirmDialog> createState() => _ResetConfirmDialogState();
}

class _ResetConfirmDialogState extends State<_ResetConfirmDialog> {
  static const String _word = 'RESET';

  final TextEditingController _controller = TextEditingController();
  bool _armed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AlertDialog(
      key: const Key('reset-data-confirm'),
      // Scrollable: the warning, the unsynced-changes line and the field are a
      // tall stack, and on a phone the keyboard takes half the screen. Without
      // this, a large text scale or the raised IME would push the confirm field
      // out of reach behind a clipped overflow.
      scrollable: true,
      title: const Text('Reset local data?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Every task and list on this device is removed — including '
            'local-only lists, which exist nowhere else. This cannot be '
            'undone. A recovery copy is written next to the database first, '
            'and your preferences are kept.',
          ),
          if (widget.pendingPushes > 0) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: colors.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${widget.pendingPushes} change(s) on this device never '
                    'reached Google. Sign in and sync before resetting if you '
                    'want to keep them.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const Key('reset-data-confirm-field'),
            controller: _controller,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Type $_word to confirm',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              final armed = v.trim().toUpperCase() == _word;
              if (armed != _armed) setState(() => _armed = armed);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('reset-data-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('reset-data-confirm-button'),
          onPressed: _armed ? () => Navigator.of(context).pop(true) : null,
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          child: const Text('Reset local data'),
        ),
      ],
    );
  }
}
