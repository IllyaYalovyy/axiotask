// Domain types shared between API, store, and sync — the Dart port of
// `model.rs`. Both API-shape and store-shape rows live here; conversions are
// straightforward field maps. Keeping them in one module keeps the domain easy
// to reason about (mirrors the reference crate's single `model` module).
//
// Pure Dart: no Flutter/UI dependency, fully testable (the crate contract).

/// Completion status for a task. Serializes to Google's wire strings.
enum TaskStatus {
  /// Task is open.
  needsAction,

  /// Task has been completed.
  completed;

  /// String form used by Google's API.
  String get apiStr => switch (this) {
    TaskStatus.needsAction => 'needsAction',
    TaskStatus.completed => 'completed',
  };

  /// Parse from Google's API string form. Returns `null` for unknown values.
  static TaskStatus? parseApi(String s) => switch (s) {
    'needsAction' => TaskStatus.needsAction,
    'completed' => TaskStatus.completed,
    _ => null,
  };
}

/// Sentinel distinguishing "leave [Task.completed] unchanged" (the default)
/// from an explicit `null` clear in [Task.copyWith].
const Object _unset = Object();

/// A Google Tasks task (a leaf or an interior node of the two-level tree).

class Task {
  const Task({
    required this.id,
    this.parent,
    required this.position,
    required this.title,
    this.notes,
    required this.status,
    this.due,
    this.completed,
    this.etag,
    required this.updated,
    this.webViewLink,
    this.deleted = false,
  });

  /// Google's identifier (or a local UUID before first push).
  final String id;

  /// Parent task id; `null` means the task is a top-level item of its list.
  final String? parent;

  /// Google's lex-sortable position string. Opaque to us.
  final String position;

  /// Display title.
  final String title;

  /// Free-form notes. Empty string is treated as `null` on the wire.
  final String? notes;

  /// Completion status.
  final TaskStatus status;

  /// Due date (RFC 3339; date-only effectively, time component ignored by
  /// Google).
  final String? due;

  /// Completion timestamp (RFC 3339).
  final String? completed;

  /// Opaque etag returned by Google.
  final String? etag;

  /// Server-side `updated` timestamp.
  final String updated;

  /// Absolute link to the task in the Google Tasks web UI (output-only from
  /// Google; `null` for tasks not yet synced). Powers "Open in Google Tasks".
  final String? webViewLink;

  /// Google's soft-delete tombstone flag. Output-only, and meaningful ONLY on a
  /// by-id refetch: a soft-deleted task still answers `200` flagged
  /// `deleted: true` (verified live, RFC-009 §B/§D). Carried through so the
  /// `412`-conflict refetch resolves a delete×edit race as P4 delete-wins
  /// instead of resurrecting the row. Always `false` for stored/listed rows.
  final bool deleted;

  /// A copy with the named fields replaced. The command layer edits an
  /// immutable [Task] by producing a new one (the Dart equivalent of the
  /// reference's in-place `t.task.field = …` mutations). [completed] defaults to
  /// a sentinel so passing an explicit `null` (clearing the completion timestamp
  /// on re-open) is distinguishable from "leave unchanged". [notes] uses the
  /// same sentinel so an explicit `null` (clearing the notes field) is
  /// distinguishable from omission — Google treats empty notes as absent.
  Task copyWith({
    String? id,
    String? parent,
    String? position,
    String? title,
    Object? notes = _unset,
    TaskStatus? status,
    String? due,
    Object? completed = _unset,
    String? etag,
    String? updated,
    String? webViewLink,
    bool? deleted,
  }) => Task(
    id: id ?? this.id,
    parent: parent ?? this.parent,
    position: position ?? this.position,
    title: title ?? this.title,
    notes: identical(notes, _unset) ? this.notes : notes as String?,
    status: status ?? this.status,
    due: due ?? this.due,
    completed: identical(completed, _unset)
        ? this.completed
        : completed as String?,
    etag: etag ?? this.etag,
    updated: updated ?? this.updated,
    webViewLink: webViewLink ?? this.webViewLink,
    deleted: deleted ?? this.deleted,
  );

