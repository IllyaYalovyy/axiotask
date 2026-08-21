import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:http/http.dart' as http;

import 'barriers.dart';

enum FakeGoogleTasksMethod {
  listTaskLists,
  getTaskList,
  listTasks,
  createTaskList,
  renameTaskList,
  deleteTaskList,
  createTask,
  patchTask,
  deleteTask,
  moveTask,
}

final class FakeGoogleTasksCall {
  FakeGoogleTasksCall({
    required this.operation,
    required this.method,
    required this.path,
    Map<String, String> query = const <String, String>{},
    Map<String, String> headers = const <String, String>{},
    Map<String, Object?>? body,
  }) : query = Map<String, String>.unmodifiable(query),
       headers = Map<String, String>.unmodifiable(headers),
       body = body == null ? null : Map<String, Object?>.unmodifiable(body);

  final FakeGoogleTasksMethod operation;
  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final Map<String, Object?>? body;
}

/// A strict deterministic model of only the Google Tasks behavior admitted by
/// docs/GOOGLE_TASKS_API_CONTRACT.md. It is test support, not sync policy.
final class FakeGoogleTasksService
    implements GoogleTasksService, GoogleTasksRecoveryService {
  FakeGoogleTasksService({this.taskListPageSize = 2, this.taskPageSize = 2}) {
    if (taskListPageSize <= 0 || taskListPageSize > 1000) {
      throw ArgumentError.value(taskListPageSize, 'taskListPageSize');
    }
    if (taskPageSize <= 0 || taskPageSize > 100) {
      throw ArgumentError.value(taskPageSize, 'taskPageSize');
    }
  }

  final int taskListPageSize;
  final int taskPageSize;
  final LinkedHashMap<String, _FakeTaskListState> _lists = LinkedHashMap();
  final List<FakeGoogleTasksCall> _calls = <FakeGoogleTasksCall>[];
  final Set<String> _issuedPageTokens = <String>{};
  var _nextList = 1;
  var _nextTask = 1;
  var _listCollectionRevision = 0;
  var _tick = 0;
  var _closed = false;

  List<FakeGoogleTasksCall> get calls =>
      List<FakeGoogleTasksCall>.unmodifiable(_calls);

  int get taskCount =>
      _lists.values.fold<int>(0, (count, list) => count + list.tasks.length);

  int callCount(FakeGoogleTasksMethod operation) =>
      _calls.where((call) => call.operation == operation).length;

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.listTaskLists,
        method: 'GET',
        path: '/tasks/v1/users/@me/lists',
        query: <String, String>{
          'maxResults': '1000',
          if (pageToken != null) 'pageToken': pageToken.value,
        },
      ),
    );
    final unavailable = _readUnavailable<RemoteTaskList>(cancellation);
    if (unavailable != null) return unavailable;
    final offset = _pageOffset(pageToken, 'lists');
    if (offset == null) return Outcome.failure(_invalidPageFailure());
    final resources = _lists.values.map(_taskListDto).toList(growable: false);
    if (offset > resources.length) {
      return Outcome.failure(_invalidPageFailure());
    }
    final end = (offset + taskListPageSize).clamp(0, resources.length);
    return Outcome.success(
      RemotePage<RemoteTaskList>(
        items: resources.sublist(offset, end),
        collectionEtag: 'fake-task-lists-v$_listCollectionRevision',
        nextPageToken: _nextPageToken('lists', end, end < resources.length),
      ),
    );
  }

  @override
  Future<Outcome<RemoteTaskList?>> getTaskList(
    RemoteTaskListId taskListId, {
    GoogleTasksReadCancellation? cancellation,
  }) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.getTaskList,
        method: 'GET',
        path: '/tasks/v1/users/@me/lists/${_path(taskListId.value)}',
      ),
    );
    final unavailable = _readUnavailable<RemoteTaskList>(cancellation);
    if (unavailable case Failed<RemotePage<RemoteTaskList>>(:final failure)) {
      return Outcome<RemoteTaskList?>.failure(failure);
    }
    final list = _lists[taskListId.value];
    return Outcome<RemoteTaskList?>.success(
      list == null ? null : _taskListDto(list),
    );
  }

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.listTasks,
        method: 'GET',
        path: '/tasks/v1/lists/${_path(taskListId.value)}/tasks',
        query: <String, String>{
          'maxResults': '100',
          if (pageToken != null) 'pageToken': pageToken.value,
          'showCompleted': 'true',
          'showHidden': 'true',
          'showDeleted': 'true',
          'showAssigned': 'false',
        },
      ),
    );
    final unavailable = _readUnavailable<RemoteTask>(cancellation);
    if (unavailable != null) return unavailable;
    final list = _lists[taskListId.value];
    if (list == null) return Outcome.failure(_readNotFoundFailure());
    final offset = _pageOffset(pageToken, 'tasks:${taskListId.value}');
    if (offset == null) return Outcome.failure(_invalidPageFailure());
    final resources = _canonicalTasks(
      list,
    ).map(_taskDto).toList(growable: false);
    if (offset > resources.length) {
      return Outcome.failure(_invalidPageFailure());
    }
    final end = (offset + taskPageSize).clamp(0, resources.length);
    return Outcome.success(
      RemotePage<RemoteTask>(
        items: resources.sublist(offset, end),
        collectionEtag: 'fake-tasks-${list.id}-v${list.collectionRevision}',
        nextPageToken: _nextPageToken(
          'tasks:${taskListId.value}',
          end,
          end < resources.length,
        ),
      ),
    );
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.createTaskList,
        method: 'POST',
        path: '/tasks/v1/users/@me/lists',
        body: <String, Object?>{'title': operation.title},
      ),
    );
    final unavailable = _mutationUnavailable<RemoteTaskList>();
    if (unavailable != null) return unavailable;
    if (operation.title.length > 1024) return _invalidMutation();
    final id = 'list-${_nextList++}';
    final state = _FakeTaskListState(
      id: id,
      title: operation.title,
      revision: 1,
      updated: _now(),
    );
    _lists[id] = state;
    _listCollectionRevision += 1;
    return CommittedMutation<RemoteTaskList>(_taskListDto(state));
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.renameTaskList,
        method: 'PATCH',
        path: '/tasks/v1/users/@me/lists/${_path(operation.taskListId.value)}',
        body: <String, Object?>{'title': operation.title},
      ),
    );
    final unavailable = _mutationUnavailable<RemoteTaskList>();
    if (unavailable != null) return unavailable;
    final state = _lists[operation.taskListId.value];
    if (state == null) return _notFoundMutation();
    if (operation.title.length > 1024) return _invalidMutation();
    state
      ..title = operation.title
      ..revision += 1
      ..updated = _now();
    _listCollectionRevision += 1;
    return CommittedMutation<RemoteTaskList>(_taskListDto(state));
  }

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.deleteTaskList,
        method: 'DELETE',
        path: '/tasks/v1/users/@me/lists/${_path(operation.taskListId.value)}',
      ),
    );
    final unavailable = _mutationUnavailable<void>();
    if (unavailable != null) return unavailable;
    if (_lists.remove(operation.taskListId.value) != null) {
      _listCollectionRevision += 1;
    }
    return const CommittedMutation<void>(null);
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.createTask,
        method: 'POST',
        path: '/tasks/v1/lists/${_path(operation.taskListId.value)}/tasks',
        query: <String, String>{
          if (operation.parentId != null) 'parent': operation.parentId!.value,
          if (operation.previousId != null)
            'previous': operation.previousId!.value,
        },
        body: <String, Object?>{
          'title': operation.title,
          if (operation.notes != null) 'notes': operation.notes,
          'status': operation.status.name,
          if (operation.due != null) 'due': _due(operation.due!),
        },
      ),
    );
    final unavailable = _mutationUnavailable<RemoteTask>();
    if (unavailable != null) return unavailable;
    final list = _lists[operation.taskListId.value];
    if (list == null) return _notFoundMutation();
    if (!_validContent(operation.title, operation.notes) ||
        !_validDate(operation.due)) {
      return _invalidMutation();
    }
    final parent = operation.parentId == null
        ? null
        : list.tasks[operation.parentId!.value];
    if (operation.parentId != null && (parent == null || parent.deleted)) {
      return _notFoundMutation();
    }
    if (parent?.parentId != null) return _invalidMutation();
    final siblings = _siblings(list, operation.parentId?.value);
    final insertion = _insertionIndex(siblings, operation.previousId);
    if (insertion == null) return _invalidMutation();
    final id = 'task-${_nextTask++}';
    final forcedCompleted = parent?.status == RemoteTaskStatus.completed;
    final state = _FakeTaskState(
      id: id,
      title: operation.title,
      notes: operation.notes,
      status: forcedCompleted ? RemoteTaskStatus.completed : operation.status,
      due: operation.due,
      parentId: operation.parentId?.value,
      position: '',
      revision: 1,
      updated: _now(),
      completed:
          forcedCompleted || operation.status == RemoteTaskStatus.completed
          ? _peekNow()
          : null,
      createdSequence: _nextTask,
    );
    list.tasks[id] = state;
    siblings.insert(insertion, state);
    _assignPositions(siblings);
    list.collectionRevision += 1;
    return CommittedMutation<RemoteTask>(_taskDto(state));
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.patchTask,
        method: 'PATCH',
        path:
            '/tasks/v1/lists/${_path(operation.taskListId.value)}/tasks/'
            '${_path(operation.taskId.value)}',
        headers: <String, String>{'if-match': operation.etag},
        body: <String, Object?>{
          'title': operation.title,
          'notes': switch (operation.notes) {
            SetOptionalField<String>(:final value) => value,
            ClearOptionalField<String>() => null,
          },
          'status': operation.status.name,
          'due': switch (operation.due) {
            SetOptionalField<RemoteDate>(:final value) => _due(value),
            ClearOptionalField<RemoteDate>() => null,
          },
        },
      ),
    );
    final unavailable = _mutationUnavailable<RemoteTask>();
    if (unavailable != null) return unavailable;
    final list = _lists[operation.taskListId.value];
    final state = list?.tasks[operation.taskId.value];
    if (list == null || state == null) return _notFoundMutation();
    if (state.etag != operation.etag) return _conditionalMutation();
    final notes = switch (operation.notes) {
      SetOptionalField<String>(:final value) => value,
      ClearOptionalField<String>() => null,
    };
    final due = switch (operation.due) {
      SetOptionalField<RemoteDate>(:final value) => value,
      ClearOptionalField<RemoteDate>() => null,
    };
    if (!_validContent(operation.title, notes) || !_validDate(due)) {
      return _invalidMutation();
    }
    final parent = state.parentId == null ? null : list.tasks[state.parentId];
    final requestedStatus = parent?.status == RemoteTaskStatus.completed
        ? RemoteTaskStatus.completed
        : operation.status;
    state
      ..title = operation.title
      ..notes = notes
      ..due = due
      ..status = requestedStatus
      ..completed = requestedStatus == RemoteTaskStatus.completed
          ? state.completed ?? _now()
          : null
      ..revision += 1
      ..updated = _now();
    if (requestedStatus == RemoteTaskStatus.completed) {
      _completeDescendants(list, state.id);
    }
    list.collectionRevision += 1;
    return CommittedMutation<RemoteTask>(_taskDto(state));
  }

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.deleteTask,
        method: 'DELETE',
        path:
            '/tasks/v1/lists/${_path(operation.taskListId.value)}/tasks/'
            '${_path(operation.taskId.value)}',
        headers: <String, String>{'if-match': operation.etag},
      ),
    );
    final unavailable = _mutationUnavailable<void>();
    if (unavailable != null) return unavailable;
    if (operation.pathFreshness == MutationPathFreshness.possiblyStale) {
      return _stalePathMutation();
    }
    final list = _lists[operation.taskListId.value];
    final state = list?.tasks[operation.taskId.value];
    if (list == null || state == null) return _notFoundMutation();
    if (state.etag != operation.etag) return _conditionalMutation();
    if (state.deleted) return const CommittedMutation<void>(null);
    for (final task in <_FakeTaskState>[
      state,
      ..._descendants(list, state.id),
    ]) {
      task
        ..deleted = true
        ..parentId = null
        ..revision += 1
        ..updated = _now();
    }
    list.collectionRevision += 1;
    return const CommittedMutation<void>(null);
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) async {
    _record(
      FakeGoogleTasksCall(
        operation: FakeGoogleTasksMethod.moveTask,
        method: 'POST',
        path:
            '/tasks/v1/lists/${_path(operation.sourceTaskListId.value)}/tasks/'
            '${_path(operation.taskId.value)}/move',
        query: <String, String>{
          if (operation.destinationTaskListId != null)
            'destinationTasklist': operation.destinationTaskListId!.value,
          if (operation.parentId != null) 'parent': operation.parentId!.value,
          if (operation.previousId != null)
            'previous': operation.previousId!.value,
        },
        headers: <String, String>{'if-match': operation.etag},
      ),
    );
    final unavailable = _mutationUnavailable<RemoteTask>();
    if (unavailable != null) return unavailable;
    if (operation.pathFreshness == MutationPathFreshness.possiblyStale) {
      return _stalePathMutation();
    }
    final source = _lists[operation.sourceTaskListId.value];
    final state = source?.tasks[operation.taskId.value];
    if (source == null || state == null || state.deleted) {
      return _notFoundMutation();
    }
    if (state.etag != operation.etag) return _conditionalMutation();
    final destinationId =
        operation.destinationTaskListId?.value ??
        operation.sourceTaskListId.value;
    final destination = _lists[destinationId];
    if (destination == null) return _notFoundMutation();
    final movingIds = <String>{
      state.id,
      ..._descendants(source, state.id).map((task) => task.id),
    };
    final parent = operation.parentId == null
        ? null
        : destination.tasks[operation.parentId!.value];
    if (operation.parentId != null &&
        (parent == null || parent.deleted || movingIds.contains(parent.id))) {
      return _notFoundMutation();
    }
    if (parent?.parentId != null) return _invalidMutation();
    final siblings = _siblings(
      destination,
      operation.parentId?.value,
      excluding: movingIds,
    );
    final insertion = _insertionIndex(siblings, operation.previousId);
    if (insertion == null) return _invalidMutation();

    if (!identical(source, destination)) {
      final moving = <_FakeTaskState>[state, ..._descendants(source, state.id)];
      for (final task in moving) {
        source.tasks.remove(task.id);
        destination.tasks[task.id] = task;
      }
      source.collectionRevision += 1;
    }
    state.parentId = operation.parentId?.value;
    siblings.insert(insertion, state);
    _assignPositions(siblings);
    if (parent?.status == RemoteTaskStatus.completed) {
      state
        ..status = RemoteTaskStatus.completed
        ..completed ??= _now();
      _completeDescendants(destination, state.id);
    }
    state
      ..revision += 1
      ..updated = _now();
    destination.collectionRevision += 1;
    return CommittedMutation<RemoteTask>(_taskDto(state));
  }

  Outcome<RemotePage<T>>? _readUnavailable<T>(
    GoogleTasksReadCancellation? cancellation,
  ) {
    if (_closed) return Outcome.failure(_closedFailure(FailureOperation.read));
    if (cancellation?.isCancelled ?? false) {
      return Outcome.failure(_cancelledFailure());
    }
    return null;
  }

  GoogleTasksMutationResult<T>? _mutationUnavailable<T>() => _closed
      ? RejectedMutation<T>(
          _mutationError(
            status: HttpStatus.badRequest,
            code: 'fake_google_tasks.closed',
            kind: GoogleTasksErrorKind.permanent,
          ),
        )
      : null;

  void _record(FakeGoogleTasksCall call) => _calls.add(call);

  DateTime _now() =>
      DateTime.utc(2026, 8, 15, 12).add(Duration(seconds: ++_tick));

  DateTime _peekNow() =>
      DateTime.utc(2026, 8, 15, 12).add(Duration(seconds: _tick));

  int? _pageOffset(PageToken? token, String scope) {
    if (token == null) return 0;
    final prefix = 'fake:$scope:';
    if (!_issuedPageTokens.contains(token.value) ||
        !token.value.startsWith(prefix)) {
      return null;
    }
    final parsed = int.tryParse(token.value.substring(prefix.length));
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  PageToken? _nextPageToken(String scope, int offset, bool hasNextPage) {
    if (!hasNextPage) return null;
    final value = 'fake:$scope:$offset';
    _issuedPageTokens.add(value);
    return PageToken(value);
  }

  List<_FakeTaskState> _canonicalTasks(_FakeTaskListState list) {
    final result = <_FakeTaskState>[];
    final liveTop = _siblings(list, null);
    for (final parent in liveTop) {
      result.add(parent);
      result.addAll(_siblings(list, parent.id));
    }
    final included = result.map((task) => task.id).toSet();
    final remainder =
        list.tasks.values.where((task) => !included.contains(task.id)).toList()
          ..sort((a, b) => a.createdSequence.compareTo(b.createdSequence));
    result.addAll(remainder);
    return result;
  }

  List<_FakeTaskState> _siblings(
    _FakeTaskListState list,
    String? parentId, {
    Set<String> excluding = const <String>{},
  }) =>
      list.tasks.values
          .where(
            (task) =>
                !task.deleted &&
                task.parentId == parentId &&
                !excluding.contains(task.id),
          )
          .toList()
        ..sort((a, b) => a.position.compareTo(b.position));

  int? _insertionIndex(List<_FakeTaskState> siblings, RemoteTaskId? previous) {
    if (previous == null) return 0;
    final index = siblings.indexWhere((task) => task.id == previous.value);
    return index < 0 ? null : index + 1;
  }

  void _assignPositions(List<_FakeTaskState> siblings) {
    for (var index = 0; index < siblings.length; index += 1) {
      siblings[index].position = (index + 1).toString().padLeft(8, '0');
    }
  }

  Iterable<_FakeTaskState> _descendants(
    _FakeTaskListState list,
    String parentId,
  ) sync* {
    for (final child in list.tasks.values.where(
      (task) => !task.deleted && task.parentId == parentId,
    )) {
      yield child;
      yield* _descendants(list, child.id);
    }
  }

  void _completeDescendants(_FakeTaskListState list, String parentId) {
    for (final task in _descendants(list, parentId)) {
      if (task.status != RemoteTaskStatus.completed) {
        task
          ..status = RemoteTaskStatus.completed
          ..completed = _now()
          ..revision += 1
          ..updated = _now();
      }
    }
  }

  RemoteTaskList _taskListDto(_FakeTaskListState state) => RemoteTaskList(
    id: RemoteTaskListId(state.id),
    etag: state.etag,
    title: state.title,
    updated: state.updated,
    selfLink: null,
  );

  RemoteTask _taskDto(_FakeTaskState state) {
    if (state.deleted) {
      return RemoteTaskTombstone(
        id: RemoteTaskId(state.id),
        etag: state.etag,
        updated: state.updated,
        selfLink: null,
        retainedTitle: state.title,
        retainedParentId: state.parentId == null
            ? null
            : RemoteTaskId(state.parentId!),
        retainedPosition: state.position,
        retainedNotes: state.notes,
        retainedStatus: state.status,
        retainedDue: state.due,
        retainedCompleted: state.completed,
        hidden: state.hidden,
        retainedLinks: const <RemoteTaskLink>[],
        retainedWebViewLink: null,
      );
    }
    return RemoteLiveTask(
      id: RemoteTaskId(state.id),
      etag: state.etag,
      updated: state.updated,
      selfLink: null,
      title: state.title,
      parentId: state.parentId == null ? null : RemoteTaskId(state.parentId!),
      position: state.position,
      notes: state.notes,
      status: state.status,
      due: state.due,
      completed: state.completed,
      hidden: state.hidden,
      links: const <RemoteTaskLink>[],
      webViewLink: null,
    );
  }

  bool _validContent(String title, String? notes) =>
      title.length <= 1024 && (notes?.length ?? 0) <= 8192;

  bool _validDate(RemoteDate? value) {
    if (value == null) return true;
    final parsed = DateTime.utc(value.year, value.month, value.day);
    return parsed.year == value.year &&
        parsed.month == value.month &&
        parsed.day == value.day;
  }

  @override
  void close() => _closed = true;
}

