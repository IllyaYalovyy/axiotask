import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/diagnostics/diagnostics.dart';
import '../../../core/failure.dart';
import '../../../core/outcome.dart';

const int _credentialBundleSchemaVersion = 1;
const int _maximumCredentialBundleLength = 131072;

final class CredentialBundle {
  const CredentialBundle({
    required this.refreshToken,
    required this.dpopPrivateKeyJwk,
  });

  final String refreshToken;
  final String dpopPrivateKeyJwk;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CredentialBundle &&
          refreshToken == other.refreshToken &&
          dpopPrivateKeyJwk == other.dpopPrivateKeyJwk;

  @override
  int get hashCode => Object.hash(refreshToken, dpopPrivateKeyJwk);

  @override
  String toString() => 'CredentialBundle([REDACTED])';
}

abstract interface class CredentialStore {
  Future<Outcome<CredentialBundle?>> read();

  Future<Outcome<void>> replace(CredentialBundle bundle);

  Future<Outcome<void>> delete();
}

enum SecureValueStoreFailureKind { unavailable, locked, denied, unknown }

final class SecureValueStoreException implements Exception {
  const SecureValueStoreException(this.kind, {this.sensitiveDetails});

  final SecureValueStoreFailureKind kind;
  final String? sensitiveDetails;

  @override
  String toString() => 'SecureValueStoreException(${kind.name})';
}

abstract interface class SecureValueStore {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});

  Future<void> delete({required String key});
}

final class FlutterSecureStorageValueStore implements SecureValueStore {
  FlutterSecureStorageValueStore([
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  ]) : _storage = storage;

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) =>
      _translate(() => _storage.read(key: key));

  @override
  Future<void> write({required String key, required String value}) =>
      _translate(() => _storage.write(key: key, value: value));

  @override
  Future<void> delete({required String key}) =>
      _translate(() => _storage.delete(key: key));

  Future<T> _translate<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlatformException catch (error) {
      throw SecureValueStoreException(
        _platformFailureKind(error.code),
        sensitiveDetails: error.message,
      );
    } catch (error) {
      throw SecureValueStoreException(
        SecureValueStoreFailureKind.unknown,
        sensitiveDetails: error.toString(),
      );
    }
  }

  static SecureValueStoreFailureKind _platformFailureKind(String code) {
    switch (code.toLowerCase()) {
      case 'keyringlocked':
        return SecureValueStoreFailureKind.locked;
      case 'accessdenied':
      case 'permissiondenied':
      case 'permission-denied':
        return SecureValueStoreFailureKind.denied;
      case 'libsecret error':
      case 'secretnotfound':
      case 'storageerror':
      case 'unavailable':
        return SecureValueStoreFailureKind.unavailable;
      default:
        return SecureValueStoreFailureKind.unknown;
    }
  }
}

String credentialBundleStorageKey(String namespace) {
  final normalized = namespace.trim();
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,126}$').hasMatch(normalized)) {
    throw ArgumentError.value(
      namespace,
      'namespace',
      'must be a lowercase storage namespace',
    );
  }
  return '$normalized.credential-bundle.v1';
}

final class LinuxSecureCredentialStore implements CredentialStore {
  LinuxSecureCredentialStore({
    required String namespace,
    required SecureValueStore storage,
    required DiagnosticSink diagnostics,
  }) : this._(credentialBundleStorageKey(namespace), storage, diagnostics);

  LinuxSecureCredentialStore._(this._key, this._storage, this._diagnostics);

  final String _key;
  final SecureValueStore _storage;
  final DiagnosticSink _diagnostics;

  @override
  Future<Outcome<CredentialBundle?>> read() async {
    try {
      final encoded = await _storage.read(key: _key);
      if (encoded == null) {
        return const Outcome<CredentialBundle?>.success(null);
      }
      return Outcome<CredentialBundle?>.success(_decode(encoded));
    } on FormatException {
      final failure = _malformedBundleFailure();
      _recordFailure(failure);
      return Outcome<CredentialBundle?>.failure(failure);
    } on SecureValueStoreException catch (error) {
      final failure = _storageFailure(error.kind, FailureOperation.read);
      _recordFailure(failure);
      return Outcome<CredentialBundle?>.failure(failure);
    }
  }

