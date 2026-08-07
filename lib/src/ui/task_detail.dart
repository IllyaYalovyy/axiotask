// The task detail panel — the SKELETON of the fresh TaskDetail contract (T2.4).
// It is the ONLY home of subtasks (invariant #1): the list never renders a
// subtask as a row, and a subtask's own panel offers no way to add another
// (the two-level guard, [canAddSubtask]).
//
// What is real here: the title and notes fields auto-save on blur/close,
// diff-only (an untouched field never queues a write); subtasks render as a
// checklist whose checkboxes toggle completion and whose titles open their own
// panel; an inline "Add a subtask" input creates a named child under the parent
// and KEEPS focus for rapid entry; and Delete removes the task with an Undo
// affordance. Live-tracking updates a field from the store WITHOUT clobbering
// what the user is typing (only an unfocused field is refreshed).
//
// Deferred to T7.4 (full detail): prev/next sibling navigation, the date
// picker + per-subtask dates, hide-completed / un-complete-all, drag reorder,
// detach, list dropdown, and the empty-subtask discard-on-close rule. The undo
// toast/stack proper is T7.8; the SnackBar here is the minimal honest home for
// the undo command until then.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../model/task.dart';
import '../model/task_tree.dart';
import '../store/stored.dart';
import 'date_format.dart';

/// The detail/edit panel for one task, identified by [taskId].
class TaskDetail extends ConsumerStatefulWidget {
  const TaskDetail({
    required this.taskId,
    required this.onClose,
    required this.onOpenTask,
    super.key,
  });

  /// The task this panel shows.
  final String taskId;

  /// Close the panel (also called after the task is deleted).
  final VoidCallback onClose;

  /// Open another task's panel (a subtask title tap; the panel follows it).
  final ValueChanged<String> onOpenTask;

  @override
  ConsumerState<TaskDetail> createState() => _TaskDetailState();
}

