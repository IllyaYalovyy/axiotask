import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/clock.dart';
import '../../data/backup/local_account_backup_exporter.dart';
import '../../domain/backup/account_backup.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/account_backup_repository.dart';
import 'account_backup_view_model.dart';

final class AccountBackupHost extends StatefulWidget {
  const AccountBackupHost({
    required this.accountId,
    required this.repository,
    required this.exporter,
    required this.clock,
    super.key,
  });

  final AccountId accountId;
  final AccountBackupRepository repository;
  final AccountBackupExporter exporter;
  final Clock clock;

  @override
  State<AccountBackupHost> createState() => _AccountBackupHostState();
}

final class _AccountBackupHostState extends State<AccountBackupHost> {
  late final AccountBackupViewModel _viewModel = AccountBackupViewModel(
    accountId: widget.accountId,
    repository: widget.repository,
    exporter: widget.exporter,
    clock: widget.clock,
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
  const AccountBackupView({required this.viewModel, super.key});

  final AccountBackupViewModel viewModel;

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
      appBar: AppBar(title: const Text('Export account backup')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
