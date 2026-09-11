import 'package:axiotask/src/app/local_calendar_day.dart';
import 'package:axiotask/src/ui/date_format.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a mounted due label refreshes immediately when the app resumes',
    (tester) async {
      // This prevents the resumed detail/list surface from continuing to say
      // "today" after its task has become overdue while mobile timers slept.
      var now = DateTime(2026, 9, 10, 22);
      await withClock(Clock(() => now), () async {
        await tester.pumpWidget(
          ProviderScope(
            child: LocalCalendarDayLifecycleObserver(
              child: MaterialApp(
                home: Consumer(
                  builder: (context, ref, _) {
                    ref.watch(localCalendarDayProvider);
                    return Text(formatDue('2026-09-10'));
                  },
                ),
              ),
            ),
          ),
        );
        expect(find.text('today'), findsOneWidget);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        now = DateTime(2026, 9, 11, 9);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        expect(find.text('yesterday'), findsOneWidget);
      });
    },
  );

  test('disposing the shared day owner cancels its scheduled boundary', () {
    // A cancelled owner must not retain a midnight callback after its scope is
    // gone; that would leak work across a test/app teardown.
    fakeAsync((async) {
      withClock(Clock(() => DateTime(2026, 9, 10, 23, 59)), () {
        final scheduler = LocalCalendarDayScheduler(() {});
        scheduler.schedule();
        expect(async.pendingTimers, hasLength(1));
        scheduler.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
