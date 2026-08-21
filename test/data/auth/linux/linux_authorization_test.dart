import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/auth/linux/browser_flow.dart';
import 'package:axiotask/src/data/auth/linux/linux_authorization.dart';
import 'package:axiotask/src/data/auth/linux/secure_credentials.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/http_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';
import 'package:oauth2/oauth2.dart' as oauth2;

void main() {
  group('LinuxAuthorization', () {
    test(
      'completes the real loopback callback through token exchange and storage',
      () async {
        final endpoint = StatefulTokenAndTasksEndpoint(<String>[]);
        final browser = LoopbackAuthorizationBrowser();
        final adapter = createAdapter(
          endpoint: endpoint,
          credentials: MemoryCredentialStore(),
          subjects: MemoryPinnedSubjectStore(),
          browser: LinuxBrowserFlow(
            callbackFactory: const HttpLoopbackCallbackFactory(),
            browserLauncher: browser,
            randomness: SequenceRandomSource(
              List<int>.generate(256, (index) => index % 256),
            ),
          ),
        );

        final connected = await adapter.connect();
        final response = await browser.response;

        expect(connected, isA<Success<LinuxAuthorizedSession>>());
        expect(response.statusCode, 200);
        expect(response.body, contains('Authorization completed'));
        expect(endpoint.tokenCalls, 1);
      },
    );

    test(
      'connects, validates identity, pins subject, persists, then lists tasks',
      () async {
        final ledger = <String>[];
        final endpoint = StatefulTokenAndTasksEndpoint(ledger);
        final credentials = MemoryCredentialStore();
        final subjects = MemoryPinnedSubjectStore(ledger: ledger);
        final adapter = createAdapter(
          endpoint: endpoint,
          credentials: credentials,
          subjects: subjects,
        );

        final connected = await adapter.connect();
        expect(connected, isA<Success<LinuxAuthorizedSession>>());
        expect(credentials.bundle, isNotNull);
        expect(credentials.bundle!.refreshToken, 'synthetic-refresh');
        expect(
          () => jsonDecode(credentials.bundle!.dpopPrivateKeyJwk),
          returnsNormally,
        );
        expect(subjects.subject, const AccountSubject('dedicated-subject'));

        final listed = await adapter.probeTaskLists();
        expect(listed, const Outcome<int>.success(1));
        expect(
          ledger.indexOf('subject.pin'),
          lessThan(ledger.indexOf('tasks.list')),
        );
        expect(adapter.currentState, isA<TasksAuthorized>());
      },
    );

    test(
      'restore fails closed before token or Tasks calls without pinned subject',
      () async {
        final key = DpopFixture.keyBundle();
        final endpoint = StatefulTokenAndTasksEndpoint(<String>[]);
        final adapter = createAdapter(
          endpoint: endpoint,
          credentials: MemoryCredentialStore(initial: key),
          subjects: MemoryPinnedSubjectStore(),
        );

        final result = await adapter.restore();

        expect(result, isA<Failed<LinuxAuthorizedSession>>());
        expect(
          (result as Failed<LinuxAuthorizedSession>).failure.code,
          'account.pinned_subject_absent',
        );
        expect(endpoint.tokenCalls, 0);
        expect(endpoint.tasksCalls, 0);
      },
    );

    test(
      'restore rejects malformed or wrong DPoP key before refresh',
      () async {
        for (final encoded in <String>['', '{}']) {
          final endpoint = StatefulTokenAndTasksEndpoint(<String>[]);
          final adapter = createAdapter(
            endpoint: endpoint,
            credentials: MemoryCredentialStore(
              initial: CredentialBundle(
                refreshToken: 'synthetic-refresh',
                dpopPrivateKeyJwk: encoded,
              ),
            ),
            subjects: MemoryPinnedSubjectStore(
              initial: const AccountSubject('dedicated-subject'),
            ),
          );

          final result = await adapter.restore();
          expect(
            (result as Failed<LinuxAuthorizedSession>).failure.code,
            'auth.dpop_key_invalid',
          );
          expect(endpoint.tokenCalls, 0);
        }
      },
    );

    test(
      'restore refreshes with the persisted key and rejects subject mismatch',
      () async {
        final ledger = <String>[];
        final endpoint = StatefulTokenAndTasksEndpoint(ledger);
        final initialCredentials = MemoryCredentialStore();
        final firstSubjects = MemoryPinnedSubjectStore(ledger: ledger);
        final first = createAdapter(
          endpoint: endpoint,
          credentials: initialCredentials,
          subjects: firstSubjects,
        );
        expect(await first.connect(), isA<Success<LinuxAuthorizedSession>>());

        final restored = createAdapter(
          endpoint: endpoint,
          credentials: MemoryCredentialStore(
            initial: initialCredentials.bundle,
          ),
          subjects: MemoryPinnedSubjectStore(
            initial: const AccountSubject('different-subject'),
          ),
        );
        final result = await restored.restore();

        expect(
          (result as Failed<LinuxAuthorizedSession>).failure.code,
          'account.subject_mismatch',
        );
        expect(endpoint.tasksCalls, 0);
      },
    );

    test('missing Tasks scope never persists or calls Tasks', () async {
      final endpoint = StatefulTokenAndTasksEndpoint(<String>[])
        ..omitTasksScope = true;
      final credentials = MemoryCredentialStore();
      final history = InMemoryDiagnosticHistory();
      final adapter = createAdapter(
        endpoint: endpoint,
        credentials: credentials,
        subjects: MemoryPinnedSubjectStore(),
        diagnostics: SensitiveDevelopmentDiagnosticSink(history),
      );

      final result = await adapter.connect();

      expect(
        (result as Failed<LinuxAuthorizedSession>).failure.code,
        'auth.tasks_scope_absent',
      );
      expect(credentials.bundle, isNull);
      expect(endpoint.tasksCalls, 0);
      expect(
        history.records.map((record) => record.renderedText).join('\n'),
        contains('grantedScopes=openid'),
      );
    });

    test(
      'secure-store and subject-store failures are typed and stop access',
      () async {
        final endpoint = StatefulTokenAndTasksEndpoint(<String>[]);
        final secureFailure = createAdapter(
          endpoint: endpoint,
          credentials: MemoryCredentialStore(failReplace: true),
          subjects: MemoryPinnedSubjectStore(),
        );
        final secureResult = await secureFailure.connect();
        expect(
          (secureResult as Failed<LinuxAuthorizedSession>).failure.code,
          'auth.secure_store_test_failure',
        );

        final subjectFailure = createAdapter(
          endpoint: endpoint,
          credentials: MemoryCredentialStore(),
          subjects: MemoryPinnedSubjectStore(failPin: true),
        );
        final subjectResult = await subjectFailure.connect();
        expect(
          (subjectResult as Failed<LinuxAuthorizedSession>).failure.code,
          'account.subject_store_failed',
        );
        expect(endpoint.tasksCalls, 0);
      },
    );

    test(
      'terminal refresh rejection is typed and requires reauthorization',
      () async {
        final endpoint = StatefulTokenAndTasksEndpoint(<String>[]);
        final credentials = MemoryCredentialStore();
        final subjects = MemoryPinnedSubjectStore();
        final first = createAdapter(
          endpoint: endpoint,
          credentials: credentials,
          subjects: subjects,
        );
        expect(await first.connect(), isA<Success<LinuxAuthorizedSession>>());
        endpoint.rejectRefresh = true;

        final restored = createAdapter(
          endpoint: endpoint,
          credentials: MemoryCredentialStore(initial: credentials.bundle),
          subjects: MemoryPinnedSubjectStore(initial: subjects.subject),
        );
        final result = await restored.restoreTasksAuthorization();

        expect(
          (result as Failed<AccountSubject>).failure.code,
          'auth.refresh_rejected',
        );
        expect(restored.currentState, isA<AuthorizationRejected>());
      },
    );

    test(
      'token exchange deadline fails red without a real-time wait',
      () async {
        final endpoint = StatefulTokenAndTasksEndpoint(<String>[])
          ..holdAuthorizationCode = true;
        final clock = ManualClock(DateTime.utc(2026, 8, 21, 12));
        final adapter = createAdapter(
          endpoint: endpoint,
          credentials: MemoryCredentialStore(),
          subjects: MemoryPinnedSubjectStore(),
          clock: clock,
        );
        addTearDown(adapter.close);

        final pending = adapter.connect();
        await endpoint.authorizationCodeStarted;
        clock.advance(linuxAuthorizationNetworkDeadline);
        final result = await pending;

        expect(result, isA<Failed<LinuxAuthorizedSession>>());
        expect(
          (result as Failed<LinuxAuthorizedSession>).failure.code,
          'auth.network_timeout',
        );
        expect(result.failure.category, FailureCategory.network);
        expect(adapter.currentState, isA<AuthorizationRequestFailed>());
      },
    );

    test(
      'identity deadline stops persistence without a real-time wait',
      () async {
        final endpoint = StatefulTokenAndTasksEndpoint(<String>[]);
        final clock = ManualClock(DateTime.utc(2026, 8, 21, 12));
        final credentials = MemoryCredentialStore();
        final identity = HangingIdentityVerifier();
        final adapter = createAdapter(
          endpoint: endpoint,
          credentials: credentials,
          subjects: MemoryPinnedSubjectStore(),
          clock: clock,
          identityVerifier: identity,
        );
        addTearDown(adapter.close);

        final pending = adapter.connect();
        await identity.started;
        clock.advance(linuxAuthorizationNetworkDeadline);
        final result = await pending;

        expect(
          (result as Failed<LinuxAuthorizedSession>).failure.code,
          'auth.network_timeout',
        );
        expect(credentials.bundle, isNull);
        expect(endpoint.tasksCalls, 0);
      },
    );

    test(
      'restore persists a rotated refresh token before identity read-back',
      () async {
        final endpoint = StatefulTokenAndTasksEndpoint(<String>[])
          ..rotateRefreshToken = true;
        final clock = ManualClock(DateTime.utc(2026, 8, 21, 12));
        final credentials = MemoryCredentialStore(
          initial: DpopFixture.keyBundle(),
        );
        final identity = HangingIdentityVerifier();
        final adapter = createAdapter(
          endpoint: endpoint,
          credentials: credentials,
          subjects: MemoryPinnedSubjectStore(
            initial: const AccountSubject('dedicated-subject'),
          ),
          clock: clock,
          identityVerifier: identity,
        );
        addTearDown(adapter.close);

        final pending = adapter.restore();
        await identity.started;

        expect(credentials.bundle?.refreshToken, 'rotated-refresh');
        clock.advance(linuxAuthorizationNetworkDeadline);
        final result = await pending;
        expect(
          (result as Failed<LinuxAuthorizedSession>).failure.code,
          'auth.network_timeout',
        );
        expect(endpoint.tasksCalls, 0);
      },
    );

    test('closing during token exchange prevents late persistence', () async {
      final endpoint = StatefulTokenAndTasksEndpoint(<String>[])
        ..holdAuthorizationCode = true;
      final credentials = MemoryCredentialStore();
      final adapter = createAdapter(
        endpoint: endpoint,
        credentials: credentials,
        subjects: MemoryPinnedSubjectStore(),
      );

      final pending = adapter.connect();
      await endpoint.authorizationCodeStarted;
      adapter.close();
      final result = await pending;

      expect(result, isA<Failed<LinuxAuthorizedSession>>());
      expect(credentials.bundle, isNull);
      expect(endpoint.tasksCalls, 0);
    });

    test(
      'closing during identity verification completes immediately',
      () async {
        final identity = HangingIdentityVerifier();
        final credentials = MemoryCredentialStore();
        final adapter = createAdapter(
          endpoint: StatefulTokenAndTasksEndpoint(<String>[]),
          credentials: credentials,
          subjects: MemoryPinnedSubjectStore(),
          identityVerifier: identity,
        );

        final pending = adapter.connect();
        await identity.started;
        adapter.close();
        final result = await pending;

        expect(
          (result as Failed<LinuxAuthorizedSession>).failure.code,
          'auth.closed',
        );
        expect(credentials.bundle, isNull);
      },
    );

    test(
      'expired resource request refreshes, validates, and persists rotation before dispatch',
      () async {
        final endpoint = StatefulTokenAndTasksEndpoint(<String>[])
          ..expireAuthorizationCodeAccess = true
          ..rotateRefreshToken = true;
        final credentials = MemoryCredentialStore();
        final adapter = createAdapter(
          endpoint: endpoint,
          credentials: credentials,
          subjects: MemoryPinnedSubjectStore(),
        );
        addTearDown(adapter.close);
        expect(await adapter.connect(), isA<Success<LinuxAuthorizedSession>>());
        final service = _tasksService(adapter);
        addTearDown(service.close);

        final result = await service.listTaskLists();

        expect(result, isA<Success<RemotePage<RemoteTaskList>>>());
        expect(endpoint.tokenCalls, 2);
        expect(endpoint.tasksCalls, 1);
        expect(credentials.bundle?.refreshToken, 'rotated-refresh');
        expect(adapter.currentState, isA<TasksAuthorized>());
      },
    );

    test('concurrent expired requests share one durable refresh', () async {
      final endpoint = StatefulTokenAndTasksEndpoint(<String>[])
        ..expireAuthorizationCodeAccess = true
        ..rotateRefreshToken = true
        ..holdRefresh = true;
      final credentials = MemoryCredentialStore();
      final adapter = createAdapter(
        endpoint: endpoint,
        credentials: credentials,
        subjects: MemoryPinnedSubjectStore(),
      );
      addTearDown(adapter.close);
      expect(await adapter.connect(), isA<Success<LinuxAuthorizedSession>>());
      final client = LinuxAuthorizedHttpClient(adapter);

      final endpointUri = Uri.parse(
        'https://tasks.example.test/tasks/v1/users/@me/lists',
      );
      final first = client.get(endpointUri);
      final second = client.get(endpointUri);
      await endpoint.refreshStarted;
      expect(endpoint.tokenCalls, 2);
      endpoint.releaseRefresh();

      expect((await first).statusCode, 200);
      expect((await second).statusCode, 200);
      expect(endpoint.tokenCalls, 2);
      expect(credentials.replaceCalls, 2);
      expect(endpoint.tasksCalls, 2);
    });

    test(
      'expired resource request preserves invalid_grant and dispatches no Tasks call',
      () async {
        final endpoint = StatefulTokenAndTasksEndpoint(<String>[])
          ..expireAuthorizationCodeAccess = true;
        final adapter = createAdapter(
          endpoint: endpoint,
          credentials: MemoryCredentialStore(),
          subjects: MemoryPinnedSubjectStore(),
        );
        addTearDown(adapter.close);
        expect(await adapter.connect(), isA<Success<LinuxAuthorizedSession>>());
        endpoint.rejectRefresh = true;
        final service = _tasksService(adapter);
        addTearDown(service.close);

        final result = await service.listTaskLists();

        expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
        expect(
          (result as Failed<RemotePage<RemoteTaskList>>).failure.code,
          'auth.refresh_rejected',
        );
        expect(
          result.failure.authorizationRecovery,
          AuthorizationRecovery.reauthorize,
        );
        expect(endpoint.tasksCalls, 0);
        expect(adapter.currentState, isA<AuthorizationRejected>());
      },
    );

    test('resource 401 reaches the strict Tasks adapter unchanged', () async {
      final endpoint = StatefulTokenAndTasksEndpoint(<String>[])
        ..rejectTasksAsUnauthorized = true;
      final adapter = createAdapter(
        endpoint: endpoint,
        credentials: MemoryCredentialStore(),
        subjects: MemoryPinnedSubjectStore(),
      );
      addTearDown(adapter.close);
      expect(await adapter.connect(), isA<Success<LinuxAuthorizedSession>>());
      final service = _tasksService(adapter);
      addTearDown(service.close);

      final result = await service.listTaskLists();

      expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
      final failure = (result as Failed<RemotePage<RemoteTaskList>>).failure;
      expect(failure.code, 'google_tasks.unauthorized');
      expect(failure.authorizationRecovery, AuthorizationRecovery.refreshOnce);
      expect(endpoint.tasksCalls, 1);
    });

    test(
      'cancellation preserves absent authorization and emits no secret',
      () async {
        final history = InMemoryDiagnosticHistory();
        final adapter = createAdapter(
          endpoint: StatefulTokenAndTasksEndpoint(<String>[]),
          credentials: MemoryCredentialStore(),
          subjects: MemoryPinnedSubjectStore(),
          browser: const CancelledBrowserFlow(),
          diagnostics: SensitiveDevelopmentDiagnosticSink(history),
        );

        final result = await adapter.connect();

        expect(
          (result as Failed<LinuxAuthorizedSession>).failure.code,
          'auth.cancelled',
        );
        expect(adapter.currentState, isA<NoTasksAuthorization>());
        final output = history.records
            .map((record) => record.renderedText)
            .join('\n');
        expect(output, isNot(contains('credential-canary')));
        expect(output, isNot(contains('synthetic-refresh')));
      },
    );

    test('closing the adapter cancels an outstanding browser flow', () async {
      final browser = CloseAwareBrowserFlow();
      final credentials = MemoryCredentialStore();
      final adapter = createAdapter(
        endpoint: StatefulTokenAndTasksEndpoint(<String>[]),
        credentials: credentials,
        subjects: MemoryPinnedSubjectStore(),
        browser: browser,
      );

      final pending = adapter.connect();
      await browser.started;
      adapter.close();
      final result = await pending;

      expect(
        (result as Failed<LinuxAuthorizedSession>).failure.code,
        'auth.cancelled',
      );
      expect(credentials.bundle, isNull);
    });
  });

  group('GoogleIdTokenVerifier', () {
    test(
      'verifies signature, issuer, audience, expiry, nonce, and subject',
      () async {
        final key = JsonWebKey.generate('RS256', keyBitLength: 2048);
        final store = JsonWebKeyStore()..addKey(key);
        final verifier = GoogleIdTokenVerifier(
          clock: ManualClock(DateTime.utc(2026, 8, 14, 12)),
          keys: store,
        );
        final token = signedIdentityToken(
          key: key,
          audience: 'client.example.test',
          nonce: 'nonce-one',
        );

        expect(
          await verifier.verify(
            token,
            clientId: 'client.example.test',
            expectedNonce: 'nonce-one',
          ),
          const Outcome<AccountSubject>.success(
            AccountSubject('dedicated-subject'),
          ),
        );
      },
    );

    test('rejects nonce, audience, expiry, and signature mismatches', () async {
      final key = JsonWebKey.generate('RS256', keyBitLength: 2048);
      final store = JsonWebKeyStore()..addKey(key);
      final verifier = GoogleIdTokenVerifier(
        clock: ManualClock(DateTime.utc(2026, 8, 14, 12)),
        keys: store,
      );
      final otherKey = JsonWebKey.generate('RS256', keyBitLength: 2048);
      final cases = <(String, String?)>[
        (
          signedIdentityToken(
            key: key,
            audience: 'wrong-client',
            nonce: 'nonce-one',
          ),
          'nonce-one',
        ),
        (
          signedIdentityToken(
            key: key,
            audience: 'client.example.test',
            nonce: 'wrong-nonce',
          ),
          'nonce-one',
        ),
        (
          signedIdentityToken(
            key: key,
            audience: 'client.example.test',
            nonce: 'nonce-one',
            expiry: DateTime.utc(2026, 8, 14, 11),
          ),
          'nonce-one',
        ),
        (
          signedIdentityToken(
            key: otherKey,
            audience: 'client.example.test',
            nonce: 'nonce-one',
          ),
          'nonce-one',
        ),
      ];
      for (final (token, nonce) in cases) {
        final result = await verifier.verify(
          token,
          clientId: 'client.example.test',
          expectedNonce: nonce,
        );
        expect(result, isA<Failed<AccountSubject>>());
        expect(
          (result as Failed<AccountSubject>).failure.code,
          'auth.identity_invalid',
        );
      }
    });

    test('resolves the stable subject from authenticated UserInfo', () async {
      final verifier = GoogleIdTokenVerifier(
        clock: ManualClock(DateTime.utc(2026, 8, 14, 12)),
        keys: JsonWebKeyStore(),
        userInfoEndpoint: Uri.parse(
          'https://openidconnect.example.test/v1/userinfo',
        ),
      );
      final client = oauth2.Client(
        oauth2.Credentials('test-access'),
        httpClient: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer test-access');
          return http.Response('{"sub":"dedicated-subject"}', 200);
        }),
      );

      expect(
        await verifier.resolveSubject(client),
        const Outcome<AccountSubject>.success(
          AccountSubject('dedicated-subject'),
        ),
      );
      client.close();
    });
  });

  group('FilePinnedSubjectStore', () {
    test('pins once, restores, and rejects a different subject', () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-subject-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/subject')..createSync();
      final store = FilePinnedSubjectStore(file);

      expect(await store.read(), const Outcome<AccountSubject?>.success(null));
      expect(
        await store.pin(const AccountSubject('dedicated-subject')),
        const Outcome<void>.success(null),
      );
      expect(
        await store.read(),
        const Outcome<AccountSubject?>.success(
          AccountSubject('dedicated-subject'),
        ),
      );
      final mismatch = await store.pin(
        const AccountSubject('different-subject'),
      );
      expect(
        (mismatch as Failed<void>).failure.code,
        'account.subject_mismatch',
      );
    });

    test('missing and malformed private stores fail closed', () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-subject-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final missing = FilePinnedSubjectStore(File('${directory.path}/missing'));
      expect(
        (await missing.read() as Failed<AccountSubject?>).failure.code,
        'account.subject_store_missing',
      );
      final malformedFile = File('${directory.path}/malformed')
        ..writeAsStringSync('not a subject with spaces');
      final malformed = FilePinnedSubjectStore(malformedFile);
      expect(
        (await malformed.read() as Failed<AccountSubject?>).failure.code,
        'account.subject_store_invalid',
      );
    });
  });
}

