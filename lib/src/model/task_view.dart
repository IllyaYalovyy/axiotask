// The pure view logic behind the sidebar and the list pane — the Dart port of
// App.svelte's smart-view filters, per-view counts, and sort/order pipeline
// (`inFocusDate`/`inUpcomingDate`/`inMissedDate`, `viewCounts`,
// `applySortAndOrder`). No widgets, no plugins: every predicate, count, and
// comparator is a pure function of (tasks, prefs, today) so the whole contract
// is unit-tested without pumping an app.
//
// Everything filters and sorts on the EFFECTIVE due date (a task's own date or
// the earliest unfinished-subtask date — see effective_due.dart), top-level
// tasks only (invariant #1). "Today" comes from package:clock, never the wall
// clock.
//
// One deliberate divergence from the reference: the reference computes its
// window bounds with millisecond arithmetic (`now + 7*86400000`), which lands a
// few hours off a calendar day across a DST boundary and would make a
// boundary-day task's membership depend on the season. The window here is pure
// CALENDAR-day arithmetic (`DateTime(y, m, d + 7)`), matching the documented
// intent ("today + next 6 days", "tomorrow through +14 days") deterministically.

import 'package:clock/clock.dart';

import '../store/stored.dart';
import 'effective_due.dart';
import 'task.dart';

/// The per-view sort orders, with the ids persisted in `prefs.json`'s
/// `sort_per_view` and the labels the [SortDropdown] renders. Ported from
/// `SortDropdown.svelte`'s option list.
enum SortMode {
  /// Backend/position order — the default; the only mode where manual reorder
  /// (drag / Alt+arrows) is allowed.
  manual('manual', 'My order'),

  /// Earliest effective due first; undated tasks sink to the bottom.
  due('due', 'Due date'),

  /// Case-insensitive A→Z by title.
  alpha('alpha', 'Alphabetical'),

  /// Reverse position order (newest-by-position first). Named "created" in the
  /// reference for its localStorage key; the label is "Reverse my order".
  created('created', 'Reverse my order');

  const SortMode(this.id, this.label);

  /// The stable id persisted per view.
  final String id;

  /// The dropdown label.
  final String label;

  /// The mode with this [id], defaulting to [manual] for null/unknown ids (a
  /// stale persisted value must never crash the list).
  static SortMode byId(String? id) {
    for (final m in values) {
      if (m.id == id) return m;
    }
    return manual;
  }
}

/// The calendar-day window the smart-view predicates compare against, as
/// `YYYY-MM-DD` strings (a lexical compare equals a chronological one).
class DateWindow {
  const DateWindow({
    required this.today,
    required this.plus7,
    required this.plus14,
  });

  /// Today (local calendar day).
  final String today;

  /// Today + 7 calendar days — the exclusive upper bound of Focus.
  final String plus7;

