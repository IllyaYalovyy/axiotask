// Every whole-selection action the bulk bar offers (#274) — complete, set a
// date, move, duplicate, nest, delete — as one object over the command layer
// rather than a dozen methods on the list pane.
//
// The contract every op here keeps: it takes the selection as it stood when the
// user pressed the button, clears the selection immediately (the op is
// committed the moment it starts), and reports ONE outcome for the whole
// thing — one toast, one Undo, one haptic. A row that vanished between
// selection and op (a sync pull, another gesture) is skipped so the rest of the
// selection still lands as one unit.

import 'package:flutter/widgets.dart';

import '../app/commands.dart';
import '../model/dates.dart' show DateMove;
import '../model/task.dart';
import '../model/task_tree.dart' show hasSubtasks, isSubtask;
import '../store/stored.dart';
import 'due_editing.dart';
import 'haptics.dart';
import 'list_pickers.dart';
import 'selection_controller.dart';
import 'task_actions.dart';
import 'toast.dart';

/// The seams a bulk op needs from the surface hosting it: the command layer,
/// the toast line, the haptic vocabulary, and the row set it is selecting from.
class BulkOps {
  BulkOps({
    required this.commands,
    required this.toasts,
    required this.haptics,
    required this.selection,
    required this.byId,
    required this.lists,
    required this.expectChanges,
    required this.alive,
  });

  final Commands commands;
  final ToastController toasts;
  final Haptics haptics;
  final SelectionController selection;

  /// The FULL task set by id — bulk demote's legality scan and duplicate both
  /// need the row behind an id, not just the id.
  final Map<String, StoredTask> byId;

  /// Every known list — a bulk move shows them all, because the selection may
  /// already span lists.
  final List<StoredTaskList> lists;

  /// Declare the rows about to be written, so their commits flash the whole row
  /// rather than one badge (#252).
  final void Function(Iterable<String>) expectChanges;

  /// Whether the surface that started the op is still on screen. An op whose
  /// list was torn down mid-flight still finishes its writes — they were
  /// committed the moment the button was pressed — but says nothing: a toast
  /// about a list the user has already left is noise they cannot act on.
  final bool Function() alive;

  List<String> _take() {
    final ids = selection.ids.toList();
    selection.clear();
    return ids;
  }

  /// A 4-second info toast reporting an outcome ("N tasks `<verb>`").
  void _toast(int n, String verb) {
    if (n <= 0) return;
    toasts.showInfo('$n task${n == 1 ? '' : 's'} $verb');
  }

  /// Complete every still-open selected task, with ONE Undo reopening exactly
  /// what this op flipped — every toggle's cascade-exact set, so a descendant
  /// already completed before the op stays completed on undo (F11/#184).
  Future<void> complete() async {
    final ids = _take();
    final tokens = <CompleteToken>[];
    for (final id in ids) {
      // Completing is idempotent-ish: only flip a still-open task (toggle would
      // otherwise re-open an already-completed one).
      if (byId[id]?.task.status == TaskStatus.completed) continue;
      try {
        tokens.add(await commands.toggleComplete(id));
      } on CommandError {
        // Row vanished between selection and op — skip it and still complete,
        // and undo, the rest.
      }
    }
    if (!alive() || tokens.isEmpty) return;
    final n = tokens.length;
    toasts.showUndo('$n task${n == 1 ? '' : 's'} completed', () {
      for (final token in tokens) {
        commands.undoToggleComplete(token);
      }
    });
  }

  /// Move the whole selection with one quick-date choice. The #164 cascade the
  /// command layer runs is carried into the report, so a reschedule that
  /// dragged subtask dates along is undoable as one unit (#274).
  Future<void> setDue(DateMove move) async {
    haptics.tick(); // one tick for the whole selection, not one per task
    final ids = _take();
    expectChanges(ids);
    final edit = await applyDueMove(commands, ids, move);
    if (alive()) reportBulkDueEdit(toasts, commands, edit);
  }

  /// The bulk "Pick a date…": one calendar for the whole selection. Bulk could
  /// not reach a picked day at all before the surfaces were unified (#243), and
  /// could not undo its cascade until they shared one apply (#274).
  Future<void> pickDue(BuildContext context) async {
    // The picker is opened BEFORE the selection is taken: a dismissed calendar
    // must leave the selection exactly as it was. A CONFIRMED one stands the
    // bar down immediately, like every other bulk action — the op is committed
    // the moment the day is picked, not when the last row finishes writing.
    final ids = selection.ids.toList();
    final edit = await pickAndApplyDue(
      context,
      commands,
      ids,
      onPicked: () {
        haptics.tick();
        expectChanges(ids);
        selection.clear();
      },
    );
    if (edit.isEmpty || !alive()) return;
    reportBulkDueEdit(toasts, commands, edit);
  }

