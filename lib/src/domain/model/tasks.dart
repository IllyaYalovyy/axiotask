import 'dart:collection';

final class AccountId {
  const AccountId(this.value) : assert(value > 0);

  final int value;

  @override
  bool operator ==(Object other) => other is AccountId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AccountId($value)';
}

final class TaskListId {
  const TaskListId(this.value) : assert(value > 0);

  final int value;

  @override
  bool operator ==(Object other) => other is TaskListId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'TaskListId($value)';
}

final class TaskId {
  const TaskId(this.value) : assert(value > 0);

  final int value;

  @override
  bool operator ==(Object other) => other is TaskId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'TaskId($value)';
}

final class TaskListRemoteId {
  const TaskListRemoteId(this.value) : assert(value.length > 0);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is TaskListRemoteId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'TaskListRemoteId(<redacted>)';
}

final class TaskRemoteId {
  const TaskRemoteId(this.value) : assert(value.length > 0);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is TaskRemoteId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'TaskRemoteId(<redacted>)';
}

enum TaskStatus { needsAction, completed }

final class TaskDate {
  TaskDate(this.year, this.month, this.day) {
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw ArgumentError.value('$year-$month-$day', 'date', 'is invalid');
    }
  }

  final int year;
  final int month;
  final int day;

  @override
  bool operator ==(Object other) =>
      other is TaskDate &&
      year == other.year &&
      month == other.month &&
      day == other.day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

final class CachedTaskList {
  const CachedTaskList({
    required this.id,
    required this.accountId,
    required this.remoteId,
    required this.title,
  });

  final TaskListId id;
  final AccountId accountId;
  final TaskListRemoteId? remoteId;
  final String title;

  CachedTaskList copyWith({String? title}) => CachedTaskList(
    id: id,
    accountId: accountId,
    remoteId: remoteId,
    title: title ?? this.title,
  );

  @override
  bool operator ==(Object other) =>
      other is CachedTaskList &&
      id == other.id &&
      accountId == other.accountId &&
      remoteId == other.remoteId &&
      title == other.title;

  @override
  int get hashCode => Object.hash(id, accountId, remoteId, title);
}

final class CachedTask {
  const CachedTask({
    required this.id,
    required this.accountId,
    required this.taskListId,
    required this.parentTaskId,
    required this.remoteId,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
  });

  final TaskId id;
  final AccountId accountId;
  final TaskListId taskListId;
  final TaskId? parentTaskId;
  final TaskRemoteId remoteId;
  final String title;
  final String? notes;
  final TaskStatus status;
  final TaskDate? due;

  CachedTask copyWith({
    TaskListId? taskListId,
    Object? parentTaskId = _notProvided,
    String? title,
    Object? notes = _notProvided,
    TaskStatus? status,
    Object? due = _notProvided,
  }) => CachedTask(
    id: id,
    accountId: accountId,
    taskListId: taskListId ?? this.taskListId,
    parentTaskId: identical(parentTaskId, _notProvided)
        ? this.parentTaskId
        : parentTaskId as TaskId?,
    remoteId: remoteId,
    title: title ?? this.title,
    notes: identical(notes, _notProvided) ? this.notes : notes as String?,
    status: status ?? this.status,
    due: identical(due, _notProvided) ? this.due : due as TaskDate?,
  );

  @override
  bool operator ==(Object other) =>
      other is CachedTask &&
      id == other.id &&
      accountId == other.accountId &&
      taskListId == other.taskListId &&
      parentTaskId == other.parentTaskId &&
      remoteId == other.remoteId &&
      title == other.title &&
      notes == other.notes &&
      status == other.status &&
      due == other.due;

  @override
  int get hashCode => Object.hash(
    id,
    accountId,
    taskListId,
    parentTaskId,
    remoteId,
    title,
    notes,
    status,
    due,
  );
}

final class TasksQuery {
  const TasksQuery({required this.accountId, this.taskListId});

  final AccountId accountId;
  final TaskListId? taskListId;

  @override
  bool operator ==(Object other) =>
      other is TasksQuery &&
      accountId == other.accountId &&
      taskListId == other.taskListId;

  @override
  int get hashCode => Object.hash(accountId, taskListId);
}

enum CacheCompleteness { unobserved, incomplete, complete }

enum CacheVerification { unverifiedCache }

final class CachedTasksSnapshot {
  CachedTasksSnapshot({
    required this.accountId,
    required List<CachedTaskList> taskLists,
    required List<CachedTask> tasks,
    required this.completeness,
  }) : taskLists = UnmodifiableListView<CachedTaskList>(taskLists),
       tasks = UnmodifiableListView<CachedTask>(tasks);

  final AccountId accountId;
  final List<CachedTaskList> taskLists;
  final List<CachedTask> tasks;
  final CacheCompleteness completeness;

  CacheVerification get verification => CacheVerification.unverifiedCache;

  CachedTasksSnapshot copyWith({
    List<CachedTaskList>? taskLists,
    List<CachedTask>? tasks,
    CacheCompleteness? completeness,
  }) => CachedTasksSnapshot(
    accountId: accountId,
    taskLists: taskLists ?? this.taskLists,
    tasks: tasks ?? this.tasks,
    completeness: completeness ?? this.completeness,
  );

  @override
  bool operator ==(Object other) =>
      other is CachedTasksSnapshot &&
      accountId == other.accountId &&
      _listEquals(taskLists, other.taskLists) &&
      _listEquals(tasks, other.tasks) &&
      completeness == other.completeness;

  @override
  int get hashCode => Object.hash(
    accountId,
    Object.hashAll(taskLists),
    Object.hashAll(tasks),
    completeness,
  );
}

const Object _notProvided = Object();

bool _listEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
