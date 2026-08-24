// Where the desktop OAuth client id/secret come from (#229).
//
// A shipped install must sync out of the box: hand-editing `config.json` before
// the first sign-in is not something a user of a packaged app can be asked to
// do. Google's installed-app model makes that possible — the id and secret of a
// "Desktop app" client are NOT confidential (they ship inside every installed
// copy; PKCE + the loopback redirect are what actually protect the flow), so
// the build bundles them.
//
// This pins the resolution ORDER and its edge: an operator who edits
// `config.json` still wins, a build with no credentials compiled in behaves
// exactly as it did before #229, and a HALF-edited config is never silently
// completed from the bundle — pairing a hand-written client id with a bundled
// secret would send Google a mismatched pair and fail as `invalid_client`,
// which names nothing the user can act on.

import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/google_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bundled = BundledCredentials(
    clientId: 'bundled-id.apps.example.test',
    clientSecret: 'bundled-secret',
  );

  test('an unedited config resolves to the credentials built into the app', () {
    // What a packaged first launch has: bootstrap wrote the default config,
    // whose `google` section is empty.
    final resolved = resolveGoogleCredentials(
      config: const GoogleConfig(),
      bundled: bundled,
    );

    expect(resolved.clientId, 'bundled-id.apps.example.test');
    expect(resolved.clientSecret, 'bundled-secret');
    expect(resolved.scopes, const [tasksScope]);
  });

  test('a config the operator filled in overrides the bundled default', () {
    final resolved = resolveGoogleCredentials(
      config: const GoogleConfig(
        clientId: 'mine.apps.example.test',
        clientSecret: 'my-secret',
        scopes: ['https://www.googleapis.com/auth/tasks.readonly'],
      ),
      bundled: bundled,
    );

    expect(resolved.clientId, 'mine.apps.example.test');
    expect(resolved.clientSecret, 'my-secret');
    expect(resolved.scopes, ['https://www.googleapis.com/auth/tasks.readonly']);
  });

  test(
    'with nothing bundled, an empty config stays empty (pre-#229 build)',
    () {
      // The fallback chain a build made WITHOUT a credentials file has: nothing
      // is compiled in, so the app is exactly as unconfigured as it was before
      // #229 and #228's loud "not configured" fault is what the user gets.
      final resolved = resolveGoogleCredentials(
        config: const GoogleConfig(),
        bundled: const BundledCredentials(),
      );

      expect(resolved.clientId, isEmpty);
      expect(resolved.clientSecret, isEmpty);
    },
  );

  test('a half-edited config is NOT completed from the bundle', () {
    // The non-happy path: someone pasted their own client id and left the
    // secret blank. Taking the id from the file and the secret from the bundle
    // sends Google a pair that does not belong together — a bare
    // `invalid_client` the user cannot act on. The file the user edited wins
    // WHOLE, so what they get is #228's message naming that same file.
    final resolved = resolveGoogleCredentials(
      config: const GoogleConfig(clientId: 'mine.apps.example.test'),
      bundled: bundled,
    );

    expect(resolved.clientId, 'mine.apps.example.test');
    expect(
      resolved.clientSecret,
      isEmpty,
      reason: 'a bundled secret must never be paired with a foreign client id',
    );
  });

  test('whitespace-only config values count as unset', () {
    final resolved = resolveGoogleCredentials(
      config: const GoogleConfig(clientId: '   ', clientSecret: '\n'),
      bundled: bundled,
    );

    expect(resolved.clientId, 'bundled-id.apps.example.test');
    expect(resolved.clientSecret, 'bundled-secret');
  });

  test('this repository compiles in no credentials of its own', () {
    // The default the composition root uses reads `String.fromEnvironment`, so
    // a checkout with no gitignored credentials file — every clone, and CI —
    // has an EMPTY bundle. If this ever fails, a credential leaked into the
    // build configuration that is under version control.
    expect(BundledCredentials.fromEnvironment.clientId, isEmpty);
    expect(BundledCredentials.fromEnvironment.clientSecret, isEmpty);
    expect(BundledCredentials.fromEnvironment.isComplete, isFalse);
  });
}
