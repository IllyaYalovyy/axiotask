import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/linux/secure_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const firstBundle = CredentialBundle(
    refreshToken: 'synthetic-refresh-token-one',
    dpopPrivateKeyJwk: 'synthetic-private-jwk-one',
  );
  const replacementBundle = CredentialBundle(
    refreshToken: 'synthetic-refresh-token-two',
    dpopPrivateKeyJwk: 'synthetic-private-jwk-two',
  );

  group('LinuxSecureCredentialStore', () {
    test('reports an absent bundle without creating storage', () async {
      final values = <String, String>{};
      final store = _store(values: values, namespace: 'synthetic.absent');

      final result = await store.read();

      expect(result, const Success<CredentialBundle?>(null));
      expect(values, isEmpty);
    });

    test('stores and retrieves both credentials as one value', () async {
      final values = <String, String>{};
      final store = _store(values: values, namespace: 'synthetic.roundtrip');

      expect(await store.replace(firstBundle), const Success<void>(null));
      expect(await store.read(), const Success<CredentialBundle?>(firstBundle));
      expect(values, hasLength(1));
      expect(values.values.single, contains('"schemaVersion":1'));
      expect(values.values.single, contains('"refreshToken"'));
      expect(values.values.single, contains('"dpopPrivateKeyJwk"'));
    });

    test('maps missing, locked, and denied Secret Service failures', () async {
      for (final expectation
          in <(SecureValueStoreFailureKind, String, FailureAction)>[
            (
              SecureValueStoreFailureKind.unavailable,
              'auth.secure_store_unavailable',
              FailureAction.reviewConfiguration,
            ),
            (
              SecureValueStoreFailureKind.locked,
              'auth.secure_store_locked',
              FailureAction.retry,
            ),
            (
              SecureValueStoreFailureKind.denied,
              'auth.secure_store_denied',
              FailureAction.reviewConfiguration,
            ),
          ]) {
        final driver = FakeSecureValueStore()
          ..readFailure = SecureValueStoreException(expectation.$1);
        final store = LinuxSecureCredentialStore(
          namespace: 'synthetic.failures',
          storage: driver,
          diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        );

        final result = await store.read();

        expect(result, isA<Failed<CredentialBundle?>>());
        final failure = (result as Failed<CredentialBundle?>).failure;
        expect(failure.code, expectation.$2);
        expect(failure.action, expectation.$3);
        expect(failure.category, FailureCategory.authorization);
      }
    });

    test('failed replacement preserves the previous complete bundle', () async {
      final driver = FakeSecureValueStore();
      final store = LinuxSecureCredentialStore(
        namespace: 'synthetic.replace-failure',
        storage: driver,
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
      );
      expect(await store.replace(firstBundle), const Success<void>(null));
      driver.writeFailure = const SecureValueStoreException(
        SecureValueStoreFailureKind.denied,
      );

      final result = await store.replace(replacementBundle);

      expect(result, isA<Failed<void>>());
      expect(await store.read(), const Success<CredentialBundle?>(firstBundle));
    });

    test(
      'commit-then-fail replacement succeeds only after exact read-back',
      () async {
        final driver = FakeSecureValueStore();
        final store = LinuxSecureCredentialStore(
          namespace: 'synthetic.ambiguous-replace',
          storage: driver,
          diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        );
        expect(await store.replace(firstBundle), const Success<void>(null));
        driver
          ..writeFailure = const SecureValueStoreException(
            SecureValueStoreFailureKind.unknown,
          )
          ..commitWriteBeforeFailure = true;

        expect(
          await store.replace(replacementBundle),
          const Success<void>(null),
        );
        expect(
          await store.read(),
          const Success<CredentialBundle?>(replacementBundle),
        );
      },
    );

    test(
      'partial replacement is never decoded as a credential bundle',
      () async {
        final driver = FakeSecureValueStore();
        final store = LinuxSecureCredentialStore(
          namespace: 'synthetic.partial-replace',
          storage: driver,
          diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        );
        expect(await store.replace(firstBundle), const Success<void>(null));
        driver
          ..writeFailure = const SecureValueStoreException(
            SecureValueStoreFailureKind.unknown,
          )
          ..replacementOnFailure = '{"schemaVersion":1,"refreshToken":"only"}';

        final replaceResult = await store.replace(replacementBundle);
        final readResult = await store.read();

        expect(replaceResult, isA<Failed<void>>());
        expect(readResult, isA<Failed<CredentialBundle?>>());
        expect(
          (readResult as Failed<CredentialBundle?>).failure.code,
          'auth.secure_store_malformed_bundle',
        );
      },
    );

    test('rejects malformed and unsupported bundle representations', () async {
      for (final malformed in <String>[
        'not-json',
        '{}',
        '{"schemaVersion":2,"refreshToken":"r","dpopPrivateKeyJwk":"k"}',
        '{"schemaVersion":1,"refreshToken":"","dpopPrivateKeyJwk":"k"}',
        '{"schemaVersion":1,"refreshToken":"r","dpopPrivateKeyJwk":"k","extra":true}',
      ]) {
        final driver = FakeSecureValueStore()
          ..values[credentialBundleStorageKey('synthetic.malformed')] =
              malformed;
        final store = LinuxSecureCredentialStore(
          namespace: 'synthetic.malformed',
          storage: driver,
          diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        );

        final result = await store.read();

        expect(result, isA<Failed<CredentialBundle?>>());
        final failure = (result as Failed<CredentialBundle?>).failure;
        expect(failure.code, 'auth.secure_store_malformed_bundle');
        expect(failure.action, FailureAction.connect);
        expect(
          driver.values,
          isNotEmpty,
          reason: 'recovery must not silently delete',
        );
      }
    });

    test('isolates read, replacement, and deletion by namespace', () async {
      final values = <String, String>{};
      final first = _store(values: values, namespace: 'synthetic.namespace-a');
      final second = _store(values: values, namespace: 'synthetic.namespace-b');
      expect(await first.replace(firstBundle), const Success<void>(null));
      expect(
        await second.replace(replacementBundle),
        const Success<void>(null),
      );

      expect(await first.delete(), const Success<void>(null));

      expect(await first.read(), const Success<CredentialBundle?>(null));
      expect(
        await second.read(),
        const Success<CredentialBundle?>(replacementBundle),
      );
      expect(values, hasLength(1));
    });

    test('deletion failure is reported and does not claim removal', () async {
      final driver = FakeSecureValueStore();
      final store = LinuxSecureCredentialStore(
        namespace: 'synthetic.delete-failure',
        storage: driver,
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
      );
      expect(await store.replace(firstBundle), const Success<void>(null));
      driver.deleteFailure = const SecureValueStoreException(
        SecureValueStoreFailureKind.denied,
      );

      final result = await store.delete();

      expect(result, isA<Failed<void>>());
      expect(await store.read(), const Success<CredentialBundle?>(firstBundle));
    });

    test(
      'commit-then-fail deletion succeeds only after absent read-back',
      () async {
        final driver = FakeSecureValueStore();
        final store = LinuxSecureCredentialStore(
          namespace: 'synthetic.ambiguous-delete',
          storage: driver,
          diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        );
        expect(await store.replace(firstBundle), const Success<void>(null));
        driver
          ..deleteFailure = const SecureValueStoreException(
            SecureValueStoreFailureKind.unknown,
          )
          ..commitDeleteBeforeFailure = true;

        expect(await store.delete(), const Success<void>(null));
        expect(await store.read(), const Success<CredentialBundle?>(null));
      },
    );

    test('never emits credential canaries from storage failures', () async {
      const canary = 'refresh_token=credential-canary-secure-store';
      for (final sinkFactory
          in <DiagnosticSink Function(InMemoryDiagnosticHistory)>[
            ProductionDiagnosticSink.new,
            SensitiveDevelopmentDiagnosticSink.new,
          ]) {
        final history = InMemoryDiagnosticHistory();
        final driver = FakeSecureValueStore()
          ..readFailure = const SecureValueStoreException(
            SecureValueStoreFailureKind.unknown,
            sensitiveDetails: canary,
          );
        final store = LinuxSecureCredentialStore(
          namespace: 'synthetic.canary',
          storage: driver,
          diagnostics: sinkFactory(history),
        );

        final result = await store.read();

        expect(result, isA<Failed<CredentialBundle?>>());
        expect(history.records, isNotEmpty);
        final output = history.records
            .map((record) => record.renderedText)
            .join('\n');
        expect(output, isNot(contains('credential-canary')));
        expect(output, isNot(contains('refresh_token')));
      }
    });

    test('rejects unsafe namespaces before touching storage', () {
      for (final namespace in <String>['', 'normal credentials', '../normal']) {
        expect(
          () => LinuxSecureCredentialStore(
            namespace: namespace,
            storage: FakeSecureValueStore(),
            diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
          ),
          throwsArgumentError,
        );
      }
    });
  });
}

LinuxSecureCredentialStore _store({
  required Map<String, String> values,
  required String namespace,
}) => LinuxSecureCredentialStore(
  namespace: namespace,
  storage: FakeSecureValueStore(values),
  diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
);

final class FakeSecureValueStore implements SecureValueStore {
  FakeSecureValueStore([Map<String, String>? values])
    : values = values ?? <String, String>{};

  final Map<String, String> values;
  SecureValueStoreException? readFailure;
  SecureValueStoreException? writeFailure;
  SecureValueStoreException? deleteFailure;
  bool commitWriteBeforeFailure = false;
  bool commitDeleteBeforeFailure = false;
  String? replacementOnFailure;

  @override
  Future<String?> read({required String key}) async {
    final failure = readFailure;
    if (failure != null) {
      throw failure;
    }
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    final failure = writeFailure;
    if (failure != null) {
      if (commitWriteBeforeFailure) {
        values[key] = value;
      } else if (replacementOnFailure case final replacement?) {
        values[key] = replacement;
      }
      throw failure;
    }
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    final failure = deleteFailure;
    if (failure != null) {
      if (commitDeleteBeforeFailure) {
        values.remove(key);
      }
      throw failure;
    }
    values.remove(key);
  }
}
