import 'dart:async';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/linux/browser_flow.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('SystemBrowserLauncher', () {
    test('accepts a successful platform browser handoff', () async {
      final opened = <Uri>[];
      final launcher = SystemBrowserLauncher(
        starter: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      final uri = Uri.https('accounts.example.test', '/authorize');

      expect(await launcher.launchExternal(uri), isTrue);
      expect(opened, <Uri>[uri]);
    });

    test('reports a platform browser launch failure', () async {
      final launcher = SystemBrowserLauncher(
        starter: (_) async => throw PlatformException(code: 'launch'),
      );

      expect(
        await launcher.launchExternal(
          Uri.https('accounts.example.test', '/authorize'),
        ),
        isFalse,
      );
    });
  });

  group('LinuxBrowserFlow', () {
    test(
      'real listener ignores unrelated requests before the callback',
      () async {
        final listener = await const HttpLoopbackCallbackFactory().bind();
        addTearDown(listener.close);
        var callbackObserved = false;
        unawaited(listener.nextRequest.then((_) => callbackObserved = true));

        final unrelated = await http.get(
          listener.redirectUri.replace(path: '/favicon.ico'),
        );
        expect(unrelated.statusCode, 404);
        expect(callbackObserved, isFalse);

        final callbackResponse = Completer<http.Response>();
        unawaited(
          http
              .get(
                listener.redirectUri.replace(
                  queryParameters: const <String, String>{
                    'code': 'synthetic-code',
                    'state': 'synthetic-state',
                  },
                ),
              )
              .then(
                callbackResponse.complete,
                onError: callbackResponse.completeError,
              ),
        );
        final callback = await listener.nextRequest;
        expect(callback.path, '/oauth2/callback');
        await listener.respond(CallbackResponse.success);
        expect((await callbackResponse.future).statusCode, 200);
      },
    );

    test(
      'uses loopback ephemeral redirect, PKCE S256, state, and nonce',
      () async {
        final listener = FakeCallbackListener();
        final launcher = RecordingBrowserLauncher();
        final flow = LinuxBrowserFlow(
          callbackFactory: FakeCallbackFactory(listener),
          browserLauncher: launcher,
          randomness: SequenceRandomSource(List<int>.generate(160, (i) => i)),
        );

        final future = flow.authorize(
          buildAuthorizationUri: buildTestAuthorizationUri,
          cancellation: AuthorizationCancellation(),
        );
        await launcher.launched;
        final authorizationUri = launcher.uris.single;
        listener.complete(
          CallbackRequest(
            method: 'GET',
            path: '/oauth2/callback',
            queryParameters: <String, List<String>>{
              'code': <String>['synthetic-code'],
              'state': <String>[authorizationUri.queryParameters['state']!],
            },
          ),
        );

        final result = await future;
        expect(result, isA<Success<BrowserAuthorizationCode>>());
        final value = (result as Success<BrowserAuthorizationCode>).value;
        expect(value.code, 'synthetic-code');
        expect(value.redirectUri, listener.redirectUri);
        expect(value.state, authorizationUri.queryParameters['state']);
        expect(value.nonce, authorizationUri.queryParameters['nonce']);
        expect(value.codeVerifier.length, greaterThanOrEqualTo(43));
        expect(
          authorizationUri.queryParameters['code_challenge_method'],
          'S256',
        );
        expect(authorizationUri.queryParameters['code_challenge'], isNotEmpty);
        expect(listener.lastResponse, CallbackResponse.success);
        expect(listener.closed, isTrue);
      },
    );

    test('rejects missing, repeated, and mismatched state', () async {
      for (final stateValues in <List<String>>[
        <String>[],
        <String>['wrong-state'],
        <String>['one', 'two'],
      ]) {
        final listener = FakeCallbackListener();
        final launcher = RecordingBrowserLauncher();
        final flow = LinuxBrowserFlow(
          callbackFactory: FakeCallbackFactory(listener),
          browserLauncher: launcher,
          randomness: SequenceRandomSource(List<int>.filled(160, 7)),
        );
        final future = flow.authorize(
          buildAuthorizationUri: buildTestAuthorizationUri,
          cancellation: AuthorizationCancellation(),
        );
        await launcher.launched;
        listener.complete(
          CallbackRequest(
            method: 'GET',
            path: '/oauth2/callback',
            queryParameters: <String, List<String>>{
              'code': <String>['synthetic-code'],
              if (stateValues.isNotEmpty) 'state': stateValues,
            },
          ),
        );

        final result = await future;
        expect(result, isA<Failed<BrowserAuthorizationCode>>());
        expect(
          (result as Failed<BrowserAuthorizationCode>).failure.code,
          'auth.callback_state_mismatch',
        );
        expect(listener.lastResponse, CallbackResponse.failure);
      }
    });

    test(
      'rejects callback path, method, and repeated code mismatches',
      () async {
        final requests = <CallbackRequest>[
          const CallbackRequest(
            method: 'GET',
            path: '/wrong',
            queryParameters: <String, List<String>>{},
          ),
          const CallbackRequest(
            method: 'POST',
            path: '/oauth2/callback',
            queryParameters: <String, List<String>>{},
          ),
          const CallbackRequest(
            method: 'GET',
            path: '/oauth2/callback',
            queryParameters: <String, List<String>>{
              'code': <String>['one', 'two'],
            },
          ),
          const CallbackRequest(
            method: 'GET',
            path: '/oauth2/callback',
            queryParameters: <String, List<String>>{
              'code': <String>['synthetic-code'],
              'error': <String>['access_denied'],
            },
          ),
          const CallbackRequest(
            method: 'GET',
            path: '/oauth2/callback',
            queryParameters: <String, List<String>>{
              'code': <String>['synthetic-code'],
              'error': <String>['access_denied', 'server_error'],
            },
          ),
        ];
        for (final request in requests) {
          final listener = FakeCallbackListener();
          final launcher = RecordingBrowserLauncher();
          final flow = LinuxBrowserFlow(
            callbackFactory: FakeCallbackFactory(listener),
            browserLauncher: launcher,
            randomness: SequenceRandomSource(List<int>.filled(160, 8)),
          );
          final future = flow.authorize(
            buildAuthorizationUri: buildTestAuthorizationUri,
            cancellation: AuthorizationCancellation(),
          );
          await launcher.launched;
          final state = launcher.uris.single.queryParameters['state']!;
          listener.complete(
            CallbackRequest(
              method: request.method,
              path: request.path,
              queryParameters: <String, List<String>>{
                ...request.queryParameters,
                'state': <String>[state],
              },
            ),
          );

          final result = await future;
          expect(result, isA<Failed<BrowserAuthorizationCode>>());
          expect(
            (result as Failed<BrowserAuthorizationCode>).failure.code,
            'auth.callback_invalid',
          );
        }
      },
    );

    test(
      'reports bind conflict and browser launch failure without waiting',
      () async {
        final conflictFlow = LinuxBrowserFlow(
          callbackFactory: const FailingCallbackFactory(),
          browserLauncher: RecordingBrowserLauncher(),
          randomness: SequenceRandomSource(List<int>.filled(160, 9)),
        );
        final conflict = await conflictFlow.authorize(
          buildAuthorizationUri: buildTestAuthorizationUri,
          cancellation: AuthorizationCancellation(),
        );
        expect(
          (conflict as Failed<BrowserAuthorizationCode>).failure.code,
          'auth.callback_bind_failed',
        );

        final listener = FakeCallbackListener();
        final launchFlow = LinuxBrowserFlow(
          callbackFactory: FakeCallbackFactory(listener),
          browserLauncher: RecordingBrowserLauncher(succeed: false),
          randomness: SequenceRandomSource(List<int>.filled(160, 10)),
        );
        final launch = await launchFlow.authorize(
          buildAuthorizationUri: buildTestAuthorizationUri,
          cancellation: AuthorizationCancellation(),
        );
        expect(
          (launch as Failed<BrowserAuthorizationCode>).failure.code,
          'auth.browser_launch_failed',
        );
        expect(listener.closed, isTrue);
      },
    );

    test(
      'cancellation closes the callback listener and changes no callback state',
      () async {
        final listener = FakeCallbackListener();
        final launcher = RecordingBrowserLauncher();
        final cancellation = AuthorizationCancellation();
        final flow = LinuxBrowserFlow(
          callbackFactory: FakeCallbackFactory(listener),
          browserLauncher: launcher,
          randomness: SequenceRandomSource(List<int>.filled(160, 11)),
        );
        final future = flow.authorize(
          buildAuthorizationUri: buildTestAuthorizationUri,
          cancellation: cancellation,
        );
        await launcher.launched;
        cancellation.cancel();

        final result = await future;
        expect(
          (result as Failed<BrowserAuthorizationCode>).failure.code,
          'auth.cancelled',
        );
        expect(listener.closed, isTrue);
        expect(listener.lastResponse, isNull);
      },
    );

    test(
      'callback deadline closes the listener without a real-time wait',
      () async {
        final listener = FakeCallbackListener();
        final launcher = RecordingBrowserLauncher();
        final clock = ManualClock(DateTime.utc(2026, 8, 21));
        final flow = LinuxBrowserFlow(
          callbackFactory: FakeCallbackFactory(listener),
          browserLauncher: launcher,
          randomness: SequenceRandomSource(List<int>.filled(160, 14)),
          scheduler: clock,
        );
        final future = flow.authorize(
          buildAuthorizationUri: buildTestAuthorizationUri,
          cancellation: AuthorizationCancellation(),
        );
        await launcher.launched;
        await listener.waitingForRequest;

        clock.advance(linuxAuthorizationCallbackDeadline);
        final result = await future;

        expect(
          (result as Failed<BrowserAuthorizationCode>).failure.code,
          'auth.callback_timeout',
        );
        expect(result.failure.category, FailureCategory.network);
        expect(listener.closed, isTrue);
        expect(listener.lastResponse, isNull);
      },
    );

    test(
      'validated callback survives response and listener cleanup failures',
      () async {
        final history = InMemoryDiagnosticHistory();
        final listener = FakeCallbackListener(
          failResponse: true,
          failClose: true,
        );
        final launcher = RecordingBrowserLauncher();
        final flow = LinuxBrowserFlow(
          callbackFactory: FakeCallbackFactory(listener),
          browserLauncher: launcher,
          randomness: SequenceRandomSource(List<int>.filled(160, 12)),
          diagnostics: SensitiveDevelopmentDiagnosticSink(history),
        );
        final future = flow.authorize(
          buildAuthorizationUri: buildTestAuthorizationUri,
          cancellation: AuthorizationCancellation(),
        );
        await launcher.launched;
        final state = launcher.uris.single.queryParameters['state']!;
        listener.complete(
          CallbackRequest(
            method: 'GET',
            path: '/oauth2/callback',
            queryParameters: <String, List<String>>{
              'code': <String>['synthetic-code'],
              'state': <String>[state],
            },
          ),
        );

        expect(await future, isA<Success<BrowserAuthorizationCode>>());
        expect(
          history.records.map((record) => record.code),
          containsAll(<String>[
            'auth.callback_response_failed',
            'auth.callback_close_failed',
          ]),
        );
      },
    );

    test('completes through the real loopback HTTP listener', () async {
      final launcher = LoopbackCompletingBrowserLauncher();
      final flow = LinuxBrowserFlow(
        callbackFactory: const HttpLoopbackCallbackFactory(),
        browserLauncher: launcher,
        randomness: SequenceRandomSource(List<int>.filled(160, 13)),
      );

      final result = await flow.authorize(
        buildAuthorizationUri: buildTestAuthorizationUri,
        cancellation: AuthorizationCancellation(),
      );
      final browserResponse = await launcher.response;

      expect(result, isA<Success<BrowserAuthorizationCode>>());
      expect(browserResponse.statusCode, 200);
      expect(browserResponse.body, contains('Authorization completed'));
    });
  });
}

