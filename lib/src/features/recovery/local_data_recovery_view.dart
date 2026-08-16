import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/recovery/local_data_recovery.dart';
import 'local_data_recovery_view_model.dart';

final class LocalDataRecoveryHost extends StatefulWidget {
  const LocalDataRecoveryHost({required this.viewModel, super.key});

  final LocalDataRecoveryViewModel viewModel;

  @override
  State<LocalDataRecoveryHost> createState() => _LocalDataRecoveryHostState();
}

final class _LocalDataRecoveryHostState extends State<LocalDataRecoveryHost> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.viewModel.loadPreview());
  }

  @override
  void dispose() {
    widget.viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      LocalDataRecoveryView(viewModel: widget.viewModel);
}

final class LocalDataRecoveryView extends StatefulWidget {
  const LocalDataRecoveryView({required this.viewModel, super.key});

  final LocalDataRecoveryViewModel viewModel;

  @override
  State<LocalDataRecoveryView> createState() => _LocalDataRecoveryViewState();
}

final class _LocalDataRecoveryViewState extends State<LocalDataRecoveryView> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant LocalDataRecoveryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel == widget.viewModel) return;
    oldWidget.viewModel.removeListener(_changed);
    widget.viewModel.addListener(_changed);
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _confirm(LocalDataResetPreview preview) async {
    final confirmed = await showLocalDataResetConfirmation(context, preview);
    if (confirmed == true) {
      unawaited(widget.viewModel.resetConfirmed(preview));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.viewModel.state;
    final preview = state.preview;
    final colorScheme = Theme.of(context).colorScheme;
    final contentColor = colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(title: const Text('Local data recovery')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: <Widget>[
                Text(
                  'Recovery controls',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Refresh and Retry Open are non-destructive. Reset Local Data '
                  'is a separate destructive action for the current Google account.',
                  style: TextStyle(color: contentColor),
                ),
                const SizedBox(height: 20),
                if (state.isWorking) const LinearProgressIndicator(),
                if (preview != null) ...<Widget>[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Selected account preview',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _counts(preview),
                            style: TextStyle(color: contentColor),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Authorization and theme, density, and onboarding '
                            'preferences will remain. Google Tasks data is not '
                            'deleted by this local action.',
                            style: TextStyle(color: contentColor),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: state.isWorking ? null : () => _confirm(preview),
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: colorScheme.onPrimary,
                    ),
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('Reset Local Data'),
                  ),
                ],
                if (state.outcome case final outcome?) ...<Widget>[
                  const SizedBox(height: 20),
                  _OutcomeCard(outcome: outcome),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool?> showLocalDataResetConfirmation(
  BuildContext context,
  LocalDataResetPreview preview,
) => showDialog<bool>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Reset local data?'),
    content: Text(
      'This permanently discards the selected account’s cached data, '
      'pending and uncertain changes, Undo records, sync history, '
      'account-scoped preferences, and import history.\n\n'
      '${_counts(preview)}\n\n'
      'A change already sent to Google cannot be recalled. Authorization '
      'and device-only preferences are preserved. Axiotask will rebuild '
      'from Google, and sync will remain non-green until that succeeds.',
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(dialogContext).pop(true),
        child: const Text('Reset and rebuild'),
      ),
    ],
  ),
);

String _counts(LocalDataResetPreview preview) =>
    '${preview.cachedListCount} cached lists, ${preview.cachedTaskCount} cached tasks\n'
    '${preview.pendingChangeCount} pending changes, '
    '${preview.uncertainChangeCount} uncertain changes\n'
    '${preview.undoRecordCount} Undo records, '
    '${preview.accountPreferenceCount} account preferences\n'
    '${preview.syncHistoryCount} sync records, '
    '${preview.importManifestCount} import records';

final class _OutcomeCard extends StatelessWidget {
  const _OutcomeCard({required this.outcome});

  final LocalDataRecoveryOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final (icon, title, detail, failed) = switch (outcome) {
      LocalDataRecoveryOutcome.rebuilt => (
        Icons.cloud_done_outlined,
        'Rebuilt from Google',
        'The selected local account cache was rebuilt and synchronization is healthy.',
        false,
      ),
      LocalDataRecoveryOutcome.rebuildFailed => (
        Icons.cloud_off_outlined,
        'Local data reset; rebuild unavailable',
        'The selected cache is empty and sync is not healthy. Authorization is '
            'preserved. Use Retry or Refresh when Google is available.',
        true,
      ),
      LocalDataRecoveryOutcome.resetFailed => (
        Icons.error_outline,
        'Local data was not reset',
        'The reset transaction did not complete. Review the safe diagnostic and try again.',
        true,
      ),
    };
    final foreground = failed
        ? Theme.of(context).colorScheme.onErrorContainer
        : null;
    return Card(
      color: failed ? Theme.of(context).colorScheme.errorContainer : null,
      child: ListTile(
        leading: Icon(icon, color: foreground),
        title: Text(title, style: TextStyle(color: foreground)),
        subtitle: Text(detail, style: TextStyle(color: foreground)),
      ),
    );
  }
}
