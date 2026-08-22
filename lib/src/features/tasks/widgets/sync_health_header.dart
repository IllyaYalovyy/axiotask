import 'package:flutter/material.dart';

import '../../../sync/health/sync_health.dart';

final class SyncHealthHeader extends StatelessWidget {
  const SyncHealthHeader({
    required this.health,
    this.onAction,
    this.diagnosticsBuilder,
    this.iconOnly = false,
    super.key,
  });

  final SyncHealth health;
  final ValueChanged<SyncHealthAction>? onAction;
  final WidgetBuilder? diagnosticsBuilder;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    if (health.outcome == SyncHealthOutcome.good) {
      return _CompactSyncHealth(
        health: health,
        diagnosticsBuilder: diagnosticsBuilder,
        iconOnly: iconOnly,
      );
    }
    final colors = Theme.of(context).colorScheme;
    final visual = _visualFor(health.outcome, colors);
    final actionLabel = _actionLabel(health.action);

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: _semanticsLabel(health),
      child: Material(
        color: visual.background,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: _ExpandedHealthContent(
            health: health,
            visual: visual,
            actionLabel: actionLabel,
            onAction: onAction,
            diagnosticsBuilder: diagnosticsBuilder,
          ),
        ),
      ),
    );
  }
}

final class _CompactSyncHealth extends StatelessWidget {
  const _CompactSyncHealth({
    required this.health,
    required this.iconOnly,
    this.diagnosticsBuilder,
  });

  final SyncHealth health;
  final WidgetBuilder? diagnosticsBuilder;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visual = _visualFor(health.outcome, colors);
    final relative = health.lastSuccessRelativeLabel ?? 'verification required';
    return Semantics(
      button: true,
      label: '${_semanticsLabel(health)} Open synchronization details.',
      child: Tooltip(
        message: 'Sync details',
        child: iconOnly
            ? IconButton(
                key: const Key('sync-health-good'),
                tooltip: 'Sync details',
                onPressed: () => _showSyncDetails(
                  context,
                  health: health,
                  diagnosticsBuilder: diagnosticsBuilder,
                ),
                icon: Icon(visual.icon, color: visual.foreground),
              )
            : TextButton.icon(
                key: const Key('sync-health-good'),
                onPressed: () => _showSyncDetails(
                  context,
                  health: health,
                  diagnosticsBuilder: diagnosticsBuilder,
                ),
                icon: Icon(visual.icon, color: visual.foreground, size: 20),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'Synced',
                      style: TextStyle(
                        color: visual.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(relative, style: TextStyle(color: visual.foreground)),
                  ],
                ),
              ),
      ),
    );
  }
}

final class _ExpandedHealthContent extends StatelessWidget {
  const _ExpandedHealthContent({
    required this.health,
    required this.visual,
    required this.actionLabel,
    required this.onAction,
    this.diagnosticsBuilder,
  });

  final SyncHealth health;
  final ({Color background, Color foreground, IconData icon}) visual;
  final String? actionLabel;
  final ValueChanged<SyncHealthAction>? onAction;
  final WidgetBuilder? diagnosticsBuilder;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.textScalerOf(context).scale(14) > 18.2;
    final summary = _Summary(health: health, visual: visual);
    final controls = _HealthControls(
      health: health,
      visual: visual,
      actionLabel: actionLabel,
      onAction: onAction,
      diagnosticsBuilder: diagnosticsBuilder,
    );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[summary, const SizedBox(height: 8), controls],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: summary),
        const SizedBox(width: 12),
        controls,
      ],
    );
  }
}

final class _Summary extends StatelessWidget {
  const _Summary({required this.health, required this.visual});

  final SyncHealth health;
  final ({Color background, Color foreground, IconData icon}) visual;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Icon(visual.icon, color: visual.foreground, size: 24),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              health.summary,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: visual.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              health.reasonLabel,
              style: TextStyle(color: visual.foreground),
            ),
            const SizedBox(height: 2),
            Text(
              'Last successful sync: ${health.lastSuccessLabel}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: visual.foreground),
            ),
          ],
        ),
      ),
    ],
  );
}

