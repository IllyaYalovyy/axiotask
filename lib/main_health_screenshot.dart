import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'src/app/adaptive_shell.dart';
import 'src/domain/model/tasks.dart';
import 'src/domain/repository/tasks_repository.dart';
import 'src/features/tasks/tasks_view_model.dart';
import 'src/sync/health/sync_health.dart';
import 'src/sync/health/sync_health_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _HealthScreenshotSequence());
}

final class _HealthScreenshotSequence extends StatefulWidget {
  const _HealthScreenshotSequence();

  @override
  State<_HealthScreenshotSequence> createState() =>
      _HealthScreenshotSequenceState();
}

final class _HealthScreenshotSequenceState
    extends State<_HealthScreenshotSequence> {
  final GlobalKey _boundaryKey = GlobalKey();
  var _index = 0;
  late TasksViewModel _viewModel = _createViewModel(_scenarios.first.health);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _captureAll());
  }

  Future<void> _captureAll() async {
    try {
      final output = Directory('screenshots/actual');
      await output.create(recursive: true);
      for (var index = 0; index < _scenarios.length; index += 1) {
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
        _viewModel.selectTask(const TaskId(11));
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
        final boundary =
            _boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (bytes == null) throw StateError('PNG encoding failed.');
        await File('${output.path}/${_scenarios[index].name}.png').writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true,
        );
        if (index + 1 < _scenarios.length) {
          final previous = _viewModel;
          setState(() {
            _index = index + 1;
            _viewModel = _createViewModel(_scenarios[_index].health);
          });
          WidgetsBinding.instance.scheduleFrame();
          await WidgetsBinding.instance.endOfFrame;
          previous.dispose();
        }
      }
      exit(0);
    } on Object catch (error) {
      stderr.writeln('Synthetic screenshot capture failed: $error');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _boundaryKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xff315da8),
          useMaterial3: true,
        ),
        home: AdaptiveShell(
          key: ValueKey<String>(_scenarios[_index].name),
          viewModel: _viewModel,
          onHealthAction: (_) {},
        ),
      ),
    );
  }
}

TasksViewModel _createViewModel(SyncHealth health) => TasksViewModel(
  accountId: const AccountId(1),
  tasksRepository: const _ScreenshotTasksRepository(),
  syncHealthRepository: _ScreenshotHealthRepository(health),
);

final class _ScreenshotTasksRepository implements TasksRepository {
  const _ScreenshotTasksRepository();

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => Stream.value(
    CachedTasksSnapshot(
      accountId: query.accountId,
      taskLists: const <CachedTaskList>[
        CachedTaskList(
          id: TaskListId(7),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-list'),
          title: 'Synthetic inbox',
        ),
      ],
      tasks: const <CachedTask>[
        CachedTask(
          id: TaskId(11),
          accountId: AccountId(1),
          taskListId: TaskListId(7),
          parentTaskId: null,
          remoteId: TaskRemoteId('synthetic-task'),
          title: 'Cached synthetic task',
          notes: 'No personal data is used in this screenshot.',
          status: TaskStatus.needsAction,
          due: null,
        ),
      ],
      completeness: CacheCompleteness.complete,
    ),
  );
}

final class _ScreenshotHealthRepository implements SyncHealthRepository {
  const _ScreenshotHealthRepository(this.health);

  final SyncHealth health;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(health);
}

final List<({String name, SyncHealth health})> _scenarios =
    <({String name, SyncHealth health})>[
      (
        name: 'health-cached-pending',
        health: _health(
          SyncHealthOutcome.pending,
          pendingReason: SyncPendingReason.verifying,
          counts: const SyncWorkCounts(pending: 2),
        ),
      ),
      (
        name: 'health-partial-failed',
        health: _health(
          SyncHealthOutcome.failed,
          failureReason: SyncFailureReason.remoteFailure,
          action: SyncHealthAction.retry,
          lastSuccessfulSyncAt: DateTime.utc(2026, 8, 15, 11, 58),
        ),
      ),
      (
        name: 'health-first-good',
        health: _health(
          SyncHealthOutcome.good,
          lastSuccessfulSyncAt: DateTime.utc(2026, 8, 15, 12),
        ),
      ),
      (
        name: 'health-stale-failed',
        health: _health(
          SyncHealthOutcome.failed,
          failureReason: SyncFailureReason.stale,
          action: SyncHealthAction.retry,
          lastSuccessfulSyncAt: DateTime.utc(2026, 8, 15, 11, 45),
          counts: const SyncWorkCounts(uncertain: 1),
        ),
      ),
      (
        name: 'health-no-authorization',
        health: _health(
          SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.noAuthorization,
          action: SyncHealthAction.reauthorize,
          counts: const SyncWorkCounts(pending: 2),
        ),
      ),
      (
        name: 'health-sync-stopped',
        health: _health(
          SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.syncStopped,
          action: SyncHealthAction.resume,
          counts: const SyncWorkCounts(pending: 3, uncertain: 1),
        ),
      ),
    ];

SyncHealth _health(
  SyncHealthOutcome outcome, {
  SyncInactiveReason? inactiveReason,
  SyncFailureReason? failureReason,
  SyncPendingReason? pendingReason,
  SyncHealthAction action = SyncHealthAction.none,
  DateTime? lastSuccessfulSyncAt,
  SyncWorkCounts counts = const SyncWorkCounts(),
}) => SyncHealth(
  outcome: outcome,
  inactiveReason: inactiveReason,
  failureReason: failureReason,
  pendingReason: pendingReason,
  action: action,
  counts: counts,
  lastSuccessfulSyncAt: lastSuccessfulSyncAt,
  evaluatedAt: DateTime.utc(2026, 8, 15, 12),
);
