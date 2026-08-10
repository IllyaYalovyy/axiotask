// The redaction surface (T7.8): the last-line guard that turns a raw command
// failure into the calm sentence a toast shows the user. Port of the
// reference's `friendlyError` allowlist (#128/#135).
//
// The guard is an ALLOWLIST: only messages WE author (validation refusals the
// user must understand, and the two auth signals) pass through verbatim;
// everything else — raw SQL, raw reqwest network text that can embed a request
// URL and its query params, a brand-new internal string we never taught the
// guard about — is redacted to a family-scoped "a local error occurred, see the
// log" sentence. These assert exactly what reaches the toast.

import 'package:axiotask/src/app/command_watchdog.dart';
import 'package:axiotask/src/ui/user_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('commandUserMessage — redaction (#128/#135)', () {
    test('hides raw SQL/sqlx detail, points at the log', () {
      final msg = commandUserMessage(
        'toggle_complete',
        Exception('sql: UNIQUE constraint failed: tasks.id, tasks.list_id'),
      );
      expect(msg.toLowerCase(), isNot(contains('sql:')));
      expect(msg.toLowerCase(), isNot(contains('constraint')));
      expect(msg.toLowerCase(), isNot(contains('tasks.id')));
      expect(msg.toLowerCase(), contains('log'));
    });

    test('redacts raw reqwest network text carrying a URL and secret', () {
      final msg = commandUserMessage(
        'sync_now',
        Exception(
          'network: error sending request for url '
          '(https://tasks.googleapis.com/tasks/v1/lists?key=SECRET): reset',
        ),
      );
      expect(msg, isNot(contains('https://')));
      expect(msg.toLowerCase(), isNot(contains('googleapis')));
      expect(msg, isNot(contains('SECRET')));
      expect(msg.toLowerCase(), contains('log'));
    });

    test('redacts a brand-new no-marker internal string', () {
      final msg = commandUserMessage(
        'toggle_complete',
        Exception('kaboom widget 42: the frobnicator overheated'),
      );
      expect(msg.toLowerCase(), isNot(contains('kaboom')));
      expect(msg.toLowerCase(), isNot(contains('frobnicator')));
      expect(msg.toLowerCase(), contains('log'));
    });

    test('a redacted message names the family action for what was done', () {
      // A generic task mutation → "save your change".
      expect(
        commandUserMessage('toggle_complete', Exception('boom')).toLowerCase(),
        contains('save your change'),
      );
      // A list command → "update your lists".
      expect(
        commandUserMessage('create_list', Exception('boom')).toLowerCase(),
        contains('update your lists'),
      );
      // Sync → "sync with Google".
      expect(
        commandUserMessage('sync_now', Exception('boom')).toLowerCase(),
        contains('sync with google'),
      );
      // Backup import → "restore your backup".
      expect(
        commandUserMessage('import_backup', Exception('boom')).toLowerCase(),
        contains('restore your backup'),
      );
    });
  });

  group('commandUserMessage — authored messages pass verbatim (#128)', () {
    test('a two-level-nesting refusal is shown verbatim', () {
      const authored =
          'cannot nest under a subtask: subtasks are one level deep';
      expect(
        commandUserMessage('move_task', Exception(authored)),
        contains('cannot nest under a subtask'),
      );
    });

    test('an invalid-due-date refusal is shown verbatim', () {
      expect(
        commandUserMessage(
          'set_due',
          Exception('invalid due date: 2026-13-40'),
        ),
        contains('invalid due date'),
      );
    });

    test('a "task <id> not found" refusal is shown verbatim', () {
      expect(
        commandUserMessage('rename_task', Exception('task abc-123 not found')),
        contains('task abc-123 not found'),
      );
    });

    test(
      'a network error that merely CONTAINS "not found" is still redacted',
      () {
        // The not-found allowance is pinned to the exact authored shape, so a raw
        // error that happens to contain the words does not slip through.
        final msg = commandUserMessage(
          'sync_now',
          Exception('network: 404 page not found at https://evil/x'),
        );
        expect(msg, isNot(contains('https://')));
        expect(msg.toLowerCase(), contains('log'));
      },
    );
  });

  group('commandUserMessage — auth + timeout signals', () {
    test('a not-authenticated error becomes the sign-in nudge', () {
      final msg = commandUserMessage(
        'sync_now',
        Exception('not authenticated'),
      );
      expect(msg, contains('Not signed in'));
    });

    test('a session-expired error becomes the re-auth nudge', () {
      final msg = commandUserMessage(
        'sync_now',
        Exception('Google session expired — sign in again to resume sync'),
      );
      expect(msg.toLowerCase(), contains('session expired'));
      expect(msg.toLowerCase(), contains('sign in again'));
    });

    test('a CommandTimeoutError becomes the "taking too long" reassurance', () {
      final msg = commandUserMessage(
        'sync_now',
        const CommandTimeoutError('sync_now', Duration(minutes: 5)),
      );
      expect(msg, contains('sync_now'));
      expect(msg.toLowerCase(), contains('taking too long'));
      expect(msg.toLowerCase(), contains('still responsive'));
    });
  });
}
