abstract interface class ExternalLinkLauncher {
  /// Returns whether the operating system accepted the external launch.
  Future<bool> launch(Uri uri);
}

final class UnavailableExternalLinkLauncher implements ExternalLinkLauncher {
  const UnavailableExternalLinkLauncher();

  @override
  Future<bool> launch(Uri uri) async => false;
}
