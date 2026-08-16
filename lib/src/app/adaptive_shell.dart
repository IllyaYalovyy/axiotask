import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/model/tasks.dart';
import '../features/tasks/tasks_view_model.dart';
import '../features/tasks/widgets/sync_health_header.dart';
import '../sync/health/sync_health.dart';

final class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({
    required this.viewModel,
    this.onHealthAction,
    super.key,
  });

  final TasksViewModel viewModel;
  final ValueChanged<SyncHealthAction>? onHealthAction;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

final class _AdaptiveShellState extends State<AdaptiveShell> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.start();
  }

  @override
  void didUpdateWidget(covariant AdaptiveShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel != widget.viewModel) widget.viewModel.start();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.viewModel,
          builder: (context, _) {
            final state = widget.viewModel.state;
            return Column(
              children: <Widget>[
                _ApplicationHeader(
                  health: state.health,
                  onHealthAction: state.isSyncControlPending
                      ? null
                      : widget.onHealthAction ??
                            (action) => unawaited(
                              widget.viewModel.handleSyncHealthAction(action),
                            ),
                  isRefreshing: state.isRefreshing,
                  isSyncControlPending: state.isSyncControlPending,
                  onRefresh: widget.viewModel.refresh,
                  onStopSync: widget.viewModel.stopSync,
                ),
                if (state.syncControlFailureMessage case final message?)
                  MaterialBanner(
                    content: Text(message),
                    actions: const <Widget>[SizedBox.shrink()],
                  ),
                if (state.listCommandFailureMessage case final message?)
                  MaterialBanner(
                    content: Text(message),
                    actions: const <Widget>[SizedBox.shrink()],
                  ),
                if (state.taskCommandFailureMessage case final message?)
                  MaterialBanner(
                    content: Text(message),
                    actions: const <Widget>[SizedBox.shrink()],
                  ),
                if (state.taskDeleteUndos.firstOrNull case final undo?)
                  MaterialBanner(
                    leading: const Icon(Icons.delete_outline),
                    content: Text('“${undo.title}” deleted'),
                    actions: <Widget>[
                      TextButton(
                        onPressed: state.isTaskCommandPending
                            ? null
                            : () => unawaited(
                                widget.viewModel.undoTaskDelete(undo.taskId),
                              ),
                        child: const Text('Undo'),
                      ),
                    ],
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => _ShellBody(
                      state: state,
                      viewModel: widget.viewModel,
                      wide: constraints.maxWidth >= 900,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

final class _ApplicationHeader extends StatelessWidget {
  const _ApplicationHeader({
    required this.health,
    required this.isRefreshing,
    required this.isSyncControlPending,
    required this.onRefresh,
    required this.onStopSync,
    this.onHealthAction,
  });

  final SyncHealth health;
  final ValueChanged<SyncHealthAction>? onHealthAction;
  final bool isRefreshing;
  final bool isSyncControlPending;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onStopSync;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.check_circle_outline,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Text(
                'Axiotask',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed:
                    isRefreshing ||
                        isSyncControlPending ||
                        health.inactiveReason == SyncInactiveReason.syncStopped
                    ? null
                    : onRefresh,
                icon: isRefreshing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
              if (health.outcome != SyncHealthOutcome.inactive) ...<Widget>[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: isSyncControlPending ? null : onStopSync,
                  icon: isSyncControlPending
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.pause_circle_outline),
                  label: const Text('Stop sync'),
                ),
              ],
            ],
          ),
        ),
        SyncHealthHeader(health: health, onAction: onHealthAction),
      ],
    );
  }
}

final class _ShellBody extends StatelessWidget {
  const _ShellBody({
    required this.state,
    required this.viewModel,
    required this.wide,
  });

  final TasksViewState state;
  final TasksViewModel viewModel;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    if (state.failureMessage case final message?) {
      return Center(child: Text(message));
    }
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!wide) {
      return _TaskCollection(state: state, viewModel: viewModel);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 244,
          child: _ListNavigation(state: state, viewModel: viewModel),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _TaskCollection(state: state, viewModel: viewModel),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 360,
          child: _TaskDetails(state: state, viewModel: viewModel),
        ),
      ],
    );
  }
}

final class _ListNavigation extends StatelessWidget {
  const _ListNavigation({required this.state, required this.viewModel});