final class FakeGoogleTasksHttpClient extends http.BaseClient {
  FakeGoogleTasksHttpClient(
    this.backend, {
    this.barriers,
    this.responseChunkSize,
  }) {
    if (responseChunkSize != null && responseChunkSize! <= 0) {
      throw ArgumentError.value(responseChunkSize, 'responseChunkSize');
    }
  }

  static final Uri endpoint = Uri.parse(
    'https://fake.googleapis.test/tasks/v1/',
  );

  final FakeGoogleTasksService backend;
  final DeterministicBarriers? barriers;
  final int? responseChunkSize;
  var _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('fake client is closed');
    final bodyBytes = await request.finalize().toBytes();
    if (request.url.scheme != endpoint.scheme ||
        request.url.host != endpoint.host ||
        request.url.port != endpoint.port) {
      return _error(HttpStatus.notFound);
    }
    final segments = request.url.pathSegments;
    if (segments.length < 3 || segments[0] != 'tasks' || segments[1] != 'v1') {
      return _error(HttpStatus.notFound);
    }
    final operation = _operationFor(request, segments);
    if (operation != null) {
      await _cross(
        BarrierPoint.beforeRequestDispatch,
        operation,
        request.url.path,
      );
    }
    late http.StreamedResponse response;
    try {
      response = await _route(request, segments, bodyBytes);
    } on FormatException {
      response = _error(HttpStatus.badRequest);
    } on ArgumentError {
      response = _error(HttpStatus.badRequest);
    }
    return operation == null
        ? response
        : _controlResponse(response, operation, request.url.path);
  }

  Future<http.StreamedResponse> _route(
    http.BaseRequest request,
    List<String> segments,
    List<int> bodyBytes,
  ) async {
    if (_matches(segments, <String>['tasks', 'v1', 'users', '@me', 'lists'])) {
      return switch (request.method) {
        'GET' => _listTaskLists(request),
        'POST' => _createTaskList(request, bodyBytes),
        _ => _error(HttpStatus.methodNotAllowed),
      };
    }
    if (segments.length == 6 &&
        _matches(segments.take(5).toList(), <String>[
          'tasks',
          'v1',
          'users',
          '@me',
          'lists',
        ])) {
      return switch (request.method) {
        'GET' => _getTaskList(request, segments[5]),
        'PATCH' => _renameTaskList(request, segments[5], bodyBytes),
        'DELETE' => _deleteTaskList(request, segments[5], bodyBytes),
        _ => _error(HttpStatus.methodNotAllowed),
      };
    }
    if (segments.length == 5 &&
        segments[0] == 'tasks' &&
        segments[1] == 'v1' &&
        segments[2] == 'lists' &&
        segments[4] == 'tasks') {
      return switch (request.method) {
        'GET' => _listTasks(request, segments[3]),
        'POST' => _createTask(request, segments[3], bodyBytes),
        _ => _error(HttpStatus.methodNotAllowed),
      };
    }
    if (segments.length == 6 &&
        segments[0] == 'tasks' &&
        segments[1] == 'v1' &&
        segments[2] == 'lists' &&
        segments[4] == 'tasks') {
      return switch (request.method) {
        'PATCH' => _patchTask(request, segments[3], segments[5], bodyBytes),
        'DELETE' => _deleteTask(request, segments[3], segments[5], bodyBytes),
        _ => _error(HttpStatus.methodNotAllowed),
      };
    }
    if (segments.length == 7 &&
        segments[0] == 'tasks' &&
        segments[1] == 'v1' &&
        segments[2] == 'lists' &&
        segments[4] == 'tasks' &&
        segments[6] == 'move') {
      return request.method == 'POST'
          ? _moveTask(request, segments[3], segments[5], bodyBytes)
          : _error(HttpStatus.methodNotAllowed);
    }
    return _error(HttpStatus.notFound);
  }

  FakeGoogleTasksMethod? _operationFor(
    http.BaseRequest request,
    List<String> segments,
  ) {
    if (_matches(segments, const <String>[
      'tasks',
      'v1',
      'users',
      '@me',
      'lists',
    ])) {
      return switch (request.method) {
        'GET' => FakeGoogleTasksMethod.listTaskLists,
        'POST' => FakeGoogleTasksMethod.createTaskList,
        _ => null,
      };
    }
    if (segments.length == 6 &&
        _matches(segments.take(5).toList(), const <String>[
          'tasks',
          'v1',
          'users',
          '@me',
          'lists',
        ])) {
      return switch (request.method) {
        'GET' => FakeGoogleTasksMethod.getTaskList,
        'PATCH' => FakeGoogleTasksMethod.renameTaskList,
        'DELETE' => FakeGoogleTasksMethod.deleteTaskList,
        _ => null,
      };
    }
    if (segments.length == 5 &&
        segments[2] == 'lists' &&
        segments[4] == 'tasks') {
      return switch (request.method) {
        'GET' => FakeGoogleTasksMethod.listTasks,
        'POST' => FakeGoogleTasksMethod.createTask,
        _ => null,
      };
    }
    if (segments.length == 6 &&
        segments[2] == 'lists' &&
        segments[4] == 'tasks') {
      return switch (request.method) {
        'PATCH' => FakeGoogleTasksMethod.patchTask,
        'DELETE' => FakeGoogleTasksMethod.deleteTask,
        _ => null,
      };
    }
    if (segments.length == 7 &&
        segments[2] == 'lists' &&
        segments[4] == 'tasks' &&
        segments[6] == 'move' &&
        request.method == 'POST') {
      return FakeGoogleTasksMethod.moveTask;
    }
    return null;
  }

  Future<http.StreamedResponse> _listTaskLists(http.BaseRequest request) async {
    if (!_queryMatches(
      request.url.queryParameters,
      required: const <String, String>{'maxResults': '1000'},
      optional: const <String>{'pageToken'},
    )) {
      return _error(HttpStatus.badRequest);
    }
    final result = await backend.listTaskLists(
      pageToken: _pageToken(request.url.queryParameters['pageToken']),
    );
    return _readPageResponse(result, _taskListJson, 'tasks#taskLists');
  }

  Future<http.StreamedResponse> _getTaskList(
    http.BaseRequest request,
    String listId,
  ) async {
    if (request.url.queryParameters.isNotEmpty) {
      return _error(HttpStatus.badRequest);
    }
    return switch (await backend.getTaskList(RemoteTaskListId(listId))) {
      Success<RemoteTaskList?>(value: final value?) => _jsonResponse(
        HttpStatus.ok,
        _taskListJson(value),
      ),
      Success<RemoteTaskList?>(value: null) => _error(HttpStatus.notFound),
      Failed<RemoteTaskList?>(:final failure) => _failureResponse(failure),
    };
  }

  Future<http.StreamedResponse> _listTasks(
    http.BaseRequest request,
    String listId,
  ) async {
    if (!_queryMatches(
      request.url.queryParameters,
      required: const <String, String>{
        'maxResults': '100',
        'showCompleted': 'true',
        'showHidden': 'true',
        'showDeleted': 'true',
        'showAssigned': 'false',
      },
      optional: const <String>{'pageToken'},
    )) {
      return _error(HttpStatus.badRequest);
    }
    final result = await backend.listTasks(
      RemoteTaskListId(listId),
      pageToken: _pageToken(request.url.queryParameters['pageToken']),
    );
    return _readPageResponse(result, _taskJson, 'tasks#tasks');
  }

  Future<http.StreamedResponse> _createTaskList(
    http.BaseRequest request,
    List<int> bytes,
  ) async {
    if (request.url.hasQuery || !_isJson(request) || bytes.isEmpty) {
      return _error(HttpStatus.badRequest);
    }
    final body = _jsonObject(bytes);
    if (!_keys(body, const <String>{'title'}) || body['title'] is! String) {
      return _error(HttpStatus.badRequest);
    }
    return _mutationResponse(
      await backend.createTaskList(
        CreateTaskListOperation(title: body['title']! as String),
      ),
      _taskListJson,
      FakeGoogleTasksMethod.createTaskList,
      request.url.path,
    );
  }

  Future<http.StreamedResponse> _renameTaskList(
    http.BaseRequest request,
    String listId,
    List<int> bytes,
  ) async {
    if (request.url.hasQuery || !_isJson(request) || bytes.isEmpty) {
      return _error(HttpStatus.badRequest);
    }
    final body = _jsonObject(bytes);
    if (!_keys(body, const <String>{'title'}) || body['title'] is! String) {
      return _error(HttpStatus.badRequest);
    }
    return _mutationResponse(
      await backend.renameTaskList(
        RenameTaskListOperation(
          taskListId: RemoteTaskListId(listId),
          title: body['title']! as String,
        ),
      ),
      _taskListJson,
      FakeGoogleTasksMethod.renameTaskList,
      request.url.path,
    );
  }

  Future<http.StreamedResponse> _deleteTaskList(
    http.BaseRequest request,
    String listId,
    List<int> bytes,
  ) async {
    if (request.url.hasQuery || bytes.isNotEmpty) {
      return _error(HttpStatus.badRequest);
    }
    return _emptyMutationResponse(
      await backend.deleteTaskList(
        DeleteTaskListOperation(RemoteTaskListId(listId)),
      ),
      FakeGoogleTasksMethod.deleteTaskList,
      request.url.path,
    );
  }

  Future<http.StreamedResponse> _createTask(
    http.BaseRequest request,
    String listId,
    List<int> bytes,
  ) async {
    if (!_queryMatches(
          request.url.queryParameters,
          required: const <String, String>{},
          optional: const <String>{'parent', 'previous'},
        ) ||
        !_isJson(request) ||
        bytes.isEmpty) {
      return _error(HttpStatus.badRequest);
    }
    final body = _jsonObject(bytes);
    if (!_keys(
          body,
          const <String>{'title', 'status'},
          optional: const <String>{'notes', 'due'},
        ) ||
        body['title'] is! String) {
      return _error(HttpStatus.badRequest);
    }
    final status = _status(body['status']);
    final notes = body['notes'];
    if (notes != null && notes is! String) return _error(HttpStatus.badRequest);
    final due = body.containsKey('due') ? _remoteDate(body['due']) : null;
    return _mutationResponse(
      await backend.createTask(
        CreateTaskOperation(
          taskListId: RemoteTaskListId(listId),
          title: body['title']! as String,
          notes: notes as String?,
          status: status,
          due: due,
          parentId: _taskId(request.url.queryParameters['parent']),
          previousId: _taskId(request.url.queryParameters['previous']),
        ),
      ),
      _taskJson,
      FakeGoogleTasksMethod.createTask,
      request.url.path,
    );
  }

  Future<http.StreamedResponse> _patchTask(
    http.BaseRequest request,
    String listId,
    String taskId,
    List<int> bytes,
  ) async {
    if (request.url.hasQuery || !_isJson(request) || bytes.isEmpty) {
      return _error(HttpStatus.badRequest);
    }
    final etag = request.headers['if-match'];
    if (etag == null || etag.isEmpty) return _error(HttpStatus.badRequest);
    final body = _jsonObject(bytes);
    if (!_keys(body, const <String>{'title', 'notes', 'status', 'due'}) ||
        body['title'] is! String) {
      return _error(HttpStatus.badRequest);
    }
    final notes = body['notes'];
    if (notes != null && notes is! String) return _error(HttpStatus.badRequest);
    return _mutationResponse(
      await backend.patchTask(
        PatchTaskOperation(
          taskListId: RemoteTaskListId(listId),
          taskId: RemoteTaskId(taskId),
          etag: etag,
          title: body['title']! as String,
          notes: notes == null
              ? const OptionalFieldWrite<String>.clear()
              : OptionalFieldWrite<String>.set(notes as String),
          status: _status(body['status']),
          due: body['due'] == null
              ? const OptionalFieldWrite<RemoteDate>.clear()
              : OptionalFieldWrite<RemoteDate>.set(_remoteDate(body['due'])),
        ),
      ),
      _taskJson,
      FakeGoogleTasksMethod.patchTask,
      request.url.path,
    );
  }

  Future<http.StreamedResponse> _deleteTask(
    http.BaseRequest request,
    String listId,
    String taskId,
    List<int> bytes,
  ) async {
    final etag = request.headers['if-match'];
    if (request.url.hasQuery ||
        bytes.isNotEmpty ||
        etag == null ||
        etag.isEmpty) {
      return _error(HttpStatus.badRequest);
    }
    return _emptyMutationResponse(
      await backend.deleteTask(
        DeleteTaskOperation(
          taskListId: RemoteTaskListId(listId),
          taskId: RemoteTaskId(taskId),
          etag: etag,
          pathFreshness: MutationPathFreshness.current,
        ),
      ),
      FakeGoogleTasksMethod.deleteTask,
      request.url.path,
    );
  }

  Future<http.StreamedResponse> _moveTask(
    http.BaseRequest request,
    String listId,
    String taskId,
    List<int> bytes,
  ) async {
    final etag = request.headers['if-match'];
    if (bytes.isNotEmpty ||
        !_isJson(request) ||
        etag == null ||
        etag.isEmpty ||
        !_queryMatches(
          request.url.queryParameters,
          required: const <String, String>{},
          optional: const <String>{'destinationTasklist', 'parent', 'previous'},
        )) {
      return _error(HttpStatus.badRequest);
    }
    return _mutationResponse(
      await backend.moveTask(
        MoveTaskOperation(
          sourceTaskListId: RemoteTaskListId(listId),
          destinationTaskListId: _listId(
            request.url.queryParameters['destinationTasklist'],
          ),
          taskId: RemoteTaskId(taskId),
          etag: etag,
          pathFreshness: MutationPathFreshness.current,
          parentId: _taskId(request.url.queryParameters['parent']),
          previousId: _taskId(request.url.queryParameters['previous']),
        ),
      ),
      _taskJson,
      FakeGoogleTasksMethod.moveTask,
      request.url.path,
    );
  }

  http.StreamedResponse _readPageResponse<T>(
    Outcome<RemotePage<T>> result,
    Map<String, Object?> Function(T value) encode,
    String kind,
  ) => switch (result) {
    Success<RemotePage<T>>(:final value) =>
      _jsonResponse(HttpStatus.ok, <String, Object?>{
        'kind': kind,
        'etag': value.collectionEtag,
        if (value.nextPageToken != null)
          'nextPageToken': value.nextPageToken!.value,
        'items': value.items.map(encode).toList(growable: false),
      }),
    Failed<RemotePage<T>>(:final failure) => _failureResponse(failure),
  };

  Future<http.StreamedResponse> _mutationResponse<T>(
    GoogleTasksMutationResult<T> result,
    Map<String, Object?> Function(T value) encode,
    FakeGoogleTasksMethod operation,
    String scope,
  ) async {
    if (result is CommittedMutation<T>) {
      await _cross(BarrierPoint.afterServerCommit, operation, scope);
    }
    return switch (result) {
      CommittedMutation<T>(:final value) => _jsonResponse(
        HttpStatus.ok,
        encode(value),
      ),
      RejectedMutation<T>(:final error) => _mutationFailureResponse(error),
      UncertainMutation<T>(:final error) => _mutationFailureResponse(error),
    };
  }

  Future<http.StreamedResponse> _emptyMutationResponse(
    GoogleTasksMutationResult<void> result,
    FakeGoogleTasksMethod operation,
    String scope,
  ) async {
    if (result is CommittedMutation<void>) {
      await _cross(BarrierPoint.afterServerCommit, operation, scope);
    }
    return switch (result) {
      CommittedMutation<void>() => _bytesResponse(
        HttpStatus.noContent,
        const <int>[],
      ),
      RejectedMutation<void>(:final error) => _mutationFailureResponse(error),
      UncertainMutation<void>(:final error) => _mutationFailureResponse(error),
    };
  }

  http.StreamedResponse _mutationFailureResponse(
    GoogleTasksMutationError error,
  ) => _error(error.failure.remoteContext?.statusCode ?? HttpStatus.badRequest);

  http.StreamedResponse _failureResponse(Failure failure) =>
      _error(failure.remoteContext?.statusCode ?? HttpStatus.badRequest);

  http.StreamedResponse _error(int status) =>
      _jsonResponse(status, <String, Object?>{
        'error': <String, Object?>{
          'code': status,
          'status': 'FAKE_REJECTED',
          'message': 'Synthetic fake rejection.',
        },
      });

  http.StreamedResponse _jsonResponse(int status, Object body) =>
      _bytesResponse(status, utf8.encode(jsonEncode(body)), json: true);

  http.StreamedResponse _bytesResponse(
    int status,
    List<int> bytes, {
    bool json = false,
  }) => http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    status,
    contentLength: bytes.length,
    headers: <String, String>{
      if (json)
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
    },
  );

  Future<http.StreamedResponse> _controlResponse(
    http.StreamedResponse response,
    FakeGoogleTasksMethod operation,
    String scope,
  ) async {
    final bytes = await response.stream.toBytes();
    await _cross(BarrierPoint.beforeResponseHeaders, operation, scope);
    return http.StreamedResponse(
      _deliver(bytes, operation, scope),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  Stream<List<int>> _deliver(
    List<int> bytes,
    FakeGoogleTasksMethod operation,
    String scope,
  ) async* {
    final chunkSize = responseChunkSize ?? (bytes.isEmpty ? 1 : bytes.length);
    var chunkIndex = 0;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      await _cross(
        BarrierPoint.beforeResponseChunk,
        operation,
        scope,
        chunkIndex: chunkIndex,
      );
      final end = (offset + chunkSize).clamp(0, bytes.length);
      yield bytes.sublist(offset, end);
      chunkIndex += 1;
    }
    await _cross(BarrierPoint.afterResponseDelivery, operation, scope);
  }

  Future<void> _cross(
    BarrierPoint point,
    FakeGoogleTasksMethod operation,
    String scope, {
    int? chunkIndex,
  }) async {
    final controls = barriers;
    if (controls == null) return;
    final outcome = await controls.reach(
      BarrierAddress(
        point: point,
        operation: operation.name,
        scope: scope,
        chunkIndex: chunkIndex,
      ),
    );
    if (outcome == BarrierOutcome.cancelled ||
        outcome == BarrierOutcome.killed) {
      throw http.ClientException('Synthetic cancellation at ${point.name}.');
    }
  }

  @override
  void close() {
    _closed = true;
    backend.close();
  }
}

