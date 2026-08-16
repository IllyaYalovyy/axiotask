import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/domain/repository/preferences_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(_loadFlutterRoboto);

  for (final brightness in <Brightness>[Brightness.light, Brightness.dark]) {
    testWidgets('Linux smart views ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: const _TasksRepository(),
        preferencesRepository: const _PreferencesRepository(),
        syncHealthRepository: const _HealthRepository(),
        clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
      );
      addTearDown(viewModel.dispose);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: brightness,
            colorSchemeSeed: const Color(0xff315da8),
            fontFamily: 'GoldenRoboto',
            useMaterial3: true,
          ),
          home: AdaptiveShell(viewModel: viewModel),
        ),
      );
      await tester.pump();
      viewModel.selectSmartView(SmartView.focus);
      viewModel.selectTask(const TaskId(11));
      await tester.pump();

      await expectLater(
        find.byType(AdaptiveShell),
        matchesGoldenFile(
          '../../goldens/linux/smart_views_${brightness.name}.png',
        ),
      );
    });
  }
}

Future<void> _loadFlutterRoboto() async {
  final packageConfig = File('.dart_tool/package_config.json');
  final document = jsonDecode(await packageConfig.readAsString());
  final packages =
      (document as Map<String, Object?>)['packages']! as List<Object?>;
  final flutter = packages.cast<Map<String, Object?>>().singleWhere(
    (value) => value['name'] == 'flutter',
  );
  final configUri = packageConfig.absolute.uri;
  final flutterPackage = Directory.fromUri(
    configUri.resolve(flutter['rootUri']! as String),
  );
  final flutterRoot = flutterPackage.parent.parent;
  final fontFile = File(
    '${flutterRoot.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  if (!fontFile.existsSync()) {
    throw StateError('The locked Flutter SDK Roboto font is unavailable.');
  }
  final bytes = await fontFile.readAsBytes();
  await (FontLoader('GoldenRoboto')..addFont(
        Future<ByteData>.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
        ),
      ))
      .load();
}

final class _TasksRepository implements TasksRepository {
  const _TasksRepository();

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => Stream.value(
    CachedTasksSnapshot(
      accountId: query.accountId,
      taskLists: const <CachedTaskList>[
        CachedTaskList(
          id: TaskListId(7),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-smart-inbox'),
          title: 'Focus lab',
        ),
        CachedTaskList(
          id: TaskListId(8),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-smart-plans'),
          title: 'Future plans',
        ),
      ],
      tasks: <CachedTask>[
        _task(11, title: 'Prepare the smart-view review'),
        _task(
          12,
          title: 'Inspect inherited date',
          parent: 11,
          due: TaskDate(2026, 8, 16),
        ),
        _task(13, title: 'Review overdue section', due: TaskDate(2026, 8, 13)),
        _task(
          14,
          title: 'Confirm visible row counts',
          list: 8,
          due: TaskDate(2026, 8, 15),
        ),
        _task(
          15,
          title: 'Later than Focus',
          list: 8,
          due: TaskDate(2026, 9, 15),
        ),
      ],
      completeness: CacheCompleteness.complete,
    ),
  );

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream.value(const <TaskDeleteUndo>[]);

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async =>
      const Outcome<TaskId>.success(TaskId(99));

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async => Outcome<TaskDeleteReceipt>.success(
    TaskDeleteReceipt(taskId: command.taskId, notBefore: DateTime.utc(2026)),
  );

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      const Outcome<void>.success(null);
}

final class _PreferencesRepository implements PreferencesRepository {
  const _PreferencesRepository();

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) => Stream.value(const <TaskListId, ListPreferences>{});

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) => Stream.value(const <ViewKey, ViewPreferences>{});

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => Stream.value(const ListPreferences.defaults());

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) => Stream.value(const ViewPreferences.defaults());

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Stream<DevicePreferences> watchDevicePreferences() =>
      Stream.value(const DevicePreferences.defaults());

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async =>
      const Outcome<void>.success(null);
}

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 15, 12),
    ),
  );
}

CachedTask _task(
  int id, {
  required String title,
  int list = 7,
  int? parent,
  TaskDate? due,
}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: TaskListId(list),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: TaskRemoteId('synthetic-smart-$id'),
  title: title,
  notes: id == 11 ? 'Synthetic projection evidence.' : null,
  status: TaskStatus.needsAction,
  due: due,
);
