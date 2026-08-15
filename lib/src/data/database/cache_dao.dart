import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/model/tasks.dart';
import 'app_database.dart';

enum CacheProjection { supported, deleted, unsupported }

enum CacheScopeKind { taskLists, tasks }

final class CacheScope {
  const CacheScope.taskLists()
    : kind = CacheScopeKind.taskLists,
      taskListId = null;

  const CacheScope.tasks(TaskListId this.taskListId)
    : kind = CacheScopeKind.tasks;

  final CacheScopeKind kind;
  final TaskListId? taskListId;
}

final class CacheInvariantException implements Exception {
  const CacheInvariantException(this.code);

  final String code;

  @override
  String toString() => 'CacheInvariantException($code)';
}

final class TaskListRemoteBaseRecord {
  const TaskListRemoteBaseRecord({
    required this.accountId,
    required this.taskListId,
    required this.remoteId,
    required this.title,
    required this.etag,
    required this.remoteUpdatedAt,
    required this.deleted,
    required this.observedPublicationId,
  });

  final AccountId accountId;
  final TaskListId taskListId;
  final TaskListRemoteId remoteId;
  final String title;
  final String? etag;
  final DateTime? remoteUpdatedAt;
  final bool deleted;
  final String observedPublicationId;
}

final class TaskRemoteLinkRecord {
  const TaskRemoteLinkRecord({
    required this.type,
    required this.description,
    required this.link,
  });

  final String? type;
  final String? description;
  final Uri? link;

  @override
  bool operator ==(Object other) =>
      other is TaskRemoteLinkRecord &&
      type == other.type &&
      description == other.description &&
      link == other.link;

  @override
  int get hashCode => Object.hash(type, description, link);
}

final class TaskRemoteBaseRecord {
  TaskRemoteBaseRecord({
    required this.accountId,
    required this.taskId,
    required this.taskListId,
    required this.parentTaskId,
    required this.remoteId,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
    required this.position,
    required this.completedAt,
    required this.hidden,
    required this.deleted,
    required this.etag,
    required this.remoteUpdatedAt,
    required this.selfLink,
    required List<TaskRemoteLinkRecord> links,
    required this.webViewLink,
    required this.observedPublicationId,
  }) : links = List<TaskRemoteLinkRecord>.unmodifiable(links);

  final AccountId accountId;
  final TaskId taskId;
  final TaskListId taskListId;
  final TaskId? parentTaskId;
  final TaskRemoteId remoteId;
  final String? title;
  final String? notes;
  final TaskStatus? status;
  final TaskDate? due;
  final String? position;
  final DateTime? completedAt;
  final bool hidden;
  final bool deleted;
  final String? etag;
  final DateTime? remoteUpdatedAt;
  final Uri? selfLink;
  final List<TaskRemoteLinkRecord> links;
  final Uri? webViewLink;
  final String observedPublicationId;
}

final class CacheDao {
  const CacheDao(this._database);

  final AppDatabase _database;

  Future<T> transaction<T>(Future<T> Function() action) =>
      _database.transaction(action);

  Future<TaskListId> putTaskList({
    required AccountId accountId,
    required TaskListRemoteId? remoteId,
    required String title,
    CacheProjection projection = CacheProjection.supported,
  }) async {
    if (remoteId != null) {
      _requireRemoteValue(remoteId.value, 'task_list_remote_id');
    }
    final id = await _database
        .into(_database.taskListCacheRows)
        .insert(
          TaskListCacheRowsCompanion.insert(
            accountId: accountId.value,
            remoteId: Value<String?>(remoteId?.value),
            title: title,
            projection: projection.name,
          ),
        );
    return TaskListId(id);
  }

  Future<TaskId> putTask({
    required AccountId accountId,
    required TaskListId taskListId,
    required TaskRemoteId? remoteId,
    required String title,
    required String position,
    TaskId? parentTaskId,
    String? notes,
    TaskStatus status = TaskStatus.needsAction,
    TaskDate? due,
    CacheProjection projection = CacheProjection.supported,
  }) async {
    if (remoteId != null) {
      _requireRemoteValue(remoteId.value, 'task_remote_id');
    }
    if (position.isEmpty) {
      throw const CacheInvariantException('empty_position');
    }
    if (parentTaskId != null) {
      final parent =
          await (_database.select(_database.taskCacheRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.taskListId.equals(taskListId.value) &
                    row.id.equals(parentTaskId.value),
              ))
              .getSingleOrNull();
      if (parent?.parentTaskId != null) {
        throw const CacheInvariantException('unsupported_task_depth');
      }
    }
    final id = await _database
        .into(_database.taskCacheRows)
        .insert(
          TaskCacheRowsCompanion.insert(
            accountId: accountId.value,
            taskListId: taskListId.value,
            parentTaskId: Value<int?>(parentTaskId?.value),
            remoteId: Value<String?>(remoteId?.value),
            title: title,
            notes: Value<String?>(notes),
            status: _statusValue(status),
            dueEpochDay: Value<int?>(_epochDay(due)),
            position: position,
            projection: projection.name,
          ),
        );
    return TaskId(id);
  }

