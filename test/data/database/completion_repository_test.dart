import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/bulk_operations.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/completion_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late File file;
  late AppDatabase database;
  late ManualClock clock;
  late _Fixture f;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('axiotask-completion-');
    file = File('${root.path}/completion.sqlite');
    clock = ManualClock(DateTime.utc(2026, 11, 16, 12));
    database = await AppDatabase.openFile(file);
    f = await _seed(database);
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  Future<void> reopen() async {
    await database.close();
    database = await AppDatabase.openFile(file);
  }

  test(
    'parent completion is atomic, offline, and survives reopening',
    () async {
      final repository = DatabaseTasksRepository(database, clock: clock);

      final receipt = _value(
        await repository.setTaskCompletion(f.complete(f.parent)),
      );

      expect(receipt.changedTaskIds, <TaskId>[f.parent, f.openChild]);
      final undo = receipt.undo!;
      expect(undo.title, 'Parent');
      expect(undo.completedCount, 2);
      expect(undo.cascadedCount, 1);
      expect(undo.expiresAt, clock.now().add(taskCompletionUndoWindow));
      await _expectStatuses(database, f, completed: {f.parent, f.openChild});
      await _expectIntent(database, f, <TaskId, TaskStatus>{
        f.parent: TaskStatus.completed,
        f.openChild: TaskStatus.completed,
      });

      await reopen();
      await _expectStatuses(database, f, completed: {f.parent, f.openChild});
      await _expectIntent(database, f, <TaskId, TaskStatus>{
        f.parent: TaskStatus.completed,
        f.openChild: TaskStatus.completed,
      });
      final restarted = DatabaseTasksRepository(database, clock: clock);
      final afterRestart = await restarted.undoTaskCompletion(
        f.undo(undo.operationId),
      );
      expect(
        _failureCode(afterRestart),
        'task.completion_undo_unavailable',
        reason: 'an Undo offer belongs to the running application',
      );
      await _expectStatuses(database, f, completed: {f.parent, f.openChild});
    },
  );

  test('completing a subtask alone leaves its parent open', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);

    final receipt = _value(
      await repository.setTaskCompletion(f.complete(f.openChild)),
    );

    expect(receipt.changedTaskIds, <TaskId>[f.openChild]);
    expect(receipt.undo?.cascadedCount, 0);
    expect(receipt.undo?.title, 'Open child');
    await _expectStatuses(database, f, completed: {f.openChild});
    await _expectIntent(database, f, <TaskId, TaskStatus>{
      f.openChild: TaskStatus.completed,
    });
  });

  test(
    'Undo restores exactly the changed statuses and keeps later edits',
    () async {
      final repository = DatabaseTasksRepository(database, clock: clock);
      final undo = _value(
        await repository.setTaskCompletion(f.complete(f.parent)),
      ).undo!;
      clock.advance(const Duration(seconds: 5));
      expect(
        await repository.apply(
          SetTaskTitleCommand(
            accountId: f.account,
            taskId: f.openChild,
            title: 'Child edited after completion',
          ),
        ),
        isA<Success<void>>(),
      );
      expect(
        await repository.apply(
          SetTaskNotesCommand(
            accountId: f.account,
            taskId: f.parent,
            notes: 'Parent notes edited after completion',
          ),
        ),
        isA<Success<void>>(),
      );

      final result = _value(
        await repository.undoTaskCompletion(f.undo(undo.operationId)),
      );

      expect(result.restoredTaskIds, <TaskId>[f.parent, f.openChild]);
      expect(result.skippedTaskIds, isEmpty);
      expect(result.alreadyUndone, isFalse);
      await _expectStatuses(database, f, completed: {f.completedChild});
      await _expectIntent(database, f, <TaskId, TaskStatus>{
        f.parent: TaskStatus.needsAction,
        f.openChild: TaskStatus.needsAction,
      });
      final desired = DesiredStateDao(database);
      final child = (await desired.readTask(f.account, f.openChild))!;
      expect(child.title, 'Child edited after completion');
      final parent = (await desired.readTask(f.account, f.parent))!;
      expect(parent.notes, 'Parent notes edited after completion');
      expect(parent.due, TaskDate(2026, 11, 20));
      final tasks = await _tasks(database, f);
      expect(tasks[f.openChild]!.title, 'Child edited after completion');
      expect(tasks[f.parent]!.notes, 'Parent notes edited after completion');

      // An idempotent retry of the committed Undo changes nothing.
      final retried = _value(
        await repository.undoTaskCompletion(f.undo(undo.operationId)),
      );
      expect(retried.alreadyUndone, isTrue);
      expect(retried.restoredTaskIds, isEmpty);
      expect(
        (await desired.readTask(f.account, f.parent))!.generation,
        parent.generation,
      );

      await reopen();
      await _expectStatuses(database, f, completed: {f.completedChild});
      await _expectIntent(database, f, <TaskId, TaskStatus>{
        f.parent: TaskStatus.needsAction,
        f.openChild: TaskStatus.needsAction,
      });
    },
  );

  test('Undo skips a cascaded subtask deleted after the completion', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);
    final undo = _value(
      await repository.setTaskCompletion(f.complete(f.parent)),
    ).undo!;
    expect(
      await repository.deleteTask(
        DeleteTaskCommand(accountId: f.account, taskId: f.openChild),
      ),
      isA<Success<TaskDeleteReceipt>>(),
    );

    final result = _value(
      await repository.undoTaskCompletion(f.undo(undo.operationId)),
    );

    expect(result.restoredTaskIds, <TaskId>[f.parent]);
    expect(result.skippedTaskIds, <TaskId>[f.openChild]);
    expect(
      (await _tasks(database, f))[f.parent]!.status,
      TaskStatus.needsAction,
    );
  });

  test('a later status change makes an earlier receipt stale', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);
    final first = _value(
      await repository.setTaskCompletion(f.complete(f.parent)),
    ).undo!;

    // Reopening the cascaded child supersedes the parent's offer.
    final reopen = _value(
      await repository.setTaskCompletion(
        f.complete(f.openChild, TaskStatus.needsAction),
      ),
    );
    expect(reopen.changedTaskIds, <TaskId>[f.openChild]);
    expect(reopen.undo, isNull, reason: 'reopening offers no Undo');
    expect(
      _failureCode(
        await repository.undoTaskCompletion(f.undo(first.operationId)),
      ),
      'task.completion_undo_unavailable',
    );
    await _expectStatuses(database, f, completed: {f.parent});

    // A newer completion replaces the offer; only the newest is undoable.
    final second = _value(
      await repository.setTaskCompletion(f.complete(f.unrelated)),
    ).undo!;
    final third = _value(
      await repository.setTaskCompletion(f.complete(f.openChild)),
    ).undo!;
    expect(
      _failureCode(
        await repository.undoTaskCompletion(f.undo(second.operationId)),
      ),
      'task.completion_undo_unavailable',
    );
    expect(
      _value(await repository.undoTaskCompletion(f.undo(third.operationId)))
          .restoredTaskIds,
      <TaskId>[f.openChild],
    );
    await _expectStatuses(database, f, completed: {f.parent, f.unrelated});

    // A details edit that changes status also supersedes the offer.
    final fourth = _value(
      await repository.setTaskCompletion(f.complete(f.otherParent)),
    ).undo!;
    expect(
      await repository.apply(
        UpdateTaskContentCommand(
          accountId: f.account,
          taskId: f.unrelated,
          title: 'Unrelated',
          notes: null,
          status: TaskStatus.needsAction,
          due: null,
        ),
      ),
      isA<Success<void>>(),
    );
    expect(
      _failureCode(
        await repository.undoTaskCompletion(f.undo(fourth.operationId)),
      ),
      'task.completion_undo_unavailable',
    );
  });

  test('a receipt expires at the end of the Undo window', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);
    final undo = _value(
      await repository.setTaskCompletion(f.complete(f.parent)),
    ).undo!;
    clock.advance(taskCompletionUndoWindow);

    expect(
      _failureCode(
        await repository.undoTaskCompletion(f.undo(undo.operationId)),
      ),
      'task.completion_undo_expired',
    );
    await _expectStatuses(database, f, completed: {f.parent, f.openChild});

    final reopened = _value(
      await repository.setTaskCompletion(
        f.complete(f.parent, TaskStatus.needsAction),
      ),
    );
    expect(reopened.changedTaskIds, <TaskId>[f.parent]);
    final next = _value(
      await repository.setTaskCompletion(f.complete(f.parent)),
    ).undo!;
    expect(next.cascadedCount, 0, reason: 'the child is still completed');
    clock.advance(taskCompletionUndoWindow - const Duration(milliseconds: 1));
    expect(
      _value(await repository.undoTaskCompletion(f.undo(next.operationId)))
          .restoredTaskIds,
      <TaskId>[f.parent],
    );
  });

  test('a repeated completion is an idempotent no-op', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);
    final undo = _value(
      await repository.setTaskCompletion(f.complete(f.parent)),
    ).undo!;
    final desired = DesiredStateDao(database);
    final generation = (await desired.readTask(
      f.account,
      f.parent,
    ))!.generation;

    final retry = _value(
      await repository.setTaskCompletion(f.complete(f.parent)),
    );

    expect(retry.changedTaskIds, isEmpty);
    expect(retry.undo, isNull);
    expect(
      (await desired.readTask(f.account, f.parent))!.generation,
      generation,
    );
    expect(
      _value(await repository.undoTaskCompletion(f.undo(undo.operationId)))
          .restoredTaskIds,
      <TaskId>[f.parent, f.openChild],
      reason: 'a no-op retry keeps the available Undo',
    );
  });

  test('concurrent commands commit in order and apply Undo once', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);
    final completions = await Future.wait(
      <Future<Outcome<TaskCompletionReceipt>>>[
        repository.setTaskCompletion(f.complete(f.parent)),
        repository.setTaskCompletion(f.complete(f.unrelated)),
      ],
    );
    final first = _value(completions[0]).undo!;
    final second = _value(completions[1]).undo!;
    final (older, newer) = first.operationId < second.operationId
        ? (first, second)
        : (second, first);
    await _expectStatuses(
      database,
      f,
      completed: {f.parent, f.openChild, f.unrelated},
    );
    expect(
      _failureCode(
        await repository.undoTaskCompletion(f.undo(older.operationId)),
      ),
      'task.completion_undo_unavailable',
    );

    final generations = <TaskId, int>{
      for (final id in <TaskId>[f.parent, f.openChild, f.unrelated])
        id: (await DesiredStateDao(
          database,
        ).readTask(f.account, id))!.generation,
    };
    final undos = await Future.wait(<Future<Outcome<TaskCompletionUndoResult>>>[
      repository.undoTaskCompletion(f.undo(newer.operationId)),
      repository.undoTaskCompletion(f.undo(newer.operationId)),
    ]);
    final results = undos.map(_value).toList();
    expect(results.where((result) => result.alreadyUndone), hasLength(1));
    final applied = results.singleWhere((result) => !result.alreadyUndone);
    expect(applied.restoredTaskIds, hasLength(newer.completedCount));
    for (final id in applied.restoredTaskIds) {
      expect(
        (await DesiredStateDao(database).readTask(f.account, id))!.generation,
        generations[id]! + 1,
        reason: 'Undo writes each task exactly once',
      );
    }
  });

  test('persistence failures roll back completion and Undo', () async {
    DesiredStateTransactionBoundary? failAt;
    final repository = DatabaseTasksRepository(
      database,
      clock: clock,
      transactionControl: (boundary) {
        if (boundary == failAt) {
          throw const DesiredStatePersistenceException('synthetic_failure');
        }
      },
    );
    for (final boundary in <DesiredStateTransactionBoundary>[
      DesiredStateTransactionBoundary.afterProjectionWrite,
      DesiredStateTransactionBoundary.afterDesiredStateWrite,
      DesiredStateTransactionBoundary.beforeLocalCommit,
    ]) {
      failAt = boundary;
      expect(
        _failureCode(await repository.setTaskCompletion(f.complete(f.parent))),
        'task.persistence_failed',
        reason: '$boundary',
      );
      await _expectStatuses(database, f, completed: <TaskId>{});
      await _expectIntent(database, f, const <TaskId, TaskStatus>{});
    }

    failAt = null;
    final undo = _value(
      await repository.setTaskCompletion(f.complete(f.parent)),
    ).undo!;
    for (final boundary in <DesiredStateTransactionBoundary>[
      DesiredStateTransactionBoundary.afterProjectionWrite,
      DesiredStateTransactionBoundary.afterDesiredStateWrite,
      DesiredStateTransactionBoundary.beforeLocalCommit,
    ]) {
      failAt = boundary;
      expect(
        _failureCode(
          await repository.undoTaskCompletion(f.undo(undo.operationId)),
        ),
        'task.persistence_failed',
        reason: '$boundary',
      );
      await _expectStatuses(database, f, completed: {f.parent, f.openChild});
      await _expectIntent(database, f, <TaskId, TaskStatus>{
        f.parent: TaskStatus.completed,
        f.openChild: TaskStatus.completed,
      });
    }

    failAt = null;
    expect(
      _value(await repository.undoTaskCompletion(f.undo(undo.operationId)))
          .restoredTaskIds,
      <TaskId>[f.parent, f.openChild],
      reason: 'a rolled-back Undo stays available for retry',
    );
    await _expectStatuses(database, f, completed: <TaskId>{});
  });

  test('bulk completion cascades and offers one precise Undo', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);

    final result = await repository.applyBulk(
      BulkCompleteTasksCommand(
        accountId: f.account,
        taskIds: <TaskId>{f.parent, f.unrelated},
      ),
    );

    final receipt = (result as Success<BulkOperationReceipt>).value;
    expect(receipt.taskIds, <TaskId>[f.parent, f.unrelated]);
    expect(receipt.summary.selectedCount, 2);
    expect(receipt.summary.affectedCount, 2);
    final undo = receipt.completionUndo!;
    expect(undo.title, isNull);
    expect(undo.completedCount, 3);
    expect(undo.cascadedCount, 1);
    await _expectStatuses(
      database,
      f,
      completed: {f.parent, f.openChild, f.unrelated},
    );
    await _expectIntent(database, f, <TaskId, TaskStatus>{
      f.parent: TaskStatus.completed,
      f.openChild: TaskStatus.completed,
      f.unrelated: TaskStatus.completed,
    });

    final undone = _value(
      await repository.undoTaskCompletion(f.undo(undo.operationId)),
    );
    expect(undone.restoredTaskIds, <TaskId>[
      f.parent,
      f.openChild,
      f.unrelated,
    ]);
    await _expectStatuses(database, f, completed: <TaskId>{});
  });

  test('a details status edit follows the same cascade policy', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);

    expect(
      await repository.apply(
        UpdateTaskContentCommand(
          accountId: f.account,
          taskId: f.parent,
          title: 'Parent renamed',
          notes: null,
          status: TaskStatus.completed,
          due: TaskDate(2026, 11, 20),
        ),
      ),
      isA<Success<void>>(),
    );

    await _expectStatuses(database, f, completed: {f.parent, f.openChild});
    await _expectIntent(database, f, <TaskId, TaskStatus>{
      f.parent: TaskStatus.completed,
      f.openChild: TaskStatus.completed,
    });
    expect((await _tasks(database, f))[f.parent]!.title, 'Parent renamed');
  });

  test('the generic apply path uses the completion policy', () async {
    final repository = DatabaseTasksRepository(database, clock: clock);

    expect(await repository.apply(f.complete(f.parent)), isA<Success<void>>());

    await _expectStatuses(database, f, completed: {f.parent, f.openChild});
  });
}

