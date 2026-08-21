import '../../core/clock.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../core/outcome.dart';
import '../../core/randomness.dart';
import '../../data/auth/authorization.dart';
import 'app_composition.dart';
import 'synthetic_read_transport.dart';

final class TestComposition implements AppComposition {
  TestComposition._({
    required this.clock,
    required this.randomness,
    required this.authorization,
    required this.diagnostics,
    required this.diagnosticHistory,
    required this.accountGuard,
    required this.boundary,
  });

  factory TestComposition.create({required String instanceId}) {
    final normalizedId = _normalizeInstanceId(instanceId);
    final subject = AccountSubject('synthetic-$normalizedId');
    final history = InMemoryDiagnosticHistory();
    return TestComposition._(
      clock: ManualClock(DateTime.utc(2026, 1, 1, 12)),
      randomness: SequenceRandomSource(
        List<int>.generate(256, (index) => index),
      ),
      authorization: SyntheticAuthorization(subject),
      diagnostics: ProductionDiagnosticSink(history),
      diagnosticHistory: history,
      accountGuard: DedicatedAccountGuard(subject),
      boundary: CompositionBoundary(
        profile: CompositionProfile.syntheticTest,
        applicationIdentifier: 'dev.axiotask.axiotask.test.$normalizedId',
        storage: StorageBoundary(
          databaseName: 'axiotask-test-$normalizedId.sqlite',
          diagnosticsFileName:
              'axiotask-test-$normalizedId-diagnostics-safe.json',
          preferencesNamespace:
              'dev.axiotask.axiotask.test.$normalizedId.preferences',
          secureStorageNamespace:
              'dev.axiotask.axiotask.test.$normalizedId.credentials',
          diagnosticsNamespace:
              'dev.axiotask.axiotask.test.$normalizedId.diagnostics',
        ),
        oauthConfiguration: OAuthConfigurationBoundary(
          name: 'synthetic-$normalizedId',
          allowsRealGoogle: false,
        ),
      ),
    );
  }

  @override
  final ManualClock clock;

  @override
  MonotonicScheduler get scheduler => clock;

  @override
  final SequenceRandomSource randomness;

  @override
  final SyntheticAuthorization authorization;

  @override
  final ProductionDiagnosticSink diagnostics;

  final InMemoryDiagnosticHistory diagnosticHistory;

  @override
  final DedicatedAccountGuard accountGuard;

  @override
  AccountSubject get configuredAccountSubject => authorization.subject;

  @override
  Future<ReadSliceTransport> createReadTransport(
    AccountSubject? subject,
  ) async {
    final selectedSubject = subject ?? authorization.subject;
    final access = accountGuard.verify(selectedSubject);
    if (access is! Success<void>) {
      throw StateError(
        'Synthetic account guard rejected its configured subject.',
      );
    }
    return createSyntheticReadTransport(selectedSubject);
  }

  @override
  final CompositionBoundary boundary;

  static String _normalizeInstanceId(String instanceId) {
    final normalized = instanceId.trim().toLowerCase();
    if (normalized.isEmpty ||
        !RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(normalized)) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'must contain only lowercase letters, digits, and hyphens',
      );
    }
    return normalized;
  }
}
