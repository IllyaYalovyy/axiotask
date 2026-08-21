import 'dart:async';

/// Runs a live Google contract probe only after its non-Tasks identity check.
///
/// The probe body deliberately receives no way to bypass [verifySubject].  The
/// small abstraction also lets the safety/cleanup behavior be qualified without
/// contacting Google.
final class GoogleContractHarness {
  GoogleContractHarness({
    required this.expectedSubject,
    required this.resolveAuthenticatedSubject,
    required this.cleanup,
  });

  final String expectedSubject;
  final Future<String?> Function() resolveAuthenticatedSubject;
  final Future<void> Function() cleanup;

  Future<T> run<T>(Future<T> Function() probe) async {
    final subject = await resolveAuthenticatedSubject();
    requirePinnedSubject(expectedSubject, subject);

    Object? primary;
    StackTrace? primaryStack;
    T? result;
    try {
      // A previous interrupted run can only have created resources under this
      // dedicated prefix. Clean it before adding a new disposable list.
      await cleanup();
      result = await probe();
    } catch (error, stackTrace) {
      primary = error;
      primaryStack = stackTrace;
    }

    Object? cleanupError;
    try {
      await cleanup();
    } catch (error) {
      cleanupError = error;
    }
    if (primary != null) {
      if (cleanupError != null) {
        throw GoogleContractCleanupException(primary, cleanupError);
      }
      Error.throwWithStackTrace(primary, primaryStack!);
    }
    if (cleanupError != null) {
      throw GoogleContractCleanupException(null, cleanupError);
    }
    return result as T;
  }
}

/// Refuses probe entry unless the current OAuth identity is the dedicated
/// account. The production account guard separately repeats this check for
/// every Tasks operation.
void requirePinnedSubject(String expectedSubject, String? subject) {
  if (expectedSubject.isEmpty || subject == null || subject.isEmpty) {
    throw const GoogleContractSafetyException(
      'The dedicated account subject is missing.',
    );
  }
  if (subject != expectedSubject) {
    throw const GoogleContractSafetyException(
      'The authenticated subject does not match the dedicated account.',
    );
  }
}

final class GoogleContractSafetyException implements Exception {
  const GoogleContractSafetyException(this.message);

  final String message;

  @override
  String toString() => 'GoogleContractSafetyException: $message';
}

final class GoogleContractCleanupException implements Exception {
  const GoogleContractCleanupException(this.primary, this.cleanup);

  final Object? primary;
  final Object cleanup;

  @override
  String toString() => primary == null
      ? 'Google contract cleanup failed.'
      : 'Google contract probe and cleanup both failed.';
}

bool isSafeGoogleContractPrefix(String value) => RegExp(
  r'^axiotask-contract-probe-[0-9]{8}T[0-9]{6}Z-[a-z0-9]{6,32}$',
).hasMatch(value);

/// A usable Tasks link is an HTTPS Google Tasks URL. Its navigation destination
/// is intentionally a human-owned Linux approval, not an automated claim.
bool hasGoogleTasksWebViewLinkShape(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  return uri != null &&
      uri.isAbsolute &&
      uri.scheme == 'https' &&
      uri.host == 'tasks.google.com' &&
      uri.path.isNotEmpty;
}