  /// Serialize to Google's wire JSON: camelCase status, `webViewLink` field
  /// name, and `null`/`false`-default fields skipped exactly as serde does.
  Map<String, Object?> toJson() => {
    'id': id,
    if (parent != null) 'parent': parent,
    'position': position,
    'title': title,
    if (notes != null) 'notes': notes,
    'status': status.apiStr,
    if (due != null) 'due': due,
    if (completed != null) 'completed': completed,
    if (etag != null) 'etag': etag,
    'updated': updated,
    if (webViewLink != null) 'webViewLink': webViewLink,
    if (deleted) 'deleted': deleted,
  };

  /// Parse a task from Google's wire JSON. Missing optional fields become
  /// `null`; a missing `updated` becomes the empty string (parity with the
  /// reference `TaskWire` conversion). Throws [FormatException] on an unknown
  /// status string.
  factory Task.fromJson(Map<String, Object?> json) {
    final statusStr = json['status'] as String? ?? 'needsAction';
    final status = TaskStatus.parseApi(statusStr);
    if (status == null) {
      throw FormatException('unknown task status: $statusStr');
    }
    return Task(
      id: json['id'] as String? ?? '',
      parent: json['parent'] as String?,
      position: json['position'] as String? ?? '',
      title: json['title'] as String? ?? '',
      notes: json['notes'] as String?,
      status: status,
      due: json['due'] as String?,
      completed: json['completed'] as String?,
      etag: json['etag'] as String?,
      updated: json['updated'] as String? ?? '',
      webViewLink: json['webViewLink'] as String?,
      deleted: json['deleted'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Task &&
      other.id == id &&
      other.parent == parent &&
      other.position == position &&
      other.title == title &&
      other.notes == notes &&
      other.status == status &&
      other.due == due &&
      other.completed == completed &&
      other.etag == etag &&
      other.updated == updated &&
      other.webViewLink == webViewLink &&
      other.deleted == deleted;

  @override
  int get hashCode => Object.hash(
    id,
    parent,
    position,
    title,
    notes,
    status,
    due,
    completed,
    etag,
    updated,
    webViewLink,
    deleted,
  );
}

/// Payload accepted by `insert_task`. The server fills in the missing fields.

class NewTask {
  const NewTask({
    required this.title,
    this.notes,
    this.due,
    this.status,
    this.parent,
    this.previous,
  });

  /// Display title.
  final String title;

  /// Optional notes.
  final String? notes;

  /// Optional due date.
  final String? due;

  /// Optional initial status (defaults to needsAction server-side).
  final TaskStatus? status;

  /// Optional parent task id; `null` makes it a top-level task.
  final String? parent;

  /// Optional preceding-sibling id for placement.
  final String? previous;

  /// Serialize the insert payload, skipping unset optional fields.
  Map<String, Object?> toJson() => {
    'title': title,
    if (notes != null) 'notes': notes,
    if (due != null) 'due': due,
    if (status != null) 'status': status!.apiStr,
    if (parent != null) 'parent': parent,
    if (previous != null) 'previous': previous,
  };

  @override
  bool operator ==(Object other) =>
      other is NewTask &&
      other.title == title &&
      other.notes == notes &&
      other.due == due &&
      other.status == status &&
      other.parent == parent &&
      other.previous == previous;

  @override
  int get hashCode => Object.hash(title, notes, due, status, parent, previous);
}

/// Sparse update for `patch_task` — only non-`null` fields are sent. `''` for
/// [notes] or [due] clears the field (parity with the reference wire contract).

class TaskPatch {
  const TaskPatch({this.title, this.notes, this.due, this.status});

  /// New title.
  final String? title;

  /// New notes (`''` clears).
  final String? notes;

  /// New due date (`''` clears).
  final String? due;

  /// New status.
  final TaskStatus? status;

  /// Returns true when no fields are set.
  bool get isEmpty =>
      title == null && notes == null && due == null && status == null;

  /// Serialize the sparse patch, skipping unset fields.
  Map<String, Object?> toJson() => {
    if (title != null) 'title': title,
    if (notes != null) 'notes': notes,
    if (due != null) 'due': due,
    if (status != null) 'status': status!.apiStr,
  };

  @override
  bool operator ==(Object other) =>
      other is TaskPatch &&
      other.title == title &&
      other.notes == notes &&
      other.due == due &&
      other.status == status;

  @override
  int get hashCode => Object.hash(title, notes, due, status);
}
