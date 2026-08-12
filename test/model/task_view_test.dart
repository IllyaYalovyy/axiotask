// Contract for the pure view logic: the smart-view predicates, per-view counts,
// exclusion, show-completed gating, and the sort/order pipeline. These protect
// the exact partition semantics ported from the reference App.svelte —
// especially that Focus includes overdue+today+next-6-days, Missed is
// overdue-only, counts ignore the show-completed toggle, and undated tasks sink
// to the bottom under a due sort. Pure functions, so no widget is pumped; the
// clock is pinned so "today" is deterministic.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_view.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

// A fixed "today" of 2026-06-15 (a Monday).
final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

/// A YYYY-MM-DD date [days] from 2026-06-15.
String day(int days) {
  final d = DateTime.utc(2026, 6, 15).add(Duration(days: days));
  return '${d.year.toString().padLeft(4, '0')}'
      '-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';
}

StoredTask task(
  String id, {
  String title = 't',
  String? due,
  String? parent,
  String position = '5',
  String listId = 'L1',
  bool done = false,
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    status: done ? TaskStatus.completed : TaskStatus.needsAction,
    due: due == null ? null : '${due}T00:00:00.000Z',
    updated: 't',
  ),
  listId: listId,
  syncState: SyncState.clean,
  localUpdated: 't',
);

DateWindow window() => withClock(_clock, dateWindowNow);

List<StoredTask> visible(
  List<StoredTask> all,
  String viewId, {
  Set<String> excluded = const {},
  bool showCompleted = false,
  SortMode sort = SortMode.manual,
  String? newestId,
}) => withClock(
  _clock,
  () => visibleTasksForView(
    allTasks: all,
    viewId: viewId,
    excludedLists: excluded,
    showCompleted: showCompleted,
    sort: sort,
    window: dateWindowNow(),
    newestId: newestId,
  ),
);

List<String> ids(List<StoredTask> rows) => [for (final r in rows) r.task.id];

