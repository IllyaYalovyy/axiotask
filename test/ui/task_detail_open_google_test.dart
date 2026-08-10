// OpenInGoogle suite — the "Open in Google Tasks" affordance in TaskDetail
// (MIGRATION-PLAN §5 T7.5). Google assigns the webViewLink on sync, so the
// button is present ONLY for a synced task and opens exactly that URL through
// the same url-opener seam the link badges use. A local, not-yet-synced task
// (webViewLink == null) shows no button — the non-happy path.

import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

void main() {
  group('OpenInGoogle', () {
    testWidgets('a synced task shows the button and opens its webViewLink', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpDetail(
        tester,
        taskId: 'T1',
        initial: [
          row(
            'T1',
            'Renew passport',
            webViewLink: 'https://tasks.google.com/task/T1',
          ),
        ],
        urlOpener: (url) async => opened.add(url),
      );

      final button = find.text('Open in Google Tasks');
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pump();
      expect(opened, ['https://tasks.google.com/task/T1']);
    });

    testWidgets('a local (unsynced) task shows no Open-in-Google button', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'T1',
        // No webViewLink — Google has not assigned one yet.
        initial: [row('T1', 'Draft')],
      );
      expect(find.text('Open in Google Tasks'), findsNothing);
    });

    testWidgets('a subtask with a webViewLink also offers the button', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpDetail(
        tester,
        taskId: 'S1',
        initial: [
          row('P1', 'Parent'),
          row(
            'S1',
            'Child',
            parent: 'P1',
            webViewLink: 'https://tasks.google.com/task/S1',
          ),
        ],
        urlOpener: (url) async => opened.add(url),
      );

      await tester.tap(find.text('Open in Google Tasks'));
      await tester.pump();
      expect(opened, ['https://tasks.google.com/task/S1']);
    });
  });
}
