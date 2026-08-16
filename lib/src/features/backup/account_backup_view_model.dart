import 'package:flutter/foundation.dart';

import '../../core/clock.dart';
import '../../data/backup/local_account_backup_exporter.dart';
import '../../domain/backup/account_backup.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/account_backup_repository.dart';
import '../../sync/health/sync_health.dart';
import '../../sync/health/sync_health_repository.dart';

final class AccountBackupResult {
  const AccountBackupResult({
    required this.fileName,
    required this.listCount,
    required this.taskCount,
  });

  final String fileName;
  final int listCount;
  final int taskCount;
}

final class AccountBackupViewState {
  const AccountBackupViewState({
    this.isWorking = false,
    this.result,
    this.notice,
    this.error,
    this.importFileName,
    this.importPreview,
    this.importResult,
  });

  final bool isWorking;
  final AccountBackupResult? result;
  final String? notice;
  final String? error;
  final String? importFileName;
  final AccountBackupImportPreview? importPreview;
  final AccountBackupImportResult? importResult;
}

final class AccountBackupViewModel extends ChangeNotifier {
  AccountBackupViewModel({
    required this.accountId,
    required this.repository,
    required this.exporter,
    required this.clock,
    this.restoreRepository,
    this.importer,
    this.syncHealthRepository,
    this.importCommitted,
    this.codec = const AccountBackupCodec(),
  });

  final AccountId accountId;
  final AccountBackupRepository repository;
  final AccountBackupExporter exporter;
  final AccountBackupRestoreRepository? restoreRepository;
  final AccountBackupImporter? importer;
  final SyncHealthRepository? syncHealthRepository;
  final Future<void> Function()? importCommitted;
  final Clock clock;
  final AccountBackupCodec codec;
  AccountBackupViewState _state = const AccountBackupViewState();
  AccountBackupDocument? _pendingImport;

  AccountBackupViewState get state => _state;

  Future<void> export() async {
    if (_state.isWorking) return;
    _state = const AccountBackupViewState(isWorking: true);
    notifyListeners();
    try {
      final snapshot = await repository.readProjectedAccount(accountId);
      final now = clock.now().toUtc();
      final contents = codec.encode(snapshot, exportedAt: now);
      final result = await exporter.save(
        suggestedName: _suggestedName(now),
        contents: contents,
      );
      _state = switch (result) {
        AccountBackupSaveCancelled() => const AccountBackupViewState(
          notice: 'Export canceled. No backup file was written.',
        ),
        AccountBackupSaved(:final fileName) => AccountBackupViewState(
          result: AccountBackupResult(
            fileName: fileName,
            listCount: snapshot.lists.length,
            taskCount: snapshot.tasks.length,
          ),
        ),
      };
    } on Object {
      _state = const AccountBackupViewState(
        error: 'Could not export this account backup.',
      );
    }
    notifyListeners();
  }

  Future<void> chooseImport() async {
    if (_state.isWorking ||
        importer == null ||
        restoreRepository == null ||
        syncHealthRepository == null) {
      return;
    }
    _state = const AccountBackupViewState(isWorking: true);
    notifyListeners();
    try {
      final opened = await importer!.open();
      if (opened is AccountBackupOpenCancelled) {
        _state = const AccountBackupViewState(
          notice: 'Restore canceled. No task data was changed.',
        );
        notifyListeners();
        return;
      }
      final selected = opened as AccountBackupOpened;
      final document = codec.decode(selected.contents);
      final health = await syncHealthRepository!.watchHealth(accountId).first;
      final preview = await restoreRepository!.previewImport(
        accountId: accountId,
        document: document,
        readiness: _readiness(health),
        lastSuccessfulSyncAt: health.lastSuccessfulSyncAt,
      );
      _pendingImport = document;
      _state = AccountBackupViewState(
        importFileName: selected.fileName,
        importPreview: preview,
      );
    } on AccountBackupFormatException catch (error) {
      _state = AccountBackupViewState(
        error:
            'This backup file is not valid (${error.code}). Nothing changed.',
      );
    } on AccountBackupImportException catch (error) {
      _state = AccountBackupViewState(error: _importError(error.code));
    } on Object {
      _state = const AccountBackupViewState(
        error: 'Could not read this account backup. Nothing changed.',
      );
    }
    notifyListeners();
  }

  Future<void> restore() async {
    final document = _pendingImport;
    if (_state.isWorking ||
        document == null ||
        restoreRepository == null ||
        syncHealthRepository == null) {
      return;
    }
    _state = AccountBackupViewState(
      isWorking: true,
      importFileName: _state.importFileName,
      importPreview: _state.importPreview,
    );
    notifyListeners();
    try {
      final health = await syncHealthRepository!.watchHealth(accountId).first;
      final result = await restoreRepository!.restoreImport(
        accountId: accountId,
        document: document,
        readiness: _readiness(health),
        lastSuccessfulSyncAt: health.lastSuccessfulSyncAt,
      );
      _pendingImport = null;
      _state = AccountBackupViewState(importResult: result);
      if (!result.alreadyImported) {
        try {
          await importCommitted?.call();
        } on Object {
          _state = AccountBackupViewState(
            importResult: result,
            error:
                'Restore was accepted locally, but immediate sync could not be scheduled. Use Refresh.',
          );
        }
      }
    } on AccountBackupImportException catch (error) {
      _state = AccountBackupViewState(error: _importError(error.code));
    } on Object {
      _state = const AccountBackupViewState(
        error:
            'Could not restore this backup. No partial local restore was kept.',
      );
    }
    notifyListeners();
  }
}

AccountBackupImportReadiness _readiness(SyncHealth health) =>
    switch (health.outcome) {
      SyncHealthOutcome.good => AccountBackupImportReadiness.ready,
      SyncHealthOutcome.pending => AccountBackupImportReadiness.pending,
      SyncHealthOutcome.inactive
          when health.inactiveReason == SyncInactiveReason.syncStopped =>
        AccountBackupImportReadiness.syncStopped,
      SyncHealthOutcome.inactive =>
        AccountBackupImportReadiness.noAuthorization,
      SyncHealthOutcome.failed
          when health.failureReason == SyncFailureReason.noConnection =>
        AccountBackupImportReadiness.offline,
      SyncHealthOutcome.failed => AccountBackupImportReadiness.stale,
    };

String _importError(String code) {
  if (code.contains('syncStopped')) {
    return 'Resume synchronization and complete a fresh sync before restoring.';
  }
  if (code.contains('noAuthorization')) {
    return 'Authorize Google Tasks and complete a fresh sync before restoring.';
  }
  if (code.contains('offline')) {
    return 'Restore is unavailable offline. Complete a fresh sync first.';
  }
  if (code.startsWith('not_fresh_') || code == 'freshness_changed') {
    return 'Complete a fresh successful sync before restoring. Nothing changed.';
  }
  return 'Could not restore this backup. No partial local restore was kept.';
}

String _suggestedName(DateTime value) {
  final date =
      '${value.year.toString().padLeft(4, '0')}'
      '${value.month.toString().padLeft(2, '0')}'
      '${value.day.toString().padLeft(2, '0')}';
  return 'axiotask-account-backup-v1-$date.json';
}
