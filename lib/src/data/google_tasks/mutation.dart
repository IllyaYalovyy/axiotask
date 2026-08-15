import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/failure.dart';
import 'dto.dart';

enum MutationCommitState { notCommitted, uncertain }

enum GoogleTasksErrorKind {
  authorization,
  quota,
  conditional,
  notFound,
  transient,
  permanent,
  stalePath,
  unknown,
}

enum MutationPathFreshness { current, possiblyStale }

final class GoogleTasksMutationError {
  const GoogleTasksMutationError({
    required this.failure,
    required this.kind,
    required this.commitState,
  });

  final Failure failure;
  final GoogleTasksErrorKind kind;
  final MutationCommitState commitState;
}

sealed class GoogleTasksMutationResult<T> {
  const GoogleTasksMutationResult();
}

final class CommittedMutation<T> extends GoogleTasksMutationResult<T> {
  const CommittedMutation(this.value);

  final T value;
}

final class RejectedMutation<T> extends GoogleTasksMutationResult<T> {
  const RejectedMutation(this.error);

  final GoogleTasksMutationError error;
}

final class UncertainMutation<T> extends GoogleTasksMutationResult<T> {
  const UncertainMutation(this.error);

  final GoogleTasksMutationError error;
}

final class GoogleTasksMutationCapabilities {
  const GoogleTasksMutationCapabilities({
    this.notesNullClearing = true,
    this.dueNullClearing = true,
  });

  final bool notesNullClearing;
  final bool dueNullClearing;
}

sealed class OptionalFieldWrite<T> {
  const OptionalFieldWrite();

  const factory OptionalFieldWrite.set(T value) = SetOptionalField<T>;
  const factory OptionalFieldWrite.clear() = ClearOptionalField<T>;
}

final class SetOptionalField<T> extends OptionalFieldWrite<T> {
  const SetOptionalField(this.value);

  final T value;
}

final class ClearOptionalField<T> extends OptionalFieldWrite<T> {
  const ClearOptionalField();
}

sealed class GoogleTasksMutationOperation<T> {
  const GoogleTasksMutationOperation();

  String get diagnosticName;
  MutationPathFreshness get pathFreshness => MutationPathFreshness.current;

  http.AbortableRequest toRequest({
    required Uri endpoint,
    required Future<void> abortTrigger,
    required GoogleTasksMutationCapabilities capabilities,
  });
}

final class CreateTaskListOperation
    extends GoogleTasksMutationOperation<RemoteTaskList> {
  const CreateTaskListOperation({required this.title});

  final String title;

  @override
  String get diagnosticName => 'createTaskList';

  @override
  http.AbortableRequest toRequest({
    required Uri endpoint,
    required Future<void> abortTrigger,
    required GoogleTasksMutationCapabilities capabilities,
  }) => _jsonRequest(
    endpoint: endpoint,
    method: 'POST',
    suffix: const <String>['users', '@me', 'lists'],
    body: <String, Object?>{'title': _validTitle(title, 'title')},
    abortTrigger: abortTrigger,
  );
}

final class RenameTaskListOperation
    extends GoogleTasksMutationOperation<RemoteTaskList> {
  const RenameTaskListOperation({
    required this.taskListId,
    required this.title,
  });

  final RemoteTaskListId taskListId;
  final String title;

  @override
  String get diagnosticName => 'renameTaskList';

  @override
  http.AbortableRequest toRequest({
    required Uri endpoint,
    required Future<void> abortTrigger,
    required GoogleTasksMutationCapabilities capabilities,
  }) => _jsonRequest(
    endpoint: endpoint,
    method: 'PATCH',
    suffix: <String>[
      'users',
      '@me',
      'lists',
      _validId(taskListId.value, 'taskListId'),
    ],
    body: <String, Object?>{'title': _validTitle(title, 'title')},
    abortTrigger: abortTrigger,
  );
}

final class DeleteTaskListOperation extends GoogleTasksMutationOperation<void> {
  const DeleteTaskListOperation(this.taskListId);

  final RemoteTaskListId taskListId;

  @override
  String get diagnosticName => 'deleteTaskList';

  @override
  http.AbortableRequest toRequest({
    required Uri endpoint,
    required Future<void> abortTrigger,
    required GoogleTasksMutationCapabilities capabilities,
  }) => _emptyRequest(
    endpoint: endpoint,
    method: 'DELETE',
    suffix: <String>[
      'users',
      '@me',
      'lists',
      _validId(taskListId.value, 'taskListId'),
    ],
    abortTrigger: abortTrigger,
  );
}

