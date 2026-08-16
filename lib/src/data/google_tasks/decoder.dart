import 'dart:convert';

import '../../core/failure.dart';
import '../../core/outcome.dart';
import 'dto.dart';

final class GoogleTasksDecoder {
  const GoogleTasksDecoder();

  Outcome<RemoteTaskList> decodeTaskListReadResource(List<int> bytes) {
    try {
      return Outcome<RemoteTaskList>.success(_taskList(_decodeRoot(bytes)));
    } on _DecodeFailure catch (error) {
      return Outcome<RemoteTaskList>.failure(error.failure);
    } on FormatException {
      return Outcome<RemoteTaskList>.failure(_malformedSuccessFailure());
    }
  }

  Outcome<RemoteTaskList> decodeTaskListResource(List<int> bytes) {
    try {
      return Outcome<RemoteTaskList>.success(_taskList(_decodeRoot(bytes)));
    } on _DecodeFailure catch (error) {
      return Outcome<RemoteTaskList>.failure(_mutationDecodeFailure(error));
    } on FormatException {
      return Outcome<RemoteTaskList>.failure(_malformedMutationFailure());
    }
  }

  Outcome<RemoteTask> decodeTaskResource(List<int> bytes) {
    try {
      return Outcome<RemoteTask>.success(_task(_decodeRoot(bytes)));
    } on _DecodeFailure catch (error) {
      return Outcome<RemoteTask>.failure(_mutationDecodeFailure(error));
    } on FormatException {
      return Outcome<RemoteTask>.failure(_malformedMutationFailure());
    }
  }

  Outcome<RemotePage<RemoteTaskList>> decodeTaskListPage(List<int> bytes) {
    try {
      final root = _decodeRoot(bytes);
      _expectKind(root, 'tasks#taskLists');
      final rows = _items(root, maximum: 1000);
      final decoded = <RemoteTaskList>[];
      final ids = <String>{};
      for (final row in rows) {
        final resource = _taskList(row);
        if (!ids.add(resource.id.value)) {
          throw const _DecodeFailure(
            'google_tasks.duplicate_resource',
            'A Google Tasks page contains a duplicate resource identifier.',
          );
        }
        decoded.add(resource);
      }
      return Outcome<RemotePage<RemoteTaskList>>.success(
        RemotePage<RemoteTaskList>(
          items: decoded,
          collectionEtag: _optionalNonEmptyString(root, 'etag'),
          nextPageToken: _pageToken(root),
        ),
      );
    } on _DecodeFailure catch (error) {
      return Outcome<RemotePage<RemoteTaskList>>.failure(error.failure);
    } on FormatException {
      return Outcome<RemotePage<RemoteTaskList>>.failure(
        _malformedSuccessFailure(),
      );
    }
  }

  Outcome<RemotePage<RemoteTask>> decodeTaskPage(List<int> bytes) {
    try {
      final root = _decodeRoot(bytes);
      _expectKind(root, 'tasks#tasks');
      final rows = _items(root, maximum: 100);
      final decoded = <RemoteTask>[];
      final ids = <String>{};
      for (final row in rows) {
        final resource = _task(row);
        if (!ids.add(resource.id.value)) {
          throw const _DecodeFailure(
            'google_tasks.duplicate_resource',
            'A Google Tasks page contains a duplicate resource identifier.',
          );
        }
        decoded.add(resource);
      }
      return Outcome<RemotePage<RemoteTask>>.success(
        RemotePage<RemoteTask>(
          items: decoded,
          collectionEtag: _optionalNonEmptyString(root, 'etag'),
          nextPageToken: _pageToken(root),
        ),
      );
    } on _DecodeFailure catch (error) {
      return Outcome<RemotePage<RemoteTask>>.failure(error.failure);
    } on FormatException {
      return Outcome<RemotePage<RemoteTask>>.failure(
        _malformedSuccessFailure(),
      );
    }
  }

