import 'dart:convert';

import 'package:axiotask/src/data/backup/android_account_backup_documents.dart';
import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
import 'package:axiotask/src/data/export/android_document_export_destination.dart';
import 'package:axiotask/src/data/export/android_view_export_share.dart';
import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:axiotask/src/domain/export/view_export.dart';
import 'package:axiotask/src/domain/repository/view_export_destination.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart side of the Android document channel `MainActivity` serves:
/// account backup export and restore (v1.5.3 parity on Android) and sharing
/// a view export. The native side is exercised on a device by
/// `integration_test/android_regression/`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall call) handler = (_) async => null;

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(documentExportChannel, (call) {
          calls.add(call);
          return handler(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(documentExportChannel, null);
  });

  group('backup export', () {
    const exporter = AndroidDocumentAccountBackupExporter();

    test('creates a JSON document and writes the whole backup', () async {
      handler = (call) async => switch (call.method) {
        'createDocument' => 'content://provider/backup',
        'writeDocument' => 'my-backup.json',
        _ => null,
      };

      final result = await exporter.save(
        suggestedName: 'axiotask-backup.json',
        contents: '{"private":"täsk"}',
      );

      expect(result, const AccountBackupSaveResult.saved('my-backup.json'));
      expect(calls.map((call) => call.method), <String>[
        'createDocument',
        'writeDocument',
      ]);
      final create = calls[0].arguments as Map<Object?, Object?>;
      expect(create['fileName'], 'axiotask-backup.json');
      expect(create['mimeType'], 'application/json');
      final write = calls[1].arguments as Map<Object?, Object?>;
      expect(write['uri'], 'content://provider/backup');
      expect(utf8.decode(write['bytes']! as Uint8List), '{"private":"täsk"}');
    });

    test('a dismissed picker writes nothing', () async {
      handler = (_) async => null;
      final result = await exporter.save(
        suggestedName: 'a.json',
        contents: '{}',
      );
      expect(result, const AccountBackupSaveResult.cancelled());
      expect(calls.map((call) => call.method), <String>['createDocument']);
    });

    test('a failed write discards the empty document and fails', () async {
      handler = (call) async {
        if (call.method == 'createDocument') return 'content://provider/x';
        if (call.method == 'writeDocument') {
          throw PlatformException(code: 'write_failed');
        }
        return true;
      };
      await expectLater(
        exporter.save(suggestedName: 'a.json', contents: '{}'),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.map((call) => call.method), <String>[
        'createDocument',
        'writeDocument',
        'discardDocument',
      ]);
    });
  });

  group('backup restore', () {
    const importer = AndroidDocumentAccountBackupImporter();

    test('opens the chosen document within the size limit', () async {
      handler = (call) async => switch (call.method) {
        'openDocument' => 'content://provider/chosen',
        'readDocument' => <String, Object?>{
          'name': 'chosen.json',
          'bytes': Uint8List.fromList(utf8.encode('{"tasks":["ü"]}')),
        },
        _ => null,
      };

      final result = await importer.open() as AccountBackupOpened;

      expect(result.fileName, 'chosen.json');
      expect(result.contents, '{"tasks":["ü"]}');
      final read = calls.last.arguments as Map<Object?, Object?>;
      expect(read['uri'], 'content://provider/chosen');
      expect(read['maxBytes'], maxAccountBackupBytes);
      final open = calls.first.arguments as Map<Object?, Object?>;
      expect(open['mimeTypes'], contains('application/json'));
    });

    test('a dismissed picker reads nothing', () async {
      handler = (_) async => null;
      expect(await importer.open(), isA<AccountBackupOpenCancelled>());
      expect(calls.map((call) => call.method), <String>['openDocument']);
    });

    test('an oversized document is refused, never truncated', () async {
      handler = (call) async {
        if (call.method == 'openDocument') return 'content://provider/huge';
        throw PlatformException(code: 'too_large');
      };
      await expectLater(
        importer.open(),
        throwsA(
          isA<AccountBackupFormatException>().having(
            (error) => error.code,
            'code',
            'document_too_large',
          ),
        ),
      );
    });

    test('bytes that are not UTF-8 are rejected', () async {
      handler = (call) async => call.method == 'openDocument'
          ? 'content://provider/binary'
          : <String, Object?>{
              'name': 'binary.json',
              'bytes': Uint8List.fromList(<int>[0xff, 0xfe, 0xfd]),
            };
      await expectLater(importer.open(), throwsA(isA<FormatException>()));
    });
  });

  group('share', () {
    const share = AndroidViewExportShare();
    const document = ViewExportDocument(
      title: 'Groceries',
      fileName: 'axiotask-groceries.md',
      format: ViewExportFormat.markdown,
      text: '# Groceries\n\n- [ ] Bread\n',
      taskCount: 1,
    );

    test('hands the document text and title to the share sheet', () async {
      handler = (_) async => true;
      await share.share(document);
      expect(calls.single.method, 'shareText');
      expect(calls.single.arguments, <String, Object?>{
        'subject': 'Groceries',
        'text': '# Groceries\n\n- [ ] Bread\n',
      });
    });

    test('an unavailable share sheet is a typed failure', () async {
      handler = (_) async => throw PlatformException(code: 'share_unavailable');
      await expectLater(
        share.share(document),
        throwsA(
          isA<ViewExportDestinationException>().having(
            (error) => error.failure,
            'failure',
            ViewExportFailure.pickerFailed,
          ),
        ),
      );
    });
  });
}
