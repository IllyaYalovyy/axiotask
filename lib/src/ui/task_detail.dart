// The task detail panel — the ONLY home of subtasks (invariant #1): the list
// never renders a subtask as a row, and a subtask's own panel offers no way to
// add another (the two-level guard, [canAddSubtask]).
//
// Beyond the T2.4 skeleton (title/notes auto-save, add/toggle subtask, delete),
// this is the complete T7.4 surface:
//   • prev/next sibling navigation across the current view (flush edits first).
//   • the task's own due date: a tappable badge opening the calendar plus the
//     one-gesture quick-date strip, with the #164 cascade toast.
//   • per-subtask due dates, edited inline from the parent's checklist.
//   • "Hide completed" subtasks — a persisted, count-gated toggle that is UX
//     only (never mutates the tasks).
//   • "Un-complete all subtasks" (#89) — reopen a parent's finished children in
//     one action (un-completing never cascades on its own).
//   • hidden-aware subtask reorder via up/down buttons — steps are measured
//     against the FULL sibling list so a move stays correct across a hidden
//     completed row (#90).
//   • detach (#promoteTask): a subtask's panel can promote it back to top level.
//   • the List dropdown, shown for top-level tasks only — a subtask always
//     lives in its parent's list (#93). Moving lists repoints the panel to the
//     recreated row.
//   • clickable links detected in the title/notes.
//   • the empty-subtask discard-on-close rule: closing an untitled, dateless,
//     childless subtask left untouched removes it — but NEVER one with children
//     of its own (that would silently take the subtree, with no undo).
//
// Live-tracking updates a field from the store WITHOUT clobbering what the user
// is typing (only an unfocused field is refreshed). The undo toast/stack proper
// is T7.8; the SnackBars here are the minimal honest home until then.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../model/dates.dart' show DateMove;
import '../model/task.dart';
import '../model/task_tree.dart';
import '../store/stored.dart';
import 'date_format.dart';
import 'due_date_picker.dart';
import 'url_detect.dart';
import 'url_opener.dart';

/// The detail/edit panel for one task, identified by [taskId].
class TaskDetail extends ConsumerStatefulWidget {
  const TaskDetail({
    required this.taskId,
    required this.onClose,
    required this.onOpenTask,
    this.onPrev,
    this.onNext,
    this.autofocusNotes = false,
    super.key,
  });

  /// The task this panel shows.
  final String taskId;

  /// Focus the Notes field once the panel loads (the context menu's
  /// "Edit notes"); a one-shot honored on the first load of [taskId].
  final bool autofocusNotes;

  /// Close the panel (also called after the task is deleted).
  final VoidCallback onClose;

  /// Open another task's panel (a subtask title tap, a detach, a list move, or
  /// the breadcrumb up to a parent). The panel follows it.
  final ValueChanged<String> onOpenTask;