  /// Delete the whole selection, with ONE Undo restoring all N (each with its
  /// own subtree, parent, and position).
  Future<void> delete() async {
    haptics.confirm(); // ONE confirm for the op, never one per task
    final ids = _take();
    final tokens = <DeleteToken>[];
    for (final id in ids) {
      try {
        tokens.add(await commands.deleteTask(id));
      } on CommandError {
        // Row vanished between selection and op: nothing left to delete or undo
        // for this id — skip it so the rest still deletes as one Undo unit.
      }
    }
    if (!alive() || tokens.isEmpty) return;
    final n = tokens.length;
    toasts.showUndo('$n task${n == 1 ? '' : 's'} deleted', () {
      for (final token in tokens) {
        commands.undoDelete(token);
      }
    });
  }

  /// Move every selected task to one picked list.
  Future<void> move(BuildContext context) async {
    // Bulk mode shows EVERY list (the selection may span lists).
    final target = await showMoveToListPicker(context, lists: lists);
    if (target == null || !alive()) return;
    final ids = _take();
    expectChanges(ids);
    for (final id in ids) {
      await commands.moveTaskToList(id, target);
    }
    if (alive()) _toast(ids.length, 'moved');
  }

  /// Copy every selected task (#245 — Duplicate lost its per-row menu and needs
  /// a whole-selection home).
  Future<void> duplicate() async {
    final ids = _take();
    var made = 0;
    for (final id in ids) {
      final t = byId[id];
      // The row may have vanished between selection and op (a sync pull,
      // another gesture): there is nothing to copy, so skip it rather than
      // inventing one.
      if (t == null) continue;
      await duplicateTask(commands, t);
      made++;
    }
    if (alive()) _toast(made, 'duplicated');
  }

  /// The parents the whole selection may legally nest under.
  List<StoredTask> demoteCandidates() =>
      bulkDemoteCandidates(selection.ids, byId.values.toList(growable: false));

  /// Nest the whole selection under one picked parent (#245's bulk half of the
  /// #88 picker).
  Future<void> demote(BuildContext context) async {
    final candidates = demoteCandidates();
    if (candidates.isEmpty) return;
    final parentId = await showParentPicker(context, candidates: candidates);
    if (parentId == null || !alive()) return;
    final ids = _take();
    for (final id in ids) {
      await commands.moveTask(id, parentId: parentId);
    }
    if (alive()) _toast(ids.length, 'nested');
  }
}

/// The parents every task in [selected] may legally nest under (#88 + #245): a
/// task outside the selection that can host ALL of them. Empty means the bulk
/// action is not offered at all — a selection spanning lists, or containing a
/// task with subtasks of its own, has no legal single host.
///
/// This is `canNestUnder` applied to a whole selection WITHOUT re-scanning the
/// task set for every (selected, candidate) pair — the list rebuilds on every
/// store emit, and the naive form is quadratic in the task count. The only part
/// of the predicate that depends on the child is "has no subtasks of its own",
/// answered once per selected task; what is left is a property of the candidate
/// alone (top-level, same list, not itself selected).
///
/// A free function, not a method, because the bulk bar has to ask it on every
/// build to decide whether to offer the action at all — and building a whole
/// command-backed [BulkOps] just to answer a question about rows would drag the
/// command layer into a pane that may not have one (a golden, a layout test).
List<StoredTask> bulkDemoteCandidates(
  Set<String> selected,
  List<StoredTask> all,
) {
  // Answered before anything is indexed: with nothing selected the list pane
  // asks this on every build, and a phone with a large account must not pay for
  // an index it will not read.
  if (selected.isEmpty) return const [];
  final rows = [
    for (final t in all)
      if (selected.contains(t.task.id)) t,
  ];
  // An id in the selection that no longer exists (a sync pull removed it):
  // offer nothing rather than silently nesting a partial selection.
  if (rows.length != selected.length) return const [];
  final listId = rows.first.listId;
  if (rows.any((t) => t.listId != listId)) return const [];
  final tasks = [for (final t in all) t.task];
  if (rows.any((t) => hasSubtasks(t.task.id, tasks))) return const [];
  return [
    for (final c in all)
      if (!selected.contains(c.task.id) &&
          c.listId == listId &&
          !isSubtask(c.task))
        c,
  ];
}
