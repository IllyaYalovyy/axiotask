import 'dart:io';

import 'package:axiotask/src/data/backup/local_account_backup_exporter.dart';
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

final class _Picker implements AccountBackupSaveLocationPicker {
  const _Picker(this.path);

  final String? path;

  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async =>
      path;
}
