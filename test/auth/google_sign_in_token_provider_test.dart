// GoogleSignInTokenProvider tests — the Android half of the provider seam
// (MIGRATION-PLAN §5 T9.1). Two layers:
//
//  1. The pure contract mapper over a fake [GoogleAuthGateway]: it maps a
//     Play Services round-trip onto the three-state [TokenProvider] contract the
//     [AuthController] drives, and — wired through the controller — proves the
//     user-visible outcome: a live grant restores with no gesture, and Play
//     Services being absent starts the app quietly signed out (local-only) with
//     no crash, no false "session expired" banner, and no retry loop.
//
//  2. The live [GoogleSignInAuthGateway] over a mock GoogleSignInPlatform. This
//     is where T9.1's real behaviour lives, so it is pinned here: the SILENT
//     path never authenticates and never prompts for scopes; the interactive
//     path is the ONLY one that prompts; initialize() carries NO
//     clientId/serverClientId; and a GMS failure degrades to "unavailable"
//     rather than throwing out of the app.

import 'package:axiotask/src/auth/auth_controller.dart';
import 'package:axiotask/src/auth/google_sign_in_token_provider.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// A scripted [GoogleAuthGateway] for the contract-mapper tests. Records the
/// `interactive` flag of every authorize so a test can prove the restore path
/// asked silently and the gesture path asked interactively.
class _FakeGateway implements GoogleAuthGateway {
  _FakeGateway._(this._outcome);

  /// Grant is live: hands back a [GoogleAuthorization.token].
  factory _FakeGateway.token(String token) =>
      _FakeGateway._(GoogleAuthorization.token(token));

  /// Grant needs the interactive gesture.
  factory _FakeGateway.needsInteraction() =>
      _FakeGateway._(const GoogleAuthorization.needsInteraction());

  /// A broken "success" with a blank token.
  factory _FakeGateway.emptyToken() =>
      _FakeGateway._(const GoogleAuthorization.token(''));

  /// Play Services is unavailable (GMS absent/outdated, no network).
  factory _FakeGateway.unavailable(String message) =>
      _FakeGateway._(GoogleAuthUnavailable(message));

  final Object _outcome;
  final List<bool> calls = <bool>[];
  bool signedOut = false;

  @override
  Future<GoogleAuthorization> authorize({required bool interactive}) async {
    calls.add(interactive);
    final outcome = _outcome;
    if (outcome is GoogleAuthUnavailable) throw outcome;
    return outcome as GoogleAuthorization;
  }

  @override
  Future<void> signOut() async => signedOut = true;
}

/// A mock GoogleSignInPlatform driving the live gateway with no Play Services.
/// Scripted via the public fields; records init params, the auth calls made,
/// and — per authorize call — whether prompting UI was permitted.
class _MockPlatform extends GoogleSignInPlatform
    with MockPlatformInterfaceMixin {
  // Scripted outcomes.
  GoogleSignInException? initException;
  // A raw (non-GoogleSignInException) failure thrown from init — models a
  // method-channel PlatformException or a MissingPluginException escaping the
  // plugin.
  Exception? initRawError;
  AuthenticationResults? lightweightResult; // null => no cached session
  AuthenticationResults? authenticateResult;
  GoogleSignInException? authenticateException;
  ClientAuthorizationTokenData? clientAuthorization; // null => not grantable
  GoogleSignInException? clientAuthorizationException;

  // Records.
  int initCalls = 0;
  InitParameters? lastInit;
  int lightweightCalls = 0;
  int authenticateCalls = 0;
  final List<bool> authorizationPrompts = <bool>[];
  int signOutCalls = 0;

  @override
  Future<void> init(InitParameters params) async {
    initCalls++;
    lastInit = params;
    if (initRawError != null) throw initRawError!;
    if (initException != null) throw initException!;
  }

  @override
  Future<AuthenticationResults?>? attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    lightweightCalls++;
    return lightweightResult;
  }

  @override
  bool supportsAuthenticate() => true;

  @override
  Future<AuthenticationResults> authenticate(
    AuthenticateParameters params,
  ) async {
    authenticateCalls++;
    if (authenticateException != null) throw authenticateException!;
    return authenticateResult!;
  }

  @override
  bool authorizationRequiresUserInteraction() => false;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    authorizationPrompts.add(params.request.promptIfUnauthorized);
    if (clientAuthorizationException != null) {
      throw clientAuthorizationException!;
    }
    return clientAuthorization;
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async => throw UnimplementedError();

  // A failure to inject into signOut — models a raw GMS crash / method-channel
  // error escaping the plugin's signOut (a GoogleSignInException, a
  // PlatformException, or a MissingPluginException — all Exceptions).
  Exception? signOutError;

  @override
  Future<void> signOut(SignOutParams params) async {
    signOutCalls++;
    if (signOutError != null) throw signOutError!;
  }

  @override
  Future<void> disconnect(DisconnectParams params) async =>
      throw UnimplementedError();
}

