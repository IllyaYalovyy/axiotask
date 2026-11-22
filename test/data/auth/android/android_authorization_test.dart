import 'dart:async';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/android/android_authorization.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late _Gateway gateway;
  late ManualClock clock;
  late AndroidAuthorization authorization;
  late List<http.Request> identityRequests;
  late String subject;
  late int status;

  setUp(() {
    gateway = _Gateway();
    clock = ManualClock(DateTime.utc(2026));
    identityRequests = [];
    subject = 'account-a';
    status = 200;
    authorization = AndroidAuthorization(
      gateway: gateway,
      clock: clock,
      identityClient: MockClient((request) async {
        identityRequests.add(request);
        return http.Response('{"sub":"$subject"}', status);
      }),
    );
  });
  tearDown(() => authorization.close());

  test(
    'sign-out clears the token and ends the Play Services session',
    () async {
      await authorization.requestTasksAuthorization();
      final states = <AuthorizationState>[];
      final subscription = authorization.states.listen(states.add);
      addTearDown(subscription.cancel);

      final outcome = await authorization.signOut();
      await Future<void>.value();

      expect(outcome, isA<Success<void>>());
      expect(gateway.cleared, ['token-1']);
      expect(gateway.signOuts, 1);
      expect(authorization.currentState, isA<NoTasksAuthorization>());
      expect(states.last, isA<NoTasksAuthorization>());
    },
  );

  test('a Play Services sign-out failure is reported, not swallowed', () async {
    await authorization.requestTasksAuthorization();
    gateway.signOutError = StateError('synthetic');

    final outcome = await authorization.signOut();

    expect((outcome as Failed<void>).failure.code, 'auth.sign_out_failed');
    expect(gateway.signOuts, 0);
  });

  test(
    'interactive authorization verifies identity before accepting a grant',
    () async {
      final states = <AuthorizationState>[];
      final subscription = authorization.states.listen(states.add);
      addTearDown(subscription.cancel);
      expect(
        await authorization.requestTasksAuthorization(),
        isA<Success<AccountSubject>>(),
      );
      await Future<void>.value();
      expect(gateway.interactions, [true]);
      expect(
        identityRequests.single.url.toString(),
        'https://openidconnect.googleapis.com/v1/userinfo',
      );
      expect(
        identityRequests.single.headers['authorization'],
        'Bearer token-1',
      );
      expect(states, [isA<AuthorizationConnecting>(), isA<TasksAuthorized>()]);
      expect(
        (authorization.currentState as TasksAuthorized).subject,
        const AccountSubject('account-a'),
      );
    },
  );

  test(
    'restore never prompts; an absent grant requires explicit connection',
    () async {
      gateway.token = null;
      expect(
        await authorization.restoreTasksAuthorization(),
        isA<Failed<AccountSubject>>(),
      );
      expect(gateway.interactions, [false]);
      expect(identityRequests, isEmpty);
      expect(authorization.currentState, isA<AuthorizationRejected>());
    },
  );

  test('refresh invalidates cached token, reacquires silently and verifies identity', () async {
    await authorization.requestTasksAuthorization();
    gateway.token = 'token-2';
    expect(
      await authorization.refreshTasksAuthorization(),
      isA<Success<AccountSubject>>(),
    );
    expect(gateway.cleared, ['token-1']);
    expect(gateway.interactions, [true, false]);
    expect(identityRequests, hasLength(2));
    expect(
      (await authorization.accessToken() as Success<String>).value,
      'token-2',
    );
  });

  test(
    'expired in-memory token is refreshed silently before a request',
    () async {
      await authorization.requestTasksAuthorization();
      clock.advance(const Duration(minutes: 46));
      gateway.token = 'token-2';
      expect(
        (await authorization.accessToken() as Success<String>).value,
        'token-2',
      );
      expect(gateway.interactions, [true, false]);
      expect(gateway.cleared, ['token-1']);
    },
  );

  test('a switched account cannot send Tasks requests or replace the pinned identity', () async {
    await authorization.requestTasksAuthorization();
    subject = 'account-b';
    final result =
        await authorization.refreshTasksAuthorization()
            as Failed<AccountSubject>;
    expect(result.failure.code, 'account.subject_mismatch');
    var taskRequests = 0;
    final client = AndroidAuthorizedHttpClient(
      authorization,
      MockClient((_) async {
        taskRequests++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.get(
        Uri.parse('https://tasks.googleapis.com/tasks/v1/users/@me/lists'),
      ),
      throwsA(isA<AuthorizationTransportException>()),
    );
    expect(taskRequests, 0);
    subject = 'account-a';
    expect(
      await authorization.requestTasksAuthorization(),
      isA<Success<AccountSubject>>(),
    );
  });

  test('existing local account must match on first restore', () async {
    final restored = AndroidAuthorization(
      gateway: gateway,
      identityClient: MockClient(
        (_) async => http.Response('{"sub":"other"}', 200),
      ),
      clock: clock,
      expectedSubject: const AccountSubject('account-a'),
    );
    addTearDown(restored.close);
    final result =
        await restored.restoreTasksAuthorization() as Failed<AccountSubject>;
    expect(result.failure.code, 'account.subject_mismatch');
  });

  test('identity rejection clears an invalid cached token', () async {
    status = 401;
    expect(
      await authorization.requestTasksAuthorization(),
      isA<Failed<AccountSubject>>(),
    );
    expect(gateway.cleared, ['token-1']);
    expect(authorization.currentState, isA<AuthorizationRejected>());
  });

  test(
    'identity network failure is retryable and does not accept the token',
    () async {
      status = 503;
      final result =
          await authorization.requestTasksAuthorization()
              as Failed<AccountSubject>;
      expect(result.failure.code, 'auth.network');
      expect(authorization.currentState, isA<AuthorizationRequestFailed>());
    },
  );

  test(
    'cancel and configuration errors are typed without leaking plugin details',
    () async {
      gateway.error = const GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: 'private account details',
      );
      var result =
          await authorization.requestTasksAuthorization()
              as Failed<AccountSubject>;
      expect(result.failure.code, 'auth.credentials_absent');
      expect(result.failure.sensitiveContext, isNull);
      gateway.error = const GoogleSignInException(
        code: GoogleSignInExceptionCode.clientConfigurationError,
      );
      result =
          await authorization.requestTasksAuthorization()
              as Failed<AccountSubject>;
      expect(result.failure.code, 'auth.configuration');
    },
  );

  test('Google registration rejection is a safe configuration failure', () async {
    gateway.error = const GoogleSignInException(
      code: GoogleSignInExceptionCode.unknownError,
      description:
          'Unknown error [status=UNREGISTERED_ON_API_CONSOLE] private account',
    );
    final result =
        await authorization.requestTasksAuthorization()
            as Failed<AccountSubject>;
    expect(result.failure.code, 'auth.configuration');
    expect(result.failure.sensitiveContext, isNull);
    expect(
      result.failure.safeSummary,
      'Authorization configuration is invalid.',
    );
  });

  test(
    'concurrent restore shares one acquisition and closing discards late grant',
    () async {
      final completion = Completer<String?>();
      gateway.pending = completion.future;
      final first = authorization.restoreTasksAuthorization();
      final second = authorization.restoreTasksAuthorization();
      authorization.close();
      completion.complete('token-1');
      expect(await first, isA<Failed<AccountSubject>>());
      expect(await second, isA<Failed<AccountSubject>>());
      expect(gateway.interactions, [false]);
      expect(identityRequests, isEmpty);
    },
  );

  test('authorized HTTP requests cannot leak tokens through endpoints or redirects', () async {
    await authorization.requestTasksAuthorization();
    final requests = <http.Request>[];
    final client = AndroidAuthorizedHttpClient(
      authorization,
      MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.get(Uri.parse('https://example.com/')),
      throwsArgumentError,
    );
    await client.get(
      Uri.parse('https://tasks.googleapis.com/tasks/v1/users/@me/lists'),
    );
    expect(requests, hasLength(1));
    expect(requests.single.headers['authorization'], 'Bearer token-1');
    expect(requests.single.followRedirects, isFalse);
  });
}

class _Gateway implements AndroidAuthorizationGateway {
  String? token = 'token-1';
  Object? error;
  Future<String?>? pending;
  final interactions = <bool>[];
  final cleared = <String>[];

  @override
  Future<String?> authorize({required bool interactive}) async {
    interactions.add(interactive);
    if (error case final error?) throw error;
    return pending ?? token;
  }

  @override
  Future<void> clearToken(String token) async => cleared.add(token);

  int signOuts = 0;
  Object? signOutError;

  @override
  Future<void> signOut() async {
    if (signOutError case final error?) throw error;
    signOuts += 1;
  }
}
