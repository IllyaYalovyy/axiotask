import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/diagnostics/diagnostics.dart';
import '../../../core/failure.dart';
import '../../../core/outcome.dart';
import '../../../core/randomness.dart';

const String _callbackPath = '/oauth2/callback';

typedef AuthorizationUriBuilder =
    Uri Function({
      required Uri redirectUri,
      required String state,
      required String nonce,
      required String codeVerifier,
    });

final class BrowserAuthorizationCode {
  const BrowserAuthorizationCode({
    required this.code,
    required this.redirectUri,
    required this.state,
    required this.nonce,
    required this.codeVerifier,
  });

  final String code;
  final Uri redirectUri;
  final String state;
  final String nonce;
  final String codeVerifier;

  @override
  String toString() => 'BrowserAuthorizationCode(<redacted>)';
}

final class AuthorizationCancellation {
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get whenCancelled => _cancelled.future;
  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }
}

abstract interface class BrowserLauncher {
  Future<bool> launchExternal(Uri uri);
}

typedef ExternalBrowserStarter = Future<bool> Function(Uri uri);

final class SystemBrowserLauncher implements BrowserLauncher {
  const SystemBrowserLauncher({this.starter = _startExternalBrowser});

  final ExternalBrowserStarter starter;

  @override
  Future<bool> launchExternal(Uri uri) async {
    try {
      return await starter(uri);
    } on PlatformException {
      return false;
    }
  }
}

Future<bool> _startExternalBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

final class LoopbackBindException implements Exception {
  const LoopbackBindException();

  @override
  String toString() => 'LoopbackBindException';
}

enum CallbackResponse { success, failure }

final class CallbackRequest {
  const CallbackRequest({
    required this.method,
    required this.path,
    required this.queryParameters,
  });

  final String method;
  final String path;
  final Map<String, List<String>> queryParameters;
}

abstract interface class LoopbackCallbackListener {
  Uri get redirectUri;
  Future<CallbackRequest> get nextRequest;

  Future<void> respond(CallbackResponse response);
  Future<void> close();
}

abstract interface class LoopbackCallbackFactory {
  Future<LoopbackCallbackListener> bind();
}

final class HttpLoopbackCallbackFactory implements LoopbackCallbackFactory {
  const HttpLoopbackCallbackFactory();

  @override
  Future<LoopbackCallbackListener> bind() async {
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      return _HttpLoopbackCallbackListener(server);
    } on SocketException {
      throw const LoopbackBindException();
    }
  }
}