final class _FakeTaskListState {
  _FakeTaskListState({
    required this.id,
    required this.title,
    required this.revision,
    required this.updated,
  });

  final String id;
  String title;
  int revision;
  DateTime updated;
  int collectionRevision = 0;
  final LinkedHashMap<String, _FakeTaskState> tasks = LinkedHashMap();

  String get etag => 'fake-list-$id-v$revision';
}

final class _FakeTaskState {
  _FakeTaskState({
    required this.id,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
    required this.parentId,
    required this.position,
    required this.revision,
    required this.updated,
    required this.completed,
    required this.createdSequence,
  });

  final String id;
  String title;
  String? notes;
  RemoteTaskStatus status;
  RemoteDate? due;
  String? parentId;
  String position;
  int revision;
  DateTime updated;
  DateTime? completed;
  final int createdSequence;
  bool hidden = false;
  bool deleted = false;

  String get etag => 'fake-task-$id-v$revision';
}

bool _matches(List<String> actual, List<String> expected) {
  if (actual.length != expected.length) return false;
  for (var index = 0; index < actual.length; index += 1) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

bool _queryMatches(
  Map<String, String> actual, {
  required Map<String, String> required,
  required Set<String> optional,
}) {
  if (!required.entries.every((entry) => actual[entry.key] == entry.value)) {
    return false;
  }
  final allowed = <String>{...required.keys, ...optional};
  return actual.keys.every(allowed.contains) &&
      actual.length >= required.length &&
      optional.every(
        (key) => !actual.containsKey(key) || actual[key]!.isNotEmpty,
      );
}

bool _keys(
  Map<String, Object?> object,
  Set<String> required, {
  Set<String> optional = const <String>{},
}) {
  if (!required.every(object.containsKey)) return false;
  final allowed = <String>{...required, ...optional};
  return object.keys.every(allowed.contains);
}

bool _isJson(http.BaseRequest request) =>
    request.headers[HttpHeaders.contentTypeHeader]
        ?.split(';')
        .first
        .trim()
        .toLowerCase() ==
    'application/json';

Map<String, Object?> _jsonObject(List<int> bytes) {
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map<String, Object?>) throw const FormatException();
  return value;
}

