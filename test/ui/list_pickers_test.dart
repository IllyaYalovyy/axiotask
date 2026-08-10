// MoveToListPicker + ParentPicker (MIGRATION-PLAN §5 T7.6). Focused widget
// tests of the two modal pickers driven directly (a button opens each and the
// resolved value is captured), so the exclusion rule, the searchable filter,
// the empty state, selection, and barrier-dismiss are all asserted on what
// RENDERS and what the Future resolves to. The arrow/Enter keyboard navigation
// dies with the keyboard layer.

import 'package:axiotask/src/ui/list_pickers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;

Future<void> pumpOpener(
  WidgetTester tester,
  Future<String?> Function(BuildContext context) open,
  List<String?> captured,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async => captured.add(await open(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  final threeLists = [
    list('L1', 'My Tasks'),
    list('L2', 'Errands'),
    list('L3', 'Work'),
  ];

  group('MoveToListPicker', () {
    testWidgets('renders every list EXCEPT the current one', (tester) async {
      final captured = <String?>[];
      await pumpOpener(
        tester,
        (c) => showMoveToListPicker(c, lists: threeLists, currentListId: 'L1'),
        captured,
      );
      expect(find.text('Errands'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('My Tasks'), findsNothing); // current excluded
    });

    testWidgets('resolves the tapped list id', (tester) async {
      final captured = <String?>[];
      await pumpOpener(
        tester,
        (c) => showMoveToListPicker(c, lists: threeLists, currentListId: 'L1'),
        captured,
      );
      await tester.tap(find.byKey(const Key('move-picker-L3')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(captured, ['L3']);
    });

    testWidgets('bulk mode (no current) shows every list', (tester) async {
      final captured = <String?>[];
      await pumpOpener(
        tester,
        (c) => showMoveToListPicker(c, lists: threeLists),
        captured,
      );
      expect(find.text('My Tasks'), findsOneWidget);
      expect(find.text('Errands'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
    });

    testWidgets('a barrier tap dismisses without moving (resolves null)', (
      tester,
    ) async {
      final captured = <String?>[];
      await pumpOpener(
        tester,
        (c) => showMoveToListPicker(c, lists: threeLists, currentListId: 'L1'),
        captured,
      );
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(captured, [null]);
    });
  });

  group('ParentPicker (#88)', () {
    final candidates = [row('B', 'bread'), row('C', 'cherry')];

    testWidgets('lists candidates and resolves the tapped parent', (
      tester,
    ) async {
      final captured = <String?>[];
      await pumpOpener(
        tester,
        (c) => showParentPicker(c, candidates: candidates),
        captured,
      );
      expect(find.text('bread'), findsOneWidget);
      expect(find.text('cherry'), findsOneWidget);
      await tester.tap(find.byKey(const Key('parent-picker-C')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(captured, ['C']);
    });

    testWidgets('the type-to-filter narrows to a matching candidate', (
      tester,
    ) async {
      final captured = <String?>[];
      await pumpOpener(
        tester,
        (c) => showParentPicker(c, candidates: candidates),
        captured,
      );
      await tester.enterText(
        find.byKey(const Key('parent-picker-query')),
        'brea',
      );
      await tester.pump();
      expect(find.byKey(const Key('parent-picker-B')), findsOneWidget);
      expect(find.byKey(const Key('parent-picker-C')), findsNothing);
    });

    testWidgets('an unmatched query shows the empty state', (tester) async {
      final captured = <String?>[];
      await pumpOpener(
        tester,
        (c) => showParentPicker(c, candidates: candidates),
        captured,
      );
      await tester.enterText(
        find.byKey(const Key('parent-picker-query')),
        'zzz',
      );
      await tester.pump();
      expect(find.text('No matching task'), findsOneWidget);
    });
  });
}
