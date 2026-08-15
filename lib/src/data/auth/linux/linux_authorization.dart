import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';
import 'package:oauth2/oauth2.dart' as oauth2;

import '../../../core/clock.dart';
import '../../../core/diagnostics/diagnostics.dart';
import '../../../core/failure.dart';
import '../../../core/outcome.dart';
import '../../../core/randomness.dart';
import '../authorization.dart';
import 'browser_flow.dart';
import 'dpop.dart';
import 'secure_credentials.dart';

const String googleTasksScope = 'https://www.googleapis.com/auth/tasks';
const String googleOpenIdScope = 'openid';
final Uri _googleJwksEndpoint = Uri.parse(
  'https://www.googleapis.com/oauth2/v3/certs',
);
final Uri _googleUserInfoEndpoint = Uri.parse(
  'https://openidconnect.googleapis.com/v1/userinfo',
);
const int _maximumUserInfoResponseBytes = 65536;

final class LinuxAuthorizationConfig {
  LinuxAuthorizationConfig({
    required this.clientId,
    required this.clientSecret,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.taskListsEndpoint,
  }) {
    if (clientId.trim().isEmpty || clientSecret.trim().isEmpty) {
      throw ArgumentError('OAuth client configuration must not be empty.');
    }
    for (final endpoint in <Uri>[
      authorizationEndpoint,
      tokenEndpoint,
      taskListsEndpoint,
    ]) {
      if (endpoint.scheme != 'https' || endpoint.host.isEmpty) {
        throw ArgumentError('OAuth and Tasks endpoints must use HTTPS.');
      }
    }
  }

  factory LinuxAuthorizationConfig.google({
    required String clientId,
    required String clientSecret,
  }) => LinuxAuthorizationConfig(
    clientId: clientId,
    clientSecret: clientSecret,
    authorizationEndpoint: Uri.parse(
      'https://accounts.google.com/o/oauth2/v2/auth',
    ),
    tokenEndpoint: Uri.parse('https://oauth2.googleapis.com/token'),
    taskListsEndpoint: Uri.parse(
      'https://tasks.googleapis.com/tasks/v1/users/@me/lists',
    ),
  );

  final String clientId;
  final String clientSecret;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri taskListsEndpoint;
}

abstract interface class IdentityTokenVerifier {
  Future<Outcome<AccountSubject>> verify(
    String idToken, {
    required String clientId,
    String? expectedNonce,
  });

  Future<Outcome<AccountSubject>> resolveSubject(http.Client client);
}

final class GoogleIdTokenVerifier implements IdentityTokenVerifier {
  factory GoogleIdTokenVerifier({
    required Clock clock,
    JsonWebKeyStore? keys,
    Uri? userInfoEndpoint,
  }) => GoogleIdTokenVerifier._(
    clock,
    keys ?? (JsonWebKeyStore()..addKeySetUrl(_googleJwksEndpoint)),
    userInfoEndpoint ?? _googleUserInfoEndpoint,
  );

  GoogleIdTokenVerifier._(this._clock, this._keys, this._userInfoEndpoint);

  final Clock _clock;
  final JsonWebKeyStore _keys;
  final Uri _userInfoEndpoint;

  @override
  Future<Outcome<AccountSubject>> verify(
    String idToken, {
    required String clientId,
    String? expectedNonce,
  }) async {
    try {
      final token = await JsonWebToken.decodeAndVerify(
        idToken,
        _keys,
        allowedArguments: const <String>['RS256'],
      );
      final claims = token.claims;
      final issuer = claims['iss'];
      final audience = claims['aud'];
      final subjectValue = claims['sub'];
      final expiryValue = claims['exp'];
      final nonce = claims['nonce'];
      final audienceMatches =
          audience == clientId ||
          (audience is List<dynamic> && audience.contains(clientId));
      final expiry = expiryValue is num
          ? DateTime.fromMillisecondsSinceEpoch(
              expiryValue.toInt() * 1000,
              isUtc: true,
            )
          : null;
      if ((issuer != 'https://accounts.google.com' &&
              issuer != 'accounts.google.com') ||
          !audienceMatches ||
          expiry == null ||
          !expiry.isAfter(_clock.now().toUtc()) ||
          subjectValue is! String ||
          !_isValidSubject(subjectValue) ||
          (expectedNonce != null && nonce != expectedNonce)) {
        return Outcome<AccountSubject>.failure(_identityFailure());
      }
      return Outcome<AccountSubject>.success(AccountSubject(subjectValue));
    } catch (_) {
      return Outcome<AccountSubject>.failure(_identityFailure());
    }
  }

