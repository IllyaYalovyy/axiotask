import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/app/navigation_state.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
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
    testWidgets('Linux search and navigation ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final navigation = AppNavigationController();
      final model = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: const _TasksRepository(),
        syncHealthRepository: const _HealthRepository(),
      );
      addTearDown(navigation.dispose);
      addTearDown(model.dispose);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: brightness,
            colorSchemeSeed: const Color(0xff315da8),
            fontFamily: 'GoldenRoboto',
            useMaterial3: true,
          ),
          home: AdaptiveShell(viewModel: model, navigation: navigation),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Search tasks'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search-input')), 'needle');
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(AdaptiveShell),
        matchesGoldenFile(
          '../../goldens/linux/search_results_${brightness.name}.png',
        ),
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(600, 800);
      await tester.pump();
      await tester.tap(find.byTooltip('Open navigation'));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(AdaptiveShell),
        matchesGoldenFile(
          '../../goldens/linux/navigation_back_${brightness.name}.png',
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
          remoteId: TaskListRemoteId('synthetic-search-list'),
          title: 'Search lab',
        ),
      ],
      tasks: const <CachedTask>[
        CachedTask(
          id: TaskId(11),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: null,
          remoteId: TaskRemoteId('synthetic-search-parent'),
          title: 'Plan the synthetic release',
          notes: 'A needle appears in these safe notes.',
          status: TaskStatus.needsAction,
          due: null,
        ),
        CachedTask(
          id: TaskId(12),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: TaskId(11),
          remoteId: TaskRemoteId('synthetic-search-child'),
          title: 'Verify needle context 世界',
          notes: null,
          status: TaskStatus.needsAction,
          due: null,
        ),
        CachedTask(
          id: TaskId(13),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: null,
          remoteId: TaskRemoteId('synthetic-search-second'),
          title: 'Review another needle result',
          notes: null,
          status: TaskStatus.needsAction,
          due: null,
        ),
      ],
      completeness: CacheCompleteness.complete,
    ),
  );

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream.value(const <TaskDeleteUndo>[]);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => Stream.value(const <TaskDueChangeUndo>[]);

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async =>
      const Outcome.success(TaskId(90));

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async =>
      const Outcome.success(null);

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async => const Outcome.success(TaskDueChangeReceipt(undo: null));

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async => Outcome.success(
    TaskDeleteReceipt(taskId: command.taskId, notBefore: DateTime.utc(2026)),
  );

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      const Outcome.success(null);

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async => const Outcome.success(null);
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
      evaluatedAt: DateTime.utc(2026, 8, 16, 12),
    ),
  );
}
