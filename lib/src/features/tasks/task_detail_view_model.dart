import 'package:flutter/foundation.dart';

import '../../domain/commands/task_commands.dart';
import '../../domain/model/tasks.dart';
import '../../domain/policy/date_workflow.dart';
import '../../domain/policy/effective_due.dart';
import '../../domain/policy/subtask_progress.dart';
import 'tasks_view_model.dart';

final class TaskDetailState {
  const TaskDetailState({
    required this.task,
    required this.parent,
    required this.children,
    required this.progress,
    required this.effectiveDue,
    required this.dueChangeUndo,
    required this.parentCandidates,
    required this.siblings,
    required this.destinationLists,
    required this.isCommandPending,
    required this.failureMessage,
  });

  final CachedTask task;
  final CachedTask? parent;
  final List<CachedTask> children;
  final DirectChildProgress progress;
  final EffectiveDue effectiveDue;
  final TaskDueChangeUndo? dueChangeUndo;
  final List<CachedTask> parentCandidates;
  final List<CachedTask> siblings;
  final List<CachedTaskList> destinationLists;
  final bool isCommandPending;
  final String? failureMessage;

  bool get hasChildren => children.isNotEmpty;
  bool get canCreateSubtask => task.parentTaskId == null;
  int get siblingIndex => siblings.indexWhere((value) => value.id == task.id);
}

/// Projects task-detail state and routes every user action through the shared
/// task command boundary owned by [TasksViewModel].
final class TaskDetailViewModel implements Listenable {
  TaskDetailViewModel.fromTasks(
    this._tasks, {
    this.navigateToTask,
    this.navigateBack,
  });

  final TasksViewModel _tasks;
  final ValueChanged<TaskId>? navigateToTask;
  final VoidCallback? navigateBack;
  TaskDetailState? get state => _project(_tasks.state);

  @override
  void addListener(VoidCallback listener) => _tasks.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _tasks.removeListener(listener);

  static TaskDetailState? _project(TasksViewState source) {
    final task = source.selectedTask;
    if (task == null) return null;
    final children = source.tasks
        .where((candidate) => candidate.parentTaskId == task.id)
        .toList(growable: false);
    final parent = task.parentTaskId == null
        ? null
        : source.tasks
              .where((candidate) => candidate.id == task.parentTaskId)
              .firstOrNull;
    final parents = source.tasks
        .where(
          (candidate) =>
              candidate.id != task.id &&
              candidate.taskListId == task.taskListId &&
              candidate.parentTaskId == null,
        )
        .toList(growable: false);
    final siblings = source.tasks
        .where(
          (candidate) =>
              candidate.taskListId == task.taskListId &&
              candidate.parentTaskId == task.parentTaskId,
        )
        .toList(growable: false);
    final due = effectiveDueDates(source.tasks)[task.id]!;
    return TaskDetailState(
      task: task,
      parent: parent,
      children: List<CachedTask>.unmodifiable(children),
      progress: projectDirectChildProgress(
        parentTaskId: task.id,
        tasks: source.tasks,
      ),
      effectiveDue: due,
      dueChangeUndo: source.taskDueChangeUndos.firstOrNull,
      parentCandidates: List<CachedTask>.unmodifiable(parents),
      siblings: List<CachedTask>.unmodifiable(siblings),
      destinationLists: List<CachedTaskList>.unmodifiable(
        source.taskLists.where((candidate) => candidate.id != task.taskListId),
      ),
      isCommandPending: source.isTaskCommandPending,
      failureMessage: source.taskCommandFailureMessage,
    );
  }

  Future<void> createSubtask({required String title}) {
    final detail = state;
    if (detail == null || !detail.canCreateSubtask) {
      return Future<void>.value();
    }
    return _tasks.createTask(
      taskListId: detail.task.taskListId,
      parentTaskId: detail.task.id,
      title: title,
    );
  }

  Future<void> saveContent({
    required CachedTask task,
    required String title,
    required String? notes,
  }) => _tasks.updateTaskContent(
    taskId: task.id,
    title: title,
    notes: notes,
    status: task.status,
    due: task.due,
  );

