// The Sync activity screen (#218) — the per-run sync history, reachable ONLY
// from Properties → Sync.
//
// Deliberately NOT on the front page: quiet sync stands. No banner, no counter,
// no chip on the main UI — a user who wants to know what sync has been doing
// goes and looks, and everyone else is never told.
//
// Two surfaces, one content: a full-screen page on a phone (where a 640-wide
// dialog would be a letterbox) and a dialog-sized surface on the desktop,
// branching at the same width [ListDetailScaffold.breakpoint] the shell uses.
// Both are pushed as a route ABOVE the Properties dialog, so one system back
// closes the activity and lands back on Properties — one rung per press.
//
// PRIVACY: a failed run renders [syncFailureLabel] of its stored
// [SyncFailureKind] and nothing else. The classification is a closed
// vocabulary, so no provider or API text — a request URL with its query params,
// a refresh-denial string, raw SQL, a captive portal's HTML login page — can
// reach this screen (#131/#187).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_settings.dart';
import '../app/providers.dart';
import '../model/sync_run.dart';
import 'date_format.dart';
import 'list_detail_scaffold.dart';

/// Open the Sync activity screen over the current surface (the Properties
/// dialog). A plain dialog route: the framework's own back handling pops it,
/// which is exactly the "return to Properties" rung.
Future<void> showSyncActivity(BuildContext context) => showDialog<void>(
  context: context,
  // The screen owns its own insets: the phone surface paints edge to edge (a
  // route-level SafeArea would inset the whole page and leave the scrim showing
  // as a stripe under the status bar) and pads its CONTENT instead.
  useSafeArea: false,
  builder: (_) => const SyncActivityScreen(),
);

/// The sync history: a summary of where sync stands, then the recent runs.
class SyncActivityScreen extends ConsumerWidget {
  const SyncActivityScreen({super.key});

  /// How many runs the screen asks for. The store retains more; this is the
  /// window a human would actually scroll.
  static const int displayedRuns = 50;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact =
        MediaQuery.sizeOf(context).width < ListDetailScaffold.breakpoint;
    final body = _body(context, ref);

    if (compact) {
      // Full-screen on a phone. SafeArea keeps the header clear of the status
      // bar and the list's last row clear of the gesture bar.
      return Dialog.fullscreen(
        child: SizedBox.expand(
          key: const Key('sync-activity-surface'),
          child: SafeArea(child: body),
        ),
      );
    }
    // Not compact — a centred dialog. Its inset padding ADDS the display's own
    // safe-area padding to the Material default (40/24): on the desktop that is
    // zero, but a phone held in landscape is wide enough to land here and its
    // cutout is on the side the dialog would otherwise touch.
    final safe = MediaQuery.paddingOf(context);
    return Dialog(
      insetPadding: EdgeInsets.fromLTRB(
        40 + safe.left,
        24 + safe.top,
        40 + safe.right,
        24 + safe.bottom,
      ),
      child: ConstrainedBox(
        key: const Key('sync-activity-surface'),
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
        child: body,
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final compact =
        MediaQuery.sizeOf(context).width < ListDetailScaffold.breakpoint;
    final settings = ref.watch(appSettingsProvider);
    final runs = ref.watch(syncRunsProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(context, theme, compact),
        // Flexible + shrinkWrap, not Expanded: a short history (or none at all)
        // gets a dialog sized to its content instead of 620dp of empty surface.
        // The list still scrolls once the runs outgrow the room.
        Flexible(
          child: ListView(
            key: const Key('sync-activity-list'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            children: [
              ..._summary(theme, settings),
              const SizedBox(height: 16),
              _heading(theme, 'Recent runs'),
              ...switch (runs) {
                AsyncData(:final value) =>
                  value.isEmpty
                      ? [_empty(theme)]
                      : [for (final r in value) _runTile(theme, r)],
                AsyncError() => [
                  Text(
                    "Couldn't read the sync history.",
                    key: const Key('sync-activity-error'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                // A local read of a few dozen rows lands within a frame; a
                // static line beats a spinner that would flash and animate.
                _ => [
                  Text(
                    'Loading…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              },
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, ThemeData theme, bool compact) {
    final title = Text('Sync activity', style: theme.textTheme.titleLarge);
    // The dismiss affordance sits where each platform's convention puts it: a
    // LEADING back arrow on the phone (this surface reads as a page pushed over
    // Properties), a trailing close box on the desktop (it reads as a dialog
    // over a dialog). Same route pop either way.
    final dismiss = IconButton(
      key: const Key('sync-activity-close'),
      icon: Icon(compact ? Icons.arrow_back : Icons.close),
      tooltip: compact ? 'Back' : 'Close',
      onPressed: () => Navigator.of(context).pop(),
    );
    return Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(8, 8, 8, 8)
          : const EdgeInsets.fromLTRB(20, 16, 8, 8),
      child: Row(
        children: compact
            ? [dismiss, const SizedBox(width: 4), Expanded(child: title)]
            : [
                Icon(Icons.history, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: title),
                dismiss,
              ],
      ),
    );
  }

  List<Widget> _summary(ThemeData theme, AppSettingsView settings) {
    final last = DateTime.tryParse(settings.sync.lastSynced ?? '');
    return [
      _heading(theme, 'Where sync stands'),
      _stat(
        theme,
        'Last synced',
        last == null
            ? formatRelativeSince(null)
            : '${formatRelativeSince(last)} · ${formatAbsoluteLocal(last)}',
      ),
      _stat(theme, 'Syncs this session', '${settings.sync.totalSyncs}'),
      _stat(theme, 'Pending local changes', '${settings.pendingPushes}'),
    ];
  }

  Widget _empty(ThemeData theme) => Padding(
    key: const Key('sync-activity-empty'),
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('No syncs yet', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 4),
        Text(
          'Runs appear here once sync has something to do.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  Widget _runTile(ThemeData theme, SyncRun run) {
    final colors = theme.colorScheme;
    final when = run.ranAt == null
        ? 'Unknown time'
        : '${formatAbsoluteLocal(run.ranAt!)} · '
              '${formatRelativeSince(run.ranAt)}';
    return Padding(
      key: Key('sync-run-${run.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The icon alone carries the outcome, so it is labelled for a screen
          // reader rather than left as decoration.
          Semantics(
            label: run.failed ? 'Failed run' : 'Successful run',
            child: Icon(
              run.failed ? Icons.error_outline : Icons.check_circle_outline,
              size: 20,
              color: run.failed ? colors.error : colors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(when, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  '↓${run.pulled} ↑${run.pushed} · '
                  '${run.conflicts} conflicts · ${run.durationMs} ms',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (run.failure != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    syncFailureLabel(run.failure!),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heading(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  Widget _stat(ThemeData theme, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 160,
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
}
