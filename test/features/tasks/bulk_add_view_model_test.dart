import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/bulk_capture.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/bulk_add_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('previews parsed entries and one visible target before submit', () {
    final repository = _BulkRepository();
    final model = BulkAddViewModel(
      accountId: const AccountId(1),
      repository: repository,
      lists: () => _lists,
      defaultTarget: () => const TaskListId(7),
    );

    model.setInput('Alpha\nBeta');

    expect(model.state.preview.entries.map((entry) => entry.title), [
      'Alpha',
      'Beta',
    ]);
    expect(model.state.targetName, 'Synthetic inbox');
    expect(repository.commands, isEmpty);
  });

  test('mode change produces paragraph titles and notes', () {
    final model = BulkAddViewModel(
      accountId: const AccountId(1),
      repository: _BulkRepository(),
      lists: () => _lists,
      defaultTarget: () => const TaskListId(7),
    );
    model
      ..setInput('Plan\nOne\nTwo\n\nCall\nAgenda')
      ..setMode(BulkCaptureMode.paragraphs);

    expect(model.state.preview.entries, const <BulkCaptureEntry>[
      BulkCaptureEntry(title: 'Plan', notes: 'One\nTwo'),
      BulkCaptureEntry(title: 'Call', notes: 'Agenda'),
    ]);
  });

  test('invalid target is rechecked before acknowledgement', () async {
    final repository = _BulkRepository();
    var lists = _lists;
    final model = BulkAddViewModel(
      accountId: const AccountId(1),
      repository: repository,
      lists: () => lists,
      defaultTarget: () => const TaskListId(7),
    );
    model.setInput('Alpha\nBeta');
    lists = const <CachedTaskList>[];

    await model.submit();

    expect(repository.commands, isEmpty);
    expect(model.state.failureMessage, 'Choose an available Google task list.');
  });

  test(
    'duplicate submit shares one atomic acknowledgement and trigger',
    () async {
      final durable = Completer<Outcome<List<TaskId>>>();
      final repository = _BulkRepository()..result = durable.future;
      var publications = 0;
      final model = BulkAddViewModel(
        accountId: const AccountId(1),
        repository: repository,
        lists: () => _lists,
        defaultTarget: () => const TaskListId(7),
        localEditCommitted: () async => publications += 1,
      );
      model.setInput('Alpha\nBeta');

      final first = model.submit();
      final duplicate = model.submit();
      expect(repository.commands, hasLength(1));
      durable.complete(const Outcome.success(<TaskId>[TaskId(1), TaskId(2)]));
      await Future.wait(<Future<void>>[first, duplicate]);

      expect(publications, 1);
      expect(
        model.state.successMessage,
        '2 tasks saved locally and waiting for Google.',
      );
      expect(model.state.input, isEmpty);
    },
  );

  test(
    'repository rollback retains preview and reports no partial acceptance',
    () async {
      final repository = _BulkRepository()
        ..result = Future.value(const Outcome.failure(_failure));
      final model = BulkAddViewModel(
        accountId: const AccountId(1),
        repository: repository,
        lists: () => _lists,
        defaultTarget: () => const TaskListId(7),
      );
      model.setInput('Alpha\nBeta');

      await model.submit();

      expect(model.state.input, 'Alpha\nBeta');
      expect(
        model.state.failureMessage,
        'No tasks were saved. Review the input and try again.',
      );
      expect(model.state.successMessage, isNull);
    },
  );
}

const _lists = <CachedTaskList>[
  CachedTaskList(
    id: TaskListId(7),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list'),
    title: 'Synthetic inbox',
  ),
];

final class _BulkRepository implements BulkTasksRepository {
  Future<Outcome<List<TaskId>>> result = Future.value(
    const Outcome.success(<TaskId>[TaskId(1)]),
  );
  final List<BulkCreateTasksCommand> commands = <BulkCreateTasksCommand>[];

  @override
  Future<Outcome<List<TaskId>>> createTasks(BulkCreateTasksCommand command) {
    commands.add(command);
    return result;
  }
}

const _failure = Failure(
  code: 'task.persistence_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'No tasks were saved.',
  safeSummary: 'The bulk transaction failed.',
);
