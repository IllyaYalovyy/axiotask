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

import '../app/commands.dart' show DeleteToken;
import '../app/pending_edits.dart';
import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../app/quick_add.dart';
import '../model/dates.dart' show DateMove;
import '../model/effective_due.dart';
import '../model/task.dart';
import '../model/task_tree.dart';
import '../model/task_view.dart';
import '../store/stored.dart';
import 'bulk_add.dart';
import 'bulk_bar.dart';
import 'date_format.dart';
import 'due_date_picker.dart';
import 'list_detail_scaffold.dart' show ListDetailScaffold;
import 'list_pickers.dart';
import 'search.dart';
import 'sort_dropdown.dart';
import 'task_actions.dart';
import 'task_row.dart';
import 'url_opener.dart';
import 'views.dart';

/// The reorder move a drag from [oldIndex] to landing [newIndex] over the
/// visible [rows] should apply: a direction plus a STEP COUNT that counts only
/// siblings in the SAME list (cross-list cards in the "all" view are skipped,
/// mirroring ListView.svelte). [newIndex] is the ADJUSTED landing index (as
/// delivered by ReorderableListView.onReorderItem — the down-shift is already
/// applied). Returns `null` for a no-op (dropped in place, or only other-list
/// cards were crossed). Visible rows are top-level only (invariant #1), so
/// "same parent" is implicit.
({String direction, int steps})? reorderStep(
  List<StoredTask> rows,
  int oldIndex,
  int newIndex,
) {
  if (newIndex == oldIndex) return null;
  final moving = rows[oldIndex];
  final down = newIndex > oldIndex;
  final lo = down ? oldIndex + 1 : newIndex;
  final hi = down ? newIndex : oldIndex - 1;
  var steps = 0;
  for (var i = lo; i <= hi; i++) {
    if (rows[i].listId == moving.listId) steps++;
  }
  if (steps == 0) return null;
  return (direction: down ? 'down' : 'up', steps: steps);
}

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
    this.onOpenTaskNotes,
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

  /// Open the detail panel for a task id with the Notes field focused (the
  /// context menu's "Edit notes"). When null, falls back to [onOpenTask].
  final ValueChanged<String>? onOpenTaskNotes;

  /// Open a task in a SPECIFIC view (list) — used by search to land a subtask
  /// on its parent's list (#92). When null, opening falls back to [onOpenTask]
  /// in the current view.
  final void Function(String viewId, String taskId)? onOpenInView;

  @override
  ConsumerState<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends ConsumerState<TaskListView> {
  final TextEditingController _quickAdd = TextEditingController();
  // The quick-add FocusNode is app-wide (read from quickAddFocusProvider) so the
  // mobile FAB — which lives outside this pane — can focus the input.

  // Transient "pin this new task to the top" id, cleared when the view unmounts
  // on a view switch (only the "all" view mounts this widget today).
  String? _newestId;

  // The typed title whose parsed date the user chose to keep as literal text
  // (the preview chip's ×), so its phrase is not re-read as a due date.
  String _dateIgnoredFor = '';

  // The known lists, kept current by the build's watch so quick-add can resolve
  // its target synchronously at submit time.
  List<StoredTaskList> _lists = const [];

  // The full visible task set from the last build, so the action handlers can
  // resolve demote candidates and task rows without re-reading the provider.
  List<StoredTask> _all = const [];

  // The current multi-select (BulkOps). Empty means the bulk bar is hidden.
  // The widget is keyed per-view, so a view switch remounts and clears it.
  final Set<String> _selectedIds = {};

  // The one row asked to enter inline rename via the context menu's "Edit
  // title"; cleared when that row leaves edit mode.
  String? _editId;

  // The app-wide pending-edits registry, captured in initState so dispose can
  // unregister the quick-add draft flush without an unsafe `ref` lookup (#183).
  late final PendingEdits _pendingEdits;

  bool get _isSmartView => SmartView.byId(widget.viewId) != null;

  /// The list a fresh bulk insert targets: the current list, or the first list
  /// when a smart view is active (mirrors the reference's bulkTargetList).
  String? get _bulkTargetList => _isSmartView
      ? (_lists.isEmpty ? null : _lists.first.list.id)
      : widget.viewId;

  /// The natural-language due parsed from the current input, unless the user
  /// dismissed it for this exact text.
  String? get _previewDue => _quickAdd.text == _dateIgnoredFor
      ? null
      : parseQuickAddDue(_quickAdd.text);

  @override
  void initState() {
    super.initState();
    // Reset the back ladder's view of the selection for this freshly-mounted
    // view: the widget is keyed per view, so a view switch remounts here and a
    // stale "selection active" from the previous view must not deaden the back
    // button. Scheduled after the first frame so it never modifies a provider
    // mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncBackHandle();
    });
    // A non-empty quick-add draft is an in-progress "create a task" edit; commit
    // it when the app is backgrounded so a swiped-away process never loses it
    // (#183). Only the app-lifecycle path flushes the quick-add (a detail close
    // does not touch it). Captured so [dispose] unregisters without a `ref`
    // lookup on a deactivated widget.
    _pendingEdits = ref.read(pendingEditsProvider)
      ..register(PendingEdit.quickAdd, _flushDraft);
  }

  @override
  void dispose() {
    _pendingEdits.unregister(PendingEdit.quickAdd, _flushDraft);
    _quickAdd.dispose();
    // The FocusNode is owned by quickAddFocusProvider (app-wide) — not disposed
    // here.
    super.dispose();
  }

  /// Publish this view's selection liveness to the shell's back-precedence
  /// ladder (T8.3) — non-empty means a back should clear it rather than exit.
  void _syncBackHandle() => ref
      .read(selectionBackHandleProvider.notifier)
      .set(_selectedIds.isEmpty ? null : _clearSelection);

  /// Run a manual refresh (mobile pull-to-refresh): a real sync when a session
  /// is live, else a no-op over the always-live reactive store.
  Future<void> _pullRefresh() => ref.read(refreshActionProvider)();

  Future<void> _submit() async {
    final messenger = ScaffoldMessenger.of(context);
    final created = await _createFromDraft();
    if (created == null || !mounted) return;
    // Landing feedback (#190): when the new task's date fails the current view's
    // filter it renders nowhere here — toast WHERE it actually went (with a
    // jump) rather than leaving a silent, invisible create.
    final dest = landingDestinationFor(
      viewId: widget.viewId,
      due: _bareDue(created.task.due),
      listId: created.listId,
      listTitle: _listTitle(created.listId),
      window: dateWindowNow(),
    );
    if (dest != null) {
      _landingToast(
        messenger,
        dest,
        subject: 'Added "${created.task.title}"',
        taskIds: [created.task.id],
      );
    }
    // Creating a task never opens the panel on its own; if it was already open,
    // follow it to the new task instead of leaving a stale one selected.
    if (widget.selectedTaskId != null) widget.onOpenTask(created.task.id);
  }

  /// The created task's own due reduced to a bare `YYYY-MM-DD` so it compares
  /// against the smart-view window bounds (which are bare) — a fresh task has no
  /// subtasks, so its effective due is its own explicit date. Truncating the
  /// stored RFC-3339 form keeps a boundary-day create (e.g. today+14) classified
  /// exactly, not one day off.
  static String? _bareDue(String? due) =>
      (due == null || due.length < 10) ? due : due.substring(0, 10);

  /// The title of the list with [listId], or `null` when it is unknown — the
  /// cross-list row tag (F18) omits the tag rather than mislabel a row whose
  /// list has not loaded yet.
  String? _listTitleOrNull(String listId) {
    for (final l in _lists) {
      if (l.list.id == listId) return l.list.title;
    }
    return null;
  }

  /// The title of the list with [listId], for the landing toast — falls back to
  /// the first known list (the lists set is never empty once a create landed).
  String _listTitle(String listId) => _lists
      .firstWhere((l) => l.list.id == listId, orElse: () => _lists.first)
      .list
      .title;

  /// The #190 landing toast: "`<subject>` to `<where>`" with a **View** jump to
  /// the view that actually shows the just-created task(s). Fired only when the
  /// current view hides the create — an in-view create stays toast-free. The
  /// jump opens the first created task in [dest] so the user lands on it.
  void _landingToast(
    ScaffoldMessengerState messenger,
    LandingDestination dest, {
    required String subject,
    required List<String> taskIds,
  }) {
    final jump = widget.onOpenInView;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('$subject to ${dest.label}'),
          duration: const Duration(seconds: 6),
          action: (jump == null || taskIds.isEmpty)
              ? null
              : SnackBarAction(
                  label: 'View',
                  onPressed: () => jump(dest.viewId, taskIds.first),
                ),
        ),
      );
  }

  /// Commit the current quick-add draft as a task (never an empty one), pin it,
  /// and clear the field. Returns the created task, or null when there is
  /// nothing to create (empty draft, or no list to create in). Shared by the
  /// Enter/+ submit and the app-backgrounded flush (#183).
  Future<StoredTask?> _createFromDraft() async {
    final title = _quickAdd.text.trim();
    if (title.isEmpty) return null; // never create an empty task

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
    if (target == null) return null; // no list to create in

    final stored = await ref
        .read(commandsProvider)
        .createTask(listId: target, title: title, due: due);
    if (!mounted) return stored;
    setState(() {
      _newestId = stored.task.id;
      _quickAdd.clear();
      _dateIgnoredFor = '';
    });
    return stored;
  }

  /// The quick-add's entry in the pending-edits registry — commit the draft on
  /// the way to the background so a killed process never drops it (#183).
  void _flushDraft() {
    _createFromDraft();
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

  // ── multi-select + bulk operations (BulkOps) ──────────────────────────────

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
    // Republish selection liveness so the shell's back ladder (T8.3) knows a
    // back should now clear (or, when the last row is deselected, stop clearing)
    // the selection instead of exiting the app.
    _syncBackHandle();
  }

  void _clearSelection() {
    setState(_selectedIds.clear);
    _syncBackHandle();
  }

  /// A 4-second info toast reporting a bulk op's outcome ("N tasks `<verb>`").
  void _bulkToast(int n, String verb) {
    if (n <= 0) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('$n task${n == 1 ? '' : 's'} $verb'),
          duration: const Duration(seconds: 4),
        ),
      );
  }

  Future<void> _bulkComplete() async {
    final ids = _selectedIds.toList();
    final commands = ref.read(commandsProvider);
    final byId = {for (final t in _all) t.task.id: t};
    _clearSelection();
    for (final id in ids) {
      // Completing is idempotent-ish: only flip a still-open task (toggle would
      // otherwise re-open an already-completed one).
      final t = byId[id];
      if (t != null && t.task.status != TaskStatus.completed) {
        await commands.toggleComplete(id);
      }
    }
    if (mounted) _bulkToast(ids.length, 'completed');
  }

  Future<void> _bulkSetDue(DateMove move) async {
    final ids = _selectedIds.toList();
    final commands = ref.read(commandsProvider);
    _clearSelection();
    for (final id in ids) {
      await commands.setDue(id, move);
    }
    if (mounted) {
      _bulkToast(
        ids.length,
        move == DateMove.clear ? 'cleared' : 'rescheduled',
      );
    }
  }

  Future<void> _bulkDelete() async {
    final ids = _selectedIds.toList();
    final commands = ref.read(commandsProvider);
    final messenger = ScaffoldMessenger.of(context);
    _clearSelection();
    // Capture every delete token so one Undo restores all N (each with its own
    // subtree, parent, and position) — the same undoDelete the single-row delete
    // uses, replayed across the selection.
    final tokens = <DeleteToken>[];
    for (final id in ids) {
      tokens.add(await commands.deleteTask(id));
    }
    if (!mounted || tokens.isEmpty) return;
    final n = tokens.length;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('$n task${n == 1 ? '' : 's'} deleted'),
          duration: const Duration(seconds: 30),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              for (final token in tokens) {
                commands.undoDelete(token);
              }
            },
          ),
        ),
      );
  }

  Future<void> _bulkMove() async {
    // Bulk mode shows EVERY list (the selection may span lists).
    final target = await showMoveToListPicker(context, lists: _lists);
    if (target == null || !mounted) return;
    final ids = _selectedIds.toList();
    final commands = ref.read(commandsProvider);
    _clearSelection();
    for (final id in ids) {
      await commands.moveTaskToList(id, target);
    }
    if (mounted) _bulkToast(ids.length, 'moved');
  }

  // ── per-row action surface (§4) ───────────────────────────────────────────

  /// The legal parents [t] could be demoted under: every OTHER childless
  /// top-level task in the SAME list (#88). canNestUnder is the single source of
  /// truth for the two-level rule.
  List<StoredTask> _demoteCandidates(StoredTask t) => _all
      .where(
        (c) =>
            c.listId == t.listId &&
            canNestUnder(t.task.id, c.task, _all.map((x) => x.task)),
      )
      .toList();

  /// Build and show the row's action surface: the desktop context menu at
  /// [globalPosition] (a right-click), or the touch action sheet ([globalPosition]
  /// null). Both carry EVERY action.
  Future<void> _showRowActions(StoredTask t, {Offset? globalPosition}) async {
    final demotable = t.task.parent == null && _demoteCandidates(t).isNotEmpty;
    final entries = buildTaskMenu(
      task: t,
      lists: _lists,
      demotable: demotable,
      selected: _selectedIds.contains(t.task.id),
      onToggleSelect: () => _toggleSelect(t.task.id),
      onEditTitle: () => setState(() => _editId = t.task.id),
      onEditNotes: () =>
          (widget.onOpenTaskNotes ?? widget.onOpenTask)(t.task.id),
      onSetDue: (move) => _quickMove(t.task.id, move),
      onPickDate: () => _openDatePicker(t.task.id, t.task.due),
      onMoveToList: (listId) => _moveToList(t, listId),
      onDetach: () => _detach(t),
      onDemote: () => _demote(t),
      onDuplicate: () => _duplicate(t),
      onDetails: () => widget.onOpenTask(t.task.id),
      onOpenGoogle: () => _openGoogle(t),
      onDelete: () => _delete(t),
    );
    if (globalPosition != null) {
      await showTaskContextMenu(context, globalPosition, entries);
    } else {
      await showTaskActionSheet(context, entries);
    }
  }

  /// Move [t]'s subtree to [targetListId] and surface an undoable toast (F11:
  /// undoMoveToList reverses the delete-from-old + create-in-new, restoring the
  /// pre-move subtree in its original list).
  Future<void> _moveToList(StoredTask t, String targetListId) async {
    if (t.listId == targetListId) return; // already there
    final title = t.task.title;
    final listTitle = _lists
        .firstWhere(
          (l) => l.list.id == targetListId,
          orElse: () => _lists.first,
        )
        .list
        .title;
    final commands = ref.read(commandsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final token = await commands.moveTaskToList(t.task.id, targetListId);
    if (!mounted || token == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Moved "$title" to $listTitle'),
          duration: const Duration(seconds: 30),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => commands.undoMoveToList(token),
          ),
        ),
      );
  }

  /// Detach a subtask back to top level, directly after its former parent.
  Future<void> _detach(StoredTask t) async {
    final parentId = t.task.parent;
    if (parentId == null) return;
    await ref
        .read(commandsProvider)
        .moveTask(t.task.id, parentId: null, previousId: parentId);
  }

  /// Demote [t] into a subtask via the searchable parent picker (#88).
  Future<void> _demote(StoredTask t) async {
    final candidates = _demoteCandidates(t);
    if (candidates.isEmpty) return;
    final parentId = await showParentPicker(context, candidates: candidates);
    if (parentId == null || !mounted) return;
    await ref.read(commandsProvider).moveTask(t.task.id, parentId: parentId);
  }

  /// Duplicate [t] as "`<title>` (copy)" in the same list and parent.
  Future<void> _duplicate(StoredTask t) async {
    await ref
        .read(commandsProvider)
        .createTask(
          listId: t.listId,
          parentId: t.task.parent,
          title: '${t.task.title} (copy)',
        );
  }

  /// Open the task's Google Tasks URL via the shared opener.
  Future<void> _openGoogle(StoredTask t) async {
    final url = t.task.webViewLink;
    if (url == null || url.isEmpty) return;
    await ref.read(urlOpenerProvider)(url);
  }

  /// Toggle [stored]'s completion. A COMPLETION (checkbox tick or swipe-right,
  /// the primary mobile gesture) surfaces a 30-second Undo toast whose token
  /// carries the exact cascade set, so undo restores the pre-swipe state — an
  /// already-completed subtask is never reopened. A reopen is silent (no toast).
  Future<void> _toggle(StoredTask stored) async {
    final commands = ref.read(commandsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final token = await commands.toggleComplete(stored.task.id);
    if (!mounted || !token.wasCompleting) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Completed "${stored.task.title}"'),
          duration: const Duration(seconds: 30),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => commands.undoToggleComplete(token),
          ),
        ),
      );
  }

  /// Delete [t] with a 30-second Undo toast (mirrors the detail panel's delete).
  Future<void> _delete(StoredTask t) async {
    final commands = ref.read(commandsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final token = await commands.deleteTask(t.task.id);
    if (!mounted) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted "${t.task.title}"'),
          duration: const Duration(seconds: 30),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => commands.undoDelete(token),
          ),
        ),
      );
  }

  /// Open the BulkAdd dialog (prefilled with [initialText]) and create the
  /// tasks it returns, then toast the count (BulkAdd / PasteCreate bulk-split).
  Future<void> _openBulkAdd({String initialText = ''}) async {
    final target = _bulkTargetList;
    if (target == null) return;
    final result = await showBulkAddDialog(
      context,
      lists: _lists,
      defaultListId: target,
      initialText: initialText,
    );
    if (result == null || !mounted) return;
    final commands = ref.read(commandsProvider);
    final createdIds = <String>[];
    if (result.mode == BulkAddMode.titleNotes) {
      final all = result.text.split('\n');
      final title = all.first.trim();
      final notes = all.skip(1).join('\n').trim();
      if (title.isNotEmpty) {
        final task = await commands.createTask(
          listId: result.listId,
          title: title,
        );
        if (notes.isNotEmpty) await commands.setNotes(task.task.id, notes);
        createdIds.add(task.task.id);
      }
    } else {
      for (final line in splitBulkLines(result.text)) {
        final task = await commands.createTask(
          listId: result.listId,
          title: line,
        );
        createdIds.add(task.task.id);
      }
    }
    if (mounted && createdIds.isNotEmpty) {
      final n = createdIds.length;
      final countPrefix = 'Added $n task${n == 1 ? '' : 's'}';
      // Bulk-added rows are always undated, so from a dated smart view they land
      // in Unscheduled, invisible to that view — name where they went (#190).
      final dest = landingDestinationFor(
        viewId: widget.viewId,
        due: null,
        listId: result.listId,
        listTitle: _listTitle(result.listId),
        window: dateWindowNow(),
      );
      final messenger = ScaffoldMessenger.of(context);
      if (dest == null) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(countPrefix),
              duration: const Duration(seconds: 4),
            ),
          );
      } else {
        _landingToast(
          messenger,
          dest,
          subject: countPrefix,
          taskIds: createdIds,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final all =
        ref.watch(allTasksProvider).asData?.value ?? const <StoredTask>[];
    _all = all;
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
    // Focus renders an "Overdue (N)" headed bucket above the dated one (F17):
    // the overdue cards are lifted to the front (their internal order kept) and
    // a heading marks the split. Every other view is a single ungrouped list.
    final displayTasks = <StoredTask>[];
    var overdueCount = 0;
    if (widget.viewId == SmartView.focus.id) {
      final part = partitionFocusOverdue(
        rows: tasks,
        allTasks: all,
        window: dateWindowNow(),
      );
      overdueCount = part.overdueCount;
      displayTasks
        ..addAll(part.overdue)
        ..addAll(part.rest);
    } else {
      displayTasks.addAll(tasks);
    }
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
    final quickAddFocus = ref.watch(quickAddFocusProvider);
    return Column(
      children: [
        _QuickAddBar(
          controller: _quickAdd,
          focusNode: quickAddFocus,
          previewDue: _previewDue,
          onSubmit: _submit,
          onDismissPreview: () {
            setState(() => _dateIgnoredFor = _quickAdd.text);
            quickAddFocus.requestFocus();
          },
          onChanged: () => setState(() {}),
        ),
        const Divider(height: 1),
        _ListToolbar(
          sort: sort,
          showCompleted: prefs.showCompleted,
          onSearch: _openSearch,
          onBulkAdd: _bulkTargetList == null ? null : () => _openBulkAdd(),
          onSort: (m) => ref
              .read(prefsControllerProvider.notifier)
              .setSort(widget.viewId, m),
          onShowCompleted: (v) =>
              ref.read(prefsControllerProvider.notifier).setShowCompleted(v),
          // Clear-completed is a concrete-list-only action, and only while
          // completed tasks are visible (you cannot bulk-delete what you cannot
          // see). Smart views (which aggregate across lists) never offer it.
          onClearCompleted:
              prefs.showCompleted && SmartView.byId(widget.viewId) == null
              ? _confirmClearCompleted
              : null,
        ),
        const Divider(height: 1),
        if (_selectedIds.isNotEmpty)
          BulkBar(
            count: _selectedIds.length,
            onComplete: _bulkComplete,
            onSetDue: _bulkSetDue,
            onMove: _bulkMove,
            onDelete: _bulkDelete,
            onClear: _clearSelection,
          ),
        Expanded(
          child: _listArea(
            displayTasks,
            overdueCount,
            dueInfo,
            subDone,
            subTotal,
            openUrl,
          ),
        ),
      ],
    );
  }

  /// The scrollable task list for the current view, wrapped on a phone in a
  /// pull-to-refresh. The list scrolls even when short (AlwaysScrollable) so an
  /// over-pull from the top can arm the refresh — and, because RefreshIndicator
  /// only fires at scroll offset 0, a pull begun after scrolling DOWN never
  /// refreshes (it just scrolls). Ports the reference's from-the-top pull rule
  /// via Flutter-native means.
  ///
  /// When [overdueCount] > 0 (Focus with overdue cards) an "Overdue (N)" heading
  /// is rendered as the first list item, above the [overdueCount] leading rows;
  /// the remaining rows follow after a gap. The heading occupies a list slot, so
  /// both list types offset their row indices by 1 when it is present.
  Widget _listArea(
    List<StoredTask> tasks,
    int overdueCount,
    Map<String, DueInfo> dueInfo,
    Map<String, int> subDone,
    Map<String, int> subTotal,
    UrlOpener openUrl,
  ) {
    final sort = SortMode.byId(
      ref.read(prefsControllerProvider).sortPerView[widget.viewId],
    );
    final mobile =
        MediaQuery.sizeOf(context).width < ListDetailScaffold.breakpoint;
    final physics = mobile ? const AlwaysScrollableScrollPhysics() : null;
    // On a phone the "new task" FAB floats over the bottom of the list; pad the
    // scroll so the last row can clear it (its trailing quick-date/⋯ are never
    // stuck under the FAB). Desktop has no FAB, so no padding.
    final listPadding = mobile
        ? const EdgeInsets.only(bottom: 88)
        : EdgeInsets.zero;

    // The heading is present only when there ARE overdue cards to head; it then
    // shifts every row down one slot in the list's index space.
    final headerOffset = overdueCount > 0 ? 1 : 0;

    final Widget content;
    if (tasks.isEmpty) {
      final empty = Center(
        child: Text(
          emptyMessageFor(widget.viewId),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
      // Keep the empty view pull-refreshable on a phone: a full-height scroll
      // view that always accepts an over-pull.
      content = mobile
          ? LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: empty,
                ),
              ),
            )
          : empty;
    } else if (sort == SortMode.manual) {
      // Drag reorder rides ONLY the manual sort (backend position); the other
      // sorts derive their order, so reordering them is meaningless (the
      // reference disables it too).
      content = ReorderableListView.builder(
        buildDefaultDragHandles: false,
        physics: physics,
        padding: listPadding,
        itemCount: tasks.length + headerOffset,
        // Drag indices are in list-item space (the heading is item 0); map them
        // back to row indices, clamping a drop above the heading to the top row.
        onReorderItem: (oldIndex, newIndex) => _onReorder(
          tasks,
          oldIndex - headerOffset,
          (newIndex - headerOffset).clamp(0, tasks.length - 1),
        ),
        itemBuilder: (context, i) {
          if (headerOffset == 1 && i == 0) {
            // A non-draggable heading (no ReorderableDragStartListener) — it
            // stays put while the overdue rows drag around it.
            return _overdueHeading(overdueCount);
          }
          final ti = i - headerOffset;
          final stored = tasks[ti];
          final row = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ReorderableDragStartListener(
                index: i,
                child: SizedBox(
                  key: ValueKey('drag-handle-${stored.task.id}'),
                  // A comfortable drag target for both a mouse and a finger
                  // (touch-drag rides the same handle); the glyph stays small,
                  // the HIT AREA is 48dp tall.
                  width: 36,
                  height: 48,
                  child: Icon(
                    Icons.drag_indicator,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: _taskRow(stored, dueInfo, subDone, subTotal, openUrl),
              ),
            ],
          );
          return _bucketSpaced(
            row,
            ti,
            overdueCount,
            key: ValueKey('reorder-${stored.task.id}'),
          );
        },
      );
    } else {
      content = ListView.builder(
        physics: physics,
        padding: listPadding,
        itemCount: tasks.length + headerOffset,
        itemBuilder: (context, i) {
          if (headerOffset == 1 && i == 0) return _overdueHeading(overdueCount);
          final ti = i - headerOffset;
          return _bucketSpaced(
            _taskRow(tasks[ti], dueInfo, subDone, subTotal, openUrl),
            ti,
            overdueCount,
          );
        },
      );
    }

    if (!mobile) return content;
    return RefreshIndicator(onRefresh: _pullRefresh, child: content);
  }

  /// Apply a drag from [oldIndex] to [newIndex] over the visible [tasks] as the
  /// step-count reorder the command layer understands (one swap per step).
  Future<void> _onReorder(
    List<StoredTask> tasks,
    int oldIndex,
    int newIndex,
  ) async {
    final step = reorderStep(tasks, oldIndex, newIndex);
    if (step == null) return;
    final id = tasks[oldIndex].task.id;
    final commands = ref.read(commandsProvider);
    for (var i = 0; i < step.steps; i++) {
      await commands.reorderTask(id, step.direction);
    }
  }

  /// Confirm, then permanently clear the completed tasks in the current list.
  /// Destructive and NOT undoable, so it goes behind a styled confirm naming the
  /// count (the reference's clear-completed flow). Only reachable on a concrete
  /// list view with completed tasks visible (see the toolbar gating).
  Future<void> _confirmClearCompleted() async {
    final listId = widget.viewId;
    final count = _all
        .where(
          (t) => t.listId == listId && t.task.status == TaskStatus.completed,
        )
        .length;
    final plural = count == 1 ? '' : 's';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('clear-completed-confirm'),
        title: const Text('Clear completed'),
        content: Text(
          'Delete $count completed task$plural? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('clear-completed-confirm-button'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(commandsProvider).clearCompleted(listId);
  }

  /// The Focus view's "Overdue (N)" section heading — a small, bold, error-toned
  /// label that names the count of overdue cards below it (F17). Rendered only
  /// when there is at least one overdue card.
  Widget _overdueHeading(int count) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('overdue-heading'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        'Overdue ($count)',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: scheme.error,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  /// Wrap [row] with the inter-bucket gap when it is the FIRST row after the
  /// overdue bucket (Focus's dated bucket starts at index [overdueCount]), so
  /// the two buckets read as distinct groups; otherwise return [row] as-is. When
  /// a [key] is given it is carried on the returned widget (the reorderable list
  /// requires a stable per-item key).
  Widget _bucketSpaced(
    Widget row,
    int taskIndex,
    int overdueCount, {
    Key? key,
  }) {
    final firstRest = overdueCount > 0 && taskIndex == overdueCount;
    if (firstRest) {
      return Padding(
        key: key,
        padding: const EdgeInsets.only(top: 10),
        child: row,
      );
    }
    return key == null ? row : KeyedSubtree(key: key, child: row);
  }

  /// One [TaskRow] for [stored], wired to selection, the action surface, inline
  /// rename, and the quick-date/date-picker/URL affordances.
  Widget _taskRow(
    StoredTask stored,
    Map<String, DueInfo> dueInfo,
    Map<String, int> subDone,
    Map<String, int> subTotal,
    UrlOpener openUrl,
  ) {
    final t = stored.task;
    // In a cross-list view (any smart view aggregates across lists) every row is
    // tagged with the list it lives in, so a task's home is legible at a glance;
    // a single concrete-list view needs no tag (F18). The tag is the list's own
    // title, resolved from the current lists set.
    final listTag = _isSmartView ? _listTitleOrNull(stored.listId) : null;
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
      listTag: listTag,
      selected: _selectedIds.contains(t.id),
      selectionActive: _selectedIds.isNotEmpty,
      onSelectToggle: () => _toggleSelect(t.id),
      onContextMenu: (pos) => _showRowActions(stored, globalPosition: pos),
      onShowActions: () => _showRowActions(stored),
      editRequested: _editId == t.id,
      onEditDone: () {
        if (_editId == t.id) setState(() => _editId = null);
      },
      onOpen: () => widget.onOpenTask(t.id),
      onToggle: () => _toggle(stored),
      onRename: (v) => ref.read(commandsProvider).renameTask(t.id, v),
      onSetDue: (m) => _quickMove(t.id, m),
      onPickDate: () => _openDatePicker(t.id, t.due),
      onOpenUrl: openUrl,
    );
  }
}

