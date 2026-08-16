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
import 'mutation.dart';
import 'request.dart';
import 'service.dart';

typedef TimeoutSignal = Future<void> Function(Duration duration);

final class HttpGoogleTasksService
    implements GoogleTasksService, GoogleTasksRecoveryService {
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
    GoogleTasksMutationCapabilities mutationCapabilities =
        const GoogleTasksMutationCapabilities(),
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
    final resolvedEndpoint =
        endpoint ?? GoogleTasksReadRequestFactory.googleEndpoint;
    return HttpGoogleTasksService._(
      client,
      authorization,
      accountGuard,
      diagnostics,
      GoogleTasksReadRequestFactory(resolvedEndpoint),
      resolvedEndpoint,
      requestTimeout,
      maxResponseBytes,
      timeoutSignal ?? _defaultTimeoutSignal,
      decoder,
      mutationCapabilities,
    );
  }

  HttpGoogleTasksService._(
    this._client,
    this._authorization,
    this._accountGuard,
    this._diagnostics,
    this._requestFactory,
    this._mutationEndpoint,
    this._requestTimeout,
    this._maxResponseBytes,
    this._timeoutSignal,
    this._decoder,
    this._mutationCapabilities,
  );

  static const int defaultMaxResponseBytes = 8 * 1024 * 1024;

  final http.Client _client;
  final AuthorizationPort _authorization;
  final AccountGuard _accountGuard;
  final DiagnosticSink _diagnostics;
  final GoogleTasksReadRequestFactory _requestFactory;
  final Uri _mutationEndpoint;
  final Duration _requestTimeout;
  final int _maxResponseBytes;
  final TimeoutSignal _timeoutSignal;
  final GoogleTasksDecoder _decoder;
  final GoogleTasksMutationCapabilities _mutationCapabilities;
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

  @override
  Future<Outcome<RemoteTaskList?>> getTaskList(
    RemoteTaskListId taskListId, {
    GoogleTasksReadCancellation? cancellation,
  }) async {
    const resourceType = 'taskListReadBack';
    final eligibility = _verifyEligibility(FailureOperation.read);
    if (eligibility case Failed<void>(:final failure)) {
      _recordFailure(resourceType, failure);
      return Outcome<RemoteTaskList?>.failure(failure);
    }
    if (cancellation?.isCancelled ?? false) {
      final failure = _cancelledFailure();
      _recordFailure(resourceType, failure);
      return Outcome<RemoteTaskList?>.failure(failure);
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
    final request = _requestFactory.taskList(
      taskListId: taskListId,
      abortTrigger: abortReason.future.then<void>((_) {}),
    );
    try {
      final response = await _client.send(request);
      final bytes = await _readBounded(response);
      if (response.statusCode == HttpStatus.notFound) {
        _diagnostics.record(
          DiagnosticEvent(
            subsystem: DiagnosticSubsystem.api,
            kind: DiagnosticEventKind.resolution,
            code: 'google_tasks.task_list_readback_missing',
            operation: 'read',
            fields: <DiagnosticField>[
              const DiagnosticField.safe('resourceType', resourceType),
              DiagnosticField.safe('status', response.statusCode),
              DiagnosticField.private('requestUri', request.url),
            ],
          ),
        );
        return const Outcome<RemoteTaskList?>.success(null);
      }
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
        return Outcome<RemoteTaskList?>.failure(failure);
      }
      if (response.statusCode != HttpStatus.ok ||
          !_isJson(response.headers['content-type'])) {
        final failure = _malformedContentTypeFailure();
        _recordFailure(
          resourceType,
          failure,
          requestUri: request.url,
          responseBody: bytes,
          statusCode: response.statusCode,
        );
        return Outcome<RemoteTaskList?>.failure(failure);
      }
      switch (_decoder.decodeTaskListReadResource(bytes)) {
        case Success<RemoteTaskList>(:final value):
          return Outcome<RemoteTaskList?>.success(value);
        case Failed<RemoteTaskList>(:final failure):
          _recordFailure(
            resourceType,
            failure,
            requestUri: request.url,
            responseBody: bytes,
            statusCode: response.statusCode,
          );
          return Outcome<RemoteTaskList?>.failure(failure);
      }
    } on _ResponseTooLarge {
      final failure = _responseTooLargeFailure();
      _recordFailure(resourceType, failure, requestUri: request.url);
      return Outcome<RemoteTaskList?>.failure(failure);
    } on http.RequestAbortedException {
      final reason = abortReason.isCompleted ? await abortReason.future : null;
      final failure = switch (reason) {
        _AbortReason.cancelled => _cancelledFailure(),
        _AbortReason.timeout => _timeoutFailure(),
        null => _transportFailure(),
      };
      _recordFailure(resourceType, failure, requestUri: request.url);
      return Outcome<RemoteTaskList?>.failure(failure);
    } on TimeoutException {
      final failure = _timeoutFailure();
      _recordFailure(resourceType, failure, requestUri: request.url);
      return Outcome<RemoteTaskList?>.failure(failure);
    } on http.ClientException {
      final failure = _transportFailure();
      _recordFailure(resourceType, failure, requestUri: request.url);
      return Outcome<RemoteTaskList?>.failure(failure);
    }
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) => _mutateResource<RemoteTaskList>(
    operation: operation,
    decode: _decoder.decodeTaskListResource,
  );

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) => _mutateResource<RemoteTaskList>(
    operation: operation,
    decode: _decoder.decodeTaskListResource,
  );

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => _mutateEmpty(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => _mutateResource<RemoteTask>(
    operation: operation,
    decode: _decoder.decodeTaskResource,
  );

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) => _mutateResource<RemoteTask>(
    operation: operation,
    decode: _decoder.decodeTaskResource,
  );

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) => _mutateEmpty(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => _mutateResource<RemoteTask>(
    operation: operation,
    decode: _decoder.decodeTaskResource,
  );

  Future<GoogleTasksMutationResult<T>> _mutateResource<T>({
    required GoogleTasksMutationOperation<T> operation,
    required Outcome<T> Function(List<int>) decode,
  }) => _mutate<T>(
    operation: operation,
    expectedStatus: HttpStatus.ok,
    decode: decode,
  );

  Future<GoogleTasksMutationResult<void>> _mutateEmpty(
    GoogleTasksMutationOperation<void> operation,
  ) => _mutate<void>(
    operation: operation,
    expectedStatus: HttpStatus.noContent,
    decode: (bytes) => bytes.isEmpty
        ? const Outcome<void>.success(null)
        : Outcome<void>.failure(_malformedMutationSuccessFailure()),
  );

  Future<GoogleTasksMutationResult<T>> _mutate<T>({
    required GoogleTasksMutationOperation<T> operation,
    required int expectedStatus,
    required Outcome<T> Function(List<int>) decode,
  }) async {
    final eligibility = _verifyEligibility(FailureOperation.write);
    if (eligibility case Failed<void>(:final failure)) {
      final error = GoogleTasksMutationError(
        failure: _asWriteFailure(failure),
        kind: failure.category == FailureCategory.authorization
            ? GoogleTasksErrorKind.authorization
            : GoogleTasksErrorKind.permanent,
        commitState: MutationCommitState.notCommitted,
      );
      _recordMutationFailure(operation, error);
      return RejectedMutation<T>(error);
    }

    final abortReason = Completer<_AbortReason>();
    unawaited(
      _timeoutSignal(_requestTimeout).then((_) {
        if (!abortReason.isCompleted) {
          abortReason.complete(_AbortReason.timeout);
        }
      }),
    );
    final request = operation.toRequest(
      endpoint: _mutationEndpoint,
      abortTrigger: abortReason.future.then<void>((_) {}),
      capabilities: _mutationCapabilities,
    );
    final requestBody = request.bodyBytes;
    http.StreamedResponse? receivedResponse;

    try {
      final response = await _client.send(request);
      receivedResponse = response;
      final bytes = await _readBounded(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        var error = _mapMutationHttpError(
          response.statusCode,
          bytes,
          response.headers,
        );
        if (operation.pathFreshness == MutationPathFreshness.possiblyStale &&
            response.statusCode == HttpStatus.notFound) {
          error = _stalePathMutationError(response.statusCode);
        }
        _recordMutationFailure(
          operation,
          error,
          requestUri: request.url,
          requestBody: requestBody,
          responseBody: bytes,
          statusCode: response.statusCode,
        );
        return _mutationErrorResult<T>(error);
      }

      if (response.statusCode != expectedStatus ||
          (expectedStatus == HttpStatus.ok &&
              !_isJson(response.headers['content-type']))) {
        final error = _uncertainMutationError(
          expectedStatus == HttpStatus.ok
              ? 'google_tasks.malformed_mutation_success'
              : 'google_tasks.unexpected_mutation_success',
          'Google returned an unexpected Tasks mutation response.',
          statusCode: response.statusCode,
        );
        _recordMutationFailure(
          operation,
          error,
          requestUri: request.url,
          requestBody: requestBody,
          responseBody: bytes,
          statusCode: response.statusCode,
        );
        return UncertainMutation<T>(error);
      }

      final decoded = decode(bytes);
      if (decoded case Failed<T>(:final failure)) {
        final error = GoogleTasksMutationError(
          failure: _asWriteFailure(failure),
          kind: GoogleTasksErrorKind.unknown,
          commitState: MutationCommitState.uncertain,
        );
        _recordMutationFailure(
          operation,
          error,
          requestUri: request.url,
          requestBody: requestBody,
          responseBody: bytes,
          statusCode: response.statusCode,
        );
        return UncertainMutation<T>(error);
      }
      if (operation.pathFreshness == MutationPathFreshness.possiblyStale) {
        final error = _stalePathMutationError(response.statusCode);
        _recordMutationFailure(
          operation,
          error,
          requestUri: request.url,
          requestBody: requestBody,
          responseBody: bytes,
          statusCode: response.statusCode,
        );
        return UncertainMutation<T>(error);
      }

      final value = (decoded as Success<T>).value;
      _recordMutationSuccess(
        operation,
        statusCode: response.statusCode,
        requestUri: request.url,
        requestBody: requestBody,
        responseBody: bytes,
      );
      return CommittedMutation<T>(value);
    } on _ResponseTooLarge {
      final response = receivedResponse;
      if (response != null &&
          (response.statusCode < 200 || response.statusCode >= 300)) {
        var error = _mapMutationHttpError(
          response.statusCode,
          const <int>[],
          response.headers,
        );
        if (operation.pathFreshness == MutationPathFreshness.possiblyStale &&
            response.statusCode == HttpStatus.notFound) {
          error = _stalePathMutationError(response.statusCode);
        }
        _recordMutationFailure(
          operation,
          error,
          requestUri: request.url,
          requestBody: requestBody,
          statusCode: response.statusCode,
        );
        return _mutationErrorResult<T>(error);
      }
      final error = _uncertainMutationError(
        'google_tasks.mutation_response_too_large',
        'Google returned a mutation response above the decoding limit.',
      );
      _recordMutationFailure(
        operation,
        error,
        requestUri: request.url,
        requestBody: requestBody,
      );
      return UncertainMutation<T>(error);
    } on http.RequestAbortedException {
      final error = _uncertainMutationError(
        'google_tasks.mutation_timeout',
        'The Google Tasks mutation reached its request timeout.',
        transient: true,
      );
      _recordMutationFailure(
        operation,
        error,
        requestUri: request.url,
        requestBody: requestBody,
      );
      return UncertainMutation<T>(error);
    } on TimeoutException {
      final error = _uncertainMutationError(
        'google_tasks.mutation_timeout',
        'The Google Tasks mutation reached its request timeout.',
        transient: true,
      );
      _recordMutationFailure(
        operation,
        error,
        requestUri: request.url,
        requestBody: requestBody,
      );
      return UncertainMutation<T>(error);
    } on http.ClientException {
      final error = _uncertainMutationError(
        'google_tasks.mutation_transport',
        'The Google Tasks mutation transport failed.',
        transient: true,
      );
      _recordMutationFailure(
        operation,
        error,
        requestUri: request.url,
        requestBody: requestBody,
      );
      return UncertainMutation<T>(error);
    }
  }

  Future<Outcome<RemotePage<T>>> _read<T>({
    required String resourceType,
    required GoogleTasksReadCancellation? cancellation,
    required http.AbortableRequest Function(Future<void>) createRequest,
    required Outcome<RemotePage<T>> Function(List<int>) decode,
  }) async {
    final eligibility = _verifyEligibility(FailureOperation.read);
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
              subsystem: DiagnosticSubsystem.api,
              kind: DiagnosticEventKind.transition,
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

  Outcome<void> _verifyEligibility(FailureOperation operation) {
    if (_closed) {
      return Outcome<void>.failure(
        Failure(
          code: 'google_tasks.service_closed',
          category: FailureCategory.internal,
          operation: operation,
          retry: RetryClassification.permanent,
          impact: _eligibilityImpact(operation),
          safeSummary: 'The Google Tasks service is closed.',
        ),
      );
    }
    final state = _authorization.currentState;
    if (state case TasksAuthorized(:final subject)) {
      return _accountGuard.verify(subject);
    }
    return Outcome<void>.failure(
      Failure(
        code: 'google_tasks.authorization_unavailable',
        category: FailureCategory.authorization,
        operation: operation,
        retry: RetryClassification.permanent,
        impact: _eligibilityImpact(operation),
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
    if (_isObservedMalformedBearerResponse(statusCode, body, headers)) {
      return Failure(
        code: 'google_tasks.unauthorized',
        category: FailureCategory.authorization,
        operation: FailureOperation.read,
        retry: RetryClassification.unknown,
        impact: 'Google Tasks authorization was not accepted.',
        action: FailureAction.connect,
        safeSummary: 'Google rejected the Tasks request as unauthorized.',
        remoteContext: remoteContext,
        authorizationRecovery: AuthorizationRecovery.refreshOnce,
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

  bool _isObservedMalformedBearerResponse(
    int statusCode,
    List<int> body,
    Map<String, String> headers,
  ) {
    if (statusCode != HttpStatus.unauthorized ||
        headers['www-authenticate'] == null) {
      return false;
    }
    try {
      final decoded = jsonDecode(_safeUtf8(body));
      if (decoded is! Map<String, Object?>) return false;
      final error = decoded['error'];
      if (error is! Map<String, Object?>) return false;
      return error['code'] == HttpStatus.unauthorized &&
          error['errors'] is List<Object?> &&
          error['message'] is String &&
          error['status'] is String;
    } on FormatException {
      return false;
    }
  }

  GoogleTasksMutationError _mapMutationHttpError(
    int statusCode,
    List<int> body,
    Map<String, String> headers,
  ) {
    final remoteContext = RemoteFailureContext(
      statusCode: statusCode,
      retryAfter: _parseRetryAfter(headers['retry-after']),
    );
    if (statusCode == HttpStatus.tooManyRequests ||
        (statusCode == HttpStatus.forbidden &&
            _errorReasons(body).contains('quotaExceeded'))) {
      return GoogleTasksMutationError(
        failure: Failure(
          code: 'google_tasks.rate_limited',
          category: FailureCategory.rateLimit,
          operation: FailureOperation.write,
          retry: RetryClassification.transient,
          impact: 'A Google Tasks mutation was rejected because of a limit.',
          action: FailureAction.retry,
          safeSummary: 'Google limited a Tasks mutation request.',
          remoteContext: remoteContext,
        ),
        kind: GoogleTasksErrorKind.quota,
        commitState: MutationCommitState.notCommitted,
      );
    }
    if (statusCode == HttpStatus.notFound) {
      return GoogleTasksMutationError(
        failure: Failure(
          code: 'google_tasks.not_found',
          category: FailureCategory.remote,
          operation: FailureOperation.write,
          retry: RetryClassification.permanent,
          impact: 'The addressed Google Tasks resource was not mutated.',
          safeSummary: 'Google did not find the addressed Tasks resource.',
          remoteContext: remoteContext,
        ),
        kind: GoogleTasksErrorKind.notFound,
        commitState: MutationCommitState.notCommitted,
      );
    }
    if (statusCode == HttpStatus.preconditionFailed) {
      return GoogleTasksMutationError(
        failure: Failure(
          code: 'google_tasks.precondition_failed',
          category: FailureCategory.remote,
          operation: FailureOperation.write,
          retry: RetryClassification.permanent,
          impact: 'The Google Tasks mutation did not pass its precondition.',
          safeSummary: 'Google rejected a stale Tasks mutation precondition.',
          remoteContext: remoteContext,
        ),
        kind: GoogleTasksErrorKind.conditional,
        commitState: MutationCommitState.notCommitted,
      );
    }
    if (statusCode >= 500 && statusCode <= 599) {
      return GoogleTasksMutationError(
        failure: Failure(
          code: 'google_tasks.remote_unavailable',
          category: FailureCategory.remote,
          operation: FailureOperation.write,
          retry: RetryClassification.transient,
          impact: 'A Google Tasks mutation may not have completed.',
          action: FailureAction.retry,
          safeSummary: 'Google Tasks returned a server failure.',
          remoteContext: remoteContext,
        ),
        kind: GoogleTasksErrorKind.transient,
        commitState: MutationCommitState.uncertain,
      );
    }
    if (statusCode == HttpStatus.badRequest ||
        statusCode == HttpStatus.unprocessableEntity) {
      return GoogleTasksMutationError(
        failure: Failure(
          code: 'google_tasks.invalid_mutation',
          category: FailureCategory.remote,
          operation: FailureOperation.write,
          retry: RetryClassification.permanent,
          impact: 'Google rejected the Tasks mutation without changing it.',
          safeSummary: 'Google rejected an invalid Tasks mutation.',
          remoteContext: remoteContext,
        ),
        kind: GoogleTasksErrorKind.permanent,
        commitState: MutationCommitState.notCommitted,
      );
    }
    return GoogleTasksMutationError(
      failure: Failure(
        code: 'google_tasks.unknown_mutation_response',
        category: FailureCategory.remote,
        operation: FailureOperation.write,
        retry: RetryClassification.unknown,
        impact: 'A Google Tasks mutation outcome could not be established.',
        safeSummary: 'Google returned an unclassified mutation response.',
        remoteContext: remoteContext,
      ),
      kind: GoogleTasksErrorKind.unknown,
      commitState: MutationCommitState.uncertain,
    );
  }

  void _recordMutationSuccess<T>(
    GoogleTasksMutationOperation<T> operation, {
    required int statusCode,
    required Uri requestUri,
    required List<int> requestBody,
    required List<int> responseBody,
  }) {
    _diagnostics.record(
      DiagnosticEvent(
        subsystem: DiagnosticSubsystem.api,
        kind: DiagnosticEventKind.transition,
        code: 'google_tasks.mutation_succeeded',
        operation: 'write',
        fields: <DiagnosticField>[
          DiagnosticField.safe('mutation', operation.diagnosticName),
          DiagnosticField.safe('status', statusCode),
          DiagnosticField.private('requestUri', requestUri),
          DiagnosticField.private('requestBody', _safeUtf8(requestBody)),
          DiagnosticField.private('responseBody', _safeUtf8(responseBody)),
        ],
      ),
    );
  }

  void _recordMutationFailure<T>(
    GoogleTasksMutationOperation<T> operation,
    GoogleTasksMutationError error, {
    Uri? requestUri,
    List<int>? requestBody,
    List<int>? responseBody,
    int? statusCode,
  }) {
    _diagnostics.record(
      DiagnosticEvent(
        subsystem: DiagnosticSubsystem.api,
        kind: DiagnosticEventKind.failure,
        code: 'google_tasks.mutation_failed',
        operation: 'write',
        fields: <DiagnosticField>[
          DiagnosticField.safe('mutation', operation.diagnosticName),
          DiagnosticField.safe('failureCode', error.failure.code),
          DiagnosticField.safe('errorKind', error.kind.name),
          DiagnosticField.safe('commitState', error.commitState.name),
          if (statusCode != null) DiagnosticField.safe('status', statusCode),
          if (requestUri != null)
            DiagnosticField.private('requestUri', requestUri),
          if (requestBody != null)
            DiagnosticField.private('requestBody', _safeUtf8(requestBody)),
          if (responseBody != null)
            DiagnosticField.private('responseBody', _safeUtf8(responseBody)),
        ],
      ),
    );
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
        subsystem: DiagnosticSubsystem.api,
        kind: DiagnosticEventKind.failure,
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

GoogleTasksMutationResult<T> _mutationErrorResult<T>(
  GoogleTasksMutationError error,
) => switch (error.commitState) {
  MutationCommitState.notCommitted => RejectedMutation<T>(error),
  MutationCommitState.uncertain => UncertainMutation<T>(error),
};

GoogleTasksMutationError _stalePathMutationError(int statusCode) =>
    GoogleTasksMutationError(
      failure: Failure(
        code: 'google_tasks.stale_path_unresolved',
        category: FailureCategory.remote,
        operation: FailureOperation.write,
        retry: RetryClassification.unknown,
        impact: 'The intended Google Tasks mutation is not yet confirmed.',
        safeSummary:
            'A possibly stale task-list path cannot confirm the mutation.',
        remoteContext: RemoteFailureContext(
          statusCode: statusCode,
          retryAfter: null,
        ),
      ),
      kind: GoogleTasksErrorKind.stalePath,
      commitState: MutationCommitState.uncertain,
    );

GoogleTasksMutationError _uncertainMutationError(
  String code,
  String summary, {
  bool transient = false,
  int? statusCode,
}) => GoogleTasksMutationError(
  failure: Failure(
    code: code,
    category: transient
        ? FailureCategory.network
        : FailureCategory.unsupportedRemoteState,
    operation: FailureOperation.write,
    retry: transient
        ? RetryClassification.transient
        : RetryClassification.unknown,
    impact: 'A Google Tasks mutation may have completed remotely.',
    action: transient ? FailureAction.retry : null,
    safeSummary: summary,
    remoteContext: statusCode == null
        ? null
        : RemoteFailureContext(statusCode: statusCode, retryAfter: null),
  ),
  kind: transient
      ? GoogleTasksErrorKind.transient
      : GoogleTasksErrorKind.unknown,
  commitState: MutationCommitState.uncertain,
);

Failure _asWriteFailure(Failure failure) => Failure(
  code: failure.code,
  category: failure.category,
  operation: FailureOperation.write,
  retry: failure.retry,
  impact: failure.impact,
  action: failure.action,
  safeSummary: failure.safeSummary,
  sensitiveContext: failure.sensitiveContext,
  remoteContext: failure.remoteContext,
);

Failure _malformedMutationSuccessFailure() => const Failure(
  code: 'google_tasks.malformed_mutation_success',
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'A Google Tasks mutation may have completed remotely.',
  safeSummary: 'Google returned a malformed Tasks mutation response.',
);

Future<void> _defaultTimeoutSignal(Duration duration) =>
    Future<void>.delayed(duration);

String _safeUtf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

String _eligibilityImpact(FailureOperation operation) =>
    operation == FailureOperation.write
    ? 'Google Tasks data cannot be changed.'
    : 'Google Tasks data cannot be read.';

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
