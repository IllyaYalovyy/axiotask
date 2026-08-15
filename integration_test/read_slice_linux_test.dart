import 'dart:io';

import 'package:axiotask/src/app/axiotask_app.dart';
import 'package:axiotask/src/app/composition/app_composition.dart';
import 'package:axiotask/src/app/composition/test_composition.dart';
import 'package:axiotask/src/app/tasks_feature_runtime.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/fake_lifecycle.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryRoot;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp(
      'axiotask-read-slice-integration-',
    );
  });

  tearDown(() async {
    if (temporaryRoot.existsSync()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  testWidgets(
    'cold/warm launch, Refresh, and Linux resume verify cached data',
    (tester) async {
      final databaseFile = File('${temporaryRoot.path}/read-slice.sqlite');
      final firstComposition = _IntegrationComposition.success('cold-warm');
      final first = await TasksFeatureRuntime.open(
        firstComposition,
        injectedDatabase: await AppDatabase.openFile(databaseFile),
      );
      await first.start();
      expect(firstComposition.service.listCalls, 1);
      await first.close();

      final lifecycle = FakeLifecycle();
      final secondComposition = _IntegrationComposition.success('cold-warm');
      final second = await TasksFeatureRuntime.open(
        secondComposition,
        injectedDatabase: await AppDatabase.openFile(databaseFile),
        lifecycle: lifecycle,
      );
      addTearDown(second.close);
      addTearDown(lifecycle.close);

      await tester.pumpWidget(AxiotaskApp(viewModel: second.viewModel));
      await tester.pumpAndSettle();
      expect(find.text('Validated remote task'), findsOneWidget);
      expect(find.text('Pending'), findsWidgets);
      expect(find.text('Synced'), findsNothing);

      await second.start();
      await tester.pumpAndSettle();
      expect(find.text('Synced'), findsWidgets);
      expect(secondComposition.service.listCalls, 1);

      secondComposition.clock.advance(const Duration(minutes: 1));
      await tester.tap(find.widgetWithText(FilledButton, 'Refresh'));
      await second.coordinator!.whenIdle;
      await tester.pumpAndSettle();
      expect(secondComposition.service.listCalls, 2);
      expect(find.textContaining('2026-01-01 12:01 UTC'), findsOneWidget);

      secondComposition.clock.advance(const Duration(minutes: 1));
      lifecycle.enterBackground();
      lifecycle.acknowledgeCancellation();
      lifecycle.enterForeground();
      await second.coordinator!.whenIdle;
      await tester.pumpAndSettle();
      expect(secondComposition.service.listCalls, 3);
      expect(find.textContaining('2026-01-01 12:02 UTC'), findsOneWidget);
    },
  );

  testWidgets(
    'partial-data failure keeps prior validated cache visibly Failed',
    (tester) async {
      final databaseFile = File('${temporaryRoot.path}/partial.sqlite');
      final seedComposition = _IntegrationComposition.success('partial');
      final seed = await TasksFeatureRuntime.open(
        seedComposition,
        injectedDatabase: await AppDatabase.openFile(databaseFile),
      );
      await seed.start();
      await seed.close();

      final failedComposition = _IntegrationComposition(
        instanceId: 'partial',
        service: _IntegrationReadService(failTasks: true),
      );
      failedComposition.clock.advance(const Duration(minutes: 2));
      final runtime = await TasksFeatureRuntime.open(
        failedComposition,
        injectedDatabase: await AppDatabase.openFile(databaseFile),
      );
      addTearDown(runtime.close);
      await tester.pumpWidget(AxiotaskApp(viewModel: runtime.viewModel));
      await tester.pumpAndSettle();
      await runtime.start();
      await tester.pumpAndSettle();

      expect(find.text('Validated remote task'), findsOneWidget);
      expect(find.text('Failed'), findsWidgets);
      expect(find.text('No connection'), findsOneWidget);
      expect(find.textContaining('2026-01-01 12:00 UTC'), findsOneWidget);
    },
  );

  testWidgets(
    'malformed remote data is Failed and no authorization is Inactive',
    (tester) async {
      final malformedComposition = _IntegrationComposition(
        instanceId: 'malformed',
        service: _IntegrationReadService(malformedTask: true),
      );
      final malformed = await TasksFeatureRuntime.open(
        malformedComposition,
        injectedDatabase: AppDatabase.inMemory(),
      );
      await tester.pumpWidget(AxiotaskApp(viewModel: malformed.viewModel));
      await malformed.start();
      await tester.pumpAndSettle();
      expect(find.text('Application failure'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
      await malformed.close();

      final unavailableComposition = _IntegrationComposition(
        instanceId: 'no-authorization',
        service: _IntegrationReadService(),
        authorizationOverride: const UnavailableAuthorization(),
      );
      final unavailable = await TasksFeatureRuntime.open(
        unavailableComposition,
        injectedDatabase: AppDatabase.inMemory(),
      );
      addTearDown(unavailable.close);
      await tester.pumpWidget(AxiotaskApp(viewModel: unavailable.viewModel));
      await unavailable.start();
      await tester.pumpAndSettle();

      expect(find.text('Inactive'), findsWidgets);
      expect(find.text('No authorization'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
      expect(unavailableComposition.service.listCalls, 0);
    },
  );
}

final class _IntegrationComposition implements AppComposition {
  _IntegrationComposition({
    required String instanceId,
    required this.service,
    this.authorizationOverride,
  }) : _base = TestComposition.create(instanceId: instanceId);

  factory _IntegrationComposition.success(String instanceId) =>
      _IntegrationComposition(
        instanceId: instanceId,
        service: _IntegrationReadService(),
      );

  final TestComposition _base;
  final AuthorizationPort? authorizationOverride;
  final _IntegrationReadService service;

  @override
  ManualClock get clock => _base.clock;

  @override
  MonotonicScheduler get scheduler => clock;

  @override
  RandomSource get randomness => _base.randomness;

  @override
  AuthorizationPort get authorization =>
      authorizationOverride ?? _base.authorization;

  @override
  DiagnosticSink get diagnostics => _base.diagnostics;

  @override
  AccountGuard get accountGuard => _base.accountGuard;

  @override
  CompositionBoundary get boundary => _base.boundary;

  @override
  AccountSubject get configuredAccountSubject => _base.configuredAccountSubject;

  @override
  Future<ReadSliceTransport> createReadTransport(
    AccountSubject subject,
  ) async =>
      ReadSliceTransport(authorization: authorization, googleTasks: service);
}

final class _IntegrationReadService implements GoogleTasksService {
  _IntegrationReadService({this.failTasks = false, this.malformedTask = false});

  final bool failTasks;
  final bool malformedTask;
  var listCalls = 0;

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    listCalls += 1;
    return Outcome<RemotePage<RemoteTaskList>>.success(
      RemotePage<RemoteTaskList>(
        items: <RemoteTaskList>[
          RemoteTaskList(
            id: const RemoteTaskListId('integration-list'),
            etag: 'integration-list-etag',
            title: 'Validated remote list',
            updated: DateTime.utc(2026, 1, 1, 12),
            selfLink: null,
          ),
        ],
        collectionEtag: 'integration-lists-etag',
        nextPageToken: null,
      ),
    );
  }

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    if (failTasks) {
      return const Outcome<RemotePage<RemoteTask>>.failure(
        Failure(
          code: 'google_tasks.integration_connection',
          category: FailureCategory.network,
          operation: FailureOperation.read,
          retry: RetryClassification.transient,
          impact: 'Synthetic remote tasks were not verified.',
          action: FailureAction.retry,
          safeSummary: 'Synthetic connection failed.',
        ),
      );
    }
    return Outcome<RemotePage<RemoteTask>>.success(
      RemotePage<RemoteTask>(
        items: <RemoteTask>[
          RemoteLiveTask(
            id: const RemoteTaskId('integration-task'),
            etag: 'integration-task-etag',
            updated: DateTime.utc(2026, 1, 1, 12),
            selfLink: null,
            title: 'Validated remote task',
            parentId: null,
            position: malformedTask ? '' : '00000000000000000001',
            notes: 'Synthetic integration data.',
            status: RemoteTaskStatus.needsAction,
            due: null,
            completed: null,
            hidden: false,
            links: const <RemoteTaskLink>[],
            webViewLink: null,
          ),
        ],
        collectionEtag: 'integration-tasks-etag',
        nextPageToken: null,
      ),
    );
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) => throw UnsupportedError('Read-only integration.');
  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) => throw UnsupportedError('Read-only integration.');
  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => throw UnsupportedError('Read-only integration.');
  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => throw UnsupportedError('Read-only integration.');
  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) => throw UnsupportedError('Read-only integration.');
  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) => throw UnsupportedError('Read-only integration.');
  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => throw UnsupportedError('Read-only integration.');
  @override
  void close() {}
}
