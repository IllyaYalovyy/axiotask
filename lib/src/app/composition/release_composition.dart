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
    final history = InMemoryDiagnosticHistory();
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

  @override
  final Clock clock;

  @override
  final RandomSource randomness;

  @override
  final AuthorizationPort authorization;

  @override
  final ProductionDiagnosticSink diagnostics;

  final InMemoryDiagnosticHistory diagnosticHistory;

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