  @override
  Future<Outcome<AccountSubject>> resolveSubject(http.Client client) async {
    try {
      final response = await client.get(_userInfoEndpoint);
      if (response.statusCode != HttpStatus.ok ||
          response.bodyBytes.length > _maximumUserInfoResponseBytes) {
        return Outcome<AccountSubject>.failure(_identityFailure());
      }
      final decoded = jsonDecode(response.body);
      final subject = decoded is Map<String, dynamic> ? decoded['sub'] : null;
      if (subject is! String || !_isValidSubject(subject)) {
        return Outcome<AccountSubject>.failure(_identityFailure());
      }
      return Outcome<AccountSubject>.success(AccountSubject(subject));
    } catch (_) {
      return Outcome<AccountSubject>.failure(_identityFailure());
    }
  }
}

abstract interface class PinnedSubjectStore {
  Future<Outcome<AccountSubject?>> read();
  Future<Outcome<void>> pin(AccountSubject subject);
}

final class FilePinnedSubjectStore implements PinnedSubjectStore {
  FilePinnedSubjectStore(this._file);

  final File _file;

  @override
  Future<Outcome<AccountSubject?>> read() async {
    try {
      if (!await _file.exists()) {
        return Outcome<AccountSubject?>.failure(_subjectStoreMissingFailure());
      }
      final length = await _file.length();
      if (length == 0) {
        return const Outcome<AccountSubject?>.success(null);
      }
      if (length > 512) {
        return Outcome<AccountSubject?>.failure(_subjectStoreInvalidFailure());
      }
      final value = (await _file.readAsString()).trim();
      if (!_isValidSubject(value)) {
        return Outcome<AccountSubject?>.failure(_subjectStoreInvalidFailure());
      }
      return Outcome<AccountSubject?>.success(AccountSubject(value));
    } on FileSystemException {
      return Outcome<AccountSubject?>.failure(_subjectStoreReadFailure());
    }
  }

  @override
  Future<Outcome<void>> pin(AccountSubject subject) async {
    if (!_isValidSubject(subject.value)) {
      return Outcome<void>.failure(_identityFailure());
    }
    final existing = await read();
    switch (existing) {
      case Failed<AccountSubject?>(:final failure):
        return Outcome<void>.failure(failure);
      case Success<AccountSubject?>(:final value):
        if (value != null) {
          return value == subject
              ? const Outcome<void>.success(null)
              : Outcome<void>.failure(_subjectMismatchFailure());
        }
    }
    try {
      final output = await _file.open(mode: FileMode.writeOnly);
      try {
        await output.writeString('${subject.value}\n');
        await output.flush();
      } finally {
        await output.close();
      }
      final verified = await read();
      return switch (verified) {
        Success<AccountSubject?>(value: final value) when value == subject =>
          const Outcome<void>.success(null),
        Failed<AccountSubject?>(:final failure) => Outcome<void>.failure(
          failure,
        ),
        _ => Outcome<void>.failure(_subjectStoreWriteFailure()),
      };
    } on FileSystemException {
      return Outcome<void>.failure(_subjectStoreWriteFailure());
    }
  }
}

final class LinuxAuthorizedSession {
  factory LinuxAuthorizedSession({
    required AccountSubject subject,
    required oauth2.Client client,
    required DpopKeyPair dpopKey,
  }) => LinuxAuthorizedSession._(subject, client, dpopKey);

  const LinuxAuthorizedSession._(this.subject, this._client, this._dpopKey);

