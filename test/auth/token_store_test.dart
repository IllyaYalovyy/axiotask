// Token-store tests — the ports of `store.rs`'s round-trip cases plus the three
// enumerated `FileTokenStore` tests from `state.rs`. What they protect: the
// tokens the user's session depends on survive a process restart intact, a
// logout actually removes them from disk, a first save into a fresh data dir
// works, and (Q4) the file is not readable by other local users.

import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/auth/auth_error.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

    test('a malformed tokens.json surfaces a TokenStoreException', () {
      final file = tokensFile()..writeAsStringSync('{not json');
      expect(
        () => FileTokenStore(file).load(),
        throwsA(isA<TokenStoreException>()),
      );
    });
  });
}
