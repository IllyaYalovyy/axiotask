import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth2;

import '../../../core/clock.dart';
import '../../../core/diagnostics/diagnostics.dart';
import '../../../core/outcome.dart';
import '../../../core/randomness.dart';
import 'browser_flow.dart';
import 'dpop.dart';
import 'linux_authorization.dart';
import 'secure_credentials.dart';

final class LinuxAuthProbeConfiguration {
  LinuxAuthProbeConfiguration({
    required this.clientId,
    required this.clientSecret,
    required this.subjectFile,
    required this.instanceName,
  }) {
    if (!clientId.endsWith('.apps.googleusercontent.com') ||
        clientSecret.isEmpty ||
        !RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(instanceName)) {
      throw ArgumentError(
        'Linux authorization probe configuration is invalid.',
      );
    }
  }

  final String clientId;
  final String clientSecret;
  final File subjectFile;
  final String instanceName;
}

final class LinuxAuthProbeResult {
  const LinuxAuthProbeResult();

  Map<String, Object> toRecord() => const <String, Object>{
    'status': 'passed',
    'pkceExchangeVerified': true,
    'dpopNonceVerified': true,
    'refreshVerified': true,
    'missingKeyRejected': true,
    'wrongKeyRejected': true,
    'restartRestoreVerified': true,
    'subjectGuardVerified': true,
    'taskListsCallVerified': true,
    'credentialCleanupVerified': true,
  };
}

final class LinuxAuthProbeException implements Exception {
  LinuxAuthProbeException({
    required Object primary,
    required Iterable<DiagnosticRecord> diagnostics,
    Object? cleanup,
  }) : _primary = const CredentialRedactor().redact(primary),
       _cleanup = cleanup == null
           ? null
           : const CredentialRedactor().redact(cleanup),
       _diagnostics = List<DiagnosticRecord>.unmodifiable(diagnostics);

  final String _primary;
  final String? _cleanup;
  final List<DiagnosticRecord> _diagnostics;

  @override
  String toString() {
    final buffer = StringBuffer('Linux authorization probe failed: $_primary');
    if (_cleanup case final cleanup?) {
      buffer.write('\nCleanup also failed: $cleanup');
    }
    if (_diagnostics.isNotEmpty) {
      buffer.write('\nDevelopment diagnostics:');
      for (final record in _diagnostics) {
        buffer.write('\n- ${record.renderedText}');
      }
    }
    return buffer.toString();
  }
}

Future<LinuxAuthProbeResult> runLinuxAuthProbe(
  LinuxAuthProbeConfiguration configuration,
) async {
  final history = InMemoryDiagnosticHistory();
  final diagnostics = SensitiveDevelopmentDiagnosticSink(history);
  final credentialStore = LinuxSecureCredentialStore(
    namespace: 'dev.axiotask.axiotask.probe.s05.${configuration.instanceName}',
    storage: FlutterSecureStorageValueStore(),
    diagnostics: diagnostics,
  );
  final subjectStore = FilePinnedSubjectStore(configuration.subjectFile);
  final authConfig = LinuxAuthorizationConfig.google(
    clientId: configuration.clientId,
    clientSecret: configuration.clientSecret,
  );

  Object? primaryError;
  StackTrace? primaryStack;
  LinuxAuthProbeResult? result;
  try {
    await _expectVoid(credentialStore.delete(), 'initial credential cleanup');
    result = await _runProbeOperations(
      config: authConfig,
      credentialStore: credentialStore,
      subjectStore: subjectStore,
      diagnostics: diagnostics,
    );
  } catch (error, stackTrace) {
    primaryError = error;
    primaryStack = stackTrace;
  }

  Object? cleanupError;
  try {
    await _expectVoid(credentialStore.delete(), 'final credential cleanup');
    final deleted = await credentialStore.read();
    if (deleted is! Success<CredentialBundle?> || deleted.value != null) {
      throw StateError('Final credential cleanup could not be verified.');
    }
  } catch (error) {
    cleanupError = error;
  }

  if (primaryError != null) {
    Error.throwWithStackTrace(
      LinuxAuthProbeException(
        primary: primaryError,
        cleanup: cleanupError,
        diagnostics: history.records,
      ),
      primaryStack!,
    );
  }
  if (cleanupError != null) {
    throw LinuxAuthProbeException(
      primary: cleanupError,
      diagnostics: history.records,
    );
  }
  return result!;
}

Future<LinuxAuthProbeResult> _runProbeOperations({
  required LinuxAuthorizationConfig config,
  required CredentialStore credentialStore,
  required PinnedSubjectStore subjectStore,
  required DiagnosticSink diagnostics,
}) async {
  final first = _createAdapter(
    config: config,
    credentials: credentialStore,
    subjects: subjectStore,
    diagnostics: diagnostics,
  );
  final firstSession = await _expectSession(first.connect(), 'PKCE exchange');
  if (!first.observedDpopNonce) {
    throw StateError('PKCE exchange did not return a DPoP nonce.');
  }
  await _expectTaskLists(first.probeTaskLists(), 'initial tasklists.list');
  first.close();

  final restored = _createAdapter(
    config: config,
    credentials: credentialStore,
    subjects: subjectStore,
    diagnostics: diagnostics,
  );
  final restoredSession = await _expectSession(
    restored.restore(),
    'restart restore',
  );
  if (restoredSession.subject != firstSession.subject ||
      !restored.observedDpopNonce) {
    throw StateError('Restart restore did not preserve bound identity.');
  }
  await _expectTaskLists(restored.probeTaskLists(), 'restored tasklists.list');

  final bundle = await _expectBundle(credentialStore.read());
  await _expectRejected(
    _refreshWithoutDpop(config, bundle.refreshToken),
    'missing DPoP key',
  );
  await _expectRejected(
    _refreshWithWrongDpop(config, bundle.refreshToken),
    'wrong DPoP key',
  );
  await _expectSession(restored.refresh(), 'refresh after rejection probes');
  restored.close();
  return const LinuxAuthProbeResult();
}