class _TaskDetailState extends ConsumerState<TaskDetail> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  final TextEditingController _newSubtask = TextEditingController();
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _notesFocus = FocusNode();
  final FocusNode _newSubtaskFocus = FocusNode();

  // The task id the controllers were last loaded for, so switching the panel to
  // a different task re-seeds the fields (rather than clobbering across tasks).
  String? _loadedId;

  // The most recent task snapshot, so the focus-loss savers can diff against the
  // persisted values without re-reading the provider off the widget tree.
  StoredTask? _current;

  @override
  void initState() {
    super.initState();
    // Auto-save on blur, diff-only (see [_saveTitle] / [_saveNotes]).
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus) _saveTitle();
    });
    _notesFocus.addListener(() {
      if (!_notesFocus.hasFocus) _saveNotes();
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _newSubtask.dispose();
    _titleFocus.dispose();
    _notesFocus.dispose();
    _newSubtaskFocus.dispose();
    super.dispose();
  }

  /// Seed the fields from [task], or refresh an UNFOCUSED field when the store
  /// changed it out from under us (live-tracking without clobbering typing).
  void _sync(Task task) {
    if (task.id != _loadedId) {
      _loadedId = task.id;
      _title.text = task.title;
      _notes.text = task.notes ?? '';
      return;
    }
    if (!_titleFocus.hasFocus && _title.text != task.title) {
      _title.text = task.title;
    }
    final notes = task.notes ?? '';
    if (!_notesFocus.hasFocus && _notes.text != notes) _notes.text = notes;
  }

  void _saveTitle() {
    final task = _current?.task;
    if (task == null) return;
    final value = _title.text.trim();
    // Diff-only: an unchanged (or empty) title never queues a write. The
    // empty-⇒-delete inline-rename rule lives on the row (T7.2), not here.
    if (value.isEmpty || value == task.title) return;
    ref.read(commandsProvider).renameTask(task.id, value);
  }

  void _saveNotes() {
    final task = _current?.task;
    if (task == null) return;
    final value = _notes.text;
    if (value == (task.notes ?? '')) return; // diff-only
    ref.read(commandsProvider).setNotes(task.id, value);
  }

  Future<void> _addSubtask(StoredTask parent) async {
    final title = _newSubtask.text.trim();
    if (title.isEmpty) return; // an empty add creates nothing
    await ref
        .read(commandsProvider)
        .createTask(
          listId: parent.listId,
          parentId: parent.task.id,
          title: title,
        );
    if (!mounted) return;
    _newSubtask.clear();
    // Keep focus for rapid successive entry.
    _newSubtaskFocus.requestFocus();
  }

  Future<void> _delete(StoredTask task) async {
    // Flush any pending field edits before the row goes away.
    _saveTitle();
    _saveNotes();
    final commands = ref.read(commandsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final token = await commands.deleteTask(task.task.id);
    if (!mounted) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted "${task.task.title}"'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => commands.undoDelete(token),
          ),
        ),
      );
    widget.onClose();
  }

  void _close() {
    _saveTitle();
    _saveNotes();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final all =
        ref.watch(allTasksProvider).asData?.value ?? const <StoredTask>[];
    final matches = all.where((t) => t.task.id == widget.taskId);
    final current = matches.isEmpty ? null : matches.first;
    _current = current;

    if (current == null) {
      // The task was deleted (or never existed) — the panel reacts rather than
      // stranding a stale row.
      return _MissingTask(onClose: widget.onClose);
    }
    _sync(current.task);

    final task = current.task;
    final subtask = isSubtask(task);
    final children = all.where((t) => t.task.parent == task.id).toList()
      ..sort((a, b) => a.task.position.compareTo(b.task.position));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: _close,
          ),
          title: Text(subtask ? 'Subtask' : 'Task Details'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: () => _delete(current),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _title,
                focusNode: _titleFocus,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _saveTitle(),
              ),
              const SizedBox(height: 16),
              _DueRow(due: task.due),
              const SizedBox(height: 16),
              TextField(
                controller: _notes,
                focusNode: _notesFocus,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              // Subtasks are top-level tasks' business only — a subtask's panel
              // shows no checklist and no add input (invariant #1).
              if (!subtask) ...[
                const SizedBox(height: 24),
                Text('Subtasks', style: Theme.of(context).textTheme.titleSmall),
                for (final c in children)
                  _SubtaskRow(
                    key: ValueKey(c.task.id),
                    task: c.task,
                    onToggle: () =>
                        ref.read(commandsProvider).toggleComplete(c.task.id),
                    onOpen: () => widget.onOpenTask(c.task.id),
                  ),
                _AddSubtaskField(
                  controller: _newSubtask,
                  focusNode: _newSubtaskFocus,
                  onSubmit: () => _addSubtask(current),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The read-only due display (the date PICKER is T5.1/T7.4).
class _DueRow extends StatelessWidget {
  const _DueRow({required this.due});

  final String? due;

  @override
  Widget build(BuildContext context) {
    final label = formatDue(due);
    return Row(
      children: [
        const Icon(Icons.event_outlined, size: 20),
        const SizedBox(width: 8),
        Text(
          label.isEmpty ? 'No date' : label,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

/// One subtask checklist row: a real checkbox toggles completion, the title
/// opens the subtask's own panel.
class _SubtaskRow extends StatelessWidget {
  const _SubtaskRow({
    required this.task,
    required this.onToggle,
    required this.onOpen,
    super.key,
  });

  final Task task;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.completed;
    return Row(
      children: [
        // 48dp hit area (the glyph stays default-sized — enlarge the target,
        // never the checkbox, #167).
        SizedBox(
          width: 48,
          height: 48,
          child: Checkbox(value: done, onChanged: (_) => onToggle()),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                task.title.isEmpty ? 'Untitled' : task.title,
                style: TextStyle(
                  decoration: done ? TextDecoration.lineThrough : null,
                  color: done ? Theme.of(context).disabledColor : null,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The inline "Add a subtask" input — Enter or the + button creates the child
/// and the caller keeps focus for rapid entry.
class _AddSubtaskField extends StatelessWidget {
  const _AddSubtaskField({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: const InputDecoration(
                hintText: 'Add a subtask',
                isDense: true,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add subtask',
            onPressed: onSubmit,
          ),
        ],
      ),
    );
  }
}

/// Shown when the panel's task is gone (deleted or never existed).
class _MissingTask extends StatelessWidget {
  const _MissingTask({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: onClose,
          ),
          title: const Text('Details'),
        ),
        const Expanded(
          child: Center(child: Text('This task is no longer available.')),
        ),
      ],
    );
  }
}