LinuxAuthorization createAdapter({
  required StatefulTokenAndTasksEndpoint endpoint,
  required MemoryCredentialStore credentials,
  required MemoryPinnedSubjectStore subjects,
  BrowserAuthorizationFlow browser = const SuccessfulBrowserFlow(),
  DiagnosticSink? diagnostics,
  ManualClock? clock,
  IdentityTokenVerifier identityVerifier = const SyntheticIdentityVerifier(),
}) {
  final resolvedClock = clock ?? ManualClock(DateTime.utc(2026, 8, 14, 12));
  return LinuxAuthorization(
    config: LinuxAuthorizationConfig(
      clientId: 'client.example.test',
      clientSecret: 'credential-canary-client-secret',
      authorizationEndpoint: Uri.parse(
        'https://accounts.example.test/authorize',
      ),
      tokenEndpoint: Uri.parse('https://oauth2.example.test/token'),
      taskListsEndpoint: Uri.parse(
        'https://tasks.example.test/tasks/v1/users/@me/lists',
      ),
    ),
    browserFlow: browser,
    credentialStore: credentials,
    subjectStore: subjects,
    identityVerifier: identityVerifier,
    httpClientFactory: () => endpoint,
    clock: resolvedClock,
    scheduler: resolvedClock,
    randomness: SequenceRandomSource(List<int>.generate(1024, (i) => i % 256)),
    diagnostics:
        diagnostics ?? ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
  );
}

