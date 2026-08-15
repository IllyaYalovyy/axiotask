final class PageToken {
  const PageToken(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PageToken && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PageToken(<redacted>)';
}

final class RemoteTaskListId {
  const RemoteTaskListId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteTaskListId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'RemoteTaskListId(<redacted>)';
}

final class RemoteTaskId {
  const RemoteTaskId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RemoteTaskId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'RemoteTaskId(<redacted>)';
}

final class RemoteDate {
  const RemoteDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  DateTime get utcMidnight => DateTime.utc(year, month, day);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteDate &&
          year == other.year &&
          month == other.month &&
          day == other.day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

final class RemotePage<T> {
  RemotePage({
    required List<T> items,
    required this.collectionEtag,
    required this.nextPageToken,
  }) : items = List<T>.unmodifiable(items);

  final List<T> items;
  final String? collectionEtag;
  final PageToken? nextPageToken;
}

final class RemoteTaskList {
  const RemoteTaskList({
    required this.id,
    required this.etag,
    required this.title,
    required this.updated,
    required this.selfLink,
  });

  final RemoteTaskListId id;
  final String? etag;
  final String title;
  final DateTime? updated;
  final Uri? selfLink;
}

enum RemoteTaskStatus { needsAction, completed }

final class RemoteTaskLink {
  const RemoteTaskLink({
    required this.type,
    required this.description,
    required this.link,
  });

  final String? type;
  final String? description;
  final Uri? link;
}

sealed class RemoteTask {
  const RemoteTask({
    required this.id,
    required this.etag,
    required this.updated,
    required this.selfLink,
  });

  final RemoteTaskId id;
  final String? etag;
  final DateTime? updated;
  final Uri? selfLink;

  bool get deleted;
}

final class RemoteLiveTask extends RemoteTask {
  RemoteLiveTask({
    required super.id,
    required super.etag,
    required super.updated,
    required super.selfLink,
    required this.title,
    required this.parentId,
    required this.position,
    required this.notes,
    required this.status,
    required this.due,
    required this.completed,
    required this.hidden,
    required List<RemoteTaskLink> links,
    required this.webViewLink,
  }) : links = List<RemoteTaskLink>.unmodifiable(links);

  final String title;
  final RemoteTaskId? parentId;
  final String position;
  final String? notes;
  final RemoteTaskStatus status;
  final RemoteDate? due;
  final DateTime? completed;
  final bool hidden;
  final List<RemoteTaskLink> links;
  final Uri? webViewLink;

  @override
  bool get deleted => false;
}

final class RemoteTaskTombstone extends RemoteTask {
  RemoteTaskTombstone({
    required super.id,
    required super.etag,
    required super.updated,
    required super.selfLink,
    required this.retainedTitle,
    required this.retainedParentId,
    required this.retainedPosition,
    required this.retainedNotes,
    required this.retainedStatus,
    required this.retainedDue,
    required this.retainedCompleted,
    required this.hidden,
    required List<RemoteTaskLink> retainedLinks,
    required this.retainedWebViewLink,
  }) : retainedLinks = List<RemoteTaskLink>.unmodifiable(retainedLinks);

  final String? retainedTitle;
  final RemoteTaskId? retainedParentId;
  final String? retainedPosition;
  final String? retainedNotes;
  final RemoteTaskStatus? retainedStatus;
  final RemoteDate? retainedDue;
  final DateTime? retainedCompleted;
  final bool hidden;
  final List<RemoteTaskLink> retainedLinks;
  final Uri? retainedWebViewLink;

  @override
  bool get deleted => true;
}