  final AccountSubject subject;
  final oauth2.Client _client;
  final DpopKeyPair _dpopKey;

  http.Client get authenticatedClient => _client;
  oauth2.Credentials get credentials => _client.credentials;

  @override
  String toString() => 'LinuxAuthorizedSession(<redacted>)';
}

/// Presents the currently restored Linux OAuth session to the Tasks adapter
/// without exposing credentials or letting that adapter own the session.
final class LinuxAuthorizedHttpClient extends http.BaseClient {
  LinuxAuthorizedHttpClient(this._authorization);

  final LinuxAuthorization _authorization;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final session = _authorization._session;
    if (session == null) {
      return Future<http.StreamedResponse>.error(
        http.ClientException('Google Tasks authorization is unavailable.'),
      );
    }
    return session.authenticatedClient.send(request);
  }

  @override
  void close() {
    // LinuxAuthorization owns and closes the authenticated OAuth client.
  }
}

final class LinuxAuthorization implements AuthorizationPort {
  factory LinuxAuthorization({
    required LinuxAuthorizationConfig config,
    required BrowserAuthorizationFlow browserFlow,
    required CredentialStore credentialStore,
    required PinnedSubjectStore subjectStore,
    required IdentityTokenVerifier identityVerifier,
    required http.Client Function() httpClientFactory,
    required Clock clock,
    required RandomSource randomness,
    required DiagnosticSink diagnostics,
  }) => LinuxAuthorization._(
    config,
    browserFlow,
    credentialStore,
    subjectStore,
    identityVerifier,
    httpClientFactory,
    clock,
    randomness,
    diagnostics,
  );

  LinuxAuthorization._(
    this._config,
    this._browserFlow,
    this._credentialStore,
    this._subjectStore,
    this._identityVerifier,
    this._httpClientFactory,
    this._clock,
    this._randomness,
    this._diagnostics,
  );

  final LinuxAuthorizationConfig _config;
  final BrowserAuthorizationFlow _browserFlow;
  final CredentialStore _credentialStore;
  final PinnedSubjectStore _subjectStore;
  final IdentityTokenVerifier _identityVerifier;
  final http.Client Function() _httpClientFactory;
  final Clock _clock;
  final RandomSource _randomness;
  final DiagnosticSink _diagnostics;
  final StreamController<AuthorizationState> _states =
      StreamController<AuthorizationState>.broadcast();

  AuthorizationState _currentState = const NoTasksAuthorization();
  LinuxAuthorizedSession? _session;
  DpopTokenClient? _activeTokenClient;

  @override
  AuthorizationState get currentState => _currentState;

  @override
  Stream<AuthorizationState> get states => _states.stream;

  bool get observedDpopNonce => _activeTokenClient?.currentNonce != null;

  Future<Outcome<LinuxAuthorizedSession>> connect({
    AuthorizationCancellation? cancellation,
  }) async {
    _emit(const AuthorizationConnecting());
    final key = DpopKeyPair.generate();
    final tokenClient = _createTokenClient(key);
    oauth2.AuthorizationCodeGrant? grant;
    final browserResult = await _browserFlow.authorize(
      cancellation: cancellation ?? AuthorizationCancellation(),
      buildAuthorizationUri:
          ({
            required Uri redirectUri,
            required String state,
            required String nonce,
            required String codeVerifier,
          }) {
            grant = oauth2.AuthorizationCodeGrant(
              _config.clientId,
              _config.authorizationEndpoint,
              _config.tokenEndpoint,
              secret: _config.clientSecret,
              basicAuth: false,
              httpClient: tokenClient,
              codeVerifier: codeVerifier,
            );
            final standardUri = grant!.getAuthorizationUrl(
              redirectUri,
              scopes: const <String>[googleOpenIdScope, googleTasksScope],
              state: state,
            );
            return standardUri.replace(
              queryParameters: <String, String>{
                ...standardUri.queryParameters,
                'nonce': nonce,
                'access_type': 'offline',
                'prompt': 'consent',
              },
            );
          },
    );
    if (browserResult case Failed<BrowserAuthorizationCode>(:final failure)) {
      tokenClient.close();
      if (failure.code == 'auth.cancelled') {
        _emit(const NoTasksAuthorization());
        return Outcome<LinuxAuthorizedSession>.failure(failure);
      }
      return _fail(failure);
    }
    final code = (browserResult as Success<BrowserAuthorizationCode>).value;
    try {
      final oauthClient = await grant!.handleAuthorizationResponse(
        <String, String>{'code': code.code, 'state': code.state},
      );
      return _acceptClient(
        oauthClient,
        key,
        expectedNonce: code.nonce,
        pinFirstAuthorization: true,
      );
    } on oauth2.AuthorizationException catch (error) {
      tokenClient.close();
      return _fail(_oauthFailure(error, refresh: false));
    } on FormatException {
      tokenClient.close();
      return _fail(_tokenResponseFailure());
    } catch (_) {
      tokenClient.close();
      return _fail(_tokenResponseFailure());
    }
  }

