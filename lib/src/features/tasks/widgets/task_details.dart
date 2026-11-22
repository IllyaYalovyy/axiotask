import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../app/device_preferences_scope.dart';
import '../../../app/navigation_state.dart';
import '../../../domain/commands/task_commands.dart';
import '../../../domain/model/tasks.dart';
import '../../../domain/policy/date_workflow.dart';
import '../../../domain/policy/effective_due.dart';
import '../../../domain/policy/subtask_progress.dart';
import '../../../domain/policy/task_links.dart';
import '../task_detail_view_model.dart';
import 'task_content_editor.dart';
import 'task_date_calendar.dart';
import 'task_swipe.dart';

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
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          key: const Key('task-detail-empty-scroll-view'),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
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
            ),
          ),
        ),
      );
    }
    final phone =
        compact &&
        <TargetPlatform>{
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.fuchsia,
        }.contains(Theme.of(context).platform);
    final task = state.task;
    final alternateParents = state.parentCandidates
        .where((candidate) => candidate.id != task.parentTaskId)
        .toList(growable: false);
    final siblingIndex = state.siblingIndex;
    return TaskContentEditor(
      // One editor per task: switching tasks disposes the previous editor,
      // which stores its text for that task only.
      key: ValueKey<TaskId>(task.id),
      viewModel: viewModel,
      task: task,
      touchLayout: phone,
      builder: (context, content) => phone
          ? _buildPhoneDetails(context, state, content, alternateParents)
          : _buildDetails(
              context,
              state,
              content,
              alternateParents,
              siblingIndex,
            ),
    );
  }

  Widget _buildDetails(
    BuildContext context,
    TaskDetailState state,
    TaskContentFields content,
    List<CachedTask> alternateParents,
    int siblingIndex,
  ) {
    final task = state.task;
    return FocusTraversalGroup(
      child: SingleChildScrollView(
        key: const Key('task-detail-scroll-view'),
        primary: false,
        padding: EdgeInsets.fromLTRB(
          compact ? 12 : 16,
          12,
          compact ? 12 : 16,
          24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Previous/Next walk the ordering the user came from (the visible
            // collection, or the parent's subtasks); a disabled arrow marks a
            // boundary. The title gets the full width beneath, which a phone
            // needs once four 48 dp controls share the row.
            Row(
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
                const Spacer(),
                IconButton(
                  key: const Key('task-detail-previous'),
                  tooltip: 'Previous task',
                  onPressed: state.previousTaskId == null
                      ? null
                      : viewModel.selectPrevious,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  key: const Key('task-detail-next'),
                  tooltip: 'Next task',
                  onPressed: state.nextTaskId == null
                      ? null
                      : viewModel.selectNext,
                  icon: const Icon(Icons.chevron_right),
                ),
                IconButton(
                  autofocus: !compact && state.parent == null,
                  tooltip: 'Close details',
                  onPressed: viewModel.close,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            content.title,
            const SizedBox(height: 8),
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
                Tooltip(
                  message: 'Edit task content',
                  child: TextButton.icon(
                    onPressed: state.isCommandPending
                        ? null
                        : () => showTaskContentDialog(context, viewModel, task),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit task'),
                  ),
                ),
              ],
            ),
            if (state.isCommandPending ||
                state.failureMessage != null) ...<Widget>[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  state.failureMessage ?? 'Updating task…',
                  style: TextStyle(
                    color: state.failureMessage == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            _InspectorSection(
              title: 'Status',
              child: Text(_statusLabel(task.status)),
            ),
            _InspectorSection(
              title: 'Due',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_effectiveDueLabel(state.effectiveDue)),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _DateShortcutMenu(
                      enabled: !state.isCommandPending,
                      task: task,
                      viewModel: viewModel,
                    ),
                  ),
                ],
              ),
            ),
            if (state.dueChangeUndo case final undo?) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  const Icon(Icons.history, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Date changed for ${undo.cascadedCount + 1} related tasks',
                    ),
                  ),
                  TextButton(
                    onPressed: state.isCommandPending
                        ? null
                        : () =>
                              unawaited(viewModel.undoDueChange(undo.groupId)),
                    child: const Text('Undo due changes'),
                  ),
                ],
              ),
            ],
            _InspectorSection(title: 'Notes', child: content.notes),
            _InspectorSection(
              title: 'Google Tasks',
              child: TaskLinksSection(task: task, viewModel: viewModel),
            ),
            _InspectorSection(
              title: 'Subtasks',
              trailing: state.canCreateSubtask
                  ? TextButton.icon(
                      onPressed: state.isCommandPending
                          ? null
                          : () => _showCreateSubtaskDialog(context, viewModel),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add subtask'),
                    )
                  : null,
              child: state.children.isEmpty
                  ? Text(
                      'No subtasks',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  : _SubtasksBody(
                      // One toggle state per task: it resets to hidden when
                      // another task is shown.
                      key: ValueKey<TaskId>(task.id),
                      viewModel: viewModel,
                      progress: state.progress,
                      children: state.children,
                    ),
            ),
            _InspectorSection(
              title: 'Organization',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
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
                  _TaskStructureMenu(
                    enabled: !state.isCommandPending,
                    task: task,
                    hasChildren: state.hasChildren,
                    parents: state.parentCandidates,
                    alternateParents: alternateParents,
                    viewModel: viewModel,
                  ),
                  _TaskActionsMenu(
                    enabled: !state.isCommandPending,
                    canDuplicate: state.canDuplicate,
                    taskId: task.id,
                    viewModel: viewModel,
                  ),
                  if (state.duplicated case final copy?)
                    _DuplicatedConfirmation(copy: copy, viewModel: viewModel),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhoneDetails(
    BuildContext context,
    TaskDetailState state,
    TaskContentFields content,
    List<CachedTask> alternateParents,
  ) {
    final task = state.task;
    final completed = task.status == TaskStatus.completed;
    final dueText = _phoneDueText(context, state.effectiveDue, viewModel.today);
    return Column(
      children: <Widget>[
        AppBar(
          primary: false,
          centerTitle: false,
          title: Text(state.parent == null ? 'Task details' : 'Subtask'),
          leading: IconButton(
            tooltip: state.parent == null
                ? 'Back to task collection'
                : 'Back to parent task',
            onPressed: viewModel.back,
            icon: const Icon(Icons.arrow_back),
          ),
          actions: <Widget>[
            _PhoneTaskActions(
              state: state,
              viewModel: viewModel,
              alternateParents: alternateParents,
            ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            key: const Key('task-detail-scroll-view'),
            primary: false,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    IconButton(
                      key: const Key('task-detail-completion-action'),
                      tooltip: completed
                          ? 'Reopen selected task'
                          : 'Complete selected task',
                      onPressed: state.isCommandPending
                          ? null
                          : () =>
                                unawaited(viewModel.toggleCompletion(task.id)),
                      icon: Icon(
                        completed
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: content.title),
                  ],
                ),
                if (state.failureMessage case final message?)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                _DateShortcutMenu(
                  enabled: !state.isCommandPending,
                  task: task,
                  viewModel: viewModel,
                  phoneLabel: dueText.title,
                  phoneSubtitle: dueText.subtitle,
                ),
                if (state.dueChangeUndo case final undo?)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: <Widget>[
                      Text(
                        'Date changed for ${undo.cascadedCount + 1} related tasks',
                      ),
                      TextButton(
                        onPressed: state.isCommandPending
                            ? null
                            : () => unawaited(
                                viewModel.undoDueChange(undo.groupId),
                              ),
                        child: const Text('Undo due changes'),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.notes_outlined),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: content.notes),
                  ],
                ),
                const SizedBox(height: 8),
                if (state.canCreateSubtask || state.children.isNotEmpty)
                  _InspectorSection(
                    title: 'Subtasks',
                    trailing: state.canCreateSubtask
                        ? TextButton.icon(
                            onPressed: state.isCommandPending
                                ? null
                                : () => _showCreateSubtaskDialog(
                                    context,
                                    viewModel,
                                  ),
                            icon: const Icon(Icons.add, size: 20),
                            label: const Text('Add subtask'),
                          )
                        : null,
                    child: state.children.isEmpty
                        ? const SizedBox.shrink()
                        : _SubtasksBody(
                            key: ValueKey<TaskId>(task.id),
                            viewModel: viewModel,
                            progress: state.progress,
                            children: state.children,
                          ),
                  ),
                const SizedBox(height: 16),
                ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('Google Tasks'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: <Widget>[
                    TaskLinksSection(task: task, viewModel: viewModel),
                  ],
                ),
                if (state.duplicated case final copy?)
                  _DuplicatedConfirmation(copy: copy, viewModel: viewModel),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

enum _PhoneTaskAction {
  edit,
  moveToList,
  moveUp,
  moveDown,
  makeSubtask,
  promote,
  changeParent,
  duplicate,
  previous,
  next,
  delete,
}

/// A route-backed Material menu gives Android Back the expected behavior:
/// dismiss the menu first, then leave details on a subsequent Back.
final class _PhoneTaskActions extends StatelessWidget {
  const _PhoneTaskActions({
    required this.state,
    required this.viewModel,
    required this.alternateParents,
  });
  final TaskDetailState state;
  final TaskDetailViewModel viewModel;
  final List<CachedTask> alternateParents;

  @override
  Widget build(BuildContext context) {
    final task = state.task;
    final enabled = !state.isCommandPending;
    PopupMenuItem<_PhoneTaskAction> item(
      _PhoneTaskAction action,
      String label,
      IconData icon, {
      Key? key,
      bool? available,
    }) => PopupMenuItem<_PhoneTaskAction>(
      key: key,
      value: action,
      enabled: available ?? enabled,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 24),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              style: action == _PhoneTaskAction.delete
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
          ),
        ],
      ),
    );
    return PopupMenuButton<_PhoneTaskAction>(
      key: const Key('task-detail-actions-menu'),
      tooltip: 'Task actions',
      position: PopupMenuPosition.under,
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        switch (action) {
          case _PhoneTaskAction.edit:
            unawaited(showTaskContentDialog(context, viewModel, task));
          case _PhoneTaskAction.moveToList:
            unawaited(
              showTaskMoveListDialog(
                context,
                viewModel,
                task,
                state.destinationLists,
              ),
            );
          case _PhoneTaskAction.moveUp:
            unawaited(viewModel.moveSelectedUp());
          case _PhoneTaskAction.moveDown:
            unawaited(viewModel.moveSelectedDown());
          case _PhoneTaskAction.makeSubtask:
            unawaited(
              _showParentDialog(
                context,
                viewModel,
                task,
                state.parentCandidates,
              ),
            );
          case _PhoneTaskAction.promote:
            unawaited(viewModel.promote(task.id));
          case _PhoneTaskAction.changeParent:
            unawaited(
              _showParentDialog(context, viewModel, task, alternateParents),
            );
          case _PhoneTaskAction.duplicate:
            unawaited(viewModel.duplicate(task.id));
          case _PhoneTaskAction.previous:
            viewModel.selectPrevious();
          case _PhoneTaskAction.next:
            viewModel.selectNext();
          case _PhoneTaskAction.delete:
            unawaited(viewModel.deleteTask(task.id));
        }
      },
      itemBuilder: (_) => <PopupMenuEntry<_PhoneTaskAction>>[
        item(_PhoneTaskAction.edit, 'Edit task', Icons.edit_outlined),
        if (state.destinationLists.isNotEmpty)
          item(
            _PhoneTaskAction.moveToList,
            'Move to list',
            Icons.drive_file_move_outline,
          ),
        if (state.siblingIndex > 0)
          item(_PhoneTaskAction.moveUp, 'Move up', Icons.arrow_upward),
        if (state.siblingIndex >= 0 &&
            state.siblingIndex < state.siblings.length - 1)
          item(_PhoneTaskAction.moveDown, 'Move down', Icons.arrow_downward),
        if (task.parentTaskId == null &&
            !state.hasChildren &&
            state.parentCandidates.isNotEmpty)
          item(
            _PhoneTaskAction.makeSubtask,
            'Make subtask',
            Icons.subdirectory_arrow_right,
          ),
        if (task.parentTaskId != null)
          item(
            _PhoneTaskAction.promote,
            'Promote to task',
            Icons.subdirectory_arrow_left,
          ),
        if (task.parentTaskId != null && alternateParents.isNotEmpty)
          item(
            _PhoneTaskAction.changeParent,
            'Change parent',
            Icons.account_tree_outlined,
          ),
        if (state.canDuplicate)
          item(
            _PhoneTaskAction.duplicate,
            'Duplicate task',
            Icons.content_copy_outlined,
            key: const Key('task-detail-duplicate'),
          ),
        const PopupMenuDivider(),
        item(
          _PhoneTaskAction.previous,
          'Previous task',
          Icons.chevron_left,
          key: const Key('task-detail-previous'),
          available: state.previousTaskId != null,
        ),
        item(
          _PhoneTaskAction.next,
          'Next task',
          Icons.chevron_right,
          key: const Key('task-detail-next'),
          available: state.nextTaskId != null,
        ),
        const PopupMenuDivider(),
        item(_PhoneTaskAction.delete, 'Delete task', Icons.delete_outline),
      ],
    );
  }
}