HttpGoogleTasksService _tasksService(LinuxAuthorization authorization) =>
    HttpGoogleTasksService(
      client: LinuxAuthorizedHttpClient(authorization),
      authorization: authorization,
      accountGuard: const NormalAccountGuard(),
      diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
      endpoint: Uri.parse('https://tasks.example.test/tasks/v1/'),
    );

final class SuccessfulBrowserFlow implements BrowserAuthorizationFlow {
  const SuccessfulBrowserFlow();

  @override
  Future<Outcome<BrowserAuthorizationCode>> authorize({
    required AuthorizationUriBuilder buildAuthorizationUri,
    required AuthorizationCancellation cancellation,
  }) async {
    const verifier =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final redirect = Uri.parse('http://127.0.0.1:43127/oauth2/callback');
    final uri = buildAuthorizationUri(
      redirectUri: redirect,
      state: 'synthetic-state',
      nonce: 'synthetic-nonce',
      codeVerifier: verifier,
    );
    expect(uri.queryParameters['code_challenge_method'], 'S256');
    expect(uri.queryParameters['access_type'], 'offline');
    expect(uri.queryParameters['nonce'], 'synthetic-nonce');
    return Outcome<BrowserAuthorizationCode>.success(
      BrowserAuthorizationCode(
        code: 'synthetic-code',
        redirectUri: redirect,
        state: 'synthetic-state',
        nonce: 'synthetic-nonce',
        codeVerifier: verifier,
      ),
    );
  }
}

