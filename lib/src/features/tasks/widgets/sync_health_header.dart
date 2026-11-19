import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../sync/health/sync_health.dart';

/// Synchronization status for the application header.
///
/// Routine states ([SyncHealth.usesCompactStatus]) render as one compact
/// header control whose details open on demand. Every other state renders a
/// bounded banner with a specific explanation, the unresolved local work, the
/// last-success age, the recovery action and a details button, each reachable
/// as its own accessible control.
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
    if (health.usesCompactStatus) {
      return _CompactSyncHealth(
        health: health,
        diagnosticsBuilder: diagnosticsBuilder,
        iconOnly: iconOnly,
      );
    }
    final colors = Theme.of(context).colorScheme;
    final visual = _visualFor(health, colors);

    return Material(
      key: const Key('sync-health-banner'),
      color: visual.background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 0),
        child: _ExpandedHealthContent(
          health: health,
          visual: visual,
          actionLabel: _actionLabel(health.action),
          onAction: onAction,
          diagnosticsBuilder: diagnosticsBuilder,
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
    final visual = _visualFor(health, colors);
    final waiting = health.outcome == SyncHealthOutcome.good
        ? 0
        : health.counts.pendingConfirmation;
    final key = Key(
      health.outcome == SyncHealthOutcome.good
          ? 'sync-health-good'
          : 'sync-health-pending',
    );
    void open() => _showSyncDetails(
      context,
      health: health,
      diagnosticsBuilder: diagnosticsBuilder,
    );
    // One announced button: the state, unresolved work and age, without the
    // badge digit or tooltip as separate fragments.
    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      label: '${_semanticsLabel(health)} Open synchronization details.',
      onTap: open,
      child: Tooltip(
        message: 'Sync details',
        child: iconOnly
            ? IconButton(
                key: key,
                tooltip: 'Sync details',
                onPressed: open,
                // The count keeps unconfirmed work visible without a banner.
                icon: Badge(
                  isLabelVisible: waiting > 0,
                  backgroundColor: colors.tertiary,
                  textColor: colors.onTertiary,
                  label: Text('$waiting'),
                  child: Icon(visual.icon, color: visual.foreground),
                ),
              )
            : TextButton.icon(
                key: key,
                onPressed: open,
                icon: Icon(visual.icon, color: visual.foreground, size: 20),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      health.compactLabel,
                      style: TextStyle(
                        color: visual.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      health.compactDetail,
                      style: TextStyle(color: visual.foreground),
                    ),
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
  final _Visual visual;
  final String? actionLabel;
  final ValueChanged<SyncHealthAction>? onAction;
  final WidgetBuilder? diagnosticsBuilder;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18.2;
    final textTheme = Theme.of(context).textTheme;
    final bodyStyle = textTheme.bodySmall?.copyWith(color: visual.foreground);
    final explanation = <String>[
      ?health.localWorkLabel,
      if (health.guidance.isNotEmpty) health.guidance,
    ].join(' ');
    final relative = health.lastSuccessRelativeLabel;
    final controls = <Widget>[
      if (actionLabel case final label?)
        OutlinedButton(
          key: const Key('sync-health-action'),
          onPressed: onAction == null ? null : () => onAction!(health.action),
          style: OutlinedButton.styleFrom(
            foregroundColor: visual.foreground,
            side: BorderSide(color: visual.foreground),
          ),
          child: Text(label),
        ),
      IconButton(
        key: const Key('sync-health-details'),
        tooltip: 'Sync details',
        color: visual.foreground,
        onPressed: () => _showSyncDetails(
          context,
          health: health,
          diagnosticsBuilder: diagnosticsBuilder,
        ),
        icon: const Icon(Icons.info_outline),
      ),
    ];
    final headline = Semantics(
      container: true,
      excludeSemantics: true,
      label: _semanticsLabel(health),
      child: Row(
        children: <Widget>[
          Icon(visual.icon, color: visual.foreground, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              // One flowing line: the outcome word, then its reason.
              child: Text.rich(
                key: const Key('sync-health-headline'),
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(
                      text: health.summary,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const TextSpan(text: ' · '),
                    TextSpan(text: health.reasonLabel),
                  ],
                ),
                maxLines: largeText ? 4 : 3,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall?.copyWith(
                  color: visual.foreground,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    // The explanation and age are visible text for sighted users; the
    // headline's label already announces them, so they are excluded here.
    final explanationText = explanation.isEmpty
        ? null
        : ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(left: 32, right: 12),
              child: Text(
                explanation,
                key: const Key('sync-health-explanation'),
                // Full text stays in the label and in Sync details.
                maxLines: largeText ? 2 : 3,
                overflow: TextOverflow.ellipsis,
                style: bodyStyle,
              ),
            ),
          );
    final lastSyncText =
        '${largeText ? 'Last sync' : 'Last successful sync'}: '
        '${relative ?? health.lastSuccessExactLabel}';
    final lastSync = ExcludeSemantics(
      child: Text(
        // Large text keeps the age on one line with a shorter lead.
        lastSyncText,
        key: const Key('sync-health-last-success'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: bodyStyle,
      ),
    );
    final stackedAge = Padding(
      padding: const EdgeInsets.only(left: 32, top: 2, right: 12),
      child: lastSync,
    );
    final stackedControls = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: controls,
    );
    final beside = Row(
      children: <Widget>[
        const SizedBox(width: 32),
        Expanded(child: lastSync),
        const SizedBox(width: 8),
        ...controls,
      ],
    );

    // The age shares the control row only where it stays whole beside a
    // long action such as Reauthorize; otherwise it gets its own line.
    bool fitsBeside(double width) {
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      var controlsWidth = kMinInteractiveDimension;
      if (actionLabel case final label?) {
        final button = TextPainter(
          text: TextSpan(text: label, style: textTheme.labelLarge),
          textDirection: direction,
          textScaler: scaler,
        )..layout();
        // Outlined button padding, border and a margin for rounding.
        controlsWidth += button.width + 56;
        button.dispose();
      }
      final remaining = width - 40 - controlsWidth;
      if (remaining <= 0) return false;
      final age = TextPainter(
        text: TextSpan(text: lastSyncText, style: bodyStyle),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 2,
      )..layout(maxWidth: remaining);
      final fits = !age.didExceedMaxLines;
      age.dispose();
      return fits;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = MediaQuery.sizeOf(context);
        final shortPhone =
            !largeText && screen.width < 360 && screen.height < 800;
        // Wide layouts keep the controls beside the text in one band.
        if (!largeText && constraints.maxWidth >= 600) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      headline,
                      ?explanationText,
                      // Wide layouts have room for the exact time too.
                      Padding(
                        padding: const EdgeInsets.only(left: 32),
                        child: ExcludeSemantics(
                          child: Text(
                            'Last successful sync: ${health.lastSuccessLabel}',
                            key: const Key('sync-health-last-success'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: bodyStyle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ...controls,
              ],
            ),
          );
        }
        if (!largeText && !shortPhone && fitsBeside(constraints.maxWidth)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[headline, ?explanationText, beside],
          );
        }
        // Short phones keep normal-size feedback within a fifth of the
        // screen. Text scrolls without truncation while controls stay in view.
        // Large text retains the larger reading area.
        final cap = shortPhone
            ? screen.height * 0.2
            : math.max(160, screen.height * 0.4);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: cap - 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Flexible(
                child: SingleChildScrollView(
                  // A new state starts at its headline, not at an earlier
                  // state's scroll offset.
                  key: ValueKey<String>(
                    'sync-health-text ${health.summary} ${health.reasonLabel}',
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[headline, ?explanationText, stackedAge],
                  ),
                ),
              ),
              stackedControls,
            ],
          ),
        );
      },
    );
  }
}

