import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/composition/linux_read_transport.dart';
import 'package:axiotask/src/app/composition/release_composition.dart';
import 'package:axiotask/src/app/tasks_feature_runtime.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/auth/linux/browser_flow.dart';
import 'package:axiotask/src/data/auth/linux/linux_authorization.dart';
import 'package:axiotask/src/data/auth/linux/secure_credentials.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'release composition connects, commits account, restores, then verifies Tasks',
    () async {
      const subject = AccountSubject('release-workflow-subject');
      final endpoint = _GoogleEndpoint();
      final credentials = _MemoryCredentialStore();
      final credentialNamespaces = <String>[];
      final composition = ReleaseComposition.create(
        linuxReadConfiguration: const LinuxReadConfiguration(
          clientId: 'synthetic.apps.googleusercontent.com',
          clientSecret: 'synthetic-installed-client-secret',
        ),
        linuxReadTransportDependencies: LinuxReadTransportDependencies(
          browserFlow: const _BrowserFlow(),
          credentialStoreFactory: (namespace, diagnostics) {
            credentialNamespaces.add(namespace);
            return credentials;
          },
          identityVerifier: const _IdentityVerifier(subject),
          httpClientFactory: () => endpoint,
        ),
      );
      final directory = Directory.systemTemp.createTempSync(
        'axiotask-release-auth-workflow-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final databaseFile = File('${directory.path}/workflow.sqlite');
      final preferences = InMemoryDevicePreferencesBackend();

      var database = await AppDatabase.openFile(databaseFile);
      var runtime = await TasksFeatureRuntime.open(
        composition,
        injectedDatabase: database,
        injectedDevicePreferencesBackend: preferences,
      );
      runtime.viewModel.start();
      final reload = runtime.reloadRequested!;

      await runtime.viewModel.handleSyncHealthAction(SyncHealthAction.connect);
      await reload;

      final accounts = await database.allAccounts();
      expect(accounts, hasLength(1));
      expect(accounts.single.googleSubject, subject.value);
      expect(endpoint.authorizationCodeExchanges, 1);
      expect(endpoint.taskListCalls, 0);
      expect(credentials.bundle, isNotNull);
      await runtime.close();

      database = await AppDatabase.openFile(databaseFile);
      runtime = await TasksFeatureRuntime.open(
        composition,
        injectedDatabase: database,
        injectedDevicePreferencesBackend: preferences,
      );
      await runtime.start();

      expect(endpoint.refreshExchanges, 1);
      expect(endpoint.taskListCalls, 1);
      expect(
        credentialNamespaces,
        everyElement('dev.axiotask.axiotask.credentials'),
      );
      final health = await runtime.syncHealthRepository!
          .watchHealth(const AccountId(1))
          .first;
      expect(health.outcome, SyncHealthOutcome.good);
      await runtime.close();
    },
  );
}

final class _BrowserFlow implements BrowserAuthorizationFlow {
  const _BrowserFlow();

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
      state: 'release-workflow-state',
      nonce: 'release-workflow-nonce',
      codeVerifier: verifier,
    );
    expect(uri.origin, 'https://accounts.google.com');
    expect(uri.queryParameters['code_challenge_method'], 'S256');
    expect(uri.queryParameters['access_type'], 'offline');
    expect(uri.queryParameters['prompt'], 'consent');
    return Outcome<BrowserAuthorizationCode>.success(
      BrowserAuthorizationCode(
        code: 'release-workflow-code',
        redirectUri: redirect,
        state: 'release-workflow-state',
        nonce: 'release-workflow-nonce',
        codeVerifier: verifier,
      ),
    );
  }
}

final class _IdentityVerifier implements IdentityTokenVerifier {
  const _IdentityVerifier(this.subject);

  final AccountSubject subject;

  @override
  Future<Outcome<AccountSubject>> verify(
    String idToken, {
    required String clientId,
    String? expectedNonce,
  }) async {
    expect(idToken, 'release-workflow-id-token');
    expect(expectedNonce, 'release-workflow-nonce');
    return Outcome<AccountSubject>.success(subject);
  }

  @override
  Future<Outcome<AccountSubject>> resolveSubject(http.Client client) async =>
      Outcome<AccountSubject>.success(subject);
}

final class _MemoryCredentialStore implements CredentialStore {
  CredentialBundle? bundle;

  @override
  Future<Outcome<CredentialBundle?>> read() async =>
      Outcome<CredentialBundle?>.success(bundle);

  @override
  Future<Outcome<void>> replace(CredentialBundle value) async {
    bundle = value;
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> delete() async {
    bundle = null;
    return const Outcome<void>.success(null);
  }
}

final class _GoogleEndpoint extends http.BaseClient {
  int authorizationCodeExchanges = 0;
  int refreshExchanges = 0;
  int taskListCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'oauth2.googleapis.com') {
      expect(request, isA<http.Request>());
      final fields = Uri.splitQueryString((request as http.Request).body);
      expect(request.headers['dpop'], isNotNull);
      switch (fields['grant_type']) {
        case 'authorization_code':
          authorizationCodeExchanges += 1;
          expect(fields['code'], 'release-workflow-code');
          expect(fields['code_verifier'], isNotEmpty);
        case 'refresh_token':
          refreshExchanges += 1;
          expect(fields['refresh_token'], 'release-workflow-refresh');
        default:
          fail('Unexpected OAuth grant.');
      }
      return _response(
        jsonEncode(<String, Object>{
          'access_token': 'test-access-$refreshExchanges',
          'refresh_token': 'release-workflow-refresh',
          'token_type': 'Bearer',
          'expires_in': 3600,
          'scope': '$googleOpenIdScope $googleTasksScope',
          if (fields['grant_type'] == 'authorization_code')
            'id_token': 'release-workflow-id-token',
        }),
        200,
        headers: const <String, String>{
          'dpop-nonce': 'release-workflow-dpop-nonce',
        },
      );
    }
    if (request.url.host == 'tasks.googleapis.com') {
      taskListCalls += 1;
      expect(
        request.headers[HttpHeaders.authorizationHeader],
        'Bearer test-access-1',
      );
      return _response('{"kind":"tasks#taskLists","items":[]}', 200);
    }
    return _response('', 404);
  }

  http.StreamedResponse _response(
    String body,
    int status, {
    Map<String, String> headers = const <String, String>{},
  }) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
    headers: <String, String>{'content-type': 'application/json', ...headers},
  );
}