  @override
  Future<Outcome<void>> replace(CredentialBundle bundle) async {
    final encoded = _encode(bundle);
    try {
      await _storage.write(key: _key, value: encoded);
    } on SecureValueStoreException catch (writeError) {
      return _recoverReplacement(encoded, writeError);
    }

    try {
      final observed = await _storage.read(key: _key);
      if (observed == encoded) {
        return const Outcome<void>.success(null);
      }
    } on SecureValueStoreException {
      // The typed failure below intentionally excludes plugin exception text.
    }
    final failure = _unverifiedMutationFailure('replacement');
    _recordFailure(failure);
    return Outcome<void>.failure(failure);
  }

  Future<Outcome<void>> _recoverReplacement(
    String expected,
    SecureValueStoreException writeError,
  ) async {
    try {
      if (await _storage.read(key: _key) == expected) {
        _recordRecoveredMutation('replacement');
        return const Outcome<void>.success(null);
      }
    } on SecureValueStoreException {
      final failure = _unverifiedMutationFailure('replacement');
      _recordFailure(failure);
      return Outcome<void>.failure(failure);
    }
    final failure = _storageFailure(writeError.kind, FailureOperation.write);
    _recordFailure(failure);
    return Outcome<void>.failure(failure);
  }

  @override
  Future<Outcome<void>> delete() async {
    try {
      await _storage.delete(key: _key);
    } on SecureValueStoreException catch (deleteError) {
      return _recoverDeletion(deleteError);
    }

    try {
      if (await _storage.read(key: _key) == null) {
        return const Outcome<void>.success(null);
      }
    } on SecureValueStoreException {
      // The typed failure below intentionally excludes plugin exception text.
    }
    final failure = _unverifiedMutationFailure('deletion');
    _recordFailure(failure);
    return Outcome<void>.failure(failure);
  }

  Future<Outcome<void>> _recoverDeletion(
    SecureValueStoreException deleteError,
  ) async {
    try {
      if (await _storage.read(key: _key) == null) {
        _recordRecoveredMutation('deletion');
        return const Outcome<void>.success(null);
      }
    } on SecureValueStoreException {
      final failure = _unverifiedMutationFailure('deletion');
      _recordFailure(failure);
      return Outcome<void>.failure(failure);
    }
    final failure = _storageFailure(deleteError.kind, FailureOperation.write);
    _recordFailure(failure);
    return Outcome<void>.failure(failure);
  }

  static String _encode(CredentialBundle bundle) {
    if (bundle.refreshToken.isEmpty || bundle.dpopPrivateKeyJwk.isEmpty) {
      throw ArgumentError('Credential bundle values must not be empty.');
    }
    final encoded = jsonEncode(<String, Object>{
      'schemaVersion': _credentialBundleSchemaVersion,
      'refreshToken': bundle.refreshToken,
      'dpopPrivateKeyJwk': bundle.dpopPrivateKeyJwk,
    });
    if (encoded.length > _maximumCredentialBundleLength) {
      throw ArgumentError('Credential bundle exceeds the supported size.');
    }
    return encoded;
  }

  static CredentialBundle _decode(String encoded) {
    if (encoded.isEmpty || encoded.length > _maximumCredentialBundleLength) {
      throw const FormatException('Invalid credential bundle length.');
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 3 ||
        decoded['schemaVersion'] != _credentialBundleSchemaVersion ||
        decoded['refreshToken'] is! String ||
        decoded['dpopPrivateKeyJwk'] is! String) {
      throw const FormatException('Invalid credential bundle shape.');
    }
    final refreshToken = decoded['refreshToken'] as String;
    final dpopPrivateKeyJwk = decoded['dpopPrivateKeyJwk'] as String;
    if (refreshToken.isEmpty || dpopPrivateKeyJwk.isEmpty) {
      throw const FormatException(
        'Credential bundle values must not be empty.',
      );
    }
    return CredentialBundle(
      refreshToken: refreshToken,
      dpopPrivateKeyJwk: dpopPrivateKeyJwk,
    );
  }

