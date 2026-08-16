import 'dart:collection';

import 'tasks.dart';

enum TaskSearchField { title, notes }

final class TaskSearchQuery {
  const TaskSearchQuery({required this.accountId, required this.text});

  final AccountId accountId;
  final String text;

  String get normalizedText => text.trim().toLowerCase();

  bool get isEmpty => normalizedText.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is TaskSearchQuery &&
      accountId == other.accountId &&
      text == other.text;

  @override
  int get hashCode => Object.hash(accountId, text);
}

final class TaskSearchResult {
  TaskSearchResult({
    required this.parent,
    required this.match,
    required this.taskListTitle,
    required Set<TaskSearchField> matchedFields,
  }) : matchedFields = UnmodifiableSetView<TaskSearchField>(
         Set<TaskSearchField>.of(matchedFields),
       );

  final CachedTask parent;
  final CachedTask match;
  final String taskListTitle;
  final Set<TaskSearchField> matchedFields;

  bool get isChildMatch => match.id != parent.id;
}