final class CancelledBrowserFlow implements BrowserAuthorizationFlow {
  const CancelledBrowserFlow();

  @override
  Future<Outcome<BrowserAuthorizationCode>> authorize({
    required AuthorizationUriBuilder buildAuthorizationUri,
    required AuthorizationCancellation cancellation,
  }) async => const Outcome<BrowserAuthorizationCode>.failure(
    Failure(
      code: 'auth.cancelled',
      category: FailureCategory.authorization,
      operation: FailureOperation.authorize,
      retry: RetryClassification.permanent,
      impact: 'Google authorization was cancelled.',
      safeSummary: 'The authorization request was cancelled.',
    ),
  );
}

final class CloseAwareBrowserFlow implements BrowserAuthorizationFlow {
  final Completer<void> _started = Completer<void>();

  Future<void> get started => _started.future;

  @override
  Future<Outcome<BrowserAuthorizationCode>> authorize({
    required AuthorizationUriBuilder buildAuthorizationUri,
    required AuthorizationCancellation cancellation,
  }) async {
    _started.complete();
    await cancellation.whenCancelled;
    return const Outcome<BrowserAuthorizationCode>.failure(
      Failure(
        code: 'auth.cancelled',
        category: FailureCategory.authorization,
        operation: FailureOperation.authorize,
        retry: RetryClassification.permanent,
        impact: 'Synthetic authorization was cancelled.',
        safeSummary: 'Synthetic authorization was cancelled.',
      ),
    );
  }
}

