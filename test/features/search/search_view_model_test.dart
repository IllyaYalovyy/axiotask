import 'dart:async';

import 'package:axiotask/src/domain/model/search.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/search_repository.dart';
import 'package:axiotask/src/features/search/search_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'query changes replace results and keyboard selection is bounded',
    () async {
      final repository = _SearchRepository();
      final model = SearchViewModel(
        accountId: const AccountId(1),
        repository: repository,
      );
      addTearDown(model.dispose);

      model.setQuery('needle');
      expect(repository.queries.single.text, 'needle');
      repository.emit(<TaskSearchResult>[
        _result(1, 'First'),
        _result(2, 'Second'),
      ]);
      await pumpEventQueue();
      expect(model.state.results, hasLength(2));
      expect(model.state.selectedIndex, 0);

      model.selectNext();
      model.selectNext();
      expect(model.state.selectedResult?.match.title, 'Second');
      model.selectPrevious();
      expect(model.state.selectedResult?.match.title, 'First');

      model.setQuery('updated');
      expect(model.state.results, isEmpty);
      expect(model.state.isSearching, isTrue);
      repository.emit(<TaskSearchResult>[_result(3, 'Updated')]);
      await pumpEventQueue();
      expect(model.state.selectedResult?.match.title, 'Updated');
    },
  );

  test('empty query clears results without opening a repository search', () {
    final repository = _SearchRepository();
    final model = SearchViewModel(
      accountId: const AccountId(1),
      repository: repository,
    );
    addTearDown(model.dispose);

    model.setQuery('   ');
    expect(repository.queries, isEmpty);
    expect(model.state.results, isEmpty);
    expect(model.state.isSearching, isFalse);
  });

  test('search results snapshot caller-owned match metadata', () {
    final fields = <TaskSearchField>{TaskSearchField.title};
    final task = _result(1, 'Stable result');
    final result = TaskSearchResult(
      parent: task.parent,
      match: task.match,
      taskListTitle: task.taskListTitle,
      matchedFields: fields,
    );

    fields.add(TaskSearchField.notes);

    expect(result.matchedFields, const <TaskSearchField>{
      TaskSearchField.title,
    });
  });
}

final class _SearchRepository implements SearchRepository {
  final queries = <TaskSearchQuery>[];
  final _controller = StreamController<List<TaskSearchResult>>.broadcast();

  void emit(List<TaskSearchResult> values) => _controller.add(values);

  @override
  Stream<List<TaskSearchResult>> watchSearch(TaskSearchQuery query) {
    queries.add(query);
    return _controller.stream;
  }
}

TaskSearchResult _result(int id, String title) {
  final task = CachedTask(
    id: TaskId(id),
    accountId: const AccountId(1),
    taskListId: const TaskListId(1),
    parentTaskId: null,
    remoteId: TaskRemoteId('synthetic-$id'),
    title: title,
    notes: null,
    status: TaskStatus.needsAction,
    due: null,
  );
  return TaskSearchResult(
    parent: task,
    match: task,
    taskListTitle: 'Synthetic list',
    matchedFields: const <TaskSearchField>{TaskSearchField.title},
  );
}
