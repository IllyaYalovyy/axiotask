// A Google Tasks task list — the Dart port of `model.rs`'s `TaskList`.

/// A Google Tasks task list.
class TaskList {
  const TaskList({
    required this.id,
    required this.title,
    this.etag,
    required this.updated,
  });

  /// Google's identifier (or a local UUID before first push).
  final String id;

  /// Display title.
  final String title;

  /// Opaque etag returned by Google. `null` for local-only rows.
  final String? etag;

  /// Server-side `updated` timestamp (RFC 3339).
  final String updated;

  /// Serialize to wire JSON, skipping a `null` etag.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    if (etag != null) 'etag': etag,
    'updated': updated,
  };

  /// Parse from wire JSON; a missing `updated` becomes the empty string.
  factory TaskList.fromJson(Map<String, Object?> json) => TaskList(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    etag: json['etag'] as String?,
    updated: json['updated'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is TaskList &&
      other.id == id &&
      other.title == title &&
      other.etag == etag &&
      other.updated == updated;

  @override
  int get hashCode => Object.hash(id, title, etag, updated);
}
