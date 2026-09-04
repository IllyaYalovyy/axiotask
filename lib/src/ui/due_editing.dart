// The ONE way a due date is edited from a surface that has a task to write it
// to (#274) — the list row, the detail panel, and the bulk bar.
//
// Every one of them does the same three things: apply the move (a quick-date
// choice, or a day picked out of the calendar), let the command layer run the
// #164 consistency cascade, and give the user ONE Undo covering the edit and
// everything the cascade dragged with it. They used to do it in three places,
// and bulk — the surface where an edit moves the most rows — did it wrong: it
// dropped every [SetDueResult] on the floor, so a reschedule that pulled a
// dozen subtask dates along offered nothing but a count.
//
// [DueEdit] is what makes the bulk case expressible: N rows written one after
// another are ONE edit from the user's side, so their undo entries accumulate
// into one unit and their cascades into one count.

import 'package:flutter/widgets.dart';

import '../app/commands.dart';
import '../model/dates.dart' show DateMove;
import 'due_date_picker.dart';
import 'toast.dart';

/// The accumulated outcome of applying one date edit across one or more rows.
///
/// A single-row edit is the degenerate case (one target, its own cascade); a
/// bulk edit is N of them merged, so the Undo the user is offered reverses the
/// WHOLE op — every target row and every row its cascade moved — in one tap.
class DueEdit {
  const DueEdit({
    required this.undo,
    required this.applied,
    required this.cascaded,
    required this.cascadedParent,
    this.cleared = false,
  });

  /// Nothing was written (a dismissed picker, an empty selection).
  static const DueEdit none = DueEdit(
    undo: [],
    applied: 0,
    cascaded: 0,
    cascadedParent: false,
  );

  /// Every row's prior date — the edited ones first, then the cascaded ones.
  /// Feed straight to [Commands.undoSetDue] to revert the whole edit.
  final List<DueUndoEntry> undo;

  /// How many TARGET rows were written (the selection size, minus rows that
  /// vanished under the op).
  final int applied;

  /// How many OTHER rows the cascade moved across all targets.
  final int cascaded;

  /// True when the cascade pulled a PARENT down rather than children up —
  /// selects the toast wording. With a mixed bulk cascade the children wording
  /// wins, because it is the one that names a count.
  final bool cascadedParent;

  /// Whether the edit REMOVED the date rather than moving it — the toast verb
  /// ("cleared" vs "rescheduled"), decided where the choice was made rather
  /// than re-derived from the rows afterwards.
  final bool cleared;

  bool get isEmpty => applied == 0;

  /// Merge [next] into this outcome — how a bulk edit accumulates.
  DueEdit merge(SetDueResult next, {required bool cleared}) => DueEdit(
    undo: [...undo, ...next.undo],
    applied: applied + 1,
    cascaded: cascaded + next.cascaded,
    // Children-pulled-up wins a mixed bulk cascade: its wording carries a
    // count, and a count is the honest thing to say about N rows.
    cascadedParent: next.cascaded > 0
        ? (cascaded == 0
              ? next.cascadedParent
              : cascadedParent && next.cascadedParent)
        : cascadedParent,
    cleared: cleared,
  );
}

/// Apply [move] to every id in [ids], accumulating the cascade into one
/// [DueEdit]. A row that vanished under the op (a sync pull, another gesture)
/// is skipped so the rest of the edit still lands as one undo unit.
Future<DueEdit> applyDueMove(
  Commands commands,
  Iterable<String> ids,
  DateMove move,
) async {
  var edit = DueEdit.none;
  for (final id in ids) {
    try {
      edit = edit.merge(
        await commands.setDue(id, move),
        cleared: move == DateMove.clear,
      );
    } on CommandError {
      // The row is gone; there is no date to move and nothing to undo for it.
    }
  }
  return edit;
}

/// Open the shared calendar and apply the choice to every id in [ids] — a
/// picked day through `setDueRaw`, "Clear" through `setDue` — accumulating the
/// cascade into one [DueEdit].
///
/// Returns [DueEdit.none] for a dismissed picker, which leaves every row's date
/// exactly as it was. [initial] pre-selects a day (the single-row case's own
/// date); bulk opens on today, because a selection has no one date to open on.
/// [onPicked] runs once the choice is confirmed and BEFORE the first write.
Future<DueEdit> pickAndApplyDue(
  BuildContext context,
  Commands commands,
  Iterable<String> ids, {
  String? initial,
  VoidCallback? onPicked,
}) async {
  final pick = await showDueDatePicker(context, initial: initial);
  if (pick == null || !context.mounted) return DueEdit.none;
  // The choice is made and the op is committed: a caller that has UI to stand
  // down (the bulk bar) does it HERE, before the writes, so the selection is
  // not still sitting there highlighted while N rows are written one by one.
  onPicked?.call();
  var edit = DueEdit.none;
  for (final id in ids) {
    try {
      edit = edit.merge(switch (pick) {
        DuePickClear() => await commands.setDue(id, DateMove.clear),
        DuePickDate(:final ymd) => await commands.setDueRaw(id, ymd),
      }, cleared: pick is DuePickClear);
    } on CommandError {
      // See [applyDueMove].
    }
  }
  return edit;
}

/// The #164 cascade wording for [edit], or `null` when it moved no other row.
String? cascadeMessage(DueEdit edit) {
  final n = edit.cascaded;
  if (n == 0) return null;
  if (edit.cascadedParent) return 'Parent date moved to match';
  return '$n subtask date${n == 1 ? '' : 's'} moved to match';
}

/// Surface a SINGLE-row edit's cascade as an undoable toast, or say nothing
/// when the edit moved no other row (a plain date set is its own feedback —
/// the row's date badge changed under the finger that set it).
void offerCascadeUndo(ToastController toasts, Commands commands, DueEdit edit) {
  final message = cascadeMessage(edit);
  if (message == null) return;
  toasts.showUndo(message, () => commands.undoSetDue(edit.undo));
}

/// Report a BULK edit: "N tasks rescheduled/cleared", carrying the cascade —
/// and with it a real Undo — whenever the op moved rows the user did not
/// select.
///
/// Bulk is the surface where an edit reaches furthest: N selected parents can
/// drag many more subtasks along, and before #274 that happened behind a bare
/// info toast with no way back. Undo reverses the WHOLE op as one unit.
void reportBulkDueEdit(
  ToastController toasts,
  Commands commands,
  DueEdit edit,
) {
  if (edit.isEmpty) return;
  final n = edit.applied;
  final verb = edit.cleared ? 'cleared' : 'rescheduled';
  final headline = '$n task${n == 1 ? '' : 's'} $verb';
  final cascade = cascadeMessage(edit);
  if (cascade == null) {
    toasts.showInfo(headline);
    return;
  }
  toasts.showUndo(
    '$headline — ${cascade[0].toLowerCase()}${cascade.substring(1)}',
    () => commands.undoSetDue(edit.undo),
  );
}
