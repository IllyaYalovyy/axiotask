// The Properties dialog — the port of `Properties.svelte`, minus the Shortcuts
// tab (which dies with the keyboard layer). Four tabs: Sync, Appearance,
// Account, About. Fresh Material 3 visuals (Q3), not a pixel port.
//
// What is REAL today: the theme radio (re-themes live), the read-write/auto-sync
// config toggles (persist-first), and backup Export/Restore (writes/reads a
// lossless JSON snapshot). What waits on the auth/scheduler-integration task is
// seam-backed with safe defaults: the sync stats read "never synced", the sync
// actions (Sync now / Fresh sync) are DISABLED until authenticated — exactly the
// reference's gating — and the Account sign-in/out call the (currently no-op)
// action seams. Every control is exercised in tests via provider overrides.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_settings.dart';
import '../app/backup_service.dart';
import '../app/local_data_reset.dart';
import '../app/prefs_controller.dart';
import '../app/providers.dart';
import 'auth/account_section.dart';
import 'date_format.dart';
import 'sync_activity.dart';
import 'url_opener.dart';

/// GitHub Sponsors — the ONE place axiotask ever asks for money (#239). The row
/// lives in the About tab and nowhere else: no banner, no startup prompt, no
/// badge on the Properties button. App-store billing policy is deliberately
/// out of scope here (the user deferred it).
const _sponsorsUrl = 'https://github.com/sponsors/IllyaYalovyy';

/// Material's minimum touch target — the height the dialog's tabs are pinned
/// to, since Material's own text-only [Tab] default is 46dp.
const _tabHeight = 48.0;

/// Open the Properties dialog over the current app surface.
Future<void> showProperties(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const PropertiesDialog(),
);

/// The tabbed Properties dialog.
class PropertiesDialog extends ConsumerStatefulWidget {
  const PropertiesDialog({super.key});

  @override
  ConsumerState<PropertiesDialog> createState() => _PropertiesDialogState();
}

class _PropertiesDialogState extends ConsumerState<PropertiesDialog> {
  late bool _pushEnabled;
  late bool _autoSync;
  bool _confirmingPush = false;
  bool _busy = false;

  // The most recent backup result / error, shown INLINE in the Sync tab. A
  // SnackBar would render behind this modal dialog (invisible to the user), so
  // the confirmation lives inside the dialog where it is actually seen.
  String? _notice;
  bool _noticeIsError = false;

