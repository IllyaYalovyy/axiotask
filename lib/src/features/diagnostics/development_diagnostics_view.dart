import 'package:flutter/material.dart';

import '../../core/diagnostics/diagnostics.dart';
import 'diagnostics_view.dart';
import 'diagnostics_view_model.dart';
import 'system_diagnostic_clipboard.dart';

final class DevelopmentDiagnosticsHost extends StatefulWidget {
  const DevelopmentDiagnosticsHost({
    required this.history,
    required this.exporter,
    super.key,
  });

  final DiagnosticHistory history;
  final DiagnosticExportPort exporter;

  @override
  State<DevelopmentDiagnosticsHost> createState() =>
      _DevelopmentDiagnosticsHostState();
}

final class _DevelopmentDiagnosticsHostState
    extends State<DevelopmentDiagnosticsHost> {
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
      DevelopmentDiagnosticsView(viewModel: _viewModel);
}

final class DevelopmentDiagnosticsView extends StatelessWidget {
  const DevelopmentDiagnosticsView({required this.viewModel, super.key});

  final DiagnosticsViewModel viewModel;

  @override
  Widget build(BuildContext context) => DiagnosticsScaffold(
    title: 'Sensitive development diagnostics',
    description:
        'Search the complete allowed application, API, database, and sync '
        'context. Credentials remain redacted and nothing is uploaded.',
    warning: const MaterialBanner(
      leading: Icon(Icons.privacy_tip_outlined),
      content: Text(
        'Sensitive: this view and its exports contain private test-account '
        'data. Keep them local and clear them when investigation is complete.',
      ),
      actions: <Widget>[SizedBox.shrink()],
    ),
    viewModel: viewModel,
  );
}
