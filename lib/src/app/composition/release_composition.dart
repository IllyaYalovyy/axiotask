import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/clock.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../core/randomness.dart';
import '../../data/auth/authorization.dart';
import '../../data/diagnostics/local_diagnostic_exporter.dart';
import 'app_composition.dart';
import 'linux_read_transport.dart';

final class ReleaseComposition implements AppComposition {
  ReleaseComposition._({
    required this.clock,
    required this.randomness,
    required this.authorization,
    required this.diagnostics,
    required this.diagnosticHistory,
    required this.diagnosticExporter,
    required this.accountGuard,
    required this.linuxReadConfiguration,
    required this.linuxReadTransportDependencies,
  });

  factory ReleaseComposition.create({
    DiagnosticExportPort? diagnosticExporter,
    LinuxReadConfiguration linuxReadConfiguration =
        const LinuxReadConfiguration(clientId: '', clientSecret: ''),
    LinuxReadTransportDependencies? linuxReadTransportDependencies,
  }) {
    final history = InMemoryDiagnosticHistory(
      maxRecords: defaultReleaseDiagnosticRecordLimit,
    );
    return ReleaseComposition._fromHistory(
      history: history,
      diagnosticExporter:
          diagnosticExporter ?? const _UnavailableDiagnosticExporter(),
      linuxReadConfiguration: linuxReadConfiguration,
      linuxReadTransportDependencies: linuxReadTransportDependencies,
    );
  }

  factory ReleaseComposition._fromHistory({
    required DiagnosticHistory history,
    required DiagnosticExportPort diagnosticExporter,
    required LinuxReadConfiguration linuxReadConfiguration,
    LinuxReadTransportDependencies? linuxReadTransportDependencies,
  }) {
    return ReleaseComposition._(
      clock: SystemClock(),
      randomness: SecureRandomSource(),
      authorization: const UnavailableAuthorization(),
      diagnostics: ProductionDiagnosticSink(history),
      diagnosticHistory: history,
      diagnosticExporter: diagnosticExporter,
      accountGuard: const NormalAccountGuard(),
      linuxReadConfiguration: linuxReadConfiguration,
      linuxReadTransportDependencies: linuxReadTransportDependencies,
    );
  }

  static Future<ReleaseComposition> open({
    File? diagnosticFile,
    LinuxReadConfiguration linuxReadConfiguration =
        const LinuxReadConfiguration(clientId: '', clientSecret: ''),
    LinuxReadTransportDependencies? linuxReadTransportDependencies,
  }) async {
    final file = diagnosticFile ?? await _resolveDiagnosticFile(_boundary);
    final history = PersistentDiagnosticHistory.open(
      file,
      product: DiagnosticProduct.releaseSafe,
      maxRecords: defaultReleaseDiagnosticRecordLimit,
    );
    return ReleaseComposition._fromHistory(
      history: history,
      diagnosticExporter: LocalDiagnosticExporter(
        Directory(
          '${file.parent.path}${Platform.pathSeparator}'
          'axiotask-diagnostic-exports',
        ),
        product: DiagnosticProduct.releaseSafe,
      ),
      linuxReadConfiguration: linuxReadConfiguration,
      linuxReadTransportDependencies: linuxReadTransportDependencies,
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

  final DiagnosticExportPort diagnosticExporter;

  @override
  final NormalAccountGuard accountGuard;

  final LinuxReadConfiguration linuxReadConfiguration;
  final LinuxReadTransportDependencies? linuxReadTransportDependencies;

  @override
  AccountSubject? get configuredAccountSubject => null;

  @override
  Future<ReadSliceTransport> createReadTransport(AccountSubject? subject) =>
      createLinuxReadTransport(
        composition: this,
        configuredSubject: subject,
        configuration: linuxReadConfiguration,
        dependencies: linuxReadTransportDependencies,
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

final class _UnavailableDiagnosticExporter implements DiagnosticExportPort {
  const _UnavailableDiagnosticExporter();

  @override
  Future<DiagnosticExportReceipt> export(List<DiagnosticRecord> records) =>
      Future<DiagnosticExportReceipt>.error(
        StateError('Local diagnostic export is unavailable.'),
      );
}

Future<File> _resolveDiagnosticFile(CompositionBoundary boundary) async {
  final directory = await getApplicationSupportDirectory();
  return File(
    '${directory.path}${Platform.pathSeparator}'
    '${boundary.storage.diagnosticsFileName}',
  );
}