  Future<void> bindTaskListRemoteId({
    required AccountId accountId,
    required TaskListId taskListId,
    required TaskListRemoteId remoteId,
  }) async {
    _requireRemoteValue(remoteId.value, 'task_list_remote_id');
    final changed =
        await (_database.update(_database.taskListCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(taskListId.value),
            ))
            .write(TaskListCacheRowsCompanion(remoteId: Value(remoteId.value)));
    if (changed != 1) {
      throw const CacheInvariantException('task_list_not_found');
    }
  }

  Future<void> putTaskListRemoteBase({
    required AccountId accountId,
    required TaskListId taskListId,
    required TaskListRemoteId remoteId,
    required String title,
    required String observedPublicationId,
    String? etag,
    DateTime? remoteUpdatedAt,
    bool deleted = false,
  }) async {
    _requireRemoteValue(remoteId.value, 'task_list_remote_id');
    _requireRemoteValue(observedPublicationId, 'observed_publication_id');
    _requireOptionalRemoteValue(etag, 'etag');
    final projection =
        await (_database.select(_database.taskListCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(taskListId.value),
            ))
            .getSingleOrNull();
    if (projection == null || projection.remoteId != remoteId.value) {
      throw const CacheInvariantException('task_list_base_identity_mismatch');
    }
    await _database
        .into(_database.taskListRemoteBases)
        .insertOnConflictUpdate(
          TaskListRemoteBasesCompanion.insert(
            accountId: accountId.value,
            taskListId: taskListId.value,
            remoteId: remoteId.value,
            title: title,
            etag: Value<String?>(etag),
            remoteUpdatedAt: Value<DateTime?>(_utc(remoteUpdatedAt)),
            deleted: Value<bool>(deleted),
            observedPublicationId: observedPublicationId,
          ),
        );
  }

