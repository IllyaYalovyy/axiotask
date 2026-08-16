import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/clock.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../core/randomness.dart';
import '../../data/auth/authorization.dart';
import 'app_composition.dart';
import 'linux_read_transport.dart';

final class ReleaseComposition implements AppComposition {
  ReleaseComposition._({
    required this.clock,
    required this.randomness,
    required this.authorization,
    required this.diagnostics,
    required this.diagnosticHistory,
    required this.accountGuard,
    required this.linuxReadConfiguration,
  });

  factory ReleaseComposition.create({
    LinuxReadConfiguration linuxReadConfiguration =
        const LinuxReadConfiguration(clientId: '', clientSecret: ''),
  }) {
    final history = InMemoryDiagnosticHistory(
      maxRecords: defaultReleaseDiagnosticRecordLimit,
    );
    return ReleaseComposition._fromHistory(
      history: history,
      linuxReadConfiguration: linuxReadConfiguration,
    );
  }

  factory ReleaseComposition._fromHistory({
    required DiagnosticHistory history,
    required LinuxReadConfiguration linuxReadConfiguration,
  }) {
    return ReleaseComposition._(
      clock: SystemClock(),
      randomness: SecureRandomSource(),
      authorization: const UnavailableAuthorization(),
      diagnostics: ProductionDiagnosticSink(history),
      diagnosticHistory: history,
      accountGuard: const NormalAccountGuard(),
      linuxReadConfiguration: linuxReadConfiguration,
    );
  }

  static Future<ReleaseComposition> open({
    File? diagnosticFile,
    LinuxReadConfiguration linuxReadConfiguration =
        const LinuxReadConfiguration(clientId: '', clientSecret: ''),
  }) async {
    final file = diagnosticFile ?? await _resolveDiagnosticFile(_boundary);
    final history = PersistentDiagnosticHistory.open(
      file,
      product: DiagnosticProduct.releaseSafe,
      maxRecords: defaultReleaseDiagnosticRecordLimit,
    );
    return ReleaseComposition._fromHistory(
      history: history,
      linuxReadConfiguration: linuxReadConfiguration,
    );
  }

  @override
  final SystemClock clock;

  @override
  MonotonicScheduler get scheduler => clock;

  @override
  final RandomSource randomness;

  @override
  final AuthorizationPort authorization;

  @override
  final ProductionDiagnosticSink diagnostics;

  final DiagnosticHistory diagnosticHistory;

  @override
  final NormalAccountGuard accountGuard;

  final LinuxReadConfiguration linuxReadConfiguration;

  @override
  AccountSubject? get configuredAccountSubject => null;

  @override
  Future<ReadSliceTransport> createReadTransport(AccountSubject subject) =>
      createLinuxReadTransport(
        composition: this,
        configuredSubject: subject,
        configuration: linuxReadConfiguration,
      );

  @override
  CompositionBoundary get boundary => _boundary;

  static const CompositionBoundary _boundary = CompositionBoundary(
    profile: CompositionProfile.release,
    applicationIdentifier: 'dev.axiotask.axiotask',
    storage: StorageBoundary(
      databaseName: 'axiotask.sqlite',
      diagnosticsFileName: 'axiotask-diagnostics-safe.json',
      preferencesNamespace: 'dev.axiotask.axiotask.preferences',
      secureStorageNamespace: 'dev.axiotask.axiotask.credentials',
      diagnosticsNamespace: 'dev.axiotask.axiotask.diagnostics.safe',
    ),
    oauthConfiguration: OAuthConfigurationBoundary(
      name: 'production',
      allowsRealGoogle: true,
    ),
  );
}

Future<File> _resolveDiagnosticFile(CompositionBoundary boundary) async {
  final directory = await getApplicationSupportDirectory();
  return File(
    '${directory.path}${Platform.pathSeparator}'
    '${boundary.storage.diagnosticsFileName}',
  );
}
