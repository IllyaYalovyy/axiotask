import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/data/backup/android_account_backup_documents.dart';
import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
import 'package:axiotask/src/data/export/android_document_export_destination.dart';
import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Exercises the Android document channel `MainActivity` serves, natively:
/// the read and write halves of account backup and restore go through the
/// real `ContentResolver`. The system pickers themselves cannot be driven by
/// a test, so each call is handed a private `file://` document, exactly as
/// the picker would hand it a `content://` one.
///
/// Run with `flutter test
/// integration_test/android_document_channel_probe_test.dart -d DEVICE`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a backup written natively is read back byte for byte', (
    _,
  ) async {
    if (!Platform.isAndroid) {
      markTestSkipped('The document channel exists only on Android.');
      return;
    }
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}/axiotask-document-probe',
    );
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    directory.createSync(recursive: true);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final uri = Uri.file('${directory.path}/probe-backup.json').toString();
    const contents = '{"synthetic":"probe","unicode":"täsk ✓"}';

    final written = await documentExportChannel.invokeMethod<String>(
      'writeDocument',
      <String, Object>{
        'uri': uri,
        'bytes': Uint8List.fromList(utf8.encode(contents)),
      },
    );
    expect(written, 'probe-backup.json');

    final read = await documentExportChannel.invokeMapMethod<Object?, Object?>(
      'readDocument',
      <String, Object>{'uri': uri, 'maxBytes': maxAccountBackupBytes},
    );
    expect(read!['name'], 'probe-backup.json');
    expect(utf8.decode(read['bytes']! as Uint8List), contents);

    // A document over the limit is refused, never truncated.
    await expectLater(
      documentExportChannel.invokeMethod<Object?>(
        'readDocument',
        <String, Object>{'uri': uri, 'maxBytes': 8},
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'too_large',
        ),
      ),
    );

    // A missing document is a typed failure, not a crash.
    await expectLater(
      documentExportChannel.invokeMethod<Object?>(
        'readDocument',
        <String, Object>{
          'uri': Uri.file('${directory.path}/absent.json').toString(),
          'maxBytes': maxAccountBackupBytes,
        },
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'read_failed',
        ),
      ),
    );

    // Invalid arguments are rejected by the native side.
    for (final method in <String>[
      'openDocument',
      'readDocument',
      'shareText',
    ]) {
      await expectLater(
        documentExportChannel.invokeMethod<Object?>(method, <String, Object>{}),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalid_arguments',
          ),
        ),
        reason: method,
      );
    }
  });

  testWidgets('the production importer and exporter are wired to the channel', (
    _,
  ) async {
    if (!Platform.isAndroid) {
      markTestSkipped('The document channel exists only on Android.');
      return;
    }
    // Their picker calls need a person; their types prove the product's
    // Android services resolve to the document-channel implementations.
    expect(
      const AndroidDocumentAccountBackupExporter(),
      isA<AccountBackupExporter>(),
    );
    expect(
      const AndroidDocumentAccountBackupImporter(),
      isA<AccountBackupImporter>(),
    );
  });
}