final class _InspectorSection extends StatelessWidget {
  const _InspectorSection({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            ?trailing,
          ],
        ),
        const SizedBox(height: 4),
        child,
      ],
    ),
  );
}

final class _TaskStructureMenu extends StatelessWidget {
  const _TaskStructureMenu({
    required this.enabled,
    required this.task,
    required this.hasChildren,
    required this.parents,
    required this.alternateParents,
    required this.viewModel,
  });

  final bool enabled;
  final CachedTask task;
  final bool hasChildren;
  final List<CachedTask> parents;
  final List<CachedTask> alternateParents;
  final TaskDetailViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final canMakeSubtask =
        task.parentTaskId == null && !hasChildren && parents.isNotEmpty;
    final canPromote = task.parentTaskId != null;
    final canChangeParent = canPromote && alternateParents.isNotEmpty;
    if (!canMakeSubtask && !canPromote && !canChangeParent) {
      return const SizedBox.shrink();
    }
    return MenuAnchor(
      menuChildren: <Widget>[
        if (canMakeSubtask)
          MenuItemButton(
            onPressed: enabled
                ? () => _showParentDialog(context, viewModel, task, parents)
                : null,
            child: const Text('Make subtask'),
          ),
        if (canPromote)
          MenuItemButton(
            onPressed: enabled
                ? () => unawaited(viewModel.promote(task.id))
                : null,
            child: const Text('Promote to task'),
          ),
        if (canChangeParent)
          MenuItemButton(
            onPressed: enabled
                ? () => _showParentDialog(
                    context,
                    viewModel,
                    task,
                    alternateParents,
                  )
                : null,
            child: const Text('Change parent'),
          ),
      ],
      builder: (context, controller, _) => OutlinedButton.icon(
        key: const Key('task-detail-structure-menu'),
        onPressed: enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
        icon: const Icon(Icons.account_tree_outlined),
        label: const Text('Structure'),
      ),
    );
  }
}

