import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/date_workflow.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/quick_add_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty capture is rejected without a durable mutation', () async {
    final repository = _Repository();
    final model = QuickAddViewModel(
      accountId: const AccountId(1),
      repository: repository,
      today: () => TaskDate(2026, 8, 16),
      lists: () => _lists,
      defaultTarget: () => const TaskListId(7),
    );

    await model.submit();

    expect(repository.created, isEmpty);
    expect(model.state.failureMessage, 'Enter a task title.');
    expect(model.state.isSubmitting, isFalse);
  });

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

  test(
    'explicit destination and optional due date override contextual defaults',
    () async {
      final repository = _Repository();
      final model = QuickAddViewModel(
        accountId: const AccountId(1),
        repository: repository,
        today: () => TaskDate(2026, 8, 16),
        lists: () => _twoLists,
        defaultTarget: () => const TaskListId(7),
        defaultDue: () => TaskDate(2026, 8, 16),
        destinationRequired: () => true,
      );
      model
        ..setInput('Plan synthetic errand')
        ..selectTarget(const TaskListId(8))
        ..selectDueShortcut(DateShortcut.nextWeek);

      expect(model.state.destinationRequired, isTrue);
      expect(model.state.targetName, 'Synthetic errands');
      expect(model.state.previewDue, TaskDate(2026, 8, 23));
      expect(model.state.hasExplicitDue, isTrue);

      await model.submit();

      expect(repository.created.single.taskListId, const TaskListId(8));
      expect(repository.created.single.due, TaskDate(2026, 8, 23));
      expect(model.state.successMessage, 'Saved locally. Waiting for Google.');
    },
  );

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

  group('capture notes (Android audit 08)', () {
    QuickAddViewModel notesModel(_Repository repository) => QuickAddViewModel(
      accountId: const AccountId(1),
      repository: repository,
      today: () => TaskDate(2026, 8, 16),
      lists: () => _lists,
      defaultTarget: () => const TaskListId(7),
    );

    test('multiline notes are stored with the title, then cleared', () async {
      final repository = _Repository();
      final model = notesModel(repository);
      model
        ..setInput('Plan trip')
        ..setNotes('Book train\nPack charger');

      await model.submit();

      final command = repository.created.single;
      expect(command.title, 'Plan trip');
      expect(command.notes, 'Book train\nPack charger');
      expect(command.taskListId, const TaskListId(7));
      expect(model.state.input, isEmpty);
      expect(model.state.notes, isEmpty);
      expect(model.state.successMessage, isNotNull);
    });

    test('blank notes stay absent rather than empty', () async {
      final repository = _Repository();
      final model = notesModel(repository);
      model
        ..setInput('No notes')
        ..setNotes('  \n ');

      await model.submit();

      expect(repository.created.single.notes, isNull);
    });

    test('an empty title keeps the notes and creates nothing', () async {
      final repository = _Repository();
      final model = notesModel(repository);
      model
        ..setInput('   ')
        ..setNotes('Keep these notes');

      await model.submit();

      expect(repository.created, isEmpty);
      expect(model.state.failureMessage, 'Enter a task title.');
      expect(model.state.input, '   ');
      expect(model.state.notes, 'Keep these notes');
    });

    test('a storage failure keeps title and notes for retry', () async {
      final repository = _Repository()
        ..result = Future.value(const Outcome.failure(_persistenceFailure));
      final model = notesModel(repository);
      model
        ..setInput('Retry me')
        ..setNotes('Retained notes');

      await model.submit();

      expect(model.state.input, 'Retry me');
      expect(model.state.notes, 'Retained notes');
      expect(model.state.failureMessage, 'The task could not be saved safely.');

      repository.result = Future.value(const Outcome.success(TaskId(31)));
      await model.submit();

      expect(repository.created, hasLength(2));
      expect(repository.created.last.title, 'Retry me');
      expect(repository.created.last.notes, 'Retained notes');
      expect(model.state.notes, isEmpty);
    });

    test('too-long notes are explained and kept', () async {
      final repository = _Repository()
        ..result = Future.value(
          const Outcome.failure(
            Failure(
              code: 'task.notes_too_long',
              category: FailureCategory.internal,
              operation: FailureOperation.write,
              retry: RetryClassification.permanent,
              impact: 'The task was not saved.',
              safeSummary: 'Notes are too long.',
            ),
          ),
        );
      final model = notesModel(repository);
      model
        ..setInput('Long notes')
        ..setNotes('x' * 8193);

      await model.submit();

      expect(
        model.state.failureMessage,
        'Task notes can contain at most 8192 characters.',
      );
      expect(model.state.notes, hasLength(8193));
    });

    test('two consecutive captures create two distinct tasks', () async {
      final repository = _Repository();
      final model = notesModel(repository);
      model
        ..setInput('First')
        ..setNotes('First notes');
      final first = model.submit();
      // A second tap while the first is in flight joins it.
      final duplicate = model.submit();
      await Future.wait(<Future<void>>[first, duplicate]);
      model.setInput('Second');
      await model.submit();

      expect(repository.created.map((command) => command.title), <String>[
        'First',
        'Second',
      ]);
      expect(repository.created.map((command) => command.notes), <String?>[
        'First notes',
        null,
      ]);
    });

    test('clearDraft discards title, notes and choices without a command', () {
      final repository = _Repository();
      final model = notesModel(repository)
        ..setInput('Abandon')
        ..setNotes('Abandoned notes')
        ..selectDueShortcut(DateShortcut.tomorrow);

      model.clearDraft();

      expect(repository.created, isEmpty);
      expect(model.state.input, isEmpty);
      expect(model.state.notes, isEmpty);
      expect(model.state.hasExplicitDue, isFalse);
      expect(model.state.previewDue, isNull);
    });
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

const _twoLists = <CachedTaskList>[
  ..._lists,
  CachedTaskList(
    id: TaskListId(8),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list-two'),
    title: 'Synthetic errands',
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
