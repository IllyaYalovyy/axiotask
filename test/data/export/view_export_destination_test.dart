import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/data/export/android_document_export_destination.dart';
import 'package:axiotask/src/data/export/file_view_export_destination.dart';
import 'package:axiotask/src/domain/export/view_export.dart';
import 'package:axiotask/src/domain/repository/view_export_destination.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const document = ViewExportDocument(
    title: 'Groceries',
    fileName: 'axiotask-groceries-20261115.csv',
    format: ViewExportFormat.csv,
    text: 'title,list\n"Eggs, ""12""",Привет 🥚\n',
    taskCount: 1,
  );

  group('Android document destination', () {
    late List<MethodCall> calls;
    late Future<Object?> Function(MethodCall call) handler;

    setUp(() {
      calls = <MethodCall>[];
      handler = (_) async => null;
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

    test('creates the document, then writes the UTF-8 bytes to it', () async {
      handler = (call) async => switch (call.method) {
        'createDocument' => 'content://downloads/document/7',
        'writeDocument' => 'groceries.csv',
        _ => throw StateError(call.method),
      };

      final result = await AndroidDocumentExportDestination().save(document);

      expect(result, const ViewExportSaved('groceries.csv'));
      expect(calls.map((call) => call.method), <String>[
        'createDocument',
        'writeDocument',
      ]);
      expect(calls.first.arguments, <String, Object>{
        'fileName': 'axiotask-groceries-20261115.csv',
        'mimeType': 'text/csv',
      });
      final write = calls.last.arguments as Map<Object?, Object?>;
      expect(write['uri'], 'content://downloads/document/7');
      expect(utf8.decode(write['bytes']! as List<int>), document.text);
    });

    test('a dismissed picker is a cancellation with nothing written', () async {
      handler = (call) async => null;

      final result = await AndroidDocumentExportDestination().save(document);

      expect(result, const ViewExportCancelled());
      expect(calls.map((call) => call.method), <String>['createDocument']);
    });

    test('a picker error is reported without writing', () async {
      handler = (call) async =>
          throw PlatformException(code: 'picker_unavailable');

      await expectLater(
        AndroidDocumentExportDestination().save(document),
        throwsA(
          isA<ViewExportDestinationException>().having(
            (error) => error.failure,
            'failure',
            ViewExportFailure.pickerFailed,
          ),
        ),
      );
      expect(calls.map((call) => call.method), <String>['createDocument']);
    });

    test('a write error discards the created document and fails', () async {
      handler = (call) async => switch (call.method) {
        'createDocument' => 'content://provider/doc/1',
        'writeDocument' => throw PlatformException(code: 'write_failed'),
        'discardDocument' => true,
        _ => throw StateError(call.method),
      };

      await expectLater(
        AndroidDocumentExportDestination().save(document),
        throwsA(
          isA<ViewExportDestinationException>()
              .having(
                (error) => error.failure,
                'failure',
                ViewExportFailure.writeFailed,
              )
              .having((error) => error.detail, 'detail', 'write_failed'),
        ),
      );
      expect(calls.map((call) => call.method), <String>[
        'createDocument',
        'writeDocument',
        'discardDocument',
      ]);
      expect(
        (calls.last.arguments as Map<Object?, Object?>)['uri'],
        'content://provider/doc/1',
      );
    });

    test('a failing discard still reports the write failure', () async {
      handler = (call) async => switch (call.method) {
        'createDocument' => 'content://provider/doc/1',
        _ => throw PlatformException(code: call.method),
      };

      await expectLater(
        AndroidDocumentExportDestination().save(document),
        throwsA(
          isA<ViewExportDestinationException>().having(
            (error) => error.failure,
            'failure',
            ViewExportFailure.writeFailed,
          ),
        ),
      );
    });

    test('a platform without the channel reports unavailable', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(documentExportChannel, null);

      await expectLater(
        AndroidDocumentExportDestination().save(document),
        throwsA(
          isA<ViewExportDestinationException>().having(
            (error) => error.failure,
            'failure',
            ViewExportFailure.unavailable,
          ),
        ),
      );
    });

    test('an injected picker replaces only the choice of location', () async {
      handler = (call) async => call.method == 'writeDocument' ? null : 'x';
      String? suggested;
      String? mime;

      final result = await AndroidDocumentExportDestination(
        picker: ({required suggestedName, required mimeType}) async {
          suggested = suggestedName;
          mime = mimeType;
          return 'file:///data/export.csv';
        },
      ).save(document);

      expect(suggested, document.fileName);
      expect(mime, 'text/csv');
      // A provider that reports no display name falls back to the file name.
      expect(result, ViewExportSaved(document.fileName));
      expect(calls.map((call) => call.method), <String>['writeDocument']);
    });
  });

  group('desktop file destination', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('view-export-test-');
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test('writes the exact text to the chosen path', () async {
      final path = '${directory.path}/chosen.csv';

      final result = await FileViewExportDestination(picker: (_) async => path)
          .save(document);

      expect(result, const ViewExportSaved('chosen.csv'));
      expect(await File(path).readAsString(), document.text);
      expect(directory.listSync().map((entry) => entry.path), <String>[
        path,
      ], reason: 'no temporary file is left behind');
    });

    test('appends the extension a typed name left out', () async {
      final result = await FileViewExportDestination(
        picker: (_) async => '${directory.path}/groceries',
      ).save(document);

      expect(result, const ViewExportSaved('groceries.csv'));
      expect(
        await File('${directory.path}/groceries.csv').readAsString(),
        document.text,
      );
    });

    test('a dismissed dialog writes nothing', () async {
      final result = await FileViewExportDestination(picker: (_) async => null)
          .save(document);

      expect(result, const ViewExportCancelled());
      expect(directory.listSync(), isEmpty);
    });

    test('an unwritable destination fails and leaves nothing behind', () async {
      final path = '${directory.path}/missing/dir/out.csv';

      await expectLater(
        FileViewExportDestination(picker: (_) async => path).save(document),
        throwsA(
          isA<ViewExportDestinationException>().having(
            (error) => error.failure,
            'failure',
            ViewExportFailure.writeFailed,
          ),
        ),
      );
      expect(directory.listSync(), isEmpty);
    });

    test('a failing dialog is a picker failure', () async {
      await expectLater(
        FileViewExportDestination(
          picker: (_) async => throw StateError('portal'),
        ).save(document),
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
