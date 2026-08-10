// SubtaskReorder suite — the hidden-aware reorder of a parent's subtasks from
// the detail panel (#90). The [FakeBackend] actually swaps sibling positions on
// each `reorderTask`, so these assert the USER-VISIBLE order the panel renders,
// not merely that a command fired. The move buttons are the touch path (they
// work with a mouse too); the key non-happy case is reordering across a HIDDEN
// completed row, which a naive visible-index step would get wrong.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

/// The rendered top-to-bottom order of the named subtask titles (hidden ones
/// are simply absent from [titles]).
List<String> subtaskOrder(WidgetTester tester, List<String> titles) {
  final present = titles.where((t) => find.text(t).evaluate().isNotEmpty);
  final entries = [
    for (final t in present) (t, tester.getTopLeft(find.text(t)).dy),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final e in entries) e.$1];
}

void main() {
  testWidgets('the move-down button reorders the subtask (touch path)', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      taskId: 'P',
      initial: [
        row('P', 'Parent'),
        row('s1', 'Alpha', parent: 'P', position: '1'),
        row('s2', 'Beta', parent: 'P', position: '2'),
      ],
    );
    expect(subtaskOrder(tester, ['Alpha', 'Beta']), ['Alpha', 'Beta']);

    await tester.tap(find.byKey(const Key('sub-down-s1')));
    await settleDetail(tester);

    expect(subtaskOrder(tester, ['Alpha', 'Beta']), ['Beta', 'Alpha']);
  });

  testWidgets('the top subtask has no move-up, the last no move-down', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      taskId: 'P',
      initial: [
        row('P', 'Parent'),
        row('s1', 'Alpha', parent: 'P', position: '1'),
        row('s2', 'Beta', parent: 'P', position: '2'),
      ],
    );
    // Boundary buttons are disabled (onPressed == null), never dead-but-enabled.
    expect(
      tester.widget<IconButton>(find.byKey(const Key('sub-up-s1'))).onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.byKey(const Key('sub-down-s2'))).onPressed,
      isNull,
    );
  });

  testWidgets(
    'reorders correctly ACROSS a hidden completed subtask (#90 non-happy)',
    (tester) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P', position: '1'),
          row('s2', 'Beta', parent: 'P', position: '2', done: true),
          row('s3', 'Gamma', parent: 'P', position: '3'),
        ],
      );

      // Hide completed: Beta (between Alpha and Gamma in the FULL list) vanishes.
      await tester.tap(find.text('Hide completed'));
      await settleDetail(tester);
      expect(subtaskOrder(tester, ['Alpha', 'Gamma']), ['Alpha', 'Gamma']);

      // Move Gamma up past Alpha. Beta sits between them in the full list, so
      // this must cross it — a single visible-index step would land wrong.
      await tester.tap(find.byKey(const Key('sub-up-s3')));
      await settleDetail(tester);
      expect(subtaskOrder(tester, ['Alpha', 'Gamma']), ['Gamma', 'Alpha']);

      // Two single-step swaps were emitted (Gamma crossed Beta, then Alpha).
      expect(fake.reordered, ['s3:up', 's3:up']);

      // Revealing completed shows Beta kept its place after the reorder.
      await tester.tap(find.text('Hide completed'));
      await settleDetail(tester);
      expect(subtaskOrder(tester, ['Alpha', 'Beta', 'Gamma']), [
        'Gamma',
        'Alpha',
        'Beta',
      ]);
    },
  );
}
