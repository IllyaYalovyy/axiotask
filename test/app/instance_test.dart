import 'dart:io';

import 'package:axiotask/src/app/instance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('app dir name', () {
    test('default and prefixed', () {
      expect(appDirNameFor(null), 'axiotask');
      expect(appDirNameFor('dev'), 'axiotask-dev');
      expect(appDirNameFor('qa_2'), 'axiotask-qa_2');
    });
  });

  group('prefix validation', () {
    test('accepts safe names', () {
      expect(prefixError('dev'), isNull);
      expect(prefixError('Test-1_b'), isNull);
      expect(sanitizePrefix('Test-1_b'), 'Test-1_b');
    });

    test(
      'rejects unsafe names — empty, traversal, separators, over-length',
      () {
        // A malformed prefix must never resolve to a usable directory name: it
        // would silently point an isolated instance at production data.
        expect(prefixError(''), isNotNull);
        expect(prefixError('../prod'), isNotNull);
        expect(prefixError('a/b'), isNotNull);
        expect(prefixError(r'a\b'), isNotNull);
        expect(prefixError('with space'), isNotNull);
        expect(prefixError('dot.dot'), isNotNull);
        expect(prefixError('x' * 65), isNotNull);
      },
    );

    test('sanitizePrefix throws on an invalid prefix', () {
      expect(() => sanitizePrefix('../prod'), throwsArgumentError);
    });
  });

  group('instancePrefix (dev-mode data isolation)', () {
    test('unset → null (production instance)', () {
      expect(instancePrefix(env: const {}), isNull);
    });

    test('blank/whitespace → null, not a "" prefix', () {
      expect(instancePrefix(env: const {instanceEnv: '   '}), isNull);
    });

    test('a set prefix is trimmed and returned', () {
      expect(instancePrefix(env: const {instanceEnv: ' dev '}), 'dev');
    });

    test('an invalid prefix throws rather than falling back to production', () {
      // The whole point of isolation: never silently resolve to prod data.
      expect(
        () => instancePrefix(env: const {instanceEnv: 'a/b'}),
        throwsArgumentError,
      );
    });
  });

  group('instance-aware path layout', () {
    final base = Directory(p.join('x', 'data'));

    test('db/config/prefs all sit under base/<app-dir>/', () {
      const env = <String, String>{};
      final db = dbPathIn(base, env: env);
      final cfg = configPathIn(base, env: env);
      final prefs = prefsPathIn(base, env: env);

      for (final f in [db, cfg, prefs]) {
        expect(p.isWithin(base.path, f.path), isTrue);
        expect(p.basename(p.dirname(f.path)), 'axiotask');
      }
      expect(p.basename(db.path), 'axiotask.sqlite');
      expect(p.basename(cfg.path), 'config.json');
      expect(p.basename(prefs.path), 'prefs.json');
    });

    test('a prefix namespaces the whole subtree (isolation)', () {
      const env = {instanceEnv: 'dev'};
      expect(
        p.basename(p.dirname(dbPathIn(base, env: env).path)),
        'axiotask-dev',
      );
      expect(
        p.basename(p.dirname(configPathIn(base, env: env).path)),
        'axiotask-dev',
      );
      expect(
        p.basename(p.dirname(prefsPathIn(base, env: env).path)),
        'axiotask-dev',
      );
    });
  });
}
