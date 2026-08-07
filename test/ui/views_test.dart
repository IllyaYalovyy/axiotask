// Protects the window-title contract "<View> — axiotask" (port of the
// reference's App.svelte title map + WindowTitle.test.js) and the guarantee
// that a stale/unknown persisted view never yields a blank title.

import 'package:axiotask/src/ui/views.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SmartView', () {
    test('byId resolves a smart view and returns null for a list id', () {
      expect(SmartView.byId('all'), SmartView.all);
      expect(SmartView.byId('focus'), SmartView.focus);
      // A list id (or anything unknown) is not a smart view.
      expect(SmartView.byId('L1'), isNull);
    });

    test(
      'the five views are ordered Focus-first, as the reference lists them',
      () {
        expect(SmartView.values.map((v) => v.id).toList(), [
          'focus',
          'upcoming',
          'missed',
          'unscheduled',
          'all',
        ]);
      },
    );
  });

  group('viewLabelFor', () {
    test('smart views map to their human labels', () {
      expect(viewLabelFor('focus'), 'Focus');
      expect(viewLabelFor('upcoming'), 'Upcoming');
      expect(viewLabelFor('missed'), 'Missed');
      expect(viewLabelFor('unscheduled'), 'Unscheduled');
      expect(viewLabelFor('all'), 'All Tasks');
    });

    test('a list id resolves to its title', () {
      expect(viewLabelFor('L1', listTitles: {'L1': 'Work'}), 'Work');
    });

    test('an unknown view falls back to All Tasks (never blank)', () {
      // A stale view id persisted by an older build must still title sensibly.
      expect(viewLabelFor('deleted-list-id'), 'All Tasks');
    });
  });

  group('windowTitleFor', () {
    test('a smart view produces "<label> — axiotask"', () {
      expect(windowTitleFor('focus'), 'Focus — axiotask');
      expect(windowTitleFor('all'), 'All Tasks — axiotask');
    });

    test('a selected list uses the list title', () {
      expect(
        windowTitleFor('L1', listTitles: {'L1': 'Work'}),
        'Work — axiotask',
      );
    });

    test('a dev instance keeps its prefix badge in the title', () {
      // The reference dropped the prefix once the UI took over the title; we
      // preserve it so an isolated run is never mistaken for production.
      expect(
        windowTitleFor('focus', instancePrefix: 'dev'),
        'Focus — axiotask (dev)',
      );
    });
  });
}