final class _TaskActionsMenu extends StatelessWidget {
  const _TaskActionsMenu({
    required this.enabled,
    required this.canDuplicate,
    required this.taskId,
    required this.viewModel,
  });

  final bool enabled;
  final bool canDuplicate;
  final TaskId taskId;
  final TaskDetailViewModel viewModel;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: <Widget>[
      if (canDuplicate)
        MenuItemButton(
          key: const Key('task-detail-duplicate'),
          onPressed: enabled
              ? () => unawaited(viewModel.duplicate(taskId))
              : null,
          leadingIcon: const Icon(Icons.content_copy_outlined),
          child: const Text('Duplicate task'),
        ),
      const MenuItemButton(onPressed: null, child: Text('Destructive actions')),
      MenuItemButton(
        onPressed: enabled
            ? () => unawaited(viewModel.deleteTask(taskId))
            : null,
        leadingIcon: const Icon(Icons.delete_outline),
        child: const Text('Delete task'),
      ),
    ],
    builder: (context, controller, _) => OutlinedButton.icon(
      key: const Key('task-detail-actions-menu'),
      onPressed: enabled
          ? () => controller.isOpen ? controller.close() : controller.open()
          : null,
      icon: const Icon(Icons.more_horiz),
      label: const Text('More actions'),
    ),
  );
}

