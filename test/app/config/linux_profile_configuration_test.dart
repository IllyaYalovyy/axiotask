import 'dart:io';

import 'package:axiotask/src/app/config/linux_profile_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinuxProfileConfiguration', () {
    test('resolves production and development XDG paths independently', () {
      const environment = <String, String>{
        'XDG_CONFIG_HOME': '/tmp/axiotask-config-test',
      };

      expect(
        LinuxProfileConfiguration.resolvePath(
          profile: LinuxApplicationProfile.production,
          environment: environment,
        ),
        '/tmp/axiotask-config-test/axiotask/config.toml',
      );
      expect(
        LinuxProfileConfiguration.resolvePath(
          profile: LinuxApplicationProfile.development,
          environment: environment,
        ),
        '/tmp/axiotask-config-test/axiotask-dev/config.toml',
      );
    });

    test('uses the standard HOME fallback when XDG_CONFIG_HOME is absent', () {
      expect(
        LinuxProfileConfiguration.resolvePath(
          profile: LinuxApplicationProfile.development,
          environment: const <String, String>{'HOME': '/var/empty/developer'},
        ),
        '/var/empty/developer/.config/axiotask-dev/config.toml',
      );
    });

    test('loads the Rust-compatible production Google table', () async {
      final fixture = await _configurationFile('''
[google]
client_id = "client.apps.googleusercontent.com"
client_secret = "desktop-client-value"
scopes = ["https://www.googleapis.com/auth/tasks"]

[sync]
push_enabled = true
auto_sync_on_start = true
''');
      addTearDown(() => fixture.parent.delete(recursive: true));

      final loaded = await LinuxProfileConfiguration.load(
        profile: LinuxApplicationProfile.production,
        file: fixture,
      );

      expect(loaded.google.clientId, 'client.apps.googleusercontent.com');
      expect(loaded.google.clientSecret, 'desktop-client-value');
      expect(loaded.dedicatedAccountSubject, isNull);
    });

    test('requires and loads the dedicated subject for development', () async {
      final fixture = await _configurationFile('''
[google]
client_id = "client.apps.googleusercontent.com"
client_secret = "desktop-client-value"
account_subject = "dedicated-google-subject"
''');
      addTearDown(() => fixture.parent.delete(recursive: true));

      final loaded = await LinuxProfileConfiguration.load(
        profile: LinuxApplicationProfile.development,
        file: fixture,
      );

      expect(loaded.dedicatedAccountSubject?.value, 'dedicated-google-subject');
    });

    test('fails closed when development subject is absent', () async {
      final fixture = await _configurationFile('''
[google]
client_id = "client.apps.googleusercontent.com"
client_secret = "desktop-client-value"
''');
      addTearDown(() => fixture.parent.delete(recursive: true));

      await expectLater(
        LinuxProfileConfiguration.load(
          profile: LinuxApplicationProfile.development,
          file: fixture,
        ),
        throwsA(
          isA<LinuxProfileConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('google.account_subject'),
          ),
        ),
      );
    });

    test(
      'fails closed for malformed TOML without echoing its content',
      () async {
        final fixture = await _configurationFile('''
[google
client_secret = "client-secret-output-canary"
''');
        addTearDown(() => fixture.parent.delete(recursive: true));

        await expectLater(
          LinuxProfileConfiguration.load(
            profile: LinuxApplicationProfile.production,
            file: fixture,
          ),
          throwsA(
            isA<LinuxProfileConfigurationException>()
                .having(
                  (error) => error.toString(),
                  'safe error',
                  contains('not valid TOML'),
                )
                .having(
                  (error) => error.toString(),
                  'redacted error',
                  isNot(contains('client-secret-output-canary')),
                ),
          ),
        );
      },
    );

    test('rejects a configuration symlink', () async {
      final fixture = await _configurationFile('''
[google]
client_id = "client.apps.googleusercontent.com"
client_secret = "desktop-client-value"
''');
      addTearDown(() => fixture.parent.delete(recursive: true));
      final link = Link('${fixture.parent.path}/linked.toml');
      await link.create(fixture.path);

      await expectLater(
        LinuxProfileConfiguration.load(
          profile: LinuxApplicationProfile.production,
          file: File(link.path),
        ),
        throwsA(
          isA<LinuxProfileConfigurationException>().having(
            (error) => error.message,
            'message',
            contains('not a link'),
          ),
        ),
      );
    });

    test('rejects relative XDG roots instead of falling back', () {
      expect(
        () => LinuxProfileConfiguration.resolvePath(
          profile: LinuxApplicationProfile.development,
          environment: const <String, String>{
            'XDG_CONFIG_HOME': '../production',
            'HOME': '/var/empty/developer',
          },
        ),
        throwsA(isA<LinuxProfileConfigurationException>()),
      );
    });
  });
}

Future<File> _configurationFile(String contents) async {
  final directory = await Directory.systemTemp.createTemp(
    'axiotask-profile-config-',
  );
  final file = File('${directory.path}/config.toml');
  await file.writeAsString(contents);
  return file;
}
