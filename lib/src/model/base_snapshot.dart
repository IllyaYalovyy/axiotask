// A row's content as of its last agreement with the server — the Dart port of
// `model.rs`'s `BaseSnapshot` (RFC-009 §B/§G, #124).

import 'task.dart';

/// A task's content as of its last agreement with the server. The reconciler
/// compares the refetched remote against this to tell "only WE changed the
/// content" from "the server changed it too": a base-equal remote on a `412`
/// means a bare reorder bumped the etag, so the local edit wins with no
/// conflicted copy (#118); orphan adoption after a crashed create matches on
/// the base so an edit during the in-flight window can't duplicate the task
/// (#122). Holds exactly the user-content fields a [Task] carries — title,
/// notes, due, status — and nothing structural (position, parent, etag).
class BaseSnapshot {
  const BaseSnapshot({
    required this.title,
    this.notes,
    this.due,
    required this.status,
  });

  /// Title as last agreed with the server.
  final String title;

  /// Notes as last agreed (empty string is treated as `null`, as on the wire).
  final String? notes;

  /// Due date as last agreed (RFC 3339).
  final String? due;

  /// Completion status as last agreed.
  final TaskStatus status;

  /// Snapshot a task's current content as the new base.
  factory BaseSnapshot.of(Task task) => BaseSnapshot(
    title: task.title,
    notes: task.notes,
    due: task.due,
    status: task.status,
  );

  @override
  bool operator ==(Object other) =>
      other is BaseSnapshot &&
      other.title == title &&
      other.notes == notes &&
      other.due == due &&
      other.status == status;

  @override
  int get hashCode => Object.hash(title, notes, due, status);
}
