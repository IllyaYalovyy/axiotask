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
  var _result = false;
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
  );

  Future<void> _capture() async {
    try {
      final output = Directory('screenshots/actual');
      await output.create(recursive: true);
      await _settleFrames();
      await _write(output, 'account-backup-warning-light.png');

      await _viewModel.export();
      setState(() => _result = true);
      await _settleFrames();
      await _write(output, 'account-backup-result-dark.png');
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
      key: ValueKey<bool>(_result),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: _result ? Brightness.dark : Brightness.light,
        colorSchemeSeed: const Color(0xff315da8),
        useMaterial3: true,
      ),
      home: AccountBackupView(viewModel: _viewModel),
    ),
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }
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