  /// Today + 14 calendar days — the inclusive upper bound of Upcoming.
  final String plus14;
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// Build the [DateWindow] for the current calendar day (via package:clock).
DateWindow dateWindowNow() {
  final n = clock.now();
  DateTime day(int add) => DateTime(n.year, n.month, n.day + add);
  return DateWindow(
    today: _ymd(day(0)),
    plus7: _ymd(day(7)),
    plus14: _ymd(day(14)),
  );
}

/// Focus: effective due before today+7 (all overdue + today + the next 6 days).
bool inFocus(String? effectiveDue, DateWindow w) =>
    effectiveDue != null && effectiveDue.compareTo(w.plus7) < 0;

/// Upcoming: effective due strictly after today, up to and including today+14.
bool inUpcoming(String? effectiveDue, DateWindow w) =>
    effectiveDue != null &&
    effectiveDue.compareTo(w.today) > 0 &&
    effectiveDue.compareTo(w.plus14) <= 0;

/// Missed: effective due strictly before today (today itself is never missed).
bool inMissed(String? effectiveDue, DateWindow w) =>
    effectiveDue != null && effectiveDue.compareTo(w.today) < 0;

/// Unscheduled: no effective due at all.
bool isUnscheduled(String? effectiveDue) => effectiveDue == null;

/// The ids of the four date-window smart views (All is handled separately — it
/// imposes no date filter and ignores list exclusion).
const _dateSmartViews = {'focus', 'upcoming', 'missed', 'unscheduled'};

/// Per-view badge counts — the port of `viewCounts`. Every count is top-level
/// only and ALWAYS excludes completed tasks (independent of the show-completed
/// toggle). Smart-view counts respect list [excludedLists]; the `all` count and
/// each per-list count (keyed by list id) do not. Views with a zero count are
/// still present in the map (the sidebar hides a 0 badge itself).
Map<String, int> computeViewCounts({
  required List<StoredTask> allTasks,
  required List<String> listIds,
  required Set<String> excludedLists,
  required DateWindow window,
}) {
  final effective = _effectiveDue(allTasks);
  bool open(StoredTask t) => t.task.status != TaskStatus.completed;

  final tops = allTasks.where((t) => t.task.parent == null && open(t)).toList();
  final smart = tops.where((t) => !excludedLists.contains(t.listId));
  int count(bool Function(String?) pred) =>
      smart.where((t) => pred(effective(t.task.id))).length;

  final counts = <String, int>{
    'focus': count((d) => inFocus(d, window)),
    'upcoming': count((d) => inUpcoming(d, window)),
    'missed': count((d) => inMissed(d, window)),
    'unscheduled': count(isUnscheduled),
    'all': tops.length,
  };
  for (final id in listIds) {
    counts[id] = tops.where((t) => t.listId == id).length;
  }
  return counts;
}

/// The sorted top-level rows shown for [viewId] — the port of `visibleTasks` +
/// `applySortAndOrder`.
///
/// The base set depends on the view: a date smart view filters top-level tasks
/// (minus [excludedLists]) by its predicate; `all` takes every top-level task
/// (no exclusion); any other id is a list view (that list's top-level tasks, no
/// exclusion). [showCompleted] gates completed rows in every case (counts do
/// not use it). Then the chosen [sort] runs, completed rows are pushed to the
/// bottom, and [newestId] (a just-created task) is pinned to the very top.
///
/// Missed is special: its natural (manual) order is oldest-effective-due first,
/// so an overdue backlog reads worst-first even before a sort is chosen.
List<StoredTask> visibleTasksForView({
  required List<StoredTask> allTasks,
  required String viewId,
  required Set<String> excludedLists,
  required bool showCompleted,
  required SortMode sort,
  required DateWindow window,
  String? newestId,
}) {
  final effective = _effectiveDue(allTasks);
  bool open(StoredTask t) => t.task.status != TaskStatus.completed;
  bool shown(StoredTask t) => showCompleted || open(t);

  final tops = allTasks.where((t) => t.task.parent == null && shown(t));

  List<StoredTask> base;
  if (_dateSmartViews.contains(viewId)) {
    final smart = tops.where((t) => !excludedLists.contains(t.listId));
    bool pred(StoredTask t) {
      final d = effective(t.task.id);
      return switch (viewId) {
        'focus' => inFocus(d, window),
        'upcoming' => inUpcoming(d, window),
        'missed' => inMissed(d, window),
        _ => isUnscheduled(d),
      };
    }

    base = smart.where(pred).toList();
  } else if (viewId == 'all') {
    base = tops.toList();
  } else {
    base = tops.where((t) => t.listId == viewId).toList();
  }

  // Missed's manual order is oldest-first; every other view's manual order is
  // backend/position order.
  final effectiveSort = (viewId == 'missed' && sort == SortMode.manual)
      ? SortMode.due
      : sort;
  base.sort((a, b) => _compare(a, b, effectiveSort, effective));

  // Completed always sinks to the bottom (stable within each partition), then a
  // freshly created row is pinned to the very top.
  final result = [...base.where(open), ...base.where((t) => !open(t))];
  if (newestId != null) {
    final i = result.indexWhere((t) => t.task.id == newestId);
    if (i > 0) {
      final row = result.removeAt(i);
      result.insert(0, row);
    }
  }
  return result;
}

/// Deterministic comparator for [sort]. Ties break by position then id so the
/// order never depends on the input order (Dart's sort is not stable).
int _compare(
  StoredTask a,
  StoredTask b,
  SortMode sort,
  String? Function(String) effective,
) {
  int primary;
  switch (sort) {
    case SortMode.manual:
      primary = a.task.position.compareTo(b.task.position);
    case SortMode.created:
      primary = b.task.position.compareTo(a.task.position);
    case SortMode.alpha:
      primary = a.task.title.toLowerCase().compareTo(
        b.task.title.toLowerCase(),
      );
    case SortMode.due:
      final da = effective(a.task.id);
      final db = effective(b.task.id);
      primary = (da == null && db == null)
          ? 0
          : da == null
          ? 1 // undated sinks below dated
          : db == null
          ? -1
          : da.compareTo(db);
  }
  if (primary != 0) return primary;
  final byPos = a.task.position.compareTo(b.task.position);
  return byPos != 0 ? byPos : a.task.id.compareTo(b.task.id);
}

/// Effective-due lookup over a stored-task set (id → `YYYY-MM-DD` or null).
String? Function(String) _effectiveDue(List<StoredTask> tasks) {
  final info = computeEffectiveDue(tasks.map((t) => t.task));
  return (id) => info[id]?.effective;
}
