import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/quick_add_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shows stripped title, target, and interpreted date before submit', () {
    final repository = _Repository();
    final model = QuickAddViewModel(
      accountId: const AccountId(1),
      repository: repository,
      today: () => TaskDate(2026, 8, 16),
      lists: () => _lists,
      defaultTarget: () => const TaskListId(7),
    );

    model.setInput('Send invoice tomorrow');

    expect(model.state.previewTitle, 'Send invoice');
    expect(model.state.targetName, 'Synthetic inbox');
    expect(model.state.previewDue, TaskDate(2026, 8, 17));
    expect(repository.created, isEmpty);
  });

  test('dismissal preserves the date phrase as literal title text', () async {
    final repository = _Repository();
    final model = QuickAddViewModel(
      accountId: const AccountId(1),
      repository: repository,
      today: () => TaskDate(2026, 8, 16),
      lists: () => _lists,
      defaultTarget: () => const TaskListId(7),
    );
    model.setInput('Discuss tomorrow');

    model.dismissDatePreview();
    await model.submit();

    expect(repository.created.single.title, 'Discuss tomorrow');
    expect(repository.created.single.due, isNull);
  });

  test('rejects a target removed before acknowledgement', () async {
    final repository = _Repository();
    var lists = _lists;
    final model = QuickAddViewModel(
      accountId: const AccountId(1),
      repository: repository,
      today: () => TaskDate(2026, 8, 16),
      lists: () => lists,
      defaultTarget: () => const TaskListId(7),
    );
    model.setInput('Capture safely');
    lists = const <CachedTaskList>[];

    await model.submit();

    expect(repository.created, isEmpty);
    expect(model.state.failureMessage, 'Choose an available Google task list.');
  });

  test(
    'suppresses duplicate submit and publishes only after durability',
    () async {
      final durable = Completer<Outcome<TaskId>>();
      final repository = _Repository()..result = durable.future;
      var publications = 0;
      final model = QuickAddViewModel(
        accountId: const AccountId(1),
        repository: repository,
        today: () => TaskDate(2026, 8, 16),
        lists: () => _lists,
        defaultTarget: () => const TaskListId(7),
        localEditCommitted: () async => publications += 1,
      );
      model.setInput('One durable task');

      final first = model.submit();
      final duplicate = model.submit();
      expect(repository.created, hasLength(1));
      expect(model.state.isSubmitting, isTrue);
      expect(publications, 0);
      durable.complete(const Outcome.success(TaskId(31)));
      await Future.wait(<Future<void>>[first, duplicate]);

      expect(publications, 1);
      expect(model.state.input, isEmpty);
      expect(model.state.isSubmitting, isFalse);
    },
  );

  test('rollback remains visible and retains entered capture', () async {
    final repository = _Repository()
      ..result = Future.value(const Outcome.failure(_persistenceFailure));
    final model = QuickAddViewModel(
      accountId: const AccountId(1),
      repository: repository,
      today: () => TaskDate(2026, 8, 16),
      lists: () => _lists,
      defaultTarget: () => const TaskListId(7),
    );
    model.setInput('Retain me today');

    await model.submit();

    expect(model.state.input, 'Retain me today');
    expect(model.state.failureMessage, 'The task could not be saved safely.');
  });
}

const _lists = <CachedTaskList>[
  CachedTaskList(
    id: TaskListId(7),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list'),
    title: 'Synthetic inbox',
  ),
];

final class _Repository implements TasksRepository {
  Future<Outcome<TaskId>> result = Future.value(
    const Outcome.success(TaskId(30)),
  );
  final List<CreateTaskCommand> created = <CreateTaskCommand>[];

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) {
    created.add(command);
    return result;
  }

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) =>
      Future.value(const Outcome.success(null));

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) =>
      const Stream.empty();

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      const Stream.empty();

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => const Stream.empty();

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(DeleteTaskCommand command) =>
      throw UnimplementedError();

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(SetTaskDueCommand command) =>
      throw UnimplementedError();

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) =>
      throw UnimplementedError();

  @override
  Future<Outcome<void>> undoTaskDueChange(UndoTaskDueChangeCommand command) =>
      throw UnimplementedError();
}

const _persistenceFailure = Failure(
  code: 'task.persistence_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The task was not saved.',
  safeSummary: 'The task transaction failed.',
);
