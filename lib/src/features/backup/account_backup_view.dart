import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/clock.dart';
import '../../data/backup/local_account_backup_exporter.dart';
import '../../domain/backup/account_backup.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/account_backup_repository.dart';
import '../../sync/health/sync_health_repository.dart';
import 'account_backup_view_model.dart';

final class AccountBackupHost extends StatefulWidget {
  const AccountBackupHost({
    required this.accountId,
    required this.repository,
    required this.exporter,
    required this.clock,
    this.restoreRepository,
    this.importer,
    this.syncHealthRepository,
    this.importCommitted,
    super.key,
  });

  final AccountId accountId;
  final AccountBackupRepository repository;
  final AccountBackupExporter exporter;
  final Clock clock;
  final AccountBackupRestoreRepository? restoreRepository;
  final AccountBackupImporter? importer;
  final SyncHealthRepository? syncHealthRepository;
  final Future<void> Function()? importCommitted;

  @override
  State<AccountBackupHost> createState() => _AccountBackupHostState();
}

final class _AccountBackupHostState extends State<AccountBackupHost> {
  late final AccountBackupViewModel _viewModel = AccountBackupViewModel(
    accountId: widget.accountId,
    repository: widget.repository,
    exporter: widget.exporter,
    clock: widget.clock,
    restoreRepository: widget.restoreRepository,
    importer: widget.importer,
    syncHealthRepository: widget.syncHealthRepository,
    importCommitted: widget.importCommitted,
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AccountBackupView(viewModel: _viewModel);
}

final class AccountBackupView extends StatefulWidget {
  const AccountBackupView({
    required this.viewModel,
    this.scrollController,
    super.key,
  });

  final AccountBackupViewModel viewModel;
  final ScrollController? scrollController;

  @override
  State<AccountBackupView> createState() => _AccountBackupViewState();
}

final class _AccountBackupViewState extends State<AccountBackupView> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant AccountBackupView oldWidget) {
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

  Future<void> _confirmExport() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export private task data?'),
        content: const Text(
          '$accountBackupPrivateDataWarning\n\n'
          'The backup includes the selected account’s supported projected '
          'lists and tasks, including edits still waiting for Google.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Export backup'),
          ),
        ],
      ),
    );
    if (confirmed == true) unawaited(widget.viewModel.export());
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.viewModel.state;
    return Scaffold(
      appBar: AppBar(title: const Text('Account backup')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.all(24),
              children: <Widget>[
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          Icons.privacy_tip_outlined,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            accountBackupPrivateDataWarning,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Selected account',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const ListTile(
                  leading: Icon(Icons.account_circle_outlined),
                  title: Text('Current Google account'),
                  subtitle: Text(
                    'Only this account’s supported projected lists and tasks '
                    'will be exported.',
                  ),
                ),
                const Divider(height: 32),
                Text(
                  'Backup contents',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const ListTile(
                  leading: Icon(Icons.data_object),
                  title: Text('Version 1 JSON'),
                  subtitle: Text(
                    'Includes list/task relationships, manual order, completion, '
                    'notes, due dates, Google identity when available, and '
                    'acknowledged offline edits. Credentials, authorization, '
                    'sync history, diagnostics, and device preferences are excluded.',
                  ),
                ),
                if (state.isWorking) ...<Widget>[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                if (state.notice case final notice?) ...<Widget>[
                  const SizedBox(height: 16),
                  _ResultCard(icon: Icons.info_outline, title: notice),
                ],
                if (state.error case final error?) ...<Widget>[
                  const SizedBox(height: 16),
                  _ResultCard(
                    icon: Icons.error_outline,
                    title: error,
                    isError: true,
                  ),
                ],
                if (state.result case final result?) ...<Widget>[
                  const SizedBox(height: 16),
                  _ResultCard(
                    icon: Icons.check_circle_outline,
                    title: 'Backup exported',
                    detail:
                        '${result.fileName}\n${result.listCount} '
                        '${result.listCount == 1 ? 'list' : 'lists'} and '
                        '${result.taskCount} '
                        '${result.taskCount == 1 ? 'task' : 'tasks'} exported.',
                  ),
                ],
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: state.isWorking ? null : _confirmExport,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Choose file and export'),
                  ),
                ),
                if (widget.viewModel.restoreRepository != null) ...<Widget>[
                  const Divider(height: 48),
                  Text(
                    'Restore from backup',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'A fresh successful sync is required. Existing Google identities '
                    'are never overwritten or deleted. Content is never used to find '
                    'duplicates.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: state.isWorking
                        ? null
                        : widget.viewModel.chooseImport,
                    icon: const Icon(Icons.upload_file_outlined),
                    label: const Text('Choose backup to restore'),
                  ),
                ],
                if (state.importPreview case final preview?) ...<Widget>[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            preview.alreadyImported
                                ? 'Backup already accepted'
                                : 'Restore preview',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${state.importFileName}\n'
                            '${_previewCounts(preview)}',
                          ),
                          const SizedBox(height: 12),
                          Text(
                            preview.sourceAccountMatches
                                ? 'The source account matches this target account.'
                                : 'The source account differs. Remote IDs cannot prevent '
                                      'cross-account duplicates.',
                            style: TextStyle(
                              color: preview.sourceAccountMatches
                                  ? null
                                  : Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Deleting local import history or importing into another '
                            'account can create duplicates. Google publication may '
                            'complete partially and will remain visible as pending or failed.',
                          ),
                          if (!preview.alreadyImported) ...<Widget>[
                            const SizedBox(height: 16),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton(
                                onPressed: state.isWorking
                                    ? null
                                    : widget.viewModel.restore,
                                child: const Text('Restore absent records'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                if (state.importResult case final result?) ...<Widget>[
                  const SizedBox(height: 16),
                  _ResultCard(
                    icon: Icons.restore,
                    title: result.alreadyImported
                        ? 'Backup was already restored'
                        : 'Restore accepted locally',
                    detail:
                        '${_count(result.createdListCount, 'list')} and '
                        '${_count(result.createdTaskCount, 'task')} recreated; '
                        '${_count(result.existingListCount, 'existing list')} and '
                        '${_count(result.existingTaskCount, 'existing task')} unchanged. '
                        'Synchronization will publish the new records to Google.',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _count(int value, String singular) =>
    '$value ${value == 1 ? singular : '${singular}s'}';

String _previewCounts(AccountBackupImportPreview preview) =>
    preview.alreadyImported
    ? '${_count(preview.listsToCreate, 'list')} and '
          '${_count(preview.tasksToCreate, 'task')} were recreated by the earlier restore. '
          '${_count(preview.existingListCount, 'list')} and '
          '${_count(preview.existingTaskCount, 'task')} remained unchanged.'
    : '${_count(preview.listsToCreate, 'list')} and '
          '${_count(preview.tasksToCreate, 'task')} will be recreated. '
          '${_count(preview.existingListCount, 'list')} and '
          '${_count(preview.existingTaskCount, 'task')} already exist and '
          'will remain unchanged.';

final class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.icon,
    required this.title,
    this.detail,
    this.isError = false,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: isError ? colors.errorContainer : colors.secondaryContainer,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: detail == null ? null : Text(detail!),
      ),
    );
  }
}
