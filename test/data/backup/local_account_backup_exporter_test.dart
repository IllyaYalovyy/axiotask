import 'dart:io';

import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
import 'package:axiotask/src/domain/backup/account_backup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('axiotask-backup-test-');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('cancel leaves the filesystem unchanged', () async {
    final exporter = LocalAccountBackupExporter(const _Picker(null));

    final result = await exporter.save(
      suggestedName: 'axiotask-backup-v1.json',
      contents: '{"version":1}',
    );

    expect(result, const AccountBackupSaveResult.cancelled());
    expect(directory.listSync(), isEmpty);
  });

  test(
    'writes exact validated contents and reports only the file name',
    () async {
      final path = '${directory.path}${Platform.pathSeparator}selected.json';
      final exporter = LocalAccountBackupExporter(_Picker(path));

      final result = await exporter.save(
        suggestedName: 'axiotask-backup-v1.json',
        contents: '{"version":1}',
      );

      expect(result, const AccountBackupSaveResult.saved('selected.json'));
      expect(File(path).readAsStringSync(), '{"version":1}');
      expect(directory.listSync().whereType<File>().length, 1);
    },
  );

  test('import cancel reads nothing and is not a failure', () async {
    final importer = LocalAccountBackupImporter(const _OpenPicker(null));

    expect(await importer.open(), isA<AccountBackupOpenCancelled>());
    expect(directory.listSync(), isEmpty);
  });

  test('import reads exact UTF-8 and reports only the file name', () async {
    final path = '${directory.path}${Platform.pathSeparator}private.json';
    File(path).writeAsStringSync('{"title":"Synthetic ☕"}');

    final result =
        await LocalAccountBackupImporter(_OpenPicker(path)).open()
            as AccountBackupOpened;

    expect(result.fileName, 'private.json');
    expect(result.contents, '{"title":"Synthetic ☕"}');
  });

  test('import rejects oversized and malformed UTF-8 files', () async {
    final oversized = File('${directory.path}/oversized.json');
    oversized.openSync(mode: FileMode.write)
      ..truncateSync(maxAccountBackupBytes + 1)
      ..closeSync();
    await expectLater(
      LocalAccountBackupImporter(_OpenPicker(oversized.path)).open(),
      throwsA(
        isA<AccountBackupFormatException>().having(
          (error) => error.code,
          'code',
          'document_too_large',
        ),
      ),
    );

    final malformed = File('${directory.path}/malformed.json')
      ..writeAsBytesSync(<int>[0xff, 0xfe]);
    await expectLater(
      LocalAccountBackupImporter(_OpenPicker(malformed.path)).open(),
      throwsFormatException,
    );
  });

  test(
    'file failure propagates and removes the sibling temporary file',
    () async {
      final target = Directory('${directory.path}/target');
      target.createSync();
      final exporter = LocalAccountBackupExporter(_Picker(target.path));

      await expectLater(
        exporter.save(
          suggestedName: 'axiotask-backup-v1.json',
          contents: '{"version":1}',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('${target.path}.next').existsSync(), isFalse);
    },
  );
}

final class _OpenPicker implements AccountBackupOpenLocationPicker {
  const _OpenPicker(this.path);

  final String? path;

  @override
  Future<String?> chooseOpenLocation() async => path;
}

final class _Picker implements AccountBackupSaveLocationPicker {
  const _Picker(this.path);

  final String? path;

  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async =>
      path;
}
