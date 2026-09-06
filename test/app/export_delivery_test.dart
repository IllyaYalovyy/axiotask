// How an export LEAVES the app (#297) — the platform seams behind the export
// sheet's three buttons.
//
// The plugin calls themselves (share_plus' share sheet, file_selector's save
// dialog) cannot run on the host VM, so each is one injected function; what is
// tested here is everything around them, which is where the failures a user
// would actually meet live:
//
//   • Save writes the document to the path the user picked — the whole point of
//     the button; a save that opens a dialog and writes nothing is the bug.
//   • A cancelled dialog writes NOTHING and reports nothing saved (a dismissed
//     picker must not leave a stray file, nor claim success).
//   • A path typed without an extension still produces a .md/.csv file — GTK's
//     save dialog does not append one.
//   • Android hands Markdown to the share sheet as TEXT (so it pastes into a
//     chat) and CSV as a FILE whose bytes are the document (so a spreadsheet
//     app can open it) — and the temp file is named the way the export is.
//   • Copy puts the document on the real system clipboard (asserted through the
//     platform channel, not a spy).

import 'dart:io';

import 'package:axiotask/src/app/export_delivery.dart';
import 'package:axiotask/src/app/task_export.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _markdownDoc = ExportDocument(
  title: 'Groceries',
  fileName: 'axiotask-groceries-20260615.md',
  format: ExportFormat.markdown,
  text: '# Groceries\n\n- [ ] Buy milk\n',
  taskCount: 1,
);

const _csvDoc = ExportDocument(
  title: 'Groceries',
  fileName: 'axiotask-groceries-20260615.csv',
  format: ExportFormat.csv,
  text:
      'title,list,due,status,completed_at,notes,parent_title\nBuy milk,'
      'Groceries,,needsAction,,,\n',
  taskCount: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask-export'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('desktop — save to a picked file', () {
    test('writes the document where the user pointed the dialog', () async {
      final target = p.join(tmp.path, 'notes', 'groceries.md');
      final delivery = FileExportDelivery(picker: (doc) async => target);

      final written = await delivery.save(_markdownDoc);

      expect(written, target);
      expect(File(target).readAsStringSync(), _markdownDoc.text);
    });

    test(
      'a dismissed dialog writes no file and reports nothing saved',
      () async {
        final delivery = FileExportDelivery(picker: (doc) async => null);

        expect(await delivery.save(_csvDoc), isNull);
        expect(tmp.listSync(), isEmpty);
      },
    );

    test('a path typed without an extension still gets one', () async {
      final delivery = FileExportDelivery(
        picker: (doc) async => p.join(tmp.path, 'groceries'),
      );

      final written = await delivery.save(_csvDoc);

      expect(written, p.join(tmp.path, 'groceries.csv'));
      expect(File(written!).readAsStringSync(), _csvDoc.text);
    });

    test('the dialog is offered the export as its suggested name', () async {
      ExportDocument? asked;
      final delivery = FileExportDelivery(
        picker: (doc) async {
          asked = doc;
          return p.join(tmp.path, doc.fileName);
        },
      );

      await delivery.save(_markdownDoc);

      expect(asked?.fileName, 'axiotask-groceries-20260615.md');
      expect(delivery.canSave, isTrue);
      expect(delivery.canShare, isFalse);
    });
  });

  group('Android — hand it to the share sheet', () {
    test('Markdown goes as text, with no file attached', () async {
      ShareRequest? sent;
      final delivery = ShareExportDelivery(
        sharer: (r) async => sent = r,
        tempDir: () async => tmp,
      );

      await delivery.share(_markdownDoc);

      expect(sent?.text, _markdownDoc.text);
      expect(sent?.filePath, isNull);
      expect(sent?.subject, 'Groceries');
      expect(tmp.listSync(), isEmpty, reason: 'text needs no temp file');
    });

    test(
      'CSV goes as a file holding the document, named for the export',
      () async {
        ShareRequest? sent;
        final delivery = ShareExportDelivery(
          sharer: (r) async => sent = r,
          tempDir: () async => tmp,
        );

        await delivery.share(_csvDoc);

        expect(sent?.text, isNull);
        expect(p.basename(sent!.filePath!), 'axiotask-groceries-20260615.csv');
        expect(File(sent!.filePath!).readAsStringSync(), _csvDoc.text);
        expect(sent?.mimeType, 'text/csv');
      },
    );

    test('offers sharing and not saving', () {
      final delivery = ShareExportDelivery(
        sharer: (r) async {},
        tempDir: () async => tmp,
      );

      expect(delivery.canShare, isTrue);
      expect(delivery.canSave, isFalse);
      expect(() => delivery.save(_csvDoc), throwsUnsupportedError);
    });
  });

  group('copy', () {
    test('puts the document text on the system clipboard', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await FileExportDelivery(picker: (doc) async => null).copy(_markdownDoc);

      final set = calls.singleWhere((c) => c.method == 'Clipboard.setData');
      expect((set.arguments as Map)['text'], _markdownDoc.text);
    });
  });
}