  final TasksViewState state;
  final TasksViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'TASK LISTS',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            const SizedBox(height: 8),
            if (state.taskLists.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No cached Google task lists'),
              ),
            for (final list in state.taskLists)
              ListTile(
                selected: list.id == state.selectedTaskListId,
                leading: const Icon(Icons.list_alt_outlined),
                title: Text(
                  list.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => viewModel.selectTaskList(list.id),
              ),
          ],
        ),
      ),
    );
  }
}

final class _TaskCollection extends StatelessWidget {
  const _TaskCollection({required this.state, required this.viewModel});

  final TasksViewState state;
  final TasksViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final tasks = state.visibleTasks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      state.selectedTaskList?.title ?? 'Cached tasks',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Create task',
                    onPressed:
                        state.isTaskCommandPending ||
                            state.selectedTaskList == null
                        ? null
                        : () => _showCreateTaskDialog(
                            context,
                            viewModel,
                            state.selectedTaskList!.id,
                          ),
                    icon: const Icon(Icons.add_task),
                  ),
                  IconButton(
                    tooltip: 'Create Google task list',
                    onPressed:
                        state.isListCommandPending ||
                            viewModel.taskListsRepository == null
                        ? null
                        : () => _showCreateTaskListDialog(context, viewModel),
                    icon: const Icon(Icons.playlist_add),
                  ),
                  IconButton(
                    tooltip: 'Rename selected task list',
                    onPressed:
                        state.isListCommandPending ||
                            viewModel.taskListsRepository == null ||
                            state.selectedTaskList == null
                        ? null
                        : () => _showRenameTaskListDialog(
                            context,
                            viewModel,
                            state.selectedTaskList!,
                          ),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'Delete selected task list',
                    onPressed:
                        state.isListCommandPending ||
                            viewModel.taskListsRepository == null ||
                            state.selectedTaskList == null
                        ? null
                        : () => _showDeleteTaskListConfirmation(
                            context,
                            viewModel,
                            state.selectedTaskList!,
                          ),
                    icon: const Icon(Icons.delete_forever_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${tasks.length} cached ${tasks.length == 1 ? 'task' : 'tasks'}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? const Center(child: Text('No cached tasks in this list'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final childCount = state.tasks
                        .where((value) => value.parentTaskId == task.id)
                        .length;
                    return ListTile(
                      selected: task.id == state.selectedTaskId,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 6,
                      ),
                      leading: IconButton(
                        tooltip: task.status == TaskStatus.completed
                            ? 'Reopen task'
                            : 'Complete task',
                        onPressed: state.isTaskCommandPending
                            ? null
                            : () => unawaited(
                                viewModel.setTaskCompletion(
                                  task.id,
                                  task.status == TaskStatus.completed
                                      ? TaskStatus.needsAction
                                      : TaskStatus.completed,
                                ),
                              ),
                        icon: Icon(
                          task.status == TaskStatus.completed
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                        ),
                      ),
                      title: Text(task.title),
                      subtitle: Text(
                        <String>[
                          if (task.due != null) 'Due ${task.due}',
                          if (childCount > 0)
                            '$childCount ${childCount == 1 ? 'subtask' : 'subtasks'}',
                        ].join(' • '),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => viewModel.selectTask(task.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

Future<void> _showCreateTaskListDialog(
  BuildContext context,
  TasksViewModel viewModel,
) => showDialog<void>(
  context: context,
  builder: (_) => _TaskListEditDialog(
    viewModel: viewModel,
    dialogTitle: 'Create task list',
    actionLabel: 'Create',
    initialTitle: '',
    submit: viewModel.createTaskList,
  ),
);

Future<void> _showRenameTaskListDialog(
  BuildContext context,
  TasksViewModel viewModel,
  CachedTaskList taskList,
) => showDialog<void>(
  context: context,
  builder: (_) => _TaskListEditDialog(
    viewModel: viewModel,
    dialogTitle: 'Rename task list',
    actionLabel: 'Rename',
    initialTitle: taskList.title,
    submit: (title) => viewModel.renameTaskList(taskList.id, title),
  ),
);

Future<void> _showCreateTaskDialog(
  BuildContext context,
  TasksViewModel viewModel,
  TaskListId taskListId, {
  TaskId? parentTaskId,
}) => showDialog<void>(
  context: context,
  builder: (_) => _CreateTaskDialog(
    viewModel: viewModel,
    taskListId: taskListId,
    parentTaskId: parentTaskId,
  ),
);

final class _TaskListEditDialog extends StatefulWidget {
  const _TaskListEditDialog({
    required this.viewModel,
    required this.dialogTitle,
    required this.actionLabel,
    required this.initialTitle,
    required this.submit,
  });

  final TasksViewModel viewModel;
  final String dialogTitle;
  final String actionLabel;
  final String initialTitle;
  final Future<void> Function(String title) submit;

  @override
  State<_TaskListEditDialog> createState() => _TaskListEditDialogState();
}

final class _TaskListEditDialogState extends State<_TaskListEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    await widget.submit(_controller.text);
    if (mounted && widget.viewModel.state.listCommandFailureMessage == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) => AlertDialog(
        title: Text(widget.dialogTitle),
        content: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 1024,
          decoration: const InputDecoration(labelText: 'List title'),
          onSubmitted: widget.viewModel.state.isListCommandPending
              ? null
              : (_) => _submit(),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: widget.viewModel.state.isListCommandPending
                ? null
                : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: widget.viewModel.state.isListCommandPending
                ? null
                : _submit,
            child: widget.viewModel.state.isListCommandPending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.actionLabel),
          ),
        ],
      ),
    );
  }
}

