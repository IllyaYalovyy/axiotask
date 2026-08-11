// The per-row ACTION SURFACE (MIGRATION-PLAN §4). A single action list — Edit
// title, Edit notes, Set due date, Move to list, Detach/Make-subtask-of,
// Duplicate, Details, Open in Google Tasks, Delete — reachable two ways so no
// pointer class is stranded:
//
//   • desktop right-click → [showTaskContextMenu]: a small menu positioned at
//     the cursor, clamped to the viewport, dismissed by tapping outside;
//   • touch (and any pointer) → [showTaskActionSheet]: a modal bottom sheet
//     carrying the SAME actions, the coarse-pointer path (no hover, no
//     right-click).
//
// Submenus (Set due date, Move to list) expand INLINE on tap — click-not-hover
// (ported from ContextMenu.svelte's click-to-open rule), which also makes them
// work under touch. The keyboard-navigation sub-suite dies with the keyboard
// layer; the ACTIONS all port.

import 'dart:async';

import 'package:flutter/material.dart';

import '../model/dates.dart' show DateMove;
import '../store/stored.dart';

/// One entry in the task action surface. A [TaskMenuItem] is a leaf action; a
/// [TaskMenuSubmenu] expands inline into its child items; a [TaskMenuDivider]
/// groups the list.
sealed class TaskMenuEntry {
  const TaskMenuEntry();
}

/// A visual separator between action groups.
class TaskMenuDivider extends TaskMenuEntry {
  const TaskMenuDivider();
}

/// A leaf action: [onInvoke] runs after the surface closes.
class TaskMenuItem extends TaskMenuEntry {
  const TaskMenuItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.onInvoke,
    this.danger = false,
  });

  /// A stable id used for the widget [Key] (`taskmenu-<id>`) so tests target it.
  final String id;
  final IconData icon;
  final String label;

  /// Styled as a destructive action (Delete).
  final bool danger;

  /// The action to run once the surface has dismissed.
  final FutureOr<void> Function() onInvoke;
}

/// A submenu that expands inline on tap into [items].
class TaskMenuSubmenu extends TaskMenuEntry {
  const TaskMenuSubmenu({
    required this.id,
    required this.icon,
    required this.label,
    required this.items,
  });

  final String id;
  final IconData icon;
  final String label;
  final List<TaskMenuItem> items;
}

/// Build the task action list for [task]. The visibility rules mirror
/// ContextMenu.svelte exactly: Detach only for a subtask, Make-subtask-of only
/// when [demotable], Open-in-Google only with a `webViewLink`, and NO
/// "Add subtask" (#91 — subtasks are added only in the detail panel). The Move
/// submenu lists every list (moving to the current one is a no-op).
List<TaskMenuEntry> buildTaskMenu({
  required StoredTask task,
  required List<StoredTaskList> lists,
  required bool demotable,
  required bool selected,
  required VoidCallback onToggleSelect,
  required VoidCallback onEditTitle,
  required VoidCallback onEditNotes,
  required void Function(DateMove move) onSetDue,
  required VoidCallback onPickDate,
  required void Function(String listId) onMoveToList,
  required VoidCallback onDetach,
  required VoidCallback onDemote,
  required VoidCallback onDuplicate,
  required VoidCallback onDetails,
  required VoidCallback onOpenGoogle,
  required VoidCallback onDelete,
}) {
  final isSubtask = task.task.parent != null;
  return [
    // A VISIBLE entry into multi-select (F18): the reference reached selection
    // only by Ctrl-click (invisible to a first-time user and impossible under
    // touch). This makes it discoverable and gives touch a menu route in
    // addition to the long-press. Reads "Deselect" for an already-selected row.
    TaskMenuItem(
      id: 'select',
      icon: selected ? Icons.check_box : Icons.check_box_outline_blank,
      label: selected ? 'Deselect' : 'Select',
      onInvoke: onToggleSelect,
    ),
    TaskMenuItem(
      id: 'edit',
      icon: Icons.edit_outlined,
      label: 'Edit title',
      onInvoke: onEditTitle,
    ),
    TaskMenuItem(
      id: 'notes',
      icon: Icons.notes,
      label: 'Edit notes',
      onInvoke: onEditNotes,
    ),
    const TaskMenuDivider(),
    TaskMenuSubmenu(
      id: 'due',
      icon: Icons.event,
      label: 'Set due date',
      items: [
        TaskMenuItem(
          id: 'due-today',
          icon: Icons.today,
          label: 'Today',
          onInvoke: () => onSetDue(DateMove.today),
        ),
        TaskMenuItem(
          id: 'due-tomorrow',
          icon: Icons.wb_sunny_outlined,
          label: 'Tomorrow',
          onInvoke: () => onSetDue(DateMove.tomorrow),
        ),
        TaskMenuItem(
          id: 'due-week',
          icon: Icons.next_week_outlined,
          label: 'Next week',
          onInvoke: () => onSetDue(DateMove.nextWeek),
        ),
        TaskMenuItem(
          id: 'due-month',
          icon: Icons.calendar_month_outlined,
          label: 'Next month',
          onInvoke: () => onSetDue(DateMove.nextMonth),
        ),
        TaskMenuItem(
          id: 'due-pick',
          icon: Icons.calendar_today_outlined,
          label: 'Pick a date…',
          onInvoke: onPickDate,
        ),
        TaskMenuItem(
          id: 'due-clear',
          icon: Icons.event_busy_outlined,
          label: 'Clear',
          onInvoke: () => onSetDue(DateMove.clear),
        ),
      ],
    ),
    TaskMenuSubmenu(
      id: 'move',
      icon: Icons.drive_file_move_outline,
      label: 'Move to list',
      items: [
        for (final l in lists)
          TaskMenuItem(
            id: 'move-${l.list.id}',
            icon: Icons.list_alt,
            label: l.list.title,
            onInvoke: () => onMoveToList(l.list.id),
          ),
      ],
    ),
    const TaskMenuDivider(),
    if (isSubtask)
      TaskMenuItem(
        id: 'detach',
        icon: Icons.subdirectory_arrow_left,
        label: 'Detach subtask',
        onInvoke: onDetach,
      ),
    if (demotable)
      TaskMenuItem(
        id: 'demote',
        icon: Icons.subdirectory_arrow_right,
        label: 'Make subtask of…',
        onInvoke: onDemote,
      ),
    TaskMenuItem(
      id: 'duplicate',
      icon: Icons.copy_all_outlined,
      label: 'Duplicate',
      onInvoke: onDuplicate,
    ),
    TaskMenuItem(
      id: 'details',
      icon: Icons.info_outline,
      label: 'Details',
      onInvoke: onDetails,
    ),
    if ((task.task.webViewLink ?? '').isNotEmpty)
      TaskMenuItem(
        id: 'open-google',
        icon: Icons.open_in_new,
        label: 'Open in Google Tasks',
        onInvoke: onOpenGoogle,
      ),
    const TaskMenuDivider(),
    TaskMenuItem(
      id: 'delete',
      icon: Icons.delete_outline,
      label: 'Delete',
      danger: true,
      onInvoke: onDelete,
    ),
  ];
}