LinuxAuthorization _createAdapter({
  required LinuxAuthorizationConfig config,
  required CredentialStore credentials,
  required PinnedSubjectStore subjects,
  required DiagnosticSink diagnostics,
}) => LinuxAuthorization(
  config: config,
  browserFlow: LinuxBrowserFlow(
    callbackFactory: const HttpLoopbackCallbackFactory(),
    browserLauncher: const SystemBrowserLauncher(),
    randomness: SecureRandomSource(),
    diagnostics: diagnostics,
  ),
  credentialStore: credentials,
  subjectStore: subjects,
  identityVerifier: GoogleIdTokenVerifier(clock: SystemClock()),
  httpClientFactory: http.Client.new,
  clock: SystemClock(),
  randomness: SecureRandomSource(),
  diagnostics: diagnostics,
);

Future<_ProbeRejection> _refreshWithoutDpop(
  LinuxAuthorizationConfig config,
  String refreshToken,
) async {
  final client = http.Client();
  try {
    final response = await client.post(
      config.tokenEndpoint,
      body: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': config.clientId,
        'client_secret': config.clientSecret,
      },
    );
    return _probeRejection(response);
  } finally {
    client.close();
  }
}

Future<_ProbeRejection> _refreshWithWrongDpop(
  LinuxAuthorizationConfig config,
  String refreshToken,
) async {
  final tokenClient = DpopTokenClient(
    inner: http.Client(),
    tokenEndpoint: config.tokenEndpoint,
    proofs: DpopProofFactory(
      key: DpopKeyPair.generate(),
      clock: SystemClock(),
      randomness: SecureRandomSource(),
    ),
  );
  final client = oauth2.Client(
    oauth2.Credentials(
      'expired-access-token-placeholder',
      refreshToken: refreshToken,
      tokenEndpoint: config.tokenEndpoint,
      scopes: const <String>[googleOpenIdScope, googleTasksScope],
      expiration: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    ),
    identifier: config.clientId,
    secret: config.clientSecret,
    basicAuth: false,
    httpClient: tokenClient,
  );
  try {
    await client.refreshCredentials();
    return const _ProbeRejection(statusCode: 200, errorCode: 'accepted');
  } on oauth2.AuthorizationException catch (error) {
    return _ProbeRejection(statusCode: 400, errorCode: error.error);
  } finally {
    client.close();
  }
}

_ProbeRejection _probeRejection(http.Response response) {
  String? errorCode;
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic> && decoded['error'] is String) {
      errorCode = decoded['error'] as String;
    }
  } on FormatException {
    // The safe status remains enough to reject the probe without logging body.
  }
  return _ProbeRejection(
    statusCode: response.statusCode,
    errorCode: errorCode ?? 'unstructured',
  );
}

final class _ProbeRejection {
  const _ProbeRejection({required this.statusCode, required this.errorCode});

  final int statusCode;
  final String errorCode;
}

Future<void> _expectRejected(
  Future<_ProbeRejection> operation,
  String phase,
) async {
  final result = await operation;
  if (result.statusCode == 400 &&
      <String>{
        'invalid_dpop_proof',
        'invalid_grant',
      }.contains(result.errorCode)) {
    return;
  }
  throw StateError(
    '$phase was not rejected by the token endpoint '
    '(status=${result.statusCode}, error=${result.errorCode}).',
  );
}

Future<LinuxAuthorizedSession> _expectSession(
  Future<Outcome<LinuxAuthorizedSession>> operation,
  String phase,
) async {
  return switch (await operation) {
    Success<LinuxAuthorizedSession>(:final value) => value,
    Failed<LinuxAuthorizedSession>(:final failure) => throw StateError(
      '$phase failed: ${failure.code}',
    ),
  };
}

Future<void> _expectTaskLists(
  Future<Outcome<int>> operation,
  String phase,
) async {
  switch (await operation) {
    case Success<int>():
      return;
    case Failed<int>(:final failure):
      throw StateError('$phase failed: ${failure.code}');
  }
}

Future<CredentialBundle> _expectBundle(
  Future<Outcome<CredentialBundle?>> operation,
) async {
  return switch (await operation) {
    Success<CredentialBundle?>(value: final value?) => value,
    Success<CredentialBundle?>(value: null) => throw StateError(
      'Saved credential bundle is absent.',
    ),
    Failed<CredentialBundle?>(:final failure) => throw StateError(
      'Credential read failed: ${failure.code}',
    ),
  };
}

Future<void> _expectVoid(Future<Outcome<void>> operation, String phase) async {
  switch (await operation) {
    case Success<void>():
      return;
    case Failed<void>(:final failure):
      throw StateError('$phase failed: ${failure.code}');
  }
}
