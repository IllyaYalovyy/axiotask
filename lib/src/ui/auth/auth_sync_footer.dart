// The auth/sync footer — the standalone widget cluster that later lands at the
// bottom of the real sidebar (T7.1). It owns the priority ladder
// (needsReauth > needsAttention > sync): a stuck permanent failure surfaces a
// persistent "needs attention" button (not just a line buried in Properties,
// #136); a dead or absent session offers sign-in (never a Sync button that can
// only fail); a live session offers Sync-now. A one-line status row (dot +
// phrase + Sign out) sits below.
//
// Fresh visuals (Q3): a Material 3 composition, not a pixel port of the Tauri
// footer. Every affordance is a real Button — mouse, keyboard, and touch alike.
// "Synced N ago" reads the clock through package:clock, never the wall clock,
// so goldens stay deterministic under withClock.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../date_format.dart';
import 'auth_sync_status.dart';

/// The auth/sync footer, rendered from a standalone [AuthSyncStatus].
class AuthSyncFooter extends StatelessWidget {
  const AuthSyncFooter({
    required this.status,
    required this.onSignIn,
    required this.onSignOut,
    required this.onSync,
    required this.onOpenProperties,
    super.key,
  });

  /// The state the footer renders — the priority ladder lives on this object.
  final AuthSyncStatus status;

  /// Run the OAuth sign-in (fresh or re-auth).
  final VoidCallback onSignIn;

  /// Drop the session and go offline. Only shown when authenticated.
  final VoidCallback onSignOut;

  /// Trigger a sync now. Only offered with a live session.
  final VoidCallback onSync;

  /// Open Properties — the "needs attention" button's destination, where the
  /// sanitized cause and Sync actions live (#136).
  final VoidCallback onOpenProperties;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A stuck permanent failure gets its own persistent, always-visible
          // affordance — above the primary action, so it is never hidden by it.
          if (status.needsAttention && !status.needsReauth) ...[
            _AttentionButton(onPressed: onOpenProperties),
            const SizedBox(height: 8),
          ],
          _primaryButton(context),
          const SizedBox(height: 10),
          _StatusRow(
            status: status,
            onSignOut: onSignOut,
            colors: colors,
            textTheme: theme.textTheme,
          ),
        ],
      ),
    );
  }

  Widget _primaryButton(BuildContext context) {
    final syncing = status.isSyncing;
    switch (status.primaryAction) {
      case FooterAction.reauth:
        return FilledButton.icon(
          key: const Key('auth-footer-signin'),
          onPressed: syncing ? null : onSignIn,
          icon: const Icon(Icons.vpn_key_outlined, size: 16),
          label: Text(syncing ? 'Signing in…' : 'Sign in again'),
        );
      case FooterAction.signIn:
        return FilledButton.icon(
          key: const Key('auth-footer-signin'),
          onPressed: syncing ? null : onSignIn,
          icon: const Icon(Icons.login, size: 16),
          label: Text(syncing ? 'Signing in…' : 'Sign in with Google'),
        );
      case FooterAction.sync:
        return FilledButton.tonalIcon(
          key: const Key('auth-footer-sync'),
          onPressed: syncing ? null : onSync,
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(syncing ? 'Syncing…' : 'Sync now'),
        );
    }
  }
}

/// The persistent "Sync needs attention" button (opens Properties).
class _AttentionButton extends StatelessWidget {
  const _AttentionButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      key: const Key('auth-footer-attention'),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.error,
        side: BorderSide(color: colors.error.withValues(alpha: 0.5)),
      ),
      icon: const Icon(Icons.warning_amber_rounded, size: 16),
      label: const Text('Sync needs attention'),
    );
  }
}

/// The status line: a state-colored dot, the priority phrase, and — when a
/// session exists — a Sign out affordance.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.status,
    required this.onSignOut,
    required this.colors,
    required this.textTheme,
  });

  final AuthSyncStatus status;
  final VoidCallback onSignOut;
  final ColorScheme colors;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final phrase = Text(
      _statusText(),
      style: textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      overflow: TextOverflow.ellipsis,
    );
    final absolute = _absoluteLastSync();

    return Row(
      children: [
        Container(
          key: const Key('auth-footer-dot'),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: _dotColor(), shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        // The Tooltip wraps only the phrase and adds no geometry of its own, so
        // the footer's layout (and its goldens) are untouched by #222.
        Expanded(
          child: absolute == null
              ? phrase
              : Tooltip(message: absolute, child: phrase),
        ),
        if (status.isAuthenticated) ...[
          const SizedBox(width: 8),
          TextButton(
            key: const Key('auth-footer-signout'),
            onPressed: onSignOut,
            // Compact PADDING keeps the label tight, but the tap target stays
            // the 48dp Material minimum (padded tapTargetSize) — this footer
            // also renders in the mobile drawer, where a coarse pointer needs
            // the full hit area even for a small-looking affordance.
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            child: const Text('Sign out'),
          ),
        ],
      ],
    );
  }

  /// The absolute LOCAL time behind the "Synced N ago" phrase, as the tooltip
  /// message — or null when there is nothing to show (#222).
  ///
  /// "Synced 12m ago" is friendly but unverifiable, so the exact moment lives
  /// one hover (or, on touch, one long press) away rather than inline. Every
  /// other state has no moment to name: a never-synced footer and a stamp too
  /// broken to parse both get NO tooltip, instead of an empty bubble or one
  /// that could only repeat "recently".
  String? _absoluteLastSync() {
    if (status.status != FooterStatus.synced) return null;
    final at = DateTime.tryParse(status.lastSynced ?? '');
    return at == null ? null : 'Last sync: ${formatAbsoluteLocal(at)}';
  }

  Color _dotColor() {
    switch (status.status) {
      case FooterStatus.sessionExpired:
      case FooterStatus.needsAttention:
      case FooterStatus.error:
        return colors.error;
      case FooterStatus.synced:
      case FooterStatus.ready:
        return colors.primary;
      case FooterStatus.offline:
        return colors.onSurfaceVariant;
    }
  }

  String _statusText() {
    switch (status.status) {
      case FooterStatus.sessionExpired:
        return 'Session expired';
      case FooterStatus.needsAttention:
        return 'Needs attention';
      case FooterStatus.error:
        return 'Sync error';
      case FooterStatus.synced:
        return 'Synced ${formatSynced(status.lastSynced!)}';
      case FooterStatus.ready:
        return 'Ready';
      case FooterStatus.offline:
        return 'Offline';
    }
  }
}

/// A coarse "how long ago" label for a last-synced RFC-3339 timestamp — the
/// port of the reference's `formatSynced`. "Now" comes from package:clock, so
/// the label is a pure function of (timestamp, injected clock).
String formatSynced(String lastSynced) {
  final then = DateTime.tryParse(lastSynced);
  if (then == null) return 'recently';
  final secs = clock.now().toUtc().difference(then.toUtc()).inSeconds;
  if (secs < 60) return 'just now';
  if (secs < 3600) return '${secs ~/ 60}m ago';
  if (secs < 86400) return '${secs ~/ 3600}h ago';
  return '${secs ~/ 86400}d ago';
}
