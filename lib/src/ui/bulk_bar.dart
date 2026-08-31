// The multi-select bulk bar (BulkOps). Shown while selection MODE is active;
// carries the whole-selection actions — Complete, "Due" (the ONE shared
// quick-date menu, #243), Move to a list, Duplicate, "Make subtasks of…" and
// Delete — plus a clear-selection button. Each op is the caller's to perform
// against the selected ids; this widget only renders the toolbar and reports
// the count.
//
// Duplicate and "Make subtasks of…" landed here with #245, when the per-row "⋮"
// sheet — their only touch home — was retired. The bar can also be raised with
// NOTHING selected (the toolbar's "Select tasks"): it then names the mode and
// every whole-selection action is disabled, because a button that would do
// nothing is worse than no button.
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
    required this.onDuplicate,
    required this.onDemote,
    required this.onDelete,
    required this.onClear,
    super.key,
  });

  /// How many tasks are selected. Zero is legal — the mode was entered from the
  /// toolbar and no row has been tapped yet.
  final int count;

  final VoidCallback onComplete;

  /// Apply a frozen move to every selected task.
  final void Function(DateMove move) onSetDue;

  /// Open the calendar ("Pick a date…") and apply the chosen day to every
  /// selected task.
  final VoidCallback onPickDue;

  final VoidCallback onMove;

  /// Copy every selected task ("`<title>` (copy)", same list, same parent).
  final VoidCallback onDuplicate;

  /// Nest every selected task under ONE parent picked from the #88 picker.
  /// `null` HIDES the action — no single task can host the whole selection
  /// (one of them has subtasks of its own, or the selection spans lists), and
  /// the two-level invariant is not negotiable.
  final VoidCallback? onDemote;

  final VoidCallback onDelete;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Nothing selected yet: the actions are inert, so they READ inert — and
    // the destructive tint belongs to a LIVE Delete, never a disabled one.
    final armed = count > 0;
    final danger = armed ? theme.colorScheme.error : theme.disabledColor;
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
                armed ? '$count selected' : 'Select tasks',
                key: const Key('bulk-count'),
                style: theme.textTheme.labelLarge,
              ),
            ),
            TextButton.icon(
              key: const Key('bulk-complete'),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Complete'),
              onPressed: armed ? onComplete : null,
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
                onPressed: armed ? open : null,
              ),
            ),
            TextButton.icon(
              key: const Key('bulk-move'),
              icon: const Icon(Icons.drive_file_move_outline, size: 18),
              label: const Text('Move'),
              onPressed: armed ? onMove : null,
            ),
            TextButton.icon(
              key: const Key('bulk-duplicate'),
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Duplicate'),
              onPressed: armed ? onDuplicate : null,
            ),
            if (onDemote != null)
              TextButton.icon(
                key: const Key('bulk-demote'),
                icon: const Icon(Icons.subdirectory_arrow_right, size: 18),
                label: const Text('Make subtasks of…'),
                onPressed: armed ? onDemote : null,
              ),
            TextButton.icon(
              key: const Key('bulk-delete'),
              icon: Icon(Icons.delete_outline, size: 18, color: danger),
              label: Text('Delete', style: TextStyle(color: danger)),
              onPressed: armed ? onDelete : null,
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
