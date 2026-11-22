import '../../core/outcome.dart';

/// What the Account screen may do to this device's Google connection.
abstract interface class AccountSession {
  /// Forgets the saved Google authorization and stops synchronization.
  ///
  /// Cached tasks and unsent local changes stay on this device. Signing in
  /// again with the same account resumes synchronization.
  Future<Outcome<void>> signOut();

  /// Signs out and removes this account's local copy so another Google
  /// account can connect.
  ///
  /// Unsent local changes are discarded with the local copy; Google Tasks
  /// data is untouched. On success the application reopens at first
  /// connection.
  Future<Outcome<void>> switchAccount();
}
