import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/clock.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../core/randomness.dart';
import '../../data/auth/authorization.dart';
import '../../data/diagnostics/local_diagnostic_exporter.dart';
import 'app_composition.dart';
import 'linux_read_transport.dart';

final class DevelopmentComposition implements AppComposition {
  DevelopmentComposition._({
    required this.clock,
    required this.randomness,
    required this.authorization,
    required this.diagnostics,
    required this.diagnosticHistory,
    required this.diagnosticExporter,
    required this.accountGuard,
    required this.configuredAccountSubject,
    required this.linuxReadConfiguration,
  });

  factory DevelopmentComposition.create({
    AccountSubject? expectedDedicatedSubject,
    DiagnosticExportPort? diagnosticExporter,
    LinuxReadConfiguration linuxReadConfiguration =
        const LinuxReadConfiguration(clientId: '', clientSecret: ''),
  }) {
    final history = InMemoryDiagnosticHistory(
      maxRecords: defaultDevelopmentDiagnosticRecordLimit,
    );
    return DevelopmentComposition._fromHistory(
      history: history,
      diagnosticExporter:
          diagnosticExporter ?? const _UnavailableDiagnosticExporter(),
      expectedDedicatedSubject: expectedDedicatedSubject,
      linuxReadConfiguration: linuxReadConfiguration,
    );
  }

  factory DevelopmentComposition._fromHistory({
    required DiagnosticHistory history,
    required DiagnosticExportPort diagnosticExporter,
    required AccountSubject? expectedDedicatedSubject,
    required LinuxReadConfiguration linuxReadConfiguration,
  }) {
    return DevelopmentComposition._(
      clock: SystemClock(),
      randomness: SecureRandomSource(),
      authorization: const UnavailableAuthorization(),
      diagnostics: SensitiveDevelopmentDiagnosticSink(history),
      diagnosticHistory: history,
      diagnosticExporter: diagnosticExporter,
      accountGuard: DedicatedAccountGuard(expectedDedicatedSubject),
      configuredAccountSubject: expectedDedicatedSubject,
      linuxReadConfiguration: linuxReadConfiguration,
    );
  }

  static Future<DevelopmentComposition> open({
    File? diagnosticFile,
    AccountSubject? expectedDedicatedSubject,
    LinuxReadConfiguration linuxReadConfiguration =
        const LinuxReadConfiguration(clientId: '', clientSecret: ''),
  }) async {
    final file = diagnosticFile ?? await _resolveDiagnosticFile(_boundary);
    final history = PersistentDiagnosticHistory.open(
      file,
      product: DiagnosticProduct.sensitiveDevelopment,
      maxRecords: defaultDevelopmentDiagnosticRecordLimit,
    );
    return DevelopmentComposition._fromHistory(
      history: history,
      diagnosticExporter: LocalDiagnosticExporter(
        Directory(
          '${file.parent.path}${Platform.pathSeparator}'
          'axiotask-development-diagnostic-exports',
        ),
        product: DiagnosticProduct.sensitiveDevelopment,
      ),
      expectedDedicatedSubject: expectedDedicatedSubject,
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
  final SensitiveDevelopmentDiagnosticSink diagnostics;

  final DiagnosticHistory diagnosticHistory;

  final DiagnosticExportPort diagnosticExporter;

  @override
  final DedicatedAccountGuard accountGuard;

  @override
  final AccountSubject? configuredAccountSubject;

  final LinuxReadConfiguration linuxReadConfiguration;

  @override
  Future<ReadSliceTransport> createReadTransport(AccountSubject? subject) =>
      createLinuxReadTransport(
        composition: this,
        configuredSubject: subject,
        configuration: linuxReadConfiguration,
      );

  @override
  CompositionBoundary get boundary => _boundary;

  static const CompositionBoundary _boundary = CompositionBoundary(
    profile: CompositionProfile.development,
    applicationIdentifier: 'dev.axiotask.axiotask.development',
    storage: StorageBoundary(
      databaseName: 'axiotask-development.sqlite',
      diagnosticsFileName: 'axiotask-development-diagnostics-sensitive.json',
      preferencesNamespace: 'dev.axiotask.axiotask.development.preferences',
      secureStorageNamespace: 'dev.axiotask.axiotask.development.credentials',
      diagnosticsNamespace:
          'dev.axiotask.axiotask.development.diagnostics.sensitive',
    ),
    oauthConfiguration: OAuthConfigurationBoundary(
      name: 'development-dedicated-account',
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
