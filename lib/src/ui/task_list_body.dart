// The scrollable task list itself (#274, split out of the orchestrator): the
// rows, their choreography, the drag-reorder, the Focus view's "Overdue (N)"
// bucket, the empty state, the first-snapshot gate, and the phone's
// pull-to-refresh.
//
// It is a widget of its own for one reason beyond size: a row reporting that
// its motion has finished, or an inline rename opening, is a change to the LIST
// and to nothing else. Held in the pane, each of those `setState`s rebuilt the
// composer, the toolbar and the bulk bar as well — and re-ran the view's whole
// row derivation. Held here, over a memoised [visibleRowsProvider], they rebuild
// the rows and stop there.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/logging.dart' show Log;
import '../app/pending_edits.dart';
import '../app/providers.dart';
import '../model/task.dart';
import '../model/task_view.dart';
import '../store/stored.dart';
import 'completion_motion.dart';
import 'date_format.dart';
import 'drag_lift.dart' show dragLiftProxyDecorator;
import 'empty_state.dart';
import 'first_snapshot.dart';
import 'haptics.dart';
import 'list_choreographer.dart';
import 'list_detail_scaffold.dart' show ListDetailScaffold;
import 'list_motion.dart';
import 'new_task_fab.dart' show NewTaskFab;
import 'row_actions.dart' show TaskRowActions;
import 'selection_controller.dart';
import 'state_layer.dart';
import 'task_row.dart';
import 'theme.dart';
import 'visible_rows.dart';

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

/// The list body for one view.
class TaskListBody extends ConsumerStatefulWidget {
  const TaskListBody({
    required this.viewId,
    required this.selectedTaskId,
    required this.selection,
    required this.choreographer,
    required this.actions,
    required this.editRequest,
    required this.haptics,
    required this.pendingEdits,
    required this.onInlineEditActive,
    super.key,
  });

  final String viewId;

  /// The task the detail panel currently shows — the ROUTER-derived selection
  /// (#221), so the open-row highlight follows the detail through every entry
  /// path.
  final String? selectedTaskId;

  final SelectionController selection;
  final ListChoreographer choreographer;
  final TaskRowActions actions;

  /// The row the context menu's "Edit title" has asked to open inline. Held by
  /// the pane (the menu lives there) and read here; a [ValueNotifier] rather
  /// than a callback so opening an editor rebuilds the LIST and nothing above
  /// it.
  final ValueNotifier<String?> editRequest;

  final Haptics haptics;

  /// So a mid-typing inline rename survives a system-back / backgrounding, like
  /// the detail panel's fields (#183/G4).
  final PendingEdits pendingEdits;

  /// Publish/retract this list's open inline editor to the shell's back ladder.
  final void Function(VoidCallback? commit) onInlineEditActive;

  @override
  ConsumerState<TaskListBody> createState() => _TaskListBodyState();
}

