import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/model/tasks.dart';
import '../../../domain/policy/subtask_progress.dart';
import '../task_detail_view_model.dart';

final class TaskDetailsPane extends StatelessWidget {
  const TaskDetailsPane({
    required this.viewModel,
    required this.compact,
    super.key,
  });

  final TaskDetailViewModel viewModel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final state = viewModel.state;
    if (state == null) {
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
    final task = state.task;
    final alternateParents = state.parentCandidates
        .where((candidate) => candidate.id != task.parentTaskId)
        .toList(growable: false);
    final siblingIndex = state.siblingIndex;
    return FocusTraversalGroup(
      child: SingleChildScrollView(
        key: const Key('task-detail-scroll-view'),
        padding: EdgeInsets.fromLTRB(
          compact ? 18 : 24,
          20,
          compact ? 18 : 24,
          32,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (compact || state.parent != null)
                  IconButton(
                    autofocus: true,
                    tooltip: state.parent == null
                        ? 'Back to task collection'
                        : 'Back to parent task',
                    onPressed: viewModel.back,
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      task.title,
                      key: const Key('task-detail-title'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  autofocus: !compact && state.parent == null,
                  tooltip: 'Close details',
                  onPressed: viewModel.close,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Tooltip(
                  message: 'Edit task content',
                  child: OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () =>
                              _showTaskContentDialog(context, viewModel, task),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit task'),
                  ),
                ),
                Tooltip(
                  message: 'Delete task',
                  child: OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => unawaited(viewModel.deleteTask(task.id)),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _DetailLabel(label: 'Status', value: _statusLabel(task.status)),
            if (task.due != null)
              _DetailLabel(label: 'Due', value: task.due.toString()),
            const SizedBox(height: 12),
            TaskNotesSection(notes: task.notes),
            if (state.children.isNotEmpty) ...<Widget>[
              const SizedBox(height: 24),
              SubtaskProgressIndicator(progress: state.progress),
              const SizedBox(height: 8),
              SubtaskList(viewModel: viewModel, children: state.children),
            ],
            const SizedBox(height: 22),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (state.canCreateSubtask)
                  OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => _showCreateSubtaskDialog(context, viewModel),
                    icon: const Icon(Icons.add),
                    label: const Text('Add subtask'),
                  ),
                if (task.parentTaskId == null &&
                    !state.hasChildren &&
                    state.parentCandidates.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => _showParentDialog(
                            context,
                            viewModel,
                            task,
                            state.parentCandidates,
                          ),
                    icon: const Icon(Icons.subdirectory_arrow_right),
                    label: const Text('Make subtask'),
                  ),
                if (task.parentTaskId != null)
                  OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => unawaited(viewModel.promote(task.id)),
                    icon: const Icon(Icons.arrow_upward),
                    label: const Text('Promote'),
                  ),
                if (task.parentTaskId != null && alternateParents.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => _showParentDialog(
                            context,
                            viewModel,
                            task,
                            alternateParents,
                          ),
                    icon: const Icon(Icons.account_tree_outlined),
                    label: const Text('Change parent'),
                  ),
                if (siblingIndex > 0)
                  OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => unawaited(viewModel.moveSelectedUp()),
                    icon: const Icon(Icons.arrow_upward),
                    label: const Text('Move up'),
                  ),
                if (siblingIndex >= 0 &&
                    siblingIndex < state.siblings.length - 1)
                  OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => unawaited(viewModel.moveSelectedDown()),
                    icon: const Icon(Icons.arrow_downward),
                    label: const Text('Move down'),
                  ),
                if (state.destinationLists.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => _showMoveListDialog(
                            context,
                            viewModel,
                            task,
                            state.destinationLists,
                          ),
                    icon: const Icon(Icons.drive_file_move_outline),
                    label: const Text('Move to list'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class TaskNotesSection extends StatelessWidget {
  const TaskNotesSection({required this.notes, super.key});

  final String? notes;

  @override
  Widget build(BuildContext context) {
    final value = notes;
    return Semantics(
      container: true,
      label: switch (value) {
        null => 'Notes. No notes',
        '' => 'Notes. Empty notes',
        _ => 'Task notes',
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Notes', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          SelectableText(switch (value) {
            null => 'No notes',
            '' => 'Empty notes',
            _ => value,
          }, key: const Key('task-notes-content')),
        ],
      ),
    );
  }
}

final class SubtaskProgressIndicator extends StatelessWidget {
  const SubtaskProgressIndicator({required this.progress, super.key});

  final DirectChildProgress progress;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: progress.label,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Subtasks', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(progress.label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: progress.fraction),
      ],
    ),
  );
}

enum _SubtaskAction { edit, moveUp, moveDown, promote, delete }

final class SubtaskList extends StatelessWidget {
  const SubtaskList({
    required this.viewModel,
    required this.children,
    super.key,
  });