final class _TaskDetails extends StatelessWidget {
  const _TaskDetails({required this.state, required this.viewModel});

  final TasksViewState state;
  final TasksViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final task = state.selectedTask;
    if (task == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.task_alt,
                size: 44,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              const Text('Select a cached task to view details'),
            ],
          ),
        ),
      );
    }
    final hasChildren = state.selectedTaskChildren.isNotEmpty;
    final parentCandidates = state.tasks
        .where(
          (candidate) =>
              candidate.id != task.id &&
              candidate.taskListId == task.taskListId &&
              candidate.parentTaskId == null,
        )
        .toList(growable: false);
    final alternateParentCandidates = parentCandidates
        .where((candidate) => candidate.id != task.parentTaskId)
        .toList(growable: false);
    final siblings = state.tasks
        .where(
          (candidate) =>
              candidate.taskListId == task.taskListId &&
              candidate.parentTaskId == task.parentTaskId,
        )
        .toList(growable: false);
    final siblingIndex = siblings.indexWhere(
      (candidate) => candidate.id == task.id,
    );
    final destinationLists = state.taskLists
        .where((candidate) => candidate.id != task.taskListId)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Text(
                task.title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: 'Edit task content',
              onPressed: state.isTaskCommandPending
                  ? null
                  : () => _showTaskContentDialog(context, viewModel, task),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: 'Delete task',
              onPressed: state.isTaskCommandPending
                  ? null
                  : () => unawaited(viewModel.deleteTask(task.id)),
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              tooltip: 'Close details',
              onPressed: viewModel.clearTaskSelection,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _DetailLabel(label: 'Status', value: _statusLabel(task.status)),
        if (task.due != null)
          _DetailLabel(label: 'Due', value: task.due.toString()),
        const SizedBox(height: 18),
        Text('Notes', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Text(task.notes?.isNotEmpty == true ? task.notes! : 'No notes'),
        const SizedBox(height: 22),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (task.parentTaskId == null)
              OutlinedButton.icon(
                onPressed: state.isTaskCommandPending
                    ? null
                    : () => _showCreateTaskDialog(
                        context,
                        viewModel,
                        task.taskListId,
                        parentTaskId: task.id,
                      ),
                icon: const Icon(Icons.add),
                label: const Text('Add subtask'),
              ),
            if (task.parentTaskId == null &&
                !hasChildren &&
                parentCandidates.isNotEmpty)
              OutlinedButton.icon(
                onPressed: state.isTaskCommandPending
                    ? null
                    : () => _showDemoteTaskDialog(
                        context,
                        viewModel,
                        task,
                        parentCandidates,
                      ),
                icon: const Icon(Icons.subdirectory_arrow_right),
                label: const Text('Make subtask'),
              ),
            if (task.parentTaskId != null)
              OutlinedButton.icon(
                onPressed: state.isTaskCommandPending
                    ? null
                    : () => unawaited(viewModel.promoteTask(task.id)),
                icon: const Icon(Icons.arrow_upward),
                label: const Text('Promote'),
              ),
            if (task.parentTaskId != null &&
                alternateParentCandidates.isNotEmpty)
              OutlinedButton.icon(
                onPressed: state.isTaskCommandPending
                    ? null
                    : () => _showDemoteTaskDialog(
                        context,
                        viewModel,
                        task,
                        alternateParentCandidates,
                      ),
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('Change parent'),
              ),
            if (siblingIndex > 0)
              OutlinedButton.icon(
                onPressed: state.isTaskCommandPending
                    ? null
                    : () => unawaited(
                        viewModel.moveTask(
                          taskId: task.id,
                          destinationTaskListId: task.taskListId,
                          parentTaskId: task.parentTaskId,
                          previousTaskId: siblingIndex == 1
                              ? null
                              : siblings[siblingIndex - 2].id,
                        ),
                      ),
                icon: const Icon(Icons.arrow_upward),
                label: const Text('Move up'),
              ),
            if (siblingIndex >= 0 && siblingIndex < siblings.length - 1)
              OutlinedButton.icon(
                onPressed: state.isTaskCommandPending
                    ? null
                    : () => unawaited(
                        viewModel.moveTask(
                          taskId: task.id,
                          destinationTaskListId: task.taskListId,
                          parentTaskId: task.parentTaskId,
                          previousTaskId: siblings[siblingIndex + 1].id,
                        ),
                      ),
                icon: const Icon(Icons.arrow_downward),
                label: const Text('Move down'),
              ),
            if (destinationLists.isNotEmpty)
              OutlinedButton.icon(
                onPressed: state.isTaskCommandPending
                    ? null
                    : () => _showMoveTaskDialog(
                        context,
                        viewModel,
                        task,
                        destinationLists,
                      ),
                icon: const Icon(Icons.drive_file_move_outline),
                label: const Text('Move to list'),
              ),
          ],
        ),
        if (state.selectedTaskChildren.isNotEmpty) ...<Widget>[
          const SizedBox(height: 28),
          Text('Subtasks', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final child in state.selectedTaskChildren)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                child.status == TaskStatus.completed
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
              ),
              title: Text(child.title),
              trailing: IconButton(
                tooltip: 'Promote subtask',
                onPressed: state.isTaskCommandPending
                    ? null
                    : () => unawaited(viewModel.promoteTask(child.id)),
                icon: const Icon(Icons.arrow_upward),
              ),
              onTap: () => viewModel.selectTask(child.id),
            ),
        ],
      ],
    );
  }
}

