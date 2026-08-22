import 'dart:async';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/quick_add_view_model.dart';
import 'package:axiotask/src/features/tasks/widgets/quick_add.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'concrete-list capture stays one compact row until options open',
    (tester) async {
      final model = _model();
      await tester.pumpWidget(_host(model));

      expect(find.byKey(const Key('quick-add-input')), findsOneWidget);
      expect(find.byKey(const Key('quick-add-destination')), findsNothing);
      expect(find.byKey(const Key('quick-add-date')), findsNothing);
      expect(find.byKey(const Key('quick-add-submit')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('quick-add-submit')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('quick-add-options')));
      await tester.pump();
      expect(find.byKey(const Key('quick-add-destination')), findsOneWidget);
      expect(find.byKey(const Key('quick-add-date')), findsOneWidget);
    },
  );

  testWidgets(
    'smart-view capture exposes destination and retains focus on acknowledgement',
    (tester) async {
      final repository = _Repository();
      final model = _model(
        repository: repository,
        destinationRequired: () => true,
      );
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_host(model, focusNode: focus));

      expect(find.byKey(const Key('quick-add-destination')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('quick-add-input')),
        'Synthetic task tomorrow',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(repository.created.single.title, 'Synthetic task');
      expect(repository.created.single.due, TaskDate(2026, 8, 17));
      expect(find.text('Saved locally. Waiting for Google.'), findsOneWidget);
      expect(focus.hasFocus, isTrue);
    },
  );

  testWidgets('narrow 200 percent capture keeps its primary controls usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _model(destinationRequired: () => true);
    await tester.pumpWidget(_host(model, textScale: 2));

    await tester.enterText(
      find.byKey(const Key('quick-add-input')),
      'Accessible capture',
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('quick-add-submit')), findsOneWidget);
    expect(find.byKey(const Key('quick-add-destination')), findsOneWidget);
  });

  testWidgets('capture options discover the paste multiple route', (
    tester,
  ) async {
    var pasteOpened = 0;
    final model = _model();
    await tester.pumpWidget(_host(model, onPasteMultiple: () => pasteOpened++));

    await tester.tap(find.byKey(const Key('quick-add-options')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('quick-add-paste-multiple')));

    expect(pasteOpened, 1);
  });
}

Widget _host(
  QuickAddViewModel model, {
  FocusNode? focusNode,
  double textScale = 1,
  VoidCallback? onPasteMultiple,
}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(8),
          child: QuickAddBar(
            viewModel: model,
            lists: _lists,
            focusNode: focusNode ?? FocusNode(),
            onPasteMultiple: onPasteMultiple,
          ),
        ),
      ),
    ),
  ),
);

QuickAddViewModel _model({
  _Repository? repository,
  bool Function()? destinationRequired,
}) => QuickAddViewModel(
  accountId: const AccountId(1),
  repository: repository ?? _Repository(),
  today: () => TaskDate(2026, 8, 16),
  lists: () => _lists,
  defaultTarget: () => const TaskListId(7),
  destinationRequired: destinationRequired,
);

const _lists = <CachedTaskList>[
  CachedTaskList(
    id: TaskListId(7),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list'),
    title: 'Synthetic inbox',
  ),
  CachedTaskList(
    id: TaskListId(8),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list-two'),
    title: 'Synthetic errands',
  ),
];

final class _Repository implements TasksRepository {
  final created = <CreateTaskCommand>[];

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async {
    created.add(command);
    return const Outcome<TaskId>.success(TaskId(1));
  }

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) =>
      throw UnimplementedError();

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

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) =>
      const Stream<CachedTasksSnapshot>.empty();

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      const Stream<List<TaskDeleteUndo>>.empty();

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => const Stream<List<TaskDueChangeUndo>>.empty();
}
