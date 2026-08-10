// The command watchdog (T7.8): a per-family time budget around an async
// command so a hung operation returns control to the UI instead of leaving it
// stuck forever. Port of the reference's `invokeWithTimeout` / `timeoutFor`.
//
// These assert the OBSERVABLE outcome — the future the caller awaits either
// resolves with the command's value or rejects with a [CommandTimeoutError]
// naming the command and its budget — not that some timer was scheduled.
// Timing is driven by `fakeAsync`, never a real clock, so the hung-command
// test is deterministic.

import 'dart:async';

import 'package:axiotask/src/app/command_watchdog.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('timeoutFor', () {
    test('a plain command gets the default 12s budget', () {
      expect(timeoutFor('toggle_complete'), kDefaultCommandTimeout);
      expect(kDefaultCommandTimeout, const Duration(seconds: 12));
    });

    test('network/user-paced families get their longer budgets', () {
      // auth_login is paced by the human completing browser consent; sync is
      // network-bound with backoff — a uniform 12s would strand them mid-flow.
      expect(timeoutFor('auth_login'), const Duration(minutes: 10));
      expect(timeoutFor('sync_now'), const Duration(minutes: 5));
      expect(timeoutFor('fresh_sync'), const Duration(minutes: 5));
      expect(timeoutFor('import_backup'), const Duration(minutes: 1));
      expect(timeoutFor('export_backup'), const Duration(minutes: 1));
    });
  });

  group('runCommandWithTimeout', () {
    test('a fast command resolves with its value, no timeout', () {
      fakeAsync((async) {
        Object? value;
        runCommandWithTimeout('create_list', () async => 42).then((v) {
          value = v;
        });
        async.flushMicrotasks();
        expect(value, 42);
        // No pending timer strands the zone once the command has resolved.
        expect(async.pendingTimers, isEmpty);
      });
    });

    test(
      'a hung command rejects with CommandTimeoutError after its budget',
      () {
        fakeAsync((async) {
          Object? caught;
          // A future that never completes — the classic hung IPC/network call.
          runCommandWithTimeout(
            'list_tasklists',
            () => Completer<void>().future,
          ).catchError((Object e) => caught = e);

          // Just before the 12s default budget: still hung, nothing thrown.
          async.elapse(const Duration(seconds: 11));
          expect(caught, isNull);

          // Past the budget: the watchdog fires and returns control.
          async.elapse(const Duration(seconds: 2));
          expect(caught, isA<CommandTimeoutError>());
          final e = caught! as CommandTimeoutError;
          expect(e.command, 'list_tasklists');
          expect(e.timeout, const Duration(seconds: 12));
          expect(e.toString(), contains('list_tasklists'));
          expect(e.toString(), contains('12s'));
        });
      },
    );

    test("a command's longer family budget is honored, not the default", () {
      fakeAsync((async) {
        Object? caught;
        runCommandWithTimeout(
          'sync_now',
          () => Completer<void>().future,
        ).catchError((Object e) => caught = e);

        // The default budget passes with no timeout — sync gets 5 minutes.
        async.elapse(const Duration(seconds: 30));
        expect(caught, isNull);

        async.elapse(const Duration(minutes: 5));
        expect(caught, isA<CommandTimeoutError>());
        expect(
          (caught! as CommandTimeoutError).timeout,
          const Duration(minutes: 5),
        );
      });
    });

    test('an explicit timeout overrides the family default', () {
      fakeAsync((async) {
        Object? caught;
        runCommandWithTimeout(
          'sync_now',
          () => Completer<void>().future,
          timeout: const Duration(seconds: 3),
        ).catchError((Object e) => caught = e);

        async.elapse(const Duration(seconds: 4));
        expect(caught, isA<CommandTimeoutError>());
        expect(
          (caught! as CommandTimeoutError).timeout,
          const Duration(seconds: 3),
        );
      });
    });

    test('a command that throws propagates its own error, not a timeout', () {
      fakeAsync((async) {
        Object? caught;
        runCommandWithTimeout<void>('create_list', () async {
          throw StateError('boom');
        }).catchError((Object e) => caught = e);
        async.flushMicrotasks();
        expect(caught, isA<StateError>());
      });
    });
  });
}
