// Effective-due propagation — the Dart port of the `dueInfo` computation in
// App.svelte. Pure domain logic: no rendering, no clock.
//
// Each task has up to two dates:
//   • explicit  — the date set directly on the task (its own `due`, YYYY-MM-DD)
//   • propagated — the earliest EFFECTIVE date among its UNFINISHED direct
//                  subtasks (recurses, so a completed subtask cuts off its
//                  whole subtree; only pending work propagates a date up)
// The EFFECTIVE date is the earlier of the two. It is what smart views filter
// and sort on, so a parent with a dated subtask lands in Focus/Upcoming even
// when the parent itself is undated. Dates compare as `YYYY-MM-DD` strings
// (lexical == chronological). The computation is memoized so the recursion is
// linear, not quadratic, and cycle-guarded so a malformed parent chain can
// never loop.

import 'task.dart';

/// The three dates computed for a task. All are `YYYY-MM-DD` or `null`.
class DueInfo {
  const DueInfo({this.explicit, this.propagated, this.effective});

  /// The task's own due date (`null` when it has none).
  final String? explicit;

  /// The earliest effective date borrowed from unfinished subtasks (`null` when
  /// none). Read-only; drives the "↳ inherited" marker in the UI.
  final String? propagated;

  /// The earlier of [explicit] and [propagated] — what views filter/sort on.
  final String? effective;

  @override
  bool operator ==(Object other) =>
      other is DueInfo &&
      other.explicit == explicit &&
      other.propagated == propagated &&
      other.effective == effective;

  @override
  int get hashCode => Object.hash(explicit, propagated, effective);

  @override
  String toString() =>
      'DueInfo(explicit: $explicit, '
      'propagated: $propagated, effective: $effective)';
}

/// The earlier of two `YYYY-MM-DD` dates (lexical == chronological). `null` is
/// treated as "no date", so it never wins over a real date.
String? _minDate(String? a, String? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.compareTo(b) <= 0 ? a : b;
}

/// A task's own due date reduced to `YYYY-MM-DD`, or `null` when it has none.
String? _explicitOf(Task t) {
  final due = t.due;
  if (due == null || due.isEmpty) return null;
  return due.length >= 10 ? due.substring(0, 10) : due;
}

/// Compute the [DueInfo] for every task in [tasks], keyed by task id.
Map<String, DueInfo> computeEffectiveDue(Iterable<Task> tasks) {
  final childrenByParent = <String, List<Task>>{};
  for (final t in tasks) {
    final p = t.parent;
    if (p == null) continue;
    (childrenByParent[p] ??= <Task>[]).add(t);
  }

  final memo = <String, DueInfo>{};

  DueInfo compute(Task t, Set<String> seen) {
    final cached = memo[t.id];
    if (cached != null) return cached;
    // Cycle guard: a malformed parent chain (a → b → a) must terminate.
    if (seen.contains(t.id)) return const DueInfo();
    seen.add(t.id);

    final explicit = _explicitOf(t);
    String? propagated;
    for (final child in childrenByParent[t.id] ?? const <Task>[]) {
      // A completed subtask propagates no date — it cuts off its whole subtree.
      if (child.status == TaskStatus.completed) continue;
      propagated = _minDate(propagated, compute(child, seen).effective);
    }

    seen.remove(t.id);
    final info = DueInfo(
      explicit: explicit,
      propagated: propagated,
      effective: _minDate(explicit, propagated),
    );
    memo[t.id] = info;
    return info;
  }

  final out = <String, DueInfo>{};
  for (final t in tasks) {
    out[t.id] = compute(t, <String>{});
  }
  return out;
}