final class LoopbackAuthorizationBrowser implements BrowserLauncher {
  final Completer<http.Response> _response = Completer<http.Response>();

  Future<http.Response> get response => _response.future;

  @override
  Future<bool> launchExternal(Uri uri) async {
    final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
    final callback = redirect.replace(
      queryParameters: <String, String>{
        'code': 'synthetic-code',
        'state': uri.queryParameters['state']!,
      },
    );
    unawaited(
      http
          .get(callback)
          .then(_response.complete, onError: _response.completeError),
    );
    return true;
  }
}

final class SyntheticIdentityVerifier implements IdentityTokenVerifier {
  const SyntheticIdentityVerifier();

  @override
  Future<Outcome<AccountSubject>> verify(
    String idToken, {
    required String clientId,
    String? expectedNonce,
  }) async {
    expect(idToken, 'synthetic-id-token');
    return const Outcome<AccountSubject>.success(
      AccountSubject('dedicated-subject'),
    );
  }

  @override
  Future<Outcome<AccountSubject>> resolveSubject(http.Client client) async =>
      const Outcome<AccountSubject>.success(
        AccountSubject('dedicated-subject'),
      );
}

final class HangingIdentityVerifier implements IdentityTokenVerifier {
  final Completer<void> _started = Completer<void>();
  final Completer<Outcome<AccountSubject>> _result =
      Completer<Outcome<AccountSubject>>();