  Future<Outcome<LinuxAuthorizedSession>> restore() async {
    final pinnedResult = await _subjectStore.read();
    final AccountSubject pinned;
    switch (pinnedResult) {
      case Failed<AccountSubject?>(:final failure):
        return _fail(failure);
      case Success<AccountSubject?>(value: final value?):
        pinned = value;
      case Success<AccountSubject?>(value: null):
        return _fail(_pinnedSubjectAbsentFailure());
    }

    final storedResult = await _credentialStore.read();
    final CredentialBundle stored;
    switch (storedResult) {
      case Failed<CredentialBundle?>(:final failure):
        return _fail(failure);
      case Success<CredentialBundle?>(value: final value?):
        stored = value;
      case Success<CredentialBundle?>(value: null):
        return _fail(_credentialsAbsentFailure());
    }

    final DpopKeyPair key;
    try {
      key = DpopKeyPair.fromPrivateJwkJson(stored.dpopPrivateKeyJwk);
    } on FormatException {
      return _fail(_dpopKeyInvalidFailure());
    }
    final tokenClient = _createTokenClient(key);
    final credentials = oauth2.Credentials(
      'expired-access-token-placeholder',
      refreshToken: stored.refreshToken,
      tokenEndpoint: _config.tokenEndpoint,
      scopes: const <String>[googleOpenIdScope, googleTasksScope],
      expiration: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
    final oauthClient = oauth2.Client(
      credentials,
      identifier: _config.clientId,
      secret: _config.clientSecret,
      basicAuth: false,
      httpClient: tokenClient,
    );
    _emit(AuthorizationRefreshPending(pinned));
    try {
      await oauthClient.refreshCredentials();
      return _acceptClient(
        oauthClient,
        key,
        expectedPinnedSubject: pinned,
        pinFirstAuthorization: false,
      );
    } on oauth2.AuthorizationException catch (error) {
      oauthClient.close();
      return _fail(_oauthFailure(error, refresh: true));
    } on FormatException {
      oauthClient.close();
      return _fail(_tokenResponseFailure());
    } catch (_) {
      oauthClient.close();
      return _fail(_tokenResponseFailure());
    }
  }

  Future<Outcome<LinuxAuthorizedSession>> refresh() async {
    final session = _session;
    if (session == null) {
      return _fail(_credentialsAbsentFailure());
    }
    _emit(AuthorizationRefreshPending(session.subject));
    try {
      await session._client.refreshCredentials();
      return _validateRefreshedSession(session);
    } on oauth2.AuthorizationException catch (error) {
      return _fail(_oauthFailure(error, refresh: true));
    } on FormatException {
      return _fail(_tokenResponseFailure());
    }
  }

  Future<Outcome<int>> probeTaskLists() async {
    final session = _session;
    if (session == null) {
      return Outcome<int>.failure(_credentialsAbsentFailure());
    }
    final pinnedResult = await _subjectStore.read();
    if (pinnedResult is! Success<AccountSubject?> ||
        pinnedResult.value != session.subject) {
      final failure = pinnedResult is Failed<AccountSubject?>
          ? pinnedResult.failure
          : _subjectMismatchFailure();
      _fail<LinuxAuthorizedSession>(failure);
      return Outcome<int>.failure(failure);
    }
    try {
      final endpoint = _config.taskListsEndpoint.replace(
        queryParameters: const <String, String>{'maxResults': '1'},
      );
      final response = await session.authenticatedClient.get(endpoint);
      if (response.statusCode != HttpStatus.ok) {
        return Outcome<int>.failure(_tasksProbeFailure());
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> ||
          decoded['kind'] != 'tasks#taskLists' ||
          (decoded['items'] != null && decoded['items'] is! List<dynamic>)) {
        return Outcome<int>.failure(_tasksProbeFailure());
      }
      final items = decoded['items'] as List<dynamic>?;
      return Outcome<int>.success(items?.length ?? 0);
    } on oauth2.AuthorizationException catch (error) {
      final failure = _oauthFailure(error, refresh: true);
      _fail<LinuxAuthorizedSession>(failure);
      return Outcome<int>.failure(failure);
    } catch (_) {
      return Outcome<int>.failure(_tasksProbeFailure());
    }
  }

  @override
  Future<Outcome<AccountSubject>> restoreTasksAuthorization() async {
    return switch (await restore()) {
      Success<LinuxAuthorizedSession>(:final value) =>
        Outcome<AccountSubject>.success(value.subject),
      Failed<LinuxAuthorizedSession>(:final failure) =>
        Outcome<AccountSubject>.failure(failure),
    };
  }

  @override
  Future<Outcome<AccountSubject>> refreshTasksAuthorization() async {
    return switch (await refresh()) {
      Success<LinuxAuthorizedSession>(:final value) =>
        Outcome<AccountSubject>.success(value.subject),
      Failed<LinuxAuthorizedSession>(:final failure) =>
        Outcome<AccountSubject>.failure(failure),
    };
  }

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() async {
    return switch (await connect()) {
      Success<LinuxAuthorizedSession>(:final value) =>
        Outcome<AccountSubject>.success(value.subject),
      Failed<LinuxAuthorizedSession>(:final failure) =>
        Outcome<AccountSubject>.failure(failure),
    };
  }

  Future<Outcome<LinuxAuthorizedSession>> _acceptClient(
    oauth2.Client client,
    DpopKeyPair key, {
    String? expectedNonce,
    AccountSubject? expectedPinnedSubject,
    required bool pinFirstAuthorization,
  }) async {
    final credentials = client.credentials;
    if (!(credentials.scopes?.contains(googleTasksScope) ?? false)) {
      client.close();
      return _fail(
        _missingScopeFailure(credentials.scopes ?? const <String>[]),
      );
    }
    final refreshToken = credentials.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      client.close();
      return _fail(_refreshTokenAbsentFailure());
    }
    final Outcome<AccountSubject> identity;
    if (expectedNonce != null) {
      final idToken = credentials.idToken;
      if (idToken == null || idToken.isEmpty) {
        client.close();
        return _fail(_identityFailure());
      }
      identity = await _identityVerifier.verify(
        idToken,
        clientId: _config.clientId,
        expectedNonce: expectedNonce,
      );
    } else {
      identity = await _identityVerifier.resolveSubject(client);
    }
    if (identity case Failed<AccountSubject>(:final failure)) {
      client.close();
      return _fail(failure);
    }
    final subject = (identity as Success<AccountSubject>).value;
    if (expectedPinnedSubject != null && subject != expectedPinnedSubject) {
      client.close();
      return _fail(_subjectMismatchFailure());
    }
    if (pinFirstAuthorization) {
      final pin = await _subjectStore.pin(subject);
      if (pin case Failed<void>(:final failure)) {
        client.close();
        return _fail(failure);
      }
    }
    final stored = await _credentialStore.replace(
      CredentialBundle(
        refreshToken: refreshToken,
        dpopPrivateKeyJwk: key.privateJwkJson,
      ),
    );
    if (stored case Failed<void>(:final failure)) {
      client.close();
      return _fail(failure);
    }
    final session = LinuxAuthorizedSession(
      subject: subject,
      client: client,
      dpopKey: key,
    );
    _session = session;
    _emit(TasksAuthorized(subject));
    return Outcome<LinuxAuthorizedSession>.success(session);
  }

