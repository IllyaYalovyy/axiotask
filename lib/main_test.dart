import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app/axiotask_app.dart';
import 'src/app/composition/test_composition.dart';
import 'src/app/connectivity.dart';
import 'src/app/lifecycle.dart';
import 'src/app/tasks_feature_runtime.dart';
import 'src/data/backup/local_account_backup_exporter.dart';
import 'src/features/backup/account_backup_view.dart';

const String _instanceId = String.fromEnvironment(
  'AXIOTASK_TEST_INSTANCE',
  defaultValue: 'manual-synthetic',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final composition = TestComposition.create(instanceId: _instanceId);
  final lifecycle = Platform.isLinux ? LinuxLifecycleBridge() : null;
  final connectivity = Platform.isLinux
      ? await LinuxConnectivityBridge.open()
      : null;
  final runtime = await TasksFeatureRuntime.open(
    composition,
    lifecycle: lifecycle,
    connectivity: connectivity,
  );
  runApp(
    AxiotaskApp(
      viewModel: runtime.viewModel,
      accountBackupBuilder:
          Platform.isLinux && runtime.accountBackupRepository != null
          ? (_) => AccountBackupHost(
              accountId: runtime.viewModel.accountId,
              repository: runtime.accountBackupRepository!,
              exporter: const LocalAccountBackupExporter(
                FileSelectorAccountBackupSaveLocationPicker(),
              ),
              clock: composition.clock,
            )
          : null,
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(runtime.start());
  });
}