  /// Navigate to the previous / next sibling in the current view; `null`
  /// disables that direction (a boundary, or a subtask with no list ordering).
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

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
      final firstEver = _loadedId == null;
      _loadedId = task.id;
      _title.text = task.title;
      _notes.text = task.notes ?? '';
      // Honor an "Edit notes" request once, on this task's first load.
      if (firstEver && widget.autofocusNotes) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _notesFocus.requestFocus();
        });
      }
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
    // empty-⇒-delete inline-rename rule lives on the row (T7.2), not here; the
    // empty-subtask discard rule handles abandonment on close.
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

  /// Flush edits, then discard the task if it is an abandoned empty subtask.
  /// Everything that leaves this panel (close, prev/next, breadcrumb, opening a
  /// subtask) funnels through here so a blank subtask never lingers — yet one
  /// with children of its own is always kept.
  void _flushAndDiscard() {
    _saveTitle();
    _saveNotes();
    _discardIfEmptySubtask();
  }

  /// The #DetailWorkflow rule: an untitled, note-less, dateless SUBTASK left
  /// open (not completed) and WITHOUT children of its own is debris — remove it.
  /// A subtask with children is never touched: deleting it cascades the whole
  /// subtree away, silently and with no undo token.
  void _discardIfEmptySubtask() {
    final all =
        ref.read(allTasksProvider).asData?.value ?? const <StoredTask>[];
    final t = _current?.task;
    if (t == null) return;
    final empty =
        t.parent != null &&
        t.status != TaskStatus.completed &&
        t.title.trim().isEmpty &&
        (t.notes ?? '').trim().isEmpty &&
        (t.due ?? '').isEmpty &&
        !all.any((c) => c.task.parent == t.id);
    if (empty) ref.read(commandsProvider).deleteTask(t.id);
  }

  void _close() {
    _flushAndDiscard();
    widget.onClose();
  }

  void _navigate(VoidCallback go) {
    _flushAndDiscard();
    go();
  }

  /// Set the task's OWN due date from a one-gesture quick move, surfacing any
  /// #164 cascade as an undoable toast.
  Future<void> _quickDue(String id, DateMove move) async {
    final messenger = ScaffoldMessenger.of(context);
    final commands = ref.read(commandsProvider);
    final res = await commands.setDue(id, move);
    if (!mounted) return;
    offerDueCascadeUndo(messenger, commands, res);
  }

  /// Open the calendar for [id] on [currentDue] and apply the choice (a picked
  /// day via `setDueRaw`, Clear via `setDue`), then surface any #164 cascade.
  /// A dismissed picker leaves the date untouched. Shared by the task's own due
  /// badge and each subtask's inline due button.
  Future<void> _pickDue(String id, String? currentDue) async {
    final messenger = ScaffoldMessenger.of(context);
    final commands = ref.read(commandsProvider);
    final pick = await showDueDatePicker(context, initial: currentDue);
    if (pick == null || !mounted) return;
    final res = switch (pick) {
      DuePickClear() => await commands.setDue(id, DateMove.clear),
      DuePickDate(:final ymd) => await commands.setDueRaw(id, ymd),
    };
    if (!mounted) return;
    offerDueCascadeUndo(messenger, commands, res);
  }

  /// Reopen every completed subtask of [parentId] (#89). Un-completing a parent
  /// never cascades to its children, so this is the explicit "reopen the whole
  /// checklist" action.
  Future<void> _uncompleteAll(String parentId, List<StoredTask> all) async {
    final commands = ref.read(commandsProvider);
    for (final c in all) {
      if (c.task.parent == parentId && c.task.status == TaskStatus.completed) {
        await commands.toggleComplete(c.task.id);
      }
    }
  }

  /// Move [subId] past its nearest VISIBLE neighbor [neighborId]. The distance
  /// is measured against the FULL ordered [children] (position order), then
  /// emitted as that many single-step swaps — so a reorder stays correct across
  /// hidden completed rows when "Hide completed" is on (#90).
  Future<void> _reorderPast(
    String subId,
    String neighborId,
    List<StoredTask> children,
  ) async {
    final from = children.indexWhere((c) => c.task.id == subId);
    final to = children.indexWhere((c) => c.task.id == neighborId);
    if (from < 0 || to < 0 || from == to) return;
    final direction = to > from ? 'down' : 'up';
    final commands = ref.read(commandsProvider);
    for (var i = 0; i < (to - from).abs(); i++) {
      await commands.reorderTask(subId, direction);
    }
  }

  /// Detach [subId] from its parent, promoting it to top level directly after
  /// its former parent (#promoteTask). The row keeps its id, so the panel stays
  /// open on it — now showing the top-level affordances.
  Future<void> _detach(String subId, String parentId) async {
    _saveTitle();
    _saveNotes();
    await ref
        .read(commandsProvider)
        .moveTask(subId, parentId: null, previousId: parentId);
  }

  /// Move the top-level [id] to [targetListId]. `moveTaskToList` recreates the
  /// subtree under a fresh id and returns it, so the panel repoints there (#93
  /// only hides this affordance for subtasks — a parent may still move lists).
  /// A brief toast confirms the move, since the row otherwise just vanishes
  /// from the current view.
  Future<void> _moveList(
    String id,
    String targetListId,
    String targetTitle,
  ) async {
    final commands = ref.read(commandsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final newId = await commands.moveTaskToList(id, targetListId);
    if (!mounted) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('Moved to $targetTitle')));
    widget.onOpenTask(newId);
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
    final completedCount = children
        .where((c) => c.task.status == TaskStatus.completed)
        .length;
    final hideCompleted = ref.watch(
      prefsControllerProvider.select((p) => p.hideCompletedSubtasks),
    );
    final visibleChildren = hideCompleted
        ? children.where((c) => c.task.status != TaskStatus.completed).toList()
        : children;
    // Parent (for a subtask's breadcrumb + detach) and the lists (for a
    // top-level task's List dropdown).
    final parent = subtask
        ? all.where((t) => t.task.id == task.parent).firstOrNull
        : null;
    final lists = ref.watch(orderedListsProvider);
    final links = urlsForTask(title: task.title, notes: task.notes);

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
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous task',
              onPressed: widget.onPrev == null
                  ? null
                  : () => _navigate(widget.onPrev!),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next task',
              onPressed: widget.onNext == null
                  ? null
                  : () => _navigate(widget.onNext!),
            ),
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
              if (subtask && parent != null)
                _Breadcrumb(
                  parentTitle: parent.task.title,
                  onOpenParent: () =>
                      _navigate(() => widget.onOpenTask(parent.task.id)),
                  onDetach: () async {
                    await _detach(task.id, parent.task.id);
                  },
                ),
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
              // Google assigns the webViewLink on sync; a not-yet-synced task
              // has none, so the affordance appears only once it exists. Opens
              // the task in the Google Tasks web app (to set a repeat, etc.).
              if (task.webViewLink != null) ...[
                const SizedBox(height: 12),
                _OpenInGoogle(
                  url: task.webViewLink!,
                  onOpen: ref.read(urlOpenerProvider),
                ),
              ],
              const SizedBox(height: 16),
              _DueField(
                due: task.due,
                onPick: () => _pickDue(task.id, task.due),
                onQuick: (m) => _quickDue(task.id, m),
              ),
              if (!subtask) ...[
                const SizedBox(height: 16),
                _ListDropdown(
                  value: current.listId,
                  lists: lists,
                  onChanged: (target) => _moveList(
                    task.id,
                    target,
                    lists.firstWhere((l) => l.list.id == target).list.title,
                  ),
                ),
              ],
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
              if (links.isNotEmpty) ...[
                const SizedBox(height: 16),
                _Links(urls: links, onOpen: ref.read(urlOpenerProvider)),
              ],
              // Subtasks are top-level tasks' business only — a subtask's panel
              // shows no checklist and no add input (invariant #1).
              if (!subtask) ...[
                const SizedBox(height: 24),
                _SubtaskHeader(
                  completedCount: completedCount,
                  hideCompleted: hideCompleted,
                  onHideCompleted: (v) => ref
                      .read(prefsControllerProvider.notifier)
                      .setHideCompletedSubtasks(v),
                  onUncompleteAll: () => _uncompleteAll(task.id, all),
                ),
                for (var i = 0; i < visibleChildren.length; i++)
                  _SubtaskRow(
                    key: ValueKey(visibleChildren[i].task.id),
                    task: visibleChildren[i].task,
                    isFirst: i == 0,
                    isLast: i == visibleChildren.length - 1,
                    onToggle: () => ref
                        .read(commandsProvider)
                        .toggleComplete(visibleChildren[i].task.id),
                    onOpen: () => _navigate(
                      () => widget.onOpenTask(visibleChildren[i].task.id),
                    ),
                    onPickDue: () => _pickDue(
                      visibleChildren[i].task.id,
                      visibleChildren[i].task.due,
                    ),
                    onMoveUp: i == 0
                        ? null
                        : () => _reorderPast(
                            visibleChildren[i].task.id,
                            visibleChildren[i - 1].task.id,
                            children,
                          ),
                    onMoveDown: i == visibleChildren.length - 1
                        ? null
                        : () => _reorderPast(
                            visibleChildren[i].task.id,
                            visibleChildren[i + 1].task.id,
                            children,
                          ),
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

/// The subtask breadcrumb ("← Parent") plus the detach action, shown atop a
/// subtask's own panel.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.parentTitle,
    required this.onOpenParent,
    required this.onDetach,
  });

  final String parentTitle;
  final VoidCallback onOpenParent;
  final VoidCallback onDetach;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onOpenParent,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: Text(
                parentTitle.isEmpty ? 'Parent task' : parentTitle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(height: 4),
          OutlinedButton(
            onPressed: onDetach,
            child: const Text('Detach from parent'),
          ),
        ],
      ),
    );
  }
}

