import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/http_service.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const subject = AccountSubject('synthetic-dedicated-subject');

void main() {
  group('HttpGoogleTasksService requests', () {
    test('sends exact task-list page path, query, and headers', () async {
      late HttpRequest seen;
      final server = await ScriptedServer.start((request) async {
        seen = request;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object>{
            'kind': 'tasks#taskLists',
            'etag': 'collection-etag',
            'nextPageToken': 'next-list-page',
            'items': <Object>[],
          }),
        );
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server);
      addTearDown(service.close);

      final result = await service.listTaskLists(
        pageToken: const PageToken('incoming-list-page'),
      );

      expect(result, isA<Success<RemotePage<RemoteTaskList>>>());
      expect(seen.method, 'GET');
      expect(seen.uri.path, '/tasks/v1/users/@me/lists');
      expect(seen.uri.queryParameters, <String, String>{
        'maxResults': '1000',
        'pageToken': 'incoming-list-page',
      });
      expect(seen.headers.value(HttpHeaders.acceptHeader), 'application/json');
      expect(
        seen.headers.value(HttpHeaders.authorizationHeader),
        'Bearer '
        'synthetic-access',
      );
      expect(seen.headers.value(HttpHeaders.contentTypeHeader), isNull);
    });

    test('sends every full-view task flag and encoded list path', () async {
      late HttpRequest seen;
      final server = await ScriptedServer.start((request) async {
        seen = request;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'items': <Object>[],
          }),
        );
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server);
      addTearDown(service.close);

      final result = await service.listTasks(
        const RemoteTaskListId('list / with spaces'),
        pageToken: const PageToken('incoming-task-page'),
      );

      expect(result, isA<Success<RemotePage<RemoteTask>>>());
      expect(seen.uri.path, '/tasks/v1/lists/list%20%2F%20with%20spaces/tasks');
      expect(seen.uri.queryParameters, <String, String>{
        'maxResults': '100',
        'pageToken': 'incoming-task-page',
        'showCompleted': 'true',
        'showHidden': 'true',
        'showDeleted': 'true',
        'showAssigned': 'false',
      });
    });

    test(
      'uses returned page token without treating a page as a snapshot',
      () async {
        var call = 0;
        final server = await ScriptedServer.start((request) async {
          call += 1;
          expect(
            request.uri.queryParameters['pageToken'],
            call == 1 ? isNull : 'page-2',
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object>{
              'kind': 'tasks#taskLists',
              if (call == 1) 'nextPageToken': 'page-2',
              'items': <Object>[_taskListJson('list-$call')],
            }),
          );
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final first = await service.listTaskLists();
        final firstPage = (first as Success<RemotePage<RemoteTaskList>>).value;
        final second = await service.listTaskLists(
          pageToken: firstPage.nextPageToken,
        );
        final secondPage =
            (second as Success<RemotePage<RemoteTaskList>>).value;

        expect(firstPage.items.single.id.value, 'list-1');
        expect(firstPage.nextPageToken, const PageToken('page-2'));
        expect(secondPage.items.single.id.value, 'list-2');
        expect(secondPage.nextPageToken, isNull);
      },
    );

    test('fails before HTTP when the dedicated subject mismatches', () async {
      var calls = 0;
      final server = await ScriptedServer.start((request) async {
        calls += 1;
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });
      addTearDown(server.close);
      final service = HttpGoogleTasksService(
        client: BearerClient(http.Client()),
        authorization: const SyntheticAuthorization(subject),
        accountGuard: const DedicatedAccountGuard(
          AccountSubject('different-dedicated-subject'),
        ),
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        endpoint: server.endpoint,
      );
      addTearDown(service.close);

      final result = await service.listTaskLists();

      expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
      expect(calls, 0);
      expect(
        (result as Failed<RemotePage<RemoteTaskList>>).failure.code,
        'account.dedicated_subject_mismatch',
      );
    });

    test('fails before HTTP when authorization is not usable', () async {
      var calls = 0;
      final server = await ScriptedServer.start((request) async {
        calls += 1;
        await request.response.close();
      });
      addTearDown(server.close);
      final service = HttpGoogleTasksService(
        client: BearerClient(http.Client()),
        authorization: const UnavailableAuthorization(),
        accountGuard: const NormalAccountGuard(),
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        endpoint: server.endpoint,
      );
      addTearDown(service.close);

      final result = await service.listTaskLists();

      expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
      expect(calls, 0);
      expect(
        (result as Failed<RemotePage<RemoteTaskList>>).failure.code,
        'google_tasks.authorization_unavailable',
      );
    });
  });

  group('HttpGoogleTasksService failures', () {
    test(
      'AUTH-006 classifies only the observed malformed-bearer shape as refreshable',
      () async {
        final server = await ScriptedServer.start((request) async {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.headers
            ..contentType = ContentType.json
            ..set(
              HttpHeaders.wwwAuthenticateHeader,
              'Bearer realm="synthetic"',
            );
          request.response.write(
            jsonEncode(<String, Object>{
              'error': <String, Object>{
                'code': 401,
                'errors': <Object>[
                  <String, Object>{'reason': 'authError'},
                ],
                'message': 'Synthetic malformed credential.',
                'status': 'UNAUTHENTICATED',
              },
            }),
          );
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final result = await service.listTaskLists();

        final failure = (result as Failed<RemotePage<RemoteTaskList>>).failure;
        expect(failure.code, 'google_tasks.unauthorized');
        expect(failure.category, FailureCategory.authorization);
        expect(
          failure.authorizationRecovery,
          AuthorizationRecovery.refreshOnce,
        );
      },
    );

    test('AUTH-006 unknown auth-like responses remain unclassified', () async {
      var call = 0;
      final server = await ScriptedServer.start((request) async {
        call += 1;
        request.response.statusCode = call == 1
            ? HttpStatus.unauthorized
            : HttpStatus.forbidden;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          call == 1
              ? '{"error":{"status":"UNAUTHENTICATED"}}'
              : '{"error":{"errors":[{"reason":"authError"}]}}',
        );
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server);
      addTearDown(service.close);

      for (var index = 0; index < 2; index += 1) {
        final result = await service.listTaskLists();
        final failure = (result as Failed<RemotePage<RemoteTaskList>>).failure;
        expect(failure.code, 'google_tasks.remote_rejected');
        expect(failure.category, FailureCategory.remote);
        expect(failure.retry, RetryClassification.unknown);
        expect(failure.authorizationRecovery, AuthorizationRecovery.none);
      }
    });

    test('rejects a response that exceeds the configured byte bound', () async {
      final server = await ScriptedServer.start((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write('x' * 65);
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server, maxResponseBytes: 64);
      addTearDown(service.close);

      final result = await service.listTaskLists();

      expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
      expect(
        (result as Failed<RemotePage<RemoteTaskList>>).failure.code,
        'google_tasks.response_too_large',
      );
    });

    test(
      'rejects a successful response with a non-JSON content type',
      () async {
        final server = await ScriptedServer.start((request) async {
          request.response.headers.contentType = ContentType.text;
          request.response.write('{"kind":"tasks#taskLists"}');
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final result = await service.listTaskLists();

        expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
        expect(
          (result as Failed<RemotePage<RemoteTaskList>>).failure.code,
          'google_tasks.malformed_success',
        );
      },
    );

    test('does not follow a remote redirect', () async {
      var calls = 0;
      final server = await ScriptedServer.start((request) async {
        calls += 1;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/tasks/v1/redirected',
        );
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server);
      addTearDown(service.close);

      final result = await service.listTaskLists();

      expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
      expect(calls, 1);
      expect(
        (result as Failed<RemotePage<RemoteTaskList>>)
            .failure
            .remoteContext
            ?.statusCode,
        HttpStatus.found,
      );
    });

    test('cancels an in-flight read through the transport', () async {
      final requestSeen = Completer<void>();
      final release = Completer<void>();
      final server = await ScriptedServer.start((request) async {
        requestSeen.complete();
        await release.future;
        request.response.write('{"kind":"tasks#taskLists"}');
        await request.response.close();
      });
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await server.close();
      });
      final service = _service(server: server);
      addTearDown(service.close);
      final cancellation = GoogleTasksReadCancellation();

      final pending = service.listTaskLists(cancellation: cancellation);
      await requestSeen.future;
      cancellation.cancel();
      final result = await pending;

      expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
      expect(
        (result as Failed<RemotePage<RemoteTaskList>>).failure.code,
        'google_tasks.read_cancelled',
      );
    });

    test('times out an in-flight read through an injected signal', () async {
      final requestSeen = Completer<void>();
      final release = Completer<void>();
      final timeout = Completer<void>();
      final server = await ScriptedServer.start((request) async {
        requestSeen.complete();
        await release.future;
        request.response.write('{"kind":"tasks#taskLists"}');
        await request.response.close();
      });
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await server.close();
      });
      Duration? requestedTimeout;
      final service = _service(
        server: server,
        timeoutSignal: (duration) {
          requestedTimeout = duration;
          return timeout.future;
        },
      );
      addTearDown(service.close);

      final pending = service.listTaskLists();
      await requestSeen.future;
      timeout.complete();
      final result = await pending;

      expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
      expect(
        (result as Failed<RemotePage<RemoteTaskList>>).failure.code,
        'google_tasks.read_timeout',
      );
      expect(requestedTimeout, const Duration(seconds: 30));
    });

    test(
      'preserves delta and date Retry-After headers as typed context',
      () async {
        var call = 0;
        final server = await ScriptedServer.start((request) async {
          call += 1;
          request.response.statusCode = HttpStatus.tooManyRequests;
          request.response.headers.set(
            HttpHeaders.retryAfterHeader,
            call == 1 ? '120' : 'Sat, 15 Aug 2026 20:00:00 GMT',
          );
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final first = await service.listTaskLists();
        final second = await service.listTaskLists();

        expect(
          (first as Failed<RemotePage<RemoteTaskList>>)
              .failure
              .remoteContext
              ?.retryAfter,
          const RetryAfterDelay(Duration(seconds: 120)),
        );
        expect(
          (second as Failed<RemotePage<RemoteTaskList>>)
              .failure
              .remoteContext
              ?.retryAfter,
          RetryAfterDate(DateTime.utc(2026, 8, 15, 20)),
        );
      },
    );

    for (final fixture
        in <
          ({
            int status,
            String body,
            String code,
            FailureCategory category,
            RetryClassification retry,
          })
        >[
          (
            status: 403,
            body: '{"error":{"errors":[{"reason":"quotaExceeded"}]}}',
            code: 'google_tasks.rate_limited',
            category: FailureCategory.rateLimit,
            retry: RetryClassification.transient,
          ),
          (
            status: 403,
            body: '{"error":{"errors":[{"reason":"forbidden"}]}}',
            code: 'google_tasks.remote_rejected',
            category: FailureCategory.remote,
            retry: RetryClassification.unknown,
          ),
          (
            status: 429,
            body: 'not-json',
            code: 'google_tasks.rate_limited',
            category: FailureCategory.rateLimit,
            retry: RetryClassification.transient,
          ),
          (
            status: 503,
            body: '',
            code: 'google_tasks.remote_unavailable',
            category: FailureCategory.remote,
            retry: RetryClassification.transient,
          ),
          (
            status: 418,
            body: '{"future":"shape"}',
            code: 'google_tasks.remote_rejected',
            category: FailureCategory.remote,
            retry: RetryClassification.unknown,
          ),
        ]) {
      test('maps HTTP ${fixture.status} conservatively', () async {
        final server = await ScriptedServer.start((request) async {
          request.response.statusCode = fixture.status;
          request.response.headers.contentType = ContentType.json;
          request.response.write(fixture.body);
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final result = await service.listTaskLists();

        final failure = (result as Failed<RemotePage<RemoteTaskList>>).failure;
        expect(failure.code, fixture.code);
        expect(failure.category, fixture.category);
        expect(failure.retry, fixture.retry);
        if (fixture.body.isNotEmpty) {
          expect(failure.safeSummary, isNot(contains(fixture.body)));
        }
      });
    }

    test('maps transport failure without exposing the request URL', () async {
      final history = InMemoryDiagnosticHistory();
      final client = ThrowingClient();
      final service = HttpGoogleTasksService(
        client: client,
        authorization: const SyntheticAuthorization(subject),
        accountGuard: const DedicatedAccountGuard(subject),
        diagnostics: ProductionDiagnosticSink(history),
        endpoint: Uri.parse('https://tasks.example.test/tasks/v1/'),
      );
      addTearDown(service.close);

      final result = await service.listTaskLists(
        pageToken: const PageToken('private-page-token'),
      );

      final failure = (result as Failed<RemotePage<RemoteTaskList>>).failure;
      expect(failure.code, 'google_tasks.transport');
      expect(failure.category, FailureCategory.network);
      expect(failure.safeSummary, isNot(contains('tasks.example.test')));
      expect(
        history.records.single.renderedText,
        isNot(contains('private-page-token')),
      );
    });
  });

  group('HTTP diagnostics privacy', () {
    const taskCanary = 'PRIVATE_TASK_CANARY_google_read';
    const credentialCanary =
        'Bearer '
        'credential-canary-google-read-0123456789';

    Future<void> exercise(DiagnosticSink sink) async {
      final server = await ScriptedServer.start((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object>{
            'kind': 'tasks#taskLists',
            'items': <Object>[
              <String, Object>{
                ..._taskListJson('list-1'),
                'title': taskCanary,
                'futureCredentialField': credentialCanary,
              },
            ],
          }),
        );
        await request.response.close();
      });
      final service = _service(server: server, diagnostics: sink);
      try {
        expect(
          await service.listTaskLists(),
          isA<Success<RemotePage<RemoteTaskList>>>(),
        );
      } finally {
        service.close();
        await server.close();
      }
    }

    test(
      'release records counts but no body, content, IDs, URL, or credential',
      () async {
        final history = InMemoryDiagnosticHistory();

        await exercise(ProductionDiagnosticSink(history));

        final output = history.records.single.renderedText;
        expect(output, contains('itemCount=1'));
        expect(output, isNot(contains(taskCanary)));
        expect(output, isNot(contains('list-1')));
        expect(output, isNot(contains('tasks/v1')));
        expect(output, isNot(contains('credential-canary')));
      },
    );

    test(
      'development retains body context but always redacts credentials',
      () async {
        final history = InMemoryDiagnosticHistory();

        await exercise(SensitiveDevelopmentDiagnosticSink(history));

        final output = history.records.single.renderedText;
        expect(output, contains(taskCanary));
        expect(output, contains('list-1'));
        expect(output, contains('tasks/v1'));
        expect(output, isNot(contains('credential-canary')));
        expect(output, contains('[REDACTED]'));
      },
    );
  });
}

HttpGoogleTasksService _service({
  required ScriptedServer server,
  int maxResponseBytes = HttpGoogleTasksService.defaultMaxResponseBytes,
  Future<void> Function(Duration)? timeoutSignal,
  DiagnosticSink? diagnostics,
}) => HttpGoogleTasksService(
  client: BearerClient(http.Client()),
  authorization: const SyntheticAuthorization(subject),
  accountGuard: const DedicatedAccountGuard(subject),
  diagnostics:
      diagnostics ?? ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
  endpoint: server.endpoint,
  maxResponseBytes: maxResponseBytes,
  timeoutSignal: timeoutSignal,
);

Map<String, Object> _taskListJson(String id) => <String, Object>{
  'kind': 'tasks#taskList',
  'id': id,
  'etag': 'etag-$id',
  'title': 'Synthetic $id',
  'updated': '2026-08-15T18:30:12Z',
};

final class ScriptedServer {
  ScriptedServer._(this._server, this._subscription);

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;

  Uri get endpoint =>
      Uri.parse('http://${_server.address.address}:${_server.port}/tasks/v1/');

  static Future<ScriptedServer> start(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late StreamSubscription<HttpRequest> subscription;
    subscription = server.listen((request) async {
      try {
        await handler(request);
      } on Object {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } on Object {
          // The client can intentionally abort cancellation/timeout fixtures.
        }
      }
    });
    return ScriptedServer._(server, subscription);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

final class BearerClient extends http.BaseClient {
  BearerClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers[HttpHeaders.authorizationHeader] =
        'Bearer '
        'synthetic-access';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

final class ThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw http.ClientException('synthetic transport failure', request.url);
}
