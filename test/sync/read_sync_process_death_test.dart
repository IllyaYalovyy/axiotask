import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'CRS-008 hard kill after page commit reopens incomplete publication',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-read-sync-hard-kill-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final databaseFile = File('${directory.path}/synthetic.sqlite');
      final process = await Process.start('dart', <String>[
        'run',
        'test/support/read_sync_crash_worker.dart',
        databaseFile.path,
      ], workingDirectory: Directory.current.path);
      addTearDown(() {
        if (process.kill(ProcessSignal.sigkill)) return;
      });
      final stderrBuffer = StringBuffer();
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .listen(stderrBuffer.write)
          .asFuture<void>();
      final boundary = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line == 'PAGE_COMMITTED')
          .timeout(const Duration(seconds: 30));

      await boundary;
      expect(process.kill(ProcessSignal.sigkill), isTrue);
      await process.exitCode.timeout(const Duration(seconds: 30));
      await stderrDone;

      final database = await AppDatabase.openFile(databaseFile);
      addTearDown(database.close);
      final accounts = await database.allAccounts();
      expect(accounts, hasLength(1));
      final account = AccountId(accounts.single.id);
      final snapshot = await DatabaseTasksRepository(
        database,
      ).watchTasks(TasksQuery(accountId: account)).first;
      final facts = await SyncHealthDao(database).watchFacts(account).first;

      expect(snapshot.taskLists.single.title, 'Committed process page');
      expect(snapshot.completeness, CacheCompleteness.incomplete);
      expect(facts.requiredScopeIncomplete, isTrue);
      expect(facts.lastSuccessfulSyncAt, isNull);
    },
  );
}
