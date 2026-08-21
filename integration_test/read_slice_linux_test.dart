import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:axiotask/src/app/axiotask_app.dart';
import 'package:axiotask/src/app/composition/app_composition.dart';
import 'package:axiotask/src/app/composition/test_composition.dart';
import 'package:axiotask/src/app/lifecycle.dart';
import 'package:axiotask/src/app/tasks_feature_runtime.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
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
      _useLinuxTestSurface(tester);
      final databaseFile = File('${temporaryRoot.path}/read-slice.sqlite');
      final firstComposition = _IntegrationComposition.success('cold-warm');
      final preferences = _dismissedPreferences(firstComposition);
      final first = await TasksFeatureRuntime.open(
        firstComposition,
        injectedDatabase: await AppDatabase.openFile(databaseFile),
        injectedDevicePreferencesBackend: preferences,
      );
      await first.start();
      expect(firstComposition.service.listCalls, 1);
      await first.close();

      final lifecycle = FakeLifecycle();
      final secondComposition = _IntegrationComposition.success('cold-warm');
      final second = await TasksFeatureRuntime.open(
        secondComposition,
        injectedDatabase: await AppDatabase.openFile(databaseFile),
        injectedDevicePreferencesBackend: preferences,
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
      await tester.tap(find.byTooltip('Refresh'));
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
        injectedDevicePreferencesBackend: _dismissedPreferences(
          seedComposition,
        ),
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
        injectedDevicePreferencesBackend: _dismissedPreferences(
          failedComposition,
        ),
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
        injectedDevicePreferencesBackend: _dismissedPreferences(
          malformedComposition,
        ),
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
        injectedDevicePreferencesBackend: _dismissedPreferences(
          unavailableComposition,
        ),
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

  testWidgets('Linux minimize and unfocus remain cadence eligible', (
    tester,
  ) async {
    final composition = _IntegrationComposition.success('linux-focus');
    final lifecycle = LinuxLifecycleBridge();
    final runtime = await TasksFeatureRuntime.open(
      composition,
      injectedDatabase: AppDatabase.inMemory(),
      injectedDevicePreferencesBackend: _dismissedPreferences(composition),
      lifecycle: lifecycle,
    );
    addTearDown(runtime.close);
    addTearDown(lifecycle.close);

    await tester.pumpWidget(AxiotaskApp(viewModel: runtime.viewModel));
    await runtime.start();
    expect(composition.service.listCalls, 1);

    lifecycle.didChangeViewFocus(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
    composition.clock.advance(const Duration(minutes: 5));
    await runtime.coordinator!.whenIdle;

    expect(lifecycle.currentEligibility, LifecycleEligibility.foreground);
    expect(lifecycle.isWindowFocused, isFalse);
    expect(composition.service.listCalls, 2);
  });

  testWidgets(
    'Stop survives restart and preserves auth, cache, and stopped-work fixture',
    (tester) async {
      _useLinuxTestSurface(tester);
      final databaseFile = File('${temporaryRoot.path}/stop-resume.sqlite');
      final firstComposition = _IntegrationComposition.success('stop-resume');
      final preferences = _dismissedPreferences(firstComposition);
      final first = await TasksFeatureRuntime.open(
        firstComposition,
        injectedDatabase: await AppDatabase.openFile(databaseFile),
        injectedDevicePreferencesBackend: preferences,
      );
      await tester.pumpWidget(AxiotaskApp(viewModel: first.viewModel));
      await first.start();
      await tester.pumpAndSettle();
      expect(find.text('Validated remote task'), findsOneWidget);

      await tester.tap(find.byTooltip('Stop sync'));
      await tester.pumpAndSettle();
      expect(find.text('Sync stopped'), findsOneWidget);
      expect(
        firstComposition.authorization.currentState,
        isA<TasksAuthorized>(),
      );
      final cached = first.viewModel.state.tasks.single;
      await first.viewModel.updateTaskContent(
        taskId: cached.id,
        title: 'Edited while sync is stopped',
        notes: cached.notes,
        status: cached.status,
        due: cached.due,
      );
      await tester.pumpAndSettle();
      expect(find.text('Edited while sync is stopped'), findsOneWidget);
      expect(find.text('1 unresolved'), findsOneWidget);
      firstComposition.clock.advance(const Duration(minutes: 10));
      await first.coordinator!.refresh();
      expect(firstComposition.service.listCalls, 1);
      await first.close();

      final secondComposition = _IntegrationComposition.success('stop-resume');
      final second = await TasksFeatureRuntime.open(
        secondComposition,
        injectedDatabase: await AppDatabase.openFile(databaseFile),
        injectedDevicePreferencesBackend: preferences,
      );
      addTearDown(second.close);
      await tester.pumpWidget(AxiotaskApp(viewModel: second.viewModel));
      await tester.pumpAndSettle();
      await second.start();
      await tester.pumpAndSettle();

      expect(secondComposition.service.listCalls, 0);
      expect(find.text('Edited while sync is stopped'), findsOneWidget);
      expect(find.text('Sync stopped'), findsOneWidget);
      expect(find.text('1 unresolved'), findsOneWidget);
      final stoppedFacts = await SyncHealthDao(
        second.database,
      ).watchFacts(second.viewModel.accountId).first;
      expect(
        stoppedFacts.requiredScopeIncomplete,
        isFalse,
        reason: 'stopped facts: $stoppedFacts',
      );
      expect(stoppedFacts.counts.failed, 0, reason: '$stoppedFacts');
      expect(stoppedFacts.latestFailure, isNull, reason: '$stoppedFacts');

      final resumeRead = secondComposition.service.holdNextListRead();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Resume'));
      await resumeRead.entered;
      await tester.pump();
      expect(
        second.viewModel.state.health.outcome,
        SyncHealthOutcome.pending,
        reason:
            'runtime=${second.coordinator!.currentFacts}; '
            'health=${second.viewModel.state.health.reasonLabel}; '
            'code=${second.viewModel.state.health.diagnosticCode}',
      );
      expect(find.text('Pending'), findsWidgets);
      expect(find.text('1 unresolved'), findsOneWidget);

      resumeRead.release();
      await second.coordinator!.whenIdle;
      await tester.pumpAndSettle();
      expect(secondComposition.service.listCalls, 1);
      expect(secondComposition.service.patchCalls, 1);
      expect(find.text('Synced'), findsWidgets);
      expect(find.text('0 unresolved'), findsOneWidget);
    },
  );
}

void _useLinuxTestSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1024, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

InMemoryDevicePreferencesBackend _dismissedPreferences(
  AppComposition composition,
) => InMemoryDevicePreferencesBackend(
  initialValues: <String, Object>{
    '${composition.boundary.storage.preferencesNamespace}'
            '.onboarding_dismissed':
        true,
  },
);

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
    AccountSubject? subject,
  ) async =>
      ReadSliceTransport(authorization: authorization, googleTasks: service);
}

