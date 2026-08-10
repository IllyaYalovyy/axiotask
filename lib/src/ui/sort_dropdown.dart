// The sort-order dropdown — the port of `SortDropdown.svelte`. Shows the current
// order as "Sort: <label>" and opens a menu of the four [SortMode]s. Purely
// presentational: it takes the current value and reports the picked one, so it
// is widget-tested without any store.

import 'package:flutter/material.dart';

import '../model/task_view.dart';

/// A compact dropdown that selects a [SortMode] for the current view.
class SortDropdown extends StatelessWidget {
  const SortDropdown({required this.value, required this.onChanged, super.key});

  /// The currently active sort order.
  final SortMode value;

  /// Called with the newly picked order.
  final ValueChanged<SortMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<SortMode>(
      key: const Key('sort-dropdown'),
      tooltip: 'Sort order',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final m in SortMode.values)
          PopupMenuItem(value: m, child: Text(m.label)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort, size: 18),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Sort: ${value.label}',
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.labelLarge,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}
