part of '../commands.dart';

/// A descendant captured in a [DeleteToken], so undo can rebuild the whole
/// subtree even after the parent's delete pushed — the server cascades child
/// deletion when a parent dies (verified live, #106) and the local FK mirrors
/// it, so the row is gone by undo time and must be recreated from the snapshot.
/// Port of `commands.rs::SubtreeEntry`.
class SubtreeEntry {
  const SubtreeEntry({
    required this.id,
    this.parentId,
    required this.title,
    this.notes,
    required this.status,
    this.due,
    required this.position,
  });

  /// The descendant's id at delete time.
  final String id;

  /// Its parent id (the deleted root, or a mid-level node).
  final String? parentId;

  /// Display title.
  final String title;

  /// Free-form notes.
  final String? notes;

  /// Completion status (Google's wire string).
  final TaskStatus status;

  /// Due date (RFC 3339), if any.
  final String? due;

  /// Lex-sortable position string.
  final String position;
}

/// The undo handle returned by [Commands.deleteTask]: everything needed to put
/// the task — and its whole subtree — back exactly as it was. Held in memory by
/// the caller (the undo toast, T7.8); there is no IPC boundary, so unlike the
/// reference's serialized struct this is a plain value. Port of
/// `commands.rs::DeleteToken`.
class DeleteToken {
  const DeleteToken({
    required this.id,
    required this.listId,
    this.parentId,
    required this.title,
    this.notes,
    required this.status,
    this.due,
    required this.position,
    required this.hadEtag,
    this.subtree = const [],
  });

  /// The deleted task's id.
  final String id;

  /// The list it belonged to.
  final String listId;

  /// Its parent id (`null` for a top-level task).
  final String? parentId;

  /// Display title at delete time.
  final String title;

  /// Notes at delete time.
  final String? notes;

  /// Completion status at delete time.
  final TaskStatus status;

  /// Due date at delete time.
  final String? due;

  /// Lex-sortable position at delete time.
  final String position;

  /// Whether the server had ever acknowledged the task (it carried a
  /// `remote_id`). Drives revive-vs-recreate only as a diagnostic; undo
  /// re-checks the live row instead of trusting this flag.
  final bool hadEtag;

  /// Descendants captured at delete time, parents before children.
  final List<SubtreeEntry> subtree;
}

/// The undo handle returned by [Commands.toggleComplete]. A completion that
/// cascades (a parent completing its open descendants — Google does this
/// server-side, #106) records EXACTLY the ids this call flipped: the toggled
/// row plus every descendant it completed. Undo reopens precisely that set, so a
/// descendant that was ALREADY completed before the swipe stays completed and
/// the pre-swipe state is restored to the row (F11/#184). A reopen never
/// cascades, so its token carries an empty [cascadedReopenIds] and undo simply
/// re-completes the one row.
class CompleteToken {
  const CompleteToken({
    required this.id,
    required this.wasCompleting,
    this.cascadedReopenIds = const [],
  });

  /// The toggled task's id.
  final String id;

  /// True when this call COMPLETED the task (so undo reopens); false when it
  /// reopened it (so undo re-completes).
  final bool wasCompleting;

  /// The descendant ids this completion cascaded — the exact set undo reopens
  /// alongside [id]. Empty for a reopen, or for a leaf/childless completion.
  final List<String> cascadedReopenIds;
}

/// The undo handle returned by [Commands.moveTaskToList]. A cross-list move is a
/// delete-from-old + create-in-new (Google has no native cross-list move), so
/// undo removes the freshly created clone subtree ([newRootId], in
/// [targetListId]) and restores the pre-move subtree from [original] — the same
/// snapshot a delete captures, replayed through [Commands.undoDelete] (F11/#185).
class MoveToListToken {
  const MoveToListToken({
    required this.newRootId,
    required this.targetListId,
    required this.original,
  });

  /// The clone root created in the target list; deleting it removes the whole
  /// moved subtree (Google's own DELETE cascade takes the descendants).
  final String newRootId;

  /// The list the subtree was moved INTO.
  final String targetListId;

  /// The pre-move subtree snapshot, restored in the original list on undo.
  final DeleteToken original;
}

/// One row's due date as it stood BEFORE a [Commands.setDue] edit, captured so
/// the edit and its parent/subtask cascade revert together as a single undo unit
/// (#164). Port of `commands.rs::DueUndoEntry`.
class DueUndoEntry {
  const DueUndoEntry({required this.id, this.due});

  /// The row whose date to restore.
  final String id;

  /// The value to restore; `null` means "no explicit date".
  final String? due;
}

/// Outcome of a [Commands.setDue] edit. Beyond the edit itself it reports the
/// parent/subtask consistency cascade (#164): the undo unit covering the edited
/// row and every row the cascade moved, and enough about the cascade for the UI
/// to phrase its toast. Port of `commands.rs::SetDueResult`.
class SetDueResult {
  const SetDueResult({
    required this.undo,
    required this.cascaded,
    required this.cascadedParent,
  });

  /// The edited row's prior date first, then each cascaded row's prior date.
  /// Feed straight to [Commands.undoSetDue] to revert the whole edit as one unit.
  final List<DueUndoEntry> undo;

  /// How many OTHER rows the cascade moved (0 = no cascade, no toast).
  final int cascaded;

  /// True when the cascade pulled the PARENT down (a child was set earlier);
  /// false when it pulled CHILDREN up (a parent was set later). Selects the
  /// toast wording.
  final bool cascadedParent;
}