final class _Fixture {
  const _Fixture({
    required this.account,
    required this.parent,
    required this.openChild,
    required this.completedChild,
    required this.unrelated,
    required this.otherParent,
    required this.otherChild,
  });

  final AccountId account;
  final TaskId parent;
  final TaskId openChild;
  final TaskId completedChild;
  final TaskId unrelated;
  final TaskId otherParent;
  final TaskId otherChild;

  List<TaskId> get all => <TaskId>[
    parent,
    openChild,
    completedChild,
    unrelated,
    otherParent,
    otherChild,
  ];

  SetTaskCompletionCommand complete(
    TaskId id, [
    TaskStatus status = TaskStatus.completed,
  ]) =>
      SetTaskCompletionCommand(accountId: account, taskId: id, status: status);

  UndoTaskCompletionCommand undo(int operationId) =>
      UndoTaskCompletionCommand(accountId: account, operationId: operationId);
}

Future<_Fixture> _seed(AppDatabase database) async {
  final account = AccountId(
    await database.createAccount('synthetic-completion-account'),
  );
  final cache = CacheDao(database);
  final list = await cache.putTaskList(
    accountId: account,
    remoteId: const TaskListRemoteId('synthetic-completion-list'),
    title: 'Synthetic completion',
  );
  final parent = await _putTask(
    cache,
    account,
    list,
    remote: 'parent',
    title: 'Parent',
    due: TaskDate(2026, 11, 20),
  );
  final openChild = await _putTask(
    cache,
    account,
    list,
    remote: 'open-child',
    title: 'Open child',
    parent: parent,
  );
  final completedChild = await _putTask(
    cache,
    account,
    list,
    remote: 'completed-child',
    title: 'Completed child',
    parent: parent,
    status: TaskStatus.completed,
  );
  final unrelated = await _putTask(
    cache,
    account,
    list,
    remote: 'unrelated',
    title: 'Unrelated',
  );
  final otherParent = await _putTask(
    cache,
    account,
    list,
    remote: 'other-parent',
    title: 'Other parent',
  );
  final otherChild = await _putTask(
    cache,
    account,
    list,
    remote: 'other-child',
    title: 'Other child',
    parent: otherParent,
  );
  return _Fixture(
    account: account,
    parent: parent,
    openChild: openChild,
    completedChild: completedChild,
    unrelated: unrelated,
    otherParent: otherParent,
    otherChild: otherChild,
  );
}

