import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/http_service.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const subject = AccountSubject('synthetic-dedicated-subject');

void main() {
  group('Google Tasks mutation request contract', () {
    test('creates and renames a list with exact bodies and headers', () async {
      final requests = <RecordedRequest>[];
      final server = await ScriptedMutationServer.start((request) async {
        requests.add(await RecordedRequest.read(request));
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_taskListJson('list-1')));
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server);
      addTearDown(service.close);

      final created = await service.createTaskList(
        const CreateTaskListOperation(title: 'Synthetic list'),
      );
      final renamed = await service.renameTaskList(
        const RenameTaskListOperation(
          taskListId: RemoteTaskListId('list-1'),
          title: 'Renamed list',
        ),
      );

      expect(created, isA<CommittedMutation<RemoteTaskList>>());
      expect(renamed, isA<CommittedMutation<RemoteTaskList>>());
      expect(requests[0].method, 'POST');
      expect(requests[0].path, '/tasks/v1/users/@me/lists');
      expect(requests[0].query, isEmpty);
      expect(requests[0].json, <String, Object?>{'title': 'Synthetic list'});
      expect(requests[1].method, 'PATCH');
      expect(requests[1].path, '/tasks/v1/users/@me/lists/list-1');
      expect(requests[1].query, isEmpty);
      expect(requests[1].json, <String, Object?>{'title': 'Renamed list'});
      for (final request in requests) {
        expect(request.accept, 'application/json');
        expect(request.contentType, 'application/json; charset=utf-8');
        expect(
          request.authorization,
          'Bearer '
          'synthetic-access',
        );
        expect(request.ifMatch, isNull);
      }
    });

    test(
      'deletes a list using an empty request and strict 204 response',
      () async {
        late RecordedRequest seen;
        final server = await ScriptedMutationServer.start((request) async {
          seen = await RecordedRequest.read(request);
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final result = await service.deleteTaskList(
          const DeleteTaskListOperation(RemoteTaskListId('list / one')),
        );

        expect(result, isA<CommittedMutation<void>>());
        expect(seen.method, 'DELETE');
        expect(seen.path, '/tasks/v1/users/@me/lists/list%20%2F%20one');
        expect(seen.query, isEmpty);
        expect(seen.body, isEmpty);
        expect(seen.contentType, isNull);
        expect(seen.ifMatch, isNull);
      },
    );

    test(
      'creates a task with exact writable fields and placement query',
      () async {
        late RecordedRequest seen;
        final server = await ScriptedMutationServer.start((request) async {
          seen = await RecordedRequest.read(request);
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(_taskJson('task-1')));
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final result = await service.createTask(
          const CreateTaskOperation(
            taskListId: RemoteTaskListId('list-1'),
            title: 'Synthetic task',
            notes: 'Synthetic notes',
            status: RemoteTaskStatus.completed,
            due: RemoteDate(2026, 8, 16),
            parentId: RemoteTaskId('parent-1'),
            previousId: RemoteTaskId('previous-1'),
          ),
        );

        expect(result, isA<CommittedMutation<RemoteTask>>());
        expect(seen.method, 'POST');
        expect(seen.path, '/tasks/v1/lists/list-1/tasks');
        expect(seen.query, <String, String>{
          'parent': 'parent-1',
          'previous': 'previous-1',
        });
        expect(seen.json, <String, Object?>{
          'title': 'Synthetic task',
          'notes': 'Synthetic notes',
          'status': 'completed',
          'due': '2026-08-16T00:00:00.000Z',
        });
        expect(seen.ifMatch, isNull);
      },
    );

    test(
      'creates a minimal open top-level task without optional keys',
      () async {
        late RecordedRequest seen;
        final server = await ScriptedMutationServer.start((request) async {
          seen = await RecordedRequest.read(request);
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(_taskJson('task-1')));
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        await service.createTask(
          const CreateTaskOperation(
            taskListId: RemoteTaskListId('list-1'),
            title: 'Synthetic task',
            status: RemoteTaskStatus.needsAction,
          ),
        );

        expect(seen.query, isEmpty);
        expect(seen.json, <String, Object?>{
          'title': 'Synthetic task',
          'status': 'needsAction',
        });
      },
    );

    test(
      'patches a complete supported snapshot and clears optionals with null',
      () async {
        late RecordedRequest seen;
        final server = await ScriptedMutationServer.start((request) async {
          seen = await RecordedRequest.read(request);
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(_taskJson('task-1')));
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final result = await service.patchTask(
          const PatchTaskOperation(
            taskListId: RemoteTaskListId('list-1'),
            taskId: RemoteTaskId('task-1'),
            etag: 'etag-current',
            title: 'Updated task',
            notes: OptionalFieldWrite<String>.clear(),
            status: RemoteTaskStatus.needsAction,
            due: OptionalFieldWrite<RemoteDate>.clear(),
          ),
        );

        expect(result, isA<CommittedMutation<RemoteTask>>());
        expect(seen.method, 'PATCH');
        expect(seen.path, '/tasks/v1/lists/list-1/tasks/task-1');
        expect(seen.query, isEmpty);
        expect(seen.ifMatch, 'etag-current');
        expect(seen.json, <String, Object?>{
          'title': 'Updated task',
          'notes': null,
          'status': 'needsAction',
          'due': null,
        });
      },
    );

    test('rejects optional clearing before the representation is admitted', () {
      expect(
        () =>
            const PatchTaskOperation(
              taskListId: RemoteTaskListId('list-1'),
              taskId: RemoteTaskId('task-1'),
              etag: 'etag-current',
              title: 'Updated task',
              notes: OptionalFieldWrite<String>.clear(),
              status: RemoteTaskStatus.needsAction,
              due: OptionalFieldWrite<RemoteDate>.set(RemoteDate(2026, 8, 16)),
            ).toRequest(
              endpoint: Uri.parse('https://tasks.example.test/tasks/v1/'),
              abortTrigger: Future<void>.value(),
              capabilities: const GoogleTasksMutationCapabilities(
                notesNullClearing: false,
                dueNullClearing: true,
              ),
            ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('patches nonempty optional fields with canonical values', () async {
      late RecordedRequest seen;
      final server = await ScriptedMutationServer.start((request) async {
        seen = await RecordedRequest.read(request);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_taskJson('task-1')));
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server);
      addTearDown(service.close);

      final result = await service.patchTask(
        const PatchTaskOperation(
          taskListId: RemoteTaskListId('list-1'),
          taskId: RemoteTaskId('task-1'),
          etag: 'etag-current',
          title: 'Updated task',
          notes: OptionalFieldWrite<String>.set('Updated notes'),
          status: RemoteTaskStatus.completed,
          due: OptionalFieldWrite<RemoteDate>.set(RemoteDate(2026, 8, 17)),
        ),
      );

      expect(result, isA<CommittedMutation<RemoteTask>>());
      expect(seen.json, <String, Object?>{
        'title': 'Updated task',
        'notes': 'Updated notes',
        'status': 'completed',
        'due': '2026-08-17T00:00:00.000Z',
      });
    });

    test(
      'deletes and moves tasks with current ETag and exact empty bodies',
      () async {
        final requests = <RecordedRequest>[];
        final server = await ScriptedMutationServer.start((request) async {
          requests.add(await RecordedRequest.read(request));
          if (request.method == 'DELETE') {
            request.response.statusCode = HttpStatus.noContent;
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode(_taskJson('task-1')));
          }
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final deleted = await service.deleteTask(
          const DeleteTaskOperation(
            taskListId: RemoteTaskListId('list-1'),
            taskId: RemoteTaskId('task-1'),
            etag: 'delete-etag',
            pathFreshness: MutationPathFreshness.current,
          ),
        );
        final moved = await service.moveTask(
          const MoveTaskOperation(
            sourceTaskListId: RemoteTaskListId('list-1'),
            taskId: RemoteTaskId('task-1'),
            etag: 'move-etag',
            destinationTaskListId: RemoteTaskListId('list-2'),
            parentId: RemoteTaskId('parent-2'),
            previousId: RemoteTaskId('previous-2'),
            pathFreshness: MutationPathFreshness.current,
          ),
        );

        expect(deleted, isA<CommittedMutation<void>>());
        expect(moved, isA<CommittedMutation<RemoteTask>>());
        expect(requests[0].method, 'DELETE');
        expect(requests[0].path, '/tasks/v1/lists/list-1/tasks/task-1');
        expect(requests[0].body, isEmpty);
        expect(requests[0].ifMatch, 'delete-etag');
        expect(requests[1].method, 'POST');
        expect(requests[1].path, '/tasks/v1/lists/list-1/tasks/task-1/move');
        expect(requests[1].query, <String, String>{
          'destinationTasklist': 'list-2',
          'parent': 'parent-2',
          'previous': 'previous-2',
        });
        expect(requests[1].body, isEmpty);
        expect(requests[1].contentType, 'application/json; charset=utf-8');
        expect(requests[1].ifMatch, 'move-etag');
      },
    );

    test(
      'moves to first top-level position by omitting placement query',
      () async {
        late RecordedRequest seen;
        final server = await ScriptedMutationServer.start((request) async {
          seen = await RecordedRequest.read(request);
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(_taskJson('task-1')));
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final result = await service.moveTask(
          const MoveTaskOperation(
            sourceTaskListId: RemoteTaskListId('list-1'),
            taskId: RemoteTaskId('task-1'),
            etag: 'move-etag',
            pathFreshness: MutationPathFreshness.current,
          ),
        );

        expect(result, isA<CommittedMutation<RemoteTask>>());
        expect(seen.query, isEmpty);
        expect(seen.body, isEmpty);
      },
    );
  });

  group('Google Tasks mutation result and error contract', () {
    test(
      'decodes canonical list and task mutation responses strictly',
      () async {
        var call = 0;
        final server = await ScriptedMutationServer.start((request) async {
          call += 1;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              call == 1 ? _taskListJson('list-1') : _taskJson('task-1'),
            ),
          );
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final listResult = await service.createTaskList(
          const CreateTaskListOperation(title: 'Synthetic list'),
        );
        final taskResult = await service.createTask(
          const CreateTaskOperation(
            taskListId: RemoteTaskListId('list-1'),
            title: 'Synthetic task',
            status: RemoteTaskStatus.needsAction,
          ),
        );

        expect(
          (listResult as CommittedMutation<RemoteTaskList>).value.id.value,
          'list-1',
        );
        expect(
          (taskResult as CommittedMutation<RemoteTask>).value.id.value,
          'task-1',
        );
      },
    );

    for (final fixture in <({int status, String body})>[
      (status: 200, body: '{"kind":"tasks#task"'),
      (status: 200, body: '{}'),
      (status: 200, body: ''),
      (status: 206, body: jsonEncode(_taskJson('task-1'))),
    ]) {
      test(
        'preserves malformed/truncated ${fixture.status} as uncertain',
        () async {
          final server = await ScriptedMutationServer.start((request) async {
            request.response.statusCode = fixture.status;
            request.response.headers.contentType = ContentType.json;
            request.response.write(fixture.body);
            await request.response.close();
          });
          addTearDown(server.close);
          final service = _service(server: server);
          addTearDown(service.close);

          final result = await service.createTask(
            const CreateTaskOperation(
              taskListId: RemoteTaskListId('list-1'),
              title: 'Synthetic task',
              status: RemoteTaskStatus.needsAction,
            ),
          );

          expect(result, isA<UncertainMutation<RemoteTask>>());
          final failure = (result as UncertainMutation<RemoteTask>).error;
          expect(failure.commitState, MutationCommitState.uncertain);
          expect(failure.failure.operation, FailureOperation.write);
        },
      );
    }

    test('rejects a nonempty or non-204 delete success as uncertain', () async {
      var call = 0;
      final server = await ScriptedMutationServer.start((request) async {
        call += 1;
        request.response.statusCode = 200;
        if (call == 1) request.response.write('unexpected');
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server);
      addTearDown(service.close);
      const operation = DeleteTaskListOperation(RemoteTaskListId('list-1'));

      final bodyResult = await service.deleteTaskList(operation);
      final statusResult = await service.deleteTaskList(operation);

      expect(bodyResult, isA<UncertainMutation<void>>());
      expect(statusResult, isA<UncertainMutation<void>>());
    });

    test('keeps a bounded 412 conclusive without decoding its body', () async {
      final server = await ScriptedMutationServer.start((request) async {
        request.response.statusCode = HttpStatus.preconditionFailed;
        request.response.write('x' * 128);
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server, maxResponseBytes: 16);
      addTearDown(service.close);

      final result = await service.patchTask(
        const PatchTaskOperation(
          taskListId: RemoteTaskListId('list-1'),
          taskId: RemoteTaskId('task-1'),
          etag: 'stale-etag',
          title: 'Updated task',
          notes: OptionalFieldWrite<String>.set('Updated notes'),
          status: RemoteTaskStatus.needsAction,
          due: OptionalFieldWrite<RemoteDate>.clear(),
        ),
      );

      expect(result, isA<RejectedMutation<RemoteTask>>());
      final error = (result as RejectedMutation<RemoteTask>).error;
      expect(error.kind, GoogleTasksErrorKind.conditional);
      expect(error.commitState, MutationCommitState.notCommitted);
    });

    test('keeps stale-source DELETE success conservative', () async {
      final server = await ScriptedMutationServer.start((request) async {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server);
      addTearDown(service.close);

      final result = await service.deleteTask(
        const DeleteTaskOperation(
          taskListId: RemoteTaskListId('old-list'),
          taskId: RemoteTaskId('task-1'),
          etag: 'etag-current',
          pathFreshness: MutationPathFreshness.possiblyStale,
        ),
      );

      expect(result, isA<UncertainMutation<void>>());
      final error = (result as UncertainMutation<void>).error;
      expect(error.kind, GoogleTasksErrorKind.stalePath);
      expect(error.commitState, MutationCommitState.uncertain);
    });

    test('keeps stale-source MOVE 404 conservative', () async {
      final server = await ScriptedMutationServer.start((request) async {
        request.response.statusCode = HttpStatus.notFound;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"error":{"code":404}}');
        await request.response.close();
      });
      addTearDown(server.close);
      final service = _service(server: server);
      addTearDown(service.close);

      final result = await service.moveTask(
        const MoveTaskOperation(
          sourceTaskListId: RemoteTaskListId('old-list'),
          taskId: RemoteTaskId('task-1'),
          etag: 'etag-current',
          destinationTaskListId: RemoteTaskListId('new-list'),
          pathFreshness: MutationPathFreshness.possiblyStale,
        ),
      );

      expect(result, isA<UncertainMutation<RemoteTask>>());
      expect(
        (result as UncertainMutation<RemoteTask>).error.kind,
        GoogleTasksErrorKind.stalePath,
      );
    });

    for (final fixture
        in <
          ({
            int status,
            String body,
            GoogleTasksErrorKind kind,
            MutationCommitState commitState,
            RetryClassification retry,
          })
        >[
          (
            status: 401,
            body: '{"error":{"status":"UNAUTHENTICATED"}}',
            kind: GoogleTasksErrorKind.authorization,
            commitState: MutationCommitState.notCommitted,
            retry: RetryClassification.unknown,
          ),
          (
            status: 403,
            body: '{"error":{"errors":[{"reason":"quotaExceeded"}]}}',
            kind: GoogleTasksErrorKind.quota,
            commitState: MutationCommitState.notCommitted,
            retry: RetryClassification.transient,
          ),
          (
            status: 403,
            body: '{"error":{"errors":[{"reason":"forbidden"}]}}',
            kind: GoogleTasksErrorKind.unknown,
            commitState: MutationCommitState.uncertain,
            retry: RetryClassification.unknown,
          ),
          (
            status: 404,
            body: '{"error":{"code":404}}',
            kind: GoogleTasksErrorKind.notFound,
            commitState: MutationCommitState.notCommitted,
            retry: RetryClassification.permanent,
          ),
          (
            status: 412,
            body: '{"error":{"code":412}}',
            kind: GoogleTasksErrorKind.conditional,
            commitState: MutationCommitState.notCommitted,
            retry: RetryClassification.permanent,
          ),
          (
            status: 429,
            body: 'not-json',
            kind: GoogleTasksErrorKind.quota,
            commitState: MutationCommitState.notCommitted,
            retry: RetryClassification.transient,
          ),
          (
            status: 503,
            body: '',
            kind: GoogleTasksErrorKind.transient,
            commitState: MutationCommitState.uncertain,
            retry: RetryClassification.transient,
          ),
          (
            status: 400,
            body: '{"error":{"code":400}}',
            kind: GoogleTasksErrorKind.permanent,
            commitState: MutationCommitState.notCommitted,
            retry: RetryClassification.permanent,
          ),
          (
            status: 418,
            body: '{"future":"shape"}',
            kind: GoogleTasksErrorKind.unknown,
            commitState: MutationCommitState.uncertain,
            retry: RetryClassification.unknown,
          ),
        ]) {
      test('maps mutation HTTP ${fixture.status} without retrying', () async {
        var calls = 0;
        final server = await ScriptedMutationServer.start((request) async {
          calls += 1;
          request.response.statusCode = fixture.status;
          request.response.headers.contentType = ContentType.json;
          request.response.headers.set(HttpHeaders.retryAfterHeader, '120');
          request.response.write(fixture.body);
          await request.response.close();
        });
        addTearDown(server.close);
        final service = _service(server: server);
        addTearDown(service.close);

        final result = await service.renameTaskList(
          const RenameTaskListOperation(
            taskListId: RemoteTaskListId('list-1'),
            title: 'Renamed',
          ),
        );

        expect(calls, 1);
        final error = switch (result) {
          RejectedMutation<RemoteTaskList>(:final error) => error,
          UncertainMutation<RemoteTaskList>(:final error) => error,
          _ => throw TestFailure('Expected a mutation error.'),
        };
        expect(error.kind, fixture.kind);
        expect(error.commitState, fixture.commitState);
        expect(error.failure.retry, fixture.retry);
        expect(
          error.failure.remoteContext?.retryAfter,
          const RetryAfterDelay(Duration(seconds: 120)),
        );
        if (fixture.body.isNotEmpty) {
          expect(error.failure.safeSummary, isNot(contains(fixture.body)));
        }
      });
    }

    test('transport loss after dispatch remains uncertain', () async {
      final history = InMemoryDiagnosticHistory();
      final service = HttpGoogleTasksService(
        client: ThrowingMutationClient(),
        authorization: const SyntheticAuthorization(subject),
        accountGuard: const DedicatedAccountGuard(subject),
        diagnostics: ProductionDiagnosticSink(history),
        endpoint: Uri.parse('https://tasks.example.test/tasks/v1/'),
      );
      addTearDown(service.close);

      final result = await service.createTaskList(
        const CreateTaskListOperation(title: 'Private synthetic list'),
      );

      expect(result, isA<UncertainMutation<RemoteTaskList>>());
      final error = (result as UncertainMutation<RemoteTaskList>).error;
      expect(error.kind, GoogleTasksErrorKind.transient);
      expect(error.commitState, MutationCommitState.uncertain);
      expect(history.records.single.renderedText, isNot(contains('Private')));
      expect(
        history.records.single.renderedText,
        isNot(contains('tasks.example.test')),
      );
    });

    test('timeout after dispatch remains uncertain', () async {
      final requestSeen = Completer<void>();
      final release = Completer<void>();
      final timeout = Completer<void>();
      final server = await ScriptedMutationServer.start((request) async {
        requestSeen.complete();
        await release.future;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_taskListJson('list-1')));
        await request.response.close();
      });
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await server.close();
      });
      final service = _service(
        server: server,
        timeoutSignal: (_) => timeout.future,
      );
      addTearDown(service.close);

      final pending = service.createTaskList(
        const CreateTaskListOperation(title: 'Synthetic list'),
      );
      await requestSeen.future;
      timeout.complete();
      final result = await pending;

      expect(result, isA<UncertainMutation<RemoteTaskList>>());
      expect(
        (result as UncertainMutation<RemoteTaskList>).error.kind,
        GoogleTasksErrorKind.transient,
      );
    });

    test('eligibility failures are conclusively not dispatched', () async {
      var calls = 0;
      final server = await ScriptedMutationServer.start((request) async {
        calls += 1;
        await request.response.close();
      });
      addTearDown(server.close);
      final service = HttpGoogleTasksService(
        client: BearerClient(http.Client()),
        authorization: const SyntheticAuthorization(subject),
        accountGuard: const DedicatedAccountGuard(
          AccountSubject('different-subject'),
        ),
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        endpoint: server.endpoint,
      );
      addTearDown(service.close);

      final result = await service.createTaskList(
        const CreateTaskListOperation(title: 'Synthetic list'),
      );

      expect(calls, 0);
      expect(result, isA<RejectedMutation<RemoteTaskList>>());
      expect(
        (result as RejectedMutation<RemoteTaskList>).error.commitState,
        MutationCommitState.notCommitted,
      );
    });
  });

  group('mutation diagnostics privacy', () {
    const contentCanary = 'PRIVATE_MUTATION_CANARY';
    const credentialCanary =
        'Bearer '
        'credential-canary-mutation-0123456789';

    Future<String> exercise(
      DiagnosticSink sink,
      InMemoryDiagnosticHistory history,
    ) async {
      final server = await ScriptedMutationServer.start((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            ..._taskListJson('private-list-id'),
            'title': contentCanary,
            'futureCredentialField': credentialCanary,
          }),
        );
        await request.response.close();
      });
      final service = _service(server: server, diagnostics: sink);
      try {
        await service.createTaskList(
          const CreateTaskListOperation(title: contentCanary),
        );
      } finally {
        service.close();
        await server.close();
      }
      return history.records.single.renderedText;
    }

    test('production excludes content, IDs, body, and URL', () async {
      final history = InMemoryDiagnosticHistory();
      final output = await exercise(ProductionDiagnosticSink(history), history);

      expect(output, contains('status=200'));
      expect(output, isNot(contains(contentCanary)));
      expect(output, isNot(contains('private-list-id')));
      expect(output, isNot(contains('tasks/v1')));
      expect(output, isNot(contains('credential-canary')));
    });

    test('development keeps content but always redacts credentials', () async {
      final history = InMemoryDiagnosticHistory();
      final output = await exercise(
        SensitiveDevelopmentDiagnosticSink(history),
        history,
      );

      expect(output, contains(contentCanary));
      expect(output, contains('private-list-id'));
      expect(output, contains('tasks/v1'));
      expect(output, isNot(contains('credential-canary')));
      expect(output, contains('[REDACTED]'));
    });
  });
}

HttpGoogleTasksService _service({
  required ScriptedMutationServer server,
  GoogleTasksMutationCapabilities capabilities =
      const GoogleTasksMutationCapabilities(),
  Future<void> Function(Duration)? timeoutSignal,
  DiagnosticSink? diagnostics,
  int maxResponseBytes = HttpGoogleTasksService.defaultMaxResponseBytes,
}) => HttpGoogleTasksService(
  client: BearerClient(http.Client()),
  authorization: const SyntheticAuthorization(subject),
  accountGuard: const DedicatedAccountGuard(subject),
  diagnostics:
      diagnostics ?? ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
  endpoint: server.endpoint,
  mutationCapabilities: capabilities,
  timeoutSignal: timeoutSignal,
  maxResponseBytes: maxResponseBytes,
);

Map<String, Object?> _taskListJson(String id) => <String, Object?>{
  'kind': 'tasks#taskList',
  'id': id,
  'etag': 'etag-$id',
  'title': 'Synthetic $id',
  'updated': '2026-08-15T18:30:12Z',
};

Map<String, Object?> _taskJson(String id) => <String, Object?>{
  'kind': 'tasks#task',
  'id': id,
  'etag': 'etag-$id',
  'title': 'Synthetic $id',
  'position': '0001',
  'status': 'needsAction',
  'updated': '2026-08-15T18:30:12Z',
};

final class RecordedRequest {
  const RecordedRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.accept,
    required this.contentType,
    required this.authorization,
    required this.ifMatch,
    required this.body,
  });

  static Future<RecordedRequest> read(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    return RecordedRequest(
      method: request.method,
      path: request.uri.path,
      query: request.uri.queryParameters,
      accept: request.headers.value(HttpHeaders.acceptHeader),
      contentType: request.headers.value(HttpHeaders.contentTypeHeader),
      authorization: request.headers.value(HttpHeaders.authorizationHeader),
      ifMatch: request.headers.value(HttpHeaders.ifMatchHeader),
      body: body,
    );
  }

  final String method;
  final String path;
  final Map<String, String> query;
  final String? accept;
  final String? contentType;
  final String? authorization;
  final String? ifMatch;
  final String body;

  Object? get json => jsonDecode(body);
}

final class ScriptedMutationServer {
  ScriptedMutationServer._(this._server, this._subscription);

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;

  Uri get endpoint =>
      Uri.parse('http://${_server.address.address}:${_server.port}/tasks/v1/');

  static Future<ScriptedMutationServer> start(
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
          // Intentional client aborts can close the scripted response.
        }
      }
    });
    return ScriptedMutationServer._(server, subscription);
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

final class ThrowingMutationClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw http.ClientException('synthetic response loss', request.url);
}
