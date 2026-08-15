import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/diagnostics/diagnostics.dart';
import '../../core/failure.dart';
import '../../core/outcome.dart';
import '../auth/authorization.dart';
import 'decoder.dart';
import 'dto.dart';
import 'request.dart';
import 'service.dart';

typedef TimeoutSignal = Future<void> Function(Duration duration);

final class HttpGoogleTasksService implements GoogleTasksService {
  factory HttpGoogleTasksService({
    required http.Client client,
    required AuthorizationPort authorization,
    required AccountGuard accountGuard,
    required DiagnosticSink diagnostics,
    Uri? endpoint,
    Duration requestTimeout = const Duration(seconds: 30),
    int maxResponseBytes = defaultMaxResponseBytes,
    TimeoutSignal? timeoutSignal,
    GoogleTasksDecoder decoder = const GoogleTasksDecoder(),
  }) {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be positive',
      );
    }
    if (maxResponseBytes <= 0) {
      throw ArgumentError.value(
        maxResponseBytes,
        'maxResponseBytes',
        'must be positive',
      );
    }
    return HttpGoogleTasksService._(
      client,
      authorization,
      accountGuard,
      diagnostics,
      GoogleTasksReadRequestFactory(
        endpoint ?? GoogleTasksReadRequestFactory.googleEndpoint,
      ),
      requestTimeout,
      maxResponseBytes,
      timeoutSignal ?? _defaultTimeoutSignal,
      decoder,
    );
  }

  HttpGoogleTasksService._(
    this._client,
    this._authorization,
    this._accountGuard,
    this._diagnostics,
    this._requestFactory,
    this._requestTimeout,
    this._maxResponseBytes,
    this._timeoutSignal,
    this._decoder,
  );

  static const int defaultMaxResponseBytes = 8 * 1024 * 1024;

  final http.Client _client;
  final AuthorizationPort _authorization;
  final AccountGuard _accountGuard;
  final DiagnosticSink _diagnostics;
  final GoogleTasksReadRequestFactory _requestFactory;
  final Duration _requestTimeout;
  final int _maxResponseBytes;
  final TimeoutSignal _timeoutSignal;
  final GoogleTasksDecoder _decoder;
  bool _closed = false;

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) => _read<RemoteTaskList>(
    resourceType: 'taskLists',
    cancellation: cancellation,
    createRequest: (abortTrigger) => _requestFactory.taskLists(
      pageToken: pageToken,
      abortTrigger: abortTrigger,
    ),
    decode: _decoder.decodeTaskListPage,
  );

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) => _read<RemoteTask>(
    resourceType: 'tasks',
    cancellation: cancellation,
    createRequest: (abortTrigger) => _requestFactory.tasks(
      taskListId: taskListId,
      pageToken: pageToken,
      abortTrigger: abortTrigger,
    ),
    decode: _decoder.decodeTaskPage,
  );

  Future<Outcome<RemotePage<T>>> _read<T>({
    required String resourceType,
    required GoogleTasksReadCancellation? cancellation,
    required http.AbortableRequest Function(Future<void>) createRequest,
    required Outcome<RemotePage<T>> Function(List<int>) decode,
  }) async {
    final eligibility = _verifyEligibility();
    if (eligibility case Failed<void>(:final failure)) {
      _recordFailure(resourceType, failure);
      return Outcome<RemotePage<T>>.failure(failure);
    }
    if (cancellation?.isCancelled ?? false) {
      final failure = _cancelledFailure();
      _recordFailure(resourceType, failure);
      return Outcome<RemotePage<T>>.failure(failure);
    }

    final abortReason = Completer<_AbortReason>();
    void abort(_AbortReason reason) {
      if (!abortReason.isCompleted) abortReason.complete(reason);
    }

    unawaited(
      cancellation?.whenCancelled.then((_) => abort(_AbortReason.cancelled)),
    );
    unawaited(
      _timeoutSignal(_requestTimeout).then((_) => abort(_AbortReason.timeout)),
    );
    final request = createRequest(abortReason.future.then<void>((_) {}));

    try {
      final response = await _client.send(request);
      final bytes = await _readBounded(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final failure = _mapHttpFailure(
          response.statusCode,
          bytes,
          response.headers,
        );
        _recordFailure(
          resourceType,
          failure,
          requestUri: request.url,
          responseBody: bytes,
          statusCode: response.statusCode,
        );
        return Outcome<RemotePage<T>>.failure(failure);
      }
      if (!_isJson(response.headers['content-type'])) {
        final failure = _malformedContentTypeFailure();
        _recordFailure(
          resourceType,
          failure,
          requestUri: request.url,
          responseBody: bytes,
          statusCode: response.statusCode,
        );
        return Outcome<RemotePage<T>>.failure(failure);
      }
      final result = decode(bytes);
      switch (result) {
        case Success<RemotePage<T>>(:final value):
          _diagnostics.record(
            DiagnosticEvent(
              code: 'google_tasks.read_page',
              operation: 'read',
              fields: <DiagnosticField>[
                DiagnosticField.safe('resourceType', resourceType),
                DiagnosticField.safe('status', response.statusCode),
                DiagnosticField.safe('itemCount', value.items.length),
                DiagnosticField.safe(
                  'hasNextPage',
                  value.nextPageToken != null,
                ),
                DiagnosticField.private('requestUri', request.url),
                DiagnosticField.private('responseBody', _safeUtf8(bytes)),
              ],
            ),
          );
          return result;
        case Failed<RemotePage<T>>(:final failure):
          _recordFailure(
            resourceType,
            failure,
            requestUri: request.url,
            responseBody: bytes,
            statusCode: response.statusCode,
          );
          return result;
      }
    } on _ResponseTooLarge {
      final failure = _responseTooLargeFailure();
      _recordFailure(resourceType, failure, requestUri: request.url);
      return Outcome<RemotePage<T>>.failure(failure);
    } on http.RequestAbortedException {
      final reason = abortReason.isCompleted ? await abortReason.future : null;
      final failure = switch (reason) {
        _AbortReason.cancelled => _cancelledFailure(),
        _AbortReason.timeout => _timeoutFailure(),
        null => _transportFailure(),
      };
      _recordFailure(resourceType, failure, requestUri: request.url);
      return Outcome<RemotePage<T>>.failure(failure);
    } on TimeoutException {
      final failure = _timeoutFailure();
      _recordFailure(resourceType, failure, requestUri: request.url);
      return Outcome<RemotePage<T>>.failure(failure);
    } on http.ClientException {
      final failure = _transportFailure();
      _recordFailure(resourceType, failure, requestUri: request.url);
      return Outcome<RemotePage<T>>.failure(failure);
    }
  }

  Outcome<void> _verifyEligibility() {
    if (_closed) {
      return const Outcome<void>.failure(
        Failure(
          code: 'google_tasks.service_closed',
          category: FailureCategory.internal,
          operation: FailureOperation.read,
          retry: RetryClassification.permanent,
          impact: 'Google Tasks data cannot be read.',
          safeSummary: 'The Google Tasks service is closed.',
        ),
      );
    }
    final state = _authorization.currentState;
    if (state case TasksAuthorized(:final subject)) {
      return _accountGuard.verify(subject);
    }
    return const Outcome<void>.failure(
      Failure(
        code: 'google_tasks.authorization_unavailable',
        category: FailureCategory.authorization,
        operation: FailureOperation.read,
        retry: RetryClassification.permanent,
        impact: 'Google Tasks data cannot be read.',
        action: FailureAction.connect,
        safeSummary: 'Usable Google Tasks authorization is unavailable.',
      ),
    );
  }

  Future<Uint8List> _readBounded(http.StreamedResponse response) async {
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > _maxResponseBytes) {
      throw const _ResponseTooLarge();
    }
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response.stream) {
      length += chunk.length;
      if (length > _maxResponseBytes) throw const _ResponseTooLarge();
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Failure _mapHttpFailure(
    int statusCode,
    List<int> body,
    Map<String, String> headers,
  ) {
    final remoteContext = RemoteFailureContext(
      statusCode: statusCode,
      retryAfter: _parseRetryAfter(headers['retry-after']),
    );
    if (statusCode == 401) {
      return Failure(
        code: 'google_tasks.unauthorized',
        category: FailureCategory.authorization,
        operation: FailureOperation.read,
        retry: RetryClassification.unknown,
        impact: 'Google Tasks authorization was not accepted.',
        action: FailureAction.connect,
        safeSummary: 'Google rejected the Tasks request as unauthorized.',
        remoteContext: remoteContext,
      );
    }
    if (statusCode == 429 ||
        (statusCode == 403 && _errorReasons(body).contains('quotaExceeded'))) {
      return Failure(
        code: 'google_tasks.rate_limited',
        category: FailureCategory.rateLimit,
        operation: FailureOperation.read,
        retry: RetryClassification.transient,
        impact: 'Google Tasks data could not be refreshed because of a limit.',
        action: FailureAction.retry,
        safeSummary: 'Google limited the Tasks read request.',
        remoteContext: remoteContext,
      );
    }
    if (statusCode >= 500 && statusCode <= 599) {
      return Failure(
        code: 'google_tasks.remote_unavailable',
        category: FailureCategory.remote,
        operation: FailureOperation.read,
        retry: RetryClassification.transient,
        impact: 'Google Tasks data could not be refreshed.',
        action: FailureAction.retry,
        safeSummary: 'Google Tasks returned a server failure.',
        remoteContext: remoteContext,
      );
    }
    return Failure(
      code: 'google_tasks.remote_rejected',
      category: FailureCategory.remote,
      operation: FailureOperation.read,
      retry: RetryClassification.unknown,
      impact: 'Google Tasks data could not be read.',
      safeSummary: 'Google returned an unclassified response to a Tasks read.',
      remoteContext: remoteContext,
    );
  }

  bool _isJson(String? contentType) =>
      contentType?.split(';').first.trim().toLowerCase() == 'application/json';

  RetryAfter? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) {
      return RetryAfterDelay(Duration(seconds: seconds));
    }
    try {
      return RetryAfterDate(HttpDate.parse(value).toUtc());
    } on FormatException {
      return null;
    }
  }

  Set<String> _errorReasons(List<int> body) {
    try {
      final decoded = jsonDecode(_safeUtf8(body));
      if (decoded is! Map<String, Object?>) return const <String>{};
      final error = decoded['error'];
      if (error is! Map<String, Object?>) return const <String>{};
      final errors = error['errors'];
      if (errors is! List<Object?>) return const <String>{};
      return errors
          .whereType<Map<String, Object?>>()
          .map((entry) => entry['reason'])
          .whereType<String>()
          .toSet();
    } on FormatException {
      return const <String>{};
    }
  }

  void _recordFailure(
    String resourceType,
    Failure failure, {
    Uri? requestUri,
    List<int>? responseBody,
    int? statusCode,
  }) {
    _diagnostics.record(
      DiagnosticEvent(
        code: 'google_tasks.read_failed',
        operation: 'read',
        fields: <DiagnosticField>[
          DiagnosticField.safe('resourceType', resourceType),
          DiagnosticField.safe('failureCode', failure.code),
          if (statusCode != null) DiagnosticField.safe('status', statusCode),
          if (requestUri != null)
            DiagnosticField.private('requestUri', requestUri),
          if (responseBody != null)
            DiagnosticField.private('responseBody', _safeUtf8(responseBody)),
        ],
      ),
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

enum _AbortReason { cancelled, timeout }

final class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge();
}

Future<void> _defaultTimeoutSignal(Duration duration) =>
    Future<void>.delayed(duration);

String _safeUtf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

Failure _cancelledFailure() => const Failure(
  code: 'google_tasks.read_cancelled',
  category: FailureCategory.network,
  operation: FailureOperation.read,
  retry: RetryClassification.transient,
  impact: 'The Google Tasks read was cancelled.',
  safeSummary: 'The Google Tasks read was cancelled before completion.',
);

Failure _timeoutFailure() => const Failure(
  code: 'google_tasks.read_timeout',
  category: FailureCategory.network,
  operation: FailureOperation.read,
  retry: RetryClassification.transient,
  impact: 'Google Tasks did not respond in time.',
  action: FailureAction.retry,
  safeSummary: 'The Google Tasks read reached its request timeout.',
);

Failure _transportFailure() => const Failure(
  code: 'google_tasks.transport',
  category: FailureCategory.network,
  operation: FailureOperation.read,
  retry: RetryClassification.transient,
  impact: 'Google Tasks could not be reached.',
  action: FailureAction.retry,
  safeSummary: 'The Google Tasks transport failed.',
);

Failure _responseTooLargeFailure() => const Failure(
  code: 'google_tasks.response_too_large',
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks data could not be read safely.',
  safeSummary: 'Google returned a Tasks response above the decoding limit.',
);

Failure _malformedContentTypeFailure() => const Failure(
  code: 'google_tasks.malformed_success',
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks data could not be read safely.',
  safeSummary: 'Google returned task data with an unexpected content type.',
);
