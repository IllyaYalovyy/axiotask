import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../domain/export/view_export.dart';
import '../tasks_view_model.dart';

/// Opens the export surface for the collection the user is looking at: a
/// bottom sheet under the thumb on a phone, a centred dialog on a desktop.
///
/// The sheet shows what will leave the app before anything leaves it: the
/// task count, the chosen format and a preview of the document. Copy, Save
/// and Share are separate, visible ways out; nothing is written or sent until
/// one is chosen.
Future<void> showViewExportSheet(
  BuildContext context, {
  required TasksViewModel viewModel,
  required bool phone,
}) {
  if (phone) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ViewExportSheet(viewModel: viewModel),
    );
  }
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.only(top: 24),
          child: ViewExportSheet(viewModel: viewModel),
        ),
      ),
    ),
  );
}

final class ViewExportSheet extends StatefulWidget {
  const ViewExportSheet({required this.viewModel, super.key});

  final TasksViewModel viewModel;

  @override
  State<ViewExportSheet> createState() => _ViewExportSheetState();
}

final class _ViewExportSheetState extends State<ViewExportSheet> {
  var _format = ViewExportFormat.markdown;
  var _busy = false;

  Future<void> _deliver(
    Future<void> Function(ViewExportFormat format) operation,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation(_format);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // The outcome is reported by the collection's own feedback; the sheet
    // has nothing left to say.
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewModel = widget.viewModel;
    final document = viewModel.previewCurrentView(_format);
    final count = switch (document.taskCount) {
      0 => 'No tasks',
      1 => '1 task',
      final n => '$n tasks',
    };
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const Key('export-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Export ${document.title}',
              style: theme.textTheme.titleLarge,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              count,
              key: const Key('export-count'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<ViewExportFormat>(
              key: const Key('export-format'),
              segments: <ButtonSegment<ViewExportFormat>>[
                for (final format in ViewExportFormat.values)
                  ButtonSegment<ViewExportFormat>(
                    value: format,
                    label: Text(format.label),
                    icon: Icon(
                      format == ViewExportFormat.markdown
                          ? Icons.checklist
                          : Icons.table_chart_outlined,
                    ),
                  ),
              ],
              selected: <ViewExportFormat>{_format},
              onSelectionChanged: _busy
                  ? null
                  : (selection) => setState(() => _format = selection.first),
            ),
            const SizedBox(height: 12),
            Semantics(
              label: 'Export preview',
              container: true,
              child: Container(
                key: const Key('export-preview'),
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    document.text,
                    key: const Key('export-preview-text'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Wrap, not Row: at a large text scale the labels flow onto a
            // second line instead of overflowing.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                TextButton(
                  key: const Key('export-cancel'),
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  child: const Text('Cancel'),
                ),
                OutlinedButton.icon(
                  key: const Key('export-copy'),
                  onPressed: _busy
                      ? null
                      : () => _deliver(viewModel.copyCurrentView),
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy'),
                ),
                if (viewModel.viewExportDestination != null)
                  FilledButton.tonalIcon(
                    key: const Key('export-save'),
                    onPressed: _busy
                        ? null
                        : () => _deliver(viewModel.exportCurrentView),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Save…'),
                  ),
                if (viewModel.viewExportShare != null)
                  FilledButton.icon(
                    key: const Key('export-share'),
                    onPressed: _busy
                        ? null
                        : () => _deliver(viewModel.shareCurrentView),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share…'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
