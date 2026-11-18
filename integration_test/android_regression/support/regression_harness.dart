import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:axiotask/src/app/axiotask_app.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/data/preferences/preferences_repository.dart';
import 'package:axiotask/src/data/preferences/relational_preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/view_export_destination.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../../../test/support/touch_targets.dart';
import '../../../tool/android_regression/protocol.dart';

export '../../../tool/android_regression/protocol.dart' show CaseLabel;

/// The fixed instant every regression fixture observes (audit date, noon UTC).
final regressionNow = DateTime.utc(2026, 11, 15, 12);

/// Production application data directories always contain this segment;
/// isolated integration-test packages carry an `.integrationtest` suffix.
const _productionPackageSegment = '/com.axiotask.app/';

/// Phone portrait size used when the suite runs on a desktop host.
const _hostPhoneSize = Size(412, 900);

/// Builds a case's current-view export destination over its private fixture
/// [directory].
typedef ExportDestinationFactory = ViewExportDestination Function(
  Directory directory,
);

typedef RegressionBody = Future<void> Function(
  WidgetTester tester,
  RegressionFixture fixture,
);

void ensureRegressionBinding() =>
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();

/// Registers one manifest case with deterministic setup and teardown.
///
/// The harness prints protocol events so the host runner can tell an
/// assertion failure from missing execution or a teardown error. With
/// [phoneOnHost], a desktop host renders the app as Android does (touch
/// tap targets and Android theme), so phone touch contracts hold there too.
void regressionCase(
  String id,
  RegressionBody body, {
  CaseLabel label = CaseLabel.working,
  RegressionSeed seed = const RegressionSeed(),
  bool phoneOnHost = false,
  ExportDestinationFactory? exportDestination,
}) {
  testWidgets(id, (tester) async {
    final teardown = _Teardown(id);
    RegressionFixture? fixture;
    Object? failure;
    StackTrace? failureStack;
    try {
      await _prepareView(tester, teardown);
      if (phoneOnHost && !Platform.isAndroid) {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        teardown.add(
          'target platform',
          () async => debugDefaultTargetPlatformOverride = null,
        );
      }
      fixture = await RegressionFixture.open(
        id,
        seed: seed,
        exportDestination: exportDestination,
      );
      teardown.add('database and fixture files', fixture.close);
      _emit(
        EnvironmentEvent(
          id,
          platform: Platform.operatingSystem,
          logicalSize:
              '${tester.view.physicalSize / tester.view.devicePixelRatio}',
          devicePixelRatio: tester.view.devicePixelRatio,
        ),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: fixture._captureBoundary,
          child: AxiotaskApp(viewModel: fixture.model),
        ),
      );
      teardown.add('application widget tree', () async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      fixture.model.selectTaskList(fixture.list);
      await tester.pumpAndSettle();

      await body(tester, fixture);
      await fixture.capture(tester, 'end');
      expect(
        tester.takeException(),
        isNull,
        reason: 'No rendering or runtime exception may escape the flow',
      );
      _emit(CaseEvent(id, label: label, passed: true));
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
      _emit(CaseEvent(id, label: label, passed: false, error: '$error'));
      if (fixture != null) {
        await _guarded(() => fixture!.capture(tester, 'failure'));
      }
    }
    final teardownErrors = await teardown.run(tester);
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
    if (teardownErrors.isNotEmpty) {
      fail('Teardown of $id failed: ${teardownErrors.join('; ')}');
    }
  });
}

/// Synthetic rows added to the shared fixture for one case.
final class RegressionSeed {
  const RegressionSeed({
    this.extraTopLevelTitles = const <String>[],
    this.openChildTitles = const <String>[],
    this.completedChildTitles = const <String>[],
  });

  /// Open top-level tasks appended after the shared rows in manual order.
  final List<String> extraTopLevelTitles;

  /// Open, undated subtasks of the shared parent, after its open child.
  final List<String> openChildTitles;

  /// Already-completed subtasks of the shared parent, after its open child.
  final List<String> completedChildTitles;
}

/// Isolated synthetic account in a private file-backed SQLite database.
final class RegressionFixture {
  RegressionFixture._({
    required this.caseId,
    required this.directory,
    required this.database,
    required this.clock,
    required this.health,
    required this.devicePreferences,
    required this.preferences,
    required this.tasksRepository,
    required this.account,
    required this.list,
    required this.destination,
    required this.parent,
    required this.second,
    required this.child,
    required this.extraTasks,
    required this.openChildren,
    required this.completedChildren,
    required this.viewExportDestination,
  });