  Future<Outcome<LinuxAuthorizedSession>> _validateRefreshedSession(
    LinuxAuthorizedSession session,
  ) async {
    final identity = await _identityVerifier.resolveSubject(
      session.authenticatedClient,
    );
    if (identity case Failed<AccountSubject>(:final failure)) {
      return _fail(failure);
    }
    final subject = (identity as Success<AccountSubject>).value;
    if (subject != session.subject) {
      return _fail(_subjectMismatchFailure());
    }
    final refreshToken = session.credentials.refreshToken;
    if (refreshToken == null) {
      return _fail(_refreshTokenAbsentFailure());
    }
    final stored = await _credentialStore.replace(
      CredentialBundle(
        refreshToken: refreshToken,
        dpopPrivateKeyJwk: session._dpopKey.privateJwkJson,
      ),
    );
    if (stored case Failed<void>(:final failure)) {
      return _fail(failure);
    }
    _emit(TasksAuthorized(subject));
    return Outcome<LinuxAuthorizedSession>.success(session);
  }

  DpopTokenClient _createTokenClient(DpopKeyPair key) {
    final client = DpopTokenClient(
      inner: _httpClientFactory(),
      tokenEndpoint: _config.tokenEndpoint,
      proofs: DpopProofFactory(
        key: key,
        clock: _clock,
        randomness: _randomness,
      ),
    );
    _activeTokenClient = client;
    return client;
  }

