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

    test('sync defaults: push OFF, auto-sync ON', () {
      const s = SyncConfig();
      expect(s.pushEnabled, isFalse);
      expect(s.autoSyncOnStart, isTrue);
    });

    test('the embedded default JSON parses back to the defaults', () {
      final parsed = AppConfig.fromJson(
        (jsonDecode(AppConfig.defaultJson()) as Map).cast<String, Object?>(),
      );
      expect(parsed.google.clientId, isEmpty);
      expect(parsed.sync.pushEnabled, isFalse);
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
          'sync': {'push_enabled': false, 'auto_sync_on_start': false},
        }),
      );
      final c = AppConfig.loadFrom(cfg())!;
      expect(c.google.clientId, 'my-id');
      expect(c.google.clientSecret, 'my-secret');
      expect(c.sync.pushEnabled, isFalse);
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

  group('writeDefaultIfMissingAt', () {
    test('creates the file (and parent) when missing', () {
      final nested = File(p.join(tmp.path, 'axiotask', 'config.json'));
      expect(nested.existsSync(), isFalse);
      AppConfig.writeDefaultIfMissingAt(nested);
      expect(nested.existsSync(), isTrue);
      final loaded = AppConfig.loadFrom(nested)!;
      expect(loaded.sync.pushEnabled, isFalse);
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
      AppConfig.saveSyncTo(
        cfg(),
        const SyncConfig(pushEnabled: true, autoSyncOnStart: false),
      );
      final c = AppConfig.loadFrom(cfg())!;
      expect(c.sync.pushEnabled, isTrue);
      expect(c.sync.autoSyncOnStart, isFalse);
    });

    test('preserves the google credentials already on disk', () {
      cfg().writeAsStringSync(
        jsonEncode({
          'google': {'client_id': 'keep-me', 'client_secret': 'secret-too'},
          'sync': {'push_enabled': false},
        }),
      );
      AppConfig.saveSyncTo(cfg(), const SyncConfig(pushEnabled: true));
      final c = AppConfig.loadFrom(cfg())!;
      expect(c.google.clientId, 'keep-me');
      expect(c.google.clientSecret, 'secret-too');
      expect(c.sync.pushEnabled, isTrue);
    });

    test('creates the file from defaults when missing', () {
      final nested = File(p.join(tmp.path, 'nested', 'config.json'));
      AppConfig.saveSyncTo(nested, const SyncConfig(pushEnabled: true));
      expect(nested.existsSync(), isTrue);
      expect(AppConfig.loadFrom(nested)!.sync.pushEnabled, isTrue);
    });
  });

  group('ConfigController persist-first (#171)', () {
    test('setPushEnabled persists then flips the in-memory value', () async {
      final c = ConfigController(path: cfg(), initial: const AppConfig());
      expect(c.pushEnabled, isFalse);
      await c.setPushEnabled(true);
      expect(c.pushEnabled, isTrue);
      // The durable write happened, not just the memory flip.
      expect(AppConfig.loadFrom(cfg())!.sync.pushEnabled, isTrue);
    });

    test('setPushEnabled does NOT flip when the config write fails', () async {
      // Point the controller at a path that is a DIRECTORY: writing the file
      // throws, so the in-memory toggle must stay put (#171).
      final blocked = File(p.join(tmp.path, 'blocked'));
      Directory(blocked.path).createSync();
      final c = ConfigController(path: blocked, initial: const AppConfig());

      await expectLater(
        c.setPushEnabled(true),
        throwsA(isA<FileSystemException>()),
      );
      expect(c.pushEnabled, isFalse, reason: 'write failed → no flip');
    });

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
