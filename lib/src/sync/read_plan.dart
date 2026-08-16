import 'dart:convert';

import '../core/failure.dart';
import '../data/google_tasks/dto.dart';

final class ReadPlanException implements Exception {
  const ReadPlanException(this.failure, {this.decodedScope});

  final Failure failure;
  final String? decodedScope;
}

final class TaskListReadPlan {
  final Set<String> _seen = <String>{};

  void validatePage(List<RemoteTaskList> items) {
    final pageIds = <String>{};
    for (final item in items) {
      _requireRemoteId(item.id.value, 'sync.malformed_task_list_id');
      _requireOptionalValue(item.etag, 'sync.malformed_task_list_etag');
      _requireAbsoluteUri(item.selfLink, 'sync.malformed_task_list_link');
      if (item.title.length > 1024) {
        throw ReadPlanException(_unsupported('sync.malformed_task_list_title'));
      }
      if (!pageIds.add(item.id.value) || _seen.contains(item.id.value)) {
        throw ReadPlanException(_unsupported('sync.duplicate_task_list'));
      }
    }
    _seen.addAll(pageIds);
  }
}

final class TaskScopeReadPlan {
  final Map<String, RemoteLiveTask> _live = <String, RemoteLiveTask>{};
  final Set<String> _seen = <String>{};
  final Set<String> _published = <String>{};
  final List<RemoteTask> _pending = <RemoteTask>[];

  List<RemoteTask> acceptPage(
    List<RemoteTask> items, {
    required bool terminal,
  }) {
    final pageIds = <String>{};
    for (final item in items) {
      _validateTask(item);
      if (!pageIds.add(item.id.value) || _seen.contains(item.id.value)) {
        throw ReadPlanException(
          _unsupported('sync.duplicate_task'),
          decodedScope: _encodeTasks(<RemoteTask>[..._live.values, item]),
        );
      }
      if (item case final RemoteLiveTask live) {
        _live[item.id.value] = live;
      }
    }
    _seen.addAll(pageIds);
    _pending.addAll(items);
    _validateKnownDepth();

    final ready = <RemoteTask>[];
    var advanced = true;
    while (advanced) {
      advanced = false;
      for (final task in List<RemoteTask>.of(_pending)) {
        final canPublish = switch (task) {
          RemoteTaskTombstone() => true,
          RemoteLiveTask(:final parentId) =>
            parentId == null || _published.contains(parentId.value),
        };
        if (!canPublish) continue;
        _pending.remove(task);
        ready.add(task);
        _published.add(task.id.value);
        advanced = true;
      }
    }
    if (terminal && _pending.isNotEmpty) {
      throw ReadPlanException(
        _unsupported('sync.unsupported_task_parent'),
        decodedScope: _encodeTasks(_pending),
      );
    }
    return ready;
  }

  void _validateKnownDepth() {
    for (final task in _live.values) {
      final parentId = task.parentId;
      if (parentId == null) continue;
      final parent = _live[parentId.value];
      if (parent?.parentId != null) {
        throw ReadPlanException(
          _unsupported('sync.unsupported_task_depth'),
          decodedScope: _encodeTasks(_live.values),
        );
      }
    }
  }

  void _validateTask(RemoteTask task) {
    try {
      _requireRemoteId(task.id.value, 'sync.malformed_task_id');
      _requireOptionalValue(task.etag, 'sync.malformed_task_etag');
      _requireAbsoluteUri(task.selfLink, 'sync.malformed_task_link');
      switch (task) {
        case RemoteLiveTask():
          if (task.title.length > 1024 || task.position.isEmpty) {
            throw ReadPlanException(_unsupported('sync.malformed_live_task'));
          }
          if (task.notes != null && task.notes!.length > 8192) {
            throw ReadPlanException(_unsupported('sync.malformed_task_notes'));
          }
          _requireAbsoluteUri(task.webViewLink, 'sync.malformed_web_view_link');
          for (final link in task.links) {
            _requireAbsoluteUri(link.link, 'sync.malformed_task_link');
          }
        case RemoteTaskTombstone():
          _requireOptionalValue(
            task.retainedPosition,
            'sync.malformed_tombstone_position',
          );
          _requireAbsoluteUri(
            task.retainedWebViewLink,
            'sync.malformed_tombstone_web_view_link',
          );
          for (final link in task.retainedLinks) {
            _requireAbsoluteUri(link.link, 'sync.malformed_tombstone_link');
          }
      }
    } on ReadPlanException catch (error) {
      throw ReadPlanException(
        error.failure,
        decodedScope: _encodeTasks(<RemoteTask>[task]),
      );
    }
  }
}