/// The shared, self-closing action list rendered by both presenters. Submenus
/// expand inline on tap (never on hover); activating a leaf pops [onClose] and
/// runs its action next frame (so the surface is gone before the action, which
/// may itself open another surface).
class TaskActionMenu extends StatefulWidget {
  const TaskActionMenu({
    required this.entries,
    required this.onClose,
    super.key,
  });

  final List<TaskMenuEntry> entries;

  /// Dismiss the hosting surface (a Navigator.pop by the presenter).
  final VoidCallback onClose;

  @override
  State<TaskActionMenu> createState() => _TaskActionMenuState();
}

class _TaskActionMenuState extends State<TaskActionMenu> {
  // The one expanded submenu id, or null. Inline expansion is the click-not-
  // hover behavior; only one is open at a time.
  String? _expanded;

  void _activate(TaskMenuItem item) {
    widget.onClose();
    // Run after the surface has closed so an action that opens another surface
    // (Pick a date…, Move to list picker) does not fight the dismissal.
    WidgetsBinding.instance.addPostFrameCallback((_) => item.onInvoke());
  }

  Widget _leaf(TaskMenuItem item, {double indent = 0}) {
    final theme = Theme.of(context);
    final color = item.danger ? theme.colorScheme.error : null;
    return ListTile(
      key: Key('taskmenu-${item.id}'),
      dense: true,
      contentPadding: EdgeInsets.only(left: 16 + indent, right: 16),
      leading: Icon(item.icon, size: 20, color: color),
      title: Text(item.label, style: TextStyle(color: color)),
      onTap: () => _activate(item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final entry in widget.entries) {
      switch (entry) {
        case TaskMenuDivider():
          children.add(const Divider(height: 1));
        case TaskMenuItem():
          children.add(_leaf(entry));
        case TaskMenuSubmenu():
          final open = _expanded == entry.id;
          children.add(
            ListTile(
              key: Key('taskmenu-${entry.id}'),
              dense: true,
              leading: Icon(entry.icon, size: 20),
              title: Text(entry.label),
              trailing: Icon(open ? Icons.expand_less : Icons.chevron_right),
              // Click-not-hover: tap toggles the inline expansion.
              onTap: () => setState(() => _expanded = open ? null : entry.id),
            ),
          );
          if (open) {
            for (final item in entry.items) {
              children.add(_leaf(item, indent: 16));
            }
          }
      }
    }
    return SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// Show the desktop right-click context menu for a row at [globalPosition],
/// clamped to the viewport. Dismissed by tapping outside (the barrier).
Future<void> showTaskContextMenu(
  BuildContext context,
  Offset globalPosition,
  List<TaskMenuEntry> entries,
) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) {
      final size = MediaQuery.of(context).size;
      const menuWidth = 260.0;
      const menuMaxHeight = 460.0;
      // Clamp so the menu never spills off-screen (position clamped to viewport,
      // the ContextMenu.svelte contract).
      final left = globalPosition.dx.clamp(8.0, size.width - menuWidth - 8);
      final top = globalPosition.dy.clamp(8.0, size.height - 48);
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: menuWidth,
                maxHeight: menuMaxHeight,
              ),
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: TaskActionMenu(
                  entries: entries,
                  onClose: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Show the touch action sheet carrying every context action — the coarse-
/// pointer path (no hover, no right-click). A drag handle plus the shared
/// [TaskActionMenu].
Future<void> showTaskActionSheet(
  BuildContext context,
  List<TaskMenuEntry> entries,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: TaskActionMenu(
            entries: entries,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      );
    },
  );
}
