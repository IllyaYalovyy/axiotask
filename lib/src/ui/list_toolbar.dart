// The list pane's own toolbar (#274, split out of the orchestrator): the search
// and bulk-add buttons, the sort-order dropdown, the show-completed toggle,
// clear-completed, and the overflow carrying the coarse-pointer entry into
// multi-select.
//
// It renders only where the pane has to be its own top chrome — the expanded
// layout, which has no app bar. The compact shell hosts the SAME actions in its
// one app bar instead (#244), which is why every one of them is described by a
// value-equal [ListChromeActions] rather than by this widget's parameters.

import 'package:flutter/material.dart';

import 'compact_chrome.dart';
import 'sort_dropdown.dart';
import 'state_layer.dart';

/// The list toolbar: the search and bulk-add buttons, the sort-order dropdown,
/// the show-completed toggle, clear-completed, and the overflow menu carrying
/// the list-wide actions that have no room of their own.
///
/// Every one of them comes from the ONE [ListChromeActions] the pane publishes
/// (#274), so this toolbar and the compact shell's app bar can never offer a
/// different set — or a differently-gated one — for the same view.
class ListToolbar extends StatelessWidget {
  const ListToolbar(this.actions, {super.key});

  final ListChromeActions actions;

  @override
  Widget build(BuildContext context) {
    // A Wrap (not a Row) so a narrow list pane — a phone, or the desktop list
    // beside an open detail — flows the toggle onto a second line instead of
    // overflowing. On a wide pane spaceBetween keeps sort left, toggle right.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // A nested Wrap (not a Row) so a very narrow pane flows the sort
          // dropdown below the search button instead of overflowing — the same
          // reason the outer toolbar is a Wrap.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                key: const Key('search-button'),
                icon: const Icon(Icons.search),
                tooltip: 'Search tasks',
                onPressed: actions.onSearch,
              ),
              IconButton(
                key: const Key('bulk-add-button'),
                icon: const Icon(Icons.playlist_add),
                tooltip: 'Add multiple tasks',
                onPressed: actions.onBulkAdd,
              ),
              SortDropdown(value: actions.sort, onChanged: actions.onSort),
            ],
          ),
          // Right group: the clear-completed action (when offered) sits beside
          // the show-completed toggle. Wrapped so a narrow pane flows them.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (actions.onClearCompleted != null)
                TextButton.icon(
                  key: const Key('clear-completed-button'),
                  onPressed: actions.onClearCompleted,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear completed'),
                ),
              // The whole label toggles — a coarse pointer gets a full-size
              // target, not just the checkbox (touch has no hover).
              StateLayer(
                key: const Key('show-completed-toggle'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => actions.onShowCompleted(!actions.showCompleted),
                // A 48dp-tall hit area — the toolbar renders on a phone too, so the
                // whole toggle (not just the shrink-wrapped checkbox) is tappable.
                // SizedBox (not Container-with-alignment, which would fill the width).
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: actions.showCompleted,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: (v) => actions.onShowCompleted(v ?? false),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Show completed',
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (actions.onSelectTasks != null)
                PopupMenuButton<String>(
                  key: const Key('toolbar-overflow'),
                  tooltip: 'More list actions',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (_) => actions.onSelectTasks!(),
                  itemBuilder: (context) => [
                    PopupMenuItem<String>(
                      key: const Key('toolbar-select-tasks'),
                      value: 'select',
                      enabled: actions.selectTasksEnabled,
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_box_outlined,
                            size: 20,
                            // PopupMenuItem greys the LABEL of a disabled entry
                            // (a DefaultTextStyle) but not an icon, which would
                            // leave a half-disabled row.
                            color: actions.selectTasksEnabled
                                ? null
                                : Theme.of(context).disabledColor,
                          ),
                          const SizedBox(width: 12),
                          // A Material menu caps its width; at a large text
                          // scale the label wraps rather than being clipped.
                          const Flexible(child: Text('Select tasks')),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}
