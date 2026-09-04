// Everything a SINGLE row can be asked to do (#274) — toggle, rename, set a
// date, move, detach, nest, duplicate, open on Google, delete — and the desktop
// context menu that offers them.
//
// There is no coarse-pointer counterpart to the menu: the per-row "⋮" and its
// sheet are gone (#245). Touch reaches the same actions by swipe (complete /
// quick-date), long-press (select) and the detail panel.
//
// Each action here surfaces its own consequence — an Undo toast for anything
// destructive or far-reaching, the shared #164 cascade Undo for a date — so a
// row behaves identically whether it was driven from the list, the menu, or a
// keyboard-less phone gesture.

import 'package:flutter/widgets.dart';

import '../app/commands.dart';
import '../model/dates.dart' show DateMove;
import '../store/stored.dart';
import 'due_editing.dart';
import 'haptics.dart';
import 'list_pickers.dart';
import 'selection_controller.dart';
import 'task_actions.dart';
import 'toast.dart';
import 'url_opener.dart';

/// The per-row action surface for one list pane.
class RowActions {
  RowActions({
    required this.commands,
    required this.toasts,
    required this.haptics,
    required this.selection,
    required this.lists,
    required this.allTasks,
    required this.openUrl,
    required this.alive,
    required this.onRequestEdit,
    required this.onOpenTask,
    required this.onOpenTaskNotes,
  });

  final Commands commands;
  final ToastController toasts;
  final Haptics haptics;
  final SelectionController selection;
  final List<StoredTaskList> lists;

  /// The FULL task set — the demote picker's candidate scan needs it.
  final List<StoredTask> allTasks;
  final UrlOpener openUrl;

  /// Whether the list that owns these actions is still on screen (see
  /// [BulkOps.alive]).
  final bool Function() alive;

  /// Put the row into inline rename (the menu's "Edit title").
  final ValueChanged<String> onRequestEdit;

  /// Open the detail panel for a task id.
  final ValueChanged<String> onOpenTask;

  /// Open the detail panel with the Notes field focused.
  final ValueChanged<String> onOpenTaskNotes;

  /// Build and show the row's DESKTOP context menu at [globalPosition] (a
  /// right-click).
  Future<void> showMenu(
    BuildContext context,
    StoredTask t,
    Offset globalPosition,
  ) async {
    final demotable =
        t.task.parent == null && demoteCandidates(t, allTasks).isNotEmpty;
    final entries = buildTaskMenu(
      task: t,
      lists: lists,
      demotable: demotable,
      selected: selection.contains(t.task.id),
      onToggleSelect: () => selection.toggle(t.task.id),
      onEditTitle: () => onRequestEdit(t.task.id),
      onEditNotes: () => onOpenTaskNotes(t.task.id),
      onSetDue: (move) => quickDue(t.task.id, move),
      onPickDate: () => pickDue(context, t.task.id, t.task.due),
      onMoveToList: (listId) => moveToList(t, listId),
      onDetach: () => detach(t),
      onDemote: () => demote(context, t),
      onDuplicate: () => duplicate(t),
      onDetails: () => onOpenTask(t.task.id),
      onOpenGoogle: () => openGoogle(t),
      onDelete: () => delete(t),
    );
    await showTaskContextMenu(context, globalPosition, entries);
  }

  /// Apply a one-gesture quick-date move, then surface any #164 cascade as an
  /// undoable toast.
  Future<void> quickDue(String id, DateMove move) async {
    haptics.tick();
    final edit = await applyDueMove(commands, [id], move);
    if (alive()) offerCascadeUndo(toasts, commands, edit);
  }

  /// Open the calendar for [id] on its current [currentDue] and apply the
  /// choice, then surface any #164 cascade. A dismissed picker leaves the date
  /// untouched.
  Future<void> pickDue(
    BuildContext context,
    String id,
    String? currentDue,
  ) async {
    final edit = await pickAndApplyDue(context, commands, [
      id,
    ], initial: currentDue);
    if (edit.isEmpty) return;
    haptics.tick(); // a picked day is a quick-date apply like any other
    if (alive()) offerCascadeUndo(toasts, commands, edit);
  }