  final String caseId;
  final Directory directory;

  /// The open store; [restartApp] replaces it with a fresh connection.
  AppDatabase database;
  final ManualClock clock;
  final ControlledSyncHealth health;
  final InMemoryDevicePreferencesBackend devicePreferences;
  StoredPreferencesRepository preferences;
  DatabaseTasksRepository tasksRepository;
  final AccountId account;
  final TaskListId list;
  final TaskListId destination;
  final TaskId parent;
  final TaskId second;
  final TaskId child;
  final List<TaskId> extraTasks;
  final List<TaskId> openChildren;
  final List<TaskId> completedChildren;

  /// The case's export destination; without one no export is offered.
  final ViewExportDestination? viewExportDestination;
  late TasksViewModel model;

  /// Number of refresh requests the UI issued; nothing reaches Google.
  int refreshRequests = 0;

  final _captureBoundary = GlobalKey();
  final _capturedNames = <String>{};

  static Future<RegressionFixture> open(
    String caseId, {
    RegressionSeed seed = const RegressionSeed(),
    ExportDestinationFactory? exportDestination,
  }) async {
    final root = Platform.isAndroid
        ? await getTemporaryDirectory()
        : Directory.systemTemp;
    final directory = await root.createTemp('axiotask-regression-');
    if (Platform.isAndroid &&
        directory.path.contains(_productionPackageSegment)) {
      await directory.delete(recursive: true);
      throw StateError(
        'Regression fixtures must run in the isolated integration-test '
        'package, not the production installation: ${directory.path}',
      );
    }
    final database = await AppDatabase.openFile(
      _databaseFile(directory, caseId),
    );
    try {
      return await _seed(
        caseId,
        directory,
        database,
        seed,
        exportDestination?.call(directory),
      );
    } catch (_) {
      await database.close();
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  static Future<RegressionFixture> _seed(
    String caseId,
    Directory directory,
    AppDatabase database,
    RegressionSeed seed,
    ViewExportDestination? viewExportDestination,
  ) async {
    final account = AccountId(
      await database.createAccount('regression-synthetic-$caseId'),
    );
    final cache = CacheDao(database);
    final list = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('audit-list'),
      title: 'Audit tasks',
    );
    final destination = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('audit-destination'),
      title: 'Audit destination',
    );
    final parent = await cache.putTask(
      accountId: account,
      taskListId: list,
      remoteId: const TaskRemoteId('audit-parent'),
      title: 'Audit parent',
      notes: 'Audit notes https://example.com',
      position: '1',
      due: TaskDate(2026, 11, 15),
    );
    final second = await cache.putTask(
      accountId: account,
      taskListId: list,
      remoteId: const TaskRemoteId('audit-other'),
      title: 'Audit second task',
      position: '2',
    );
    final child = await cache.putTask(
      accountId: account,
      taskListId: list,
      remoteId: const TaskRemoteId('audit-child'),
      title: 'Audit child',
      position: '3',
      parentTaskId: parent,
      due: TaskDate(2026, 11, 14),
    );
    await cache.putTask(
      accountId: account,
      taskListId: destination,
      remoteId: const TaskRemoteId('audit-destination-task'),
      title: 'Audit destination task',
      position: '1',
    );
    final extraTasks = <TaskId>[
      for (final (index, title) in seed.extraTopLevelTitles.indexed)
        await cache.putTask(
          accountId: account,
          taskListId: list,
          remoteId: TaskRemoteId('audit-extra-$index'),
          title: title,
          position: '${4 + index}',
        ),
    ];
    final openChildren = <TaskId>[
      for (final (index, title) in seed.openChildTitles.indexed)
        await cache.putTask(
          accountId: account,
          taskListId: list,
          remoteId: TaskRemoteId('audit-open-child-$index'),
          title: title,
          position: '${4 + seed.extraTopLevelTitles.length + index}',
          parentTaskId: parent,
        ),
    ];
    final completedChildren = <TaskId>[
      for (final (index, title) in seed.completedChildTitles.indexed)
        await cache.putTask(
          accountId: account,
          taskListId: list,
          remoteId: TaskRemoteId('audit-completed-child-$index'),
          title: title,
          position:
              '${4 + seed.extraTopLevelTitles.length + seed.openChildTitles.length + index}',
          parentTaskId: parent,
          status: TaskStatus.completed,
        ),
    ];

    final clock = ManualClock(regressionNow);
    final tasksRepository = DatabaseTasksRepository(database, clock: clock);
    final seeded = (await tasksRepository
        .watchTasks(TasksQuery(accountId: account))
        .first);
    for (final task in seeded.tasks) {
      await cache.putTaskRemoteBase(
        accountId: account,
        taskId: task.id,
        taskListId: task.taskListId,
        remoteId: task.remoteId!,
        observedPublicationId: 'regression-base',
        deleted: false,
        parentTaskId: task.parentTaskId,
        title: task.title,
        notes: task.notes,
        status: task.status,
        due: task.due,
        position: task.id.value.toString(),
        etag: 'regression-etag',
      );
    }

    final devicePreferences = InMemoryDevicePreferencesBackend();
    final preferences = _preferences(database, devicePreferences);
    await preferences.setOnboardingDismissed(true);

    final fixture = RegressionFixture._(
      caseId: caseId,
      directory: directory,
      database: database,
      clock: clock,
      health: ControlledSyncHealth(),
      devicePreferences: devicePreferences,
      preferences: preferences,
      tasksRepository: tasksRepository,
      account: account,
      list: list,
      destination: destination,
      parent: parent,
      second: second,
      child: child,
      extraTasks: extraTasks,
      openChildren: openChildren,
      completedChildren: completedChildren,
      viewExportDestination: viewExportDestination,
    );
    fixture.model = fixture._createModel();
    return fixture;
  }

