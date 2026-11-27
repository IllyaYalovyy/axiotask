// The "Add a subtask" field is the FIRST item of the subtasks section (#304):
// a new subtask is created first among its siblings (#302), so the field and
// the row it creates have to sit at the same end of the checklist. Positions
// are read off the laid-out widgets, so this is the order the user sees.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

Finder _field() => find.widgetWithText(TextField, 'Add a subtask');

// The phone panel is narrow and coarse-pointer, the desktop one wide and fine.
const _layouts = {
  'compact (phone)': (Size(400, 2400), TargetPlatform.android),
  'wide (desktop)': (Size(1000, 2400), TargetPlatform.linux),
};

void main() {
  for (final MapEntry(key: name, value: (size, platform)) in _layouts.entries) {
    group(name, () {
      testWidgets('the field is above every open and completed row', (
        tester,
      ) async {
        await pumpDetail(
          tester,
          taskId: 'P',
          size: size,
          theme: ThemeData(platform: platform),
          initial: [
            row('P', 'Parent'),
            row('s1', 'open one', parent: 'P', position: '1'),
            row('s2', 'finished', parent: 'P', position: '2', done: true),
            row('s3', 'open two', parent: 'P', position: '3'),
          ],
        );

        final field = tester.getRect(_field());
        expect(
          tester.getRect(find.text('Subtasks')).bottom,
          lessThanOrEqualTo(field.top),
          reason: 'the section header still opens the section',
        );
        for (final below in [
          find.text('open one'),
          find.text('open two'),
          find.byKey(const Key('completed-subtasks-toggle')),
          find.text('finished'),
        ]) {
          expect(tester.getRect(below).top, greaterThan(field.bottom));
        }
      });

      testWidgets('subtasks typed in a row each land directly under it', (
        tester,
      ) async {
        var n = 0;
        await pumpDetail(
          tester,
          taskId: 'P',
          size: size,
          theme: ThemeData(platform: platform),
          initial: [row('P', 'Parent')],
          newId: () => 'new-${++n}',
        );
        expect(find.byKey(const Key('subtasks-empty-hint')), findsOneWidget);
        expect(
          tester.getRect(find.byKey(const Key('subtasks-empty-hint'))).top,
          greaterThan(tester.getRect(find.text('Subtasks')).bottom),
        );

        await tester.tap(_field());
        await tester.pump();

        // No second tap: text reaches the field only if it kept focus.
        Future<void> typeAndSubmit(String title) async {
          tester.testTextInput.enterText(title);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await settleDetail(tester);
          final field = tester.widget<TextField>(_field());
          expect(field.controller?.text, isEmpty);
          expect(field.focusNode?.hasFocus, isTrue);
        }

        await typeAndSubmit('first');
        await typeAndSubmit('second');
        await typeAndSubmit('third');

        expect(subtaskOrder(tester, ['first', 'second', 'third']), [
          'third',
          'second',
          'first',
        ]);
        expect(
          tester.getRect(find.text('third')).top,
          greaterThan(tester.getRect(_field()).bottom),
        );
        expect(find.byKey(const Key('subtasks-empty-hint')), findsNothing);
      });
    });
  }
}