  Future<void> toggleCompletion(TaskId taskId) {
    final task = _tasks.state.tasks
        .where((candidate) => candidate.id == taskId)
        .firstOrNull;
    if (task == null) return Future<void>.value();
    return _tasks.setTaskCompletion(
      taskId,
      task.status == TaskStatus.completed
          ? TaskStatus.needsAction
          : TaskStatus.completed,
    );
  }

  Future<void> setDue(TaskId taskId, TaskDate? due) =>
      _tasks.setTaskDue(taskId, due);

  Future<void> setDueShortcut(TaskId taskId, DateShortcut shortcut) =>
      _tasks.setTaskDueShortcut(taskId, shortcut);

  Future<void> undoDueChange(int groupId) => _tasks.undoTaskDueChange(groupId);

  Future<void> deleteTask(TaskId taskId) => _tasks.deleteTask(taskId);

  Future<void> promote(TaskId taskId) => _tasks.promoteTask(taskId);

  Future<void> reparent(TaskId taskId, TaskId parentTaskId) =>
      _tasks.demoteTask(taskId, parentTaskId);

  Future<void> moveToList(TaskId taskId, TaskListId destinationTaskListId) {
    return _tasks.moveTask(
      taskId: taskId,
      destinationTaskListId: destinationTaskListId,
    );
  }

  Future<void> moveSelectedUp() {
    final detail = state;
    if (detail == null) return Future<void>.value();
    return _moveWithinSiblings(detail, detail.task.id, -1);
  }

  Future<void> moveSelectedDown() {
    final detail = state;
    if (detail == null) return Future<void>.value();
    return _moveWithinSiblings(detail, detail.task.id, 1);
  }

  Future<void> moveChildUp(TaskId childTaskId) {
    final detail = state;
    if (detail == null) return Future<void>.value();
    return _moveChild(detail, childTaskId, -1);
  }

  Future<void> moveChildDown(TaskId childTaskId) {
    final detail = state;
    if (detail == null) return Future<void>.value();
    return _moveChild(detail, childTaskId, 1);
  }

  Future<void> _moveChild(
    TaskDetailState detail,
    TaskId childTaskId,
    int offset,
  ) {
    final child = detail.children
        .where((candidate) => candidate.id == childTaskId)
        .firstOrNull;
    if (child == null) return Future<void>.value();
    final childDetail = TaskDetailState(
      task: child,
      parent: detail.task,
      children: const <CachedTask>[],
      progress: const DirectChildProgress(completed: 0, total: 0),
      effectiveDue: effectiveDueDates(<CachedTask>[child])[child.id]!,
      dueChangeUndo: detail.dueChangeUndo,
      parentCandidates: const <CachedTask>[],
      siblings: detail.children,
      destinationLists: detail.destinationLists,
      isCommandPending: detail.isCommandPending,
      failureMessage: detail.failureMessage,
    );
    return _moveWithinSiblings(childDetail, childTaskId, offset);
  }

  Future<void> _moveWithinSiblings(
    TaskDetailState detail,
    TaskId taskId,
    int offset,
  ) {
    final index = detail.siblings.indexWhere((task) => task.id == taskId);
    final target = index + offset;
    if (index < 0 || target < 0 || target >= detail.siblings.length) {
      return Future<void>.value();
    }
    final previous = offset < 0
        ? (target == 0 ? null : detail.siblings[target - 1].id)
        : detail.siblings[target].id;
    return _tasks.moveTask(
      taskId: taskId,
      destinationTaskListId: detail.task.taskListId,
      parentTaskId: detail.task.parentTaskId,
      previousTaskId: previous,
    );
  }

  void select(TaskId taskId) {
    final navigate = navigateToTask;
    if (navigate != null) {
      navigate(taskId);
    } else {
      _tasks.selectTask(taskId);
    }
  }

  void back() {
    final navigate = navigateBack;
    if (navigate != null) {
      navigate();
    } else {
      _tasks.backFromTaskDetail();
    }
  }

  void close() => _tasks.clearTaskSelection();
}
