// The list pane for one view — the ORCHESTRATOR (#274).
//
// It owns nothing that renders a row and nothing that writes a task. Its whole
// job is to hold the pieces together for one view and hand each of them what it
// needs:
//
//   • the composer lives ABOVE this pane ([ComposerHost]), because a view
//     switch mounts two panes and there must never be two composers;
//   • the rows come from the memoised [visibleRowsProvider], so a pane rebuild
//     never re-derives them;
//   • the choreography lives in [ListChoreographer] and is played by
//     [TaskListBody], so a row finishing its motion never rebuilds this pane;
//   • the multi-selection lives in [SelectionController], the whole-selection
//     actions in [BulkOps], the per-row ones in [RowActions];
//   • the list-wide actions are ONE value-equal [ListChromeActions], rendered
//     either by this pane's [ListToolbar] or by the compact shell's app bar
//     (#244) — never both.
//
// Navigation is injected ([onOpenTask]) and the current selection passed in
// ([selectedTaskId]) so this widget is testable without a router; the router
// wiring lives in ViewListPane.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/pending_edits.dart';
import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../model/task.dart';
import '../model/task_view.dart';
import '../store/stored.dart';
import 'bulk_bar.dart';
import 'bulk_ops.dart';
import 'compact_chrome.dart';
import 'composer_controller.dart';
import 'detail_motion.dart';
import 'haptics.dart';
import 'list_choreographer.dart';
import 'list_toolbar.dart';
import 'row_actions.dart';
import 'search.dart';
import 'selection_controller.dart';
import 'sync_feedback.dart';
import 'task_list_body.dart';
import 'theme.dart';
import 'toast.dart';
import 'url_opener.dart';
import 'views.dart';

export 'task_list_body.dart' show reorderAnchor;

