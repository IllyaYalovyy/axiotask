import 'package:material_ui/material_ui.dart';

import '../../app/visual_tokens.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/sync_activity_repository.dart';

/// The per-run synchronization history: what triggered each run, when it
/// ran, how long it took and how it ended.
///
/// A failed run shows only its diagnostic code, a closed vocabulary, so no
/// request, account or task text can reach this screen.
final class SyncActivityPage extends StatelessWidget {
  const SyncActivityPage({
    required this.accountId,
    required this.repository,
    this.readOnlySync = false,
    super.key,
  });

  final AccountId accountId;
  final SyncActivityRepository repository;

  /// Shows that runs currently read Google Tasks without publishing.
  final bool readOnlySync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sync activity')),
      body: StreamBuilder<List<SyncRunRecord>>(
        stream: repository.watchRecentRuns(accountId),
        builder: (context, snapshot) {
          final runs = snapshot.data;
          return LayoutBuilder(
            builder: (context, constraints) => Center(
              child: SizedBox(
                width: constraints.maxWidth.clamp(0, 760).toDouble(),
                child: ListView(
                  key: const Key('sync-activity-list'),
                  padding: EdgeInsets.all(theme.axiotaskTokens.horizontalInset),
                  children: <Widget>[
                    Text('Recent runs', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text(
                      'Each synchronization with Google Tasks, newest first.',
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (readOnlySync) ...<Widget>[
                      const SizedBox(height: 12),
                      const ListTile(
                        key: Key('sync-activity-read-only'),
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.lock_outline),
                        title: Text('Read-only sync is on'),
                        subtitle: Text(
                          'Runs read Google Tasks; local changes are not '
                          'sent.',
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (snapshot.hasError)
                      Text(
                        'The sync history could not be read.',
                        key: const Key('sync-activity-error'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      )
                    else if (runs == null)
                      const Center(child: CircularProgressIndicator())
                    else if (runs.isEmpty)
                      const Text(
                        'No synchronization has run yet.',
                        key: Key('sync-activity-empty'),
                      )
                    else
                      for (final (index, run) in runs.indexed)
                        _RunTile(key: Key('sync-run-$index'), run: run),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

final class _RunTile extends StatelessWidget {
  const _RunTile({required this.run, super.key});

  final SyncRunRecord run;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, color, outcome) = switch (run.state) {
      SyncRunRecordState.succeeded => (
        Icons.check_circle_outline,
        colors.primary,
        'Succeeded',
      ),
      SyncRunRecordState.failed => (
        Icons.error_outline,
        colors.error,
        'Failed',
      ),
      SyncRunRecordState.interrupted => (
        Icons.pause_circle_outline,
        colors.onSurfaceVariant,
        'Interrupted',
      ),
      SyncRunRecordState.inProgress => (
        Icons.sync,
        colors.onSurfaceVariant,
        'Running',
      ),
    };
    final details = <String>[
      syncRunTriggerLabel(run.triggers),
      if (run.duration case final duration?) _durationLabel(duration),
      if (run.failureCode case final code?) 'Code $code',
    ];
    final started = _timeLabel(run.startedAt.toLocal());
    return Semantics(
      label: '$outcome, $started, ${details.join(', ')}',
      child: ExcludeSemantics(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: color),
          title: Text('$outcome · $started'),
          subtitle: Text(details.join(' · ')),
        ),
      ),
    );
  }
}

/// A readable name for what started a run.
String syncRunTriggerLabel(List<String> triggers) {
  if (triggers.isEmpty) return 'Sync';
  return triggers
      .map(
        (trigger) => switch (trigger) {
          'startup' => 'App start',
          'resume' => 'Returned to app',
          'connectivity_restored' => 'Connection restored',
          'refresh' || 'explicit' => 'Refresh',
          'resume_sync' => 'Sync resumed',
          'local_edit' => 'Local change',
          'delete_eligible' => 'Pending delete',
          'reauthorization' => 'Signed in',
          'retry' => 'Retry',
          'cadence' => 'Scheduled',
          'local_data_reset' => 'Local data rebuilt',
          _ => 'Sync',
        },
      )
      .toSet()
      .join(', ');
}

String _durationLabel(Duration duration) {
  if (duration.inSeconds < 1) return 'under 1 s';
  if (duration.inMinutes < 1) return '${duration.inSeconds} s';
  return '${duration.inMinutes} min ${duration.inSeconds % 60} s';
}

String _timeLabel(DateTime local) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
