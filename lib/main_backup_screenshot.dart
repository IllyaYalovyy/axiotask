import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'src/core/clock.dart';
import 'src/data/backup/local_account_backup_exporter.dart';
import 'src/domain/backup/account_backup.dart';
import 'src/domain/model/tasks.dart';
import 'src/domain/repository/account_backup_repository.dart';
import 'src/features/backup/account_backup_view.dart';
import 'src/features/backup/account_backup_view_model.dart';
import 'src/sync/health/sync_health.dart';
import 'src/sync/health/sync_health_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _AccountBackupScreenshotSequence());
}

final class _AccountBackupScreenshotSequence extends StatefulWidget {
  const _AccountBackupScreenshotSequence();

  @override
  State<_AccountBackupScreenshotSequence> createState() =>
      _AccountBackupScreenshotSequenceState();
}

final class _AccountBackupScreenshotSequenceState
    extends State<_AccountBackupScreenshotSequence> {
  final GlobalKey _boundaryKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  var _step = 0;
  late final AccountBackupViewModel _viewModel = _createViewModel();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  AccountBackupViewModel _createViewModel() => AccountBackupViewModel(
    accountId: const AccountId(1),
    repository: const _Repository(),
    exporter: const _Exporter(),
    clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
    restoreRepository: _RestoreRepository(),
    importer: const _Importer(),
    syncHealthRepository: const _HealthRepository(),
  );

  Future<void> _capture() async {
    try {
      final output = Directory('screenshots/actual');
      await output.create(recursive: true);
      await _settleFrames();
      await _write(output, 'account-backup-warning-light.png');

      await _viewModel.export();
      setState(() => _step = 1);
      await _settleFrames();
      await _write(output, 'account-backup-result-dark.png');

      await _viewModel.chooseImport();
      setState(() => _step = 2);
      await _settleFrames();
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      await _settleFrames();
      await _write(output, 'account-restore-preview-light.png');

      await _viewModel.restore();
      setState(() => _step = 3);
      await _settleFrames();
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      await _settleFrames();
      await _write(output, 'account-restore-result-dark.png');
      exit(0);
    } on Object catch (error) {
      stderr.writeln(
        'Synthetic account backup screenshot capture failed: $error',
      );
      exit(1);
    }
  }

  Future<void> _write(Directory output, String name) async {
    final boundary =
        _boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) throw StateError('PNG encoding failed.');
    await File('${output.path}/$name').writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
  }

  Future<void> _settleFrames() async {
    await Future<void>.delayed(Duration.zero);
    for (var count = 0; count < 3; count += 1) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _boundaryKey,
    child: MaterialApp(
      key: ValueKey<int>(_step),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: _step.isOdd ? Brightness.dark : Brightness.light,
        colorSchemeSeed: const Color(0xff315da8),
        useMaterial3: true,
      ),
      home: AccountBackupView(
        viewModel: _viewModel,
        scrollController: _scrollController,
      ),
    ),
  );

  @override
  void dispose() {
    _viewModel.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

final class _Importer implements AccountBackupImporter {
  const _Importer();

  @override
  Future<AccountBackupOpenResult> open() async =>
      AccountBackupOpenResult.opened(
        fileName: 'axiotask-account-backup-v1-20260815.json',
        contents: const AccountBackupCodec().encode(
          AccountBackupSnapshot(
            sourceGoogleSubject: 'different-synthetic-subject',
            lists: const <AccountBackupList>[
              AccountBackupList(
                key: 'list-000001',
                googleId: 'source-list',
                title: 'Restored planning',
                order: 0,
              ),
            ],
            tasks: const <AccountBackupTask>[
              AccountBackupTask(
                key: 'task-000001',
                googleId: 'source-task',
                listKey: 'list-000001',
                parentKey: null,
                title: 'Synthetic restored task',
                notes: 'Synthetic private restore preview',
                status: TaskStatus.needsAction,
                due: null,
                order: 0,
              ),
            ],
          ),
          exportedAt: DateTime.utc(2026, 8, 15, 12),
        ),
      );
}

final class _RestoreRepository implements AccountBackupRestoreRepository {
  @override
  Future<AccountBackupImportPreview> previewImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  }) async => const AccountBackupImportPreview(
    documentDigest: 'synthetic-digest',
    sourceAccountMatches: false,
    listCount: 1,
    taskCount: 1,
    listsToCreate: 1,
    tasksToCreate: 1,
    existingListCount: 2,
    existingTaskCount: 3,
    alreadyImported: false,
  );

  @override
  Future<AccountBackupImportResult> restoreImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  }) async => const AccountBackupImportResult(
    createdListCount: 1,
    existingListCount: 2,
    createdTaskCount: 1,
    existingTaskCount: 3,
    alreadyImported: false,
  );
}

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.good,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: DateTime.utc(2026, 8, 16, 12),
      evaluatedAt: DateTime.utc(2026, 8, 16, 12),
    ),
  );
}

final class _Repository implements AccountBackupRepository {
  const _Repository();

  @override
  Future<AccountBackupSnapshot> readProjectedAccount(
    AccountId accountId,
  ) async => AccountBackupSnapshot(
    sourceGoogleSubject: 'synthetic-screenshot-subject',
    lists: const <AccountBackupList>[
      AccountBackupList(
        key: 'list-000001',
        googleId: 'synthetic-list',
        title: 'Planning',
        order: 0,
      ),
      AccountBackupList(
        key: 'list-000002',
        googleId: null,
        title: 'Offline capture',
        order: 1,
      ),
    ],
    tasks: const <AccountBackupTask>[
      AccountBackupTask(
        key: 'task-000001',
        googleId: 'synthetic-task',
        listKey: 'list-000001',
        parentKey: null,
        title: 'Synthetic review',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
        order: 0,
      ),
      AccountBackupTask(
        key: 'task-000002',
        googleId: null,
        listKey: 'list-000002',
        parentKey: null,
        title: 'Acknowledged offline task',
        notes: 'Synthetic private note',
        status: TaskStatus.needsAction,
        due: null,
        order: 0,
      ),
      AccountBackupTask(
        key: 'task-000003',
        googleId: null,
        listKey: 'list-000002',
        parentKey: null,
        title: 'Second offline task',
        notes: null,
        status: TaskStatus.completed,
        due: null,
        order: 1,
      ),
    ],
  );
}

final class _Exporter implements AccountBackupExporter {
  const _Exporter();

  @override
  Future<AccountBackupSaveResult> save({
    required String suggestedName,
    required String contents,
  }) async => const AccountBackupSaveResult.saved(
    'axiotask-account-backup-v1-20260816.json',
  );
}
