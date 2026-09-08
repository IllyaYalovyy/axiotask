// Release layer — what happens between `git tag v1.2.3` and a user having the
// app installed (#300).
//
// Everything below the tag is automated by .github/workflows/release.yml, and a
// release workflow only ever runs on the real thing: there is no way to
// rehearse it. So the pieces it depends on are pinned here — the version guard
// as a REAL script with real exit codes, the workflow as a contract, the
// Android signing configuration, and the install instructions a user follows.
//
// What this protects (and the failures it prevents):
//   - A TAG THAT LIES: `git tag v1.2.3` on a tree whose pubspec says 1.2.2
//     publishes assets whose file names, About dialog and dpkg/rpm version all
//     disagree with the release page. Irreversible once published — the tag and
//     the GitHub release are public the moment the workflow finishes.
//   - A STALE SOFTWARE-CENTRE VERSION: the AppStream <release> list is what
//     GNOME Software shows as "what's new". Releasing with the newest entry
//     behind pubspec advertises the previous version's notes forever.
//   - AN INCOMPLETE RELEASE: three assets (RPM, DEB, APK) plus SHA256SUMS. A
//     dropped asset means a platform silently gets no release at all, and a
//     missing checksum file leaves a sideloaded APK unverifiable.
//   - A DEBUG-SIGNED "RELEASE" APK: Play Services authorization identifies the
//     app by package name + signing SHA-1 (RFC-010). An APK signed with the
//     throwaway debug key cannot sign in on a device at all — and it would look
//     exactly like a working build until someone tried to. The fallback must
//     stay for local builds, but it must be LOUD.
//   - A LEAKED SIGNING KEY: key.properties and any keystore must be ignored by
//     git; committing one hands over the ability to ship a malicious update.
//   - NO INSTALL INSTRUCTIONS: three assets nobody knows what to do with.
//
// Pure file reads plus the guard script run against a throwaway tree — no
// clock, no network, no build.
@Tags(['packaging'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _appId = 'io.github.illyayalovyy.axiotask';
const _metainfoPath = 'linux/packaging/$_appId.metainfo.xml';
const _workflowPath = '.github/workflows/release.yml';
const _gradlePath = 'android/app/build.gradle.kts';

String _pubspecVersion() {
  final line = File(
    'pubspec.yaml',
  ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
  return line.substring('version:'.length).trim().split('+').first;
}

/// A throwaway copy of the three files the guard reads, so its failure paths
/// can be exercised without editing the repository.
Directory _guardTree() {
  final d = Directory.systemTemp.createTempSync('axiotask_guard_');
  Directory('${d.path}/tool').createSync();
  Directory('${d.path}/linux/packaging').createSync(recursive: true);
  File('tool/release_guard.sh').copySync('${d.path}/tool/release_guard.sh');
  File('pubspec.yaml').copySync('${d.path}/pubspec.yaml');
  File(_metainfoPath).copySync('${d.path}/$_metainfoPath');
  return d;
}

ProcessResult _guard(Directory tree, List<String> args) => Process.runSync(
  'bash',
  ['tool/release_guard.sh', ...args],
  workingDirectory: tree.path,
);

void main() {
  group('tool/release_guard.sh (the tag is checked before anything is built)', () {
    late Directory tree;

    setUp(() => tree = _guardTree());
    tearDown(() => tree.deleteSync(recursive: true));

    test('the tag matching pubspec passes', () {
      final r = _guard(tree, ['v${_pubspecVersion()}']);
      expect(
        r.exitCode,
        0,
        reason:
            'the repository as committed must be releasable: ${r.stdout}${r.stderr}',
      );
    });

    test('a tag ahead of pubspec is refused, naming both versions', () {
      final r = _guard(tree, ['v9.9.9']);
      expect(r.exitCode, isNot(0));
      final out = '${r.stdout}${r.stderr}';
      expect(out, contains('9.9.9'));
      expect(
        out,
        contains(_pubspecVersion()),
        reason: 'the message must say what the pubspec version actually is',
      );
    });

    test('a tag without the v prefix is refused', () {
      final r = _guard(tree, [_pubspecVersion()]);
      expect(
        r.exitCode,
        isNot(0),
        reason:
            'the workflow triggers on v*; a bare version tag would never have '
            'run it, so accepting one here would hide a mistake',
      );
    });

    test('no tag at all is refused', () {
      expect(_guard(tree, []).exitCode, isNot(0));
    });

    test('a metainfo whose newest <release> lags pubspec is refused', () {
      final f = File('${tree.path}/$_metainfoPath');
      f.writeAsStringSync(
        f.readAsStringSync().replaceFirst(
          'version="${_pubspecVersion()}"',
          'version="0.9.0"',
        ),
      );
      final r = _guard(tree, ['v${_pubspecVersion()}']);
      expect(r.exitCode, isNot(0));
      expect(
        '${r.stdout}${r.stderr}',
        contains('metainfo'),
        reason: 'the failure must point at the file that is stale',
      );
    });

    test('a metainfo advertising a version ABOVE pubspec is refused', () {
      final f = File('${tree.path}/$_metainfoPath');
      f.writeAsStringSync(
        f.readAsStringSync().replaceFirst(
          '<releases>',
          '<releases>\n    <release version="2.0.0" date="2026-09-07">\n'
              '      <description><p>Unreleased.</p></description>\n'
              '    </release>',
        ),
      );
      final r = _guard(tree, ['v${_pubspecVersion()}']);
      expect(
        r.exitCode,
        isNot(0),
        reason:
            'a release entry newer than the tag means the software centre '
            'advertises a version that was never published',
      );
    });
  });

  group('.github/workflows/release.yml', () {
    late String wf;

    setUpAll(() {
      expect(
        File(_workflowPath).existsSync(),
        isTrue,
        reason: 'the release workflow is the only way a release is produced',
      );
      // COMMENTS STRIPPED. This file explains itself at length, and a promise
      // in a comment ("we run lintian", "the guard runs first") must never be
      // what satisfies an assertion here — only a step that actually runs.
      wf = File(_workflowPath)
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('#'))
          .join('\n');
    });

    test('runs on v* tags and may write releases', () {
      expect(wf, contains('tags:'));
      expect(wf, matches(RegExp(r"-\s*'?v\*'?")));
      expect(
        wf,
        contains('contents: write'),
        reason: 'creating a release needs write permission on contents',
      );
    });

    test('checks the tag against pubspec BEFORE building anything', () {
      final guardAt = wf.indexOf('release_guard.sh');
      expect(
        guardAt,
        isNonNegative,
        reason: 'the workflow must run the version guard',
      );
      for (final build in [
        'flutter build linux --release',
        'build_rpm.sh',
        'build_deb.sh',
        'flutter build apk --release',
      ]) {
        final at = wf.indexOf(build);
        expect(at, isNonNegative, reason: 'the workflow never runs: $build');
        expect(
          at,
          greaterThan(guardAt),
          reason:
              'a failed guard must abort before $build — publishing is not '
              'reversible',
        );
      }
    });

    test('builds both Linux packages from the ONE release bundle', () {
      for (final script in ['build_rpm.sh', 'build_deb.sh']) {
        expect(
          wf,
          matches(RegExp('$script[^\n]*--bundle')),
          reason:
              '$script must package the bundle already built in this run, not '
              'rebuild it (a second build is a second, unverified binary)',
        );
      }
    });

    test('the desktop build gets the OAuth credentials from a secret', () {
      expect(
        wf,
        contains('secrets.AXIOTASK_GOOGLE_CLIENT_ID'),
        reason: 'the client id/secret may never be committed',
      );
      final writeAt = wf.indexOf('> tool/oauth_credentials.json');
      expect(
        writeAt,
        isNonNegative,
        reason:
            'tool/oauth_defines.sh compiles the credentials in from this file; '
            'without it the released RPM/DEB cannot sign in out of the box',
      );
      expect(
        writeAt,
        lessThan(wf.indexOf('flutter build linux --release')),
        reason: 'the file has to exist before the desktop build reads it',
      );
    });

    test('the APK build never sees the desktop client secret', () {
      // Android has NO client credentials of its own: Play Services identifies
      // the app by package name + signing SHA-1 (RFC-010). Compiling the
      // desktop secret into the APK would put a credential nothing there can
      // use into every installed copy.
      final removeAt = wf.indexOf('rm -f tool/oauth_credentials.json');
      final apkAt = wf.indexOf('flutter build apk --release');
      expect(
        removeAt,
        isNonNegative,
        reason:
            'the workflow must delete the desktop credentials file before it '
            'builds the APK',
      );
      expect(removeAt, lessThan(apkAt));
    });

    test('the .deb is checked by lintian and installed in ubuntu:24.04', () {
      expect(
        wf,
        matches(RegExp(r'lintian[^\n]*--fail-on')),
        reason:
            'lintian without --fail-on exits 0 on every warning it prints, '
            'which is the same as not running it',
      );
      expect(
        wf,
        contains('ubuntu:24.04'),
        reason:
            'the pinned Depends are a claim about a real distribution; the '
            'only proof is apt installing the package on it',
      );
    });

    test('publishes exactly the three assets plus SHA256SUMS', () {
      expect(
        wf,
        contains('softprops/action-gh-release'),
        reason: 'the ratified publishing action',
      );
      expect(wf, contains('SHA256SUMS'));
      for (final ext in ['.rpm', '.deb', '.apk']) {
        expect(
          wf,
          contains(ext),
          reason: 'the release must carry a $ext asset',
        );
      }
      expect(
        wf,
        contains('generate_release_notes: true'),
        reason: 'the notes come from the commits since the previous tag',
      );
    });

    test('a missing signing secret fails the release instead of shipping a '
        'debug-signed APK', () {
      expect(
        wf,
        contains('ANDROID_KEYSTORE'),
        reason: 'the release APK is signed from repository secrets',
      );
      expect(
        wf,
        anyOf(contains('exit 1'), contains('::error')),
        reason:
            'the workflow must refuse to publish rather than fall back to the '
            'debug key — a debug-signed APK cannot sign in (RFC-010)',
      );
    });
  });

  group('Android release signing (android/app/build.gradle.kts)', () {
    late String gradle;

    setUpAll(() => gradle = File(_gradlePath).readAsStringSync());

    test('key.properties is git-ignored (never committed)', () {
      final r = Process.runSync('git', [
        'check-ignore',
        'android/key.properties',
      ]);
      expect(
        r.exitCode,
        0,
        reason:
            'android/key.properties holds the keystore password; it must be '
            'ignored, not merely absent',
      );
    });

    test('no keystore is tracked in the repository', () {
      final tracked = (Process.runSync('git', ['ls-files']).stdout as String)
          .split('\n')
          .where(
            (f) =>
                f.endsWith('.jks') ||
                f.endsWith('.keystore') ||
                f.endsWith('key.properties'),
          );
      expect(
        tracked,
        isEmpty,
        reason: 'a committed signing key can never be un-published: $tracked',
      );
    });

    test('the release build type signs with the release key when present', () {
      expect(
        gradle,
        contains('key.properties'),
        reason: 'the signing material is read from the gitignored file',
      );
      expect(
        gradle,
        matches(RegExp(r'create\("release"\)')),
        reason: 'a release signingConfig must exist',
      );
      expect(
        gradle,
        isNot(contains('// TODO: Add your own signing config')),
        reason:
            'the Flutter template TODO is the marker of an unsigned release '
            'build; removing the TODO without wiring the config is worse',
      );
    });

    test('the debug fallback survives, and is LOUD', () {
      expect(
        gradle,
        contains('getByName("debug")'),
        reason:
            'a developer with no keystore must still be able to run '
            '`flutter run --release` locally',
      );
      expect(
        gradle,
        contains('logger.error('),
        reason:
            'falling back to the debug key silently is how a release APK that '
            'cannot sign in gets built and shipped — and Gradle\'s lifecycle '
            'and warn levels are BOTH invisible under a plain '
            '`flutter build apk --release` (verified: only -v showed them). '
            'Error level goes to stderr, which flutter does print.',
      );
      expect(
        gradle.toLowerCase(),
        contains('sha-1'),
        reason:
            'the warning must say WHY it matters: Play Services authorization '
            'keys on the signing certificate SHA-1',
      );
    });
  });

  group('README install instructions', () {
    late String readme;

    setUpAll(() => readme = File('README.md').readAsStringSync());

    test('documents installing each published asset', () {
      expect(
        readme,
        matches(RegExp(r'dnf install [^\n]*\.rpm')),
        reason: 'a local .rpm needs the file path form of dnf install',
      );
      expect(
        readme,
        matches(RegExp(r'apt install [^\n]*\.deb')),
        reason:
            'apt install ./file.deb is the form that resolves the Depends; '
            '`dpkg -i` leaves them unsatisfied',
      );
      expect(
        readme.toLowerCase(),
        contains('obtainium'),
        reason: 'the ratified update path for the sideloaded APK',
      );
      expect(readme, contains('SHA256SUMS'));
    });

    test('points at the releases page the workflow publishes to', () {
      expect(
        readme,
        contains('https://github.com/IllyaYalovyy/axiotask/releases'),
      );
    });
  });
}