final class _HealthControls extends StatelessWidget {
  const _HealthControls({
    required this.health,
    required this.visual,
    required this.actionLabel,
    required this.onAction,
    this.diagnosticsBuilder,
  });

  final SyncHealth health;
  final ({Color background, Color foreground, IconData icon}) visual;
  final String? actionLabel;
  final ValueChanged<SyncHealthAction>? onAction;
  final WidgetBuilder? diagnosticsBuilder;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: <Widget>[
      if (health.counts.total > 0)
        _CountChip(counts: health.counts, foreground: visual.foreground),
      IconButton(
        tooltip: 'Sync details',
        color: visual.foreground,
        onPressed: () => _showSyncDetails(
          context,
          health: health,
          diagnosticsBuilder: diagnosticsBuilder,
        ),
        icon: const Icon(Icons.info_outline),
      ),
      if (actionLabel != null)
        OutlinedButton(
          onPressed: onAction == null ? null : () => onAction!(health.action),
          style: OutlinedButton.styleFrom(
            foregroundColor: visual.foreground,
            side: BorderSide(color: visual.foreground),
          ),
          child: Text(actionLabel!),
        ),
    ],
  );
}

Future<void> _showSyncDetails(
  BuildContext context, {
  required SyncHealth health,
  WidgetBuilder? diagnosticsBuilder,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Synchronization details'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('${health.summary}: ${health.reasonLabel}'),
          const SizedBox(height: 12),
          const Text('Last successful sync'),
          Text(health.lastSuccessExactLabel),
          if (health.lastSuccessRelativeLabel case final relative?)
            Text(relative),
          const SizedBox(height: 12),
          Text(_unresolvedLabel(health.counts)),
        ],
      ),
    ),
    actions: <Widget>[
      if (diagnosticsBuilder != null)
        TextButton.icon(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            Navigator.of(
              context,
            ).push<void>(MaterialPageRoute<void>(builder: diagnosticsBuilder));
          },
          icon: const Icon(Icons.receipt_long_outlined),
          label: const Text('Open diagnostics'),
        ),
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('Close'),
      ),
    ],
  ),
);

String _semanticsLabel(SyncHealth health) =>
    'Synchronization ${health.summary}. ${health.reasonLabel}. '
    'Last successful sync ${health.lastSuccessLabel}. '
    '${_unresolvedLabel(health.counts)}.';

String _unresolvedLabel(SyncWorkCounts counts) {
  final total = counts.total;
  if (total == 0) return 'No unresolved changes';
  return '$total unresolved ${total == 1 ? 'change' : 'changes'}';
}

final class _CountChip extends StatelessWidget {
  const _CountChip({required this.counts, required this.foreground});

  final SyncWorkCounts counts;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final count = counts.total;
    return Tooltip(
      message:
          'Pending ${counts.pending}, in flight ${counts.inFlight}, '
          'uncertain ${counts.uncertain}, failed ${counts.failed}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: foreground.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '$count unresolved',
          style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

({Color background, Color foreground, IconData icon}) _visualFor(
  SyncHealthOutcome outcome,
  ColorScheme colors,
) => switch (outcome) {
  SyncHealthOutcome.inactive => (
    background: colors.surfaceContainerHighest,
    foreground: colors.onSurfaceVariant,
    icon: Icons.pause_circle_outline,
  ),
  SyncHealthOutcome.pending => (
    background: colors.tertiaryContainer,
    foreground: colors.onTertiaryContainer,
    icon: Icons.sync,
  ),
  SyncHealthOutcome.failed => (
    background: colors.errorContainer,
    foreground: colors.onErrorContainer,
    icon: Icons.sync_problem,
  ),
  SyncHealthOutcome.good => (
    background: const Color(0xffd9f3e3),
    foreground: const Color(0xff153f28),
    icon: Icons.cloud_done_outlined,
  ),
};

String? _actionLabel(SyncHealthAction action) => switch (action) {
  SyncHealthAction.none => null,
  SyncHealthAction.connect => 'Connect',
  SyncHealthAction.reauthorize => 'Reauthorize',
  SyncHealthAction.resume => 'Resume',
  SyncHealthAction.retry => 'Retry',
};
