// The LIVE sidebar auth/sync footer — the composition-root (F5) wrapper that
// binds the standalone [AuthSyncFooter] (T6.2) to the running app's providers.
//
// It watches the live auth snapshot and sanitized sync-status streams, folds
// them into the [AuthSyncStatus] the footer's priority ladder switches on, and
// routes each affordance to the real action seam (sign-in / sign-out / sync-now
// / open Properties). The transient "a run is in flight" signal — which no
// stream carries (the status holds outcomes, not "running") — is tracked here,
// around the awaited sync, so the button shows "Syncing…" and disables while a
// run is live.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../properties.dart';
import 'auth_sync_footer.dart';
import 'auth_sync_status.dart';

/// The auth/sync footer wired to the live providers — mounted at the bottom of
/// the real sidebar (and the mobile drawer) via `sidebarFooterProvider`.
class SidebarAuthSyncFooter extends ConsumerStatefulWidget {
  const SidebarAuthSyncFooter({super.key});

  @override
  ConsumerState<SidebarAuthSyncFooter> createState() =>
      _SidebarAuthSyncFooterState();
}

class _SidebarAuthSyncFooterState extends ConsumerState<SidebarAuthSyncFooter> {
  bool _syncing = false;

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(authSnapshotProvider).value;
    final sync = ref.watch(syncStatusViewProvider);
    final status = AuthSyncStatus(
      isAuthenticated: snapshot?.isAuthenticated ?? false,
      needsReauth: (snapshot?.needsReauth ?? false) || sync.needsReauth,
      needsAttention: sync.needsAttention,
      hasError: sync.lastError != null,
      activity: _syncing ? SyncActivity.syncing : SyncActivity.idle,
      lastSynced: sync.lastSynced,
    );

    return AuthSyncFooter(
      status: status,
      onSignIn: ref.read(signInActionProvider),
      onSignOut: ref.read(signOutActionProvider),
      onSync: _sync,
      onOpenProperties: _openProperties,
    );
  }

  void _openProperties() {
    // The footer also renders inside the mobile drawer; close it first so
    // Properties never opens stacked over an open drawer (#166).
    ref.read(mobileScaffoldKeyProvider).currentState?.closeDrawer();
    showProperties(context);
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      await ref.read(refreshActionProvider)();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }
}