  Future<void> get started => _started.future;

  @override
  Future<Outcome<AccountSubject>> verify(
    String idToken, {
    required String clientId,
    String? expectedNonce,
  }) {
    if (!_started.isCompleted) _started.complete();
    return _result.future;
  }

  @override
  Future<Outcome<AccountSubject>> resolveSubject(http.Client client) {
    if (!_started.isCompleted) _started.complete();
    return _result.future;
  }
}

final class MemoryCredentialStore implements CredentialStore {
  MemoryCredentialStore({CredentialBundle? initial, this.failReplace = false})
    : bundle = initial;

  CredentialBundle? bundle;
  final bool failReplace;
  int replaceCalls = 0;

  @override
  Future<Outcome<CredentialBundle?>> read() async =>
      Outcome<CredentialBundle?>.success(bundle);

  @override
  Future<Outcome<void>> replace(CredentialBundle value) async {
    replaceCalls += 1;
    if (failReplace) {
      return const Outcome<void>.failure(
        Failure(
          code: 'auth.secure_store_test_failure',
          category: FailureCategory.authorization,
          operation: FailureOperation.write,
          retry: RetryClassification.unknown,
          impact: 'Saved authorization was not updated.',
          safeSummary: 'Synthetic secure storage failed.',
        ),
      );
    }
    bundle = value;
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> delete() async {
    bundle = null;
    return const Outcome<void>.success(null);
  }
}

final class MemoryPinnedSubjectStore implements PinnedSubjectStore {
  factory MemoryPinnedSubjectStore({
    AccountSubject? initial,
    bool failPin = false,
    List<String>? ledger,
  }) => MemoryPinnedSubjectStore._(initial, failPin, ledger);

