// Token-store tests — the ports of `store.rs`'s round-trip cases plus the three
// enumerated `FileTokenStore` tests from `state.rs`. What they protect: the
// tokens the user's session depends on survive a process restart intact, a
// logout actually removes them from disk, a first save into a fresh data dir
// works, and (Q4) the file is not readable by other local users.

import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/logging.dart';
import 'package:axiotask/src/auth/auth_error.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A [File] whose delete always fails while it still reports as existing —
/// models a token file that cannot be unlinked on sign-out (a permission or IO
/// error), so [FileTokenStore.clear] must not silently claim success. Only the
/// members `clear` touches are implemented; the rest are unreachable here.
class _UndeletableFile implements File {
  @override
  String get path => '/does-not-matter/tokens.json';
  @override
  bool existsSync() => true;
  @override
  void deleteSync({bool recursive = false}) =>
      throw const FileSystemException('permission denied');
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'unexpected File member: ${invocation.memberName}',
  );
}

StoredTokens sampleTokens() => const StoredTokens(
  accessToken: 'at-123',
  refreshToken: 'rt-456',
  accessExpiresAt: 1700000000,
  scope: 'https://www.googleapis.com/auth/tasks',
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_token_test'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File tokensFile([String name = 'tokens.json']) =>
      File(p.join(tmp.path, name));

  group('StoredTokens serialization', () {
    test('round-trips through JSON preserving every field', () {
      final t = sampleTokens();
      final back = StoredTokens.fromJson(
        (jsonDecode(jsonEncode(t.toJson())) as Map).cast<String, Object?>(),
      );
      expect(back, t);
    });

    test('omits access_expires_at when unknown (serde skip parity)', () {
      const t = StoredTokens(accessToken: 'a', refreshToken: 'r');
      expect(t.toJson().containsKey('access_expires_at'), isFalse);
      // ...and a bundle with no expiry round-trips to a null expiry.
      final back = StoredTokens.fromJson(t.toJson());
      expect(back.accessExpiresAt, isNull);
      expect(back, t);
    });
  });

  group('InMemoryTokenStore', () {
    test('round-trips: empty, save, load, clear', () {
      final store = InMemoryTokenStore();
      expect(store.load(), isNull);
      store.save(sampleTokens());
      expect(store.load(), sampleTokens());
      store.clear();
      expect(store.load(), isNull);
    });
  });

  group('FileTokenStore', () {
    test('round-trips: absent → save → load', () {
      final store = FileTokenStore(tokensFile());
      expect(store.load(), isNull);
      store.save(sampleTokens());
      expect(store.load(), sampleTokens());
    });

    test('clear removes the file and load returns null', () {
      final file = tokensFile();
      final store = FileTokenStore(file);
      store.save(sampleTokens());
      expect(file.existsSync(), isTrue);
      store.clear();
      expect(file.existsSync(), isFalse);
      expect(store.load(), isNull);
    });

    test('save creates missing parent directories', () {
      final file = tokensFile(p.join('nested', 'dir', 'tokens.json'));
      final store = FileTokenStore(file);
      store.save(sampleTokens());
      expect(store.load(), sampleTokens());
    });

    test('written file is owner-only (0600) on POSIX', () {
      if (Platform.isWindows) return; // POSIX permission model only.
      final file = tokensFile();
      FileTokenStore(file).save(sampleTokens());
      // Low 9 bits (rwxrwxrwx) must be rw------- = 0600.
      expect(file.statSync().mode & 0x1FF, 0x180);
    });

    test('restricts to 0600 BEFORE any token content is written', () {
      if (Platform.isWindows) return; // POSIX permission model only.
      final file = tokensFile();
      int? bytesWhenRestricted;
      final store = FileTokenStore(
        file,
        chmod: (path) {
          // Observe the file exactly when permissions are applied: it must be
          // empty, so the refresh token never touches a world-readable file.
          bytesWhenRestricted = File(path).lengthSync();
          return Process.runSync('chmod', ['600', path]).exitCode;
        },
      );
      store.save(sampleTokens());
      expect(bytesWhenRestricted, 0);
      // ...and the landed file (now holding the tokens) is still 0600.
      expect(file.statSync().mode & 0x1FF, 0x180);
      expect(store.load(), sampleTokens());
    });

    test('save throws when the permission restriction fails', () {
      final file = tokensFile();
      // A chmod that reports a non-zero exit code: hardening failed, so the
      // refresh token must NOT be left sitting in an unrestricted file.
      final store = FileTokenStore(file, chmod: (_) => 1);
      expect(
        () => store.save(sampleTokens()),
        throwsA(isA<TokenStoreException>()),
      );
      // Nothing readable was left behind.
      expect(file.existsSync(), isFalse);
    });

    test('a malformed tokens.json surfaces a TokenStoreException', () {
      final file = tokensFile()..writeAsStringSync('{not json');
      expect(
        () => FileTokenStore(file).load(),
        throwsA(isA<TokenStoreException>()),
      );
    });

    test('clear logs a warning when the delete fails (G6 / #204)', () {
      // A delete that fails while the file still exists means the refresh token
      // is STILL on disk after logout. clear() stays best-effort (it does not
      // throw), but it must NOT succeed in silence — the leak has to be visible.
      final warnings = <String>[];
      Log.useSink((level, message) {
        if (level == LogLevel.warn) warnings.add(message);
      });
      addTearDown(Log.initLogging);

      // Does not throw — best-effort clear.
      FileTokenStore(_UndeletableFile()).clear();

      expect(warnings, hasLength(1), reason: 'the failed delete is logged');
      expect(
        warnings.single.toLowerCase(),
        contains('disk'),
        reason: 'the warning says a token may remain on disk',
      );
    });

    test('clear on an already-gone file is silent (no spurious warning)', () {
      final warnings = <String>[];
      Log.useSink((level, message) {
        if (level == LogLevel.warn) warnings.add(message);
      });
      addTearDown(Log.initLogging);

      // A never-saved store: the file does not exist, so clearing is a no-op and
      // must not warn about a nonexistent leak.
      FileTokenStore(tokensFile()).clear();

      expect(warnings, isEmpty);
    });

    test('a failed overwrite leaves the previous session intact (atomic save, '
        'G6 / #204)', () {
      final file = tokensFile();
      // A real session lands first.
      FileTokenStore(file).save(sampleTokens());
      expect(
        FileTokenStore(file).load(),
        sampleTokens(),
        reason: 'precondition',
      );

      // A second save whose permission lockdown fails must NOT clobber the file.
      // The atomic write stages into a temp and renames, so a mid-write failure
      // leaves the prior tokens.json fully intact rather than truncating it to
      // nothing (the old in-place write destroyed the live session here).
      const replacement = StoredTokens(
        accessToken: 'new-at',
        refreshToken: 'new-rt',
      );
      final failing = FileTokenStore(file, chmod: (_) => 1);
      expect(
        () => failing.save(replacement),
        throwsA(isA<TokenStoreException>()),
      );

      // The original session survives — not destroyed, not truncated.
      expect(FileTokenStore(file).load(), sampleTokens());
    });

    test('a successful save leaves no temp file behind (atomic rename)', () {
      final file = tokensFile();
      FileTokenStore(file).save(sampleTokens());

      final tmp = File('${file.path}.tmp');
      expect(
        tmp.existsSync(),
        isFalse,
        reason: 'the temp was renamed, not left',
      );
      expect(file.existsSync(), isTrue);
      expect(FileTokenStore(file).load(), sampleTokens());
    });
  });
}