  Future<TaskListRemoteBaseRecord?> readTaskListRemoteBase(
    AccountId accountId,
    TaskListId taskListId,
  ) async {
    final row =
        await (_database.select(_database.taskListRemoteBases)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.taskListId.equals(taskListId.value),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    _requireRemoteValue(row.remoteId, 'task_list_remote_id');
    _requireRemoteValue(row.observedPublicationId, 'observed_publication_id');
    _requireOptionalRemoteValue(row.etag, 'etag');
    return TaskListRemoteBaseRecord(
      accountId: AccountId(row.accountId),
      taskListId: TaskListId(row.taskListId),
      remoteId: TaskListRemoteId(row.remoteId),
      title: row.title,
      etag: row.etag,
      remoteUpdatedAt: _utc(row.remoteUpdatedAt),
      deleted: row.deleted,
      observedPublicationId: row.observedPublicationId,
    );
  }

  Future<void> putTaskRemoteBase({
    required AccountId accountId,
    required TaskId taskId,
    required TaskListId taskListId,
    required TaskRemoteId remoteId,
    required String observedPublicationId,
    required bool deleted,
    TaskId? parentTaskId,
    String? title,
    String? notes,
    TaskStatus? status,
    TaskDate? due,
    String? position,
    DateTime? completedAt,
    bool hidden = false,
    String? etag,
    DateTime? remoteUpdatedAt,
    Uri? selfLink,
    List<TaskRemoteLinkRecord> links = const <TaskRemoteLinkRecord>[],
    Uri? webViewLink,
  }) async {
    _requireRemoteValue(remoteId.value, 'task_remote_id');
    _requireRemoteValue(observedPublicationId, 'observed_publication_id');
    _requireOptionalRemoteValue(etag, 'etag');
    _requireOptionalRemoteValue(position, 'position');
    if (!deleted && (title == null || status == null || position == null)) {
      throw const CacheInvariantException('incomplete_live_task_base');
    }
    _validateAbsoluteUri(selfLink, 'self_link');
    _validateAbsoluteUri(webViewLink, 'web_view_link');
    for (final link in links) {
      _validateAbsoluteUri(link.link, 'task_link');
    }
    final projection =
        await (_database.select(_database.taskCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(taskId.value),
            ))
            .getSingleOrNull();
    if (projection == null || projection.remoteId != remoteId.value) {
      throw const CacheInvariantException('task_base_identity_mismatch');
    }
    await _database
        .into(_database.taskRemoteBases)
        .insertOnConflictUpdate(
          TaskRemoteBasesCompanion.insert(
            accountId: accountId.value,
            taskId: taskId.value,
            taskListId: taskListId.value,
            parentTaskId: Value<int?>(parentTaskId?.value),
            remoteId: remoteId.value,
            title: Value<String?>(title),
            notes: Value<String?>(notes),
            status: Value<String?>(
              status == null ? null : _statusValue(status),
            ),
            dueEpochDay: Value<int?>(_epochDay(due)),
            position: Value<String?>(position),
            completedAt: Value<DateTime?>(_utc(completedAt)),
            hidden: Value<bool>(hidden),
            deleted: Value<bool>(deleted),
            etag: Value<String?>(etag),
            remoteUpdatedAt: Value<DateTime?>(_utc(remoteUpdatedAt)),
            selfLink: Value<String?>(selfLink?.toString()),
            linksJson: Value<String>(_encodeLinks(links)),
            webViewLink: Value<String?>(webViewLink?.toString()),
            observedPublicationId: observedPublicationId,
          ),
        );
  }

  Future<TaskRemoteBaseRecord?> readTaskRemoteBase(
    AccountId accountId,
    TaskId taskId,
  ) async {
    final row =
        await (_database.select(_database.taskRemoteBases)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.taskId.equals(taskId.value),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    _requireRemoteValue(row.remoteId, 'task_remote_id');
    _requireRemoteValue(row.observedPublicationId, 'observed_publication_id');
    _requireOptionalRemoteValue(row.etag, 'etag');
    _requireOptionalRemoteValue(row.position, 'position');
    if (!row.deleted &&
        (row.title == null || row.status == null || row.position == null)) {
      throw const CacheInvariantException('incomplete_live_task_base');
    }
    return TaskRemoteBaseRecord(
      accountId: AccountId(row.accountId),
      taskId: TaskId(row.taskId),
      taskListId: TaskListId(row.taskListId),
      parentTaskId: row.parentTaskId == null ? null : TaskId(row.parentTaskId!),
      remoteId: TaskRemoteId(row.remoteId),
      title: row.title,
      notes: row.notes,
      status: _readStatus(row.status),
      due: _taskDate(row.dueEpochDay),
      position: row.position,
      completedAt: _utc(row.completedAt),
      hidden: row.hidden,
      deleted: row.deleted,
      etag: row.etag,
      remoteUpdatedAt: _utc(row.remoteUpdatedAt),
      selfLink: _readAbsoluteUri(row.selfLink, 'self_link'),
      links: _decodeLinks(row.linksJson),
      webViewLink: _readAbsoluteUri(row.webViewLink, 'web_view_link'),
      observedPublicationId: row.observedPublicationId,
    );
  }

  Future<void> putScopeCompleteness({
    required AccountId accountId,
    required CacheScope scope,
    required String publicationId,
    required bool isComplete,
    String? nextPageToken,
    String? collectionEtag,
  }) async {
    _requireRemoteValue(publicationId, 'publication_id');
    _requireOptionalRemoteValue(nextPageToken, 'next_page_token');
    _requireOptionalRemoteValue(collectionEtag, 'collection_etag');
    if (isComplete && nextPageToken != null) {
      throw const CacheInvariantException('complete_scope_has_next_page');
    }
    final kind = switch (scope.kind) {
      CacheScopeKind.taskLists => 'task_lists',
      CacheScopeKind.tasks => 'tasks',
    };
    final existing =
        await (_database.select(_database.scopeCompletenessRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.scopeKind.equals(kind) &
                  (scope.taskListId == null
                      ? row.taskListId.isNull()
                      : row.taskListId.equals(scope.taskListId!.value)),
            ))
            .getSingleOrNull();
    final companion = ScopeCompletenessRowsCompanion(
      accountId: Value(accountId.value),
      scopeKind: Value(kind),
      scopeKey: Value<String>(
        scope.taskListId == null
            ? 'task_lists'
            : 'tasks:${scope.taskListId!.value}',
      ),
      taskListId: Value<int?>(scope.taskListId?.value),
      publicationId: Value(publicationId),
      nextPageToken: Value<String?>(nextPageToken),
      collectionEtag: Value<String?>(collectionEtag),
      isComplete: Value(isComplete),
    );
    if (existing == null) {
      await _database.into(_database.scopeCompletenessRows).insert(companion);
    } else {
      await (_database.update(
        _database.scopeCompletenessRows,
      )..where((row) => row.id.equals(existing.id))).write(companion);
    }
  }

  Future<void> putListPreference({
    required AccountId accountId,
    required TaskListId taskListId,
    required int? sidebarOrder,
    required bool excludedFromSmartViews,
  }) async {
    if (sidebarOrder != null && sidebarOrder < 0) {
      throw const CacheInvariantException('negative_sidebar_order');
    }
    await _database
        .into(_database.taskListPreferenceRows)
        .insertOnConflictUpdate(
          TaskListPreferenceRowsCompanion.insert(
            accountId: accountId.value,
            taskListId: taskListId.value,
            sidebarOrder: Value<int?>(sidebarOrder),
            excludedFromSmartViews: Value<bool>(excludedFromSmartViews),
          ),
        );
  }

  Future<int> countStoredTaskLists(AccountId accountId) async {
    final count = _database.taskListCacheRows.id.count();
    final query = _database.selectOnly(_database.taskListCacheRows)
      ..addColumns(<Expression<Object>>[count])
      ..where(_database.taskListCacheRows.accountId.equals(accountId.value));
    return (await query.getSingle()).read(count) ?? 0;
  }
}

void _requireRemoteValue(String? value, String field) {
  if (value == null || value.isEmpty) {
    throw CacheInvariantException('invalid_$field');
  }
}

void _requireOptionalRemoteValue(String? value, String field) {
  if (value != null && value.isEmpty) {
    throw CacheInvariantException('invalid_$field');
  }
}

String _statusValue(TaskStatus status) => switch (status) {
  TaskStatus.needsAction => 'needs_action',
  TaskStatus.completed => 'completed',
};

int? _epochDay(TaskDate? value) {
  if (value == null) return null;
  return DateTime.utc(
    value.year,
    value.month,
    value.day,
  ).difference(DateTime.utc(1970)).inDays;
}

DateTime? _utc(DateTime? value) {
  if (value == null) return null;
  return value.toUtc();
}

TaskStatus? _readStatus(String? value) => switch (value) {
  null => null,
  'needs_action' => TaskStatus.needsAction,
  'completed' => TaskStatus.completed,
  _ => throw const CacheInvariantException('unknown_task_status'),
};

TaskDate? _taskDate(int? epochDay) {
  if (epochDay == null) return null;
  final value = DateTime.utc(1970).add(Duration(days: epochDay));
  return TaskDate(value.year, value.month, value.day);
}

String _encodeLinks(List<TaskRemoteLinkRecord> links) => jsonEncode(
  links
      .map(
        (link) => <String, String?>{
          'type': link.type,
          'description': link.description,
          'link': link.link?.toString(),
        },
      )
      .toList(growable: false),
);

List<TaskRemoteLinkRecord> _decodeLinks(String encoded) {
  final Object? decoded;
  try {
    decoded = jsonDecode(encoded);
  } on FormatException {
    throw const CacheInvariantException('malformed_task_links');
  }
  if (decoded is! List<Object?>) {
    throw const CacheInvariantException('malformed_task_links');
  }
  return decoded
      .map((item) {
        if (item is! Map<String, Object?> ||
            item.keys.any(
              (key) =>
                  !const <String>{'type', 'description', 'link'}.contains(key),
            ) ||
            !_nullableString(item['type']) ||
            !_nullableString(item['description']) ||
            !_nullableString(item['link'])) {
          throw const CacheInvariantException('malformed_task_links');
        }
        return TaskRemoteLinkRecord(
          type: item['type'] as String?,
          description: item['description'] as String?,
          link: _readAbsoluteUri(item['link'] as String?, 'task_link'),
        );
      })
      .toList(growable: false);
}

bool _nullableString(Object? value) => value == null || value is String;

void _validateAbsoluteUri(Uri? value, String field) {
  if (value != null && (!value.isAbsolute || value.host.isEmpty)) {
    throw CacheInvariantException('invalid_$field');
  }
}

Uri? _readAbsoluteUri(String? value, String field) {
  if (value == null) return null;
  final parsed = Uri.tryParse(value);
  if (parsed == null || !parsed.isAbsolute || parsed.host.isEmpty) {
    throw CacheInvariantException('invalid_$field');
  }
  return parsed;
}
