import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'CRS-001/002 local transaction hard-kill is wholly absent or pending',
    () async {
      final before = await _killWorker('local_before_commit');
      await _withDatabase(before.databaseFile, (database, account) async {
        expect(await _count(database, 'task_lists'), 0);
        expect(await _count(database, 'desired_states'), 0);
      });

      final after = await _killWorker('local_after_commit', captureWal: true);
      expect(after.walBytes, isNotEmpty);
      expect(after.shmBytes, isNotEmpty);
      await _withDatabase(after.databaseFile, (database, account) async {
        expect(await _states(database, 'desired_states'), <String>['pending']);
        expect(await _count(database, 'task_lists'), 1);
      });
    },
  );

  test(
    'CRS-003/004/005 claim and response-before-ack recover uncertain',
    () async {
      for (final mode in <String>['run_after_begin', 'claim_in_flight']) {
        final killed = await _killWorker(mode);
        await _withDatabase(killed.databaseFile, (database, account) async {
          final recovery = await DatabaseReadSyncStore(database).recoverStartup(
            accountId: account,
            recoveredAt: DateTime.utc(2026, 8, 15, 13),
          );
          if (mode == 'run_after_begin') {
            expect(recovery.interruptedRuns, 1);
            expect(await _states(database, 'desired_states'), <String>[
              'pending',
            ]);
          } else {
            expect(recovery.recoveredAttempts, 1);
            expect(await _states(database, 'desired_state_attempts'), <String>[
              'uncertain',
            ]);
            expect(await _remoteIds(database), <String?>[null]);
          }
        });
      }
    },
  );

  test('CRS-006 and DUR-009 acknowledgement kill is all-or-nothing', () async {
    for (final mode in <String>[
      'ack_after_identity',
      'ack_after_base',
      'ack_before_commit',
    ]) {
      final killed = await _killWorker(mode);
      await _withDatabase(killed.databaseFile, (database, account) async {
        expect(await _states(database, 'desired_state_attempts'), <String>[
          'in_flight',
        ]);
        expect(await _remoteIds(database), <String?>[null]);
        expect(await _count(database, 'task_list_remote_bases'), 0);
      });
    }

    final committed = await _killWorker('ack_after_commit');
    await _withDatabase(committed.databaseFile, (database, account) async {
      expect(await _states(database, 'desired_state_attempts'), <String>[
        'confirmed',
      ]);
      expect(await _remoteIds(database), <String?>['remote-created-list']);
      expect(await _count(database, 'task_list_remote_bases'), 1);
      final base = await database
          .customSelect(
            'SELECT title, etag, observed_publication_id FROM task_list_remote_bases',
          )
          .getSingle();
      expect(base.data, <String, Object?>{
        'title': 'Canonical remote title',
        'etag': 'canonical-etag',
        'observed_publication_id': 'synthetic-observation',
      });
    });
  });

  test(
    'CRS-007 confirmed partial success resumes only the pending dependent',
    () async {
      final killed = await _killWorker('partial_acknowledgement');
      await _withDatabase(killed.databaseFile, (database, account) async {
        expect(await _states(database, 'desired_states'), <String>[
          'confirmed',
          'pending',
        ]);
        expect(await _states(database, 'desired_state_attempts'), <String>[
          'confirmed',
        ]);
        expect(await _remoteIds(database), <String?>['remote-created-list']);
        expect(await _taskRemoteIds(database), <String?>[null]);
        expect(await _count(database, 'desired_state_dependencies'), 1);
      });
    },
  );

  test(
    'CRS-008 partial page publication survives without completeness',
    () async {
      final before = await _killWorker('page_before_commit');
      await _withDatabase(before.databaseFile, (database, account) async {
        await DatabaseReadSyncStore(database).recoverStartup(
          accountId: account,
          recoveredAt: DateTime.utc(2026, 8, 15, 13),
        );
        expect(await _count(database, 'task_lists'), 0);
      });

      final after = await _killWorker('page_after_commit');
      await _withDatabase(after.databaseFile, (database, account) async {
        await DatabaseReadSyncStore(database).recoverStartup(
          accountId: account,
          recoveredAt: DateTime.utc(2026, 8, 15, 13),
        );
        expect(await _count(database, 'task_lists'), 1);
        final facts = await SyncHealthDao(database).watchFacts(account).first;
        expect(facts.requiredScopeIncomplete, isTrue);
        expect(facts.lastSuccessfulSyncAt, isNull);
      });
    },
  );

  test(
    'CRS-009/010 finalization is the only durable success boundary',
    () async {
      final before = await _killWorker('finalize_before_commit');
      await _withDatabase(before.databaseFile, (database, account) async {
        await DatabaseReadSyncStore(database).recoverStartup(
          accountId: account,
          recoveredAt: DateTime.utc(2026, 8, 15, 13),
        );
        expect(
          (await SyncHealthDao(
            database,
          ).watchFacts(account).first).lastSuccessfulSyncAt,
          isNull,
        );
      });

      final after = await _killWorker('finalize_after_commit');
      await _withDatabase(after.databaseFile, (database, account) async {
        final beforeRecovery = await SyncHealthDao(
          database,
        ).watchFacts(account).first;
        expect(
          beforeRecovery.lastSuccessfulSyncAt,
          DateTime.utc(2026, 8, 15, 12, 30),
        );
        await DatabaseReadSyncStore(database).recoverStartup(
          accountId: account,
          recoveredAt: DateTime.utc(2026, 8, 15, 13),
        );
        final afterRecovery = await SyncHealthDao(
          database,
        ).watchFacts(account).first;
        expect(
          afterRecovery.lastSuccessfulSyncAt,
          beforeRecovery.lastSuccessfulSyncAt,
        );
        expect(afterRecovery.followUpRequired, isTrue);
      });

      final stale = await _killWorker('stale_finalizer_after_rejection');
      await _withDatabase(stale.databaseFile, (database, account) async {
        expect(
          (await SyncHealthDao(
            database,
          ).watchFacts(account).first).lastSuccessfulSyncAt,
          isNull,
        );
        expect(await _runStates(database), <String>[
          'interrupted',
          'in_progress',
        ]);
      });
    },
  );

  test('CRS-011 killed recovery transaction retries idempotently', () async {
    final before = await _killWorker('recovery_before_commit');
    await _withDatabase(before.databaseFile, (database, account) async {
      expect(await _states(database, 'desired_state_attempts'), <String>[
        'in_flight',
      ]);
      final first = await DatabaseReadSyncStore(database).recoverStartup(
        accountId: account,
        recoveredAt: DateTime.utc(2026, 8, 15, 13),
      );
      final second = await DatabaseReadSyncStore(database).recoverStartup(
        accountId: account,
        recoveredAt: DateTime.utc(2026, 8, 15, 14),
      );
      expect(first.recoveredAttempts, 1);
      expect(second.recoveredAttempts, 0);
    });

    final after = await _killWorker('recovery_after_commit');
    await _withDatabase(after.databaseFile, (database, account) async {
      expect(await _states(database, 'desired_state_attempts'), <String>[
        'uncertain',
      ]);
      final repeated = await DatabaseReadSyncStore(database).recoverStartup(
        accountId: account,
        recoveredAt: DateTime.utc(2026, 8, 15, 14),
      );
      expect(repeated.interruptedRuns, 0);
      expect(repeated.recoveredAttempts, 0);
    });
  });
}