final class _HttpLoopbackCallbackListener implements LoopbackCallbackListener {
  _HttpLoopbackCallbackListener(this._server)
    : _redirectUri = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _server.port,
        path: _callbackPath,
      ) {
    _subscription = _server.listen(
      _receive,
      onError: _requests.completeError,
      onDone: _completeWithoutRequest,
      cancelOnError: false,
    );
  }

  final HttpServer _server;
  final Uri _redirectUri;
  final Completer<CallbackRequest> _requests = Completer<CallbackRequest>();
  late final StreamSubscription<HttpRequest> _subscription;
  HttpRequest? _pendingRequest;

  @override
  Uri get redirectUri => _redirectUri;

  @override
  Future<CallbackRequest> get nextRequest => _requests.future;

  void _receive(HttpRequest request) {
    if (_requests.isCompleted) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }
    _pendingRequest = request;
    _requests.complete(
      CallbackRequest(
        method: request.method,
        path: request.uri.path,
        queryParameters: request.uri.queryParametersAll,
      ),
    );
  }

  void _completeWithoutRequest() {
    if (!_requests.isCompleted) {
      _requests.completeError(
        const HttpException('Loopback callback listener closed.'),
      );
    }
  }

  @override
  Future<void> respond(CallbackResponse response) async {
    final request = _pendingRequest;
    if (request == null) {
      return;
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(
        response == CallbackResponse.success
            ? '<!doctype html><title>Axiotask connected</title>'
                  '<p>Authorization completed. You can return to Axiotask.</p>'
            : '<!doctype html><title>Axiotask authorization failed</title>'
                  '<p>Authorization was not accepted. Return to Axiotask for details.</p>',
      );
    await request.response.close();
    _pendingRequest = null;
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

String pkceS256Challenge(String verifier) =>
    _base64UrlNoPadding(sha256.convert(ascii.encode(verifier)).bytes);

abstract interface class BrowserAuthorizationFlow {
  Future<Outcome<BrowserAuthorizationCode>> authorize({
    required AuthorizationUriBuilder buildAuthorizationUri,
    required AuthorizationCancellation cancellation,
  });
}

final class LinuxBrowserFlow implements BrowserAuthorizationFlow {
  factory LinuxBrowserFlow({
    required LoopbackCallbackFactory callbackFactory,
    required BrowserLauncher browserLauncher,
    required RandomSource randomness,
    DiagnosticSink? diagnostics,
  }) => LinuxBrowserFlow._(
    callbackFactory,
    browserLauncher,
    randomness,
    diagnostics,
  );

  const LinuxBrowserFlow._(
    this._callbackFactory,
    this._browserLauncher,
    this._randomness,
    this._diagnostics,
  );

  final LoopbackCallbackFactory _callbackFactory;
  final BrowserLauncher _browserLauncher;
  final RandomSource _randomness;
  final DiagnosticSink? _diagnostics;

  @override
  Future<Outcome<BrowserAuthorizationCode>> authorize({
    required AuthorizationUriBuilder buildAuthorizationUri,
    required AuthorizationCancellation cancellation,
  }) async {
    if (cancellation.isCancelled) {
      return Outcome<BrowserAuthorizationCode>.failure(_cancelledFailure());
    }

    final LoopbackCallbackListener listener;
    try {
      listener = await _callbackFactory.bind();
    } on LoopbackBindException {
      return Outcome<BrowserAuthorizationCode>.failure(_bindFailure());
    } catch (_) {
      return Outcome<BrowserAuthorizationCode>.failure(_bindFailure());
    }

    try {
      final String state;
      final String nonce;
      final String codeVerifier;
      final Uri redirectUri;
      final Uri authorizationUri;
      try {
        state = _randomValue(32);
        nonce = _randomValue(32);
        codeVerifier = _randomValue(64);
        redirectUri = listener.redirectUri;
        authorizationUri = buildAuthorizationUri(
          redirectUri: redirectUri,
          state: state,
          nonce: nonce,
          codeVerifier: codeVerifier,
        );
      } catch (_) {
        return Outcome<BrowserAuthorizationCode>.failure(
          _configurationFailure(),
        );
      }
      if (authorizationUri.scheme != 'https') {
        return Outcome<BrowserAuthorizationCode>.failure(
          _configurationFailure(),
        );
      }

      final bool launched;
      try {
        launched = await _browserLauncher.launchExternal(authorizationUri);
      } catch (_) {
        return Outcome<BrowserAuthorizationCode>.failure(_launchFailure());
      }
      if (!launched) {
        return Outcome<BrowserAuthorizationCode>.failure(_launchFailure());
      }

      final _CallbackWinner winner;
      try {
        winner = await Future.any<_CallbackWinner>(<Future<_CallbackWinner>>[
          listener.nextRequest.then(_CallbackReceived.new),
          cancellation.whenCancelled.then((_) => const _CallbackCancelled()),
        ]);
      } catch (_) {
        return Outcome<BrowserAuthorizationCode>.failure(
          _callbackReceiveFailure(),
        );
      }
      if (winner is _CallbackCancelled) {
        return Outcome<BrowserAuthorizationCode>.failure(_cancelledFailure());
      }

      final request = (winner as _CallbackReceived).request;
      final callback = _validateCallback(request, expectedState: state);
      try {
        await listener.respond(
          callback is Success<String>
              ? CallbackResponse.success
              : CallbackResponse.failure,
        );
      } catch (_) {
        _recordNonFatal('auth.callback_response_failed', 'respond');
      }
      return switch (callback) {
        Success<String>(:final value) =>
          Outcome<BrowserAuthorizationCode>.success(
            BrowserAuthorizationCode(
              code: value,
              redirectUri: redirectUri,
              state: state,
              nonce: nonce,
              codeVerifier: codeVerifier,
            ),
          ),
        Failed<String>(:final failure) =>
          Outcome<BrowserAuthorizationCode>.failure(failure),
      };
    } finally {
      try {
        await listener.close();
      } catch (_) {
        _recordNonFatal('auth.callback_close_failed', 'close');
      }
    }
  }

  String _randomValue(int bytes) =>
      _base64UrlNoPadding(_randomness.nextBytes(bytes));

  void _recordNonFatal(String code, String phase) {
    _diagnostics?.record(
      DiagnosticEvent(
        subsystem: DiagnosticSubsystem.authorization,
        kind: DiagnosticEventKind.failure,
        code: code,
        operation: 'linux-browser-authorization',
        fields: <DiagnosticField>[DiagnosticField.safe('phase', phase)],
      ),
    );
  }
}

sealed class _CallbackWinner {
  const _CallbackWinner();
}

final class _CallbackReceived extends _CallbackWinner {
  const _CallbackReceived(this.request);

  final CallbackRequest request;
}

final class _CallbackCancelled extends _CallbackWinner {
  const _CallbackCancelled();
}

Outcome<String> _validateCallback(
  CallbackRequest request, {
  required String expectedState,
}) {
  if (request.method != 'GET' || request.path != _callbackPath) {
    return Outcome<String>.failure(_invalidCallbackFailure());
  }
  final states = request.queryParameters['state'] ?? const <String>[];
  if (states.length != 1 || states.single != expectedState) {
    return Outcome<String>.failure(_stateFailure());
  }
  final errors = request.queryParameters['error'] ?? const <String>[];
  if (errors.length == 1) {
    return Outcome<String>.failure(
      errors.single == 'access_denied'
          ? _cancelledFailure()
          : _rejectedFailure(),
    );
  }
  final codes = request.queryParameters['code'] ?? const <String>[];
  if (codes.length != 1 || codes.single.isEmpty) {
    return Outcome<String>.failure(_invalidCallbackFailure());
  }
  return Outcome<String>.success(codes.single);
}

String _base64UrlNoPadding(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Failure _bindFailure() => const Failure(
  code: 'auth.callback_bind_failed',
  category: FailureCategory.configuration,
  operation: FailureOperation.authorize,
  retry: RetryClassification.transient,
  impact: 'Google authorization could not start.',
  action: FailureAction.retry,
  safeSummary: 'The loopback callback port could not be opened.',
);

Failure _launchFailure() => const Failure(
  code: 'auth.browser_launch_failed',
  category: FailureCategory.configuration,
  operation: FailureOperation.authorize,
  retry: RetryClassification.transient,
  impact: 'The system browser did not open for authorization.',
  action: FailureAction.retry,
  safeSummary: 'The external browser launch failed.',
);

Failure _callbackReceiveFailure() => const Failure(
  code: 'auth.callback_receive_failed',
  category: FailureCategory.network,
  operation: FailureOperation.authorize,
  retry: RetryClassification.transient,
  impact: 'Google authorization did not return to the application.',
  action: FailureAction.retry,
  safeSummary: 'The loopback authorization callback could not be received.',
);

Failure _configurationFailure() => const Failure(
  code: 'auth.authorization_endpoint_invalid',
  category: FailureCategory.configuration,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Google authorization cannot start.',
  action: FailureAction.reviewConfiguration,
  safeSummary: 'The authorization endpoint is not secure.',
);

Failure _cancelledFailure() => const Failure(
  code: 'auth.cancelled',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Google authorization was cancelled.',
  action: FailureAction.connect,
  safeSummary: 'The authorization request was cancelled.',
);

Failure _stateFailure() => const Failure(
  code: 'auth.callback_state_mismatch',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'The authorization response was rejected safely.',
  action: FailureAction.connect,
  safeSummary: 'The OAuth callback state did not match.',
);

Failure _invalidCallbackFailure() => const Failure(
  code: 'auth.callback_invalid',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'The authorization response was rejected safely.',
  action: FailureAction.connect,
  safeSummary: 'The OAuth callback was malformed.',
);

Failure _rejectedFailure() => const Failure(
  code: 'auth.authorization_rejected',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Google authorization was not granted.',
  action: FailureAction.connect,
  safeSummary: 'The authorization server rejected the request.',
);