/// The task's own due date: a tappable badge that opens the calendar, plus the
/// one-gesture quick-date strip (Today / Tomorrow / +1 week / +1 month / Clear).
class _DueField extends StatelessWidget {
  const _DueField({
    required this.due,
    required this.onPick,
    required this.onQuick,
  });

  final String? due;
  final VoidCallback onPick;
  final ValueChanged<DateMove> onQuick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final has = (due ?? '').isNotEmpty;
    final label = has ? formatDue(due) : 'No date';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Due date', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          key: const Key('due-field'),
          onPressed: onPick,
          icon: const Icon(Icons.event_outlined, size: 18),
          label: Align(
            alignment: Alignment.centerLeft,
            child: Text(label.isEmpty ? 'No date' : label),
          ),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            alignment: Alignment.centerLeft,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _chip(context, 'Today', () => onQuick(DateMove.today)),
            _chip(context, 'Tomorrow', () => onQuick(DateMove.tomorrow)),
            _chip(context, '+1 week', () => onQuick(DateMove.nextWeek)),
            _chip(context, '+1 month', () => onQuick(DateMove.nextMonth)),
            if (has) _chip(context, 'Clear', () => onQuick(DateMove.clear)),
          ],
        ),
      ],
    );
  }

  Widget _chip(BuildContext context, String label, VoidCallback onTap) {
    return ActionChip(label: Text(label), onPressed: onTap);
  }
}