/// Confirms a committed Duplicate. The source stays open, so this is what
/// says the copy exists, and it leads to the copy.
final class _DuplicatedConfirmation extends StatelessWidget {
  const _DuplicatedConfirmation({required this.copy, required this.viewModel});

  final TaskDuplicateReceipt copy;
  final TaskDetailViewModel viewModel;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    child: Wrap(
      key: const Key('task-detail-duplicated'),
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: <Widget>[
        Text('Duplicated as “${copy.title}”'),
        TextButton(
          key: const Key('task-detail-open-duplicate'),
          onPressed: () => viewModel.select(copy.taskId),
          child: const Text('Open copy'),
        ),
      ],
    ),
  );
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
        Text(
          googleTaskLink == null
              ? 'Google has not provided a usable link for this task yet.'
              : 'Open Google Tasks for unavailable features, including recurrence.',
        ),
        const SizedBox(height: 4),
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
          const SizedBox(height: 8),
          Text(
            'Links in task content',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 2),
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

enum _PhoneDateAction {
  today(DateShortcut.today, 'Today'),
  tomorrow(DateShortcut.tomorrow, 'Tomorrow'),
  nextWeek(DateShortcut.nextWeek, 'Next week'),
  nextMonth(DateShortcut.nextMonth, 'Next month'),
  clear(DateShortcut.clear, 'Clear date'),
  calendar(null, 'Choose date');

