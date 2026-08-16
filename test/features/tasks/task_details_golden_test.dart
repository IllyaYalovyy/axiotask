import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
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
    testWidgets('Linux long task details ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: const _TasksRepository(),
        syncHealthRepository: const _HealthRepository(),
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
      viewModel.selectTask(const TaskId(11));
      await tester.pump();

      await expectLater(
        find.byType(AdaptiveShell),
        matchesGoldenFile(
          '../../goldens/linux/task_details_long_${brightness.name}.png',
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
          remoteId: TaskListRemoteId('synthetic-detail-list'),
          title: 'Detail review',
        ),
        CachedTaskList(
          id: TaskListId(8),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-detail-archive'),
          title: 'Synthetic archive',
        ),
      ],
      tasks: const <CachedTask>[
        CachedTask(
          id: TaskId(11),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: null,
          remoteId: TaskRemoteId('synthetic-detail-parent'),
          title: 'Prepare a complete task-detail review',
          notes:
              'Planning notes — café, naïve, résumé.\n'
              'Keep multiline text exact and readable.\n'
              'Task text stays plain: <b>not markup</b>.\n'
              'The detail pane scrolls for longer content.\n'
              'No real account or personal data is present.',
          status: TaskStatus.needsAction,
          due: null,
        ),
        CachedTask(
          id: TaskId(12),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: TaskId(11),
          remoteId: TaskRemoteId('synthetic-detail-child-a'),
          title: 'Inspect multiline notes',
          notes: '',
          status: TaskStatus.completed,
          due: null,
        ),
        CachedTask(
          id: TaskId(13),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: TaskId(11),
          remoteId: TaskRemoteId('synthetic-detail-child-b'),
          title: 'Exercise subtask actions',
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
      const Outcome<TaskId>.success(TaskId(90));

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async => const Outcome.success(TaskDueChangeReceipt(undo: null));

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async => const Outcome.success(null);

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

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 2),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 15, 12),
    ),
  );
}
