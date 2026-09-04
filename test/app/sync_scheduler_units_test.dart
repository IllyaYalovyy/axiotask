// T5.9 scheduler — the PURE units of the sync scheduler (MIGRATION-PLAN §5):
// the backoff curve, the sanitized user messages (#128/#135), the log-dedup
// classifier (#131), the trigger/debounce timing, and the SyncStatusView
// privacy boundary. None of these touch the database or the network, so they
// run against fake time only — the DB-backed run_sync behaviors live in
// `sync_scheduler_test.dart`.
//
// Assertions read the VALUES the policy produces — the message a user would
// see, the level a line is logged at, the delay before the next poll — never
// which method was called.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/http_tasks_api.dart';
import 'package:axiotask/src/app/sync_scheduler.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/store/store_error.dart';
import 'package:axiotask/src/sync/sync_error.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../api/support/fake_authed_client.dart';

void main() {
  group('backoffPeriod', () {
    const base = Duration(seconds: 60);
    const cap = Duration(seconds: 3600);

    test('stays at base while healthy (no permanent-failure streak)', () {
      expect(backoffPeriod(base, 0, cap), base);
    });

    test('doubles per failure, then pins to the cap', () {
      expect(backoffPeriod(base, 1, cap), const Duration(seconds: 120));
      expect(backoffPeriod(base, 2, cap), const Duration(seconds: 240));
      expect(backoffPeriod(base, 3, cap), const Duration(seconds: 480));
      // 60 * 2^6 = 3840s would exceed the hour cap → pinned to the cap.
      expect(backoffPeriod(base, 6, cap), cap);
      // A pathologically large streak can never overflow the shift/multiply.
      expect(backoffPeriod(base, 1 << 31, cap), cap);
    });
  });

  group('syncUserMessage — the sanitized text the UI renders', () {
    test('a store failure hides the SQL from the user', () {
      // A store failure during sync carries raw SQL text. lastError is rendered
      // in the "Sync failed" toast and Properties dialog, so it must not carry
      // that detail.
      final e = SyncStoreError(StoreSqlError('no such column: foo'));
      expect(
        e.toString(),
        contains('no such column'),
        reason: 'precondition: the raw error leaks the SQL',
      );

      final shown = syncUserMessage(e);
      expect(shown, isNot(contains('no such column')));
      expect(shown.toLowerCase(), contains('log'), reason: 'points at the log');
    });

    test('an internal failure is calm and mentions the log, not the bug', () {
      final e = SyncInternalError('assertion x != y failed');
      final shown = syncUserMessage(e);
      expect(shown, isNot(contains('assertion')));
      expect(shown.toLowerCase(), contains('log'));
    });

    test('API failures that are already human keep their text', () {
      // API errors are already human and never carry SQL — keep them so the
      // user still sees "server error: 503" rather than a generic sentence.
      final e = SyncApiError(const ServerError(503));
      expect(syncUserMessage(e), 'server error: 503');
    });

    test('a network failure hides the request URL from the user (#135)', () {
      // Network embeds raw transport text, which can include the full request
      // URL and its query params. lastError is rendered verbatim, so it must
      // carry NONE of that — only a calm sentence naming Google.
      const raw =
          'error sending request for url '
          '(https://tasks.googleapis.com/tasks/v1/users/@me/lists?key=SECRET): '
          'connection reset by peer';
      final e = SyncApiError(const Network(raw));
      expect(
        e.toString(),
        contains('https://'),
        reason: 'precondition: the raw error leaks the URL',
      );

      final shown = syncUserMessage(e);
      expect(shown, isNot(contains('https://')));
      expect(shown, isNot(contains('googleapis')));
      expect(shown, isNot(contains('SECRET')));
      expect(
        shown.toLowerCase(),
        contains('google'),
        reason: 'the calm message names Google so the user knows what is down',
      );
    });
  });

  group('apiUserText — the internals-free API-error text', () {
    test('the already-human variants keep their (internals-free) text', () {
      expect(apiUserText(const Unauthorized()), 'unauthorized');
      expect(apiUserText(const NotFound()), 'not found');
      expect(
        apiUserText(const PreconditionFailed()),
        'precondition failed (etag mismatch)',
      );
      expect(apiUserText(const RateLimited()), 'rate limited');
      expect(apiUserText(const ServerError(503)), 'server error: 503');
    });

    test('AuthExpired and Network never surface their raw detail (#187)', () {
      // These two arms carry raw detail (a refresh-denial string; transport
      // text that can embed the request URL + query params, #135). They are
      // dead — intercepted upstream — but apiUserText is a public function, so
      // routing one through must still yield a calm, log-pointing sentence with
      // NONE of the raw text.
      const secretGrant = 'invalid_grant: token for user@example.com revoked';
      const secretUrl =
          'error sending request for url '
          '(https://tasks.googleapis.com/tasks/v1/lists?key=SECRET)';

      final auth = apiUserText(const AuthExpired(secretGrant));
      expect(auth, isNot(contains('invalid_grant')));
      expect(auth, isNot(contains('user@example.com')));
      expect(auth.toLowerCase(), contains('log'), reason: 'points at the log');

      final net = apiUserText(const Network(secretUrl));
      expect(net, isNot(contains('https://')));
      expect(net, isNot(contains('SECRET')));
      expect(net.toLowerCase(), contains('log'));
    });

    test('a captive-portal HTML decode error never surfaces the body on the '
        'sync status (G6 / #204, #187)', () async {
      // The end-to-end status-sanitization case: a captive portal answers 200
      // with an HTML login page, the real client fails to decode it, and the
      // resulting error flows through syncUserMessage into the UI-facing
      // lastError. The rendered status must carry NONE of the HTML body — no
      // markup, no secret-bearing login URL — only the decode label. The
      // failure is also TRANSIENT (#270): nothing in that response came from
      // Google, so the run retries silently instead of raising a permanent
      // "needs attention" for a condition that clears itself.
      const captivePortalHtml =
          '<!DOCTYPE html><html><head><title>Wi-Fi Login</title></head>'
          '<body>Please sign in at http://wifi.local/login?token=SECRET'
          '</body></html>';
      final auth = FakeAuthedClient(
        (req, i) => http.Response(
          captivePortalHtml,
          200,
          headers: const {'content-type': 'text/html'},
        ),
      );
      final api = HttpTasksApi(
        auth,
        baseUrl: 'https://mock.test',
        maxRetries: 0,
      );

      ApiError? decodeError;
      try {
        await api.listTasklists();
      } on ApiError catch (e) {
        decodeError = e;
      }
      expect(decodeError, isNotNull, reason: 'the HTML body fails to decode');
      expect(
        decodeError!.isTransient,
        isTrue,
        reason: 'a body Google did not write is a blip, not a rejection (#270)',
      );

      // What the "Sync failed" toast / Properties dialog would render.
      final shown = syncUserMessage(SyncApiError(decodeError));
      expect(shown, isNot(contains('<html')));
      expect(shown, isNot(contains('wifi.local')));
      expect(shown, isNot(contains('SECRET')));
    });
  });

  group('classifyPermanentFailure — log-dedup keyed on the RAW detail (#131)', () {
    test('logs at ERROR only when new or changed', () {
      final boom = SyncApiError(const OtherApiError('boom'));
      final kaput = SyncApiError(const OtherApiError('kaput'));
      final rawBoom = boom.toString();

      // First failure of a healthy sync → ERROR.
      expect(classifyPermanentFailure(false, null, boom).logAtError, isTrue);
      // Same error repeating while already in attention → DEBUG (no spam).
      expect(classifyPermanentFailure(true, rawBoom, boom).logAtError, isFalse);
      // A *different* permanent error while in attention → ERROR again.
      expect(classifyPermanentFailure(true, rawBoom, kaput).logAtError, isTrue);
      // Re-entering attention after a clear (prevAttention false) → ERROR.
      expect(classifyPermanentFailure(false, rawBoom, boom).logAtError, isTrue);
    });

    test(
      'distinct root causes re-log at ERROR despite identical display text',
      () {
        // Two DIFFERENT store failures both sanitize to the SAME calm sentence
        // (SQL is hidden). The dedup must key on the RAW typed detail, not that
        // display text — otherwise the second, genuinely-new root cause is
        // swallowed as a "repeat" and buried at DEBUG.
        final first = SyncStoreError(StoreSqlError('no such column: foo'));
        final second = SyncStoreError(StoreSqlError('no such table: bar'));

        final a = classifyPermanentFailure(false, null, first);
        expect(
          a.logAtError,
          isTrue,
          reason: 'first distinct failure logs ERROR',
        );
        // Precondition the fix depends on: distinct raw, identical display.
        expect(a.rawDetail, isNot(second.toString()));
        expect(
          a.userMsg,
          classifyPermanentFailure(false, null, second).userMsg,
          reason: 'both sanitize to the same user-facing sentence',
        );

        // The second failure arrives while already in attention, with the first
        // failure's RAW detail remembered.
        final b = classifyPermanentFailure(true, a.rawDetail, second);
        expect(
          b.logAtError,
          isTrue,
          reason:
              'a distinct root cause re-logs at ERROR despite identical text',
        );

        // …but an *identical* raw failure repeating stays DEBUG (no spam).
        final c = classifyPermanentFailure(true, a.rawDetail, first);
        expect(
          c.logAtError,
          isFalse,
          reason: 'identical raw repeat stays DEBUG',
        );

        // The raw detail reaches the log (carries the SQL); the user message hides it.
        expect(a.rawDetail, contains('no such column: foo'));
        expect(a.userMsg, isNot(contains('no such column')));
      },
    );
  });

  group('SyncStatusView — the UI-facing projection (#131)', () {
    test('never carries the raw error, even when the status holds SQL', () {
      final status = SyncStatus()
        ..lastError = 'Sync hit a local database problem — see the log.'
        ..lastRawError =
            'SyncError.store(StoreError: no such column: secret_col)'
        ..needsAttention = true;

      final view = SyncStatusView.of(status);

      // The sanitized message survives to the UI…
      expect(view.lastError, contains('local database problem'));
      expect(view.needsAttention, isTrue);
      // …but the raw detail has NO field on the view at all — the type simply
      // cannot express it, so no SQL can leak through this surface. Nothing the
      // view exposes contains the raw column name.
      final exposed = [
        view.lastError,
        view.lastSynced,
      ].whereType<String>().join(' ');
      expect(exposed, isNot(contains('secret_col')));
    });
  });

  group('SyncNotify — single-permit coalescing', () {
    test('a permit stored before the wait resolves it immediately', () async {
      final notify = SyncNotify()..notifyOne();
      // Completes without any further notifyOne.
      await notify.notified().timeout(const Duration(seconds: 1));
    });

    test('multiple notifications before a wait coalesce into ONE permit', () {
      fakeAsync((async) {
        final notify = SyncNotify()
          ..notifyOne()
          ..notifyOne()
          ..notifyOne();

        var firstDone = false;
        var secondDone = false;
        notify.notified().then((_) => firstDone = true);
        async.flushMicrotasks();
        expect(firstDone, isTrue, reason: 'the coalesced permit resolves once');

        // The three notifications collapsed to a single permit — the next wait
        // has nothing pending and stays open.
        notify.notified().then((_) => secondDone = true);
        async.flushMicrotasks();
        expect(secondDone, isFalse, reason: 'only one permit was ever pending');
      });
    });
  });

  group('waitForSyncTrigger — trigger/debounce timing', () {
    const debounce = Duration(seconds: 2);
    const period = Duration(seconds: 60);

    test('fires after the debounce window on a mutation', () {
      fakeAsync((async) {
        final notify = SyncNotify()..notifyOne(); // a mutation happened
        Duration? firedAt;
        waitForSyncTrigger(
          notify,
          debounce,
          period,
        ).then((_) => firedAt = async.elapsed);

        async.flushTimers();
        expect(firedAt, debounce, reason: 'debounce, not the full period');
      });
    });

    test('fires after the period when idle', () {
      fakeAsync((async) {
        final notify = SyncNotify(); // no mutation
        Duration? firedAt;
        waitForSyncTrigger(
          notify,
          debounce,
          period,
        ).then((_) => firedAt = async.elapsed);

        async.flushTimers();
        expect(firedAt, period);
      });
    });

    test('an idle-arm win must not swallow a later notifyOne (#186)', () {
      // The lost-permit race: the first cycle goes idle (period wins), which
      // leaves a stale notified() waiter registered inside SyncNotify. A
      // mutation then arrives. If notifyOne() completes that dead waiter
      // without re-arming the permit, the mutation is swallowed and the next
      // cycle waits out ANOTHER full idle period instead of firing promptly.
      fakeAsync((async) {
        final notify = SyncNotify();

        // Cycle 1: no mutation → the idle period wins.
        Duration? firstFiredAt;
        waitForSyncTrigger(
          notify,
          debounce,
          period,
        ).then((_) => firstFiredAt = async.elapsed);
        async.flushTimers();
        expect(firstFiredAt, period, reason: 'the idle arm wins cycle 1');

        // A mutation lands AFTER cycle 1 already resolved on the idle arm.
        notify.notifyOne();

        // Cycle 2 must observe that mutation immediately — a debounce trigger,
        // not a full idle period. Without the fix the queued permit is lost
        // and this fires at +period instead.
        final startedAt = async.elapsed;
        Duration? secondFiredAt;
        waitForSyncTrigger(
          notify,
          debounce,
          period,
        ).then((_) => secondFiredAt = async.elapsed);
        async.flushTimers();

        expect(
          secondFiredAt! - startedAt,
          debounce,
          reason:
              'the queued mutation fires after the debounce, not the '
              'period — the permit survived the idle-arm win',
        );
      });
    });

    test(
      'rapid mutations coalesce into one trigger, then fall to the period',
      () {
        fakeAsync((async) {
          final notify = SyncNotify()
            ..notifyOne()
            ..notifyOne()
            ..notifyOne();

          final marks = <Duration>[];
          () async {
            await waitForSyncTrigger(notify, debounce, period);
            marks.add(async.elapsed);
            // No new mutations → the next wait falls through to the periodic timer.
            await waitForSyncTrigger(notify, debounce, period);
            marks.add(async.elapsed);
          }();

          async.flushTimers();
          expect(marks, hasLength(2));
          expect(
            marks[0],
            debounce,
            reason: 'first trigger after the debounce',
          );
          expect(
            marks[1],
            debounce + period,
            reason: 'the coalesced permit was already spent; period fires next',
          );
        });
      },
    );
  });
}
