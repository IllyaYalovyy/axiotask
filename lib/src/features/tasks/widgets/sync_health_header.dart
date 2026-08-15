import 'package:flutter/material.dart';

import '../../../sync/health/sync_health.dart';

final class SyncHealthHeader extends StatelessWidget {
  const SyncHealthHeader({required this.health, this.onAction, super.key});

  final SyncHealth health;
  final ValueChanged<SyncHealthAction>? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visual = _visualFor(health.outcome, colors);
    final unresolved = health.counts.total;
    final semantics =
        'Synchronization ${health.summary}. '
        '${health.reasonLabel}. Last successful sync ${health.lastSuccessLabel}. '
        '$unresolved unresolved ${unresolved == 1 ? 'change' : 'changes'}.';
    final actionLabel = _actionLabel(health.action);

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: semantics,
      child: Material(
        color: visual.background,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: <Widget>[
              Icon(visual.icon, color: visual.foreground, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          health.summary,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: visual.foreground,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            health.reasonLabel,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: visual.foreground),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Last successful sync: ${health.lastSuccessLabel}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: visual.foreground),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _CountChip(counts: health.counts, foreground: visual.foreground),
              if (actionLabel != null) ...<Widget>[
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: onAction == null
                      ? null
                      : () => onAction!(health.action),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: visual.foreground,
                    side: BorderSide(color: visual.foreground),
                  ),
                  child: Text(actionLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
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