  const _PhoneDateAction(this.shortcut, this.label);
  final DateShortcut? shortcut;
  final String label;
}

final class _DateShortcutMenu extends StatelessWidget {
  const _DateShortcutMenu({
    required this.enabled,
    required this.task,
    required this.viewModel,
    this.phoneLabel,
    this.phoneSubtitle,
  });

  final bool enabled;
  final CachedTask task;
  final TaskDetailViewModel viewModel;
  final String? phoneLabel;
  final String? phoneSubtitle;

  @override
  Widget build(BuildContext context) {
    if (phoneLabel != null) {
      return PopupMenuButton<_PhoneDateAction>(
        key: const Key('task-detail-due-action'),
        tooltip: 'Change due date',
        enabled: enabled,
        position: PopupMenuPosition.under,
        onSelected: (action) {
          if (action.shortcut case final shortcut?) {
            unawaited(viewModel.setDueShortcut(task.id, shortcut));
          } else {
            unawaited(showTaskDateDialog(context, viewModel, task));
          }
        },
        itemBuilder: (_) => <PopupMenuEntry<_PhoneDateAction>>[
          for (final action in _PhoneDateAction.values)
            PopupMenuItem(value: action, child: Text(action.label)),
        ],
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: const Icon(Icons.event_outlined),
          title: Text(phoneLabel!),
          subtitle: phoneSubtitle == null ? null : Text(phoneSubtitle!),
          trailing: const Icon(Icons.chevron_right),
        ),
      );
    }
    return MenuAnchor(
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
                ? () => unawaited(viewModel.setDueShortcut(task.id, entry.$1))
                : null,
            child: Text(entry.$2),
          ),
        MenuItemButton(
          onPressed: enabled
              ? () => showTaskDateDialog(context, viewModel, task)
              : null,
          child: const Text('Choose date'),
        ),
      ],
      builder: (context, controller, _) => OutlinedButton.icon(
        key: const Key('task-detail-due-action'),
        onPressed: enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
        icon: const Icon(Icons.event_outlined),
        label: const Text('Change due date'),
      ),
    );
  }
}

/// The progress summary and subtask list of the details pane. Whether
/// completed subtasks start folded away follows the persistent "Collapse
/// completed subtasks" setting; a toggle shows and hides them for this task.
final class _SubtasksBody extends StatefulWidget {
  const _SubtasksBody({
    required this.viewModel,
    required this.progress,
    required this.children,
    super.key,
  });

  final TaskDetailViewModel viewModel;
  final DirectChildProgress progress;
  final List<CachedTask> children;