Future<void> _showSyncDetails(
  BuildContext context, {
  required SyncHealth health,
  WidgetBuilder? diagnosticsBuilder,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Synchronization details'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('${health.summary}: ${health.reasonLabel}'),
          if (health.localWorkLabel case final work?) Text(work),
          if (health.guidance.isNotEmpty) Text(health.guidance),
          if (!health.isCauseKnown)
            const Text(
              'Axiotask could not identify the cause. Diagnostics list the '
              'events around this failure.',
            ),
          if (health.outcome == SyncHealthOutcome.failed &&
              health.diagnosticCode != null)
            Text('Reference: ${health.diagnosticCode}'),
          const SizedBox(height: 12),
          const Text('Last successful sync'),
          Text(health.lastSuccessExactLabel),
          if (health.lastSuccessRelativeLabel case final relative?)
            Text(relative),
          const SizedBox(height: 12),
          Text(_countsLabel(health.counts)),
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

String _semanticsLabel(SyncHealth health) => <String>[
  'Synchronization ${health.summary}. ${health.reasonLabel}.',
  health.localWorkLabel ?? 'No unresolved changes.',
  if (health.guidance.isNotEmpty) health.guidance,
  'Last successful sync ${health.lastSuccessLabel}.',
].join(' ');

String _countsLabel(SyncWorkCounts counts) {
  if (counts.total == 0) return 'No unresolved changes';
  return 'Unresolved changes: ${counts.pending} waiting to send, '
      '${counts.inFlight} sending, ${counts.uncertain} awaiting confirmation, '
      '${counts.failed} failed';
}

typedef _Visual = ({Color background, Color foreground, IconData icon});

_Visual _visualFor(SyncHealth health, ColorScheme colors) =>
    switch (health.outcome) {
      SyncHealthOutcome.inactive => (
        background: colors.surfaceContainerHighest,
        foreground: colors.onSurfaceVariant,
        icon: health.inactiveReason == SyncInactiveReason.noAuthorization
            ? Icons.no_accounts_outlined
            : Icons.pause_circle_outline,
      ),
      SyncHealthOutcome.pending when health.usesCompactStatus => (
        background: colors.surface,
        foreground: colors.tertiary,
        // Unconfirmed local work shows as an upload, verification as sync.
        icon: health.counts.pendingConfirmation > 0
            ? Icons.cloud_upload_outlined
            : Icons.sync,
      ),
      SyncHealthOutcome.pending => (
        background: colors.tertiaryContainer,
        foreground: colors.onTertiaryContainer,
        icon: Icons.sync,
      ),
      SyncHealthOutcome.failed => (
        background: colors.errorContainer,
        foreground: colors.onErrorContainer,
        icon: switch (health.failureReason) {
          SyncFailureReason.noConnection => Icons.cloud_off_outlined,
          SyncFailureReason.stale => Icons.history,
          _ => Icons.sync_problem,
        },
      ),
      SyncHealthOutcome.good => (
        background: colors.brightness == Brightness.dark
            ? const Color(0xff153f28)
            : const Color(0xffd9f3e3),
        foreground: colors.brightness == Brightness.dark
            ? const Color(0xffd9f3e3)
            : const Color(0xff153f28),
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