void main() {
  group('smart-view predicates', () {
    final w = window();

    test(
      'Focus = overdue + today + the next 6 days, excludes +7 and beyond',
      () {
        expect(inFocus(day(-2), w), isTrue); // overdue is in Focus
        expect(inFocus(day(0), w), isTrue); // today
        expect(inFocus(day(6), w), isTrue); // last day in the window
        expect(inFocus(day(7), w), isFalse); // strict upper bound
        expect(inFocus(day(10), w), isFalse);
        expect(inFocus(null, w), isFalse);
      },
    );

    test('Upcoming = tomorrow through +14 inclusive', () {
      expect(inUpcoming(day(0), w), isFalse); // today is not upcoming
      expect(inUpcoming(day(1), w), isTrue);
      expect(inUpcoming(day(14), w), isTrue); // inclusive upper bound
      expect(inUpcoming(day(15), w), isFalse);
      expect(inUpcoming(day(-1), w), isFalse); // overdue is not upcoming
    });

    test('Missed = strictly overdue (today is never missed)', () {
      expect(inMissed(day(-1), w), isTrue);
      expect(inMissed(day(0), w), isFalse);
      expect(inMissed(day(1), w), isFalse);
      expect(inMissed(null, w), isFalse);
    });

    test('Unscheduled = no effective due', () {
      expect(isUnscheduled(null), isTrue);
      expect(isUnscheduled(day(0)), isFalse);
    });
  });

  group('visibleTasksForView — filtering', () {
    test('Focus renders overdue, today, and this-week; hides far-future', () {
      final all = [
        task('over', due: day(-2)),
        task('today', due: day(0)),
        task('soon', due: day(3)),
        task('far', due: day(10)),
        task('none'),
      ];
      expect(ids(visible(all, 'focus'))..sort(), ['over', 'soon', 'today']);
    });

    test('a parent with a dated unfinished subtask is pulled into Focus', () {
      // The parent is undated; only its subtask carries tomorrow's date. The
      // parent appears as ONE top-level card; the subtask is never a row.
      final all = [task('P', due: null), task('C', parent: 'P', due: day(1))];
      final rows = visible(all, 'focus');
      expect(ids(rows), ['P'], reason: 'parent pulled in by effective due');
    });

    test('Unscheduled excludes a parent whose subtask is dated', () {
      final all = [
        task('P', due: null),
        task('C', parent: 'P', due: day(1)),
        task('bare', due: null),
      ];
      expect(ids(visible(all, 'unscheduled')), ['bare']);
    });

    test('Missed shows only overdue and is oldest-first by default', () {
      final all = [
        task('a', due: day(-1), position: '1'),
        task('b', due: day(-7), position: '2'),
        task('c', due: day(-3), position: '3'),
        task('today', due: day(0)),
        task('future', due: day(2)),
      ];
      expect(ids(visible(all, 'missed')), ['b', 'c', 'a']);
    });

    test('list exclusion hides a list from smart views only', () {
      final all = [
        task('keep', due: day(0), listId: 'L1'),
        task('drop', due: day(0), listId: 'L2'),
      ];
      // Excluded from Focus…
      expect(ids(visible(all, 'focus', excluded: {'L2'})), ['keep']);
      // …but the list's own view still shows it.
      expect(ids(visible(all, 'L2', excluded: {'L2'})), ['drop']);
    });

    test('show-completed gates completed rows in a list view', () {
      final all = [
        task('open', listId: 'L1'),
        task('done', listId: 'L1', done: true),
      ];
      expect(ids(visible(all, 'L1')), ['open']);
      expect(ids(visible(all, 'L1', showCompleted: true))..sort(), [
        'done',
        'open',
      ]);
    });
  });

  group('visibleTasksForView — sort/order', () {
    test('due sort: earliest first, undated sinks to the bottom', () {
      final all = [
        task('none', due: null, position: '1'),
        task('late', due: day(5), position: '2'),
        task('early', due: day(1), position: '3'),
      ];
      expect(ids(visible(all, 'all', sort: SortMode.due)), [
        'early',
        'late',
        'none',
      ]);
    });

    test('alpha sort is case-insensitive A→Z', () {
      final all = [
        task('b', title: 'banana', position: '1'),
        task('a', title: 'Apple', position: '2'),
        task('c', title: 'cherry', position: '3'),
      ];
      expect(ids(visible(all, 'all', sort: SortMode.alpha)), ['a', 'b', 'c']);
    });

    test('manual sort is position ascending; created is descending', () {
      final all = [
        task('x', position: '1'),
        task('y', position: '2'),
        task('z', position: '3'),
      ];
      expect(ids(visible(all, 'all', sort: SortMode.manual)), ['x', 'y', 'z']);
      expect(ids(visible(all, 'all', sort: SortMode.created)), ['z', 'y', 'x']);
    });

    test('completed always sinks to the bottom regardless of sort', () {
      final all = [
        task('open2', title: 'zeta', position: '1'),
        task('done1', title: 'alpha', position: '2', done: true),
        task('open1', title: 'beta', position: '3'),
      ];
      // Alpha order among visible would be alpha,beta,zeta — but the completed
      // "alpha" is pushed below the two open rows.
      final rows = visible(
        all,
        'all',
        sort: SortMode.alpha,
        showCompleted: true,
      );
      expect(ids(rows), ['open1', 'open2', 'done1']);
    });

    test('a freshly created task is pinned to the very top', () {
      final all = [
        task('a', due: day(-1), position: '1'),
        task('b', due: day(-2), position: '2'),
        task('new', due: day(3), position: '9'),
      ];
      // Under a due sort "new" would sort last, but as the newest it pins first.
      final rows = visible(all, 'focus', sort: SortMode.due, newestId: 'new');
      expect(ids(rows).first, 'new');
    });
  });

  group('computeViewCounts', () {
    test('counts are top-level, open-only, and ignore show-completed', () {
      final all = [
        task('o1', due: day(0)),
        task('o2', due: day(-1)),
        task('doneToday', due: day(0), done: true),
        task('sub', parent: 'o1', due: day(0)),
      ];
      final c = withClock(
        _clock,
        () => computeViewCounts(
          allTasks: all,
          listIds: const ['L1'],
          excludedLists: const {},
          window: dateWindowNow(),
        ),
      );
      // o1 (today) + o2 (overdue) are both in Focus; the completed one and the
      // subtask never count.
      expect(c['focus'], 2);
      expect(c['missed'], 1);
      expect(c['all'], 2);
      expect(c['L1'], 2);
    });

    test('smart-view counts respect exclusion; the list count does not', () {
      final all = [
        task('a', due: day(0), listId: 'L1'),
        task('b', due: day(0), listId: 'L2'),
      ];
      final c = withClock(
        _clock,
        () => computeViewCounts(
          allTasks: all,
          listIds: const ['L1', 'L2'],
          excludedLists: const {'L2'},
          window: dateWindowNow(),
        ),
      );
      expect(c['focus'], 1, reason: 'L2 excluded from smart views');
      expect(c['L2'], 1, reason: "a list's own badge always counts its tasks");
    });
  });

  group('SortMode', () {
    test('byId maps ids and falls back to manual for unknown/null', () {
      expect(SortMode.byId('due'), SortMode.due);
      expect(SortMode.byId('alpha'), SortMode.alpha);
      expect(SortMode.byId(null), SortMode.manual);
      expect(SortMode.byId('bogus'), SortMode.manual);
    });
  });

  // The #190 landing-feedback decision: given a fresh create's due and the view
  // it was made in, where (if anywhere) must a toast say it went. Protects the
  // invariant "quick-add/bulk-add never leaves an invisible, silent create".
  group('landingDestinationFor', () {
    LandingDestination? dest(
      String viewId, {
      String? due,
      String listId = 'L1',
      String listTitle = 'My Tasks',
      Set<String> excludedLists = const {},
    }) => landingDestinationFor(
      viewId: viewId,
      due: due,
      listId: listId,
      listTitle: listTitle,
      excludedLists: excludedLists,
      window: window(),
    );

    test('an in-view create returns null (no toast)', () {
      // Focus create born due today shows in Focus.
      expect(dest('focus', due: day(0)), isNull);
      // Upcoming create at its +7 default shows in Upcoming.
      expect(dest('upcoming', due: day(7)), isNull);
      // A concrete list always shows its own create, dated or not.
      expect(dest('L1', due: null), isNull);
      expect(dest('L1', due: day(30)), isNull);
      // 'all' shows every create.
      expect(dest('all', due: null), isNull);
    });

    test('a Missed create (born due today) lands in Focus', () {
      final d = dest('missed', due: day(0));
      expect(d?.viewId, 'focus');
      expect(d?.label, 'Focus');
    });

    test('an out-of-window scheduled create lands in its list', () {
      // "next month" is past Focus (+7) and Upcoming (+14) — only the list and
      // All Tasks hold it, so the toast names the list.
      final d = dest('focus', due: day(30));
      expect(d?.viewId, 'L1');
      expect(d?.label, 'My Tasks');
    });

    test('an undated bulk-add from a dated view lands in Unscheduled', () {
      final d = dest('focus', due: null);
      expect(d?.viewId, 'unscheduled');
      expect(d?.label, 'Unscheduled');
      // …and from Missed too (its default create is dated, but a bulk row is not).
      expect(dest('missed', due: null)?.viewId, 'unscheduled');
    });

    test(
      'an overdue create prefers Missed over Focus (both would show it)',
      () {
        // An explicit past date typed from Upcoming: it belongs to Missed (and
        // also Focus) — name Missed, its natural home.
        final d = dest('upcoming', due: day(-3));
        expect(d?.viewId, 'missed');
        expect(d?.label, 'Missed');
      },
    );

    test('a create into a list excluded from smart views lands in its list', () {
      // Born due today PASSES the Focus predicate, but L1 is excluded from the
      // smart views — Focus never shows it, so the destination is the list, not
      // Focus. The predicate alone would wrongly return null here (#190).
      final d = dest('focus', due: day(0), excludedLists: {'L1'});
      expect(d?.viewId, 'L1');
      expect(d?.label, 'My Tasks');
      // The same create in an UNexcluded list is visible in Focus → no toast.
      expect(dest('focus', due: day(0)), isNull);
    });

    test('excluding OTHER lists does not affect an in-view create', () {
      // A create in L1 (visible in Focus) stays toast-free even though some
      // other list L2 is excluded — only the created task's own list matters.
      expect(dest('focus', due: day(0), excludedLists: {'L2'}), isNull);
    });

    test('an excluded-list create is silent in its own list view', () {
      // Viewing the excluded list itself: the list view ignores exclusion and
      // shows every create, so no toast (the newest-pin already surfaces it).
      expect(dest('L1', due: day(0), excludedLists: {'L1'}), isNull);
    });

    test('the inclusive +14 boundary stays visible in Upcoming (no toast)', () {
      // today+14 is the inclusive upper bound of Upcoming — a create there must
      // NOT toast as if it went elsewhere.
      expect(dest('upcoming', due: day(14)), isNull);
      // A day past the window does leave Upcoming → toast the list.
      expect(dest('upcoming', due: day(15))?.viewId, 'L1');
    });
  });

  group('Focus overdue partition', () {
    final w = window();

    // Partition the Focus rows produced under [sort], so the tests exercise the
    // real focus filter feeding the split.
    FocusPartition partition(
      List<StoredTask> all, {
      SortMode sort = SortMode.due,
    }) => partitionFocusOverdue(
      rows: visible(all, 'focus', sort: sort),
      allTasks: all,
      window: w,
    );

    test('splits overdue cards above the dated ones', () {
      final all = [
        task('over1', due: day(-3)),
        task('today', due: day(0)),
        task('over2', due: day(-1)),
        task('soon', due: day(3)),
      ];
      final p = partition(all);
      // Overdue = strictly-before-today, sorted earliest-first by the due sort.
      expect(ids(p.overdue), ['over1', 'over2']);
      // Rest = today + the next 6 days (today is NOT overdue).
      expect(ids(p.rest), ['today', 'soon']);
      expect(p.overdueCount, 2);
    });

    test('is independent of sort mode — alpha keeps overdue on top', () {
      final all = [
        task('zeta', title: 'zeta', due: day(-2)),
        task('alpha', title: 'alpha', due: day(1)),
        task('mid', title: 'mid', due: day(-5)),
      ];
      // Under an alphabetical sort the flat focus order is alpha, mid, zeta; the
      // partition still lifts the two overdue rows (mid, zeta) above alpha, in
      // their alphabetical order.
      final p = partition(all, sort: SortMode.alpha);
      expect(ids(p.overdue), ['mid', 'zeta']);
      expect(ids(p.rest), ['alpha']);
    });

    test('a parent is overdue by its inherited (subtask) date', () {
      // The parent has no own due; its only unfinished subtask is overdue, so
      // its effective due is overdue and it belongs in the Overdue bucket —
      // proving the split reads the EFFECTIVE date, not just the own date.
      final all = [
        task('p', due: null),
        task('c', parent: 'p', due: day(-4)),
        task('other', due: day(2)),
      ];
      final p = partition(all);
      expect(ids(p.overdue), ['p']);
      expect(ids(p.rest), ['other']);
    });

    test('no overdue rows yields an empty bucket (heading is suppressed)', () {
      final all = [task('today', due: day(0)), task('soon', due: day(4))];
      final p = partition(all);
      expect(p.overdue, isEmpty);
      expect(p.overdueCount, 0);
      expect(ids(p.rest), ['today', 'soon']);
    });
  });
}