  Failure _storageFailure(
    SecureValueStoreFailureKind kind,
    FailureOperation operation,
  ) {
    switch (kind) {
      case SecureValueStoreFailureKind.unavailable:
        return Failure(
          code: 'auth.secure_store_unavailable',
          category: FailureCategory.authorization,
          operation: operation,
          retry: RetryClassification.unknown,
          impact: 'Saved Google authorization cannot be accessed.',
          action: FailureAction.reviewConfiguration,
          safeSummary: 'GNOME Secret Service is unavailable.',
        );
      case SecureValueStoreFailureKind.locked:
        return Failure(
          code: 'auth.secure_store_locked',
          category: FailureCategory.authorization,
          operation: operation,
          retry: RetryClassification.transient,
          impact: 'Saved Google authorization is locked.',
          action: FailureAction.retry,
          safeSummary: 'Unlock the login keyring and retry.',
        );
      case SecureValueStoreFailureKind.denied:
        return Failure(
          code: 'auth.secure_store_denied',
          category: FailureCategory.authorization,
          operation: operation,
          retry: RetryClassification.permanent,
          impact: 'Saved Google authorization cannot be accessed.',
          action: FailureAction.reviewConfiguration,
          safeSummary: 'Secret Service denied credential storage access.',
        );
      case SecureValueStoreFailureKind.unknown:
        return Failure(
          code: 'auth.secure_store_failed',
          category: FailureCategory.authorization,
          operation: operation,
          retry: RetryClassification.unknown,
          impact: 'Saved Google authorization could not be accessed safely.',
          action: FailureAction.retry,
          safeSummary: 'Secure credential storage failed.',
        );
    }
  }

  Failure _malformedBundleFailure() => const Failure(
    code: 'auth.secure_store_malformed_bundle',
    category: FailureCategory.authorization,
    operation: FailureOperation.read,
    retry: RetryClassification.permanent,
    impact: 'Saved Google authorization cannot be used.',
    action: FailureAction.connect,
    safeSummary:
        'The complete refresh-token and DPoP-key bundle must be replaced by '
        'reauthorization.',
    authorizationRecovery: AuthorizationRecovery.reauthorize,
  );

  Failure _unverifiedMutationFailure(String mutation) => Failure(
    code: 'auth.secure_store_${mutation}_unverified',
    category: FailureCategory.authorization,
    operation: FailureOperation.write,
    retry: RetryClassification.unknown,
    impact: 'Saved Google authorization state could not be verified.',
    action: FailureAction.retry,
    safeSummary:
        'Secure credential $mutation did not produce a verified state.',
  );

  void _recordFailure(Failure failure) {
    _diagnostics.record(
      DiagnosticEvent(
        subsystem: DiagnosticSubsystem.storage,
        kind: DiagnosticEventKind.failure,
        code: failure.code,
        operation: failure.operation.name,
        fields: <DiagnosticField>[
          DiagnosticField.safe('category', failure.category.name),
          DiagnosticField.safe('retry', failure.retry.name),
        ],
      ),
    );
  }

  void _recordRecoveredMutation(String mutation) {
    _diagnostics.record(
      DiagnosticEvent(
        subsystem: DiagnosticSubsystem.storage,
        kind: DiagnosticEventKind.resolution,
        code: 'auth.secure_store_ambiguous_operation_recovered',
        operation: 'write',
        fields: <DiagnosticField>[DiagnosticField.safe('mutation', mutation)],
      ),
    );
  }
}
