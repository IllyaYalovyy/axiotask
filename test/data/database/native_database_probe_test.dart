import 'dart:io';

import 'package:axiotask/src/data/database/native_database_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('probe reports only synthetic non-secret database facts', () async {
    final root = await Directory.systemTemp.createTemp('axiotask-s02-probe-');
    addTearDown(() => root.delete(recursive: true));

    final result = await runNativeDatabaseProbe(
      File('${root.path}/probe.sqlite'),
    );
    final record = result.toRecord();

    expect(record, <String, Object>{
      'status': 'passed',
      'schemaVersion': 1,
      'accountCount': 1,
      'journalMode': 'wal',
      'foreignKeys': true,
      'synchronous': 'full',
      'busyTimeoutMs': 5000,
      'walAutoCheckpointPages': 1000,
      'sqliteVersion': result.sqliteVersion,
    });
    expect(record.values.join(' '), isNot(contains(root.path)));
    expect(record.values.join(' '), isNot(contains('synthetic-probe-subject')));
  });
}