RemoteTaskStatus _status(Object? value) => switch (value) {
  'needsAction' => RemoteTaskStatus.needsAction,
  'completed' => RemoteTaskStatus.completed,
  _ => throw const FormatException(),
};

RemoteDate _remoteDate(Object? value) {
  if (value is! String) throw const FormatException();
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T00:00:00\.000Z$',
  ).firstMatch(value);
  if (match == null) throw const FormatException();
  final date = RemoteDate(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
  final parsed = date.utcMidnight;
  if (parsed.year != date.year ||
      parsed.month != date.month ||
      parsed.day != date.day) {
    throw const FormatException();
  }
  return date;
}

PageToken? _pageToken(String? value) => value == null ? null : PageToken(value);
RemoteTaskId? _taskId(String? value) =>
    value == null ? null : RemoteTaskId(value);
RemoteTaskListId? _listId(String? value) =>
    value == null ? null : RemoteTaskListId(value);

Map<String, Object?> _taskListJson(RemoteTaskList value) => <String, Object?>{
  'kind': 'tasks#taskList',
  'id': value.id.value,
  if (value.etag != null) 'etag': value.etag,
  'title': value.title,
  if (value.updated != null) 'updated': value.updated!.toIso8601String(),
  if (value.selfLink != null) 'selfLink': value.selfLink.toString(),
};

