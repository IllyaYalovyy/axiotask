import '../model/search.dart';

abstract interface class SearchRepository {
  Stream<List<TaskSearchResult>> watchSearch(TaskSearchQuery query);
}