  /// Move [t]'s subtree to [targetListId] and surface an undoable toast (F11:
  /// undoMoveToList reverses the delete-from-old + create-in-new, restoring the
  /// pre-move subtree in its original list).
  Future<void> moveToList(StoredTask t, String targetListId) async {
    if (t.listId == targetListId) return; // already there
    final title = t.task.title;
    final listTitle = lists
        .firstWhere((l) => l.list.id == targetListId, orElse: () => lists.first)
        .list
        .title;
    final token = await commands.moveTaskToList(t.task.id, targetListId);
    if (!alive() || token == null) return;
    toasts.showUndo(
      'Moved "$title" to $listTitle',
      () => commands.undoMoveToList(token),
    );
  }

  /// Detach a subtask back to top level, directly after its former parent.
  Future<void> detach(StoredTask t) async {
    final parentId = t.task.parent;
    if (parentId == null) return;
    await commands.moveTask(t.task.id, parentId: null, previousId: parentId);
  }

  /// Demote [t] into a subtask via the searchable parent picker (#88).
  Future<void> demote(BuildContext context, StoredTask t) async {
    final candidates = demoteCandidates(t, allTasks);
    if (candidates.isEmpty) return;
    final parentId = await showParentPicker(context, candidates: candidates);
    if (parentId == null) return;
    await commands.moveTask(t.task.id, parentId: parentId);
  }

  /// Duplicate [t] as "`<title>` (copy)" in the same list and parent.
  Future<void> duplicate(StoredTask t) => duplicateTask(commands, t);

  /// Open the task's Google Tasks URL via the shared opener.
  Future<void> openGoogle(StoredTask t) async {
    final url = t.task.webViewLink;
    if (url == null || url.isEmpty) return;
    await openUrl(url);
  }

  /// Toggle [stored]'s completion. A COMPLETION (checkbox tick or swipe-right,
  /// the primary mobile gesture) surfaces a 30-second Undo toast whose token
  /// carries the exact cascade set, so undo restores the pre-swipe state — an
  /// already-completed subtask is never reopened. A reopen is silent (no toast).
  Future<void> toggle(StoredTask stored) async {
    // A tick the instant the box flips, not when the write lands: the user is
    // being told their tap registered, and that is true before the store says
    // anything (#257).
    haptics.tick();
    final token = await commands.toggleComplete(stored.task.id);
    if (!alive() || !token.wasCompleting) return;
    toasts.showUndo(
      'Completed "${stored.task.title}"',
      () => commands.undoToggleComplete(token),
    );
  }

  /// Delete [t] with a 30-second Undo toast (mirrors the detail panel's
  /// delete).
  Future<void> delete(StoredTask t) async {
    haptics.confirm(); // a removal is felt more firmly than a tick (#257)
    final token = await commands.deleteTask(t.task.id);
    if (!alive()) return;
    toasts.showUndo(
      'Deleted "${t.task.title}"',
      () => commands.undoDelete(token),
    );
  }
}

/// The callbacks ONE rendered row is wired to (#274).
///
/// Built once per list build and handed to every row, so a row never has to be
/// given eight separate closures — and so the wiring between a row and the
/// action surface behind it is one named thing a reader can check, rather than
/// a lambda spread over a builder.
class TaskRowActions {
  const TaskRowActions({
    required this.toggle,
    required this.open,
    required this.contextMenu,
    required this.selectToggle,
    required this.rename,
    required this.setDue,
    required this.pickDate,
    required this.openUrl,
    required this.editDone,
  });

  /// Flip the row's completion (the checkbox, or a swipe right).
  final void Function(StoredTask) toggle;

  /// Open the detail panel for the row. [rowContext] is the row's own context,
  /// so the compact detail can grow out of the rect it currently occupies
  /// (#253).
  final void Function(BuildContext rowContext, StoredTask) open;

  /// The desktop right-click menu at a global position.
  final void Function(StoredTask, Offset) contextMenu;

  /// Add or remove the row from the multi-selection.
  final void Function(String id) selectToggle;

  /// Commit an inline rename.
  final void Function(String id, String title) rename;

  /// One-gesture quick date (the row's due segment, or a swipe left).
  final void Function(String id, DateMove move) setDue;

  /// Open the calendar on the row's own date.
  final void Function(StoredTask) pickDate;

  /// Open a URL detected in the row's notes.
  final UrlOpener openUrl;

  /// The row left inline-rename mode.
  final void Function(String id) editDone;
}