Map<String, Object?> _taskJson(RemoteTask value) => switch (value) {
  RemoteLiveTask() => <String, Object?>{
    'kind': 'tasks#task',
    'id': value.id.value,
    if (value.etag != null) 'etag': value.etag,
    if (value.updated != null) 'updated': value.updated!.toIso8601String(),
    if (value.selfLink != null) 'selfLink': value.selfLink.toString(),
    'title': value.title,
    if (value.parentId != null) 'parent': value.parentId!.value,
    'position': value.position,
    if (value.notes != null) 'notes': value.notes,
    'status': value.status.name,
    if (value.due != null) 'due': _due(value.due!),
    if (value.completed != null)
      'completed': value.completed!.toIso8601String(),
    if (value.hidden) 'hidden': true,
  },
  RemoteTaskTombstone() => <String, Object?>{
    'kind': 'tasks#task',
    'id': value.id.value,
    if (value.etag != null) 'etag': value.etag,
    if (value.updated != null) 'updated': value.updated!.toIso8601String(),
    if (value.selfLink != null) 'selfLink': value.selfLink.toString(),
    'deleted': true,
    if (value.retainedTitle != null) 'title': value.retainedTitle,
    if (value.retainedParentId != null) 'parent': value.retainedParentId!.value,
    if (value.retainedPosition != null) 'position': value.retainedPosition,
    if (value.retainedNotes != null) 'notes': value.retainedNotes,
    if (value.retainedStatus != null) 'status': value.retainedStatus!.name,
    if (value.retainedDue != null) 'due': _due(value.retainedDue!),
    if (value.retainedCompleted != null)
      'completed': value.retainedCompleted!.toIso8601String(),
    if (value.hidden) 'hidden': true,
  },
};