/// The task list for [viewId], its toolbar, and its bulk bar.
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

  /// The task the detail panel currently shows, or `null` when it is closed.
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
  /// The current multi-select (BulkOps). Selection mode is entered by the
  /// toolbar's "Select tasks" (#245) as well as by picking a row, so it is a
  /// flag of its own rather than "something is selected".
  final SelectionController _selection = SelectionController();

  /// The list's motion bookkeeping (#241/#251/#252).
  final ListChoreographer _choreographer = ListChoreographer();

  /// The row the context menu's "Edit title" asked to open inline.
  final ValueNotifier<String?> _editRequest = ValueNotifier(null);

  /// The app-wide pending-edits registry, captured in initState so the body can
  /// register a row's inline rename without an unsafe `ref` lookup (#183).
  late final PendingEdits _pendingEdits;

  /// The shell's inline-rename back-handle (G4 #183), captured so a row can
  /// publish/retract its open editor without a `ref` lookup at call time.
  late final RenameBackHandle _renameBack;

  bool get _isSmartView => SmartView.byId(widget.viewId) != null;

  Haptics get _haptics => ref.read(hapticsProvider);

  @override
  void initState() {
    super.initState();
    _pendingEdits = ref.read(pendingEditsProvider);
    _renameBack = ref.read(renameBackHandleProvider.notifier);
    // Reset the back ladder's view of the selection and of any open inline
    // editor for this freshly-mounted view: a stale claim from the view the
    // user just left must not deaden the back button. Scheduled after the first
    // frame so it never modifies a provider mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncBackHandle();
      _renameBack.set(null);
    });
    // The pane's own chrome reads the selection too — "Select tasks" greys out
    // once the mode is on (#245) — so it rebuilds with it. Cheap now that the
    // row derivation is memoised behind [visibleRowsProvider]: this rebuild
    // re-renders a toolbar, it does not re-filter a task set.
    _selection.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(covariant TaskListView old) {
    super.didUpdateWidget(old);
    // The shell keys this widget per view (so a switch usually remounts); this
    // covers the in-place update too, so the contract does not depend on the
    // key. Another view's rows are not this view's rows arriving and leaving.
    if (old.viewId != widget.viewId) _choreographer.reset();
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    _editRequest.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    _syncBackHandle();
    if (mounted) setState(() {});
  }

  /// Publish this view's selection liveness to the shell's back-precedence
  /// ladder (T8.3) — non-empty means a back should clear it rather than exit.
  void _syncBackHandle() => ref
      .read(selectionBackHandleProvider.notifier)
      .set(_selection.active ? _selection.clear : null);

  // The toolbar handlers below are METHODS, not closures built in `build`, so
  // that the [ListChromeActions] the compact shell renders (#244) compares
  // equal across rebuilds — two tear-offs of the same method on the same object
  // are equal, two closure literals never are.

  /// Set the sort order of the current view.
  void _setSort(SortMode mode) =>
      ref.read(prefsControllerProvider.notifier).setSort(widget.viewId, mode);

  /// Show or hide completed tasks across the views.
  void _setShowCompleted(bool value) =>
      ref.read(prefsControllerProvider.notifier).setShowCompleted(value);

  /// Enter multi-select with nothing selected — the toolbar's "Select tasks".
  void _enterSelectionMode() => _selection.enter();

  /// Open the bulk-add dialog on this view's default target list.
  void _openBulkAddDefault() => ComposerScope.of(context).openBulkAdd(context);

  /// Open the live search over EVERY task. Selecting a result navigates to it —
  /// a matched subtask lands on its parent's list so it opens in context (#92).
  Future<void> _openSearch() async {
    final all =
        ref.read(allTasksProvider).asData?.value ?? const <StoredTask>[];
    final lists =
        ref.read(listsProvider).asData?.value ?? const <StoredTaskList>[];
    final listTitles = {for (final l in lists) l.list.id: l.list.title};
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

  /// Confirm, then permanently clear the completed tasks in the current list.
  /// Destructive and NOT undoable, so it goes behind a styled confirm naming the
  /// count (the reference's clear-completed flow). Only reachable on a concrete
  /// list view with completed tasks visible (see the toolbar gating).
  Future<void> _confirmClearCompleted() async {
    final listId = widget.viewId;
    final all =
        ref.read(allTasksProvider).asData?.value ?? const <StoredTask>[];
    final count = all
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

  // [_rowActions] and [_bulkOps] are built ON DEMAND, inside the callback that
  // needs one — never in `build`. Both read the command layer, and a pane that
  // is only being LAID OUT (a golden, a layout test, the shell's own metrics
  // pass) has no business touching it; constructing them lazily keeps the store
  // out of the render path entirely.

  /// The per-row action surface, over the current task set.
  RowActions _rowActions(List<StoredTask> all, List<StoredTaskList> lists) =>
      RowActions(
        commands: ref.read(commandsProvider),
        toasts: ref.read(toastControllerProvider),
        haptics: _haptics,
        selection: _selection,
        lists: lists,
        allTasks: all,
        openUrl: ref.read(urlOpenerProvider),
        alive: () => mounted,
        onRequestEdit: (id) => _editRequest.value = id,
        onOpenTask: widget.onOpenTask,
        onOpenTaskNotes: widget.onOpenTaskNotes ?? widget.onOpenTask,
      );

  /// The whole-selection action surface.
  BulkOps _bulkOps(List<StoredTask> all, List<StoredTaskList> lists) => BulkOps(
    commands: ref.read(commandsProvider),
    toasts: ref.read(toastControllerProvider),
    haptics: _haptics,
    selection: _selection,
    // Indexed once per op, not once per build: `complete` and `duplicate` ask
    // after a row by id, and a phone with a large account must not pay for the
    // index on a frame that only re-renders a toolbar.
    byId: {for (final t in all) t.task.id: t},
    lists: lists,
    expectChanges: _choreographer.expectBulkChanges,
    alive: () => mounted,
  );

  @override
  Widget build(BuildContext context) {
    // The pane needs the RAW inputs, not the derived rows: the full task set
    // for the action surfaces, the lists for the menus, and the sort for the
    // toolbar. Watching them directly leaves [visibleRowsProvider] with ONE
    // listener — the body — so the derivation is computed once per change and
    // read by the surface that actually renders rows.
    final all =
        ref.watch(allTasksProvider).asData?.value ?? const <StoredTask>[];
    final lists =
        ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];
    final prefs = ref.watch(prefsControllerProvider);
    final showCompleted = prefs.showCompleted;
    final sort = SortMode.byId(prefs.sortPerView[widget.viewId]);
    final composer = ComposerScope.maybeOf(context);
    final touch = coarsePointerPlatform(Theme.of(context).platform);

    // The list-wide actions, wherever they end up rendering. Every callback is
    // a METHOD TEAR-OFF, never a closure literal: [ListChromeActions] is
    // value-equal, and equal tear-offs are what keep a republish from looking
    // like a change to the hosting app bar (see compact_chrome.dart).
    final actions = ListChromeActions(
      sort: sort,
      showCompleted: showCompleted,
      onSearch: _openSearch,
      // The VISIBLE touch entry into multi-select (#245). A mouse already has
      // two (Ctrl-click and the right-click menu's "Select"), so the overflow —
      // and the extra 48dp it costs — is a coarse-pointer affordance only,
      // exactly like the swipe actions. It stays MOUNTED once selection mode is
      // on (merely disabled): a control that vanishes when used would re-flow
      // the toolbar under the finger that just tapped it.
      selectTasksEnabled: !_selection.active,
      onSelectTasks: touch ? _enterSelectionMode : null,
      onBulkAdd: composer == null || composer.defaultTargetIn(lists) == null
          ? null
          : _openBulkAddDefault,
      onSort: _setSort,
      onShowCompleted: _setShowCompleted,
      // Clear-completed is a concrete-list-only action, and only while completed
      // tasks are visible (you cannot bulk-delete what you cannot see). Smart
      // views (aggregating across lists) never offer it.
      onClearCompleted: showCompleted && !_isSmartView
          ? _confirmClearCompleted
          : null,
    );
    // Hosted by the compact shell? Then it owns the bar these actions live in
    // (#244). Published after the frame: a provider/notifier written mid-build
    // would drive a rebuild of a tree that is still building.
    final chrome = CompactChromeScope.maybeOf(context);
    if (chrome != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) chrome.publish(actions);
      });
    }

    return Column(
      children: [
        // The compact shell hosts these actions in its ONE app bar (#244); on
        // every other layout they are this pane's own toolbar. Never both.
        if (chrome == null)
          // The expanded layout has no app bar, so this pane's top chrome IS
          // one: the quiet sync line rides the toolbar's bottom edge here
          // (#255). A Stack, never another Column child — the line is painted
          // over the divider and moves nothing.
          Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [ListToolbar(actions), const Divider(height: 1)],
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LiveSyncLine(),
              ),
            ],
          ),
        // The bar's own slot: it collapses its height in and out (#265), so the
        // rows below make room for it rather than being shoved a bar's worth in
        // one frame. Always mounted, zero-height when there is no selection.
        BulkBarSlot(
          shown: _selection.active,
          builder: (context) => BulkBar(
            count: _selection.count,
            onComplete: () => _bulkOps(all, lists).complete(),
            onSetDue: (move) => _bulkOps(all, lists).setDue(move),
            onPickDue: () => _bulkOps(all, lists).pickDue(context),
            onMove: () => _bulkOps(all, lists).move(context),
            onDuplicate: () => _bulkOps(all, lists).duplicate(),
            // Hidden outright when no single task can host the whole
            // selection. Asked of the ROWS, not of a command-backed op, so
            // the question costs no store access.
            onDemote: bulkDemoteCandidates(_selection.ids, all).isEmpty
                ? null
                : () => _bulkOps(all, lists).demote(context),
            onDelete: () => _bulkOps(all, lists).delete(),
            onClear: _selection.clear,
          ),
        ),
        Expanded(
          child: TaskListBody(
            viewId: widget.viewId,
            selectedTaskId: widget.selectedTaskId,
            selection: _selection,
            choreographer: _choreographer,
            editRequest: _editRequest,
            haptics: _haptics,
            pendingEdits: _pendingEdits,
            onInlineEditActive: _renameBack.set,
            actions: TaskRowActions(
              toggle: (stored) => _rowActions(all, lists).toggle(stored),
              open: (rowContext, stored) {
                // Before the navigation, while the row is still laid out: the
                // rect the compact detail grows out of (#253). An open reached
                // any other way — search, quick-add follow, a bare URL change —
                // records nothing, and the detail fades in rather than
                // pretending it came from a row.
                DetailOriginScope.maybeOf(
                  rowContext,
                )?.report(stored.task.id, rowContext);
                widget.onOpenTask(stored.task.id);
              },
              contextMenu: (stored, pos) =>
                  _rowActions(all, lists).showMenu(context, stored, pos),
              selectToggle: (id) {
                // Joining or leaving a selection is the same small event.
                _haptics.tick();
                _selection.toggle(id);
              },
              rename: (id, title) =>
                  ref.read(commandsProvider).renameTask(id, title),
              setDue: (id, move) => _rowActions(all, lists).quickDue(id, move),
              pickDate: (stored) => _rowActions(
                all,
                lists,
              ).pickDue(context, stored.task.id, stored.task.due),
              openUrl: (url) => ref.read(urlOpenerProvider)(url),
              editDone: (id) {
                if (_editRequest.value == id) _editRequest.value = null;
              },
            ),
          ),
        ),
      ],
    );
  }
}
