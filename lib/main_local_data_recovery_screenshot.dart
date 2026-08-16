import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'src/domain/model/tasks.dart';
import 'src/domain/recovery/local_data_recovery.dart';
import 'src/features/recovery/local_data_recovery_view.dart';
import 'src/features/recovery/local_data_recovery_view_model.dart';
import 'src/sync/health/sync_health.dart';
import 'src/sync/health/sync_health_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _RecoveryScreenshotSequence());
}

final class _RecoveryScreenshotSequence extends StatefulWidget {
  const _RecoveryScreenshotSequence();

  @override
  State<_RecoveryScreenshotSequence> createState() =>
      _RecoveryScreenshotSequenceState();
}

final class _RecoveryScreenshotSequenceState
    extends State<_RecoveryScreenshotSequence> {
  final GlobalKey _boundaryKey = GlobalKey();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  var _step = 0;
  final _Health _health = _Health(SyncHealthOutcome.good);
  late final LocalDataRecoveryViewModel _viewModel = _createModel();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  LocalDataRecoveryViewModel _createModel() => LocalDataRecoveryViewModel(
    accountId: const AccountId(1),
    recovery: LocalDataRecoveryService(
      store: _Store(),
      synchronization: const _Synchronization(),
    ),
    healthRepository: _health,
  );

  Future<void> _capture() async {
    try {
      final output = Directory('screenshots/actual');
      await output.create(recursive: true);
      await _viewModel.loadPreview();
      await _settleFrames();
      final dialog = showLocalDataResetConfirmation(
        _navigatorKey.currentContext!,
        _viewModel.state.preview!,
      );
      await _settleFrames();
      await _write(output, 'local-data-reset-warning-light.png');
      _navigatorKey.currentState!.pop(false);
      await dialog;
      await _settleFrames();

      await _viewModel.resetConfirmed(_viewModel.state.preview!);
      if (_viewModel.state.isWorking ||
          _viewModel.state.outcome != LocalDataRecoveryOutcome.rebuilt) {
        throw StateError('Synthetic successful rebuild state was not reached.');
      }
      setState(() => _step = 1);
      await _settleFrames();
      await _write(output, 'local-data-reset-rebuilt-light.png');

      _health.outcome = SyncHealthOutcome.failed;
      await _viewModel.resetConfirmed(_viewModel.state.preview!);
      if (_viewModel.state.isWorking ||
          _viewModel.state.outcome != LocalDataRecoveryOutcome.rebuildFailed) {
        throw StateError('Synthetic failed rebuild state was not reached.');
      }
      setState(() => _step = 2);
      await _settleFrames();
      await _write(output, 'local-data-reset-failed-dark.png');
      exit(0);
    } on Object catch (error) {
      stderr.writeln('Synthetic local data reset capture failed: $error');
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
      navigatorKey: _navigatorKey,
      key: ValueKey<int>(_step),
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      themeAnimationDuration: Duration.zero,
      theme: ThemeData(
        brightness: _step == 2 ? Brightness.dark : Brightness.light,
        colorSchemeSeed: const Color(0xff315da8),
        useMaterial3: true,
      ),
      home: LocalDataRecoveryView(viewModel: _viewModel),
    ),
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }
}

final class _Store implements LocalDataResetStore {
  var reset = false;

  @override
  Future<LocalDataResetPreview> preview(AccountId accountId) async =>
      LocalDataResetPreview(
        accountId: accountId,
        cachedListCount: reset ? 0 : 4,
        cachedTaskCount: reset ? 0 : 18,
        pendingChangeCount: reset ? 0 : 3,
        uncertainChangeCount: reset ? 0 : 1,
        undoRecordCount: reset ? 0 : 2,
        accountPreferenceCount: reset ? 0 : 5,
        syncHistoryCount: reset ? 0 : 9,
        importManifestCount: reset ? 0 : 1,
      );

  @override
  Future<void> resetPartition(AccountId accountId) async => reset = true;
}

final class _Synchronization implements LocalDataResetSynchronization {
  const _Synchronization();

  @override
  Future<void> serializeResetAndRebuild(Future<void> Function() reset) =>
      reset();
}

final class _Health implements SyncHealthRepository {
  _Health(this.outcome);

  SyncHealthOutcome outcome;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: outcome,
      failureReason: outcome == SyncHealthOutcome.failed
          ? SyncFailureReason.noConnection
          : null,
      action: outcome == SyncHealthOutcome.failed
          ? SyncHealthAction.retry
          : SyncHealthAction.none,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: outcome == SyncHealthOutcome.good
          ? DateTime.utc(2026, 8, 16, 12)
          : null,
      evaluatedAt: DateTime.utc(2026, 8, 16, 12),
    ),
  );
}
