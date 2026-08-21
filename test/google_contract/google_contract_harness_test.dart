import 'package:flutter_test/flutter_test.dart';

import 'google_contract_harness.dart';

void main() {
  group('Google contract harness isolation', () {
    test(
      'API-008 missing subject stops before cleanup or a Tasks probe',
      () async {
        var cleanupCalls = 0;
        var taskCalls = 0;
        final harness = GoogleContractHarness(
          expectedSubject: '',
          resolveAuthenticatedSubject: () async => null,
          cleanup: () async => cleanupCalls += 1,
        );

        await expectLater(
          () => harness.run(() async => taskCalls += 1),
          throwsA(isA<GoogleContractSafetyException>()),
        );
        expect(cleanupCalls, 0);
        expect(taskCalls, 0);
      },
    );

    test('API-008 mismatch stops before cleanup or a Tasks probe', () async {
      var cleanupCalls = 0;
      var taskCalls = 0;
      final harness = GoogleContractHarness(
        expectedSubject: 'dedicated-subject-a',
        resolveAuthenticatedSubject: () async => 'different-subject-b',
        cleanup: () async => cleanupCalls += 1,
      );

      await expectLater(
        () => harness.run(() async => taskCalls += 1),
        throwsA(isA<GoogleContractSafetyException>()),
      );
      expect(cleanupCalls, 0);
      expect(taskCalls, 0);
    });

    test(
      'cleanup runs after each probe failure and preserves the failure',
      () async {
        var cleanupCalls = 0;
        final harness = GoogleContractHarness(
          expectedSubject: 'dedicated-subject',
          resolveAuthenticatedSubject: () async => 'dedicated-subject',
          cleanup: () async => cleanupCalls += 1,
        );

        await expectLater(
          () =>
              harness.run<void>(() async => throw StateError('probe failure')),
          throwsA(isA<StateError>()),
        );
        expect(cleanupCalls, 2);
      },
    );

    test(
      'cleanup failure is reported with the original probe failure',
      () async {
        var cleanupCalls = 0;
        final harness = GoogleContractHarness(
          expectedSubject: 'dedicated-subject',
          resolveAuthenticatedSubject: () async => 'dedicated-subject',
          cleanup: () async {
            cleanupCalls += 1;
            if (cleanupCalls == 2) throw StateError('cleanup failure');
          },
        );

        await expectLater(
          () =>
              harness.run<void>(() async => throw StateError('probe failure')),
          throwsA(
            isA<GoogleContractCleanupException>()
                .having((error) => error.primary, 'primary', isA<StateError>())
                .having((error) => error.cleanup, 'cleanup', isA<StateError>()),
          ),
        );
      },
    );

    test('only the unique contract prefix is admitted for stale cleanup', () {
      expect(
        isSafeGoogleContractPrefix(
          'axiotask-contract-probe-20260820T120000Z-a1b2c3',
        ),
        isTrue,
      );
      expect(
        isSafeGoogleContractPrefix('axiotask-contract-probe-20260820-a1b2c3'),
        isFalse,
      );
      expect(
        isSafeGoogleContractPrefix(
          'axiotask-contract-probe-20260820T120000Z-a1/b2c3',
        ),
        isFalse,
      );
      expect(
        isSafeGoogleContractPrefix('another-prefix-20260820T120000Z-a1b2c3'),
        isFalse,
      );
    });

    test('accepts only an HTTPS Google Tasks webViewLink shape', () {
      expect(
        hasGoogleTasksWebViewLinkShape('https://tasks.google.com/task/abc'),
        isTrue,
      );
      expect(
        hasGoogleTasksWebViewLinkShape('http://tasks.google.com/task/abc'),
        isFalse,
      );
      expect(
        hasGoogleTasksWebViewLinkShape('https://example.test/task/abc'),
        isFalse,
      );
    });
  });
}