Future<TaskId> _putTask(
  CacheDao cache,
  AccountId account,
  TaskListId list, {
  required String remote,
  required String title,
  TaskId? parent,
  TaskDate? due,
  TaskStatus status = TaskStatus.needsAction,
}) async {
  final id = await cache.putTask(
    accountId: account,
    taskListId: list,
    parentTaskId: parent,
    remoteId: TaskRemoteId('synthetic-completion-$remote'),
    title: title,
    notes: null,
    status: status,
    due: due,
    position: 'position-$remote',
  );
  await cache.putTaskRemoteBase(
    accountId: account,
    taskId: id,
    taskListId: list,
    parentTaskId: parent,
    remoteId: TaskRemoteId('synthetic-completion-$remote'),
    observedPublicationId: 'synthetic-completion-base',
    deleted: false,
    title: title,
    notes: null,
    status: status,
    due: due,
    position: 'position-$remote',
    etag: 'etag-$remote',
    remoteUpdatedAt: DateTime.utc(2026, 11, 16, 11),
  );
  return id;
}

Future<Map<TaskId, CachedTask>> _tasks(AppDatabase database, _Fixture f) async {
  final snapshot = await DatabaseTasksRepository(database)
      .watchTasks(TasksQuery(accountId: f.account))
      .first;
  return <TaskId, CachedTask>{for (final task in snapshot.tasks) task.id: task};
}

