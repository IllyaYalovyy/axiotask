// The DESKTOP right-click ACTION SURFACE (MIGRATION-PLAN §4). A single action
// list — Select, Edit title, Edit notes, Set due date, Move to list,
// Detach/Make-subtask-of, Duplicate, Details, Open in Google Tasks, Delete —
// shown by [showTaskContextMenu]: a small menu placed at the cursor so that the
// WHOLE menu is inside the window, dismissed by tapping outside.
//
// A coarse pointer has NO surface here (#245). The per-row "⋮" and its bottom
// sheet are gone: touch reaches every one of these functions where it already
// lives — the row tap (Details), the row's date segment and swipe-left (Set due
// date), a long-press or the toolbar's "Select tasks" (Select), the detail
// screen (Edit title/notes, Move to list, Detach, Duplicate, Make subtask of…,
// Open in Google, Delete) and the bulk bar (all of the whole-selection ops).
//
// Submenus (Set due date, Move to list) expand INLINE on tap — click-not-hover
// (ported from ContextMenu.svelte's click-to-open rule). The keyboard-navigation
// sub-suite dies with the keyboard layer; the ACTIONS all port.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/commands.dart';
import '../model/dates.dart' show DateMove;
import '../model/task_tree.dart' show canNestUnder;
import '../store/stored.dart';
import 'quick_date_menu.dart';

/// The ONE duplicate rule, shared by the desktop context menu, the detail
/// screen's overflow and the bulk bar (#245): a fresh task titled
/// "`<title>` (copy)" in the SAME list and under the SAME parent, so a
/// duplicated subtask stays a subtask and the two-level invariant holds.
///
/// [title] overrides the stored title for a copy taken while an editor still
/// holds an uncommitted rename.
Future<void> duplicateTask(
  Commands commands,
  StoredTask task, {
  String? title,
}) => commands.createTask(
  listId: task.listId,
  parentId: task.task.parent,
  title: '${title ?? task.task.title} (copy)',
);

/// The legal parents [task] may be demoted under (#88): every OTHER top-level
/// task in the SAME list — a candidate that already has subtasks is fine, a
/// candidate that IS one is not. [canNestUnder] is the single source of truth
/// for the two-level rule, and [all] must be the FULL task set (it is what says
/// whether [task] has subtasks of its own).
List<StoredTask> demoteCandidates(StoredTask task, List<StoredTask> all) {
  final tasks = all.map((t) => t.task);
  return all
      .where(
        (c) =>
            c.listId == task.listId &&
            canNestUnder(task.task.id, c.task, tasks),
      )
      .toList();
}

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
    // Generated from the ONE frozen option set (#243) — this submenu shares its
    // wording, order and icons with the row's date segment, the detail panel,
    // the bulk bar and the composer, because they all read the same list.
    TaskMenuSubmenu(
      id: 'due',
      icon: Icons.event,
      label: 'Set due date',
      items: [
        for (final item in kQuickDateItems)
          TaskMenuItem(
            id: 'due-${item.id}',
            icon: item.icon,
            label: item.label,
            onInvoke: () {
              final move = item.move;
              if (move == null) {
                onPickDate();
              } else {
                onSetDue(move);
              }
            },
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

/// The menu's fixed width, and the keep-out band it holds at every window edge.
const double _menuWidth = 260;
const double _menuMargin = 8;

/// Places the action menu against the cursor AFTER measuring it (#285).
///
/// The placement this replaced clamped only the menu's TOP edge into the
/// window, never the menu: a right-click in the bottom third opened a menu
/// whose lower half — everything from "Set due date" down to "Delete" — hung
/// below the window and could not be reached at all. Answering "does it fit?"
/// needs the menu's laid-out height, which is exactly what a
/// [SingleChildLayoutDelegate] is handed.
///
/// The rule is the desktop context-menu standard: open DOWNWARD from the cursor
/// when there is room, otherwise flip UP so the cursor is the menu's bottom
/// edge, otherwise sit on the margin. Because the menu is measured with LOOSE
/// constraints, an inline submenu expanding re-lays-out a child whose size the
/// parent uses — so the delegate runs again and the menu RE-ANCHORS instead of
/// growing off the bottom. A menu taller than the window scrolls inside its
/// own box (the height cap is the window minus the margins), so the last item
/// is always reachable.
class _CursorMenuLayout extends SingleChildLayoutDelegate {
  const _CursorMenuLayout({required this.anchor, required this.margins});

  /// The cursor, in the layout box's coordinates — the same as global, because
  /// the route is mounted WITHOUT a SafeArea (see [showTaskContextMenu]).
  final Offset anchor;

  /// The band kept clear at the window edges: [_menuMargin] plus whatever the
  /// device hides behind (a notch, a gesture pill).
  final EdgeInsets margins;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.min(
            _menuWidth,
            math.max(0.0, constraints.maxWidth - margins.horizontal),
          ),
          math.max(0.0, constraints.maxHeight - margins.vertical),
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = _between(
      anchor.dx,
      margins.left,
      math.max(margins.left, size.width - margins.right - childSize.width),
    );
    final lowest = size.height - margins.bottom - childSize.height;
    final double top;
    if (anchor.dy <= lowest) {
      top = anchor.dy; // room below: the cursor is the menu's TOP edge
    } else if (anchor.dy - childSize.height >= margins.top) {
      top = anchor.dy - childSize.height; // flipped: cursor is the BOTTOM edge
    } else {
      top = lowest; // taller than either side of the cursor: sit on the margin
    }
    return Offset(
      left,
      _between(top, margins.top, math.max(margins.top, lowest)),
    );
  }

  @override
  bool shouldRelayout(_CursorMenuLayout old) =>
      anchor != old.anchor || margins != old.margins;

  /// [v] held between [lo] and [hi] (callers guarantee `lo <= hi`).
  /// `num.clamp` answers a `num`, and a layout offset must be a `double`.
  static double _between(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);
}

/// Show the desktop right-click context menu for a row at [globalPosition],
/// placed so the whole menu is inside the window (#285). Dismissed by tapping
/// outside (the barrier).
Future<void> showTaskContextMenu(
  BuildContext context,
  Offset globalPosition,
  List<TaskMenuEntry> entries,
) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    // No SafeArea: it would inset the layout box and so shift the menu away
    // from the click by the device padding. The delegate holds that padding
    // clear itself, against coordinates that still match [globalPosition].
    useSafeArea: false,
    builder: (context) => CustomSingleChildLayout(
      delegate: _CursorMenuLayout(
        anchor: globalPosition,
        margins:
            MediaQuery.paddingOf(context) + const EdgeInsets.all(_menuMargin),
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
  );
}
