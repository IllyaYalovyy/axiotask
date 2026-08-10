// The guarded-command seam (T7.8): the single helper the UI routes a mutation
// through so a failure becomes a redacted error toast (never an unhandled
// exception) and a hung command trips the watchdog. This is where the three
// new pieces — watchdog + redaction + toast — meet.
//
// Asserts the OBSERVABLE outcome: what the toast controller holds after the
// command runs (the user-visible toast), not that some method fired.

import 'package:axiotask/src/ui/guarded_command.dart';
import 'package:axiotask/src/ui/toast.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('guardCommand', () {
    test('a successful command shows no toast', () async {
      final toasts = ToastController();
      addTearDown(toasts.dispose);
      await guardCommand(toasts, 'create_list', () async {});
      expect(toasts.toasts, isEmpty);
    });

    test('a raw store failure surfaces a redacted error toast', () async {
      final toasts = ToastController();
      addTearDown(toasts.dispose);
      await guardCommand(
        toasts,
        'create_list',
        () async => throw Exception('sql: UNIQUE constraint failed'),
      );
      expect(toasts.toasts, hasLength(1));
      final shown = toasts.toasts.single;
      expect(shown.variant, ToastVariant.error);
      // Redacted: the raw SQL never reaches the user; a family sentence does.
      expect(shown.message.toLowerCase(), isNot(contains('sql')));
      expect(shown.message.toLowerCase(), contains('update your lists'));
      expect(shown.message.toLowerCase(), contains('log'));
    });

    test('an authored refusal is surfaced verbatim', () async {
      final toasts = ToastController();
      addTearDown(toasts.dispose);
      await guardCommand(
        toasts,
        'move_task',
        () async => throw Exception(
          'cannot nest under a subtask: subtasks are one level deep',
        ),
      );
      expect(
        toasts.toasts.single.message,
        contains('cannot nest under a subtask'),
      );
    });

    test('a hung command trips the watchdog and toasts "taking too long"', () {
      fakeAsync((async) {
        final toasts = ToastController();
        // Never completes → the watchdog must return control.
        guardCommand(
          toasts,
          'sync_now',
          () => Future<void>.delayed(const Duration(hours: 1)),
        );
        // Just past sync's 5-minute budget — far enough to trip the watchdog,
        // not so far the freshly-shown toast auto-dismisses (5s life).
        async.elapse(const Duration(minutes: 5, seconds: 1));
        expect(toasts.toasts, hasLength(1));
        expect(
          toasts.toasts.single.message.toLowerCase(),
          contains('taking too long'),
        );
        toasts.dispose();
      });
    });
  });
}
