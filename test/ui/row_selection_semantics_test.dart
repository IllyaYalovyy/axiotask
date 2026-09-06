// What a SCREEN READER hears about a multi-selected row (#298).
//
// Multi-select marked a row with a left accent bar and a tinted wash and
// nothing else, so TalkBack announced a picked row and an unpicked one
// identically: the bulk bar said "3 selected" — the count — and nothing said
// WHICH. The user was then one tap from Delete (which cascades the subtree) or
// Complete over a set they could not inspect.
//
// The row now publishes the state the wash is drawing, on the SAME node that
// carries the title — the node a screen reader actually lands on — so
// "apples … selected" is one announcement rather than a flag parked on an
// unlabelled ancestor no AT reads.
//
// Two rulings these tests pin down:
//
//   • The state is published only while selection MODE is on. A plain list is
//     not a chooser, and a `selected: false` on every row of every list would
//     make TalkBack say "not selected" after every single title, forever.
//   • The row the DETAIL panel is showing (the quieter [openDetailWash]) is
//     NOT announced as selected. It is a pointer, not a chosen set: saying
//     "selected" there would name a row that Delete will not touch. The two
//     washes mean two different things and must not announce as one.
//
// Every assertion reads the rendered semantics tree of the real
// [TaskListView], driven through the real gestures (long-press, tap,
// Ctrl-click), so it holds however the row is built.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];

  /// The semantics node a screen reader lands on for the row titled [title] —
  /// found through the title itself, so it is by construction the node whose
  /// label the user hears.
  SemanticsData rowNode(WidgetTester tester, String title) =>
      tester.getSemantics(find.text(title)).getSemanticsData();

  /// The row's published selected state: `true`/`false` when the row says
  /// whether it is in the selection, `null` when it says nothing at all.
  bool? selectedState(WidgetTester tester, String title) {
    final data = rowNode(tester, title);
    expect(
      data.label,
      startsWith(title),
      reason: 'the flag must ride the node that carries the title',
    );
    return data.flagsCollection.isSelected.toBoolOrNull();
  }

  /// A plain (unmodified) tap on the row titled [title]. The row body has an
  /// onDoubleTap, so the onTap only resolves after the double-tap timeout.
  Future<void> plainTap(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> longPress(WidgetTester tester, String title) async {
    await tester.longPress(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('a multi-selected row announces "selected" and its neighbours '
      '"not selected"', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
        row('C', 'cheese', position: '3'),
      ],
      lists: oneList,
    );

    // The touch path into a multi-select: long-press one row, tap a second.
    await longPress(tester, 'apples');
    await plainTap(tester, 'cheese');
    expect(find.text('2 selected'), findsOneWidget, reason: 'precondition');

    expect(selectedState(tester, 'apples'), isTrue);
    expect(selectedState(tester, 'cheese'), isTrue);
    expect(
      selectedState(tester, 'bread'),
      isFalse,
      reason: 'a row Delete will NOT hit must say so, not stay silent',
    );
    handle.dispose();
  });

  testWidgets('a plain list says nothing about selection at all', (
    tester,
  ) async {
    // The everyday case: no mode, no chooser. A "not selected" after every
    // title would be pure verbosity on the app's most-read surface.
    final handle = tester.ensureSemantics();
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
    );

    expect(selectedState(tester, 'apples'), isNull);
    expect(selectedState(tester, 'bread'), isNull);
    handle.dispose();
  });

  testWidgets('entering selection mode with an EMPTY selection already tells '
      'every row apart', (tester) async {
    // The toolbar's "Select tasks" (#245) arms the mode with nothing picked.
    // The non-happy shape: the bulk bar has no count to read out, so the rows
    // are the only thing that can say the set is still empty.
    final handle = tester.ensureSemantics();
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
    );
    await tester.tap(find.byKey(const Key('toolbar-overflow')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const Key('toolbar-select-tasks')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(selectedState(tester, 'apples'), isFalse);
    expect(selectedState(tester, 'bread'), isFalse);

    await plainTap(tester, 'bread');
    expect(selectedState(tester, 'apples'), isFalse);
    expect(selectedState(tester, 'bread'), isTrue);
    handle.dispose();
  });

  testWidgets('leaving selection mode takes the announcement away with it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
    );
    await longPress(tester, 'apples');
    expect(selectedState(tester, 'apples'), isTrue, reason: 'precondition');

    // Deselecting the last row leaves the mode (SelectionController), so the
    // list is a plain list again — and must fall silent again with it.
    await plainTap(tester, 'apples');
    expect(find.text('1 selected'), findsNothing, reason: 'precondition');
    expect(selectedState(tester, 'apples'), isNull);
    expect(selectedState(tester, 'bread'), isNull);
    handle.dispose();
  });

  group('the row the detail panel is showing', () {
    testWidgets('is never announced as selected — it is a pointer, not a '
        'chosen set', (tester) async {
      final handle = tester.ensureSemantics();
      final open = ValueNotifier<String?>('B');
      addTearDown(open.dispose);
      await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread', position: '2'),
        ],
        lists: oneList,
        selection: open,
      );

      expect(
        selectedState(tester, 'bread'),
        isNull,
        reason: 'the open-in-detail wash must not claim bulk-op membership',
      );
      expect(selectedState(tester, 'apples'), isNull);
      handle.dispose();
    });

    testWidgets('says "not selected" during a multi-select that skipped it', (
      tester,
    ) async {
      // Both washes at once: the detail shows 'bread' while the user has
      // picked 'apples'. Delete would take apples only, and that is exactly
      // what the two rows must say.
      final handle = tester.ensureSemantics();
      final open = ValueNotifier<String?>('B');
      addTearDown(open.dispose);
      await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread', position: '2'),
        ],
        lists: oneList,
        selection: open,
        platform: TargetPlatform.linux,
      );

      // Ctrl-click, the desktop multi-select gesture.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('apples'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      // One more frame: the bulk bar collapses IN rather than appearing (#265).
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('1 selected'), findsOneWidget, reason: 'precondition');

      expect(selectedState(tester, 'apples'), isTrue);
      expect(selectedState(tester, 'bread'), isFalse);
      handle.dispose();
    });
  });
}