  Map<String, Object?> _decodeRoot(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map<String, Object?>) {
      throw const _DecodeFailure.malformed();
    }
    return decoded;
  }

  List<Map<String, Object?>> _items(
    Map<String, Object?> root, {
    required int maximum,
  }) {
    final value = root['items'];
    if (value == null && !root.containsKey('items')) {
      return const <Map<String, Object?>>[];
    }
    if (value is! List<Object?> || value.length > maximum) {
      throw const _DecodeFailure.malformed();
    }
    return value
        .map((row) {
          if (row is! Map<String, Object?>) {
            throw const _DecodeFailure.malformed();
          }
          return row;
        })
        .toList(growable: false);
  }

  RemoteTaskList _taskList(Map<String, Object?> row) {
    _expectKind(row, 'tasks#taskList');
    final title = _requiredString(row, 'title', allowEmpty: true);
    if (title.length > 1024) {
      throw const _DecodeFailure.malformed();
    }
    return RemoteTaskList(
      id: RemoteTaskListId(_requiredString(row, 'id')),
      etag: _optionalNonEmptyString(row, 'etag'),
      title: title,
      updated: _optionalTimestamp(row, 'updated'),
      selfLink: _optionalAbsoluteUri(row, 'selfLink'),
    );
  }

  RemoteTask _task(Map<String, Object?> row) {
    _expectKind(row, 'tasks#task');
    if (row.containsKey('assignmentInfo')) {
      throw const _DecodeFailure(
        'google_tasks.assigned_task_unsupported',
        'Google returned an assigned task that this client does not support.',
      );
    }

    final id = RemoteTaskId(_requiredString(row, 'id'));
    final etag = _optionalNonEmptyString(row, 'etag');
    final updated = _optionalTimestamp(row, 'updated');
    final selfLink = _optionalAbsoluteUri(row, 'selfLink');
    final deleted = _optionalBoolean(row, 'deleted') ?? false;
    final title = _optionalString(row, 'title');
    final notes = _optionalString(row, 'notes');
    if ((title?.length ?? 0) > 1024 || (notes?.length ?? 0) > 8192) {
      throw const _DecodeFailure.malformed();
    }
    final parent = _optionalNonEmptyString(row, 'parent');
    final position = _optionalNonEmptyString(row, 'position');
    final status = _optionalStatus(row);
    final due = _optionalDue(row);
    final completed = _optionalTimestamp(row, 'completed');
    final hidden = _optionalBoolean(row, 'hidden') ?? false;
    final links = _optionalLinks(row);
    final webViewLink = _optionalAbsoluteUri(row, 'webViewLink');

    if (deleted) {
      return RemoteTaskTombstone(
        id: id,
        etag: etag,
        updated: updated,
        selfLink: selfLink,
        retainedTitle: title,
        retainedParentId: parent == null ? null : RemoteTaskId(parent),
        retainedPosition: position,
        retainedNotes: notes,
        retainedStatus: status,
        retainedDue: due,
        retainedCompleted: completed,
        hidden: hidden,
        retainedLinks: links,
        retainedWebViewLink: webViewLink,
      );
    }

    if (title == null || position == null || status == null) {
      throw const _DecodeFailure.malformed();
    }
    return RemoteLiveTask(
      id: id,
      etag: etag,
      updated: updated,
      selfLink: selfLink,
      title: title,
      parentId: parent == null ? null : RemoteTaskId(parent),
      position: position,
      notes: notes,
      status: status,
      due: due,
      completed: completed,
      hidden: hidden,
      links: links,
      webViewLink: webViewLink,
    );
  }

  void _expectKind(Map<String, Object?> object, String expected) {
    if (object['kind'] != expected) {
      throw const _DecodeFailure(
        'google_tasks.unsupported_resource_kind',
        'Google returned an unsupported resource kind.',
      );
    }
  }

  PageToken? _pageToken(Map<String, Object?> root) {
    final value = _optionalNonEmptyString(root, 'nextPageToken');
    return value == null ? null : PageToken(value);
  }

  String _requiredString(
    Map<String, Object?> object,
    String key, {
    bool allowEmpty = false,
  }) {
    final value = object[key];
    if (value is! String || (!allowEmpty && value.isEmpty)) {
      throw const _DecodeFailure.malformed();
    }
    return value;
  }

  String? _optionalString(Map<String, Object?> object, String key) {
    if (!object.containsKey(key)) return null;
    final value = object[key];
    if (value is! String) throw const _DecodeFailure.malformed();
    return value;
  }

  String? _optionalNonEmptyString(Map<String, Object?> object, String key) {
    final value = _optionalString(object, key);
    if (value != null && value.isEmpty) {
      throw const _DecodeFailure.malformed();
    }
    return value;
  }

  bool? _optionalBoolean(Map<String, Object?> object, String key) {
    if (!object.containsKey(key)) return null;
    final value = object[key];
    if (value is! bool) throw const _DecodeFailure.malformed();
    return value;
  }

  DateTime? _optionalTimestamp(Map<String, Object?> object, String key) {
    final value = _optionalString(object, key);
    if (value == null) return null;
    if (!RegExp(r'(?:Z|[+-][0-9]{2}:[0-9]{2})$').hasMatch(value)) {
      throw const _DecodeFailure.malformed();
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) throw const _DecodeFailure.malformed();
    return parsed.toUtc();
  }

  Uri? _optionalAbsoluteUri(Map<String, Object?> object, String key) {
    final value = _optionalString(object, key);
    if (value == null) return null;
    final parsed = Uri.tryParse(value);
    if (parsed == null || !parsed.isAbsolute || parsed.host.isEmpty) {
      throw const _DecodeFailure.malformed();
    }
    return parsed;
  }

  RemoteTaskStatus? _optionalStatus(Map<String, Object?> row) {
    final value = _optionalString(row, 'status');
    return switch (value) {
      null => null,
      'needsAction' => RemoteTaskStatus.needsAction,
      'completed' => RemoteTaskStatus.completed,
      _ => throw const _DecodeFailure(
        'google_tasks.unsupported_task_status',
        'Google returned an unsupported task status.',
      ),
    };
  }

  RemoteDate? _optionalDue(Map<String, Object?> row) {
    final value = _optionalString(row, 'due');
    if (value == null) return null;
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T00:00:00\.000Z$',
    ).firstMatch(value);
    if (match == null) {
      throw const _DecodeFailure(
        'google_tasks.malformed_due',
        'Google returned a due value outside the supported date-only format.',
      );
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime.utc(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      throw const _DecodeFailure(
        'google_tasks.malformed_due',
        'Google returned an invalid due date.',
      );
    }
    return RemoteDate(year, month, day);
  }

  List<RemoteTaskLink> _optionalLinks(Map<String, Object?> row) {
    if (!row.containsKey('links')) return const <RemoteTaskLink>[];
    final value = row['links'];
    if (value is! List<Object?>) throw const _DecodeFailure.malformed();
    return value
        .map((entry) {
          if (entry is! Map<String, Object?>) {
            throw const _DecodeFailure.malformed();
          }
          return RemoteTaskLink(
            type: _optionalString(entry, 'type'),
            description: _optionalString(entry, 'description'),
            link: _optionalAbsoluteUri(entry, 'link'),
          );
        })
        .toList(growable: false);
  }
}

final class _DecodeFailure implements Exception {
  const _DecodeFailure(this.code, this.summary);

  const _DecodeFailure.malformed()
    : code = 'google_tasks.malformed_success',
      summary = 'Google returned malformed task data.';

  final String code;
  final String summary;

  Failure get failure => Failure(
    code: code,
    category: FailureCategory.unsupportedRemoteState,
    operation: FailureOperation.read,
    retry: RetryClassification.permanent,
    impact: 'Google Tasks data could not be read safely.',
    safeSummary: summary,
  );
}

Failure _malformedSuccessFailure() => const Failure(
  code: 'google_tasks.malformed_success',
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks data could not be read safely.',
  safeSummary: 'Google returned malformed task data.',
);

Failure _mutationDecodeFailure(_DecodeFailure error) => Failure(
  code: error.code,
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'A Google Tasks mutation could not be confirmed safely.',
  safeSummary: error.summary,
);

Failure _malformedMutationFailure() => const Failure(
  code: 'google_tasks.malformed_mutation_success',
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'A Google Tasks mutation could not be confirmed safely.',
  safeSummary: 'Google returned a malformed Tasks mutation response.',
);