/// Every fixture task outside [completed] (and the seeded completed child)
/// must be open, so an unrelated or untouched task can never drift.
Future<void> _expectStatuses(
  AppDatabase database,
  _Fixture f, {
  required Set<TaskId> completed,
}) async {
  final tasks = await _tasks(database, f);
  for (final id in f.all) {
    if (!tasks.containsKey(id)) continue;
    final expected = completed.contains(id) || id == f.completedChild
        ? TaskStatus.completed
        : TaskStatus.needsAction;
    expect(tasks[id]!.status, expected, reason: 'task ${id.value}');
  }
}

/// Exactly the tasks in [expected] carry pending durable publication intent
/// with the given status; every other fixture task has none.
Future<void> _expectIntent(
  AppDatabase database,
  _Fixture f,
  Map<TaskId, TaskStatus> expected,
) async {
  final desired = DesiredStateDao(database);
  for (final id in f.all) {
    final record = await desired.readTask(f.account, id);
    if (!expected.containsKey(id)) {
      expect(record, isNull, reason: 'task ${id.value} has no intent');
      continue;
    }
    expect(record?.status, expected[id], reason: 'task ${id.value} status');
    expect(
      record?.state,
      DesiredStateLifecycle.pending,
      reason: 'task ${id.value} is queued for publication',
    );
  }
}

T _value<T>(Outcome<T> outcome) => switch (outcome) {
  Success<T>(:final value) => value,
  Failed<T>(:final failure) => throw TestFailure(
    'Unexpected failure ${failure.code}',
  ),
};

String? _failureCode<T>(Outcome<T> outcome) => switch (outcome) {
  Success<T>() => null,
  Failed<T>(:final failure) => failure.code,
};
