// OpenInGoogle suite — the "Open in Google Tasks" affordance in TaskDetail
// (MIGRATION-PLAN §5 T7.5). Google assigns the webViewLink on sync, so the
// entry is present ONLY for a synced task and opens exactly that URL through
// the same url-opener seam the link badges use. A local, not-yet-synced task
// (webViewLink == null) offers nothing — the non-happy path.
//
// Since #246 it is an app-bar overflow entry, not a body button: the body's
// order is title → Due + List → notes, and a link out ranked above the fields
// the user edits. detail_hierarchy_test owns that placement rule.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

void main() {
  group('OpenInGoogle', () {
    testWidgets('a synced task offers the entry and opens its webViewLink', (
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

      await openDetailOverflow(tester);
      final entry = find.byKey(const Key('detail-open-google'));
      expect(entry, findsOneWidget);

      await tester.tap(entry);
      await settleDetail(tester);
      expect(opened, ['https://tasks.google.com/task/T1']);
    });

    testWidgets('a local (unsynced) task offers no Open-in-Google entry', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'T1',
        // No webViewLink — Google has not assigned one yet.
        initial: [row('T1', 'Draft')],
      );
      await openDetailOverflow(tester);
      expect(find.text('Open in Google Tasks'), findsNothing);
    });

    testWidgets('a subtask with a webViewLink also offers the entry', (
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

      await openDetailOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-open-google')));
      await settleDetail(tester);
      expect(opened, ['https://tasks.google.com/task/S1']);
    });
  });
}