final class _KilledDatabase {
  const _KilledDatabase({
    required this.databaseFile,
    this.walBytes,
    this.shmBytes,
  });

  final File databaseFile;
  final List<int>? walBytes;
  final List<int>? shmBytes;
}

Future<_KilledDatabase> _killWorker(
  String mode, {
  bool captureWal = false,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'axiotask-process-death-$mode-',
  );
  addTearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });
  final databaseFile = File('${directory.path}/synthetic.sqlite');
  final process = await Process.start('dart', <String>[
    'run',
    'test/support/process_death_worker.dart',
    mode,
    databaseFile.path,
  ], workingDirectory: Directory.current.path);
  final stderr = StringBuffer();
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .listen(stderr.write)
      .asFuture<void>();
  try {
    await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line == 'DURABLE_BOUNDARY')
        .timeout(const Duration(seconds: 30));
  } on Object {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await stderrDone;
    fail('Worker $mode did not reach its boundary: $stderr');
  }
  expect(process.kill(ProcessSignal.sigkill), isTrue);
  await process.exitCode.timeout(const Duration(seconds: 30));
  await stderrDone;
  final wal = File('${databaseFile.path}-wal');
  final shm = File('${databaseFile.path}-shm');
  return _KilledDatabase(
    databaseFile: databaseFile,
    walBytes: captureWal && wal.existsSync() ? wal.readAsBytesSync() : null,
    shmBytes: captureWal && shm.existsSync() ? shm.readAsBytesSync() : null,
  );
}

Future<void> _withDatabase(
  File file,
  Future<void> Function(AppDatabase database, AccountId account) verify,
) async {
  final database = await AppDatabase.openFile(file);
  try {
    final accounts = await database.allAccounts();
    expect(accounts, hasLength(1));
    await verify(database, AccountId(accounts.single.id));
  } finally {
    await database.close();
  }
}

Future<int> _count(AppDatabase database, String table) async =>
    (await database
            .customSelect('SELECT COUNT(*) AS count FROM $table')
            .getSingle())
        .read<int>('count');

Future<List<String>> _states(AppDatabase database, String table) async =>
    (await database.customSelect('SELECT state FROM $table ORDER BY id').get())
        .map((row) => row.read<String>('state'))
        .toList(growable: false);

Future<List<String>> _runStates(AppDatabase database) async =>
    (await database
            .customSelect('SELECT state FROM sync_runs ORDER BY started_at')
            .get())
        .map((row) => row.read<String>('state'))
        .toList(growable: false);

Future<List<String?>> _remoteIds(AppDatabase database) async =>
    (await database
            .customSelect('SELECT remote_id FROM task_lists ORDER BY id')
            .get())
        .map((row) => row.readNullable<String>('remote_id'))
        .toList(growable: false);

Future<List<String?>> _taskRemoteIds(AppDatabase database) async =>
    (await database
            .customSelect('SELECT remote_id FROM tasks ORDER BY id')
            .get())
        .map((row) => row.readNullable<String>('remote_id'))
        .toList(growable: false);