final class _IntegrationReadService implements GoogleTasksService {
  _IntegrationReadService({this.failTasks = false, this.malformedTask = false});

  final bool failTasks;
  final bool malformedTask;
  var listCalls = 0;
  var patchCalls = 0;
  _ListReadBarrier? _nextListRead;

  _ListReadBarrier holdNextListRead() {
    if (_nextListRead != null) {
      throw StateError('A list-read barrier is already active.');
    }
    return _nextListRead = _ListReadBarrier();
  }

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    listCalls += 1;
    final barrier = _nextListRead;
    _nextListRead = null;
    if (barrier != null) {
      barrier.markEntered();
      await barrier.released;
    }
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
          // Request/backoff behavior has dedicated deterministic coverage.
          // This fixture isolates cache preservation and health projection.
          retry: RetryClassification.permanent,
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
  ) async {
    patchCalls += 1;
    return CommittedMutation<RemoteTask>(
      RemoteLiveTask(
        id: operation.taskId,
        etag: 'integration-task-patched-etag',
        updated: DateTime.utc(2026, 1, 1, 12, 10),
        selfLink: null,
        title: operation.title,
        parentId: null,
        position: '00000000000000000001',
        notes: switch (operation.notes) {
          SetOptionalField<String>(:final value) => value,
          ClearOptionalField<String>() => null,
        },
        status: operation.status,
        due: switch (operation.due) {
          SetOptionalField<RemoteDate>(:final value) => value,
          ClearOptionalField<RemoteDate>() => null,
        },
        completed: operation.status == RemoteTaskStatus.completed
            ? DateTime.utc(2026, 1, 1, 12, 10)
            : null,
        hidden: false,
        links: const <RemoteTaskLink>[],
        webViewLink: null,
      ),
    );
  }

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

final class _ListReadBarrier {
  final Completer<void> _entered = Completer<void>();
  final Completer<void> _released = Completer<void>();

  Future<void> get entered => _entered.future;
  Future<void> get released => _released.future;

  void markEntered() => _entered.complete();
  void release() => _released.complete();
}