class _TaskListBodyState extends ConsumerState<TaskListBody> {
  @override
  void initState() {
    super.initState();
    // Selection and the open inline editor both change how ROWS render and
    // nothing else — so they rebuild this list, never the pane above it.
    widget.selection.addListener(_rebuild);
    widget.editRequest.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(covariant TaskListBody old) {
    super.didUpdateWidget(old);
    if (old.selection != widget.selection) {
      old.selection.removeListener(_rebuild);
      widget.selection.addListener(_rebuild);
    }
    if (old.editRequest != widget.editRequest) {
      old.editRequest.removeListener(_rebuild);
      widget.editRequest.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.selection.removeListener(_rebuild);
    widget.editRequest.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// Run a manual refresh (mobile pull-to-refresh): a real sync when a session
  /// is live, else a no-op over the always-live reactive store — handed off to
  /// the quiet sync line (#255).
  ///
  /// The gesture's own spinner retires the moment the run is actually UNDER
  /// WAY, and the 2dp line on the app bar's edge carries it from there — so a
  /// manual pull and the 60s poll are ONE thing on screen rather than a spinner
  /// turning beside a line for the same sync.
  ///
  /// RACED against the refresh itself, because not every refresh raises a run:
  /// signed out it is a documented no-op, and in a tree with no runtime mounted
  /// the run stream never emits at all. Whichever happens first ends the
  /// gesture, so the spinner can never be left turning forever.
  Future<void> _pullRefresh() async {
    final started = Completer<void>();
    final handoff = ref.listenManual<bool>(syncRunningProvider, (_, running) {
      if (running && !started.isCompleted) started.complete();
    });
    // The runtime's refresh already logs and sanitizes its own failures into the
    // status the footer renders. Once the line has taken over we stop awaiting
    // this future, so it needs its own handler or a late throw would escape as
    // an unhandled async error with nothing left to catch it.
    final refresh = ref
        .read(refreshActionProvider)()
        .catchError((Object e) => Log.warn('pull-to-refresh failed: $e'));
    try {
      await Future.any([refresh, started.future]);
    } finally {
      handoff.close();
    }
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
    // A drop that changes nothing — back where it started, or across nothing but
    // other lists' cards — is not a landing: no write, and nothing to say
    // (#256).
    if (anchor == null) return;
    final id = tasks[oldIndex].task.id;
    await ref.read(commandsProvider).reorderTaskAfter(id, anchor.previousId);
    // A reorder is the one confirmed write that changes no FIELD of the task, so
    // the choreographer's commit detection cannot see it: the row is flashed
    // from here instead, over the whole row, because its new place is what
    // changed about it (#252/#256).
    //
    // Only once the row is back in the list. While the drop animation runs the
    // reorderable builds the dragged slot as an empty box and re-creates the
    // row's subtree when the proxy goes away — a commit published before that
    // frame would be handed to a widget about to be replaced by one that has
    // never seen it, and #252's already-played guard would swallow the flash.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(() => widget.choreographer.flashRow(id));
  }

  /// The Focus view's "Overdue (N)" section heading — a small, bold label in the
  /// shared overdue tone (#242), naming the count of overdue cards below it
  /// (F17). Rendered only when there is at least one overdue card.
  Widget _overdueHeading(int count) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('overdue-heading'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        'Overdue ($count)',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: dueColor(DueUrgency.overdue, scheme),
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  /// Wrap [row] with the inter-bucket gap when it is the FIRST row after the
  /// overdue bucket (Focus's dated bucket starts at index [overdueCount]), so
  /// the two buckets read as distinct groups; otherwise return [row] as-is. The
  /// per-item key the reorderable list requires sits on the enclosing
  /// [CompletionMotion], so the gap folds away with the row it belongs to.
  Widget _bucketSpaced(Widget row, int taskIndex, int overdueCount) {
    final firstRest = overdueCount > 0 && taskIndex == overdueCount;
    if (!firstRest) return row;
    return Padding(padding: const EdgeInsets.only(top: 10), child: row);
  }

  /// Wrap one list item in its choreography — the #251 enter/leave outside, the
  /// #241 completion sequence inside — keyed by [key] (the task's own id) so a
  /// row that folds away and comes back keeps its own animation, and so a create
  /// landing on Google never looks like a fresh arrival.
  Widget _motion(
    RowItem item,
    Key key,
    Widget Function(Animation<double> completion) builder,
  ) {
    final id = item.id;
    final choreo = widget.choreographer;
    return RowMotion(
      key: key,
      entering: item.motion == SlotMotion.entering,
      leaving: item.motion == SlotMotion.leaving,
      delay: item.delay,
      // Clearing an arrival changes nothing on screen (the flag is read only
      // while the row is growing), so it needs no rebuild.
      onEntered: () => choreo.entered(id),
      onLeft: () {
        if (choreo.left(id)) setState(() {});
      },
      child: CompletionMotion(
        completed: item.row.stored.task.status == TaskStatus.completed,
        departing: item.motion == SlotMotion.completing,
        returning: choreo.isReturning(id),
        onDeparted: () {
          if (choreo.departed(id)) setState(() {});
        },
        onReturned: () => choreo.returned(id),
        builder: (context, completion) => builder(completion),
      ),
    );
  }

  /// One [TaskRow] for [data], wired to selection, the action surface, inline
  /// rename, and the quick-date/date-picker/URL affordances.
  Widget _taskRow(TaskRowData data, Animation<double> completion) {
    final stored = data.stored;
    final t = stored.task;
    final a = widget.actions;
    // The Builder is here for ONE reason: a context whose render object is this
    // row, so the open handler can record where the row was before navigating
    // away (#253). It is the only place that knows both the rect and the task
    // id. No render object of its own, so it changes neither layout nor paint,
    // and the surrounding slot is already keyed, so it costs no row identity.
    return Builder(
      builder: (rowContext) => TaskRow(
        key: ValueKey(t.id),
        title: t.title,
        notes: t.notes,
        completed: t.status == TaskStatus.completed,
        due: t.due,
        inheritedDue: data.inheritedDue,
        pendingSync: stored.syncState == SyncState.dirty,
        subtaskDone: data.subtaskDone,
        subtaskTotal: data.subtaskTotal,
        listTag: data.listTag,
        selected: widget.selection.contains(t.id),
        selectionActive: widget.selection.active,
        // Straight from the ROUTER-derived selection (#221), never from a
        // tap-local field, so the highlight follows the detail through every
        // entry path — row tap, search jump, detail prev/next, the quick-add
        // follow, or a bare URL change — all of which move the route.
        openInDetail: widget.selectedTaskId == t.id,
        onSelectToggle: () => a.selectToggle(t.id),
        onContextMenu: (pos) => a.contextMenu(stored, pos),
        editRequested: widget.editRequest.value == t.id,
        onEditDone: () => a.editDone(t.id),
        // So a mid-typing inline rename survives a system-back / backgrounding,
        // like the detail panel's fields (#183/G4): the registry covers
        // backgrounding, the back handle lets the shell intercept a system back.
        pendingEdits: widget.pendingEdits,
        onInlineEditActive: widget.onInlineEditActive,
        onOpen: () => a.open(rowContext, stored),
        onToggle: () => a.toggle(stored),
        onRename: (v) => a.rename(t.id, v),
        onSetDue: (m) => a.setDue(t.id, m),
        onPickDate: () => a.pickDate(stored),
        onOpenUrl: a.openUrl,
        completionProgress: completion,
        commit: widget.choreographer.commitFor(t.id),
        // The row reports ONE event itself: a swipe crossing its action
        // threshold, which happens while the finger is still down (#257).
        haptics: widget.haptics,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(visibleRowsProvider(widget.viewId));
    // Hold on to the rows that just left the filtered list so they can fold away
    // instead of vanishing (#241 for a completion, #251 for every other exit),
    // and mark the ones that just arrived so they grow into place.
    final items = widget.choreographer.choreograph(
      visible: view.rows,
      byId: view.byId,
      hasData: view.hasData,
      now: WidgetsBinding.instance.currentFrameTimeStamp,
    );
    final tasks = view.stored;
    final overdueCount = view.overdueCount;

    final mobile =
        MediaQuery.sizeOf(context).width < ListDetailScaffold.breakpoint;
    final physics = mobile ? const AlwaysScrollableScrollPhysics() : null;
    // The "new task" FAB floats over the bottom of the list; pad the scroll so
    // the LAST row can clear it (never hidden under the FAB — #234). The
    // padding tracks the FAB exactly: the shell builds one only in the compact
    // layout, and only for a coarse pointer (#216), so a narrow mouse-driven
    // window spends no room on a clearance it does not need.
    final listPadding =
        mobile && coarsePointerPlatform(Theme.of(context).platform)
        ? const EdgeInsets.only(bottom: NewTaskFab.clearance)
        : EdgeInsets.zero;

    // The heading is present only when there ARE overdue cards to head; it then
    // shifts every row down one slot in the list's index space.
    final headerOffset = overdueCount > 0 ? 1 : 0;

    // Item index → the index the row holds among the LIVE ones. Collapsing rows
    // occupy a list slot but no place in the task order, so every index the list
    // hands back (a drag, a bucket boundary) is translated through this.
    final liveIndex = <int>[];
    var live = 0;
    for (final item in items) {
      liveIndex.add(live);
      if (!item.departing) live++;
    }

    final Widget content;
    if (items.isEmpty) {
      // Scrollable on EVERY layout, and for two reasons at once: on a phone a
      // full-height scroll view is what lets an over-pull arm the refresh over
      // an empty list, and everywhere it is what keeps the state from
      // overflowing when the system text scale turns an icon and two lines into
      // more than the pane is tall (#247's rule, #260's surface).
      content = LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          physics: physics,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            // Keyed by view: switching from one empty view to another is
            // ENTERING a state, and the icon that names it arrives with it.
            child: EmptyStateView(
              key: ValueKey('empty-${widget.viewId}'),
              viewId: widget.viewId,
            ),
          ),
        ),
      );
    } else if (view.sort == SortMode.manual) {
      // Drag reorder rides ONLY the manual sort (backend position); the other
      // sorts derive their order, so reordering them is meaningless (the
      // reference disables it too).
      content = ReorderableListView.builder(
        buildDefaultDragHandles: false,
        // The lift is felt under the finger the moment the row detaches, and the
        // drop when it lands — the two ends of a gesture the user cannot
        // otherwise confirm without watching the screen (#257).
        onReorderStart: (_) => widget.haptics.tick(),
        onReorderEnd: (_) => widget.haptics.tick(),
        // The row under the finger takes the app's one lift (#256); the
        // framework's edge auto-scroll is left at its default, so a target below
        // the fold is still reachable.
        proxyDecorator: dragLiftProxyDecorator,
        physics: physics,
        padding: listPadding,
        itemCount: items.length + headerOffset,
        // Drag indices are in list-item space (the heading is item 0, and a
        // collapsing row still holds a slot); map them back to indices in the
        // live task order, clamping a drop above the heading to the top row.
        onReorderItem: (oldIndex, newIndex) => _onReorder(
          tasks,
          liveIndex[(oldIndex - headerOffset).clamp(0, items.length - 1)],
          liveIndex[(newIndex - headerOffset).clamp(0, items.length - 1)].clamp(
            0,
            tasks.length - 1,
          ),
        ),
        itemBuilder: (context, i) {
          if (headerOffset == 1 && i == 0) {
            // A non-draggable heading (no ReorderableDragStartListener) — it
            // stays put while the overdue rows drag around it.
            return _overdueHeading(overdueCount);
          }
          final item = items[i - headerOffset];
          return _motion(item, ValueKey('reorder-${item.id}'), (completion) {
            final handle = dragHandleCursor(
              child: SizedBox(
                key: ValueKey('drag-handle-${item.id}'),
                // A comfortable drag target for both a mouse and a finger
                // (touch-drag rides the same handle); the glyph stays small, the
                // HIT AREA is 48dp tall.
                width: 36,
                height: 48,
                child: Icon(
                  Icons.drag_indicator,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            );
            final row = Row(
              // Top-aligned, so the 48dp handle box centres on the row's TITLE
              // line exactly as the checkbox beside it does (#276). Centred on
              // the two-line row it pointed at the gap between the lines and
              // sat 12dp below the checkbox it shares a column with.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A row that is folding away is no longer a drag target — it is
                // leaving — but it keeps the handle's WIDTH so its title does
                // not slide sideways as it goes.
                if (item.departing)
                  handle
                else
                  ReorderableDragStartListener(index: i, child: handle),
                Expanded(child: _taskRow(item.row, completion)),
              ],
            );
            return _bucketSpaced(
              row,
              liveIndex[i - headerOffset],
              overdueCount,
            );
          });
        },
      );
    } else {
      content = ListView.builder(
        physics: physics,
        padding: listPadding,
        itemCount: items.length + headerOffset,
        itemBuilder: (context, i) {
          if (headerOffset == 1 && i == 0) return _overdueHeading(overdueCount);
          final ti = i - headerOffset;
          final item = items[ti];
          return _motion(
            item,
            ValueKey('row-${item.id}'),
            (completion) => _bucketSpaced(
              _taskRow(item.row, completion),
              liveIndex[ti],
              overdueCount,
            ),
          );
        },
      );
    }

    // Nothing on this pane may claim the store said something it has not said
    // yet: until the first snapshot lands the gate holds the pane, and past the
    // grace it shows skeleton rows rather than a spinner (#260).
    // The gate opens on the first snapshot and never closes again: an empty
    // view is a state the store HAS reported, not a store that has said
    // nothing.
    final gated = FirstSnapshotGate(
      hasData: widget.choreographer.seenContents,
      child: content,
    );
    if (!mobile) return gated;
    return RefreshIndicator(
      onRefresh: _pullRefresh,
      // The gesture's indicator and the line it hands off to (#255) are one
      // piece of feedback, so they are one colour — the app's primary, stated
      // here rather than inherited from whatever Material defaults to next.
      color: Theme.of(context).colorScheme.primary,
      child: gated,
    );
  }
}