/// The list toolbar: the sort-order dropdown and the show-completed toggle.
class _ListToolbar extends StatelessWidget {
  const _ListToolbar({
    required this.sort,
    required this.showCompleted,
    required this.onSearch,
    required this.onBulkAdd,
    required this.onSort,
    required this.onShowCompleted,
    required this.onClearCompleted,
  });

  final SortMode sort;
  final bool showCompleted;
  final VoidCallback onSearch;

  /// Open the BulkAdd dialog; `null` disables it (no list to target).
  final VoidCallback? onBulkAdd;
  final ValueChanged<SortMode> onSort;
  final ValueChanged<bool> onShowCompleted;

  /// Clear the completed tasks in the current list; `null` HIDES the action
  /// (not a concrete list, or completed tasks are hidden).
  final VoidCallback? onClearCompleted;

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
              IconButton(
                key: const Key('bulk-add-button'),
                icon: const Icon(Icons.playlist_add),
                tooltip: 'Add multiple tasks',
                onPressed: onBulkAdd,
              ),
              SortDropdown(value: sort, onChanged: onSort),
            ],
          ),
          // Right group: the clear-completed action (when offered) sits beside
          // the show-completed toggle. Wrapped so a narrow pane flows them.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (onClearCompleted != null)
                TextButton.icon(
                  key: const Key('clear-completed-button'),
                  onPressed: onClearCompleted,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear completed'),
                ),
              // The whole label toggles — a coarse pointer gets a full-size
              // target, not just the checkbox (touch has no hover).
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
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
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
