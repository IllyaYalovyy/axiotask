// The detail panel's SUBTASK SECTION (#274, split out of task_detail.dart): the
// section header with its progress summary and count-gated actions, one subtask
// row, and the "add a subtask" field.
//
// Subtasks are STRICTLY ONE LEVEL (invariant #1) and live ONLY here — they are
// never rendered as list rows, and nothing in this file nests, indents or
// collapses. Like the field rows, these are pure presentation over values and
// callbacks the panel owns.

import 'package:flutter/material.dart';

import '../model/dates.dart' show DateMove;
import '../model/task.dart';
import 'date_format.dart';
import 'quick_date_menu.dart';
import 'state_layer.dart';
import 'theme.dart';

/// The subtasks section header: the "Subtasks" label, the "x of y complete"
/// summary, the count-gated "Hide completed" toggle, and the count-gated
/// "Un-complete all subtasks" action.
class SubtaskHeader extends StatelessWidget {
  const SubtaskHeader({
    super.key,
    required this.completedCount,
    required this.totalCount,
    required this.hideCompleted,
    required this.onHideCompleted,
    required this.onUncompleteAll,
  });

  final int completedCount;

  /// EVERY subtask, including the completed ones "Hide completed" removes from
  /// view — the summary states the task's real progress, not the visible slice
  /// (#220).
  final int totalCount;
  final bool hideCompleted;
  final ValueChanged<bool> onHideCompleted;
  final VoidCallback onUncompleteAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Subtasks', style: theme.textTheme.titleSmall),
            ),
            // The toggle only exists once something can be hidden — an
            // affordance that would do nothing must not render.
            if (completedCount > 0)
              // ONE screen-reader stop, not a node labelled "Hide completed"
              // wrapping a nameless "checkbox" node (#288): the box and the
              // words beside it are the same control, so they announce as one
              // — "Hide completed, not checked, checkbox".
              MergeSemantics(
                child: StateLayer(
                  onTap: () => onHideCompleted(!hideCompleted),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: hideCompleted,
                          onChanged: (v) => onHideCompleted(v ?? false),
                        ),
                        Text(
                          'Hide completed',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        // The bar on the task row shows the same progress as a shape; here the
        // number is spelled out so nothing has to be estimated (#220).
        if (totalCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              '$completedCount of $totalCount complete',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (completedCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onUncompleteAll,
              child: const Text('Un-complete all subtasks'),
            ),
          ),
      ],
    );
  }
}

/// One subtask checklist row: a real checkbox toggles completion, the title
/// opens the subtask's own panel, up/down buttons reorder it (hidden-aware,
/// disabled at the visible ends), and a due button edits its date inline.
class SubtaskRow extends StatelessWidget {
  const SubtaskRow({
    required this.task,
    required this.isFirst,
    required this.isLast,
    required this.onToggle,
    required this.onOpen,
    required this.onPickDue,
    required this.onSetDue,
    required this.onMoveUp,
    required this.onMoveDown,
    super.key,
  });

  final Task task;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  /// Open the calendar for this subtask ("Pick a date…").
  final VoidCallback onPickDue;

  /// Apply a frozen move to this subtask from the shared menu.
  final ValueChanged<DateMove> onSetDue;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = task.status == TaskStatus.completed;
    final hasDue = (task.due ?? '').isNotEmpty;
    // The title as the row SAYS it, shared by the visible line and the
    // checkbox's accessible name so the two can never diverge.
    final displayTitle = task.title.isEmpty ? 'Untitled' : task.title;
    return Row(
      children: [
        // 48dp hit area (the glyph stays default-sized — enlarge the target,
        // never the checkbox, #167).
        // The box is its own semantics node, so it NAMES the subtask it would
        // complete (#288) — otherwise every subtask's box announced the same
        // anonymous "not checked, checkbox".
        Semantics(
          label: displayTitle,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Checkbox(value: done, onChanged: (_) => onToggle()),
          ),
        ),
        Expanded(
          // The subtask's title is a tap surface of its own (it opens the
          // subtask), so it wears the same states as every other one (#259) —
          // it was a bare GestureDetector, silent on hover, press and focus.
          child: StateLayer(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              // The title is the flexible element of the row (it sits in the
              // Expanded above): a long subtask title ellipsizes on one line so
              // the fixed reorder arrows + due button never get pushed off the
              // edge and overflow a narrow detail pane (G9 #208).
              child: Text(
                displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  decoration: done ? TextDecoration.lineThrough : null,
                  color: done ? completedTitleColor(theme.colorScheme) : null,
                ),
              ),
            ),
          ),
        ),
        // Reorder buttons (the touch path; work with a mouse too). Disabled at
        // the visible boundaries.
        IconButton(
          key: Key('sub-up-${task.id}'),
          icon: const Icon(Icons.keyboard_arrow_up),
          iconSize: 20,
          tooltip: 'Move up',
          onPressed: onMoveUp,
        ),
        IconButton(
          key: Key('sub-down-${task.id}'),
          icon: const Icon(Icons.keyboard_arrow_down),
          iconSize: 20,
          tooltip: 'Move down',
          onPressed: onMoveDown,
        ),
        // The per-subtask due button. Its tooltip carries the precise ISO date
        // (stable for tests) while the visible label is the friendly form.
        //
        // It wears the shared urgency tone too (#242): it is a DATE on the same
        // panel as the parent's Due field, and leaving it on the button default
        // would paint every subtask date — overdue ones included — in the tone
        // that now means "due today".
        // The same quick-date set the parent's Due field raises (#243): a
        // subtask is dated the way everything else in the app is dated.
        QuickDateAnchor(
          onSetDue: onSetDue,
          onPickDate: onPickDue,
          sheetTitle: 'Subtask due date',
          builder: (context, open) => Tooltip(
            message:
                'Subtask due date: ${hasDue ? task.due!.substring(0, 10) : 'No date'}',
            child: TextButton(
              key: Key('sub-due-${task.id}'),
              onPressed: open,
              style: TextButton.styleFrom(
                foregroundColor: dueColor(
                  hasDue ? dueUrgency(task.due) : DueUrgency.none,
                  theme.colorScheme,
                ),
              ),
              child: Text(hasDue ? formatDue(task.due) : 'no date'),
            ),
          ),
        ),
      ],
    );
  }
}

/// The inline "Add a subtask" input — Enter or the + button creates the child
/// and the caller keeps focus for rapid entry.
class AddSubtaskField extends StatelessWidget {
  const AddSubtaskField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: const InputDecoration(
                hintText: 'Add a subtask',
                isDense: true,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add subtask',
            onPressed: onSubmit,
          ),
        ],
      ),
    );
  }
}
