// OpenInGoogle — row half (MIGRATION-PLAN §5 T7.2). The row half of the
// open-in-browser surface: a task whose title or notes carries an http(s) link
// shows a link badge whose tap hands the FIRST detected URL to the opener. The
// "+N" count communicates that more links live in the task (opened from the
// detail panel). The full "Open in Google Tasks" action lands in T7.5; this
// pins the row's URL affordance and that the opener is fed the right URL. The
// opener here is a spy — the real url_launcher channel is never touched.

import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> pumpRow(
    WidgetTester tester, {
    String title = 'plain task',
    String? notes,
    ValueChanged<String>? onOpenUrl,
  }) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskRow(
            title: title,
            notes: notes,
            completed: false,
            onOpen: () {},
            onToggle: () {},
            onRename: (_) {},
            onOpenUrl: onOpenUrl ?? opened.add,
          ),
        ),
      ),
    );
    return opened;
  }

  testWidgets('no link badge when the task has no URL', (tester) async {
    await pumpRow(tester, title: 'buy milk', notes: 'from the corner shop');
    expect(find.byKey(const Key('link-badge')), findsNothing);
  });

  testWidgets('a task with a URL shows a badge that opens the first URL', (
    tester,
  ) async {
    final opened = await pumpRow(
      tester,
      title: 'read https://example.com/spec',
    );
    expect(find.byKey(const Key('link-badge')), findsOneWidget);

    await tester.tap(find.byKey(const Key('link-badge')));
    await tester.pump();
    expect(opened, ['https://example.com/spec']);
  });

  testWidgets('a URL in the NOTES surfaces the badge too', (tester) async {
    final opened = await pumpRow(
      tester,
      title: 'follow up',
      notes: 'ticket at https://tracker.test/42',
    );
    await tester.tap(find.byKey(const Key('link-badge')));
    await tester.pump();
    expect(opened, ['https://tracker.test/42']);
  });

  testWidgets('multiple URLs open the first and show a "+N" count', (
    tester,
  ) async {
    final opened = await pumpRow(
      tester,
      title: 'see https://a.test and https://b.test',
      notes: 'also https://c.test',
    );
    // Two extra beyond the first → "+2".
    expect(find.text('+2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('link-badge')));
    await tester.pump();
    expect(opened, ['https://a.test'], reason: 'the FIRST URL opens');
  });

  testWidgets('the badge is hidden when no opener is wired', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskRow(
            title: 'read https://example.com',
            completed: false,
            onOpen: () {},
            onToggle: () {},
            onRename: (_) {},
            onOpenUrl: null,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('link-badge')), findsNothing);
  });
}
