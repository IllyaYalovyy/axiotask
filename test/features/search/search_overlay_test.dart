import 'package:axiotask/src/domain/model/search.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/search_repository.dart';
import 'package:axiotask/src/features/search/search_overlay.dart';
import 'package:axiotask/src/features/search/search_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('child matches identify and open their parent context by touch', (
    tester,
  ) async {
    final model = SearchViewModel(
      accountId: const AccountId(1),
      repository: const _SearchRepository(),
    );
    addTearDown(model.dispose);
    TaskSearchResult? opened;

    await tester.pumpWidget(
      MaterialApp(
        home: SearchOverlay(
          viewModel: model,
          onOpenResult: (result) => opened = result,
          onClose: () {},
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('search-input')), 'needle');
    await tester.pumpAndSettle();

    expect(find.text('Parent context'), findsOneWidget);
    expect(
      find.textContaining('Matched subtask: Child needle'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Open Parent context. Matched subtask Child needle. Synthetic inbox.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('search-result-0')));
    expect(opened?.parent.id, const TaskId(10));
    expect(opened?.match.id, const TaskId(11));
  });

  testWidgets('keyboard and pointer activation open the same result', (
    tester,
  ) async {
    final model = SearchViewModel(
      accountId: const AccountId(1),
      repository: const _SearchRepository(),
    );
    addTearDown(model.dispose);
    final opened = <TaskSearchResult>[];

    await tester.pumpWidget(
      MaterialApp(
        home: SearchOverlay(
          viewModel: model,
          onOpenResult: opened.add,
          onClose: () {},
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('search-input')), 'task');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(opened.single.match.id, const TaskId(12));

    await tester.tap(find.byKey(const Key('search-result-1')));
    expect(opened.last.match.id, opened.first.match.id);
  });

  testWidgets('empty and no-result states remain explicit and Escape closes', (
    tester,
  ) async {
    final model = SearchViewModel(
      accountId: const AccountId(1),
      repository: const _SearchRepository(),
    );
    addTearDown(model.dispose);
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: SearchOverlay(
          viewModel: model,
          onOpenResult: (_) {},
          onClose: () => closed = true,
        ),
      ),
    );
    expect(find.text('Search task titles and notes'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('search-input')), 'absent');
    await tester.pump();
    expect(find.text('No supported tasks match “absent”'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closed, isTrue);
  });
}

final class _SearchRepository implements SearchRepository {
  const _SearchRepository();

  @override
  Stream<List<TaskSearchResult>> watchSearch(TaskSearchQuery query) =>
      Stream.value(
        query.text == 'absent'
            ? const <TaskSearchResult>[]
            : <TaskSearchResult>[
                TaskSearchResult(
                  parent: _task(10, 'Parent context'),
                  match: _task(11, 'Child needle', parent: 10),
                  taskListTitle: 'Synthetic inbox',
                  matchedFields: const <TaskSearchField>{TaskSearchField.title},
                ),
                TaskSearchResult(
                  parent: _task(12, 'Second task'),
                  match: _task(12, 'Second task'),
                  taskListTitle: 'Synthetic inbox',
                  matchedFields: const <TaskSearchField>{TaskSearchField.notes},
                ),
              ],
      );
}

CachedTask _task(int id, String title, {int? parent}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: const TaskListId(1),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: TaskRemoteId('synthetic-$id'),
  title: title,
  notes: null,
  status: TaskStatus.needsAction,
  due: null,
);