  Outcome<T> _fail<T>(Failure failure) {
    final terminal =
        failure.code == 'auth.refresh_rejected' ||
        failure.code == 'auth.dpop_key_rejected' ||
        failure.code == 'auth.tasks_scope_absent' ||
        failure.code == 'account.subject_mismatch';
    _emit(
      terminal
          ? AuthorizationRejected(failure)
          : AuthorizationRequestFailed(failure),
    );
    _diagnostics.record(
      DiagnosticEvent(
        code: failure.code,
        operation: 'linux-authorization',
        fields: <DiagnosticField>[
          DiagnosticField.safe('category', failure.category.name),
          DiagnosticField.safe('operation', failure.operation.name),
          DiagnosticField.safe('retry', failure.retry.name),
          DiagnosticField.safe('action', failure.action?.name ?? 'none'),
          DiagnosticField.safe('summary', failure.safeSummary),
          if (failure.sensitiveContext case final context?)
            DiagnosticField.private('developmentContext', context),
        ],
      ),
    );
    return Outcome<T>.failure(failure);
  }

  void _emit(AuthorizationState state) {
    _currentState = state;
    if (!_states.isClosed) {
      _states.add(state);
    }
  }

  void close() {
    _session?._client.close();
    unawaited(_states.close());
  }
}

bool _isValidSubject(String value) =>
    RegExp(r'^[\x21-\x7e]{1,255}$').hasMatch(value);

Failure _identityFailure() => const Failure(
  code: 'auth.identity_invalid',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'The authenticated Google identity could not be verified.',
  action: FailureAction.connect,
  safeSummary: 'The authenticated identity token was invalid.',
);

Failure _pinnedSubjectAbsentFailure() => const Failure(
  code: 'account.pinned_subject_absent',
  category: FailureCategory.configuration,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'No Google Tasks data was read or changed.',
  action: FailureAction.reviewConfiguration,
  safeSummary: 'The dedicated account subject is not pinned.',
);

Failure _subjectMismatchFailure() => const Failure(
  code: 'account.subject_mismatch',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'No Google Tasks data was read or changed.',
  action: FailureAction.reviewConfiguration,
  safeSummary: 'The authenticated subject does not match the pinned account.',
);

