// Where the desktop OAuth client id and secret come from (#229).
//
// A packaged install has to sync out of the box. Asking a user who installed an
// RPM to create a Google Cloud project and hand-edit `config.json` before the
// first sign-in is not a shippable first run, and #228 only made that state
// LOUD, not workable.
//
// Google's installed-app OAuth model is what makes bundling correct rather than
// a leak: the client id and secret of a "Desktop app" client are explicitly NOT
// treated as confidential — they ship inside every installed copy of every such
// app, and the security of the flow comes from PKCE plus the loopback redirect,
// not from the secret. So the build compiles them in, exactly as the reference
// desktop clients do.
//
// They are compiled in, never committed: the values arrive through
// `--dart-define-from-file=tool/oauth_credentials.json`, a GITIGNORED file the
// operator creates once (see README, "Google sign-in setup"). A checkout — and
// therefore any clone or CI run — has an empty bundle and behaves exactly as it
// did before #229.

import 'config.dart';

/// The OAuth client credentials compiled into this build.
///
/// Empty in every build made without a credentials file, which is what keeps
/// the repository free of secrets: the values live only in the gitignored
/// define file and in the binary produced from it.
class BundledCredentials {
  const BundledCredentials({this.clientId = '', this.clientSecret = ''});

  /// The `--dart-define` name carrying the client id.
  static const String clientIdDefine = 'AXIOTASK_GOOGLE_CLIENT_ID';

  /// The `--dart-define` name carrying the client secret.
  static const String clientSecretDefine = 'AXIOTASK_GOOGLE_CLIENT_SECRET';

  /// What THIS build carries — the production default of
  /// [resolveGoogleCredentials]. Const, so a build with no define file folds it
  /// away to a pair of empty strings.
  static const BundledCredentials fromEnvironment = BundledCredentials(
    clientId: String.fromEnvironment(clientIdDefine),
    clientSecret: String.fromEnvironment(clientSecretDefine),
  );

  /// OAuth client id built into the app, or empty when none was bundled.
  final String clientId;

  /// OAuth client secret built into the app, or empty when none was bundled.
  final String clientSecret;

  /// Whether this build carries a usable PAIR. Half a pair is no pair: Google
  /// rejects a client id sent without its secret.
  bool get isComplete =>
      clientId.trim().isNotEmpty && clientSecret.trim().isNotEmpty;
}

/// The credentials the desktop OAuth flow actually runs with.
///
/// A `config.json` the operator filled in wins; an untouched one falls back to
/// what the build carries. The choice is made over the PAIR, never field by
/// field: completing a hand-written client id with a bundled secret would send
/// Google two halves of different clients, and the only thing the user would
/// see is a bare `invalid_client`. Whichever source is chosen is used whole, so
/// a half-edited config falls through to #228's message naming that same file.
///
/// [GoogleConfig.scopes] always comes from the config — scopes are a user
/// setting, not a credential.
GoogleConfig resolveGoogleCredentials({
  required GoogleConfig config,
  BundledCredentials bundled = BundledCredentials.fromEnvironment,
}) {
  final edited =
      config.clientId.trim().isNotEmpty ||
      config.clientSecret.trim().isNotEmpty;
  if (edited) return config;
  return GoogleConfig(
    clientId: bundled.clientId,
    clientSecret: bundled.clientSecret,
    scopes: config.scopes,
  );
}
