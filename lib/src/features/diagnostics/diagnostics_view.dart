import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/diagnostics/diagnostics.dart';
import 'diagnostics_view_model.dart';
import 'system_diagnostic_clipboard.dart';

final class ReleaseDiagnosticsHost extends StatefulWidget {
  const ReleaseDiagnosticsHost({
    required this.history,
    required this.exporter,
    super.key,
  });

  final DiagnosticHistory history;
  final DiagnosticExportPort exporter;

  @override
  State<ReleaseDiagnosticsHost> createState() => _ReleaseDiagnosticsHostState();
}

final class _ReleaseDiagnosticsHostState extends State<ReleaseDiagnosticsHost> {
  late final DiagnosticsViewModel _viewModel = DiagnosticsViewModel(
    history: widget.history,
    clipboard: const SystemDiagnosticClipboard(),
    exporter: widget.exporter,
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ReleaseDiagnosticsView(viewModel: _viewModel);
}

final class ReleaseDiagnosticsView extends StatelessWidget {
  const ReleaseDiagnosticsView({required this.viewModel, super.key});

  final DiagnosticsViewModel viewModel;

  @override
  Widget build(BuildContext context) => DiagnosticsScaffold(
    title: 'Diagnostics',
    description:
        'Production-safe local history. It contains codes and summaries, '
        'not task content, account details, credentials, or full URLs.',
    viewModel: viewModel,
  );
}

final class DiagnosticsScaffold extends StatefulWidget {
  const DiagnosticsScaffold({
    required this.title,
    required this.description,
    required this.viewModel,
    this.warning,
    super.key,
  });

  final String title;
  final String description;
  final Widget? warning;
  final DiagnosticsViewModel viewModel;

  @override
  State<DiagnosticsScaffold> createState() => _DiagnosticsScaffoldState();
}

final class _DiagnosticsScaffoldState extends State<DiagnosticsScaffold> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant DiagnosticsScaffold oldWidget) {
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

  @override
  Widget build(BuildContext context) {
    final state = widget.viewModel.state;
    final visible = state.visibleRecords;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          IconButton(
            tooltip: 'Copy visible diagnostics',
            onPressed: state.isWorking
                ? null
                : () => unawaited(widget.viewModel.copyVisible()),
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            tooltip: 'Export visible diagnostics',
            onPressed: state.isWorking
                ? null
                : () => unawaited(widget.viewModel.exportVisible()),
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'Clear diagnostics',
            onPressed: state.isWorking
                ? null
                : () => unawaited(widget.viewModel.clear()),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ?widget.warning,
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(widget.description),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: TextField(
                key: const Key('diagnostics-search'),
                onChanged: widget.viewModel.setQuery,
                decoration: const InputDecoration(
                  labelText: 'Search diagnostics',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            if (state.isWorking) const LinearProgressIndicator(),
            if (state.loadError case final message?)
              _StatusBanner(message: message, isError: true)
            else if (state.error case final message?)
              _StatusBanner(message: message, isError: true)
            else if (state.notice case final message?)
              _StatusBanner(message: message, isError: false),
            Expanded(
              child: switch ((state.isEmpty, visible.isEmpty)) {
                (true, _) => const _EmptyDiagnostics(
                  message: 'No diagnostics recorded',
                ),
                (false, true) => const _EmptyDiagnostics(
                  message: 'No diagnostics match this search',
                ),
                _ => ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _DiagnosticRecordCard(record: visible[index]),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

final class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: isError ? colors.errorContainer : colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Text(
          message,
          style: TextStyle(
            color: isError
                ? colors.onErrorContainer
                : colors.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}

final class _EmptyDiagnostics extends StatelessWidget {
  const _EmptyDiagnostics({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          Icons.receipt_long_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text(message, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}

final class _DiagnosticRecordCard extends StatelessWidget {
  const _DiagnosticRecordCard({required this.record});

  final DiagnosticRecord record;

  @override
  Widget build(BuildContext context) => Semantics(
    label: record.renderedText,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(
                  record.code,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                Chip(label: Text(record.subsystem.name)),
                Chip(label: Text(record.kind.name)),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(record.renderedText),
          ],
        ),
      ),
    ),
  );
}