Failure _subjectStoreMissingFailure() => const Failure(
  code: 'account.subject_store_missing',
  category: FailureCategory.configuration,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'Development Google access is disabled.',
  action: FailureAction.reviewConfiguration,
  safeSummary: 'The private subject store is missing.',
);

Failure _subjectStoreInvalidFailure() => const Failure(
  code: 'account.subject_store_invalid',
  category: FailureCategory.persistence,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'Development Google access is disabled.',
  action: FailureAction.reviewConfiguration,
  safeSummary: 'The private subject store is invalid.',
);

Failure _subjectStoreReadFailure() => const Failure(
  code: 'account.subject_store_read_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.read,
  retry: RetryClassification.unknown,
  impact: 'Development Google access is disabled.',
  action: FailureAction.retry,
  safeSummary: 'The private subject store could not be read.',
);

Failure _subjectStoreWriteFailure() => const Failure(
  code: 'account.subject_store_write_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The dedicated account identity could not be pinned.',
  action: FailureAction.retry,
  safeSummary: 'The private subject store could not be verified.',
);

Failure _credentialsAbsentFailure() => const Failure(
  code: 'auth.credentials_absent',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks cannot be synchronized.',
  action: FailureAction.connect,
  safeSummary: 'Saved authorization is absent.',
);

Failure _dpopKeyInvalidFailure() => const Failure(
  code: 'auth.dpop_key_invalid',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Saved Google authorization cannot be refreshed.',
  action: FailureAction.connect,
  safeSummary: 'The saved DPoP key is missing or invalid.',
);

Failure _missingScopeFailure(Iterable<String> grantedScopes) => Failure(
  code: 'auth.tasks_scope_absent',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks access was not granted.',
  action: FailureAction.connect,
  safeSummary:
      'Google sign-in completed, but Google Tasks access was not granted. '
      'Reconnect and select Google Tasks access on the consent screen.',
  sensitiveContext: 'grantedScopes=${grantedScopes.join(',')}',
);

Failure _refreshTokenAbsentFailure() => const Failure(
  code: 'auth.refresh_token_absent',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Google authorization cannot be restored after restart.',
  action: FailureAction.connect,
  safeSummary: 'Google did not return a refresh token.',
);

Failure _oauthFailure(
  oauth2.AuthorizationException error, {
  required bool refresh,
}) {
  if (refresh && error.error == 'invalid_grant') {
    return const Failure(
      code: 'auth.refresh_rejected',
      category: FailureCategory.authorization,
      operation: FailureOperation.authorize,
      retry: RetryClassification.permanent,
      impact: 'Google authorization must be renewed.',
      action: FailureAction.connect,
      safeSummary: 'Google terminally rejected the refresh grant.',
    );
  }
  if (error.error == 'invalid_dpop_proof') {
    return const Failure(
      code: 'auth.dpop_key_rejected',
      category: FailureCategory.authorization,
      operation: FailureOperation.authorize,
      retry: RetryClassification.permanent,
      impact: 'Saved Google authorization cannot be refreshed.',
      action: FailureAction.connect,
      safeSummary: 'Google rejected the DPoP proof.',
    );
  }
  return Failure(
    code: refresh ? 'auth.refresh_failed' : 'auth.exchange_failed',
    category: FailureCategory.authorization,
    operation: FailureOperation.authorize,
    retry: RetryClassification.unknown,
    impact: 'Google authorization did not complete.',
    action: FailureAction.retry,
    safeSummary: 'The OAuth token endpoint rejected the request.',
  );
}

Failure _tokenResponseFailure() => const Failure(
  code: 'auth.token_response_invalid',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.unknown,
  impact: 'Google authorization did not complete.',
  action: FailureAction.retry,
  safeSummary: 'The token response could not be accepted.',
);

Failure _tasksProbeFailure() => const Failure(
  code: 'auth.tasks_probe_failed',
  category: FailureCategory.remote,
  operation: FailureOperation.read,
  retry: RetryClassification.unknown,
  impact: 'Google Tasks authorization could not be verified.',
  action: FailureAction.retry,
  safeSummary: 'The authenticated task-list request failed.',
);
