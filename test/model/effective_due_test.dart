// Unit layer — SubtaskDatePropagation.test.js ported as pure domain units.
//
// Protects the effective-date rule (ratified): effective = min(own due,
// earliest effective date among UNFINISHED direct subtasks, recursive; a
// completed subtask cuts off its subtree). This is what pulls a parent with a
// dated subtask into Focus/Upcoming and keeps a parent whose only dated subtask
// is done in Unscheduled. If propagation broke, smart-view membership and the
// ↳ inherited badge would both be wrong.

import 'package:axiotask/src/model/effective_due.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:flutter_test/flutter_test.dart';

Task task(
  String id, {
  String? parent,
  String? due,
  TaskStatus status = TaskStatus.needsAction,
}) => Task(
  id: id,
  parent: parent,
  position: '1',
  title: id,
  status: status,
  due: due,
  updated: 'u',
);

// A canonical full-form due for a given calendar day.
String at(String ymd) => '${ymd}T00:00:00.000Z';

void main() {
  test(
    'a parent with no date inherits an unfinished subtask date as effective',
    () {
      final info = computeEffectiveDue([
        task('p1'),
        task('s1', parent: 'p1', due: at('2026-08-02')),
        task('other'),
      ]);
      expect(info['p1']!.explicit, isNull);
      expect(info['p1']!.propagated, '2026-08-02');
      expect(info['p1']!.effective, '2026-08-02');
      // An unrelated undated task stays fully undated.
      expect(info['other']!.effective, isNull);
    },
  );

  test('the parent has a propagated (inherited) date but no explicit one', () {
    // Domain basis for the "↳ inherited" row marker.
    final info = computeEffectiveDue([
      task('p1'),
      task('s1', parent: 'p1', due: at('2026-08-02')),
    ]);
    expect(info['p1']!.explicit, isNull);
    expect(info['p1']!.propagated, '2026-08-02');
  });

  test(
    'a completed subtask date does NOT propagate — parent stays unscheduled',
    () {
      final info = computeEffectiveDue([
        task('p1'),
        task(
          's1',
          parent: 'p1',
          due: at('2026-08-02'),
          status: TaskStatus.completed,
        ),
      ]);
      expect(info['p1']!.effective, isNull);
      expect(info['p1']!.propagated, isNull);
    },
  );

  test(
    'an explicit parent date later than the subtask yields the earlier one',
    () {
      final info = computeEffectiveDue([
        task('p1', due: at('2026-08-30')),
        task('s1', parent: 'p1', due: at('2026-08-02')),
      ]);
      expect(info['p1']!.explicit, '2026-08-30');
      expect(info['p1']!.propagated, '2026-08-02');
      // Effective is the earlier (the subtask's) date.
      expect(info['p1']!.effective, '2026-08-02');
    },
  );

  test(
    'a parent whose subtask is dated has an effective date (not unscheduled)',
    () {
      final info = computeEffectiveDue([
        task('p1'),
        task('s1', parent: 'p1', due: at('2026-08-03')),
        task('p2'),
      ]);
      expect(info['p1']!.effective, isNotNull);
      expect(info['p2']!.effective, isNull);
    },
  );

  test('propagated is present only when a dated unfinished subtask exists', () {
    final info = computeEffectiveDue([
      task('withDatedSub'),
      task('s', parent: 'withDatedSub', due: at('2026-08-02')),
      task('noSubs'),
    ]);
    expect(info['withDatedSub']!.propagated, isNotNull);
    expect(info['noSubs']!.propagated, isNull);
  });

  test(
    'recursion: a grandchild date propagates up through an unfinished middle',
    () {
      final info = computeEffectiveDue([
        task('root'),
        task('mid', parent: 'root'),
        task('leaf', parent: 'mid', due: at('2026-08-02')),
      ]);
      expect(info['root']!.effective, '2026-08-02');
      expect(info['mid']!.effective, '2026-08-02');
    },
  );

  test('recursion: a COMPLETED middle cuts off its subtree', () {
    final info = computeEffectiveDue([
      task('root'),
      task('mid', parent: 'root', status: TaskStatus.completed),
      task('leaf', parent: 'mid', due: at('2026-08-02')),
    ]);
    expect(info['root']!.effective, isNull);
  });

  test('earliest of several unfinished subtask dates wins', () {
    final info = computeEffectiveDue([
      task('p'),
      task('a', parent: 'p', due: at('2026-08-10')),
      task('b', parent: 'p', due: at('2026-08-03')),
      task('c', parent: 'p', due: at('2026-08-20')),
    ]);
    expect(info['p']!.propagated, '2026-08-03');
  });

  test('a deep tree propagates each branch minimum up through every level', () {
    // Deeper and wider than any other fixture here: two levels of siblings,
    // each branch carrying its own date. The failure this prevents is a
    // propagation that stops at the first branch or leaks one branch's date
    // into its sibling — `root` must see the earliest date in the WHOLE
    // subtree, while `b` keeps only what its own subtree holds.
    final info = computeEffectiveDue([
      task('root'),
      task('mid', parent: 'root'),
      task('a', parent: 'mid', due: at('2026-08-02')),
      task('b', parent: 'mid'),
      task('b1', parent: 'b', due: at('2026-08-05')),
    ]);
    expect(info['root']!.effective, '2026-08-02');
    expect(info['root']!.explicit, isNull);
    expect(info['mid']!.effective, '2026-08-02');
    // The `b` branch inherits its own leaf only — not its sibling's earlier
    // date, which lives on a branch it does not contain.
    expect(info['b']!.effective, '2026-08-05');
    expect(info['b']!.propagated, '2026-08-05');
    expect(info['a']!.propagated, isNull);
    expect(info['b1']!.explicit, '2026-08-05');
  });

  test('a truncated due string is kept whole, not cropped past its end', () {
    // Non-happy path: malformed stored data. A due shorter than YYYY-MM-DD
    // (a truncated row, a hand-edited backup) is passed through as-is; the
    // length guard is what stops `substring(0, 10)` from throwing a
    // RangeError and taking the whole list view down with it.
    final info = computeEffectiveDue([
      task('short', due: '2026'),
      task('exact', due: '2026-08-02'),
      task('empty', due: ''),
    ]);
    expect(info['short']!.explicit, '2026');
    expect(info['short']!.effective, '2026');
    // A bare YYYY-MM-DD (exactly 10 chars) is already in canonical form.
    expect(info['exact']!.explicit, '2026-08-02');
    // An empty due is no due at all.
    expect(info['empty']!.explicit, isNull);
  });

  test('a cyclic parent chain does not loop and yields no effective date', () {
    // Non-happy path: malformed data (a → b → a) must terminate, not hang.
    final info = computeEffectiveDue([
      task('a', parent: 'b'),
      task('b', parent: 'a'),
    ]);
    expect(info['a']!.effective, isNull);
    expect(info['b']!.effective, isNull);
  });

  // The value contract of the result type. Every assertion above reads one
  // field at a time, so `DueInfo.==` and `hashCode` — exported model API — were
  // carried by no test at all (mutation testing could not even reach them: no
  // line of the suite executes them). They are what a WHOLE-value expectation
  // rests on: `expect(info['p'], DueInfo(...))` says "these three dates and
  // nothing else" only if `==` looks at all three. The failure this prevents is
  // an equality that ignores a field, under which such an expectation would
  // pass against a propagation that silently dropped `propagated`.
  group('DueInfo value equality', () {
    DueInfo dated({String? explicit, String? propagated, String? effective}) =>
        DueInfo(
          explicit: explicit,
          propagated: propagated,
          effective: effective,
        );

    final info = dated(
      explicit: '2026-08-02',
      propagated: '2026-08-01',
      effective: '2026-08-01',
    );

    test('same three dates means equal, and the hashes agree', () {
      expect(
        dated(
          explicit: '2026-08-02',
          propagated: '2026-08-01',
          effective: '2026-08-01',
        ),
        info,
      );
      expect(
        dated(
          explicit: '2026-08-02',
          propagated: '2026-08-01',
          effective: '2026-08-01',
        ).hashCode,
        info.hashCode,
      );
      // The all-null case the map is mostly full of: two undated tasks.
      expect(dated(), dated());
      expect(dated().hashCode, dated().hashCode);
    });

    test('a difference in any single field breaks equality', () {
      expect(
        dated(
          explicit: '2026-08-03',
          propagated: '2026-08-01',
          effective: '2026-08-01',
        ),
        isNot(info),
      );
      expect(
        dated(
          explicit: '2026-08-02',
          propagated: '2026-08-09',
          effective: '2026-08-01',
        ),
        isNot(info),
      );
      expect(
        dated(
          explicit: '2026-08-02',
          propagated: '2026-08-01',
          effective: '2026-08-02',
        ),
        isNot(info),
      );
      // Non-happy path: a DROPPED field is a difference, not a match — the
      // exact shape a broken propagation produces.
      expect(
        dated(explicit: '2026-08-02', effective: '2026-08-01'),
        isNot(info),
      );
      expect(dated(), isNot(info));
    });
  });
}
