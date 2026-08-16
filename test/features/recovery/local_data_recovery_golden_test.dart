import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/recovery/local_data_recovery.dart';
import 'package:axiotask/src/features/recovery/local_data_recovery_view.dart';
import 'package:axiotask/src/features/recovery/local_data_recovery_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(_loadFlutterRoboto);

  testWidgets('reset warning desktop light', (tester) async {
    final model = _model(SyncHealthOutcome.good);
    await model.loadPreview();
    await _pump(tester, model, Brightness.light);
    await tester.tap(find.text('Reset Local Data'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile(
        '../../goldens/linux/local-data-reset-warning-light.png',
      ),
    );
  });

  for (final scenario in <(SyncHealthOutcome, String, Brightness)>[
    (SyncHealthOutcome.good, 'rebuilt-light', Brightness.light),
    (SyncHealthOutcome.failed, 'failed-dark', Brightness.dark),
  ]) {
    testWidgets('reset ${scenario.$2} desktop', (tester) async {
      final model = _model(scenario.$1);
      await model.loadPreview();
      await model.resetConfirmed(model.state.preview!);
      await _pump(tester, model, scenario.$3);

      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile(
          '../../goldens/linux/local-data-reset-${scenario.$2}.png',
        ),
      );
    });
  }
}

Future<void> _pump(
  WidgetTester tester,
  LocalDataRecoveryViewModel model,
  Brightness brightness,
) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: brightness,
        colorSchemeSeed: const Color(0xff315da8),
        fontFamily: 'GoldenRoboto',
        useMaterial3: true,
      ),
      home: LocalDataRecoveryView(viewModel: model),
    ),
  );
  await tester.pumpAndSettle();
}

LocalDataRecoveryViewModel _model(SyncHealthOutcome outcome) =>
    LocalDataRecoveryViewModel(
      accountId: const AccountId(1),
      recovery: LocalDataRecoveryService(
        store: _Store(),
        synchronization: const _Synchronization(),
      ),
      healthRepository: _Health(outcome),
    );

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
  const _Health(this.outcome);

  final SyncHealthOutcome outcome;

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

Future<void> _loadFlutterRoboto() async {
  final packageConfig = File('.dart_tool/package_config.json');
  final document = jsonDecode(await packageConfig.readAsString());
  final packages =
      (document as Map<String, Object?>)['packages']! as List<Object?>;
  final flutter = packages.cast<Map<String, Object?>>().singleWhere(
    (value) => value['name'] == 'flutter',
  );
  final configUri = packageConfig.absolute.uri;
  final flutterPackage = Directory.fromUri(
    configUri.resolve(flutter['rootUri']! as String),
  );
  final flutterRoot = flutterPackage.parent.parent;
  final fontFile = File(
    '${flutterRoot.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  if (!fontFile.existsSync()) {
    throw StateError('The locked Flutter SDK Roboto font is unavailable.');
  }
  final bytes = await fontFile.readAsBytes();
  await (FontLoader('GoldenRoboto')..addFont(
        Future<ByteData>.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
        ),
      ))
      .load();
  final iconFile = File(
    '${flutterRoot.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!iconFile.existsSync()) {
    throw StateError(
      'The locked Flutter SDK Material Icons font is unavailable.',
    );
  }
  final iconBytes = await iconFile.readAsBytes();
  await (FontLoader('MaterialIcons')..addFont(
        Future<ByteData>.value(
          ByteData.view(
            iconBytes.buffer,
            iconBytes.offsetInBytes,
            iconBytes.length,
          ),
        ),
      ))
      .load();
}