  @override
  State<_SubtasksBody> createState() => _SubtasksBodyState();
}

final class _SubtasksBodyState extends State<_SubtasksBody> {
  /// The user's choice for this task while it is open; `null` follows the
  /// persistent "Collapse completed subtasks" setting.
  bool? _showCompletedOverride;

  @override
  Widget build(BuildContext context) {
    final collapse = DevicePreferencesScope.of(context)
        .collapseCompletedSubtasks;
    final showCompleted = _showCompletedOverride ?? !collapse;
    final completedCount = widget.children
        .where((child) => child.status == TaskStatus.completed)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SubtaskProgressIndicator(progress: widget.progress),
        if (completedCount > 0)
          TextButton.icon(
            key: const Key('toggle-completed-subtasks'),
            onPressed: () =>
                setState(() => _showCompletedOverride = !showCompleted),
            icon: Icon(
              showCompleted ? Icons.visibility_off : Icons.visibility,
              size: 18,
            ),
            label: Text(
              showCompleted
                  ? 'Hide completed subtasks'
                  : 'Show $completedCount completed '
                        '${completedCount == 1 ? 'subtask' : 'subtasks'}',
            ),
          ),
        const SizedBox(height: 4),
        SubtaskList(
          viewModel: widget.viewModel,
          children: widget.children,
          showCompleted: showCompleted,
        ),
      ],
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
        Text(progress.label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
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
    this.showCompleted = true,
    super.key,
  });

  final TaskDetailViewModel viewModel;

  /// All direct children in stored order, including hidden completed ones, so
  /// a subtask's position and reorder options do not depend on what is shown.
  final List<CachedTask> children;

  /// Whether completed subtasks are listed.
  final bool showCompleted;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      for (final (index, child) in children.indexed)
        if (showCompleted || child.status != TaskStatus.completed)
          TaskSwipeActions(
            key: ValueKey<String>('subtask-${child.id.value}'),
            enabled: viewModel.state?.isCommandPending != true,
            onComplete: child.status == TaskStatus.completed
                ? null
                : () => unawaited(viewModel.complete(child.id)),
            onSchedule: () =>
                unawaited(scheduleTaskFromSwipe(context, viewModel, child)),
            child: _reorderableSubtask(context, index, child),
          ),
    ],
  );

  Widget _reorderableSubtask(
    BuildContext context,
    int index,
    CachedTask child,
  ) {
    if (!viewModel.canReorderChildren ||
        Theme.of(context).platform != TargetPlatform.android ||
        MediaQuery.sizeOf(context).width >= 1024) {
      return _subtaskTile(context, index, child);
    }
    var dropAfter = false;
    return StatefulBuilder(
      builder: (targetContext, setDropState) => DragTarget<TaskId>(
        onWillAcceptWithDetails: (details) =>
            details.data != child.id &&
            children.any((t) => t.id == details.data),
        onMove: (details) {
          final box = targetContext.findRenderObject()! as RenderBox;
          final after =
              box.globalToLocal(details.offset).dy >= box.size.height / 2;
          if (after != dropAfter) setDropState(() => dropAfter = after);
        },
        onAcceptWithDetails: (details) {
          final box = targetContext.findRenderObject()! as RenderBox;
          final after =
              box.globalToLocal(details.offset).dy >= box.size.height / 2;
          unawaited(
            viewModel.reorderChild(details.data, child.id, after: after),
          );
        },
        builder: (context, candidates, _) => DecoratedBox(
          decoration: BoxDecoration(
            border: candidates.isEmpty
                ? null
                : Border(
                    top: dropAfter
                        ? BorderSide.none
                        : BorderSide(
                            width: 2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    bottom: dropAfter
                        ? BorderSide(
                            width: 2,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : BorderSide.none,
                  ),
          ),
          child: LongPressDraggable<TaskId>(
            key: Key('touch-reorder-${child.id.value}'),
            data: child.id,
            onDragUpdate: (details) {
              final scrollable = Scrollable.maybeOf(context);
              final box = scrollable?.context.findRenderObject();
              if (scrollable == null || box is! RenderBox) return;
              final y = box.globalToLocal(details.globalPosition).dy;
              final delta = y < 48
                  ? -32.0
                  : y > box.size.height - 48
                  ? 32.0
                  : 0.0;
              final position = scrollable.position;
              if (delta != 0) {
                position.jumpTo(
                  (position.pixels + delta).clamp(
                    position.minScrollExtent,
                    position.maxScrollExtent,
                  ),
                );
              }
            },
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: Material(
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(child.title),
              ),
            ),
            child: _subtaskTile(context, index, child),
          ),
        ),
      ),
    );
  }

  Widget _subtaskTile(BuildContext context, int index, CachedTask child) =>
      ListTile(
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
      );
}

