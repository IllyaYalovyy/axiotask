// The multi-select bulk bar (BulkOps). Shown while a selection exists; carries
// the whole-selection actions — Complete, quick reschedule (Today / Tomorrow /
// Next week / Clear date), Move to a list, Delete — plus a clear-selection
// button. Each op is the caller's to perform against the selected ids; this
// widget only renders the toolbar and reports the count.
//
// The `x`-key / Space / Ctrl+M keyboard triggers of the reference die with the
// keyboard layer; every action here is a tappable button, so touch and mouse
// reach them alike.

import 'package:flutter/material.dart';

import '../model/dates.dart' show DateMove;

/// The bulk-actions toolbar for [count] selected tasks.
class BulkBar extends StatelessWidget {
  const BulkBar({
    required this.count,
    required this.onComplete,
    required this.onSetDue,
    required this.onMove,
    required this.onDelete,
    required this.onClear,
    super.key,
  });

  /// How many tasks are selected (drives the "N selected" label).
  final int count;

  final VoidCallback onComplete;
  final void Function(DateMove move) onSetDue;
  final VoidCallback onMove;
  final VoidCallback onDelete;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        // A Wrap so a narrow pane flows the buttons instead of overflowing.
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '$count selected',
                key: const Key('bulk-count'),
                style: theme.textTheme.labelLarge,
              ),
            ),
            TextButton.icon(
              key: const Key('bulk-complete'),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Complete'),
              onPressed: onComplete,
            ),
            TextButton(
              key: const Key('bulk-today'),
              onPressed: () => onSetDue(DateMove.today),
              child: const Text('Today'),
            ),
            TextButton(
              key: const Key('bulk-tomorrow'),
              onPressed: () => onSetDue(DateMove.tomorrow),
              child: const Text('Tomorrow'),
            ),
            TextButton(
              key: const Key('bulk-week'),
              onPressed: () => onSetDue(DateMove.nextWeek),
              child: const Text('Next week'),
            ),
            TextButton(
              key: const Key('bulk-clear-date'),
              onPressed: () => onSetDue(DateMove.clear),
              child: const Text('Clear date'),
            ),
            TextButton.icon(
              key: const Key('bulk-move'),
              icon: const Icon(Icons.drive_file_move_outline, size: 18),
              label: const Text('Move'),
              onPressed: onMove,
            ),
            TextButton.icon(
              key: const Key('bulk-delete'),
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: theme.colorScheme.error,
              ),
              label: Text(
                'Delete',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onPressed: onDelete,
            ),
            IconButton(
              key: const Key('bulk-clear-selection'),
              tooltip: 'Clear selection',
              icon: const Icon(Icons.close),
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}
