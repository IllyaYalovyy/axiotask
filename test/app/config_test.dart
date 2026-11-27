import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(
    () => tmp = Directory.systemTemp.createTempSync('axiotask_config_test'),
  );
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File cfg([String name = 'config.json']) => File(p.join(tmp.path, name));

  group('defaults', () {
    test('google defaults: empty creds, tasks scope only', () {
      const g = GoogleConfig();
      expect(g.clientId, isEmpty);
      expect(g.clientSecret, isEmpty);
      expect(g.scopes, [tasksScope]);
    });

    test('sync defaults: auto-sync ON', () {
      const s = SyncConfig();
      expect(s.autoSyncOnStart, isTrue);
    });

    test('the embedded default JSON parses back to the defaults', () {
      final parsed = AppConfig.fromJson(
        (jsonDecode(AppConfig.defaultJson()) as Map).cast<String, Object?>(),
      );
      expect(parsed.google.clientId, isEmpty);
      expect(parsed.sync.autoSyncOnStart, isTrue);
    });
  });

  group('loadFrom', () {
    test('missing file → null', () {
      expect(AppConfig.loadFrom(cfg('nope.json')), isNull);
    });

    test('valid JSON round-trips values', () {
      cfg().writeAsStringSync(
        jsonEncode({
          'google': {
            'client_id': 'my-id',
            'client_secret': 'my-secret',
            'scopes': [tasksScope],
          },
          'sync': {'auto_sync_on_start': false},
        }),
      );
      final c = AppConfig.loadFrom(cfg())!;
      expect(c.google.clientId, 'my-id');
      expect(c.google.clientSecret, 'my-secret');
      expect(c.sync.autoSyncOnStart, isFalse);
    });

    test('partial JSON keeps defaults for absent fields', () {
      cfg().writeAsStringSync(
        jsonEncode({
          'google': {'client_id': 'partial-id'},
        }),
      );
      final c = AppConfig.loadFrom(cfg())!;
      expect(c.google.clientId, 'partial-id');
      expect(c.google.clientSecret, isEmpty);
      expect(c.sync.autoSyncOnStart, isTrue); // default
    });

    test('malformed JSON → null (not a crash)', () {
      cfg().writeAsStringSync('{ this is not json');
      expect(AppConfig.loadFrom(cfg()), isNull);
    });
  });

  group('a config.json written by an earlier release', () {
    for (final retired in [true, false]) {
      test('with push_enabled: $retired loads, and loses the key once the app '
          'writes the file', () async {
        cfg().writeAsStringSync(
          jsonEncode({
            'google': {'client_id': 'keep-me'},
            'sync': {'push_enabled': retired, 'auto_sync_on_start': false},
          }),
        );

        final loaded = AppConfig.loadFrom(cfg())!;
        expect(loaded.google.clientId, 'keep-me');
        expect(loaded.sync.autoSyncOnStart, isFalse);

        await ConfigController.load(cfg()).setAutoSyncOnStart(true);

        final written = (jsonDecode(cfg().readAsStringSync()) as Map);
        expect(written['sync'], {'auto_sync_on_start': true});
        expect((written['google'] as Map)['client_id'], 'keep-me');
      });
    }

    test('the default file the app writes has no push_enabled', () {
      AppConfig.writeDefaultIfMissingAt(cfg());
      expect(cfg().readAsStringSync(), isNot(contains('push_enabled')));
    });
  });

  group('writeDefaultIfMissingAt', () {
    test('creates the file (and parent) when missing', () {
      final nested = File(p.join(tmp.path, 'axiotask', 'config.json'));
      expect(nested.existsSync(), isFalse);
      AppConfig.writeDefaultIfMissingAt(nested);
      expect(nested.existsSync(), isTrue);
      final loaded = AppConfig.loadFrom(nested)!;
      expect(loaded.sync.autoSyncOnStart, isTrue);
    });

    test('does not overwrite an existing file', () {
      const custom = '{"google":{"client_id":"keep"}}';
      cfg().writeAsStringSync(custom);
      AppConfig.writeDefaultIfMissingAt(cfg());
      expect(cfg().readAsStringSync(), custom);
    });
  });

  group('saveSyncTo (persist-first, #171)', () {
    test('round-trips toggled values', () {
      AppConfig.saveSyncTo(cfg(), const SyncConfig(autoSyncOnStart: false));
      final c = AppConfig.loadFrom(cfg())!;
      expect(c.sync.autoSyncOnStart, isFalse);
    });

    test('preserves the google credentials already on disk', () {
      cfg().writeAsStringSync(
        jsonEncode({
          'google': {'client_id': 'keep-me', 'client_secret': 'secret-too'},
          'sync': {'auto_sync_on_start': true},
        }),
      );
      AppConfig.saveSyncTo(cfg(), const SyncConfig(autoSyncOnStart: false));
      final c = AppConfig.loadFrom(cfg())!;
      expect(c.google.clientId, 'keep-me');
      expect(c.google.clientSecret, 'secret-too');
      expect(c.sync.autoSyncOnStart, isFalse);
    });

    test('creates the file from defaults when missing', () {
      final nested = File(p.join(tmp.path, 'nested', 'config.json'));
      AppConfig.saveSyncTo(nested, const SyncConfig(autoSyncOnStart: false));
      expect(nested.existsSync(), isTrue);
      expect(AppConfig.loadFrom(nested)!.sync.autoSyncOnStart, isFalse);
    });
  });

  group('ConfigController persist-first (#171)', () {
    test(
      'setAutoSyncOnStart does NOT flip when the config write fails',
      () async {
        final blocked = File(p.join(tmp.path, 'blocked2'));
        Directory(blocked.path).createSync();
        final c = ConfigController(path: blocked, initial: const AppConfig());
        expect(c.autoSyncOnStart, isTrue);

        await expectLater(
          c.setAutoSyncOnStart(false),
          throwsA(isA<FileSystemException>()),
        );
        expect(c.autoSyncOnStart, isTrue, reason: 'write failed → no flip');
      },
    );
  });
}
