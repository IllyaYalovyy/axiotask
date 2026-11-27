// One Undo toast, driven by REAL list actions: complete, delete, move and bulk
// raise their toasts through their own code paths, and the screen still carries
// exactly one, for the newest of them.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/toast.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  Future<void> ctrlClick(WidgetTester tester, String title) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text(title));
    // The tap resolves after the double-tap timeout; hold Ctrl until then.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  Future<void> menu(WidgetTester tester, String title, List<String> ids) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(title)),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await settleList(tester);
    for (final id in ids) {
      await tester.tap(find.byKey(Key('taskmenu-$id')));
      await settleList(tester);
    }
  }

  Future<void> check(WidgetTester tester, String title) async {
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(TaskRow, title),
        matching: find.byType(Checkbox),
      ),
    );
    await settleList(tester);
  }

  Future<void> bulk(
    WidgetTester tester,
    List<String> titles,
    String button,
  ) async {
    for (final title in titles) {
      await ctrlClick(tester, title);
    }
    await tester.tap(find.byKey(Key(button)));
    await settleList(tester);
  }

  testWidgets('complete, delete, move and bulk leave one Undo, the newest', (
    tester,
  ) async {
    final fake = await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread'),
        row('C', 'cheese'),
        row('D', 'dates'),
        row('E', 'eggs'),
        row('F', 'figs'),
        row('G', 'grapes'),
      ],
      lists: [list('L1', 'My Tasks'), list('L2', 'Errands')],
    );

    Rect? single;
    void expectOnly(String message) {
      expect(find.byType(ToastCard), findsOneWidget);
      expect(find.text(message), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^\+\d')), findsNothing);
      final rect = tester.getRect(find.byType(ToastCard));
      single ??= rect;
      // Width follows the message; the corner and the height do not move.
      expect(rect.bottomRight, single!.bottomRight);
      expect(rect.height, single!.height);
    }

    await check(tester, 'apples');
    expectOnly('Completed "apples"');
    await menu(tester, 'bread', ['delete']);
    expectOnly('Deleted "bread"');
    await menu(tester, 'cheese', ['move', 'move-L2']);
    expectOnly('Moved "cheese" to Errands');
    await bulk(tester, ['dates', 'eggs'], 'bulk-complete');
    expectOnly('2 tasks completed');
    await check(tester, 'figs');
    expectOnly('Completed "figs"');
    await bulk(tester, ['grapes'], 'bulk-delete');
    expectOnly('1 task deleted');

    await tester.tap(find.text('Undo'));
    await settleList(tester);

    final byId = {for (final t in fake.tasks) t.task.id: t};
    // The newest action is reverted…
    expect(byId['G']?.task.status, TaskStatus.needsAction);
    // …and every earlier one, whose toast was replaced, stays done.
    for (final id in ['A', 'D', 'E', 'F']) {
      expect(byId[id]?.task.status, TaskStatus.completed, reason: id);
    }
    expect(byId.containsKey('B'), isFalse);
    expect(fake.movedToList, ['C->L2']);
    expect(find.byType(ToastCard), findsNothing);
  });
}