  final TaskDetailViewModel viewModel;
  final List<CachedTask> children;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      for (final (index, child) in children.indexed)
        ListTile(
          key: ValueKey<String>('subtask-${child.id.value}'),
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            child.status == TaskStatus.completed
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
          ),
          title: Text(child.title),
          subtitle: child.notes?.isNotEmpty == true
              ? Text(child.notes!, maxLines: 1, overflow: TextOverflow.ellipsis)
              : null,
          trailing: PopupMenuButton<_SubtaskAction>(
            tooltip: 'Manage ${child.title}',
            enabled: viewModel.state?.isCommandPending != true,
            onSelected: (action) {
              switch (action) {
                case _SubtaskAction.edit:
                  _showTaskContentDialog(context, viewModel, child);
                case _SubtaskAction.moveUp:
                  unawaited(viewModel.moveChildUp(child.id));
                case _SubtaskAction.moveDown:
                  unawaited(viewModel.moveChildDown(child.id));
                case _SubtaskAction.promote:
                  unawaited(viewModel.promote(child.id));
                case _SubtaskAction.delete:
                  unawaited(viewModel.deleteTask(child.id));
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<_SubtaskAction>>[
              const PopupMenuItem(
                value: _SubtaskAction.edit,
                child: Text('Edit subtask'),
              ),
              PopupMenuItem(
                value: _SubtaskAction.moveUp,
                enabled: index > 0,
                child: const Text('Move subtask up'),
              ),
              PopupMenuItem(
                value: _SubtaskAction.moveDown,
                enabled: index < children.length - 1,
                child: const Text('Move subtask down'),
              ),
              const PopupMenuItem(
                value: _SubtaskAction.promote,
                child: Text('Promote subtask'),
              ),
              const PopupMenuItem(
                value: _SubtaskAction.delete,
                child: Text('Delete subtask'),
              ),
            ],
          ),
          onTap: () => viewModel.select(child.id),
        ),
    ],
  );
}

Future<void> _showCreateSubtaskDialog(
  BuildContext context,
  TaskDetailViewModel viewModel,
) => showDialog<void>(
  context: context,
  builder: (_) => _CreateSubtaskDialog(viewModel: viewModel),
);

final class _CreateSubtaskDialog extends StatefulWidget {
  const _CreateSubtaskDialog({required this.viewModel});

  final TaskDetailViewModel viewModel;

  @override
  State<_CreateSubtaskDialog> createState() => _CreateSubtaskDialogState();
}

final class _CreateSubtaskDialogState extends State<_CreateSubtaskDialog> {
  final _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    await widget.viewModel.createSubtask(title: _title.text);
    if (mounted && widget.viewModel.state?.failureMessage == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) => AlertDialog(
      title: const Text('Create subtask'),
      content: TextField(
        controller: _title,
        autofocus: true,
        maxLength: 1024,
        decoration: const InputDecoration(labelText: 'Task title'),
        onSubmitted: widget.viewModel.state?.isCommandPending == true
            ? null
            : (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: widget.viewModel.state?.isCommandPending == true
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.viewModel.state?.isCommandPending == true
              ? null
              : _submit,
          child: widget.viewModel.state?.isCommandPending == true
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

Future<void> _showTaskContentDialog(
  BuildContext context,
  TaskDetailViewModel viewModel,
  CachedTask task,
) => showDialog<void>(
  context: context,
  builder: (_) => _TaskContentDialog(viewModel: viewModel, task: task),
);

final class _TaskContentDialog extends StatefulWidget {
  const _TaskContentDialog({required this.viewModel, required this.task});

  final TaskDetailViewModel viewModel;
  final CachedTask task;

  @override
  State<_TaskContentDialog> createState() => _TaskContentDialogState();
}

final class _TaskContentDialogState extends State<_TaskContentDialog> {
  late final _title = TextEditingController(text: widget.task.title);
  late final _notes = TextEditingController(text: widget.task.notes ?? '');
  late final _due = TextEditingController(
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
    await widget.viewModel.saveContent(
      task: widget.task,
      title: _title.text,
      notes: _clearNotes ? null : _notes.text,
      due: due,
    );
    if (mounted && widget.viewModel.state?.failureMessage == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) => AlertDialog(
      title: const Text('Edit task'),
      content: SizedBox(
        width: 480,
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
                minLines: 6,
                maxLines: 14,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Clear notes'),
                subtitle: const Text(
                  'Keep this off to preserve an intentionally empty note.',
                ),
                value: _clearNotes,
                onChanged: widget.viewModel.state?.isCommandPending == true
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
          onPressed: widget.viewModel.state?.isCommandPending == true
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.viewModel.state?.isCommandPending == true
              ? null
              : _submit,
          child: widget.viewModel.state?.isCommandPending == true
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

Future<void> _showParentDialog(
  BuildContext context,
  TaskDetailViewModel viewModel,
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
                await viewModel.reparent(task.id, parent.id);
                if (dialogContext.mounted &&
                    viewModel.state?.failureMessage == null) {
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

Future<void> _showMoveListDialog(
  BuildContext context,
  TaskDetailViewModel viewModel,
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
                unawaited(viewModel.moveToList(task.id, destination.id));
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
  Widget build(BuildContext context) => Padding(
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

String _statusLabel(TaskStatus status) => switch (status) {
  TaskStatus.needsAction => 'Not completed',
  TaskStatus.completed => 'Completed',
};
