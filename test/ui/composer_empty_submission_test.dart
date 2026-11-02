import 'package:axiotask/src/app/pending_edits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list;
import 'list_harness.dart' show pumpList, settleList;

void main() {
  for (final backgroundFlush in [false, true]) {
    final action = backgroundFlush ? 'background flush' : 'submission';
    testWidgets('empty $action does not block a later real task', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [],
        lists: [list('L1', 'My Tasks')],
        platform: TargetPlatform.linux,
      );
      final bar = find.byKey(const Key('quick-add-bar'));
      if (backgroundFlush) {
        final container = ProviderScope.containerOf(tester.element(bar));
        container.read(pendingEditsProvider).flushAll();
      } else {
        await tester.tap(find.byKey(const Key('quick-add-submit')));
      }
      await settleList(tester);
      expect(fake.tasks, isEmpty);

      final field = find.descendant(of: bar, matching: find.byType(TextField));
      await tester.enterText(field, 'New task after empty draft');
      await tester.tap(find.byKey(const Key('quick-add-submit')));
      await settleList(tester);
      expect(fake.tasks.single.task.title, 'New task after empty draft');
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    });
  }
}