  TasksViewModel _createModel() => TasksViewModel(
    accountId: account,
    tasksRepository: tasksRepository,
    taskListsRepository: DatabaseTaskListsRepository(
      database: database,
      clock: clock,
    ),
    syncHealthRepository: health,
    clock: clock,
    preferencesRepository: preferences,
    refreshRequested: () async => refreshRequests += 1,
    viewExportDestination: viewExportDestination,
  );

  /// Restarts the application over the same SQLite file, as a process exit
  /// and relaunch would: the app is unmounted, its view model disposed and
  /// the store closed, then the file is opened by a new connection and a new
  /// view model and app are mounted on the seeded list. Everything the case
  /// reads afterwards comes from what SQLite durably stored.
  Future<void> restartApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    model.dispose();
    await database.close();
    database = await AppDatabase.openFile(_databaseFile(directory, caseId));
    tasksRepository = DatabaseTasksRepository(database, clock: clock);
    preferences = _preferences(database, devicePreferences);
    model = _createModel();
    await tester.pumpWidget(
      RepaintBoundary(
        key: _captureBoundary,
        child: AxiotaskApp(viewModel: model),
      ),
    );
    await tester.pumpAndSettle();
    model.selectTaskList(list);
    await tester.pumpAndSettle();
  }

  /// Reads the persisted account snapshot from SQLite, not view state.
  Future<CachedTasksSnapshot> snapshot() =>
      tasksRepository.watchTasks(TasksQuery(accountId: account)).first;

  Future<List<CachedTask>> tasks() async => (await snapshot()).tasks;

  Future<CachedTask?> taskOrNull(TaskId id) async =>
      (await tasks()).where((task) => task.id == id).firstOrNull;

  Future<CachedTask> task(TaskId id) async =>
      (await tasks()).singleWhere((task) => task.id == id);

  Finder row(TaskId id) => find.byKey(Key('desktop-task-row-${id.value}'));

  Future<void> openParent(WidgetTester tester) async {
    await tester.tap(find.text('Audit parent'));
    await tester.pumpAndSettle();
    expect(model.state.selectedTaskId, parent);
  }

  /// Captures the application surface as PNG and streams it to the runner.
  /// With [settle] false it captures the current frame, for states such as
  /// a pending command whose progress indicator never settles.
  Future<void> capture(
    WidgetTester tester,
    String name, {
    bool settle = true,
  }) async {
    if (!_capturedNames.add(name)) {
      throw ArgumentError.value(name, 'name', 'was already captured');
    }
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    final boundary =
        _captureBoundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      for (final event in ScreenshotChunkEvent.split(
        caseId,
        '${caseId}_$name',
        png!.buffer.asUint8List(),
      )) {
        _emit(event);
      }
    } finally {
      image.dispose();
    }
  }

  Future<void> close() async {
    model.dispose();
    await health.close();
    await database.close();
    await directory.delete(recursive: true);
  }
}

File _databaseFile(Directory directory, String caseId) =>
    File('${directory.path}/$caseId.sqlite');

