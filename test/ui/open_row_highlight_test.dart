// The open-in-detail row highlight (#221). In the two-pane desktop layout the
// list↔detail link was invisible: nothing said WHICH row the open detail
// belongs to. The row now carries a tinted wash driven by the ROUTER-derived
// `selectedTaskId` TaskListView already receives — not by any tap-local state —
// so the highlight follows the detail through every entry path (row tap, search
// jump, detail prev/next, quick-add follow, a plain URL change).
//
// What these tests protect:
//   • the highlight lands on the OPEN row and no other;
//   • it MOVES when selectedTaskId changes without a remount (prev/next, search);
//   • it disappears when the detail closes;
//   • the multi-select accent WINS when a row is both open and selected, so a
//     bulk-op selection is never mistaken for "this is what the detail shows";
//   • the wash costs no geometry (#168 no-reflow class).

import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

/// The [TaskRow] rendering the task titled [title].
Finder _rowNamed(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(TaskRow));

/// Every box decoration painted inside the row titled [title].
Iterable<BoxDecoration> _decorations(WidgetTester tester, String title) =>
    tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: _rowNamed(title),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((b) => b.decoration)
        .whereType<BoxDecoration>();

/// Whether the row titled [title] paints a full-row background of [color].
bool _hasWash(WidgetTester tester, String title, Color color) =>
    _decorations(tester, title).any((d) => d.color == color);

/// Whether the row titled [title] paints the multi-select left accent bar.
bool _hasAccentBar(WidgetTester tester, String title, Color color) =>
    _decorations(tester, title).any((d) {
      final border = d.border;
      return border is Border &&
          border.left.color == color &&
          border.left.width > 0;
    });

ColorScheme _scheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(TaskRow).first)).colorScheme;

void main() {
  final oneList = [list('L1', 'My Tasks')];

  /// Ctrl-click the row titled [title] — the desktop multi-select gesture. The
  /// row body has an onDoubleTap, so the tap only resolves after the
  /// double-tap timeout; hold Ctrl until then.
  Future<void> ctrlClick(WidgetTester tester, String title) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('the row whose task the detail shows is the one washed', (
    tester,
  ) async {
    final selection = ValueNotifier<String?>('B');
    addTearDown(selection.dispose);
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
      selection: selection,
    );

    final wash = openDetailWash(_scheme(tester));
    expect(_hasWash(tester, 'bread', wash), isTrue, reason: 'B is open');
    expect(_hasWash(tester, 'apples', wash), isFalse, reason: 'A is not open');
  });

  testWidgets(
    'changing selectedTaskId moves the highlight (prev/next, search)',
    (tester) async {
      final selection = ValueNotifier<String?>('B');
      addTearDown(selection.dispose);
      await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread', position: '2'),
        ],
        lists: oneList,
        selection: selection,
      );
      final wash = openDetailWash(_scheme(tester));
      expect(_hasWash(tester, 'bread', wash), isTrue);

      // A route change — what detail prev/next and a search-result jump both do.
      selection.value = 'A';
      await settleList(tester);

      expect(
        _hasWash(tester, 'apples', wash),
        isTrue,
        reason: 'highlight moved',
      );
      expect(_hasWash(tester, 'bread', wash), isFalse, reason: 'B released it');
    },
  );

  testWidgets('a closed detail (selectedTaskId null) highlights nothing', (
    tester,
  ) async {
    final selection = ValueNotifier<String?>('A');
    addTearDown(selection.dispose);
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
      selection: selection,
    );
    final wash = openDetailWash(_scheme(tester));
    expect(_hasWash(tester, 'apples', wash), isTrue);

    selection.value = null;
    await settleList(tester);

    expect(_hasWash(tester, 'apples', wash), isFalse);
    expect(_hasWash(tester, 'bread', wash), isFalse);
  });

  testWidgets('the multi-select accent wins on a row that is also open', (
    tester,
  ) async {
    final selection = ValueNotifier<String?>('A');
    addTearDown(selection.dispose);
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
      selection: selection,
      platform: TargetPlatform.linux,
    );
    final scheme = _scheme(tester);
    await ctrlClick(tester, 'apples');

    expect(
      _hasWash(tester, 'apples', multiSelectWash(scheme)),
      isTrue,
      reason: 'a selected row keeps its bulk-op tint',
    );
    expect(
      _hasAccentBar(tester, 'apples', scheme.primary),
      isTrue,
      reason: 'and its left accent bar',
    );
    expect(
      _hasWash(tester, 'apples', openDetailWash(scheme)),
      isFalse,
      reason: 'the open wash must not compete with it',
    );
  });

  testWidgets('the open wash is visually distinct from the multi-select tint', (
    tester,
  ) async {
    await pumpList(tester, initial: [row('A', 'apples')], lists: oneList);
    final scheme = _scheme(tester);
    expect(openDetailWash(scheme), isNot(multiSelectWash(scheme)));
  });

  testWidgets('the wash changes no row geometry', (tester) async {
    final selection = ValueNotifier<String?>(null);
    addTearDown(selection.dispose);
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
      selection: selection,
    );
    final before = tester.getSize(_rowNamed('apples'));

    selection.value = 'A';
    await settleList(tester);

    expect(tester.getSize(_rowNamed('apples')), before);
  });

  testWidgets('an open task with no visible row highlights nothing', (
    tester,
  ) async {
    // A subtask never renders as a row (invariant #1), but the detail can be
    // open on one — reached from search, which lands on the parent's list. The
    // list must simply show no highlight rather than washing the parent.
    final selection = ValueNotifier<String?>('A1');
    addTearDown(selection.dispose);
    await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('A1', 'cider', parent: 'A'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
      selection: selection,
    );

    final wash = openDetailWash(_scheme(tester));
    expect(find.text('cider'), findsNothing, reason: 'subtasks are not rows');
    expect(_hasWash(tester, 'apples', wash), isFalse);
    expect(_hasWash(tester, 'bread', wash), isFalse);
  });
}
