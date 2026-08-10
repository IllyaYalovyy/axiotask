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

import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../app/quick_add.dart';
import '../model/dates.dart' show DateMove;
import '../model/effective_due.dart';
import '../model/task.dart';
import '../model/task_view.dart';
import '../store/stored.dart';
import 'date_format.dart';
import 'due_date_picker.dart';
import 'search.dart';
import 'sort_dropdown.dart';
import 'task_row.dart';
import 'url_opener.dart';
import 'views.dart';

/// The empty-state message for [viewId] — a per-view reassurance for a smart
/// view, the generic prompt for a list / All Tasks. Ports the reference's
/// per-view empty strings.
String emptyMessageFor(String viewId) => switch (viewId) {
  'focus' => 'All clear for this week',
  'upcoming' => 'Nothing upcoming',
  'missed' => 'Nothing overdue',
  'unscheduled' => 'Everything is scheduled',
  _ => 'No tasks yet',
};

/// The All-Tasks list plus its quick-add bar for [viewId].
class TaskListView extends ConsumerStatefulWidget {
  const TaskListView({
    required this.viewId,
    required this.selectedTaskId,
    required this.onOpenTask,
    this.onOpenInView,
    super.key,
  });

  /// The active view id (a smart view or a list id).
  final String viewId;

  /// The task the detail panel currently shows, or `null` when it is closed —
  /// drives the "new task follows the open panel" behavior.
  final String? selectedTaskId;

  /// Open the detail panel for a task id (router-backed in the app).
  final ValueChanged<String> onOpenTask;

  /// Open a task in a SPECIFIC view (list) — used by search to land a subtask
  /// on its parent's list (#92). When null, opening falls back to [onOpenTask]
  /// in the current view.
  final void Function(String viewId, String taskId)? onOpenInView;

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

  /// Apply a one-gesture quick-date move from the hover strip, then surface any
  /// #164 cascade as an undoable toast.
  Future<void> _quickMove(String id, DateMove move) async {
    final messenger = ScaffoldMessenger.of(context);
    final commands = ref.read(commandsProvider);
    final res = await commands.setDue(id, move);
    if (!mounted) return;
    offerDueCascadeUndo(messenger, commands, res);
  }

  /// Open the calendar for [id] on its current [currentDue], apply the choice
  /// (a picked day via `setDueRaw`, Clear via `setDue`), then surface any #164
  /// cascade. A dismissed picker leaves the date untouched.
  Future<void> _openDatePicker(String id, String? currentDue) async {
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

  /// Open the live search over EVERY task. Selecting a result navigates to it —
  /// a matched subtask lands on its parent's list so it opens in context (#92).
  Future<void> _openSearch() async {
    final all =
        ref.read(allTasksProvider).asData?.value ?? const <StoredTask>[];
    final listTitles = {for (final l in _lists) l.list.id: l.list.title};
    await showSearchOverlay(
      context,
      tasks: all,
      listTitles: listTitles,
      onSelect: (task) {
        final viewId = searchLandingViewId(all, task);
        final open = widget.onOpenInView;
        if (open != null) {
          open(viewId, task.task.id);
        } else {
          widget.onOpenTask(task.task.id);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final all =
        ref.watch(allTasksProvider).asData?.value ?? const <StoredTask>[];
    // Keep the lists subscribed and current so quick-add resolves its target.
    _lists = ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];

    final prefs = ref.watch(prefsControllerProvider);
    final sort = SortMode.byId(prefs.sortPerView[widget.viewId]);
    final tasks = visibleTasksForView(
      allTasks: all,
      viewId: widget.viewId,
      excludedLists: prefs.excludedLists.toSet(),
      showCompleted: prefs.showCompleted,
      sort: sort,
      window: dateWindowNow(),
      newestId: _newestId,
    );
    // Per-row derived metadata over the FULL task set (subtasks included): the
    // inherited date (earliest unfinished subtask) and the subtask progress
    // counts. Subtasks never render as rows — they only feed a parent's badges.
    final dueInfo = computeEffectiveDue(all.map((t) => t.task));
    final subDone = <String, int>{};
    final subTotal = <String, int>{};
    for (final st in all) {
      final p = st.task.parent;
      if (p == null) continue;
      subTotal[p] = (subTotal[p] ?? 0) + 1;
      if (st.task.status == TaskStatus.completed) {
        subDone[p] = (subDone[p] ?? 0) + 1;
      }
    }
    final openUrl = ref.read(urlOpenerProvider);
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
        _ListToolbar(
          sort: sort,
          showCompleted: prefs.showCompleted,
          onSearch: _openSearch,
          onSort: (m) => ref
              .read(prefsControllerProvider.notifier)
              .setSort(widget.viewId, m),
          onShowCompleted: (v) =>
              ref.read(prefsControllerProvider.notifier).setShowCompleted(v),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? Center(
                  child: Text(
                    emptyMessageFor(widget.viewId),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, i) {
                    final stored = tasks[i];
                    final t = stored.task;
                    return TaskRow(
                      key: ValueKey(t.id),
                      title: t.title,
                      notes: t.notes,
                      completed: t.status == TaskStatus.completed,
                      due: t.due,
                      inheritedDue: dueInfo[t.id]?.propagated,
                      pendingSync: stored.syncState == SyncState.dirty,
                      subtaskDone: subDone[t.id] ?? 0,
                      subtaskTotal: subTotal[t.id] ?? 0,
                      onOpen: () => widget.onOpenTask(t.id),
                      onToggle: () =>
                          ref.read(commandsProvider).toggleComplete(t.id),
                      onRename: (v) =>
                          ref.read(commandsProvider).renameTask(t.id, v),
                      onSetDue: (m) => _quickMove(t.id, m),
                      onPickDate: () => _openDatePicker(t.id, t.due),
                      onOpenUrl: openUrl,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// The list toolbar: the sort-order dropdown and the show-completed toggle.
class _ListToolbar extends StatelessWidget {
  const _ListToolbar({
    required this.sort,
    required this.showCompleted,
    required this.onSearch,
    required this.onSort,
    required this.onShowCompleted,
  });

  final SortMode sort;
  final bool showCompleted;
  final VoidCallback onSearch;
  final ValueChanged<SortMode> onSort;
  final ValueChanged<bool> onShowCompleted;

  @override
  Widget build(BuildContext context) {
    // A Wrap (not a Row) so a narrow list pane — a phone, or the desktop list
    // beside an open detail — flows the toggle onto a second line instead of
    // overflowing. On a wide pane spaceBetween keeps sort left, toggle right.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // A nested Wrap (not a Row) so a very narrow pane flows the sort
          // dropdown below the search button instead of overflowing — the same
          // reason the outer toolbar is a Wrap.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                key: const Key('search-button'),
                icon: const Icon(Icons.search),
                tooltip: 'Search tasks',
                onPressed: onSearch,
              ),
              SortDropdown(value: sort, onChanged: onSort),
            ],
          ),
          // The whole label toggles — a coarse pointer gets a full-size target,
          // not just the checkbox (touch has no hover).
          InkWell(
            key: const Key('show-completed-toggle'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => onShowCompleted(!showCompleted),
            // A 48dp-tall hit area — the toolbar renders on a phone too, so the
            // whole toggle (not just the shrink-wrapped checkbox) is tappable.
            // SizedBox (not Container-with-alignment, which would fill the width).
            child: SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: showCompleted,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) => onShowCompleted(v ?? false),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Show completed',
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
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