final class CreateTaskOperation
    extends GoogleTasksMutationOperation<RemoteTask> {
  const CreateTaskOperation({
    required this.taskListId,
    required this.title,
    required this.status,
    this.notes,
    this.due,
    this.parentId,
    this.previousId,
  });

  final RemoteTaskListId taskListId;
  final String title;
  final String? notes;
  final RemoteTaskStatus status;
  final RemoteDate? due;
  final RemoteTaskId? parentId;
  final RemoteTaskId? previousId;

  @override
  String get diagnosticName => 'createTask';

  @override
  http.AbortableRequest toRequest({
    required Uri endpoint,
    required Future<void> abortTrigger,
    required GoogleTasksMutationCapabilities capabilities,
  }) {
    final notes = this.notes;
    if (notes != null && notes.length > 8192) {
      throw ArgumentError.value(notes, 'notes', 'must not exceed 8192 chars');
    }
    return _jsonRequest(
      endpoint: endpoint,
      method: 'POST',
      suffix: <String>[
        'lists',
        _validId(taskListId.value, 'taskListId'),
        'tasks',
      ],
      query: <String, String>{
        if (parentId case final value?)
          'parent': _validId(value.value, 'parentId'),
        if (previousId case final value?)
          'previous': _validId(value.value, 'previousId'),
      },
      body: <String, Object?>{
        'title': _validTitle(title, 'title'),
        'notes': ?notes,
        'status': _status(status),
        if (due case final value?) 'due': _due(value),
      },
      abortTrigger: abortTrigger,
    );
  }
}

final class PatchTaskOperation
    extends GoogleTasksMutationOperation<RemoteTask> {
  const PatchTaskOperation({
    required this.taskListId,
    required this.taskId,
    required this.etag,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
  });

  final RemoteTaskListId taskListId;
  final RemoteTaskId taskId;
  final String etag;
  final String title;
  final OptionalFieldWrite<String> notes;
  final RemoteTaskStatus status;
  final OptionalFieldWrite<RemoteDate> due;

  @override
  String get diagnosticName => 'patchTask';

  @override
  http.AbortableRequest toRequest({
    required Uri endpoint,
    required Future<void> abortTrigger,
    required GoogleTasksMutationCapabilities capabilities,
  }) {
    final notesValue = switch (notes) {
      SetOptionalField<String>(:final value) when value.length <= 8192 => value,
      SetOptionalField<String>() => throw ArgumentError.value(
        notes,
        'notes',
        'must not exceed 8192 chars',
      ),
      ClearOptionalField<String>() when capabilities.notesNullClearing => null,
      ClearOptionalField<String>() => throw UnsupportedError(
        'Google Tasks notes clearing has not been admitted by live evidence.',
      ),
    };
    final dueValue = switch (due) {
      SetOptionalField<RemoteDate>(:final value) => _due(value),
      ClearOptionalField<RemoteDate>() when capabilities.dueNullClearing =>
        null,
      ClearOptionalField<RemoteDate>() => throw UnsupportedError(
        'Google Tasks due clearing has not been admitted by live evidence.',
      ),
    };
    return _jsonRequest(
      endpoint: endpoint,
      method: 'PATCH',
      suffix: <String>[
        'lists',
        _validId(taskListId.value, 'taskListId'),
        'tasks',
        _validId(taskId.value, 'taskId'),
      ],
      body: <String, Object?>{
        'title': _validTitle(title, 'title'),
        'notes': notesValue,
        'status': _status(status),
        'due': dueValue,
      },
      etag: _validEtag(etag),
      abortTrigger: abortTrigger,
    );
  }
}

final class DeleteTaskOperation extends GoogleTasksMutationOperation<void> {
  const DeleteTaskOperation({
    required this.taskListId,
    required this.taskId,
    required this.etag,
    required this.pathFreshness,
  });

  final RemoteTaskListId taskListId;
  final RemoteTaskId taskId;
  final String etag;

  @override
  final MutationPathFreshness pathFreshness;

  @override
  String get diagnosticName => 'deleteTask';

  @override
  http.AbortableRequest toRequest({
    required Uri endpoint,
    required Future<void> abortTrigger,
    required GoogleTasksMutationCapabilities capabilities,
  }) => _emptyRequest(
    endpoint: endpoint,
    method: 'DELETE',
    suffix: <String>[
      'lists',
      _validId(taskListId.value, 'taskListId'),
      'tasks',
      _validId(taskId.value, 'taskId'),
    ],
    etag: _validEtag(etag),
    abortTrigger: abortTrigger,
  );
}

