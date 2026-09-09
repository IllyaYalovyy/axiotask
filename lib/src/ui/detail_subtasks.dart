// The detail panel's SUBTASK SECTION (#274, split out of task_detail.dart): the
// section header with its progress summary, the checklist itself, the completed
// group, and the "add a subtask" field.
//
// Subtasks are STRICTLY ONE LEVEL (invariant #1) and live ONLY here — they are
// never rendered as list rows, and nothing in this file nests or indents.
//
// #306 rebuilt this section around the LIST ROW. A subtask used to be its own
// species — a checkbox, a title, two arrow buttons and a date label — so a
// subtask with notes showed no notes badge, an unpushed edit showed no pending
// dot, a finger could not swipe it and a mouse got nothing on hover. It is now
// a [TaskRow] at [TaskRowDensity.subtask], fed the same [TaskRowData] and
// driven by the same [TaskRowActions] the list feeds its rows, so every one of
// those comes from the one implementation instead of a second one that has to
// grow them again.
//
// Three rules the section keeps:
//
//   • ONE progress format. The header shows the SAME [SubtaskProgress] the
//     parent's row shows in the list — same bar, same "N/M", same spoken "N of
//     M subtasks complete". There were three wordings for one number.
//   • Reorder is a DRAG, never a pair of arrow buttons (#90). The handle is
//     revealed on hover for a mouse and always present for a finger, and one
//     drop is one undoable move.
//   • Completed subtasks collapse under "N completed" at the bottom, one tap
//     from view. The persisted preference behind that group is a SETTING and
//     lives in Properties → Appearance — it is not a checkbox inside every
//     task's panel.

import 'package:flutter/material.dart';

import '../app/pending_edits.dart';
import '../model/task.dart' show TaskStatus;
import '../store/stored.dart';
import 'haptics.dart';
import 'motion.dart';
import 'row_actions.dart' show TaskRowActions;
import 'state_layer.dart';
import 'task_row.dart';
import 'task_row_parts.dart' show SubtaskProgress;
import 'theme.dart' show coarsePointerPlatform;
import 'visible_rows.dart' show TaskRowData;

/// The subtasks section header: the "Subtasks" label and the shared progress
/// indicator.
class SubtaskHeader extends StatelessWidget {
  const SubtaskHeader({
    super.key,
    required this.completedCount,
    required this.totalCount,
  });

  final int completedCount;

  /// EVERY subtask, including the completed ones the group collapses out of
  /// view — the summary states the task's real progress, not the visible slice
  /// (#220).
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text('Subtasks', style: theme.textTheme.titleSmall)),
        // The ONE progress format in the app (#306): the identical widget the
        // parent's row wears in the list, so the number the user read on the
        // row is the number they read here, written the same way and spoken
        // the same way.
        if (totalCount > 0)
          SubtaskProgress(
            key: const Key('subtask-progress'),
            done: completedCount,
            total: totalCount,
            theme: theme,
          ),
      ],
    );
  }
}

/// One subtask checklist row — a [TaskRow] at subtask density.
///
/// It takes the same [TaskRowData] the list derives for its rows and the same
/// [TaskRowActions] bundle, so the checkbox, the title tap, the notes/link
/// badges, the pending-sync dot, the quick-date segment, hover/press/focus and
/// the touch swipes are ONE implementation (#306). A subtask can have no
/// children and no list of its own, so the row's inherited-date, progress and
/// list-tag slots are simply empty for it.
class SubtaskRow extends StatelessWidget {
  const SubtaskRow({
    required this.data,
    required this.actions,
    this.haptics = const NoHaptics(),
    this.pendingEdits,
    super.key,
  });

  final TaskRowData data;
  final TaskRowActions actions;
  final Haptics haptics;

  /// The app-wide pending-edits registry (#183/G4). A desktop double-click
  /// opens the row's inline rename here exactly as it does in the list, so a
  /// mid-typing rename has to survive a backgrounding the same way. `null`
  /// skips registration (a row mounted outside the app, e.g. an isolated
  /// widget test).
  final PendingEdits? pendingEdits;

