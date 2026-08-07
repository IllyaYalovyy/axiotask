// The "All Tasks" list on the real store — the T2.3 vertical slice. It watches
// every visible task across all lists, renders the top-level ones as [TaskRow]s
// (subtasks are never rows — invariant #1), and hosts the always-visible
// quick-add bar: a natural-language date preview, a freshly-created task pinned
// to the top, and — when the detail panel is already open — the panel following
// to the new task.
//
// Navigation is injected ([onOpenTask]) and the current selection passed in
// ([selectedTaskId]) so this widget is testable without a router; the router
// wiring lives in ViewListPane. The smart-view FILTERS (Focus/Upcoming/…),
// counts, and the show-completed toggle are T7.1 — this slice renders the "all"
// aggregate with completed tasks hidden by default.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/quick_add.dart';
import '../model/task.dart';
import '../store/stored.dart';
import 'date_format.dart';
import 'task_row.dart';
import 'views.dart';

/// The All-Tasks list plus its quick-add bar for [viewId].
class TaskListView extends ConsumerStatefulWidget {
  const TaskListView({
    required this.viewId,
    required this.selectedTaskId,
    required this.onOpenTask,
    super.key,
  });

  /// The active view id (a smart view or a list id).
  final String viewId;

  /// The task the detail panel currently shows, or `null` when it is closed —
  /// drives the "new task follows the open panel" behavior.
  final String? selectedTaskId;

  /// Open the detail panel for a task id (router-backed in the app).
  final ValueChanged<String> onOpenTask;

  @override
  ConsumerState<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends ConsumerState<TaskListView> {
  final TextEditingController _quickAdd = TextEditingController();
  final FocusNode _quickAddFocus = FocusNode();

  // Transient "pin this new task to the top" id, cleared when the view unmounts
  // on a view switch (only the "all" view mounts this widget today).
  String? _newestId;

  // The typed title whose parsed date the user chose to keep as literal text
  // (the preview chip's ×), so its phrase is not re-read as a due date.
  String _dateIgnoredFor = '';

  // The known lists, kept current by the build's watch so quick-add can resolve
  // its target synchronously at submit time.
  List<StoredTaskList> _lists = const [];

  bool get _isSmartView => SmartView.byId(widget.viewId) != null;

  /// The natural-language due parsed from the current input, unless the user
  /// dismissed it for this exact text.
  String? get _previewDue => _quickAdd.text == _dateIgnoredFor
      ? null
      : parseQuickAddDue(_quickAdd.text);

  @override
  void dispose() {
    _quickAdd.dispose();
    _quickAddFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = _quickAdd.text.trim();
    if (title.isEmpty) return; // never create an empty task

    // Resolve the date from the current input BEFORE any await (the field is
    // only cleared after the create lands).
    final explicitDue = _previewDue;
    final due =
        explicitDue ?? (_isSmartView ? quickAddDueFor(widget.viewId) : null);

    // A smart view imposes no target list, so the first list wins (the default
    // "My Tasks"); a concrete list view targets itself. [_lists] is kept current
    // by the build's watch.
    final target = _isSmartView
        ? (_lists.isEmpty ? null : _lists.first.list.id)
        : widget.viewId;
    if (target == null) return; // no list to create in

    final stored = await ref
        .read(commandsProvider)
        .createTask(listId: target, title: title, due: due);
    if (!mounted) return;
    setState(() {
      _newestId = stored.task.id;
      _quickAdd.clear();
      _dateIgnoredFor = '';
    });
    // Creating a task never opens the panel on its own; if it was already open,
    // follow it to the new task instead of leaving a stale one selected.
    if (widget.selectedTaskId != null) widget.onOpenTask(stored.task.id);
  }

  List<StoredTask> _visibleTopLevel(List<StoredTask> all, bool showCompleted) {
    final rows = all
        .where(
          (t) =>
              t.task.parent == null &&
              (showCompleted || t.task.status != TaskStatus.completed),
        )
        .toList();
    rows.sort((a, b) {
      if (a.task.id == _newestId) return -1;
      if (b.task.id == _newestId) return 1;
      return a.task.position.compareTo(b.task.position);
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final all =
        ref.watch(allTasksProvider).asData?.value ?? const <StoredTask>[];
    // Keep the lists subscribed and current so quick-add resolves its target.
    _lists = ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];
    // Honor the persisted show-completed pref (default hides completed, matching
    // the reference); the toggle UI lands in T7.1.
    final showCompleted = ref.watch(prefsProvider).showCompleted;
    final tasks = _visibleTopLevel(all, showCompleted);
    return Column(
      children: [
        _QuickAddBar(
          controller: _quickAdd,
          focusNode: _quickAddFocus,
          previewDue: _previewDue,
          onSubmit: _submit,
          onDismissPreview: () {
            setState(() => _dateIgnoredFor = _quickAdd.text);
            _quickAddFocus.requestFocus();
          },
          onChanged: () => setState(() {}),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? Center(
                  child: Text(
                    'No tasks yet',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, i) {
                    final t = tasks[i].task;
                    return TaskRow(
                      key: ValueKey(t.id),
                      title: t.title,
                      completed: t.status == TaskStatus.completed,
                      due: formatDue(t.due),
                      onOpen: () => widget.onOpenTask(t.id),
                      onToggle: () =>
                          ref.read(commandsProvider).toggleComplete(t.id),
                      onRename: (v) =>
                          ref.read(commandsProvider).renameTask(t.id, v),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// The always-visible quick-add input, its live date preview chip, and submit.
class _QuickAddBar extends StatelessWidget {
  const _QuickAddBar({
    required this.controller,
    required this.focusNode,
    required this.previewDue,
    required this.onSubmit,
    required this.onDismissPreview,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String? previewDue;
  final VoidCallback onSubmit;
  final VoidCallback onDismissPreview;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final preview = previewDue;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: const InputDecoration(
                hintText: 'Add a task',
                prefixIcon: Icon(Icons.add),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onChanged: (_) => onChanged(),
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          if (preview != null && preview.isNotEmpty) ...[
            const SizedBox(width: 8),
            // The chip renders a FRIENDLY relative date, never the raw ISO
            // (#78b); its × keeps the phrase as literal title text.
            InputChip(
              label: Text(formatDue(preview)),
              deleteIcon: const Icon(Icons.close, size: 18),
              deleteButtonTooltipMessage: 'Keep as text',
              onDeleted: onDismissPreview,
            ),
          ],
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Add task',
            icon: const Icon(Icons.arrow_upward),
            onPressed: onSubmit,
          ),
        ],
      ),
    );
  }
}