final class MoveTaskOperation extends GoogleTasksMutationOperation<RemoteTask> {
  const MoveTaskOperation({
    required this.sourceTaskListId,
    required this.taskId,
    required this.etag,
    required this.pathFreshness,
    this.destinationTaskListId,
    this.parentId,
    this.previousId,
  });

  final RemoteTaskListId sourceTaskListId;
  final RemoteTaskId taskId;
  final String etag;
  final RemoteTaskListId? destinationTaskListId;
  final RemoteTaskId? parentId;
  final RemoteTaskId? previousId;

  @override
  final MutationPathFreshness pathFreshness;

  @override
  String get diagnosticName => 'moveTask';

  @override
  http.AbortableRequest toRequest({
    required Uri endpoint,
    required Future<void> abortTrigger,
    required GoogleTasksMutationCapabilities capabilities,
  }) => _emptyRequest(
    endpoint: endpoint,
    method: 'POST',
    suffix: <String>[
      'lists',
      _validId(sourceTaskListId.value, 'sourceTaskListId'),
      'tasks',
      _validId(taskId.value, 'taskId'),
      'move',
    ],
    query: <String, String>{
      if (destinationTaskListId case final value?)
        'destinationTasklist': _validId(value.value, 'destinationTaskListId'),
      if (parentId case final value?)
        'parent': _validId(value.value, 'parentId'),
      if (previousId case final value?)
        'previous': _validId(value.value, 'previousId'),
    },
    etag: _validEtag(etag),
    jsonContentType: true,
    abortTrigger: abortTrigger,
  );
}

http.AbortableRequest _jsonRequest({
  required Uri endpoint,
  required String method,
  required List<String> suffix,
  required Map<String, Object?> body,
  required Future<void> abortTrigger,
  Map<String, String> query = const <String, String>{},
  String? etag,
}) {
  final request = _request(
    endpoint: endpoint,
    method: method,
    suffix: suffix,
    query: query,
    etag: etag,
    abortTrigger: abortTrigger,
  );
  request.headers['content-type'] = 'application/json; charset=utf-8';
  request.body = jsonEncode(body);
  return request;
}

http.AbortableRequest _emptyRequest({
  required Uri endpoint,
  required String method,
  required List<String> suffix,
  required Future<void> abortTrigger,
  Map<String, String> query = const <String, String>{},
  String? etag,
  bool jsonContentType = false,
}) {
  final request = _request(
    endpoint: endpoint,
    method: method,
    suffix: suffix,
    query: query,
    etag: etag,
    abortTrigger: abortTrigger,
  );
  if (jsonContentType) {
    request.headers['content-type'] = 'application/json; charset=utf-8';
  }
  request.bodyBytes = const <int>[];
  return request;
}

http.AbortableRequest _request({
  required Uri endpoint,
  required String method,
  required List<String> suffix,
  required Map<String, String> query,
  required String? etag,
  required Future<void> abortTrigger,
}) {
  _validateEndpoint(endpoint);
  final uri = endpoint.replace(
    pathSegments: <String>[
      ...endpoint.pathSegments.where((part) => part.isNotEmpty),
      ...suffix,
    ],
    queryParameters: query.isEmpty ? null : query,
  );
  return http.AbortableRequest(method, uri, abortTrigger: abortTrigger)
    ..followRedirects = false
    ..headers['accept'] = 'application/json'
    ..headers.addAll(<String, String>{'if-match': ?etag});
}

void _validateEndpoint(Uri endpoint) {
  if (!endpoint.isAbsolute ||
      (endpoint.scheme != 'https' && endpoint.scheme != 'http') ||
      endpoint.host.isEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment) {
    throw ArgumentError.value(endpoint, 'endpoint', 'must be an HTTP base URI');
  }
}

String _validId(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return value;
}

String _validEtag(String value) {
  if (value.isEmpty || value.contains('\r') || value.contains('\n')) {
    throw ArgumentError.value(value, 'etag', 'must be a valid header value');
  }
  return value;
}

String _validTitle(String value, String name) {
  if (value.length > 1024) {
    throw ArgumentError.value(value, name, 'must not exceed 1024 chars');
  }
  return value;
}

String _status(RemoteTaskStatus status) => switch (status) {
  RemoteTaskStatus.needsAction => 'needsAction',
  RemoteTaskStatus.completed => 'completed',
};

String _due(RemoteDate value) {
  final parsed = DateTime.utc(value.year, value.month, value.day);
  if (parsed.year != value.year ||
      parsed.month != value.month ||
      parsed.day != value.day) {
    throw ArgumentError.value(value, 'due', 'must be a valid calendar date');
  }
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}T00:00:00.000Z';
}
