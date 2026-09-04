// What the list actually renders for a view, derived ONCE per data change
// (#274).
//
// Producing a view's rows is not cheap: every task is filtered by the view's
// predicate, sorted, swept for each parent's inherited date (the effective-due
// pass runs over the FULL set, subtasks included) and for its subtask progress
// counts, and — on Focus — partitioned into the overdue bucket and the rest.
// That used to run inside the list pane's `build`, which meant it ran again
// every time the pane called `setState` for something that is not list data at
// all: a row selected, an inline rename opened, a row finishing its collapse,
// a commit flash landing.
//
// Here it is a memoised [Provider.family] keyed by view id, so it recomputes
// only when the tasks, the lists, the prefs, or the just-created pin move. A
// pane interaction costs nothing, and two panes mounted at once (a view switch
// cross-fade) derive once each rather than once per rebuild.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/prefs_controller.dart';
import '../app/providers.dart';
import '../model/effective_due.dart';
import '../model/task.dart';
import '../model/task_view.dart';
import '../store/stored.dart';
import 'views.dart';

/// The id of the task created most recently from the composer, pinned to the
/// top of the view it landed in until the view changes (#274 moved it out of
/// the pane's `State` because the composer now outlives the pane).
class NewestTask extends Notifier<String?> {
  @override
  String? build() => null;

  /// Pin [id] to the top of the current view.
  void pin(String id) => state = id;

  /// Drop the pin — the view changed, so "just created here" is no longer true.
  void clear() => state = null;
}

final newestTaskProvider = NotifierProvider<NewestTask, String?>(
  NewestTask.new,
);

/// One rendered row: the stored task plus everything the row needs that can
/// only be known by looking at the WHOLE task set.
///
/// Derived in one sweep rather than looked up per row — the inherited date and
/// the subtask counts are both properties of a parent's children, and the list
/// tag is a property of the view.
class TaskRowData {
  const TaskRowData({
    required this.stored,
    this.inheritedDue,
    this.subtaskDone = 0,
    this.subtaskTotal = 0,
    this.listTag,
  });

  final StoredTask stored;

  String get id => stored.task.id;

  /// The earliest unfinished-subtask date this parent shows in grey when it has
  /// no date of its own; `null` when nothing is inherited.
  final String? inheritedDue;

  final int subtaskDone;
  final int subtaskTotal;

  /// The list this row lives in, named on the row — only in a cross-list view
  /// (F18); `null` in a concrete list view, where every row shares one home.
  final String? listTag;

  /// The same row carrying a fresher [stored] snapshot — how a row that has
  /// just LEFT the filtered list is drawn with its current state (a completed
  /// row folds away ticked) without re-running the sweep for it.
  TaskRowData withStored(StoredTask next) => TaskRowData(
    stored: next,
    inheritedDue: inheritedDue,
    subtaskDone: subtaskDone,
    subtaskTotal: subtaskTotal,
    listTag: listTag,
  );
}

/// Everything a view's list body renders from.
class VisibleRows {
  const VisibleRows({
    required this.rows,
    required this.overdueCount,
    required this.sort,
    required this.lists,
    required this.byId,
    required this.hasData,
  });

  /// The rows in DISPLAY order — on Focus that is the overdue bucket lifted to
  /// the front, followed by the rest (F17); everywhere else it is one list.
  final List<TaskRowData> rows;

  /// How many leading rows are in the "Overdue (N)" bucket (0 = no heading).
  final int overdueCount;

  /// The sort this view is showing in — only [SortMode.manual] can be dragged.
  final SortMode sort;

  /// Every known list, so the composer and the row menus can offer them.
  final List<StoredTaskList> lists;

  /// The FULL task set by id (subtasks included) — what a departing row's
  /// current state is read from, and what the demote/nest predicates scan.
  final Map<String, StoredTask> byId;

  /// Whether the store has produced a snapshot yet — until it has, the pane
  /// shows the first-snapshot gate rather than an empty state (#260).
  final bool hasData;

  /// The rows' stored tasks, in display order — the shape the reorder anchor
  /// and the drag handlers work in.
  List<StoredTask> get stored => [for (final r in rows) r.stored];
}

/// The rows [viewId] renders, memoised until the data behind them changes.
///
/// Watched by exactly ONE widget — the list body. Deliberately: a derived
/// provider watched by an ancestor AND its descendant is flushed by the
/// ancestor's rebuild, so during a burst of store emissions the descendant
/// reads the value the ancestor already forced, and the list renders one
/// emission behind. The pane above the body therefore watches the RAW inputs
/// (tasks, lists, prefs) instead of this.
final visibleRowsProvider = Provider.family<VisibleRows, String>((ref, viewId) {
  final tasksAsync = ref.watch(allTasksProvider);
  final all = tasksAsync.asData?.value ?? const <StoredTask>[];
  final lists =
      ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];
  final prefs = ref.watch(prefsControllerProvider);
  final newestId = ref.watch(newestTaskProvider);
  return computeVisibleRows(
    all: all,
    lists: lists,
    viewId: viewId,
    excludedLists: prefs.excludedLists.toSet(),
    showCompleted: prefs.showCompleted,
    sort: SortMode.byId(prefs.sortPerView[viewId]),
    window: dateWindowNow(),
    newestId: newestId,
    hasData: tasksAsync.asData != null,
  );
});

/// The derivation itself — pure, so it can be exercised (and reasoned about)
/// without a container.
VisibleRows computeVisibleRows({
  required List<StoredTask> all,
  required List<StoredTaskList> lists,
  required String viewId,
  required Set<String> excludedLists,
  required bool showCompleted,
  required SortMode sort,
  required DateWindow window,
  required String? newestId,
  required bool hasData,
}) {
  final visible = visibleTasksForView(
    allTasks: all,
    viewId: viewId,
    excludedLists: excludedLists,
    showCompleted: showCompleted,
    sort: sort,
    window: window,
    newestId: newestId,
  );

  // Focus renders an "Overdue (N)" headed bucket above the dated one (F17):
  // the overdue cards are lifted to the front (their internal order kept) and a
  // heading marks the split. Every other view is a single ungrouped list.
  final display = <StoredTask>[];
  var overdueCount = 0;
  if (viewId == SmartView.focus.id) {
    final part = partitionFocusOverdue(
      rows: visible,
      allTasks: all,
      window: window,
    );
    overdueCount = part.overdueCount;
    display
      ..addAll(part.overdue)
      ..addAll(part.rest);
  } else {
    display.addAll(visible);
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

  // In a cross-list view (any smart view aggregates across lists) every row is
  // tagged with the list it lives in, so a task's home is legible at a glance;
  // a single concrete-list view needs no tag (F18).
  final smart = SmartView.byId(viewId) != null;
  final listTitles = {for (final l in lists) l.list.id: l.list.title};

  return VisibleRows(
    rows: [
      for (final t in display)
        TaskRowData(
          stored: t,
          inheritedDue: dueInfo[t.task.id]?.propagated,
          subtaskDone: subDone[t.task.id] ?? 0,
          subtaskTotal: subTotal[t.task.id] ?? 0,
          listTag: smart ? listTitles[t.listId] : null,
        ),
    ],
    overdueCount: overdueCount,
    sort: sort,
    lists: lists,
    byId: {for (final t in all) t.task.id: t},
    hasData: hasData,
  );
}
