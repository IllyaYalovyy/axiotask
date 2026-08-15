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
              Text(
                state.selectedTaskList?.title ?? 'Cached tasks',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
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
                      leading: Icon(
                        task.status == TaskStatus.completed
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
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
            ),
        ],
      ],
    );
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