/// The top-level task's List dropdown — a subtask never renders this (#93).
class _ListDropdown extends StatelessWidget {
  const _ListDropdown({
    required this.value,
    required this.lists,
    required this.onChanged,
  });

  final String value;
  final List<StoredTaskList> lists;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ids = {for (final l in lists) l.list.id};
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'List',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('list-dropdown'),
          value: ids.contains(value) ? value : null,
          isExpanded: true,
          items: [
            for (final l in lists)
              DropdownMenuItem(value: l.list.id, child: Text(l.list.title)),
          ],
          onChanged: (v) {
            if (v != null && v != value) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// The "Open in Google Tasks" affordance — opens the task's webViewLink in the
/// platform browser (via the same [urlOpenerProvider] seam as the link badges).
class _OpenInGoogle extends StatelessWidget {
  const _OpenInGoogle({required this.url, required this.onOpen});

  final String url;
  final UrlOpener onOpen;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message:
            'Open this task in the Google Tasks web app (to set a '
            'repeat, etc.)',
        child: OutlinedButton.icon(
          key: const Key('open-in-google'),
          onPressed: () => onOpen(url),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('Open in Google Tasks'),
        ),
      ),
    );
  }
}

/// The clickable links found in the task's title/notes.
class _Links extends StatelessWidget {
  const _Links({required this.urls, required this.onOpen});

  final List<String> urls;
  final UrlOpener onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Links', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        for (final url in urls)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('link-$url'),
              onPressed: () => onOpen(url),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
    );
  }
}

/// The subtasks section header: the "Subtasks" label, the count-gated "Hide
/// completed" toggle, and the count-gated "Un-complete all subtasks" action.
class _SubtaskHeader extends StatelessWidget {
  const _SubtaskHeader({
    required this.completedCount,
    required this.hideCompleted,
    required this.onHideCompleted,
    required this.onUncompleteAll,
  });

  final int completedCount;
  final bool hideCompleted;
  final ValueChanged<bool> onHideCompleted;
  final VoidCallback onUncompleteAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Subtasks', style: theme.textTheme.titleSmall),
            ),
            // The toggle only exists once something can be hidden — an
            // affordance that would do nothing must not render.
            if (completedCount > 0)
              InkWell(
                onTap: () => onHideCompleted(!hideCompleted),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: hideCompleted,
                        onChanged: (v) => onHideCompleted(v ?? false),
                      ),
                      Text('Hide completed', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (completedCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onUncompleteAll,
              child: const Text('Un-complete all subtasks'),
            ),
          ),
      ],
    );
  }
}

/// One subtask checklist row: a real checkbox toggles completion, the title
/// opens the subtask's own panel, up/down buttons reorder it (hidden-aware,
/// disabled at the visible ends), and a due button edits its date inline.
class _SubtaskRow extends StatelessWidget {
  const _SubtaskRow({
    required this.task,
    required this.isFirst,
    required this.isLast,
    required this.onToggle,
    required this.onOpen,
    required this.onPickDue,
    required this.onMoveUp,
    required this.onMoveDown,
    super.key,
  });

  final Task task;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onPickDue;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = task.status == TaskStatus.completed;
    final hasDue = (task.due ?? '').isNotEmpty;
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
                  color: done ? theme.disabledColor : null,
                ),
              ),
            ),
          ),
        ),
        // Reorder buttons (the touch path; work with a mouse too). Disabled at
        // the visible boundaries.
        IconButton(
          key: Key('sub-up-${task.id}'),
          icon: const Icon(Icons.keyboard_arrow_up),
          iconSize: 20,
          tooltip: 'Move up',
          onPressed: onMoveUp,
        ),
        IconButton(
          key: Key('sub-down-${task.id}'),
          icon: const Icon(Icons.keyboard_arrow_down),
          iconSize: 20,
          tooltip: 'Move down',
          onPressed: onMoveDown,
        ),
        // The per-subtask due button. Its tooltip carries the precise ISO date
        // (stable for tests) while the visible label is the friendly form.
        Tooltip(
          message:
              'Subtask due date: ${hasDue ? task.due!.substring(0, 10) : 'No date'}',
          child: TextButton(
            key: Key('sub-due-${task.id}'),
            onPressed: onPickDue,
            child: Text(hasDue ? formatDue(task.due) : 'no date'),
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
