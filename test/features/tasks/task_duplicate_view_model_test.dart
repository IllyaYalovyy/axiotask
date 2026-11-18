// Duplicate from task details over the real SQLite repository: the copy
// follows the v1.5.3 rule from what the editor shows, the source stays open
// with a confirmation leading to the copy, a repeated tap makes one copy, and
// failures store nothing and leave a later Duplicate free to succeed once.
import 'dart:async';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/task_content_autosave.dart';
import 'package:axiotask/src/features/tasks/task_detail_view_model.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Session session;

  setUp(() async {
    session = await _Session.open();
  });

  tearDown(() => session.close());

  List<CachedTask> copies(String title) => session.model.state.tasks
      .where((task) => task.title == title)
      .toList(growable: false);

  test('copies the open task by the shared rule and keeps it open', () async {
    session.model.selectTask(session.parent);
    final detail = session.detail;
    expect(detail.state!.canDuplicate, isTrue);

    await detail.duplicate(session.parent);
    await session.until(() => copies('Groceries (copy)').isNotEmpty);

    final copy = copies('Groceries (copy)').single;
    expect(copy.id, isNot(session.parent));
    expect(copy.notes, isNull);
    expect(copy.due, isNull);
    expect(copy.status, TaskStatus.needsAction);
    expect(copy.parentTaskId, isNull);
    expect(copy.remoteId, isNull);
    expect(
      session.model.state.tasks.where((task) => task.parentTaskId == copy.id),
      isEmpty,
    );
    expect(session.model.state.selectedTaskId, session.parent);
    expect(detail.state!.duplicated?.taskId, copy.id);
    expect(detail.state!.duplicated?.title, 'Groceries (copy)');
    expect(session.syncWakeUps, 1);
    expect(
      (await session.intent(copy.id))?.state,
      DesiredStateLifecycle.pending,
    );

    detail.select(detail.state!.duplicated!.taskId);
    expect(session.model.state.selectedTaskId, copy.id);
    expect(
      session.detail.state!.duplicated,
      isNull,
      reason: 'the confirmation belongs to the source it was made from',
    );

    session.clock.advance(TasksViewModel.transientFeedbackDuration);
    expect(session.model.state.transientFeedback, isNull);
  });

  test('a subtask is copied under the same parent', () async {
    session.model.selectTask(session.child);

    await session.detail.duplicate(session.child);
    await session.until(() => copies('Milk (copy)').isNotEmpty);

    expect(copies('Milk (copy)').single.parentTaskId, session.parent);
  });

  test('a title typed but not yet saved is duplicated as typed', () async {
    session.model.selectTask(session.parent);
    final autosave = session.model.contentAutosave;
    autosave.open(session.stored(session.parent));
    autosave.edit(session.parent, title: 'Apricots', notes: 'Parent notes');

    await session.detail.duplicate(session.parent);
    await session.until(() => copies('Apricots (copy)').isNotEmpty);

    expect(session.stored(session.parent).title, 'Apricots');
    expect(copies('Groceries (copy)'), isEmpty);
    await autosave.close(session.parent);
  });

  test('edits that cannot be stored block the copy', () async {
    session.model.selectTask(session.parent);
    final autosave = session.model.contentAutosave;
    autosave.open(session.stored(session.parent));
    autosave.edit(session.parent, title: 'Unsaved', notes: 'Parent notes');
    session.failWrites = true;
    final tasksBefore = session.model.state.tasks.length;

    await session.detail.duplicate(session.parent);

    expect(
      autosave.draft(session.parent)?.status,
      TaskContentSaveStatus.failed,
    );
    expect(
      session.model.state.taskCommandFailureMessage,
      'The task edits are not saved, so the task was not duplicated.',
    );
    expect(session.model.state.tasks, hasLength(tasksBefore));
    expect(await session.taskRows(), tasksBefore);
    expect(session.syncWakeUps, 0);
    session.failWrites = false;
    await autosave.close(session.parent);
  });

  test('a repeated tap while Duplicate runs makes one copy', () async {
    session.model.selectTask(session.parent);
    final detail = session.detail;

    final first = detail.duplicate(session.parent);
    final second = detail.duplicate(session.parent);
    expect(session.model.state.isTaskCommandPending, isTrue);
    await Future.wait(<Future<void>>[first, second]);
    await session.until(() => copies('Groceries (copy)').isNotEmpty);
    await pumpEventQueue();

    expect(copies('Groceries (copy)'), hasLength(1));
    expect(await session.taskRows(), 4);
  });

  test('a failed Duplicate stores nothing; a retry stores one copy', () async {
    session.model.selectTask(session.parent);
    session.failWrites = true;

    await session.detail.duplicate(session.parent);

    expect(
      session.model.state.taskCommandFailureMessage,
      'The task could not be saved safely.',
    );
    expect(await session.taskRows(), 3);
    expect(session.detail.state!.duplicated, isNull);
    expect(session.syncWakeUps, 0);

    session.failWrites = false;
    await session.detail.duplicate(session.parent);
    await session.until(() => copies('Groceries (copy)').isNotEmpty);

    expect(session.model.state.taskCommandFailureMessage, isNull);
    expect(copies('Groceries (copy)'), hasLength(1));
    expect(await session.taskRows(), 4);
  });
}

