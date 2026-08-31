// The multi-select bulk bar (BulkOps). Shown while a selection exists; carries
// the whole-selection actions — Complete, "Due" (the ONE shared quick-date
// menu, #243), Move to a list, Delete — plus a clear-selection button. Each op
// is the caller's to perform against the selected ids; this widget only renders
// the toolbar and reports the count.
//
// The four hard-coded date buttons this replaced (Today / Tomorrow / Next week
// / Clear date) were a fourth vocabulary AND a subset — bulk could not reach
// "Next month" or a picked day at all. Behind one "Due" button the whole frozen
// set is available to a selection, exactly as it is to a single row.
//
// The `x`-key / Space / Ctrl+M keyboard triggers of the reference die with the
// keyboard layer; every action here is a tappable button, so touch and mouse
// reach them alike.

import 'package:flutter/material.dart';

import '../model/dates.dart' show DateMove;
import 'quick_date_menu.dart';

/// The bulk-actions toolbar for [count] selected tasks.
class BulkBar extends StatelessWidget {
  const BulkBar({
    required this.count,
    required this.onComplete,
    required this.onSetDue,
    required this.onPickDue,
    required this.onMove,
    required this.onDelete,
    required this.onClear,
    super.key,
  });

  /// How many tasks are selected (drives the "N selected" label).
  final int count;

  final VoidCallback onComplete;

  /// Apply a frozen move to every selected task.
  final void Function(DateMove move) onSetDue;

  /// Open the calendar ("Pick a date…") and apply the chosen day to every
  /// selected task.
  final VoidCallback onPickDue;

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
            QuickDateAnchor(
              onSetDue: onSetDue,
              onPickDate: onPickDue,
              sheetTitle: '$count selected · due date',
              builder: (context, open) => TextButton.icon(
                key: const Key('bulk-due'),
                icon: const Icon(Icons.event, size: 18),
                label: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Due'),
                    Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
                onPressed: open,
              ),
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