Future<void> _showTaskContentDialog(
  BuildContext context,
  TasksViewModel viewModel,
  CachedTask task,
) => showDialog<void>(
  context: context,
  builder: (_) => _TaskContentDialog(viewModel: viewModel, task: task),
);

Future<void> _showDemoteTaskDialog(
  BuildContext context,
  TasksViewModel viewModel,
  CachedTask task,
  List<CachedTask> candidates,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Choose parent task'),
    content: SizedBox(
      width: 360,
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          for (final parent in candidates)
            ListTile(
              title: Text(parent.title),
              onTap: () async {
                await viewModel.demoteTask(task.id, parent.id);
                if (dialogContext.mounted &&
                    viewModel.state.taskCommandFailureMessage == null) {
                  Navigator.of(dialogContext).pop();
                }
              },
            ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('Cancel'),
      ),
    ],
  ),
);

Future<void> _showMoveTaskDialog(
  BuildContext context,
  TasksViewModel viewModel,
  CachedTask task,
  List<CachedTaskList> destinations,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Move task to list'),
    content: SizedBox(
      width: 360,
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          for (final destination in destinations)
            ListTile(
              title: Text(destination.title),
              onTap: () {
                Navigator.of(dialogContext).pop();
                unawaited(
                  viewModel.moveTask(
                    taskId: task.id,
                    destinationTaskListId: destination.id,
                  ),
                );
              },
            ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('Cancel'),
      ),
    ],
  ),
);

Future<void> _showDeleteTaskListConfirmation(
  BuildContext context,
  TasksViewModel viewModel,
  CachedTaskList taskList,
) => showDialog<void>(
  context: context,
  builder: (_) => DeleteTaskListConfirmationDialog(
    viewModel: viewModel,
    taskList: taskList,
  ),
);

final class DeleteTaskListConfirmationDialog extends StatelessWidget {
  const DeleteTaskListConfirmationDialog({
    required this.viewModel,
    required this.taskList,
    super.key,
  });