StoredPreferencesRepository _preferences(
  AppDatabase database,
  InMemoryDevicePreferencesBackend devicePreferences,
) => StoredPreferencesRepository(
  relational: DriftRelationalPreferences(database),
  device: DevicePreferencesAdapter(
    backend: devicePreferences,
    namespace: 'regression',
    diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
  ),
);

/// Health source the test drives explicitly instead of a sync engine.
final class ControlledSyncHealth implements SyncHealthRepository {
  final _changes = StreamController<SyncHealth>.broadcast();
  SyncHealth _current = SyncHealth(
    outcome: SyncHealthOutcome.good,
    counts: const SyncWorkCounts(),
    lastSuccessfulSyncAt: regressionNow,
    evaluatedAt: regressionNow,
  );

  void set(SyncHealth next) {
    _current = next;
    _changes.add(next);
  }

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) async* {
    yield _current;
    yield* _changes.stream;
  }

  Future<void> close() => _changes.close();
}

/// Lays the application out at [viewport]'s logical size and text scale,
/// keeping the device pixel ratio. On Android the device is first rotated to
/// the viewport's orientation so system insets match a real rotation.
/// Harness teardown restores the view, text scale and orientation.
Future<void> usePhoneViewport(
  WidgetTester tester,
  PhoneViewport viewport,
) async {
  if (Platform.isAndroid) {
    final landscape = viewport.orientation == PhoneOrientation.landscape;
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      if (landscape)
        DeviceOrientation.landscapeLeft
      else
        DeviceOrientation.portraitUp,
    ]);
    tester.view.resetPhysicalSize();
    await settleUntil(
      tester,
      () =>
          (tester.view.physicalSize.width > tester.view.physicalSize.height) ==
          landscape,
      description: '${viewport.orientation.name} orientation',
    );
  }
  tester.view.physicalSize =
      viewport.logicalSize * tester.view.devicePixelRatio;
  tester.platformDispatcher.textScaleFactorTestValue = viewport.textScale;
  await tester.pumpAndSettle();
  expect(
    tester.view.physicalSize / tester.view.devicePixelRatio,
    viewport.logicalSize,
  );
}

/// Pumps frames until [condition] holds, failing with [description] on
/// timeout instead of sleeping for an arbitrary interval.
Future<void> settleUntil(
  WidgetTester tester,
  FutureOr<bool> Function() condition, {
  required String description,
  Duration timeout = const Duration(seconds: 10),
}) async {
  const step = Duration(milliseconds: 50);
  for (var waited = Duration.zero; waited < timeout; waited += step) {
    if (await condition()) {
      await tester.pumpAndSettle();
      return;
    }
    await tester.pump(step);
  }
  fail('Timed out after $timeout waiting for $description');
}

Future<void> _prepareView(WidgetTester tester, _Teardown teardown) async {
  if (Platform.isAndroid) {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    teardown.add(
      'orientation',
      () => SystemChrome.setPreferredOrientations(<DeviceOrientation>[]),
    );
    await settleUntil(
      tester,
      () => tester.view.physicalSize.height > tester.view.physicalSize.width,
      description: 'portrait orientation',
    );
    teardown.add('view size', () async => tester.view.reset());
  } else {
    tester.view
      ..physicalSize = _hostPhoneSize
      ..devicePixelRatio = 1;
    teardown.add('host view size', () async => tester.view.reset());
  }
  teardown.add('text scale', () async {
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  teardown.add('keyboard and focus', () async {
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await tester.pumpAndSettle();
  });
}

/// Ordered teardown that always runs every step and reports each failure.
final class _Teardown {
  _Teardown(this.caseId);

  final String caseId;
  final _steps = <(String, Future<void> Function())>[];

  void add(String name, Future<void> Function() step) =>
      _steps.add((name, step));

  /// Runs every step in reverse registration order and reports the errors.
  Future<List<String>> run(WidgetTester tester) async {
    final errors = <String>[];
    for (final (name, step) in _steps.reversed) {
      final error = await _guarded(step);
      if (error != null) errors.add('$name: $error');
    }
    final pending = tester.takeException();
    if (pending != null) errors.add('pending exception: $pending');
    _emit(TeardownEvent(caseId, errors: errors));
    return errors;
  }
}

Future<Object?> _guarded(Future<void> Function() step) async {
  try {
    await step();
    return null;
  } catch (error) {
    return error;
  }
}

// Protocol events are the host runner's input, so they are printed.
// ignore: avoid_print
void _emit(RegressionEvent event) => print(event.encode());
