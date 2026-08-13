import '../../../core/diagnostics/diagnostics.dart';
import '../../../core/outcome.dart';
import 'secure_credentials.dart';

const CredentialBundle _initialProbeBundle = CredentialBundle(
  refreshToken: 'synthetic-s04-refresh-initial',
  dpopPrivateKeyJwk: 'synthetic-s04-dpop-key-initial',
);
const CredentialBundle _replacementProbeBundle = CredentialBundle(
  refreshToken: 'synthetic-s04-refresh-replacement',
  dpopPrivateKeyJwk: 'synthetic-s04-dpop-key-replacement',
);

final class LinuxSecureStorageProbeResult {
  const LinuxSecureStorageProbeResult();

  Map<String, Object> toRecord() => const <String, Object>{
    'status': 'passed',
    'bundleSchemaVersion': 1,
    'operationsVerified': 6,
    'dedicatedNamespace': true,
    'cleanupVerified': true,
  };
}

Future<LinuxSecureStorageProbeResult> runLinuxSecureStorageProbe(
  String instanceName,
) async {
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(instanceName)) {
    throw ArgumentError.value(
      instanceName,
      'instanceName',
      'must be a lowercase isolated probe name',
    );
  }
  final store = LinuxSecureCredentialStore(
    namespace: 'dev.axiotask.axiotask.probe.s04.$instanceName',
    storage: FlutterSecureStorageValueStore(),
    diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
  );

  try {
    await _expectSuccess(store.delete(), 'initial cleanup');
    await _expectSuccess(store.replace(_initialProbeBundle), 'initial write');
    await _expectBundle(store.read(), _initialProbeBundle, 'initial read');
    await _expectSuccess(
      store.replace(_replacementProbeBundle),
      'replacement write',
    );
    await _expectBundle(
      store.read(),
      _replacementProbeBundle,
      'replacement read',
    );
    await _expectSuccess(store.delete(), 'delete');
    await _expectBundle(store.read(), null, 'deleted read');
    return const LinuxSecureStorageProbeResult();
  } finally {
    await _expectSuccess(store.delete(), 'final cleanup');
  }
}

Future<void> _expectSuccess(
  Future<Outcome<void>> operation,
  String phase,
) async {
  switch (await operation) {
    case Success<void>():
      return;
    case Failed<void>(:final failure):
      throw StateError('$phase failed: ${failure.code}');
  }
}

Future<void> _expectBundle(
  Future<Outcome<CredentialBundle?>> operation,
  CredentialBundle? expected,
  String phase,
) async {
  switch (await operation) {
    case Success<CredentialBundle?>(:final value) when value == expected:
      return;
    case Success<CredentialBundle?>():
      throw StateError('$phase returned an unexpected credential state.');
    case Failed<CredentialBundle?>(:final failure):
      throw StateError('$phase failed: ${failure.code}');
  }
}