Uri buildTestAuthorizationUri({
  required Uri redirectUri,
  required String state,
  required String nonce,
  required String codeVerifier,
}) {
  return Uri.https('accounts.example.test', '/authorize', <String, String>{
    'redirect_uri': redirectUri.toString(),
    'state': state,
    'nonce': nonce,
    'code_challenge': pkceS256Challenge(codeVerifier),
    'code_challenge_method': 'S256',
  });
}

final class RecordingBrowserLauncher implements BrowserLauncher {
  RecordingBrowserLauncher({this.succeed = true});

  final bool succeed;
  final List<Uri> uris = <Uri>[];
  final Completer<void> _launched = Completer<void>();

  Future<void> get launched => _launched.future;

  @override
  Future<bool> launchExternal(Uri uri) async {
    uris.add(uri);
    if (!_launched.isCompleted) {
      _launched.complete();
    }
    return succeed;
  }
}

final class LoopbackCompletingBrowserLauncher implements BrowserLauncher {
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

final class FakeCallbackFactory implements LoopbackCallbackFactory {
  const FakeCallbackFactory(this.listener);

  final FakeCallbackListener listener;

  @override
  Future<LoopbackCallbackListener> bind() async => listener;
}

final class FailingCallbackFactory implements LoopbackCallbackFactory {
  const FailingCallbackFactory();

  @override
  Future<LoopbackCallbackListener> bind() async {
    throw const LoopbackBindException();
  }
}

final class FakeCallbackListener implements LoopbackCallbackListener {
  FakeCallbackListener({this.failResponse = false, this.failClose = false});

  final Completer<CallbackRequest> _request = Completer<CallbackRequest>();
  final Completer<void> _waitingForRequest = Completer<void>();
  final bool failResponse;
  final bool failClose;

  bool closed = false;
  CallbackResponse? lastResponse;

  @override
  Uri get redirectUri => Uri.parse('http://127.0.0.1:43127/oauth2/callback');

  @override
  Future<CallbackRequest> get nextRequest {
    if (!_waitingForRequest.isCompleted) _waitingForRequest.complete();
    return _request.future;
  }

  Future<void> get waitingForRequest => _waitingForRequest.future;

  void complete(CallbackRequest request) {
    _request.complete(request);
  }

  @override
  Future<void> respond(CallbackResponse response) async {
    lastResponse = response;
    if (failResponse) {
      throw StateError('synthetic response failure');
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (failClose) {
      throw StateError('synthetic close failure');
    }
  }
}