  MemoryPinnedSubjectStore._(this.subject, this.failPin, this._ledger);

  AccountSubject? subject;
  final bool failPin;
  final List<String>? _ledger;

  @override
  Future<Outcome<AccountSubject?>> read() async =>
      Outcome<AccountSubject?>.success(subject);

  @override
  Future<Outcome<void>> pin(AccountSubject value) async {
    if (failPin) {
      return const Outcome<void>.failure(
        Failure(
          code: 'account.subject_store_failed',
          category: FailureCategory.persistence,
          operation: FailureOperation.write,
          retry: RetryClassification.unknown,
          impact: 'The dedicated account identity could not be pinned.',
          safeSummary: 'The private subject store failed.',
        ),
      );
    }
    subject ??= value;
    _ledger?.add('subject.pin');
    return subject == value
        ? const Outcome<void>.success(null)
        : const Outcome<void>.failure(
            Failure(
              code: 'account.subject_mismatch',
              category: FailureCategory.authorization,
              operation: FailureOperation.authorize,
              retry: RetryClassification.permanent,
              impact: 'No Google Tasks data was read or changed.',
              safeSummary: 'The authenticated subject does not match.',
            ),
          );
  }
}

final class StatefulTokenAndTasksEndpoint extends http.BaseClient {
  StatefulTokenAndTasksEndpoint(this.ledger);

  final List<String> ledger;
  int tokenCalls = 0;
  int tasksCalls = 0;
  bool omitTasksScope = false;
  bool rejectRefresh = false;
  bool expireAuthorizationCodeAccess = false;
  bool rotateRefreshToken = false;
  bool rejectTasksAsUnauthorized = false;
  bool holdAuthorizationCode = false;
  bool holdRefresh = false;
  final Completer<void> _authorizationCodeStarted = Completer<void>();
  final Completer<void> _authorizationCodeRelease = Completer<void>();
  final Completer<void> _refreshStarted = Completer<void>();
  final Completer<void> _refreshRelease = Completer<void>();
  String _latestAccessToken = 'test-access';

  Future<void> get authorizationCodeStarted => _authorizationCodeStarted.future;
  Future<void> get refreshStarted => _refreshStarted.future;