String _encodeTasks(Iterable<RemoteTask> tasks) => jsonEncode(
  tasks.map<Map<String, Object?>>(_taskEvidence).toList(growable: false),
);

Map<String, Object?> _taskEvidence(RemoteTask task) => <String, Object?>{
  'id': task.id.value,
  'etag': task.etag,
  'updated': task.updated?.toUtc().toIso8601String(),
  'selfLink': task.selfLink?.toString(),
  'deleted': task.deleted,
  switch (task) {
    RemoteLiveTask() => 'title',
    RemoteTaskTombstone() => 'retainedTitle',
  }: switch (task) {
    RemoteLiveTask(:final title) => title,
    RemoteTaskTombstone(:final retainedTitle) => retainedTitle,
  },
  'parent': switch (task) {
    RemoteLiveTask(:final parentId) => parentId?.value,
    RemoteTaskTombstone(:final retainedParentId) => retainedParentId?.value,
  },
  'position': switch (task) {
    RemoteLiveTask(:final position) => position,
    RemoteTaskTombstone(:final retainedPosition) => retainedPosition,
  },
  'notes': switch (task) {
    RemoteLiveTask(:final notes) => notes,
    RemoteTaskTombstone(:final retainedNotes) => retainedNotes,
  },
  'status': switch (task) {
    RemoteLiveTask(:final status) => status.name,
    RemoteTaskTombstone(:final retainedStatus) => retainedStatus?.name,
  },
  'due': switch (task) {
    RemoteLiveTask(:final due) => due?.toString(),
    RemoteTaskTombstone(:final retainedDue) => retainedDue?.toString(),
  },
  'completed': switch (task) {
    RemoteLiveTask(:final completed) => completed?.toUtc().toIso8601String(),
    RemoteTaskTombstone(:final retainedCompleted) =>
      retainedCompleted?.toUtc().toIso8601String(),
  },
  'hidden': switch (task) {
    RemoteLiveTask(:final hidden) => hidden,
    RemoteTaskTombstone(:final hidden) => hidden,
  },
  'links':
      switch (task) {
            RemoteLiveTask(:final links) => links,
            RemoteTaskTombstone(:final retainedLinks) => retainedLinks,
          }
          .map(
            (link) => <String, Object?>{
              'type': link.type,
              'description': link.description,
              'link': link.link?.toString(),
            },
          )
          .toList(growable: false),
  'webViewLink': switch (task) {
    RemoteLiveTask(:final webViewLink) => webViewLink?.toString(),
    RemoteTaskTombstone(:final retainedWebViewLink) =>
      retainedWebViewLink?.toString(),
  },
};

void _requireRemoteId(String value, String code) {
  if (value.isEmpty) throw ReadPlanException(_unsupported(code));
}

void _requireOptionalValue(String? value, String code) {
  if (value != null && value.isEmpty) {
    throw ReadPlanException(_unsupported(code));
  }
}

void _requireAbsoluteUri(Uri? value, String code) {
  if (value != null && (!value.isAbsolute || value.host.isEmpty)) {
    throw ReadPlanException(_unsupported(code));
  }
}

Failure _unsupported(String code) => Failure(
  code: code,
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks returned data this version cannot safely publish.',
  safeSummary: 'The affected Google Tasks scope was not published completely.',
);
