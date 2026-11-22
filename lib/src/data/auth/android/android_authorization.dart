import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../../../core/clock.dart';
import '../../../core/failure.dart';
import '../../../core/outcome.dart';
import '../authorization.dart';

const androidGoogleScopes = <String>[
  'https://www.googleapis.com/auth/tasks',
  'openid',
];

abstract interface class AndroidAuthorizationGateway {
  Future<String?> authorize({required bool interactive});
  Future<void> clearToken(String token);

  /// Ends the Google session Play Services keeps for this application, so
  /// the next interactive authorization offers the account chooser.
  Future<void> signOut();
}

/// Uses the registered Android package and release certificate. No desktop
/// client secret or server client ID is needed for access-token authorization.
final class GoogleAndroidAuthorizationGateway
    implements AndroidAuthorizationGateway {
  static Future<void>? _initialization;

  Future<void> _initialize() async {
    try {
      await (_initialization ??= GoogleSignIn.instance.initialize());
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  @override
  Future<String?> authorize({required bool interactive}) async {
    await _initialize();
    final client = GoogleSignIn.instance.authorizationClient;
    final grant = interactive
        ? await client.authorizeScopes(androidGoogleScopes)
        : await client.authorizationForScopes(androidGoogleScopes);
    return grant?.accessToken;
  }

  @override
  Future<void> clearToken(String token) async {
    await _initialize();
    await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(
      accessToken: token,
    );
  }

  @override
  Future<void> signOut() async {
    await _initialize();
    await GoogleSignIn.instance.signOut();
  }
}

/// Play Services owns persistence. Only a short-lived access token is kept in
/// memory; every new token is bound to Google's verified OpenID subject before
/// any Tasks request can use it.
final class AndroidAuthorization
    implements AuthorizationPort, SignOutAuthorization {
  AndroidAuthorization({
    required this._gateway,
    required this._identityClient,
    required this._clock,
    this._expectedSubject,
  });

  final AndroidAuthorizationGateway _gateway;
  final http.Client _identityClient;
  final Clock _clock;
  AccountSubject? _expectedSubject;
  final _states = StreamController<AuthorizationState>.broadcast();
  AuthorizationState _state = const NoTasksAuthorization();
  Future<Outcome<AccountSubject>>? _pending;
  String? _token;
  Duration? _validUntil;
  bool _closed = false;

  @override
  AuthorizationState get currentState => _state;

  @override
  Stream<AuthorizationState> get states => _states.stream;

  @override
  Future<Outcome<AccountSubject>> restoreTasksAuthorization() =>
      _authorize(interactive: false);

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() =>
      _authorize(interactive: true);

  @override
  Future<Outcome<AccountSubject>> refreshTasksAuthorization() =>
      _authorize(interactive: false, clearCachedToken: true);

  Future<Outcome<AccountSubject>> _authorize({
    required bool interactive,
    bool clearCachedToken = false,
  }) async {
    if (_closed) return const Outcome.failure(_closedFailure);
    final pending = _pending;
    if (pending != null) return pending;
    final operation = _acquire(
      interactive: interactive,
      clearCachedToken: clearCachedToken,
    );
    _pending = operation;
    try {
      return await operation;
    } finally {
      _pending = null;
    }
  }

  Future<Outcome<AccountSubject>> _acquire({
    required bool interactive,
    required bool clearCachedToken,
  }) async {
    final previousToken = _token;
    _token = null;
    _validUntil = null;
    _emit(
      interactive
          ? const AuthorizationConnecting()
          : _expectedSubject == null
          ? const NoTasksAuthorization()
          : AuthorizationRefreshPending(_expectedSubject!),
    );
    try {
      if (clearCachedToken && previousToken != null) {
        await _gateway.clearToken(previousToken);
      }
      final token = await _gateway.authorize(interactive: interactive);
      if (_closed) return const Outcome.failure(_closedFailure);
      if (token == null || token.isEmpty) {
        return _fail(_mapped(AuthorizationAdapterFailureKind.noCredentials));
      }
      final response = await _identityClient
          .get(
            Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'),
            headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 30));
      if (_closed) return const Outcome.failure(_closedFailure);
      if (response.statusCode == 401 || response.statusCode == 403) {
        await _gateway.clearToken(token);
        return _fail(_mapped(AuthorizationAdapterFailureKind.rejected));
      }
      if (response.statusCode == 429 || response.statusCode >= 500) {
        return _fail(_mapped(AuthorizationAdapterFailureKind.network));
      }
      if (response.statusCode != 200 || response.bodyBytes.length > 65536) {
        return _fail(_identityFailure);
      }
      final data = jsonDecode(response.body);
      final value = data is Map<String, dynamic> ? data['sub'] : null;
      if (value is! String || value.trim().isEmpty || value.length > 255) {
        return _fail(_identityFailure);
      }
      final subject = AccountSubject(value);
      if (_expectedSubject != null && subject != _expectedSubject) {
        return _fail(_subjectMismatchFailure);
      }
      _expectedSubject = subject;
      _token = token;
      _validUntil = _clock.monotonicElapsed + const Duration(minutes: 45);
      _emit(TasksAuthorized(subject));
      return Outcome.success(subject);
    } on GoogleSignInException catch (error) {
      // Play Services reports registration failures as unknownError (status 8).
      // Recognize only known markers; never retain or display the raw message,
      // which can contain account details.
      final description = error.description ?? '';
      if (description.contains('UNREGISTERED_ON_API_CONSOLE') ||
          description.contains('DEVELOPER_ERROR')) {
        return _fail(_mapped(AuthorizationAdapterFailureKind.configuration));
      }
      final kind = switch (error.code) {
        GoogleSignInExceptionCode.canceled ||
        GoogleSignInExceptionCode.interrupted ||
        GoogleSignInExceptionCode.uiUnavailable =>
          AuthorizationAdapterFailureKind.noCredentials,
        GoogleSignInExceptionCode.clientConfigurationError ||
        GoogleSignInExceptionCode.providerConfigurationError =>
          AuthorizationAdapterFailureKind.configuration,
        GoogleSignInExceptionCode.userMismatch =>
          AuthorizationAdapterFailureKind.rejected,
        GoogleSignInExceptionCode.unknownError =>
          AuthorizationAdapterFailureKind.internal,
      };
      return _fail(_mapped(kind));
    } on MissingPluginException {
      return _fail(_mapped(AuthorizationAdapterFailureKind.configuration));
    } on PlatformException {
      return _fail(_mapped(AuthorizationAdapterFailureKind.internal));
    } on TimeoutException {
      return _fail(_mapped(AuthorizationAdapterFailureKind.network));
    } on SocketException {
      return _fail(_mapped(AuthorizationAdapterFailureKind.network));
    } on http.ClientException {
      return _fail(_mapped(AuthorizationAdapterFailureKind.network));
    } on FormatException {
      return _fail(_identityFailure);
    } catch (_) {
      return _fail(_mapped(AuthorizationAdapterFailureKind.internal));
    }
  }

  @override
  Future<Outcome<void>> signOut() async {
    if (_closed) return const Outcome.failure(_closedFailure);
    final token = _token;
    _token = null;
    _validUntil = null;
    try {
      if (token != null) await _gateway.clearToken(token);
      await _gateway.signOut();
    } on Object {
      return const Outcome.failure(_signOutFailure);
    }
    _emit(const NoTasksAuthorization());
    return const Outcome.success(null);
  }

  Future<Outcome<String>> accessToken() async {
    if (_closed) return const Outcome.failure(_closedFailure);
    if (_token == null || _clock.monotonicElapsed >= _validUntil!) {
      final result = await refreshTasksAuthorization();
      if (result case Failed<AccountSubject>(:final failure)) {
        return Outcome.failure(failure);
      }
    }
    if (_closed || _token == null) return const Outcome.failure(_closedFailure);
    return Outcome.success(_token!);
  }

  Outcome<AccountSubject> _fail(Failure failure) {
    _token = null;
    _validUntil = null;
    _emit(
      failure.authorizationRecovery == AuthorizationRecovery.reauthorize
          ? AuthorizationRejected(failure)
          : AuthorizationRequestFailed(failure),
    );
    return Outcome.failure(failure);
  }

  void _emit(AuthorizationState state) {
    if (_closed) return;
    _state = state;
    _states.add(state);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _token = null;
    _identityClient.close();
    unawaited(_states.close());
  }
}

final class AndroidAuthorizedHttpClient extends http.BaseClient {
  AndroidAuthorizedHttpClient(this.authorization, this.client);

  final AndroidAuthorization authorization;
  final http.Client client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.scheme != 'https' ||
        request.url.host != 'tasks.googleapis.com' ||
        request.url.port != 443) {
      throw ArgumentError(
        'Android Tasks credentials require the Tasks endpoint.',
      );
    }
    final token = await authorization.accessToken();
    switch (token) {
      case Failed<String>(:final failure):
        throw AuthorizationTransportException(failure);
      case Success<String>(:final value):
        request.headers[HttpHeaders.authorizationHeader] = 'Bearer $value';
    }
    request.followRedirects = false;
    return client.send(request);
  }

  @override
  void close() => client.close();
}

Failure _mapped(AuthorizationAdapterFailureKind kind) =>
    mapAuthorizationFailure(AuthorizationAdapterFailure(kind: kind));

const _identityFailure = Failure(
  code: 'auth.identity_invalid',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks cannot be synchronized.',
  action: FailureAction.connect,
  safeSummary: 'Google account identity could not be verified.',
  authorizationRecovery: AuthorizationRecovery.reauthorize,
);

const _subjectMismatchFailure = Failure(
  code: 'account.subject_mismatch',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'No Google Tasks data was read or changed.',
  action: FailureAction.connect,
  safeSummary: 'Connect with the account already used on this device.',
  authorizationRecovery: AuthorizationRecovery.reauthorize,
);

const _closedFailure = Failure(
  code: 'auth.closed',
  category: FailureCategory.internal,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'The authorization session is closed.',
  action: FailureAction.retry,
  safeSummary: 'The authorization session is closed.',
);

const Failure _signOutFailure = Failure(
  code: 'auth.sign_out_failed',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.unknown,
  impact: 'This device is still signed in to Google Tasks.',
  action: FailureAction.retry,
  safeSummary: 'Google Play services could not end the session.',
);