  void releaseRefresh() {
    if (!_refreshRelease.isCompleted) _refreshRelease.complete();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    if (request.url.host == 'oauth2.example.test') {
      tokenCalls += 1;
      ledger.add('token');
      expect(request.headers['dpop'], isNotNull);
      final fields = Uri.splitQueryString(body);
      expect(request.headers['authorization'], isNull);
      expect(fields['client_id'], 'client.example.test');
      expect(fields['client_secret'], 'credential-canary-client-secret');
      if (fields['grant_type'] == 'authorization_code') {
        if (!_authorizationCodeStarted.isCompleted) {
          _authorizationCodeStarted.complete();
        }
        expect(fields['code'], 'synthetic-code');
        expect(fields['code_verifier'], isNotEmpty);
        expect(fields['redirect_uri'], startsWith('http://127.0.0.1:'));
      }
      if (fields['grant_type'] == 'authorization_code' &&
          holdAuthorizationCode) {
        await _authorizationCodeRelease.future;
      }
      if (fields['grant_type'] == 'refresh_token' && holdRefresh) {
        if (!_refreshStarted.isCompleted) _refreshStarted.complete();
        await _refreshRelease.future;
      }
      if (fields['grant_type'] == 'refresh_token' && rejectRefresh) {
        return response('{"error":"invalid_grant"}', 400);
      }
      final scopes = omitTasksScope
          ? 'openid'
          : 'openid https://www.googleapis.com/auth/tasks';
      final isRefresh = fields['grant_type'] == 'refresh_token';
      _latestAccessToken = isRefresh ? 'test-access-refreshed' : 'test-access';
      final tokenResponse = <String, Object>{
        'access_token': _latestAccessToken,
        'refresh_token': isRefresh && rotateRefreshToken
            ? 'rotated-refresh'
            : 'synthetic-refresh',
        'token_type': 'Bearer',
        'expires_in': !isRefresh && expireAuthorizationCodeAccess ? -1 : 3600,
        'scope': scopes,
        if (fields['grant_type'] == 'authorization_code')
          'id_token': 'synthetic-id-token',
      };
      return response(
        jsonEncode(tokenResponse),
        200,
        headers: <String, String>{'dpop-nonce': 'synthetic-dpop-nonce'},
      );
    }
    if (request.url.host == 'tasks.example.test') {
      tasksCalls += 1;
      ledger.add('tasks.list');
      expect(request.headers['authorization'], 'Bearer $_latestAccessToken');
      if (rejectTasksAsUnauthorized) {
        return response(
          '{"error":{"code":401,"errors":[],"message":"synthetic","status":"UNAUTHENTICATED"}}',
          401,
          headers: const <String, String>{
            'www-authenticate': 'Bearer error="invalid_token"',
          },
        );
      }
      return response(
        '{"kind":"tasks#taskLists","items":[{"kind":"tasks#taskList",'
        '"id":"list-1","etag":"list-etag","title":"Synthetic inbox",'
        '"updated":"2026-08-15T18:30:12.123Z",'
        '"selfLink":"https://tasks.googleapis.com/tasks/v1/users/@me/lists/list-1"}]}',
        200,
      );
    }
    return response('', 404);
  }

  http.StreamedResponse response(
    String body,
    int status, {
    Map<String, String> headers = const <String, String>{},
  }) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
    headers: <String, String>{'content-type': 'application/json', ...headers},
  );

  @override
  void close() {
    if (holdAuthorizationCode &&
        _authorizationCodeStarted.isCompleted &&
        !_authorizationCodeRelease.isCompleted) {
      _authorizationCodeRelease.completeError(http.ClientException('closed'));
    }
    if (holdRefresh &&
        _refreshStarted.isCompleted &&
        !_refreshRelease.isCompleted) {
      _refreshRelease.completeError(http.ClientException('closed'));
    }
  }
}

final class DpopFixture {
  static CredentialBundle keyBundle() {
    final key = JsonWebKey.generate('ES256');
    return CredentialBundle(
      refreshToken: 'synthetic-refresh',
      dpopPrivateKeyJwk: jsonEncode(key.toJson()),
    );
  }
}

String signedIdentityToken({
  required JsonWebKey key,
  required String audience,
  required String nonce,
  DateTime? expiry,
}) {
  final builder = JsonWebSignatureBuilder()
    ..jsonContent = <String, Object>{
      'iss': 'https://accounts.google.com',
      'aud': audience,
      'sub': 'dedicated-subject',
      'iat': DateTime.utc(2026, 8, 14, 11).millisecondsSinceEpoch ~/ 1000,
      'exp':
          (expiry ?? DateTime.utc(2026, 8, 14, 13)).millisecondsSinceEpoch ~/
          1000,
      'nonce': nonce,
    }
    ..addRecipient(key, algorithm: 'RS256');
  return builder.build().toCompactSerialization();
}
