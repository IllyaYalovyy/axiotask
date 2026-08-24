// The build-time OAuth credentials, on the packaging side (#229).
//
// The app can only sign in out of the box if the BUILD actually carries the
// credentials, and the repository can only stay publishable if they never enter
// it. Both halves are mechanical, so both are pinned here:
//
//   - `tool/oauth_defines.sh` decides, from one place, whether a build gets a
//     `--dart-define-from-file` argument. Every build script asks it.
//   - the scripts that produce a runnable artifact — install.sh, build_rpm.sh
//     and dev.sh — really pass that argument to `flutter`, proven by capturing
//     the argv of a stand-in `flutter` on PATH rather than by reading source.
//   - no file under version control carries a credential shaped like a real
//     Google one, and the file that does carry them is ignored by git.
//
// Every script here runs against a THROWAWAY $HOME with a stand-in `flutter`
// that fails immediately: the wiring is observed, no build runs, and nothing is
// installed anywhere. The credentials path is always overridden, so an
// operator's own file is never read and never needed.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The gitignored file the operator creates once (README, "Google sign-in
/// setup"). Never read by these tests — only its NAME is contract.
const String kCredentialsPath = 'tool/oauth_credentials.json';

void main() {
  late Directory home;
  late Directory bin;
  late File argvLog;

  /// A stand-in executable that records the argv it was called with and then
  /// FAILS, so the calling script aborts before it builds, installs or packages
  /// anything.
  void writeStub(String name) {
    final f = File(p.join(bin.path, name));
    f.writeAsStringSync(
      '#!/bin/sh\nprintf "%s\\n" "\$*" >> "${argvLog.path}"\nexit 1\n',
    );
    Process.runSync('chmod', ['+x', f.path]);
  }

  Map<String, String> envWith(String? credentialsFile) => {
    'HOME': home.path,
    'XDG_DATA_HOME': p.join(home.path, '.local/share'),
    'XDG_CONFIG_HOME': p.join(home.path, '.config'),
    'PATH': '${bin.path}:${Platform.environment['PATH']}',
    'AXIOTASK_OAUTH_DEFINES':
        credentialsFile ?? p.join(home.path, 'absent.json'),
  };

  File presentCredentials() {
    final f = File(p.join(home.path, 'creds.json'));
    f.writeAsStringSync(
      jsonEncode({
        'AXIOTASK_GOOGLE_CLIENT_ID': 'stub-id.apps.example.test',
        'AXIOTASK_GOOGLE_CLIENT_SECRET': 'stub-secret',
      }),
    );
    return f;
  }

  ProcessResult runScript(
    List<String> args, {
    required String? credentialsFile,
  }) => Process.runSync('bash', args, environment: envWith(credentialsFile));

  setUp(() {
    home = Directory.systemTemp.createTempSync('axiotask_229_pkg_');
    bin = Directory(p.join(home.path, 'bin'))..createSync(recursive: true);
    argvLog = File(p.join(home.path, 'argv.log'))..writeAsStringSync('');
    writeStub('flutter');
    writeStub('rpmbuild');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  group('tool/oauth_defines.sh', () {
    test('prints the define argument when a credentials file exists', () {
      final creds = presentCredentials();
      final r = runScript([
        'tool/oauth_defines.sh',
      ], credentialsFile: creds.path);

      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(
        (r.stdout as String).trim(),
        '--dart-define-from-file=${creds.path}',
      );
    });

    test('prints nothing when there is no credentials file', () {
      // The unofficial-build path: a clone with no file has nothing compiled
      // in and behaves exactly as it did before #229.
      final r = runScript(['tool/oauth_defines.sh'], credentialsFile: null);

      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect((r.stdout as String).trim(), isEmpty);
    });

    test('never echoes the credentials themselves', () {
      // A build log is pasted into issues and CI output; the file NAME is
      // reportable, its contents are not.
      final creds = presentCredentials();
      final r = runScript([
        'tool/oauth_defines.sh',
      ], credentialsFile: creds.path);

      expect('${r.stdout}${r.stderr}', isNot(contains('stub-secret')));
      expect('${r.stdout}${r.stderr}', isNot(contains('stub-id')));
    });

    test('defaults to the gitignored tool/oauth_credentials.json', () {
      // The path is contract — the README tells the operator to create exactly
      // it, and .gitignore names exactly it.
      final src = File('tool/oauth_defines.sh').readAsStringSync();
      expect(src, contains(kCredentialsPath));
    });
  });

  group('the build scripts pass the credentials to flutter', () {
    /// Every script that turns this repository into something a user runs.
    const builds = {
      'tool/install.sh': <String>[],
      'tool/build_rpm.sh': <String>[],
      'tool/dev.sh': <String>[],
      'tool/dev.sh --release': <String>['--release'],
      'tool/dev.sh --bundle': <String>['--bundle'],
    };

    for (final entry in builds.entries) {
      final script = entry.key.split(' ').first;
      final args = entry.value;

      test('${entry.key} bundles them when the file is there', () {
        final creds = presentCredentials();
        runScript([script, ...args], credentialsFile: creds.path);

        final calls = argvLog.readAsStringSync();
        expect(
          calls.trim(),
          isNotEmpty,
          reason: 'the script never invoked flutter at all',
        );
        expect(
          calls,
          contains('--dart-define-from-file=${creds.path}'),
          reason: 'built without the credentials — the app cannot sign in',
        );
      });

      test('${entry.key} still builds with no credentials file', () {
        runScript([script, ...args], credentialsFile: null);

        final calls = argvLog.readAsStringSync();
        expect(
          calls.trim(),
          isNotEmpty,
          reason: 'the script never invoked flutter at all',
        );
        expect(
          calls,
          isNot(contains('--dart-define-from-file')),
          reason: 'a build with no credentials file must pass no define file',
        );
      });
    }
  });

  group('no credentials in the repository', () {
    /// Everything git tracks, as text (binaries are skipped, not decoded).
    List<({String path, String text})> trackedText() {
      final r = Process.runSync('git', ['ls-files', '-z']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final out = <({String path, String text})>[];
      for (final path in (r.stdout as String).split('\u0000')) {
        if (path.isEmpty) continue;
        final f = File(path);
        if (!f.existsSync()) continue;
        try {
          out.add((path: path, text: f.readAsStringSync()));
        } on FileSystemException {
          continue;
        }
      }
      return out;
    }

    test('no tracked file carries a real Google credential', () {
      // Shapes, not names: the README and the #228 fixtures legitimately say
      // "apps.googleusercontent.com", so what is banned is a value with the
      // FORM Google issues — a numeric project prefix plus a long opaque tail,
      // and the `GOCSPX-` secret prefix. Neither pattern matches its own
      // source, so this file is scanned like every other.
      final clientId = RegExp(
        r'[0-9]{6,}-[a-z0-9]{16,}\.apps\.googleusercontent\.com',
      );
      final secret = RegExp(
        'GOCSPX'
        '-'
        r'[A-Za-z0-9_\-]{8,}',
      );

      final tracked = trackedText();
      expect(tracked, isNotEmpty, reason: 'git ls-files returned nothing');

      final offenders = <String>[];
      for (final file in tracked) {
        for (final re in [clientId, secret]) {
          if (re.hasMatch(file.text)) offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'a Google credential is committed in: $offenders',
      );
    });

    test('the credentials file is ignored and untracked', () {
      final ignored = Process.runSync('git', [
        'check-ignore',
        '-q',
        kCredentialsPath,
      ]);
      expect(
        ignored.exitCode,
        0,
        reason:
            '$kCredentialsPath is not gitignored — a secret could be committed '
            'by `git add .`',
      );

      final tracked = Process.runSync('git', [
        'ls-files',
        '--error-unmatch',
        kCredentialsPath,
      ]);
      expect(
        tracked.exitCode,
        isNot(0),
        reason: '$kCredentialsPath is tracked',
      );
    });
  });
}