  final TasksViewModel viewModel;
  final CachedTaskList taskList;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Delete “${taskList.title}”?'),
    content: const Text(
      'This deletes the Google task list and its tasks. This action cannot be undone.',
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () async {
          await viewModel.deleteTaskList(taskList.id);
          if (context.mounted &&
              viewModel.state.listCommandFailureMessage == null) {
            Navigator.of(context).pop();
          }
        },
        child: const Text('Delete list'),
      ),
    ],
  );
}

final class _CreateTaskDialog extends StatefulWidget {
  const _CreateTaskDialog({
    required this.viewModel,
    required this.taskListId,
    this.parentTaskId,
  });

  final TasksViewModel viewModel;
  final TaskListId taskListId;
  final TaskId? parentTaskId;

  @override
  State<_CreateTaskDialog> createState() => _CreateTaskDialogState();
}

final class _CreateTaskDialogState extends State<_CreateTaskDialog> {
  final TextEditingController _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    await widget.viewModel.createTask(
      taskListId: widget.taskListId,
      parentTaskId: widget.parentTaskId,
      title: _title.text,
    );
    if (mounted && widget.viewModel.state.taskCommandFailureMessage == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) => AlertDialog(
      title: Text(
        widget.parentTaskId == null ? 'Create task' : 'Create subtask',
      ),
      content: TextField(
        controller: _title,
        autofocus: true,
        maxLength: 1024,
        decoration: const InputDecoration(labelText: 'Task title'),
        onSubmitted: widget.viewModel.state.isTaskCommandPending
            ? null
            : (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: widget.viewModel.state.isTaskCommandPending
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.viewModel.state.isTaskCommandPending
              ? null
              : _submit,
          child: widget.viewModel.state.isTaskCommandPending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    ),
  );
}

final class _TaskContentDialog extends StatefulWidget {
  const _TaskContentDialog({required this.viewModel, required this.task});

  final TasksViewModel viewModel;
  final CachedTask task;

  @override
  State<_TaskContentDialog> createState() => _TaskContentDialogState();
}

final class _TaskContentDialogState extends State<_TaskContentDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.task.title,
  );
  late final TextEditingController _notes = TextEditingController(
    text: widget.task.notes ?? '',
  );
  late final TextEditingController _due = TextEditingController(
    text: widget.task.due?.toString() ?? '',
  );
  late bool _clearNotes = widget.task.notes == null;
  String? _dateError;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _due.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final due = _parseTaskDate(_due.text);
    if (_due.text.trim().isNotEmpty && due == null) {
      setState(() => _dateError = 'Use a valid YYYY-MM-DD date.');
      return;
    }
    setState(() => _dateError = null);
    await widget.viewModel.updateTaskContent(
      taskId: widget.task.id,
      title: _title.text,
      notes: _clearNotes ? null : _notes.text,
      status: widget.task.status,
      due: due,
    );
    if (mounted && widget.viewModel.state.taskCommandFailureMessage == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) => AlertDialog(
      title: const Text('Edit task content'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _title,
                maxLength: 1024,
                decoration: const InputDecoration(labelText: 'Task title'),
              ),
              TextField(
                controller: _notes,
                enabled: !_clearNotes,
                maxLength: 8192,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Clear notes'),
                value: _clearNotes,
                onChanged: widget.viewModel.state.isTaskCommandPending
                    ? null
                    : (value) => setState(() => _clearNotes = value ?? false),
              ),
              TextField(
                controller: _due,
                decoration: InputDecoration(
                  labelText: 'Due date (YYYY-MM-DD)',
                  errorText: _dateError,
                  helperText: 'Leave blank to clear the due date.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: widget.viewModel.state.isTaskCommandPending
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.viewModel.state.isTaskCommandPending
              ? null
              : _submit,
          child: widget.viewModel.state.isTaskCommandPending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    ),
  );
}

TaskDate? _parseTaskDate(String input) {
  final value = input.trim();
  if (value.isEmpty) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) return null;
  try {
    return TaskDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  } on ArgumentError {
    return null;
  }
}

final class _DetailLabel extends StatelessWidget {
  const _DetailLabel({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

String _statusLabel(TaskStatus status) => switch (status) {
  TaskStatus.needsAction => 'Not completed',
  TaskStatus.completed => 'Completed',
};