String _due(RemoteDate value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}T00:00:00.000Z';

String _path(String value) => Uri.encodeComponent(value);

Failure _invalidPageFailure() => const Failure(
  code: 'fake_google_tasks.invalid_page_token',
  category: FailureCategory.remote,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'The synthetic Google Tasks page could not be read.',
  safeSummary: 'The fake rejected an invalid page token.',
  remoteContext: RemoteFailureContext(
    statusCode: HttpStatus.badRequest,
    retryAfter: null,
  ),
);

Failure _readNotFoundFailure() => const Failure(
  code: 'fake_google_tasks.not_found',
  category: FailureCategory.remote,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'The synthetic Google Tasks resource was not found.',
  safeSummary: 'The fake did not find the addressed resource.',
  remoteContext: RemoteFailureContext(
    statusCode: HttpStatus.notFound,
    retryAfter: null,
  ),
);

Failure _closedFailure(FailureOperation operation) => Failure(
  code: 'fake_google_tasks.closed',
  category: FailureCategory.internal,
  operation: operation,
  retry: RetryClassification.permanent,
  impact: 'The synthetic Google Tasks service is closed.',
  safeSummary: 'The fake service is closed.',
);

Failure _cancelledFailure() => const Failure(
  code: 'fake_google_tasks.cancelled',
  category: FailureCategory.network,
  operation: FailureOperation.read,
  retry: RetryClassification.unknown,
  impact: 'The synthetic Google Tasks read was cancelled.',
  safeSummary: 'The fake read was cancelled.',
);

