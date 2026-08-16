import 'dart:async';

import '../../core/clock.dart';
import '../../core/diagnostics/diagnostics.dart';
import '../../core/failure.dart';
import '../../core/outcome.dart';
import '../../core/randomness.dart';
import '../../data/auth/authorization.dart';
import '../../data/google_tasks/service.dart';

enum CompositionProfile { release, development, syntheticTest }

final class StorageBoundary {
  const StorageBoundary({
    required this.databaseName,
    required this.diagnosticsFileName,
    required this.preferencesNamespace,
    required this.secureStorageNamespace,
    required this.diagnosticsNamespace,
  });

  final String databaseName;
  final String diagnosticsFileName;
  final String preferencesNamespace;
  final String secureStorageNamespace;
  final String diagnosticsNamespace;

  Iterable<String> get namespaces => <String>[
    databaseName,
    diagnosticsFileName,
    preferencesNamespace,
    secureStorageNamespace,
    diagnosticsNamespace,
  ];
}

final class OAuthConfigurationBoundary {
  const OAuthConfigurationBoundary({
    required this.name,
    required this.allowsRealGoogle,
  });

  final String name;
  final bool allowsRealGoogle;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OAuthConfigurationBoundary &&
          name == other.name &&
          allowsRealGoogle == other.allowsRealGoogle;

  @override
  int get hashCode => Object.hash(name, allowsRealGoogle);
}

final class CompositionBoundary {
  const CompositionBoundary({
    required this.profile,
    required this.applicationIdentifier,
    required this.storage,
    required this.oauthConfiguration,
  });

  final CompositionProfile profile;
  final String applicationIdentifier;
  final StorageBoundary storage;
  final OAuthConfigurationBoundary oauthConfiguration;

  Outcome<void> verifyIsolatedFrom(CompositionBoundary other) {
    final overlaps = <String>[];
    if (applicationIdentifier == other.applicationIdentifier) {
      overlaps.add('application identifier');
    }
    if (oauthConfiguration == other.oauthConfiguration) {
      overlaps.add('OAuth configuration');
    }
    final otherNamespaces = other.storage.namespaces.toSet();
    if (storage.namespaces.any(otherNamespaces.contains)) {
      overlaps.add('local storage namespace');
    }
    if (overlaps.isEmpty) {
      return const Outcome<void>.success(null);
    }
    return Outcome<void>.failure(
      Failure(
        code: 'composition.isolation_overlap',
        category: FailureCategory.configuration,
        operation: FailureOperation.initialize,
        retry: RetryClassification.permanent,
        impact: 'The isolated application instance cannot start safely.',
        action: FailureAction.reviewConfiguration,
        safeSummary: 'Composition boundaries overlap: ${overlaps.join(', ')}.',
      ),
    );
  }
}

abstract interface class AppComposition {
  Clock get clock;

  MonotonicScheduler get scheduler;

  RandomSource get randomness;

  AuthorizationPort get authorization;

  DiagnosticSink get diagnostics;

  AccountGuard get accountGuard;

  CompositionBoundary get boundary;

  /// A synthetic/development subject may bootstrap its isolated partition.
  /// Production discovers only an already configured account from SQLite.
  AccountSubject? get configuredAccountSubject;

  Future<ReadSliceTransport> createReadTransport(AccountSubject subject);
}

final class ReadSliceTransport {
  const ReadSliceTransport({
    required this.authorization,
    required this.googleTasks,
    this.closeTransport,
  });

  final AuthorizationPort authorization;
  final GoogleTasksService googleTasks;
  final FutureOr<void> Function()? closeTransport;

  Future<void> close() async {
    googleTasks.close();
    await closeTransport?.call();
  }
}
