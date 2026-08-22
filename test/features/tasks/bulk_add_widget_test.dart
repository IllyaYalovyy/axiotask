import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/bulk_add_view_model.dart';
import 'package:axiotask/src/features/tasks/widgets/bulk_add.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'dialog previews line entries, target, bounds, and local result',
    (tester) async {
      final repository = _Repository();
      final model = BulkAddViewModel(
        accountId: const AccountId(1),
        repository: repository,
        lists: () => _lists,
        defaultTarget: () => const TaskListId(7),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulkAddDialog(viewModel: model, lists: _lists),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('bulk-add-input')),
        'Alpha\nBeta',
      );
      await tester.pump();

      expect(find.text('2 tasks ready'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Synthetic inbox'), findsOneWidget);
      expect(find.textContaining('Maximum 100 tasks'), findsOneWidget);
      expect(repository.commands, isEmpty);

      await tester.tap(find.byKey(const Key('bulk-add-submit')));
      await tester.pumpAndSettle();
      expect(repository.commands.single.entries, hasLength(2));
      expect(
        find.text('2 tasks saved locally and waiting for Google.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('paragraph mode previews notes and invalid input cannot submit', (
    tester,
  ) async {
    final repository = _Repository();
    final model = BulkAddViewModel(
      accountId: const AccountId(1),
      repository: repository,
      lists: () => _lists,
      defaultTarget: () => const TaskListId(7),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BulkAddDialog(viewModel: model, lists: _lists),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('bulk-add-input')),
      'Plan\nOne\nTwo\n\nCall\nAgenda',
    );
    await tester.tap(find.text('Paragraphs'));
    await tester.pump();

    expect(find.text('2 tasks ready'), findsOneWidget);
    expect(find.text('One\nTwo'), findsOneWidget);
    expect(model.state.preview.entries.last.notes, 'Agenda');

    await tester.enterText(find.byKey(const Key('bulk-add-input')), 'x' * 1025);
    await tester.pump();
    expect(find.textContaining('title is longer than 1024'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('bulk-add-submit')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('cancel closes an unsubmitted paste preview', (tester) async {
    var cancelled = false;
    final model = BulkAddViewModel(
      accountId: const AccountId(1),
      repository: _Repository(),
      lists: () => _lists,
      defaultTarget: () => const TaskListId(7),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: BulkAddDialog(
          viewModel: model,
          lists: _lists,
          onClose: () => cancelled = true,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('bulk-add-input')),
      'Synthetic preview',
    );
    await tester.pump();

    expect(find.text('1 task ready'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));

    expect(cancelled, isTrue);
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

final class _Repository implements BulkTasksRepository {
  final commands = <BulkCreateTasksCommand>[];

  @override
  Future<Outcome<List<TaskId>>> createTasks(
    BulkCreateTasksCommand command,
  ) async {
    commands.add(command);
    return Outcome.success(
      List<TaskId>.generate(
        command.entries.length,
        (index) => TaskId(index + 1),
      ),
    );
  }
}