GoogleTasksMutationResult<T> _notFoundMutation<T>() => RejectedMutation<T>(
  _mutationError(
    status: HttpStatus.notFound,
    code: 'google_tasks.not_found',
    kind: GoogleTasksErrorKind.notFound,
  ),
);

GoogleTasksMutationResult<T> _conditionalMutation<T>() => RejectedMutation<T>(
  _mutationError(
    status: HttpStatus.preconditionFailed,
    code: 'google_tasks.precondition_failed',
    kind: GoogleTasksErrorKind.conditional,
  ),
);

GoogleTasksMutationResult<T> _invalidMutation<T>() => RejectedMutation<T>(
  _mutationError(
    status: HttpStatus.badRequest,
    code: 'google_tasks.invalid_mutation',
    kind: GoogleTasksErrorKind.permanent,
  ),
);

GoogleTasksMutationResult<T> _stalePathMutation<T>() => UncertainMutation<T>(
  _mutationError(
    status: HttpStatus.notFound,
    code: 'google_tasks.stale_path_unresolved',
    kind: GoogleTasksErrorKind.stalePath,
    commitState: MutationCommitState.uncertain,
  ),
);

GoogleTasksMutationError _mutationError({
  required int status,
  required String code,
  required GoogleTasksErrorKind kind,
  MutationCommitState commitState = MutationCommitState.notCommitted,
}) => GoogleTasksMutationError(
  failure: Failure(
    code: code,
    category: FailureCategory.remote,
    operation: FailureOperation.write,
    retry: commitState == MutationCommitState.notCommitted
        ? RetryClassification.permanent
        : RetryClassification.unknown,
    impact: 'The synthetic Google Tasks mutation did not commit.',
    safeSummary: 'The fake rejected the mutation.',
    remoteContext: RemoteFailureContext(statusCode: status, retryAfter: null),
  ),
  kind: kind,
  commitState: commitState,
);