/// Opens quick scheduling for the swiped [task] and applies the choice to
/// that task only, through the shared date shortcut and due-change commands
/// (so the due cascade and its Undo behave as for every other date edit).
/// Dismissing the sheet changes nothing.
Future<void> scheduleTaskFromSwipe(
  BuildContext context,
  TaskDetailViewModel viewModel,
  CachedTask task,
) async {
  final action = await showQuickDateSheet(context, taskTitle: task.title);
  if (action == null) return;
  if (action.shortcut case final shortcut?) {
    await viewModel.setDueShortcut(task.id, shortcut);
    return;
  }
  if (!context.mounted) return;
  await showTaskDateDialog(
    context,
    viewModel,
    viewModel.taskById(task.id) ?? task,
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
  // Unsaved inline text (for example after a failed autosave) is what the
  // user last typed, so the dialog starts from it rather than from the store.
  late final _draft = widget.viewModel.contentAutosave.draft(widget.task.id);
  late final _title = TextEditingController(
    text: _draft?.title ?? widget.task.title,
  );
  late final _notes = TextEditingController(
    text: _draft?.notes ?? widget.task.notes ?? '',
  );
  late bool _clearNotes = switch (_draft) {
    null => widget.task.notes == null,
    final draft => draft.notes.isEmpty && widget.task.notes != '',
  };

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
      scrollable: true,
      insetPadding: MediaQuery.viewInsetsOf(context).bottom > 0
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
          : null,
      actionsPadding: MediaQuery.viewInsetsOf(context).bottom > 0
          ? const EdgeInsets.fromLTRB(16, 0, 16, 8)
          : null,
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

/// Opens date selection for [task]: a calendar on touch platforms (as
/// v1.5.3 did on phones) and the typed date dialog on desktop platforms.
/// Either applies the result through the shared due command.
Future<void> showTaskDateDialog(
  BuildContext context,
  TaskDetailViewModel viewModel,
  CachedTask task,
) {
  final calendar = calendarDatePlatforms.contains(Theme.of(context).platform);
  return showAppDialog<void>(
    context: context,
    kind: AppDialogKind.date,
    builder: (_) => calendar
        ? TaskCalendarDateDialog(viewModel: viewModel, task: task)
        : _TaskDateDialog(viewModel: viewModel, task: task),
  );
}

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
    if (mounted && widget.viewModel.commandFailureMessage == null) {
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
        onSubmitted: widget.viewModel.isCommandPending
            ? null
            : (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: widget.viewModel.isCommandPending
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.viewModel.isCommandPending ? null : _submit,
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

({String title, String? subtitle}) _phoneDueText(
  BuildContext context,
  EffectiveDue due,
  TaskDate today,
) {
  final effective = due.effective;
  if (effective == null) return (title: 'Add date', subtitle: null);
  String label(TaskDate date) {
    if (date == today) return 'Today';
    if (date == addTaskDateDays(today, 1)) return 'Tomorrow';
    final value = MaterialLocalizations.of(context)
        .formatMediumDate(DateTime.utc(date.year, date.month, date.day));
    return date.year == today.year ? value : '$value, ${date.year}';
  }

  return (
    title: label(effective),
    subtitle: due.explicit == null
        ? 'From subtasks'
        : compareTaskDates(effective, due.explicit!) < 0
        ? 'From subtasks · Task date ${label(due.explicit!)}'
        : null,
  );
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

String _statusLabel(TaskStatus status) => switch (status) {
  TaskStatus.needsAction => 'Not completed',
  TaskStatus.completed => 'Completed',
};
