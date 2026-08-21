import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/navigation_state.dart';
import '../../../domain/model/tasks.dart';
import '../../../domain/policy/date_workflow.dart';
import '../../../domain/policy/effective_due.dart';
import '../../../domain/policy/subtask_progress.dart';
import '../../../domain/policy/task_links.dart';
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
                  message: task.status == TaskStatus.completed
                      ? 'Reopen selected task'
                      : 'Complete selected task',
                  child: FilledButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => unawaited(viewModel.toggleCompletion(task.id)),
                    icon: Icon(
                      task.status == TaskStatus.completed
                          ? Icons.radio_button_unchecked
                          : Icons.check,
                    ),
                    label: Text(
                      task.status == TaskStatus.completed
                          ? 'Reopen'
                          : 'Complete',
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                    ),
                    key: const Key('task-detail-completion-action'),
                  ),
                ),
                _DateShortcutMenu(
                  enabled: !state.isCommandPending,
                  taskId: task.id,
                  viewModel: viewModel,
                ),
                OutlinedButton.icon(
                  onPressed: state.isCommandPending
                      ? null
                      : () => showTaskDateDialog(context, viewModel, task),
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: const Text('Choose date'),
                ),
                Tooltip(
                  message: 'Edit task content',
                  child: OutlinedButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => showTaskContentDialog(context, viewModel, task),
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
            _DetailLabel(
              label: 'Due',
              value: _effectiveDueLabel(state.effectiveDue),
            ),
            if (state.dueChangeUndo case final undo?) ...<Widget>[
              const SizedBox(height: 4),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Icon(Icons.history),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Date changed for ${undo.cascadedCount + 1} related tasks',
                            ),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: state.isCommandPending
                              ? null
                              : () => unawaited(
                                  viewModel.undoDueChange(undo.groupId),
                                ),
                          child: const Text('Undo due changes'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TaskNotesSection(notes: task.notes),
            const SizedBox(height: 18),
            TaskLinksSection(task: task, viewModel: viewModel),
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
                        : () => showTaskMoveListDialog(
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

/// Keeps the Google task page separate from links a user placed in task text.
///
/// The Google action is deliberately visible for every task.  Google can omit
/// its UI link, in which case the unavailable state explains why the action is
/// disabled rather than suggesting the task has no Google-side capabilities.
final class TaskLinksSection extends StatefulWidget {
  const TaskLinksSection({
    required this.task,
    required this.viewModel,
    super.key,
  });

  final CachedTask task;
  final TaskDetailViewModel viewModel;

  @override
  State<TaskLinksSection> createState() => _TaskLinksSectionState();
}

final class _TaskLinksSectionState extends State<TaskLinksSection> {
  String? _failureMessage;

  @override
  Widget build(BuildContext context) {
    final googleTaskLink = TaskLinkPolicy.googleTaskLink(
      widget.task.webViewLink,
    );
    final contentLinks = TaskLinkPolicy.userAuthoredLinks(
      title: widget.task.title,
      notes: widget.task.notes,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Google Tasks', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          googleTaskLink == null
              ? 'Google has not provided a usable link for this task yet.'
              : 'Open this task in Google Tasks for features not exposed by the API.',
        ),
        const SizedBox(height: 8),
        Semantics(
          button: true,
          label: 'Open task in Google Tasks',
          onTap: googleTaskLink == null
              ? null
              : () => unawaited(
                  _launch(
                    googleTaskLink,
                    failureMessage: 'Could not open Google Tasks.',
                  ),
                ),
          child: ExcludeSemantics(
            child: OutlinedButton.icon(
              key: const Key('open-in-google-tasks-action'),
              onPressed: googleTaskLink == null
                  ? null
                  : () => _launch(
                      googleTaskLink,
                      failureMessage: 'Could not open Google Tasks.',
                    ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open in Google Tasks'),
            ),
          ),
        ),
        if (contentLinks.isNotEmpty) ...<Widget>[
          const SizedBox(height: 18),
          Text(
            'Links in task content',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          for (final (index, link) in contentLinks.indexed)
            Semantics(
              button: true,
              label: 'Open external task link: ${_displayLink(link)}',
              onTap: () => unawaited(
                _launch(
                  link,
                  failureMessage: 'Could not open the external link.',
                ),
              ),
              child: ExcludeSemantics(
                child: TextButton.icon(
                  key: Key('task-content-link-$index'),
                  onPressed: () => _launch(
                    link,
                    failureMessage: 'Could not open the external link.',
                  ),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(_displayLink(link)),
                ),
              ),
            ),
        ],
        if (_failureMessage case final message?) ...<Widget>[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              key: const Key('task-link-launch-failure'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _launch(Uri uri, {required String failureMessage}) async {
    final launched = await widget.viewModel.launchExternalLink(uri);
    if (!mounted) return;
    setState(() => _failureMessage = launched ? null : failureMessage);
  }
}

String _displayLink(Uri uri) => uri.hasQuery || uri.hasFragment
    ? '${uri.host}${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}'
          '${uri.hasFragment ? '#${uri.fragment}' : ''}'
    : '${uri.host}${uri.path}';

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

final class _DateShortcutMenu extends StatelessWidget {
  const _DateShortcutMenu({
    required this.enabled,
    required this.taskId,
    required this.viewModel,
  });

  final bool enabled;
  final TaskId taskId;
  final TaskDetailViewModel viewModel;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: <Widget>[
      for (final entry in const <(DateShortcut, String)>[
        (DateShortcut.today, 'Today'),
        (DateShortcut.tomorrow, 'Tomorrow'),
        (DateShortcut.nextWeek, 'Next week'),
        (DateShortcut.nextMonth, 'Next month'),
        (DateShortcut.clear, 'Clear date'),
      ])
        MenuItemButton(
          onPressed: enabled
              ? () => unawaited(viewModel.setDueShortcut(taskId, entry.$1))
              : null,
          child: Text(entry.$2),
        ),
    ],
    builder: (context, controller, _) => OutlinedButton.icon(
      onPressed: enabled
          ? () => controller.isOpen ? controller.close() : controller.open()
          : null,
      icon: const Icon(Icons.event_outlined),
      label: const Text('Date'),
    ),
  );
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
          leading: IconButton(
            tooltip: child.status == TaskStatus.completed
                ? 'Reopen ${child.title}'
                : 'Complete ${child.title}',
            onPressed: viewModel.state?.isCommandPending == true
                ? null
                : () => unawaited(viewModel.toggleCompletion(child.id)),
            icon: Icon(
              child.status == TaskStatus.completed
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
            ),
          ),
          title: Text(child.title),
          subtitle: _subtaskSubtitle(child),
          trailing: PopupMenuButton<_SubtaskAction>(
            tooltip: 'Manage ${child.title}',
            enabled: viewModel.state?.isCommandPending != true,
            onSelected: (action) {
              switch (action) {
                case _SubtaskAction.edit:
                  showTaskContentDialog(context, viewModel, child);
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
) => showAppDialog<void>(
  context: context,
  kind: AppDialogKind.taskEdit,
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

Future<void> showTaskContentDialog(
  BuildContext context,
  TaskDetailViewModel viewModel,
  CachedTask task,
) => showAppDialog<void>(
  context: context,
  kind: AppDialogKind.taskEdit,
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
  late bool _clearNotes = widget.task.notes == null;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    await widget.viewModel.saveContent(
      task: widget.task,
      title: _title.text,
      notes: _clearNotes ? null : _notes.text,
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

Future<void> showTaskDateDialog(
  BuildContext context,
  TaskDetailViewModel viewModel,
  CachedTask task,
) => showAppDialog<void>(
  context: context,
  kind: AppDialogKind.date,
  builder: (_) => _TaskDateDialog(viewModel: viewModel, task: task),
);

final class _TaskDateDialog extends StatefulWidget {
  const _TaskDateDialog({required this.viewModel, required this.task});

  final TaskDetailViewModel viewModel;
  final CachedTask task;

  @override
  State<_TaskDateDialog> createState() => _TaskDateDialogState();
}

final class _TaskDateDialogState extends State<_TaskDateDialog> {
  late final _due = TextEditingController(
    text: widget.task.due?.toString() ?? '',
  );
  String? _dateError;

  @override
  void dispose() {
    _due.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final due = _parseTaskDate(_due.text);
    if (due == null) {
      setState(() => _dateError = 'Use a valid YYYY-MM-DD date.');
      return;
    }
    setState(() => _dateError = null);
    await widget.viewModel.setDue(widget.task.id, due);
    if (mounted && widget.viewModel.state?.failureMessage == null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) => AlertDialog(
      title: const Text('Choose due date'),
      content: TextField(
        controller: _due,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Due date (YYYY-MM-DD)',
          errorText: _dateError,
        ),
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
          child: const Text('Set date'),
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
) => showAppDialog<void>(
  context: context,
  kind: AppDialogKind.taskEdit,
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

Future<void> showTaskMoveListDialog(
  BuildContext context,
  TaskDetailViewModel viewModel,
  CachedTask task,
  List<CachedTaskList> destinations,
) => showAppDialog<void>(
  context: context,
  kind: AppDialogKind.taskEdit,
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

Widget? _subtaskSubtitle(CachedTask child) {
  final values = <String>[
    if (child.due case final due?) 'Due $due',
    if (child.notes case final notes? when notes.isNotEmpty) notes,
  ];
  if (values.isEmpty) return null;
  return Text(values.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis);
}

String _effectiveDueLabel(EffectiveDue due) {
  final effective = due.effective;
  if (effective == null) return 'No due date';
  if (due.explicit == null) return '$effective (from a direct subtask)';
  final inherited = due.fromChildren;
  if (inherited != null && compareTaskDates(inherited, due.explicit!) < 0) {
    return '$effective (earliest subtask; task date ${due.explicit})';
  }
  return effective.toString();
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