AuthenticationResults _account() => const AuthenticationResults(
  user: GoogleSignInUserData(email: 'user@example.com', id: 'uid-1'),
  authenticationTokens: AuthenticationTokenData(idToken: null),
);

GoogleSignInException _exception(GoogleSignInExceptionCode code) =>
    GoogleSignInException(code: code, description: code.name);

void main() {
  group('GoogleSignInTokenProvider (contract mapper)', () {
    test('a live grant hands back the access token', () async {
      final gateway = _FakeGateway.token('android-access');
      final provider = GoogleSignInTokenProvider(gateway);

      expect(await provider.authorize(interactive: false), 'android-access');
      expect(gateway.calls, [false], reason: 'restore asks silently');
    });

    test('a grant needing the gesture surfaces interaction-required', () async {
      final provider = GoogleSignInTokenProvider(
        _FakeGateway.needsInteraction(),
      );

      await expectLater(
        provider.authorize(interactive: false),
        throwsA(isA<TokenProviderInteractionRequired>()),
      );
    });

    test(
      'Play Services unavailable maps to the transient outage, not a dead grant',
      () async {
        final provider = GoogleSignInTokenProvider(
          _FakeGateway.unavailable('gms updating'),
        );

        await expectLater(
          provider.authorize(interactive: false),
          throwsA(
            isA<TokenProviderUnavailable>().having(
              (e) => e.message,
              'message',
              'gms updating',
            ),
          ),
        );
      },
    );

    test('a blank access token is a broken response, not a session', () async {
      final provider = GoogleSignInTokenProvider(_FakeGateway.emptyToken());

      await expectLater(
        provider.authorize(interactive: true),
        throwsA(
          isA<TokenProviderUnavailable>().having(
            (e) => e.message,
            'message',
            'empty authorize response',
          ),
        ),
      );
    });

    test('the interactive gesture asks the gateway interactively', () async {
      final gateway = _FakeGateway.token('gesture-access');
      final provider = GoogleSignInTokenProvider(gateway);

      expect(await provider.authorize(interactive: true), 'gesture-access');
      expect(gateway.calls, [true]);
    });

    test('sign-out drops the Play Services session', () async {
      final gateway = _FakeGateway.token('x');
      await GoogleSignInTokenProvider(gateway).signOut();
      expect(gateway.signedOut, isTrue);
    });
  });

  group('GoogleSignInTokenProvider under AuthController (user-visible)', () {
    test('a live grant restores the session with NO user gesture', () async {
      final gateway = _FakeGateway.token('live');
      final controller = AuthController(GoogleSignInTokenProvider(gateway));
      addTearDown(controller.dispose);

      expect(await controller.restore(), isTrue);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.accessToken, 'live');
      expect(gateway.calls, [false], reason: 'silent restore, no gesture');
    });

    test(
      'Play Services absent → app starts signed out, no banner, no loop',
      () async {
        final gateway = _FakeGateway.unavailable('play services missing');
        final controller = AuthController(GoogleSignInTokenProvider(gateway));
        addTearDown(controller.dispose);

        // Degrades to local-only: restore fails quietly.
        expect(await controller.restore(), isFalse);
        expect(controller.isAuthenticated, isFalse, reason: 'local-only');
        expect(
          controller.needsReauth,
          isFalse,
          reason: 'no false "session expired" for someone never signed in',
        );
        // A single silent probe — the startup path does not spin retrying.
        expect(gateway.calls, [false]);
      },
    );

    test('the interactive gesture signs in through the provider', () async {
      final gateway = _FakeGateway.token('after-gesture');
      final controller = AuthController(GoogleSignInTokenProvider(gateway));
      addTearDown(controller.dispose);

      await controller.signIn();

      expect(controller.isAuthenticated, isTrue);
      expect(controller.accessToken, 'after-gesture');
      expect(gateway.calls, [true], reason: 'sign-in is interactive');
    });
  });

  group('GoogleSignInAuthGateway (live seam over GoogleSignInPlatform)', () {
    late _MockPlatform platform;

    setUp(() {
      platform = _MockPlatform();
      GoogleSignInPlatform.instance = platform;
    });

    test('silent restore returns the cached token and NEVER prompts or '
        'authenticates', () async {
      platform
        ..lightweightResult = _account()
        ..clientAuthorization = const ClientAuthorizationTokenData(
          accessToken: 'silent-token',
        );

      final result = await GoogleSignInAuthGateway().authorize(
        interactive: false,
      );

      expect(result.needsInteraction, isFalse);
      expect(result.accessToken, 'silent-token');
      expect(platform.authenticateCalls, 0, reason: 'no interactive auth');
      expect(
        platform.authorizationPrompts,
        [false],
        reason: 'silent authorization only — never escalates to a prompt',
      );
    });

    test('initialize() carries NO clientId and NO serverClientId', () async {
      platform
        ..lightweightResult = _account()
        ..clientAuthorization = const ClientAuthorizationTokenData(
          accessToken: 't',
        );

      await GoogleSignInAuthGateway().authorize(interactive: false);

      expect(platform.initCalls, 1);
      expect(platform.lastInit?.clientId, isNull);
      expect(platform.lastInit?.serverClientId, isNull);
    });

    test(
      'no cached session → needs interaction, without asking for tokens',
      () async {
        platform.lightweightResult = null;

        final result = await GoogleSignInAuthGateway().authorize(
          interactive: false,
        );

        expect(result.needsInteraction, isTrue);
        expect(
          platform.authorizationPrompts,
          isEmpty,
          reason: 'no session, so no token request at all',
        );
        expect(platform.authenticateCalls, 0);
      },
    );

    test(
      'scopes not grantable silently → needs interaction, still no prompt',
      () async {
        platform
          ..lightweightResult = _account()
          ..clientAuthorization = null; // grantable only with UI

        final result = await GoogleSignInAuthGateway().authorize(
          interactive: false,
        );

        expect(result.needsInteraction, isTrue);
        expect(
          platform.authorizationPrompts,
          [false],
          reason: 'asked silently, got null, did NOT escalate to a prompt',
        );
        expect(platform.authenticateCalls, 0);
      },
    );

    test(
      'interactive gesture authenticates then authorizes WITH a prompt',
      () async {
        platform
          ..authenticateResult = _account()
          ..clientAuthorization = const ClientAuthorizationTokenData(
            accessToken: 'gesture-token',
          );

        final result = await GoogleSignInAuthGateway().authorize(
          interactive: true,
        );

        expect(result.accessToken, 'gesture-token');
        expect(platform.authenticateCalls, 1);
        expect(platform.lightweightCalls, 0, reason: 'gesture is explicit');
        expect(
          platform.authorizationPrompts,
          [true],
          reason: 'the gesture path is the one allowed to prompt',
        );
      },
    );

    test('Play Services absent at init → GoogleAuthUnavailable', () async {
      platform.initException = _exception(
        GoogleSignInExceptionCode.providerConfigurationError,
      );

      await expectLater(
        GoogleSignInAuthGateway().authorize(interactive: false),
        throwsA(isA<GoogleAuthUnavailable>()),
      );
    });

    test('a transient GMS failure carries ONLY the classified code, never the '
        'raw Play-Services description (#187)', () async {
      // The plugin's `description` can carry account/config specifics and is
      // logged verbatim upstream (auth_controller.restore); it must NOT ride
      // the exception. Only the stable error code survives.
      const rawDescription =
          'GMS blew up for user@example.com — token nonsense';
      platform.initException = GoogleSignInException(
        code: GoogleSignInExceptionCode.providerConfigurationError,
        description: rawDescription,
      );

      await expectLater(
        GoogleSignInAuthGateway().authorize(interactive: false),
        throwsA(
          isA<GoogleAuthUnavailable>()
              .having(
                (e) => e.message,
                'message is the classified code',
                GoogleSignInExceptionCode.providerConfigurationError.name,
              )
              .having(
                (e) => e.message,
                'no raw description',
                isNot(contains('user@example.com')),
              ),
        ),
      );
    });

    test('a raw PlatformException translates to GoogleAuthUnavailable, '
        'carrying only the stable code (#187)', () async {
      // A method-channel failure is NOT a GoogleSignInException; before F9 it
      // escaped the gateway raw. Its `message` can carry account specifics and
      // is logged verbatim upstream, so only the stable `code` may survive.
      platform.initRawError = PlatformException(
        code: 'GMS_TRANSPORT',
        message: 'blew up for user@example.com',
      );

      await expectLater(
        GoogleSignInAuthGateway().authorize(interactive: false),
        throwsA(
          isA<GoogleAuthUnavailable>()
              .having(
                (e) => e.message,
                'stable code',
                contains('GMS_TRANSPORT'),
              )
              .having(
                (e) => e.message,
                'no raw message',
                isNot(contains('user@example.com')),
              ),
        ),
      );
    });

    test('a MissingPluginException translates to GoogleAuthUnavailable, '
        'not a raw escape', () async {
      platform.initRawError = MissingPluginException(
        'No implementation found for method init',
      );

      await expectLater(
        GoogleSignInAuthGateway().authorize(interactive: false),
        throwsA(isA<GoogleAuthUnavailable>()),
      );
    });

    test('a cancelled gesture is interaction-required, not a crash', () async {
      platform.authenticateException = _exception(
        GoogleSignInExceptionCode.canceled,
      );

      final result = await GoogleSignInAuthGateway().authorize(
        interactive: true,
      );

      expect(result.needsInteraction, isTrue);
    });

    test('sign-out delegates to the platform', () async {
      final gateway = GoogleSignInAuthGateway();
      // Initialize first so the gateway has a session to drop.
      platform
        ..lightweightResult = _account()
        ..clientAuthorization = const ClientAuthorizationTokenData(
          accessToken: 't',
        );
      await gateway.authorize(interactive: false);

      await gateway.signOut();
      expect(platform.signOutCalls, 1);
    });

    // Initialize the gateway (so signOut runs past its `!_initialized` guard),
    // then return the gateway ready to have signOut exercised.
    Future<GoogleSignInAuthGateway> initializedGateway() async {
      final gateway = GoogleSignInAuthGateway();
      platform
        ..lightweightResult = _account()
        ..clientAuthorization = const ClientAuthorizationTokenData(
          accessToken: 't',
        );
      await gateway.authorize(interactive: false);
      return gateway;
    }

    test(
      'a raw PlatformException from signOut translates to '
      'GoogleAuthUnavailable, carrying only the stable code (G6 / #204)',
      () async {
        final gateway = await initializedGateway();
        // A method-channel GMS failure on sign-out. Before G6 this escaped raw and
        // aborted logout before the local session cleared — Sign out a silent
        // no-op. Its `message` can carry account specifics (logged verbatim
        // upstream), so only the stable `code` may survive (#187).
        platform.signOutError = PlatformException(
          code: 'GMS_TRANSPORT',
          message: 'signOut blew up for user@example.com',
        );

        await expectLater(
          gateway.signOut(),
          throwsA(
            isA<GoogleAuthUnavailable>()
                .having(
                  (e) => e.message,
                  'stable code',
                  contains('GMS_TRANSPORT'),
                )
                .having(
                  (e) => e.message,
                  'no raw message',
                  isNot(contains('user@example.com')),
                ),
          ),
        );
      },
    );

    test('a GoogleSignInException from signOut translates to the classified '
        'code, never the raw description (G6 / #187)', () async {
      final gateway = await initializedGateway();
      platform.signOutError = GoogleSignInException(
        code: GoogleSignInExceptionCode.clientConfigurationError,
        description: 'blew up for user@example.com — nonsense',
      );

      await expectLater(
        gateway.signOut(),
        throwsA(
          isA<GoogleAuthUnavailable>()
              .having(
                (e) => e.message,
                'classified code',
                GoogleSignInExceptionCode.clientConfigurationError.name,
              )
              .having(
                (e) => e.message,
                'no raw description',
                isNot(contains('user@example.com')),
              ),
        ),
      );
    });

    test('a MissingPluginException from signOut translates to '
        'GoogleAuthUnavailable, not a raw escape (G6)', () async {
      final gateway = await initializedGateway();
      platform.signOutError = MissingPluginException(
        'No implementation found for method signOut',
      );

      await expectLater(
        gateway.signOut(),
        throwsA(isA<GoogleAuthUnavailable>()),
      );
    });
  });
}
