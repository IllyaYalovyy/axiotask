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
import 'package:flutter/services.dart' show Clipboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/commands.dart' show CommandError, CompleteToken, DeleteToken;
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
import 'toast.dart';
import 'url_opener.dart';
import 'views.dart';

/// The ANCHOR SIBLING a drag from [oldIndex] to landing [newIndex] over the
/// visible [rows] should drop the dragged row after — the id of the nearest row
/// ABOVE the drop that shares the moved row's list (`previousId` == null to drop
/// it at the FRONT of its siblings). Only same-list rows count as siblings, so
/// cross-list cards in the "all" view are skipped (mirroring ListView.svelte),
/// and the anchor is a CONCRETE visible neighbour rather than a slot index — the
/// command resolves it against the store's own position ordering, so a drop
/// stays unambiguous even when hidden completed rows interleave or Focus lifts
/// an overdue bucket to the front (G1 #202). [newIndex] is the ADJUSTED landing
/// index (as delivered by ReorderableListView.onReorderItem — the down-shift for
/// the removed row is already applied). Returns `null` for a no-op (dropped in
/// place, or only other-list cards were crossed). Visible rows are top-level
/// only (invariant #1), so "same parent" is implicit. Feeds a single
/// [Commands.reorderTaskAfter] per drop.
({String? previousId})? reorderAnchor(
  List<StoredTask> rows,
  int oldIndex,
  int newIndex,
) {
  final moving = rows[oldIndex];
  // The reduced order the adjusted [newIndex] indexes into (moved row removed);
  // the anchor is the nearest same-list row strictly above the drop.
  final reduced = [...rows]..removeAt(oldIndex);
  String? previousId;
  for (var i = newIndex - 1; i >= 0 && i < reduced.length; i--) {
    if (reduced[i].listId == moving.listId) {
      previousId = reduced[i].task.id;
      break;
    }
  }
  // The sibling the row already follows in the visible order — an unchanged
  // anchor means nothing moved (dropped in place, or only other-list cards
  // crossed).
  String? currentPrevious;
  for (var i = oldIndex - 1; i >= 0; i--) {
    if (rows[i].listId == moving.listId) {
      currentPrevious = rows[i].task.id;
      break;
    }
  }
  if (previousId == currentPrevious) return null;
  return (previousId: previousId);
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

  // The shell's inline-rename back-handle (G4 #183), captured so a row can
  // publish/retract its open editor without a `ref` lookup at call time.
  late final RenameBackHandle _renameBack;

  // The list the user aimed the quick-add at (#217), or null while it still
  // follows the view's own default. Ratified semantics: the pick applies to
  // this add AND to every subsequent one (it is NOT a one-shot), it is NEVER
  // persisted as a default (no prefs write), and it resets on a view change
  // (see [didUpdateWidget]).
  String? _pickedListId;

  bool get _isSmartView => SmartView.byId(widget.viewId) != null;

  /// The list a fresh insert targets when the user has picked nothing: the
  /// current list, or the first list when a smart view is active (mirrors the
  /// reference's bulkTargetList). Also the bulk-add dialog's default, which
  /// carries its own list selector.
  String? get _defaultTargetList => _isSmartView
      ? (_lists.isEmpty ? null : _lists.first.list.id)
      : widget.viewId;

  /// The list a quick-add creates into: the user's pick while it is still a
  /// KNOWN list, else the view's default. A picked list can vanish under the
  /// composer (a sync deletes it elsewhere) — falling back keeps the add
  /// landing somewhere real instead of against a dead id.
  String? get _quickAddTargetList {
    final picked = _pickedListId;
    if (picked != null && _lists.any((l) => l.list.id == picked)) return picked;
    return _defaultTargetList;
  }

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
    // A freshly-mounted view has no open inline-rename editor; clear any stale
    // "rename active" a previous view left on the back handle (G4 #183) — the
    // same reason the selection handle is reset above.
    _renameBack = ref.read(renameBackHandleProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _renameBack.set(null);
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
  void didUpdateWidget(covariant TaskListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The quick-add target belongs to the VIEW, not the session (#217): moving
    // to another view drops the aim back to that view's own default rather than
    // silently keeping tasks flowing into the list you left behind. The shell
    // keys this widget per view (so a switch usually remounts); this covers the
    // in-place update too, so the contract does not depend on the key.
    if (oldWidget.viewId != widget.viewId) _pickedListId = null;
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

  /// The touch creation surface (#216): a modal bottom-sheet composer over the
  /// same controller/focus/submit machinery as the desktop bar, so drafts,
  /// NL-date preview, landing toasts (#190), and the background flush (#183)
  /// are identical on both pointer classes. Submitting clears the field and
  /// KEEPS the sheet open for rapid consecutive adds; back / swipe-down / a
  /// scrim tap dismisses it (an unsubmitted draft survives in the controller
  /// and reappears on the next open). Landing toasts render through
  /// ToastOverlay, which sits above modals (F19).
  Future<void> _openQuickAddSheet() async {
    final quickAddFocus = ref.read(quickAddFocusProvider);
    // Raise the keyboard with the sheet — the composer is ready to type into
    // the moment it appears, with no extra tap.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => quickAddFocus.requestFocus(),
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          // Keep the composer above the keyboard (#166 IME contract).
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: _QuickAddBar(
            controller: _quickAdd,
            focusNode: quickAddFocus,
            dateIgnoredFor: _dateIgnoredFor,
            lists: _lists,
            targetListId: _quickAddTargetList,
            onTargetChanged: (id) {
              setState(() => _pickedListId = id);
              // The sheet is its own route — re-render its content too.
              setSheetState(() {});
              quickAddFocus.requestFocus();
            },
            onSubmit: () {
              _submit();
              // Rapid entry: the field cleared; keep composing.
              quickAddFocus.requestFocus();
            },
            onAddPastedLines: (raw) {
              _addPastedLines(raw);
              // The sheet is its own route — re-render its content too.
              setSheetState(() {});
              quickAddFocus.requestFocus();
            },
            onDismissPreview: () {
              setState(() => _dateIgnoredFor = _quickAdd.text);
              // The sheet is its own route — re-render its content too.
              setSheetState(() {});
              quickAddFocus.requestFocus();
            },
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final toasts = ref.read(toastControllerProvider);
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
      excludedLists: ref.read(prefsControllerProvider).excludedLists.toSet(),
      window: dateWindowNow(),
    );
    if (dest != null) {
      _landingToast(
        toasts,
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
  /// jump opens the first created task in [dest] so the user lands on it. Routes
  /// through the [ToastController] (F19 #198) so it out-stacks any open modal.
  void _landingToast(
    ToastController toasts,
    LandingDestination dest, {
    required String subject,
    required List<String> taskIds,
  }) {
    final jump = widget.onOpenInView;
    final message = '$subject to ${dest.label}';
    if (jump == null || taskIds.isEmpty) {
      toasts.showInfo(message);
    } else {
      toasts.showAction(
        message,
        actionLabel: 'View',
        onAction: () => jump(dest.viewId, taskIds.first),
      );
    }
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

    // Where it lands: the composer's picked list (#217) when the user aimed it
    // somewhere, else the view's default — a smart view imposes no target list,
    // so the first list wins (the default "My Tasks"); a concrete list view
    // targets itself. [_lists] is kept current by the build's watch.
    final target = _quickAddTargetList;
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
    final toasts = ref.read(toastControllerProvider);
    final commands = ref.read(commandsProvider);
    final res = await commands.setDue(id, move);
    if (!mounted) return;
    offerDueCascadeUndo(toasts, commands, res);
  }

  /// Open the calendar for [id] on its current [currentDue], apply the choice
  /// (a picked day via `setDueRaw`, Clear via `setDue`), then surface any #164
  /// cascade. A dismissed picker leaves the date untouched.
  Future<void> _openDatePicker(String id, String? currentDue) async {
    final toasts = ref.read(toastControllerProvider);
    final commands = ref.read(commandsProvider);
    final pick = await showDueDatePicker(context, initial: currentDue);
    if (pick == null || !mounted) return;
    final res = switch (pick) {
      DuePickClear() => await commands.setDue(id, DateMove.clear),
      DuePickDate(:final ymd) => await commands.setDueRaw(id, ymd),
    };
    if (!mounted) return;
    offerDueCascadeUndo(toasts, commands, res);
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
    ref
        .read(toastControllerProvider)
        .showInfo('$n task${n == 1 ? '' : 's'} $verb');
  }

  Future<void> _bulkComplete() async {
    final ids = _selectedIds.toList();
    final commands = ref.read(commandsProvider);
    final toasts = ref.read(toastControllerProvider);
    final byId = {for (final t in _all) t.task.id: t};
    _clearSelection();
    // Collect each completion's undo token so ONE Undo reopens exactly what this
    // op flipped — every toggle's cascade-exact set (a descendant already
    // completed before the op stays completed on undo, F11/#184), just like bulk
    // delete offers one Undo for the whole selection.
    final tokens = <CompleteToken>[];
    for (final id in ids) {
      // Completing is idempotent-ish: only flip a still-open task (toggle would
      // otherwise re-open an already-completed one).
      final t = byId[id];
      if (t != null && t.task.status == TaskStatus.completed) continue;
      try {
        tokens.add(await commands.toggleComplete(id));
      } on CommandError {
        // Row vanished between selection and op (concurrent delete/tombstone) —
        // skip it and still complete, and undo, the rest.
      }
    }
    if (!mounted || tokens.isEmpty) return;
    final n = tokens.length;
    toasts.showUndo('$n task${n == 1 ? '' : 's'} completed', () {
      for (final token in tokens) {
        commands.undoToggleComplete(token);
      }
    });
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
    final toasts = ref.read(toastControllerProvider);
    _clearSelection();
    // Capture every delete token so one Undo restores all N (each with its own
    // subtree, parent, and position) — the same undoDelete the single-row delete
    // uses, replayed across the selection.
    final tokens = <DeleteToken>[];
    for (final id in ids) {
      try {
        tokens.add(await commands.deleteTask(id));
      } on CommandError {
        // Row vanished between selection and op (a sync pull or another gesture
        // deleted/tombstoned it): nothing left to delete or undo for this id —
        // skip it so the rest of the selection still deletes as one Undo unit.
      }
    }
    if (!mounted || tokens.isEmpty) return;
    final n = tokens.length;
    toasts.showUndo('$n task${n == 1 ? '' : 's'} deleted', () {
      for (final token in tokens) {
        commands.undoDelete(token);
      }
    });
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
    final toasts = ref.read(toastControllerProvider);
    final token = await commands.moveTaskToList(t.task.id, targetListId);
    if (!mounted || token == null) return;
    toasts.showUndo(
      'Moved "$title" to $listTitle',
      () => commands.undoMoveToList(token),
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
    final toasts = ref.read(toastControllerProvider);
    final token = await commands.toggleComplete(stored.task.id);
    if (!mounted || !token.wasCompleting) return;
    toasts.showUndo(
      'Completed "${stored.task.title}"',
      () => commands.undoToggleComplete(token),
    );
  }

  /// Delete [t] with a 30-second Undo toast (mirrors the detail panel's delete).
  Future<void> _delete(StoredTask t) async {
    final commands = ref.read(commandsProvider);
    final toasts = ref.read(toastControllerProvider);
    final token = await commands.deleteTask(t.task.id);
    if (!mounted) return;
    toasts.showUndo(
      'Deleted "${t.task.title}"',
      () => commands.undoDelete(token),
    );
  }

  /// Open the BulkAdd dialog (prefilled with [initialText]) and create the
  /// tasks it returns, then toast the count (BulkAdd / PasteCreate bulk-split).
  Future<void> _openBulkAdd({String initialText = ''}) async {
    final target = _defaultTargetList;
    if (target == null) return;
    final result = await showBulkAddDialog(
      context,
      lists: _lists,
      defaultListId: target,
      initialText: initialText,
    );
    if (result == null || !mounted) return;
    await _commitBulkAdd(result);
  }

  /// Create the tasks a confirmed [result] describes and toast the count — the
  /// ONE bulk-split commit path, shared by the toolbar dialog and the composer's
  /// multi-line-paste offer (#219), so both create identically.
  ///
  /// Per-line mode reads each line's trailing natural-language date exactly as
  /// the quick-add bar does (title kept verbatim, only the due parsed), so a
  /// pasted "call bob tomorrow" lands dated instead of arriving unscheduled.
  Future<void> _commitBulkAdd(BulkAddResult result) async {
    final commands = ref.read(commandsProvider);
    final createdIds = <String>[];
    final dues = <String?>{};
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
        dues.add(null);
      }
    } else {
      for (final line in splitBulkLines(result.text)) {
        final due = parseQuickAddDue(line);
        final task = await commands.createTask(
          listId: result.listId,
          title: line,
          due: due,
        );
        createdIds.add(task.task.id);
        dues.add(due);
      }
    }
    if (mounted && createdIds.isNotEmpty) {
      final n = createdIds.length;
      final countPrefix = 'Added $n task${n == 1 ? '' : 's'}';
      // Where they went (#190): undated rows from a dated smart view land in
      // Unscheduled, invisible to the view that created them. A landing hint
      // can only name ONE place, so it is offered only when every new row
      // shares a date — mixed per-line dates scatter, and the honest feedback
      // is then the bare count.
      final dest = dues.length == 1
          ? landingDestinationFor(
              viewId: widget.viewId,
              due: dues.single,
              listId: result.listId,
              listTitle: _listTitle(result.listId),
              excludedLists: ref
                  .read(prefsControllerProvider)
                  .excludedLists
                  .toSet(),
              window: dateWindowNow(),
            )
          : null;
      final toasts = ref.read(toastControllerProvider);
      if (dest == null) {
        toasts.showInfo(countPrefix);
      } else {
        _landingToast(toasts, dest, subject: countPrefix, taskIds: createdIds);
      }
    }
  }

  /// Accept the composer's multi-line-paste offer (#219): split the RAW pasted
  /// text into one task per line through the shared BulkAdd commit, aimed at the
  /// list the composer is currently pointing at (#217). The collapsed draft is
  /// consumed, so the composer is empty and ready for the next entry.
  Future<void> _addPastedLines(String raw) async {
    final target = _quickAddTargetList;
    if (target == null) return;
    setState(() {
      _quickAdd.clear();
      _dateIgnoredFor = '';
    });
    await _commitBulkAdd(
      BulkAddResult(text: raw, mode: BulkAddMode.perLine, listId: target),
    );
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
    // ONE creation affordance per pointer class (#216): touch creates through
    // the FAB's bottom-sheet composer (thumb zone, IME pre-raised), so the
    // inline bar — which duplicated the FAB and cost a row of screen — mounts
    // on a fine pointer only. The FAB bumps [newTaskRequestProvider]; the
    // mounted list opens its sheet.
    final touch = coarsePointerPlatform(Theme.of(context).platform);
    ref.listen(newTaskRequestProvider, (previous, next) {
      if (touch && next != previous) _openQuickAddSheet();
    });
    return Column(
      children: [
        if (!touch) ...[
          _QuickAddBar(
            controller: _quickAdd,
            focusNode: quickAddFocus,
            dateIgnoredFor: _dateIgnoredFor,
            lists: _lists,
            targetListId: _quickAddTargetList,
            onTargetChanged: (id) {
              setState(() => _pickedListId = id);
              // Aiming is a detour, not a destination: hand the caret straight
              // back so the next keystroke goes into the draft.
              quickAddFocus.requestFocus();
            },
            onSubmit: _submit,
            onAddPastedLines: _addPastedLines,
            onDismissPreview: () {
              setState(() => _dateIgnoredFor = _quickAdd.text);
              quickAddFocus.requestFocus();
            },
          ),
          const Divider(height: 1),
        ],
        _ListToolbar(
          sort: sort,
          showCompleted: prefs.showCompleted,
          onSearch: _openSearch,
          onBulkAdd: _defaultTargetList == null ? null : () => _openBulkAdd(),
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

  /// Apply a drag from [oldIndex] to [newIndex] over the visible [tasks] as a
  /// SINGLE anchored reorder — one queued move, resolved against the store's own
  /// ordering by the visible neighbour the row was dropped after (G1 #202),
  /// instead of a slot index measured over the display order.
  Future<void> _onReorder(
    List<StoredTask> tasks,
    int oldIndex,
    int newIndex,
  ) async {
    final anchor = reorderAnchor(tasks, oldIndex, newIndex);
    if (anchor == null) return;
    final id = tasks[oldIndex].task.id;
    await ref.read(commandsProvider).reorderTaskAfter(id, anchor.previousId);
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
      // Straight from the ROUTER-derived selection (#221), never from a
      // tap-local field, so the highlight follows the detail through every
      // entry path — row tap, search jump, detail prev/next, the quick-add
      // follow, or a bare URL change — all of which move the route.
      openInDetail: widget.selectedTaskId == t.id,
      onSelectToggle: () => _toggleSelect(t.id),
      onContextMenu: (pos) => _showRowActions(stored, globalPosition: pos),
      onShowActions: () => _showRowActions(stored),
      editRequested: _editId == t.id,
      onEditDone: () {
        if (_editId == t.id) setState(() => _editId = null);
      },
      // So a mid-typing inline rename survives a system-back / backgrounding,
      // like the detail panel's fields (#183/G4): the registry covers
      // backgrounding, the back handle lets the shell intercept a system back.
      pendingEdits: _pendingEdits,
      onInlineEditActive: _renameBack.set,
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
///
/// A keystroke rebuilds ONLY this bar (to update the natural-language date
/// preview) — never the enclosing [TaskListView], so typing never re-runs
/// `visibleTasksForView` or the per-row effective-due/subtask-count sweep (F20
/// #199). The bar therefore owns the preview computation locally; the parent
/// keeps [_dateIgnoredFor] (mirrored in via [dateIgnoredFor]) because its submit
/// path still needs it, and re-reads the live controller text at submit time.
class _QuickAddBar extends StatefulWidget {
  const _QuickAddBar({
    required this.controller,
    required this.focusNode,
    required this.dateIgnoredFor,
    required this.lists,
    required this.targetListId,
    required this.onTargetChanged,
    required this.onSubmit,
    required this.onAddPastedLines,
    required this.onDismissPreview,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Every known list — the destinations the target picker offers (#217).
  final List<StoredTaskList> lists;

  /// The list the next add will land in (the user's pick, or the view's
  /// default). Owned by the parent, which also performs the create.
  final String? targetListId;

  /// Aim the composer at another list.
  final ValueChanged<String> onTargetChanged;

  /// The exact input text whose parsed date the user chose to keep as literal
  /// title text (the preview chip's ×), so its phrase is not re-read as a due
  /// date. Owned by the parent; changing it flows a fresh value down here.
  final String dateIgnoredFor;
  final VoidCallback onSubmit;

  /// Accept the multi-line-paste offer (#219): create one task per line of the
  /// RAW pasted text. The parent owns the create (and clears the draft).
  final ValueChanged<String> onAddPastedLines;
  final VoidCallback onDismissPreview;

  @override
  State<_QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<_QuickAddBar> {
  /// The RAW multi-line text the last paste put into an empty composer, while
  /// the offer to split it into one task per line still stands (#219); `null`
  /// when nothing is on offer.
  String? _pasteOffer;

  /// The exact draft the standing offer belongs to. Editing away from it
  /// retracts the offer — "Add as N tasks" must never describe lines the field
  /// no longer shows.
  String _offerDraft = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_retractStaleOffer);
  }

  @override
  void dispose() {
    // The controller is the parent's; only the listener is ours.
    widget.controller.removeListener(_retractStaleOffer);
    super.dispose();
  }

  /// Retract a standing paste offer as soon as the draft is no longer the text
  /// that paste produced — a keystroke, or the parent clearing the field after
  /// a submit. "Add as N tasks" must never outlive the lines it describes.
  void _retractStaleOffer() {
    if (_pasteOffer == null || widget.controller.text == _offerDraft) return;
    setState(() => _pasteOffer = null);
  }

  /// Handle a paste ourselves (#219). A single-line [TextField] runs
  /// [FilteringTextInputFormatter.singleLineFormatter] BEFORE any formatter we
  /// could add, which DELETES the newlines ("buy milk\ncall bob" →
  /// "buy milkcall bob") and destroys the line structure before anything can
  /// read it. Intercepting the paste itself — the Ctrl+V intent and the
  /// selection toolbar's Paste, the two ways text arrives from the clipboard —
  /// is what keeps the raw text intact.
  ///
  /// It reads the clipboard exactly ONCE per paste (replacing, not adding to,
  /// the framework's own read), inserts the space-collapsed text at the caret,
  /// and raises the split offer when a list landed in an empty composer.
  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text ?? '';
    if (raw.isEmpty || !mounted) return;
    final draft = widget.controller.text;
    final insert = collapsePastedLines(raw);
    final selection = widget.controller.selection;
    final valid = selection.isValid && selection.start >= 0;
    final start = valid ? selection.start : draft.length;
    final end = valid ? selection.end : draft.length;
    final text = draft.replaceRange(start, end, insert);
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    setState(() {
      // What SURVIVES the paste decides: a list pasted over an empty field (or
      // over a select-all) is a list; lines spliced into a half-typed title are
      // part of that title.
      final remainder = draft.replaceRange(start, end, '');
      _pasteOffer = offersBulkSplit(draft: remainder, raw: raw) ? raw : null;
      _offerDraft = text;
    });
  }

  /// Retract the offer (the × / "Keep as one task"): the collapsed draft stays
  /// exactly as it is, an ordinary single-task draft.
  void _dismissOffer() => setState(() => _pasteOffer = null);

  /// The offer's label — width-capped so an accessibility text scale ellipsises
  /// it rather than overflowing the phone's single composer line.
  Widget _pasteOfferLabel(int count) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 120),
    child: Text(
      'Add as $count tasks',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );

  /// The selection toolbar with its Paste button rerouted through
  /// [_handlePaste] (#219) — the only clipboard route a finger has, and the one
  /// the phone's bottom-sheet composer uses. Every other button is the
  /// platform's own.
  Widget _pasteAwareContextMenu(
    BuildContext context,
    EditableTextState editableState,
  ) => AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableState.contextMenuAnchors,
    buttonItems: [
      for (final item in editableState.contextMenuButtonItems)
        if (item.type == ContextMenuButtonType.paste)
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: () {
              editableState.hideToolbar();
              _handlePaste();
            },
          )
        else
          item,
    ],
  );

  /// The natural-language due parsed from the CURRENT input, unless the user
  /// dismissed it for this exact text. Recomputed on each local rebuild so a
  /// keystroke updates only this bar. Mirrors [_TaskListViewState._previewDue],
  /// which the parent's submit path reads from the same live controller text.
  String? get _previewDue => widget.controller.text == widget.dateIgnoredFor
      ? null
      : parseQuickAddDue(widget.controller.text);

  @override
  Widget build(BuildContext context) {
    final offer = _pasteOffer;
    final offerCount = offer == null ? 0 : splitBulkLines(offer).length;
    final preview = _previewDue;
    // One decision at a time: while the split is on offer the question is "one
    // task or N?", so the date chip stands down (it would also fight the offer
    // for the phone's single line). Declining brings it straight back — and the
    // per-line split parses each line's own date anyway.
    final hasPreview = offer == null && preview != null && preview.isNotEmpty;
    final touch = coarsePointerPlatform(Theme.of(context).platform);
    // A destination picker only earns its slot when there IS a choice: with one
    // list the default is the only answer, and dead chrome is not a feature.
    final picker = widget.lists.length > 1 && widget.targetListId != null
        ? _TargetListButton(
            lists: widget.lists,
            targetListId: widget.targetListId!,
            onChanged: widget.onTargetChanged,
            // A coarse pointer with the date chip up spends the row on the
            // chip (147dp), the 48dp × and the send button, leaving the input
            // ~125dp: a labelled picker would not fit inside it. The composer
            // sheds the destination LABEL there — never the control, whose menu
            // still shows which list is checked.
            compact: touch && (hasPreview || offer != null),
          )
        : null;
    return Padding(
      key: const Key('quick-add-bar'),
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            // Both clipboard routes are rerouted through [_handlePaste] (#219):
            // the keyboard's paste intent here (EditableText's own paste action
            // is overridable from an ancestor), and the selection toolbar's
            // Paste below. Nothing else about the field's editing changes.
            child: Actions(
              actions: <Type, Action<Intent>>{
                PasteTextIntent: CallbackAction<PasteTextIntent>(
                  onInvoke: (_) {
                    _handlePaste();
                    return null;
                  },
                ),
              },
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                decoration: InputDecoration(
                  hintText: 'Add a task',
                  // The decorative "+" yields its 48dp to the destination
                  // picker (#217) when there is one: the picker carries its own
                  // icon and sits on the same line, so the composer says "add"
                  // once and the input keeps exactly the room it had. With a
                  // single list there is nothing to pick and the "+" stays.
                  prefixIcon: picker == null ? const Icon(Icons.add) : null,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                contextMenuBuilder: _pasteAwareContextMenu,
                // Rebuild THIS bar only, to refresh the date preview — the task
                // list is untouched by a keystroke (F20 #199).
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => widget.onSubmit(),
              ),
            ),
          ),
          if (offer != null) ...[
            const SizedBox(width: 8),
            // The offer itself (#219). Same idiom — and same footprint — as the
            // date chip it stands in for: an action plus a dismiss, so the
            // composer never grows a second line. The label is width-capped so
            // an accessibility text scale ellipsises it instead of overflowing
            // the phone row.
            if (touch) ...[
              // ELEVATED, unlike the flat date chip in the same slot: this one
              // is pressable, and a filled, raised surface is what says so at a
              // glance (an outlined chip beside an outlined field reads as a
              // label). No width is spent on a leading icon — the phone row has
              // none to spare.
              ActionChip.elevated(
                key: const Key('quick-add-paste-split'),
                label: _pasteOfferLabel(offerCount),
                onPressed: () => widget.onAddPastedLines(offer),
              ),
              IconButton(
                key: const Key('quick-add-paste-split-dismiss'),
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Keep as one task',
                onPressed: _dismissOffer,
              ),
            ] else
              // The mouse keeps the compact inline form: a hover highlight and
              // a pointer cursor already say "pressable", so no elevation is
              // needed to earn the row's width back.
              InputChip(
                key: const Key('quick-add-paste-split'),
                label: _pasteOfferLabel(offerCount),
                onPressed: () => widget.onAddPastedLines(offer),
                deleteIcon: const Icon(
                  Icons.close,
                  size: 18,
                  key: Key('quick-add-paste-split-dismiss'),
                ),
                deleteButtonTooltipMessage: 'Keep as one task',
                onDeleted: _dismissOffer,
              ),
          ],
          if (hasPreview) ...[
            const SizedBox(width: 8),
            // The chip renders a FRIENDLY relative date, never the raw ISO
            // (#78b); its × keeps the phrase as literal title text. On a touch
            // pointer the InputChip's built-in delete glyph is a sub-48dp target,
            // so the × becomes a standalone 48dp IconButton beside a plain chip
            // (F19 #198); the mouse keeps the compact inline InputChip.
            if (touch) ...[
              // The label is width-capped so the chip cannot grow without
              // bound at an accessibility text scale: at 2.0 an uncapped
              // "Aug 15, 2027" pushed the chip past 230dp and overflowed the
              // row once the destination picker joined it. Every label
              // [formatDue] produces fits inside the cap at normal scale, so
              // nothing truncates until the font is enlarged.
              Chip(
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    formatDue(preview),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Keep as text',
                onPressed: widget.onDismissPreview,
              ),
            ] else
              InputChip(
                label: Text(formatDue(preview)),
                deleteIcon: const Icon(Icons.close, size: 18),
                deleteButtonTooltipMessage: 'Keep as text',
                onDeleted: widget.onDismissPreview,
              ),
          ],
          // The destination sits between the draft and the send button, so the
          // row reads "<title> → <list> ↑" (#217).
          if (picker != null) ...[const SizedBox(width: 4), picker],
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Add task',
            icon: const Icon(Icons.arrow_upward),
            onPressed: widget.onSubmit,
          ),
        ],
      ),
    );
  }
}

/// The quick-add's target-list picker (#217) — a compact anchored menu naming
/// where the next add lands, and retargeting it in one tap WITHOUT costing the
/// composer a second line (the ratified mobile constraint).
///
/// The pick is transient by design: it survives consecutive adds but is never
/// written to prefs and resets when the view changes, so the composer's aim is
/// always either "here" or something the user set moments ago.
class _TargetListButton extends StatelessWidget {
  const _TargetListButton({
    required this.lists,
    required this.targetListId,
    required this.onChanged,
    required this.compact,
  });

  final List<StoredTaskList> lists;

  /// The list the next add lands in — checked in the menu, named on the button.
  final String targetListId;
  final ValueChanged<String> onChanged;

  /// Drop the label and show the icon alone (a crowded phone row).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final title = lists
        .firstWhere((l) => l.list.id == targetListId, orElse: () => lists.first)
        .list
        .title;
    // The menu never claims more height than the screen leaves once the soft
    // keyboard is up — the composer is ALWAYS typed into, so an uncapped menu
    // over a long list of lists puts its last entries behind the IME where no
    // finger can reach them. Capped, it scrolls instead.
    final media = MediaQuery.of(context);
    final maxMenuHeight = media.size.height - media.viewInsets.bottom - 64;
    return MenuAnchor(
      style: MenuStyle(
        maximumSize: WidgetStatePropertyAll(
          Size.fromHeight(maxMenuHeight.clamp(96.0, double.infinity)),
        ),
      ),
      menuChildren: [
        for (final l in lists)
          MenuItemButton(
            key: Key('quick-add-list-${l.list.id}'),
            leadingIcon: l.list.id == targetListId
                ? const Icon(Icons.check, size: 18)
                : const SizedBox(width: 18),
            onPressed: () => onChanged(l.list.id),
            child: Text(l.list.title),
          ),
      ],
      builder: (context, controller, _) => Tooltip(
        // The compact form is icon-only, so the destination has to be readable
        // some other way: hover on the desktop, long-press on a phone, and the
        // screen-reader label either way.
        message: 'Add to list: $title',
        child: ConstrainedBox(
          // The label truncates rather than pushing the input out of the row.
          constraints: BoxConstraints(maxWidth: compact ? 48 : 132),
          child: TextButton(
            key: const Key('quick-add-list-picker'),
            style: TextButton.styleFrom(
              // A finger-sized target on the composer's single line.
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.playlist_add, size: 20),
                if (!compact) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