  // The Account tab's own notice — the reset outcome, shown beside the button
  // that ran it rather than on the Sync tab the user is not looking at.
  String? _resetNotice;
  bool _resetNoticeIsError = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(configControllerProvider);
    _pushEnabled = config.pushEnabled;
    _autoSync = config.autoSyncOnStart;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final theme = Theme.of(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
        child: DefaultTabController(
          length: 4,
          // An install with no Google credentials opens straight on Account:
          // that is the only tab that says what is wrong and names the file to
          // edit, and the footer's "Google setup needed" is what sent the user
          // here (#228). Read at controller-creation time, so a later change
          // never yanks the tab out from under the user.
          initialIndex: settings.credentialsMissing ? 2 : 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(context, settings, theme),
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                // Material's text-only tab is 46dp tall — 2dp under its own
                // 48dp touch-target minimum, and the only sub-48 target left in
                // the app (#247). Named here rather than left to the default.
                tabs: [
                  Tab(text: 'Sync', height: _tabHeight),
                  Tab(text: 'Appearance', height: _tabHeight),
                  Tab(text: 'Account', height: _tabHeight),
                  Tab(text: 'About', height: _tabHeight),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _syncTab(context, settings, theme),
                    _appearanceTab(context, theme),
                    _accountTab(settings),
                    _aboutTab(settings, theme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    AppSettingsView settings,
    ThemeData theme,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
    child: Row(
      children: [
        Icon(Icons.settings_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        // Flexible, so a phone at 2x system text ellipsizes the title instead
        // of overflowing the header (#247). It costs nothing at every other
        // size: the [Spacer] beside it is pure slack, so as long as the title
        // fits it still takes its natural width.
        Flexible(
          child: Text(
            'Properties',
            style: theme.textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (settings.instance != null) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Chip(
              label: Text(
                settings.instance!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
        const Spacer(),
        IconButton(
          key: const Key('properties-close'),
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );

  // ── Sync ────────────────────────────────────────────────────────────────
  Widget _syncTab(
    BuildContext context,
    AppSettingsView settings,
    ThemeData theme,
  ) {
    final colors = theme.colorScheme;
    return ListView(
      key: const Key('sync-tab-list'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      children: [
        _sectionHeading(theme, 'Sync mode'),
        SwitchListTile(
          key: const Key('sync-push-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Read-write sync'),
          subtitle: Text(
            _pushEnabled
                ? 'Local edits are pushed to Google Tasks.'
                : 'Read-only: changes stay on this device and are never pushed.',
          ),
          value: _pushEnabled,
          onChanged: _busy
              ? null
              : (v) {
                  // Turning ON is confirmed inline; turning OFF is immediate.
                  if (v && !_pushEnabled) {
                    setState(() => _confirmingPush = true);
                  } else {
                    _setPush(false);
                  }
                },
        ),
        if (_confirmingPush) _pushConfirm(context, colors),
        SwitchListTile(
          key: const Key('sync-autosync-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto-sync on startup'),
          subtitle: const Text('Sync automatically when the app launches.'),
          value: _autoSync,
          onChanged: _busy ? null : (v) => _setAutoSync(v),
        ),
        const SizedBox(height: 16),
        // The Status block summarises where sync stands; the per-run history
        // lives one tap away on its own screen (#218) rather than on the front
        // page or crowded in here.
        Row(
          children: [
            Expanded(child: _sectionHeading(theme, 'Status')),
            TextButton.icon(
              key: const Key('sync-activity-button'),
              onPressed: () => showSyncActivity(context),
              icon: const Icon(Icons.history, size: 18),
              label: const Text('View activity'),
            ),
          ],
        ),
        _statusBlock(theme, settings),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('sync-now-button'),
              onPressed: settings.authenticated && !_busy ? _syncNow : null,
              icon: const Icon(Icons.sync),
              label: const Text('Sync now'),
            ),
            OutlinedButton.icon(
              key: const Key('fresh-sync-button'),
              onPressed: settings.authenticated && !_busy
                  ? () => _confirmFreshSync(context)
                  : null,
              icon: const Icon(Icons.sync_problem),
              label: const Text('Fresh sync'),
            ),
          ],
        ),
        if (!settings.authenticated)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Sign in on the Account tab to enable syncing.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 20),
        _sectionHeading(theme, 'Backup'),
        Text(
          'Save or restore a complete JSON snapshot of every list and task. '
          'Restore is non-destructive — it adds or refreshes, never deletes.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        if (_notice != null) ...[
          const SizedBox(height: 12),
          _noticeBanner(theme),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('export-backup-button'),
              onPressed: _busy ? null : _exportBackup,
              icon: const Icon(Icons.download),
              label: const Text('Export backup…'),
            ),
            OutlinedButton.icon(
              key: const Key('restore-backup-button'),
              onPressed: _busy ? null : _restoreBackup,
              icon: const Icon(Icons.upload),
              label: const Text('Restore latest…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _pushConfirm(BuildContext context, ColorScheme colors) => Card(
    key: const Key('enable-push-confirm'),
    color: colors.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Push your local changes to Google Tasks? Edits on this device '
            'will start syncing to your account.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('confirm-enable-push'),
                onPressed: () {
                  setState(() => _confirmingPush = false);
                  _setPush(true);
                },
                child: const Text('Enable push'),
              ),
              TextButton(
                onPressed: () => setState(() => _confirmingPush = false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _statusBlock(ThemeData theme, AppSettingsView settings) {
    final s = settings.sync;
    final colors = theme.colorScheme;
    final children = <Widget>[];
    if (s.needsAttention && s.lastError != null) {
      children.add(
        _alert(
          theme,
          'Sync needs attention: ${s.lastError} — automatic retries have '
          'slowed down until this is resolved.',
          colors.error,
        ),
      );
    } else if (s.lastError != null) {
      children.add(
        _alert(theme, 'Last sync failed: ${s.lastError}', colors.error),
      );
    }
    children.addAll([
      _stat(theme, 'Last synced', _lastSyncedLabel(s.lastSynced)),
      _stat(theme, 'Pending changes', '${settings.pendingPushes}'),
      _stat(
        theme,
        'Last run',
        '↓${s.lastPulled} ↑${s.lastPushed} · ${s.lastConflicts} conflicts · '
            '${s.lastDeleted} removed',
      ),
      _stat(theme, 'Syncs this session', '${s.totalSyncs}'),
    ]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _alert(ThemeData theme, String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    ),
  );

  Widget _stat(ThemeData theme, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
      ],
    ),
  );

  // ── Appearance ────────────────────────────────────────────────────────────
  Widget _appearanceTab(BuildContext context, ThemeData theme) {
    final current = ref.watch(prefsControllerProvider).theme;
    Widget option(String id, String label, Key key) => RadioListTile<String>(
      key: key,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: id,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      children: [
        _sectionHeading(theme, 'Theme'),
        RadioGroup<String>(
          groupValue: current,
          onChanged: (v) => ref
              .read(prefsControllerProvider.notifier)
              .setTheme(v ?? 'system'),
          child: Column(
            children: [
              option('light', 'Light', const Key('theme-light')),
              option('dark', 'Dark', const Key('theme-dark')),
              option('system', 'Follow system', const Key('theme-system')),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'A fresh dark and light theme. "Follow system" tracks your desktop '
          'preference.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  // ── Account ───────────────────────────────────────────────────────────────
  Widget _accountTab(AppSettingsView settings) => SingleChildScrollView(
    key: const Key('account-tab-scroll'),
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
    child: AccountSection(
      isAuthenticated: settings.authenticated,
      needsReauth: settings.needsReauth,
      scopes: settings.scopes,
      missingConfigPath: settings.credentialsMissing
          ? settings.configPath
          : null,
      pendingPushes: settings.pendingPushes,
      resetNotice: _resetNotice,
      resetNoticeIsError: _resetNoticeIsError,
      resetBusy: _busy,
      onSignIn: ref.read(signInActionProvider),
      onSignOut: ref.read(signOutActionProvider),
      onResetLocalData: _resetLocalData,
    ),
  );

  // ── About ─────────────────────────────────────────────────────────────────
  Widget _aboutTab(AppSettingsView settings, ThemeData theme) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
    children: [
      Text('axiotask', style: theme.textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text(
        'A fast, local-first Google Tasks client.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 20),
      _stat(theme, 'Version', 'v${settings.version}'),
      _stat(theme, 'Instance', settings.instance ?? 'default (production)'),
      _about(theme, 'Database', settings.dbPath),
      _about(theme, 'Config', settings.configPath),
      const Divider(height: 32),
      _sponsorRow(theme),
    ],
  );

  /// The quiet donation ask: a plain tappable row that opens GitHub Sponsors in
  /// the system browser through the same [urlOpenerProvider] seam as the task
  /// link badges. A full-width [ListTile] so touch and mouse get the same
  /// target — the heart alone would be a 24dp bullseye on a phone.
  Widget _sponsorRow(ThemeData theme) => ListTile(
    key: const Key('sponsor-link'),
    contentPadding: EdgeInsets.zero,
    leading: Icon(Icons.favorite_outline, color: theme.colorScheme.primary),
    title: const Text('Support axiotask'),
    subtitle: Text(
      'Donate via GitHub Sponsors',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
    trailing: Icon(
      Icons.open_in_new,
      size: 18,
      color: theme.colorScheme.onSurfaceVariant,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    onTap: _openSponsors,
  );

  Widget _about(ThemeData theme, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '—' : value,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ],
    ),
  );

  Widget _sectionHeading(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  // ── Actions ─────────────────────────────────────────────────────────────
  Future<void> _openSponsors() => ref.read(urlOpenerProvider)(_sponsorsUrl);

  Future<void> _setPush(bool v) async {
    await ref.read(configControllerProvider).setPushEnabled(v);
    if (mounted) setState(() => _pushEnabled = v);
  }

  Future<void> _setAutoSync(bool v) async {
    await ref.read(configControllerProvider).setAutoSyncOnStart(v);
    if (mounted) setState(() => _autoSync = v);
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      // The real "sync when authed, else reload" action — the same seam the
      // sidebar footer and mobile pull-to-refresh drive.
      await ref.read(refreshActionProvider)();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmFreshSync(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('fresh-sync-confirm'),
        title: const Text('Fresh sync'),
        content: const Text(
          'Drop local data and re-download everything from Google Tasks? '
          'Unsynced local changes can be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('fresh-sync-confirm-button'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Fresh sync'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(freshSyncActionProvider)();
  }

  Future<void> _exportBackup() async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final r = await ref.read(backupServiceProvider).export();
      _notify(
        'Backed up ${r.tasks} task(s) in ${r.lists} list(s) → ${r.path}',
        isError: false,
      );
    } on BackupError catch (e) {
      _notify(e.message, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreBackup() async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final r = await ref.read(backupServiceProvider).importFrom();
      _notify(
        'Restored ${r.tasks} task(s) in ${r.lists} list(s) ← ${r.path}',
        isError: false,
      );
    } on BackupError catch (e) {
      _notify(e.message, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Run the account-switch reset (#215). The confirm gate has already been
  /// passed inside [AccountSection]; this only executes and reports. A refusal
  /// (no durable recovery copy) is reported in the SAME place as a success —
  /// the user must never be left guessing whether their data is still there.
  Future<void> _resetLocalData() async {
    setState(() {
      _busy = true;
      _resetNotice = null;
    });
    try {
      final r = await ref.read(localDataResetProvider).run();
      _notifyReset(
        'Erased ${r.tasks} task(s) in ${r.lists} list(s). A recovery copy was '
        'saved to ${r.dumpPath}. Sign in with the other account to pull its '
        'tasks.',
        isError: false,
      );
    } on ResetAborted catch (e) {
      _notifyReset(e.message, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notifyReset(String message, {required bool isError}) {
    if (!mounted) return;
    setState(() {
      _resetNotice = message;
      _resetNoticeIsError = isError;
    });
  }

  void _notify(String message, {required bool isError}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _noticeIsError = isError;
    });
  }

  Widget _noticeBanner(ThemeData theme) {
    final colors = theme.colorScheme;
    final bg = _noticeIsError
        ? colors.errorContainer
        : colors.secondaryContainer;
    final fg = _noticeIsError
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    return Container(
      key: const Key('backup-notice'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _noticeIsError ? Icons.error_outline : Icons.check_circle_outline,
            size: 18,
            color: fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _notice!,
              style: theme.textTheme.bodySmall?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }

  /// The "Last synced" value: the relative phrase and, behind it, the absolute
  /// LOCAL time — "3m ago · Aug 22 10:48", or "never" (#222). This tab is the
  /// stats surface, so the absolute time belongs inline here (in the sidebar
  /// footer it stays one hover/long-press away).
  String _lastSyncedLabel(String? rfc3339) =>
      formatLastSynced(DateTime.tryParse(rfc3339 ?? ''));
}
