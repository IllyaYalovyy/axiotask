import 'dart:async';

import 'package:http/http.dart' as http;

import 'dto.dart';

final class GoogleTasksReadCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class GoogleTasksReadRequestFactory {
  GoogleTasksReadRequestFactory(this.endpoint) {
    if (!endpoint.isAbsolute ||
        (endpoint.scheme != 'https' && endpoint.scheme != 'http') ||
        endpoint.host.isEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'must be an HTTP base URI',
      );
    }
  }

  static final Uri googleEndpoint = Uri.parse(
    'https://tasks.googleapis.com/tasks/v1/',
  );

  final Uri endpoint;

  http.AbortableRequest taskLists({
    required PageToken? pageToken,
    required Future<void> abortTrigger,
  }) => _get(
    <String>['users', '@me', 'lists'],
    <String, String>{
      'maxResults': '1000',
      if (pageToken != null) 'pageToken': _validToken(pageToken),
    },
    abortTrigger,
  );

  http.AbortableRequest tasks({
    required RemoteTaskListId taskListId,
    required PageToken? pageToken,
    required Future<void> abortTrigger,
  }) {
    if (taskListId.value.isEmpty) {
      throw ArgumentError.value(taskListId, 'taskListId', 'must not be empty');
    }
    return _get(
      <String>['lists', taskListId.value, 'tasks'],
      <String, String>{
        'maxResults': '100',
        if (pageToken != null) 'pageToken': _validToken(pageToken),
        'showCompleted': 'true',
        'showHidden': 'true',
        'showDeleted': 'true',
        'showAssigned': 'false',
      },
      abortTrigger,
    );
  }

  http.AbortableRequest _get(
    List<String> suffix,
    Map<String, String> query,
    Future<void> abortTrigger,
  ) {
    final baseSegments = endpoint.pathSegments.where((part) => part.isNotEmpty);
    final uri = endpoint.replace(
      pathSegments: <String>[...baseSegments, ...suffix],
      queryParameters: query,
    );
    return http.AbortableRequest('GET', uri, abortTrigger: abortTrigger)
      ..followRedirects = false
      ..headers['accept'] = 'application/json';
  }

  String _validToken(PageToken pageToken) {
    if (pageToken.value.isEmpty) {
      throw ArgumentError.value(pageToken, 'pageToken', 'must not be empty');
    }
    return pageToken.value;
  }
}