  @override
  Widget build(BuildContext context) {
    final stored = data.stored;
    final t = stored.task;
    return Builder(
      builder: (rowContext) => TaskRow(
        density: TaskRowDensity.subtask,
        title: t.title,
        notes: t.notes,
        completed: t.status == TaskStatus.completed,
        due: t.due,
        pendingSync: stored.syncState == SyncState.dirty,
        onOpen: () => actions.open(rowContext, stored),
        onToggle: () => actions.toggle(stored),
        onRename: (v) => actions.rename(t.id, v),
        onSetDue: (m) => actions.setDue(t.id, m),
        onPickDate: () => actions.pickDate(stored),
        onOpenUrl: actions.openUrl,
        pendingEdits: pendingEdits,
        haptics: haptics,
      ),
    );
  }
}

/// The "N completed" disclosure that closes the checklist.
///
/// It is a GROUP, not a preference control (#306): it says how many subtasks
/// are finished and folds them out of the way, so what is left to do reads as
/// one uninterrupted list and the finished ones stay one tap from view. The
/// state it flips is persisted (it is the same answer for every task), which is
/// why the setting itself is stated in Properties → Appearance.
class CompletedSubtasksGroup extends StatelessWidget {
  const CompletedSubtasksGroup({
    super.key,
    required this.count,
    required this.expanded,
    required this.onToggle,
    required this.onUncompleteAll,
  });

  final int count;
  final bool expanded;
  final ValueChanged<bool> onToggle;

  /// Reopen every completed subtask (#89) — offered inside the group it acts
  /// on, rather than in the header above the open ones.
  final VoidCallback onUncompleteAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = count == 1 ? '1 completed' : '$count completed';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ONE screen-reader stop for the whole disclosure (#288): the chevron
        // and the words beside it are the same control, and it announces its
        // own state rather than leaving the arrow glyph to imply it.
        Semantics(
          button: true,
          expanded: expanded,
          label: '$label ${count == 1 ? 'subtask' : 'subtasks'}',
          child: StateLayer(
            key: const Key('completed-subtasks-toggle'),
            onTap: () => onToggle(!expanded),
            borderRadius: BorderRadius.circular(8),
            // The visible label is written for the eye and repeated in the
            // node's own label above, so the words underneath stay silent —
            // otherwise the group announces its count twice (#289).
            child: ExcludeSemantics(
              // A full-width 48dp band (#167's rule: grow the HIT AREA, never
              // the glyph). This is the control that puts a finished checklist
              // back on screen, and at its natural 36dp it was the one target
              // in the panel a thumb could miss.
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                alignment: AlignmentDirectional.centerStart,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (expanded)
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

/// The drag handle that replaces the old up/down arrow pair (#90/#306).
///
/// Two arrow buttons cost 96dp of chrome on every single row and could only
/// step one slot at a time. The handle costs one column, moves a row anywhere
/// in one gesture, and is the SAME affordance the task list already uses — same
/// glyph, same 36×48 target, same lift under the finger.
///
/// On a mouse the glyph is revealed on hover: the panel is a reading surface,
/// and a column of grab handles standing at rest in a three-item checklist is
/// noise. The COLUMN is always there, at full width, so revealing it moves
/// nothing (#168 no-reflow). A finger has no hover, so touch always shows it.
class SubtaskDragHandle extends StatefulWidget {
  const SubtaskDragHandle({super.key, required this.index, required this.id});

  final int index;
  final String id;

  @override
  State<SubtaskDragHandle> createState() => _SubtaskDragHandleState();
}

class _SubtaskDragHandleState extends State<SubtaskDragHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coarse = coarsePointerPlatform(theme.platform);
    final glyph = SizedBox(
      key: ValueKey('subtask-drag-handle-${widget.id}'),
      // The list's handle geometry exactly: a comfortable target for a mouse
      // and a finger alike, with a small glyph inside it.
      width: 36,
      height: 48,
      child: AnimatedOpacity(
        opacity: coarse || _hovered ? 1 : 0,
        // Reduced motion keeps the reveal and drops the TRAVEL (#250): the
        // handle is simply there the instant the pointer arrives.
        duration: Motion.of(context).resolve(MotionDurations.short),
        child: Icon(
          Icons.drag_indicator,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: dragHandleCursor(
        child: ReorderableDragStartListener(index: widget.index, child: glyph),
      ),
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
    this.showHint = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  /// Whether to introduce the concept above the field (#306). A parent with no
  /// subtasks yet showed a bare input and nothing that said what it was for;
  /// the user called the subtask concept great, so it is worth one line saying
  /// it exists. Shown ONLY while the checklist is empty.
  final bool showHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHint)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Break this task into steps.',
                key: const Key('subtasks-empty-hint'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Row(
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
        ],
      ),
    );
  }
}