final class _Session {
  _Session._(this.database, this.clock);

  final AppDatabase database;
  final ManualClock clock;
  late final TasksViewModel model;
  late final AccountId account;
  late final TaskId parent;
  late final TaskId child;
  var failWrites = false;
  var syncWakeUps = 0;

  TaskDetailViewModel get detail =>
      TaskDetailViewModel.fromTasks(model, navigateToTask: model.selectTask);

  static Future<_Session> open() async {
    final session = _Session._(
      AppDatabase.inMemory(),
      ManualClock(DateTime.utc(2026, 11, 17, 12)),
    );
    session.account = AccountId(
      await session.database.createAccount('synthetic-duplicate-detail'),
    );
    final cache = CacheDao(session.database);
    final list = await cache.putTaskList(
      accountId: session.account,
      remoteId: const TaskListRemoteId('duplicate-list'),
      title: 'Duplicate list',
    );
    session.parent = await cache.putTask(
      accountId: session.account,
      taskListId: list,
      remoteId: const TaskRemoteId('duplicate-parent'),
      title: 'Groceries',
      notes: 'Parent notes',
      due: TaskDate(2026, 11, 20),
      position: '1',
    );
    session.child = await cache.putTask(
      accountId: session.account,
      taskListId: list,
      parentTaskId: session.parent,
      remoteId: const TaskRemoteId('duplicate-child'),
      title: 'Milk',
      status: TaskStatus.completed,
      position: '1',
    );
    await cache.putTask(
      accountId: session.account,
      taskListId: list,
      remoteId: const TaskRemoteId('duplicate-other'),
      title: 'Other',
      position: '2',
    );
    session.model = TasksViewModel(
      accountId: session.account,
      tasksRepository: DatabaseTasksRepository(
        session.database,
        clock: session.clock,
        transactionControl: (boundary) {
          if (session.failWrites &&
              boundary == DesiredStateTransactionBoundary.beforeLocalCommit) {
            throw const DesiredStatePersistenceException('synthetic_failure');
          }
        },
      ),
      syncHealthRepository: const _Health(),
      clock: session.clock,
      localEditCommitted: () async => session.syncWakeUps += 1,
    );
    session.model.start();
    await session.until(
      () =>
          !session.model.state.isLoading &&
          session.model.state.tasks.isNotEmpty,
    );
    return session;
  }

  CachedTask stored(TaskId id) =>
      model.state.tasks.singleWhere((task) => task.id == id);

  Future<TaskDesiredStateRecord?> intent(TaskId id) =>
      DesiredStateDao(database).readTask(account, id);

  Future<int> taskRows() async =>
      (await database
              .customSelect('SELECT COUNT(*) AS c FROM tasks')
              .getSingle())
          .read<int>('c');

  Future<void> until(bool Function() condition) async {
    for (var attempt = 0; attempt < 500; attempt += 1) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('condition not reached');
  }

  Future<void> close() async {
    model.dispose();
    await database.close();
  }
}

final class _Health implements SyncHealthRepository {
  const _Health();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 11, 17, 12),
    ),
  );
}
