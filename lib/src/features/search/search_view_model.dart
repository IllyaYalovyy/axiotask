import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/model/search.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/search_repository.dart';

final class SearchViewState {
  const SearchViewState({
    required this.query,
    required this.results,
    required this.selectedIndex,
    required this.isSearching,
    required this.failureMessage,
  });

  final String query;
  final List<TaskSearchResult> results;
  final int? selectedIndex;
  final bool isSearching;
  final String? failureMessage;

  TaskSearchResult? get selectedResult => switch (selectedIndex) {
    final index? when index >= 0 && index < results.length => results[index],
    _ => null,
  };
}

final class SearchViewModel extends ChangeNotifier {
  SearchViewModel({required this.accountId, required this.repository});

  final AccountId accountId;
  final SearchRepository repository;
  SearchViewState _state = const SearchViewState(
    query: '',
    results: <TaskSearchResult>[],
    selectedIndex: null,
    isSearching: false,
    failureMessage: null,
  );
  StreamSubscription<List<TaskSearchResult>>? _subscription;
  int _generation = 0;

  SearchViewState get state => _state;

  void setQuery(String value) {
    if (value == _state.query) return;
    final generation = ++_generation;
    final previous = _subscription;
    _subscription = null;
    if (previous != null) unawaited(previous.cancel());
    final query = TaskSearchQuery(accountId: accountId, text: value);
    if (query.isEmpty) {
      _replace(
        SearchViewState(
          query: value,
          results: const <TaskSearchResult>[],
          selectedIndex: null,
          isSearching: false,
          failureMessage: null,
        ),
      );
      return;
    }
    _replace(
      SearchViewState(
        query: value,
        results: const <TaskSearchResult>[],
        selectedIndex: null,
        isSearching: true,
        failureMessage: null,
      ),
    );
    _subscription = repository
        .watchSearch(query)
        .listen(
          (results) {
            if (generation != _generation) return;
            _replace(
              SearchViewState(
                query: value,
                results: List<TaskSearchResult>.unmodifiable(results),
                selectedIndex: results.isEmpty ? null : 0,
                isSearching: false,
                failureMessage: null,
              ),
            );
          },
          onError: (_) {
            if (generation != _generation) return;
            _replace(
              SearchViewState(
                query: value,
                results: const <TaskSearchResult>[],
                selectedIndex: null,
                isSearching: false,
                failureMessage: 'Cached tasks could not be searched safely.',
              ),
            );
          },
        );
  }

  void selectNext() => _moveSelection(1);

  void selectPrevious() => _moveSelection(-1);

  void selectIndex(int index) {
    if (index < 0 || index >= _state.results.length) return;
    _replace(
      SearchViewState(
        query: _state.query,
        results: _state.results,
        selectedIndex: index,
        isSearching: _state.isSearching,
        failureMessage: _state.failureMessage,
      ),
    );
  }

  void _moveSelection(int offset) {
    if (_state.results.isEmpty) return;
    final current = _state.selectedIndex ?? 0;
    selectIndex((current + offset).clamp(0, _state.results.length - 1));
  }

  void _replace(SearchViewState value) {
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _generation += 1;
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }
}
